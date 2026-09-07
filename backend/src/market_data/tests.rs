use super::*;
use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::get,
    Router,
};
use std::{collections::VecDeque, sync::Arc};
use tokio::sync::Mutex;

type Reply = (u16, Value, Option<String>);
#[derive(Clone)]
struct Mock {
    replies: Arc<Mutex<VecDeque<Reply>>>,
    queries: Arc<Mutex<Vec<BTreeMap<String, String>>>>,
}
async fn handler(
    State(state): State<Mock>,
    Query(query): Query<BTreeMap<String, String>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    assert_eq!(headers.get("APCA-API-KEY-ID").unwrap(), "test-key");
    assert_eq!(headers.get("APCA-API-SECRET-KEY").unwrap(), "test-secret");
    state.queries.lock().await.push(query);
    let (code, body, retry) = state
        .replies
        .lock()
        .await
        .pop_front()
        .expect("unexpected extra HTTP request");
    let mut headers = HeaderMap::new();
    if let Some(value) = retry {
        headers.insert("retry-after", value.parse().unwrap());
    }
    (
        StatusCode::from_u16(code).unwrap(),
        headers,
        axum::Json(body),
    )
}
async fn mock(replies: Vec<Reply>) -> (AlpacaDailyClient, Mock, tokio::task::JoinHandle<()>) {
    let state = Mock {
        replies: Arc::new(Mutex::new(replies.into())),
        queries: Arc::new(Mutex::new(vec![])),
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = Router::new()
        .route("/v2/stocks/bars", get(handler))
        .with_state(state.clone());
    let handle = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let mut client = AlpacaDailyClient::new(Credentials {
        key_id: "test-key".into(),
        secret_key: "test-secret".into(),
    })
    .unwrap();
    client.endpoint = format!("http://{address}/v2/stocks/bars");
    client.pace = Duration::ZERO;
    (client, state, handle)
}
fn request() -> PanelRequest {
    serde_json::from_value(json!({"schema_version":1,"symbols":["AAPL","XOM","JPM","NEE"],
        "sessions":["2025-01-06","2025-01-07","2025-01-08","2025-01-09"],
        "benchmark":"SPY","symbol_asof":"2025-01-09","cash":"zero_interest",
        "spec":{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":1}})).unwrap()
}
fn bars(request: &PanelRequest) -> Value {
    let mut result = serde_json::Map::new();
    for (i, symbol) in request.symbols().iter().enumerate() {
        let bars = request.sessions.iter().enumerate().map(|(j,date)| json!({
            "t":format!("{date}T05:00:00Z"),"o":100+i+j,"h":110+i+j,"l":90+i+j,"c":101+i+j,"v":1000
        })).collect::<Vec<_>>();
        result.insert(symbol.clone(), json!(bars));
    }
    json!({"bars":result,"next_page_token":null})
}
#[tokio::test]
async fn paginated_download_has_explicit_feed_and_reproducible_panel() {
    let request = request();
    let all = bars(&request);
    let mut first = all.clone();
    let remainder = first["bars"]
        .as_object_mut()
        .unwrap()
        .remove("AAPL")
        .unwrap();
    first["next_page_token"] = json!("second-page");
    let second = json!({"bars":{"AAPL":remainder},"next_page_token":null});
    let (client, state, task) = mock(vec![(200, first, None), (200, second, None)]).await;
    let result = client.download(&request).await.unwrap();
    task.abort();
    assert_eq!(result["observations"].as_array().unwrap().len(), 20);
    assert_eq!(result["source_facts"]["pages"], 2);
    assert_eq!(result["source_facts"]["registered"], false);
    assert_eq!(result["source_facts"]["cash"], "assumed_zero_interest");
    let queries = state.queries.lock().await;
    for q in queries.iter() {
        assert_eq!(q["feed"], "sip");
        assert_eq!(q["timeframe"], "1Day");
        assert_eq!(q["adjustment"], "all");
        assert_eq!(q["currency"], "USD");
        assert_eq!(q["asof"], "2025-01-09");
        assert_eq!(q["start"], "2025-01-06T00:00:00-05:00");
        assert_eq!(q["end"], "2025-01-09T23:59:59-05:00");
    }
    assert_eq!(queries[1]["page_token"], "second-page");
    let panel = crate::momentum::Dataset::parse(&result["panel"]).unwrap();
    assert_eq!(
        crate::momentum::evaluate(&request.spec, &panel).unwrap()["sessions_evaluated"],
        2
    );
    let encoded = result.to_string();
    assert!(!encoded.contains("test-key"));
    assert!(!encoded.contains("test-secret"));
    assert_eq!(
        result["panel_sha256"],
        hex::encode(Sha256::digest(
            serde_json::to_vec(&result["panel"]).unwrap()
        ))
    );
}
#[tokio::test]
async fn incomplete_duplicate_and_unexpected_data_never_make_a_panel() {
    let request = request();
    let mut missing = bars(&request);
    missing["bars"]["JPM"].as_array_mut().unwrap().pop();
    let mut duplicate = bars(&request);
    let first = duplicate["bars"]["JPM"][0].clone();
    duplicate["bars"]["JPM"].as_array_mut().unwrap().push(first);
    let mut unexpected = bars(&request);
    unexpected["bars"]["JPM"][0]["t"] = json!("2025-01-10T05:00:00Z");
    for (body, error) in [
        (missing, DownloadError::IncompleteCoverage),
        (duplicate, DownloadError::DuplicateObservation),
        (unexpected, DownloadError::UnexpectedObservation),
    ] {
        let (client, _, task) = mock(vec![(200, body, None)]).await;
        assert_eq!(client.download(&request).await.unwrap_err(), error);
        task.abort();
    }
}
#[tokio::test]
async fn retry_and_access_errors_are_bounded_and_do_not_echo_provider_bodies() {
    let request = request();
    let (client, state, task) = mock(vec![
        (429, json!({"message":"test-secret"}), Some("0".into())),
        (200, bars(&request), None),
    ])
    .await;
    client.download(&request).await.unwrap();
    assert_eq!(state.queries.lock().await.len(), 2);
    task.abort();
    for (code, error) in [
        (403, DownloadError::AccessDenied),
        (302, DownloadError::ProviderRejected),
        (200, DownloadError::ProviderRejected),
    ] {
        let (client, state, task) =
            mock(vec![(code, json!({"message":"test-secret"}), None)]).await;
        assert_eq!(client.download(&request).await.unwrap_err(), error);
        assert_eq!(state.queries.lock().await.len(), 1);
        task.abort();
    }
    let (client, state, task) = mock(vec![(429, json!({}), Some("3600".into()))]).await;
    assert_eq!(
        client.download(&request).await.unwrap_err(),
        DownloadError::RateLimited
    );
    assert_eq!(state.queries.lock().await.len(), 1);
    task.abort();
    let (client, state, task) = mock(vec![(429, json!({}), Some("0".into())); 4]).await;
    assert_eq!(
        client.download(&request).await.unwrap_err(),
        DownloadError::RateLimited
    );
    assert_eq!(state.queries.lock().await.len(), 4);
    task.abort();
}
#[tokio::test]
async fn cyclic_pages_and_oversized_responses_are_rejected() {
    let request = request();
    let page = json!({"bars":{},"next_page_token":"same"});
    let (client, _, task) = mock(vec![(200, page.clone(), None), (200, page, None)]).await;
    assert_eq!(
        client.download(&request).await.unwrap_err(),
        DownloadError::InvalidResponse
    );
    task.abort();
    let (client, _, task) = mock(vec![(200, json!({"padding":"x".repeat(MAX_BODY)}), None)]).await;
    assert_eq!(
        client.download(&request).await.unwrap_err(),
        DownloadError::ResourceLimit
    );
    task.abort();
}
#[test]
fn date_identity_and_precision_validation() {
    let mut request = request();
    let now = DateTime::parse_from_rfc3339("2025-02-01T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    request.validate(now).unwrap();
    request.symbols[0] = "JPM".into();
    assert_eq!(request.validate(now), Err(DownloadError::InvalidRequest));
    for (price, expected) in [("1.005", 101), ("0.005", 1), ("100.123456", 10012)] {
        assert_eq!(
            cents(&serde_json::from_str(price).unwrap()).unwrap(),
            expected
        );
    }
    for price in ["0", "-1", "0.004", "100.1234567", "10000001"] {
        assert!(cents(&serde_json::from_str(price).unwrap()).is_err());
    }
    let mut bar: ProviderBar = serde_json::from_value(
        json!({"t":"2025-07-01T04:00:00Z","o":10,"h":11,"l":9,"c":10,"v":100}),
    )
    .unwrap();
    assert_eq!(session(&bar).unwrap().to_string(), "2025-07-01");
    bar.t = "2025-07-01T05:00:00Z".into();
    assert_eq!(session(&bar), Err(DownloadError::InvalidResponse));
    bar.t = "2025-07-01T04:00:00Z".into();
    bar.h = serde_json::from_str("9").unwrap();
    assert_eq!(session(&bar), Err(DownloadError::InvalidPrice));
}
#[tokio::test]
async fn invalid_or_unfinished_request_makes_no_network_call() {
    let mut request = request();
    request.sessions[3] = Utc::now().with_timezone(&New_York).date_naive();
    let (client, state, task) = mock(vec![]).await;
    assert_eq!(
        client.download(&request).await.unwrap_err(),
        DownloadError::InvalidRequest
    );
    assert!(state.queries.lock().await.is_empty());
    task.abort();
}

#[tokio::test]
async fn raw_decimal_precision_is_checked_before_float_normalization() {
    for value in ["100.004999999999999", "10000000.0000000001"] {
        let wire = format!(
            r#"{{"bars":{{"AAPL":[{{"t":"2025-01-06T05:00:00Z","o":{value},"h":10000000,"l":90,"c":101,"v":100}}]}},"next_page_token":null}}"#
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new().route(
            "/v2/stocks/bars",
            get(move || {
                let wire = wire.clone();
                async move { wire }
            }),
        );
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let mut client = AlpacaDailyClient::new(Credentials {
            key_id: "test-key".into(),
            secret_key: "test-secret".into(),
        })
        .unwrap();
        client.endpoint = format!("http://{address}/v2/stocks/bars");
        client.pace = Duration::ZERO;
        assert_eq!(
            client.download(&request()).await.unwrap_err(),
            DownloadError::InvalidPrice
        );
        task.abort();
    }
}

#[tokio::test]
async fn saved_download_rejects_panel_tampering_and_extra_provenance() {
    let (client, _, task) = mock(vec![(200, bars(&request()), None)]).await;
    let envelope = client.download(&request()).await.unwrap();
    task.abort();
    validate_download(&serde_json::to_vec(&envelope).unwrap()).unwrap();
    let mut tampered = envelope.clone();
    tampered["panel"]["series"][0]["bars"][0]["open_cents"] = json!(1);
    assert!(validate_download(&serde_json::to_vec(&tampered).unwrap()).is_err());
    let mut tampered = envelope.clone();
    tampered["source_facts"]["extra"] = json!("untrusted");
    assert!(validate_download(&serde_json::to_vec(&tampered).unwrap()).is_err());
    let mut tampered = envelope;
    tampered["observations"][0]["bar"]["o"] = json!(999);
    assert!(validate_download(&serde_json::to_vec(&tampered).unwrap()).is_err());
}
