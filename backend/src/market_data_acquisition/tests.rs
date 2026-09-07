use super::*;
use crate::market_data::Credentials;
use axum::{
    extract::{Query, State},
    routing::get,
};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

#[derive(Clone, Default)]
struct Provider {
    queries: Arc<Mutex<Vec<BTreeMap<String, String>>>>,
    missing: Arc<Mutex<bool>>,
}
async fn bars(State(p): State<Provider>, Query(q): Query<BTreeMap<String, String>>) -> Json<Value> {
    assert_eq!(q["feed"], "sip");
    assert_eq!(q["adjustment"], "all");
    p.queries.lock().unwrap().push(q.clone());
    let mut bars = serde_json::Map::new();
    for symbol in q["symbols"].split(',') {
        let count = if *p.missing.lock().unwrap() { 3 } else { 4 };
        bars.insert(symbol.into(), json!((5..5+count).map(|day| json!({"t":format!("2026-01-{day:02}T05:00:00Z"),"o":123.451234,"h":126,"l":120,"c":124.451234,"v":1000})).collect::<Vec<_>>()));
    }
    Json(json!({"bars":bars,"next_page_token":null}))
}
fn data_request(symbols: Value) -> Value {
    json!({"calendar":"XNYS_2025_2026_v1","symbols":symbols,"start":"2026-01-05","end":"2026-01-08","benchmark":"SPY","symbol_asof":"2026-01-08","cash":"zero_interest"})
}
async fn connection() -> tokio_postgres::Client {
    let (db, c) = tokio_postgres::connect(
        &std::env::var("DATABASE_URL").unwrap(),
        tokio_postgres::NoTls,
    )
    .await
    .unwrap();
    tokio::spawn(async move {
        let _ = c.await;
    });
    db
}
async fn waiting(db: &tokio_postgres::Client, label: &str, symbols: Value) -> i64 {
    let id = crate::incubator_experiment::tests::ticket(db, label).await;
    crate::incubator_experiment::tests::acquisition_tick(data_request(symbols))
        .await
        .unwrap();
    let v: Value = db
        .query_one("SELECT read_incubator_experiment($1)", &[&id])
        .await
        .unwrap()
        .get(0);
    assert_eq!(v["status"], "awaiting_data");
    id
}
async fn complete() {
    for _ in 0..3 {
        assert!(
            crate::incubator_experiment::tests::acquisition_tick(Value::Null)
                .await
                .unwrap()
        );
    }
}
async fn claim(db: &tokio_postgres::Client, source: &str) -> Value {
    db.query_one(
        "SELECT claim_market_data_acquisition($1::text::uuid)",
        &[&source],
    )
    .await
    .unwrap()
    .get::<_, Option<Value>>(0)
    .unwrap()
}
async fn queue(db: &tokio_postgres::Client, source: &str) {
    db.query_one(
        "SELECT queue_market_data_acquisitions($1::text::uuid)",
        &[&source],
    )
    .await
    .unwrap();
}
#[tokio::test]
#[ignore = "requires isolated WU-62 PostgreSQL fixture"]
async fn acquisition_workflow() {
    let admin = connection().await;
    admin
        .batch_execute(include_str!(
            "../../../db/fixtures/wu62_market_data_seed.sql"
        ))
        .await
        .unwrap();
    let source: String = admin
        .query_one("SELECT id FROM wu62_source", &[])
        .await
        .unwrap()
        .get(0);
    let db = connection().await;
    db.batch_execute("SET ROLE market_data_acquirer")
        .await
        .unwrap();
    let other = connection().await;
    other
        .batch_execute("SET ROLE market_data_acquirer")
        .await
        .unwrap();
    assert!(db
        .batch_execute("DELETE FROM market_data_acquisition")
        .await
        .is_err());
    assert!(db
        .batch_execute("SELECT bind_incubator_experiment_dataset(1,gen_random_uuid())")
        .await
        .is_err());
    let provider = Provider::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let app = Router::new()
        .route("/bars", get(bars))
        .with_state(provider.clone());
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let client = AlpacaDailyClient::new(
        serde_json::from_value::<Credentials>(json!({"key_id":"fixture","secret_key":"fixture"}))
            .unwrap(),
    )
    .unwrap()
    .test_endpoint(format!("http://{addr}/bars"));
    let first = waiting(&admin, "wu62-first", json!(["A", "B", "C", "D"])).await;
    let (a, b) = tokio::join!(tick(&db, &source, &client), tick(&other, &source, &client));
    assert_eq!([a.unwrap(), b.unwrap()].iter().filter(|x| **x).count(), 1);
    complete().await;
    let result: Value = admin
        .query_one("SELECT read_incubator_experiment($1)", &[&first])
        .await
        .unwrap()
        .get(0);
    assert_eq!(result["status"], "completed");
    assert_eq!(result["detail"]["result"]["outcome"], "diagnostic_only");
    assert_eq!(provider.queries.lock().unwrap().len(), 1);
    // A complete compatible cache avoids HTTP entirely.
    let reused = waiting(&admin, "wu62-reused", json!(["A", "B", "C", "D"])).await;
    assert!(tick(&db, &source, &client).await.unwrap());
    complete().await;
    assert_eq!(provider.queries.lock().unwrap().len(), 1);
    let bindings: i64 = admin
        .query_one(
            "SELECT count(*) FROM incubator_experiment_dataset WHERE experiment_id IN ($1,$2)",
            &[&first, &reused],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(bindings, 2);
    // A new symbol is fetched as a full window; existing symbols are reused.
    waiting(&admin, "wu62-gap", json!(["A", "B", "C", "E"])).await;
    assert!(tick(&db, &source, &client).await.unwrap());
    complete().await;
    assert_eq!(
        provider.queries.lock().unwrap().last().unwrap()["symbols"],
        "E"
    );
    *provider.missing.lock().unwrap() = true;
    let missing = waiting(&admin, "wu62-missing", json!(["Z1", "Z2", "Z3", "Z4"])).await;
    assert!(tick(&db, &source, &client).await.unwrap());
    let job: Value = admin
        .query_one("SELECT read_market_data_acquisition($1)", &[&missing])
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .unwrap();
    assert_eq!(job["state"], "failed");
    assert_eq!(job["error_code"], "IncompleteCoverage");
    let pinned: bool = admin
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=$1)",
            &[&missing],
        )
        .await
        .unwrap()
        .get(0);
    assert!(!pinned);
    // Explicit retry preserves the same request and uses the remaining attempt budget.
    *provider.missing.lock().unwrap() = false;
    admin
        .query_one(
            "SELECT control_market_data_acquisition($1,'retry')",
            &[&missing],
        )
        .await
        .unwrap();
    assert!(tick(&db, &source, &client).await.unwrap());
    complete().await;
    let recovered = waiting(&admin, "wu62-restart", json!(["A", "B", "C", "D"])).await;
    queue(&db, &source).await;
    let old = claim(&db, &source).await;
    assert_eq!(old["experiment_id"], recovered);
    admin.execute("UPDATE market_data_acquisition SET lease_until=now()-interval '1 second' WHERE experiment_id=$1",&[&recovered]).await.unwrap();
    // A different connection claims the expired lease. The old worker has a valid
    // response and no existing binding to mask a broken lease fence.
    let replacement = claim(&other, &source).await;
    let bundle = client
        .acquire(
            &serde_json::from_value(old["request"].clone()).unwrap(),
            &json!([]),
        )
        .await
        .unwrap();
    let error = db
        .query_one(
            "SELECT finish_market_data_acquisition($1,$2::text::uuid,$3)",
            &[&recovered, &old["lease_token"].as_str().unwrap(), &bundle],
        )
        .await
        .unwrap_err();
    assert_eq!(
        error.as_db_error().unwrap().message(),
        "stale_acquisition_lease"
    );
    let count: i64 = admin
        .query_one(
            "SELECT count(*) FROM incubator_experiment_dataset WHERE experiment_id=$1",
            &[&recovered],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(count, 0);
    other
        .query_one(
            "SELECT finish_market_data_acquisition($1,$2::text::uuid,$3)",
            &[
                &recovered,
                &replacement["lease_token"].as_str().unwrap(),
                &bundle,
            ],
        )
        .await
        .unwrap();
    complete().await;
    let cancelled = waiting(&admin, "wu62-cancel", json!(["A", "B", "C", "D"])).await;
    queue(&db, &source).await;
    let lease = claim(&db, &source).await;
    admin
        .query_one(
            "SELECT control_market_data_acquisition($1,'cancel')",
            &[&cancelled],
        )
        .await
        .unwrap();
    assert!(db
        .query_one(
            "SELECT finish_market_data_acquisition($1,$2::text::uuid,$3)",
            &[&cancelled, &lease["lease_token"].as_str().unwrap(), &bundle]
        )
        .await
        .is_err());
    let revoked = waiting(&admin, "wu62-revoke", json!(["A", "B", "C", "D"])).await;
    queue(&db, &source).await;
    let lease = claim(&db, &source).await;
    admin
        .query_one(
            "SELECT remove_market_data_source($1::text::uuid)",
            &[&source],
        )
        .await
        .unwrap();
    assert!(db
        .query_one(
            "SELECT finish_market_data_acquisition($1,$2::text::uuid,$3)",
            &[&revoked, &lease["lease_token"].as_str().unwrap(), &bundle]
        )
        .await
        .is_err());
    assert!(!tick(&other, &source, &client).await.unwrap());
    let clean: bool = admin.query_one("SELECT NOT EXISTS(SELECT 1 FROM market_data_payload) AND NOT EXISTS(SELECT 1 FROM market_data_result) AND NOT EXISTS(SELECT 1 FROM audit_event WHERE payload::text LIKE '%123.451234%') AND NOT EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id IN ($1,$2))",&[&cancelled,&revoked]).await.unwrap().get(0);
    assert!(clean);
    let valid: bool = admin
        .query_one("SELECT valid FROM verify_audit_event_chain()", &[])
        .await
        .unwrap()
        .get(0);
    assert!(valid);
    server.abort();
}
