use super::*;
use axum::extract::Query;
use chrono::{Datelike, TimeZone};
use std::collections::BTreeMap;
async fn bars(Query(q): Query<BTreeMap<String, String>>) -> Json<Value> {
    let start = chrono::NaiveDate::parse_from_str(&q["start"][..10], "%Y-%m-%d").unwrap();
    let end = chrono::NaiveDate::parse_from_str(&q["end"][..10], "%Y-%m-%d").unwrap();
    let mut rows = Vec::new();
    let mut day = start;
    while day <= end {
        if day.weekday().number_from_monday() <= 5 && day.to_string() != "2026-01-19" {
            rows.push(json!({"t":chrono_tz::America::New_York.from_local_datetime(&day.and_hms_opt(0,0,0).unwrap()).single().unwrap().to_rfc3339(),"o":100,"h":102,"l":99,"c":101,"v":1000}));
        }
        day = day.succ_opt().unwrap();
    }
    Json(
        json!({"bars":q["symbols"].split(',').map(|s|(s,rows.clone())).collect::<BTreeMap<_,_>>(),"next_page_token":null}),
    )
}
#[tokio::test]
#[ignore = "requires isolated WU63 database"]
async fn setup_and_refresh() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, Router::new().route("/bars", get(bars)))
            .await
            .unwrap();
    });
    let dir = std::env::temp_dir().join(format!("wu63-secrets-{}", rand::random::<u64>()));
    let mut s = Connection::new(dir.join("credentials.json"));
    s.endpoint = Some(format!("http://{addr}/bars"));
    let existing = dir.join("paper.json");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        &existing,
        br#"{"key_id":"fixture-key","secret_key":"fixture-secret"}"#,
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&existing, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    s = s.with_existing_credentials(existing.clone());
    let s = Arc::new(s);
    let input = || Setup {
        key_id: "fixture-key".into(),
        secret_key: "fixture-secret".into(),
        rights_confirmed: true,
    };
    let mut rejected = input();
    rejected.rights_confirmed = false;
    assert!(setup(State(s.clone()), Json(rejected)).await.is_err());
    assert!(!s.path.exists());
    let before = std::fs::read(&existing).unwrap();
    assert!(reuse(
        State(s.clone()),
        Json(ReuseSetup {
            rights_confirmed: false
        })
    )
    .await
    .is_err());
    assert!(!s.path.exists());
    reuse(
        State(s.clone()),
        Json(ReuseSetup {
            rights_confirmed: true,
        }),
    )
    .await
    .unwrap();
    assert_eq!(std::fs::read(&existing).unwrap(), before);
    assert_eq!(std::fs::read(&s.path).unwrap(), before);
    std::fs::rename(&existing, dir.join("paper.saved")).unwrap();
    let missing = reuse(
        State(s.clone()),
        Json(ReuseSetup {
            rights_confirmed: true,
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(missing.1 .0["error"], "existing_connection_unavailable");
    assert_eq!(std::fs::read(&s.path).unwrap(), before);
    std::fs::rename(dir.join("paper.saved"), &existing).unwrap();
    assert!(serde_json::from_value::<ReuseSetup>(
        json!({"rights_confirmed":true,"path":"/arbitrary"})
    )
    .is_err());

    setup(State(s.clone()), Json(input())).await.unwrap();
    let json = status(State(s.clone())).await.unwrap().0;
    assert_eq!(json["existing_alpaca_available"], true);
    assert!(!json.to_string().contains("fixture-secret"));
    assert!(!json.to_string().contains("fixture-key"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&s.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    let admin = db().await.unwrap();
    let src = json["settings"]["source_id"].as_str().unwrap();
    let id = crate::incubator_experiment::tests::ticket(&admin.client, "wu63-owner-request").await;
    crate::incubator_experiment::tests::acquisition_tick(Value::Null)
        .await
        .unwrap();
    let request = json!({"calendar":"XNYS_2025_2026_v1","symbols":["AAPL","XOM","JPM","NEE"],"start":"2026-01-05","end":"2026-01-08","benchmark":"SPY","symbol_asof":"2026-01-08","cash":"zero_interest"});
    admin
        .client
        .query_one("SELECT supply_market_data_request($1,$2)", &[&id, &request])
        .await
        .unwrap();
    admin
        .client
        .query_one("SELECT supply_market_data_request($1,$2)", &[&id, &request])
        .await
        .unwrap();
    let mut other = request.clone();
    other["benchmark"] = json!("QQQ");
    assert!(admin
        .client
        .query_one("SELECT supply_market_data_request($1,$2)", &[&id, &other])
        .await
        .is_err());
    let client = s.client(&s.load().unwrap()).unwrap();
    admin
        .client
        .batch_execute("SET ROLE market_data_service")
        .await
        .unwrap();
    assert!(
        admin
            .client
            .query_one("SELECT queue_market_data_refreshes_at(now())", &[])
            .await
            .unwrap_err()
            .code()
            == Some(&tokio_postgres::error::SqlState::INSUFFICIENT_PRIVILEGE)
    );
    assert!(
        admin
            .client
            .batch_execute("UPDATE market_data_settings SET enabled=false")
            .await
            .unwrap_err()
            .code()
            == Some(&tokio_postgres::error::SqlState::INSUFFICIENT_PRIVILEGE)
    );
    admin
        .client
        .query_one("SELECT change_market_data_settings(false,true)", &[])
        .await
        .unwrap();
    assert!(
        !crate::market_data_acquisition::tick(&admin.client, src, &client)
            .await
            .unwrap()
    );
    admin
        .client
        .query_one("SELECT change_market_data_settings(true,true)", &[])
        .await
        .unwrap();
    assert!(
        crate::market_data_acquisition::tick(&admin.client, src, &client)
            .await
            .unwrap()
    );
    admin.client.batch_execute("RESET ROLE").await.unwrap();
    for _ in 0..3 {
        crate::incubator_experiment::tests::acquisition_tick(Value::Null)
            .await
            .unwrap();
    }
    let pinned: String = admin
        .client
        .query_one(
            "SELECT snapshot_id::text FROM incubator_experiment_dataset WHERE experiment_id=$1",
            &[&id],
        )
        .await
        .unwrap()
        .get(0);
    for now in ["2026-01-19T12:00:00Z", "2026-01-20T10:59:00Z"] {
        let n: i32 = admin
            .client
            .query_one(
                "SELECT queue_market_data_refreshes_at($1::text::timestamptz)",
                &[&now],
            )
            .await
            .unwrap()
            .get(0);
        assert_eq!(n, 0);
    }
    let n: i32 = admin
        .client
        .query_one(
            "SELECT queue_market_data_refreshes_at('2026-01-20T11:00:00Z')",
            &[],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(n, 1);
    let n: i32 = admin
        .client
        .query_one(
            "SELECT queue_market_data_refreshes_at('2026-01-20T11:00:00Z')",
            &[],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(n, 0);
    let range: Value = admin
        .client
        .query_one("SELECT request->'sessions' FROM market_data_refresh", &[])
        .await
        .unwrap()
        .get(0);
    assert_eq!(
        range,
        json!(["2026-01-13", "2026-01-14", "2026-01-15", "2026-01-16"])
    );
    admin
        .client
        .batch_execute("SET ROLE market_data_service")
        .await
        .unwrap();
    refresh(&admin.client, &client).await.unwrap();
    admin.client.batch_execute("RESET ROLE").await.unwrap();
    let saved: String = admin
        .client
        .query_one(
            "SELECT snapshot_id::text FROM incubator_experiment_dataset WHERE experiment_id=$1",
            &[&id],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(pinned, saved);
    let refreshed: String = admin
        .client
        .query_one("SELECT state FROM market_data_refresh", &[])
        .await
        .unwrap()
        .get(0);
    assert_eq!(refreshed, "completed");
    // Pausing fences even an otherwise valid response from an already leased worker.
    admin
        .client
        .query_one(
            "SELECT queue_market_data_refreshes_at('2026-01-21T11:00:00Z')",
            &[],
        )
        .await
        .unwrap();
    let lease: Value = admin
        .client
        .query_one("SELECT claim_market_data_refresh()", &[])
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .unwrap();
    let bundle = client
        .download(&serde_json::from_value(lease["request"].clone()).unwrap())
        .await
        .unwrap();
    admin
        .client
        .query_one("SELECT change_market_data_settings(false,true)", &[])
        .await
        .unwrap();
    let error = admin
        .client
        .query_one(
            "SELECT finish_market_data_refresh($1,$2::text::date,$3::text::uuid,$4)",
            &[
                &id,
                &lease["session_end"].as_str().unwrap(),
                &lease["token"].as_str().unwrap(),
                &bundle,
            ],
        )
        .await
        .unwrap_err();
    assert_eq!(
        error.as_db_error().unwrap().message(),
        "refresh_no_longer_active"
    );
    admin
        .client
        .query_one("SELECT change_market_data_settings(true,true)", &[])
        .await
        .unwrap();
    admin
        .client
        .query_one(
            "SELECT set_incubator_research_archived('wu63-owner-request','wu63-archive',true,0)",
            &[],
        )
        .await
        .unwrap();
    let archived_error = admin
        .client
        .query_one(
            "SELECT finish_market_data_refresh($1,$2::text::date,$3::text::uuid,$4)",
            &[
                &id,
                &lease["session_end"].as_str().unwrap(),
                &lease["token"].as_str().unwrap(),
                &bundle,
            ],
        )
        .await
        .unwrap_err();
    assert_eq!(
        archived_error.as_db_error().unwrap().message(),
        "refresh_no_longer_active"
    );
    // Remove the lease as an alternative reason for refusing this archived job.
    admin.client.execute("UPDATE market_data_refresh SET state='queued',token=NULL,lease_until=NULL WHERE experiment_id=$1 AND state='leased'", &[&id]).await.unwrap();
    let n: i32 = admin
        .client
        .query_one(
            "SELECT queue_market_data_refreshes_at('2026-01-22T11:00:00Z')",
            &[],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(n, 0);
    assert!(admin
        .client
        .query_one("SELECT claim_market_data_refresh()", &[])
        .await
        .unwrap()
        .get::<_, Option<Value>>(0)
        .is_none());
    admin
        .client
        .batch_execute("SET ROLE market_data_service")
        .await
        .unwrap();
    admin
        .client
        .query_one("SELECT run_market_data_housekeeping()", &[])
        .await
        .unwrap();
    assert_eq!(
        admin
            .client
            .query_one("SELECT run_market_data_housekeeping()", &[])
            .await
            .unwrap()
            .get::<_, i32>(0),
        0
    );
    admin.client.batch_execute("RESET ROLE").await.unwrap();
    assert_eq!(
        admin
            .client
            .query_one("SELECT count(*) FROM market_data_housekeeping", &[])
            .await
            .unwrap()
            .get::<_, i64>(0),
        1
    );
    let safe:bool=admin.client.query_one("SELECT NOT EXISTS(SELECT 1 FROM audit_event WHERE payload::text LIKE '%fixture-secret%') AND (SELECT valid FROM verify_audit_event_chain())",&[]).await.unwrap().get(0);
    assert!(safe);
    // Setup serializes only credential writers. Holding its lock cannot stall the worker.
    let setup_gate = s.gate.lock().await;
    tokio::time::timeout(Duration::from_secs(3), work(&s))
        .await
        .expect("worker shares setup gate")
        .unwrap();
    drop(setup_gate);
    server.abort();
    std::fs::remove_dir_all(dir).unwrap();
}
