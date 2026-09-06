//! Read-only Alpaca Paper POC. This is not a ledger or a certified execution adapter.
use axum::{
    extract::State,
    http::{header, StatusCode},
    routing::get,
    Json, Router,
};
use reqwest::{
    header::{HeaderMap, HeaderValue},
    Client,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::Mutex;

const PAPER_ORIGIN: &str = "https://paper-api.alpaca.markets";
const MAX_BODY: usize = 2_000_000;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    key_id: String,
    secret_key: String,
}

impl Credentials {
    fn headers(&self) -> Result<HeaderMap, &'static str> {
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("APCA-API-KEY-ID", &self.key_id),
            ("APCA-API-SECRET-KEY", &self.secret_key),
        ] {
            if value.is_empty()
                || value.len() > 512
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
            {
                return Err("invalid_credentials");
            }
            let mut header = HeaderValue::from_str(value).map_err(|_| "invalid_credentials")?;
            header.set_sensitive(true);
            headers.insert(name, header);
        }
        Ok(headers)
    }
}

#[derive(Clone, Copy)]
enum Resource {
    Account,
    Positions,
    Orders,
    Activities,
}

impl Resource {
    fn path(self) -> &'static str {
        match self {
            Self::Account => "/v2/account",
            Self::Positions => "/v2/positions",
            Self::Orders => "/v2/orders?status=all&limit=50&direction=desc&nested=false",
            Self::Activities => "/v2/account/activities?page_size=50&direction=desc",
        }
    }
}

#[derive(Serialize, Deserialize)]
pub struct Account {
    pub status: String,
    pub currency: String,
    pub cash: String,
    pub equity: String,
    pub buying_power: String,
    pub trading_blocked: bool,
    pub account_blocked: bool,
}
#[derive(Serialize, Deserialize)]
pub struct Position {
    pub symbol: String,
    pub asset_class: String,
    pub side: String,
    pub qty: String,
    pub market_value: Option<String>,
    pub unrealized_pl: Option<String>,
}
#[derive(Serialize, Deserialize)]
pub struct Order {
    pub id: String,
    pub symbol: String,
    pub side: String,
    pub status: String,
    #[serde(rename = "type")]
    pub order_type: String,
    pub qty: Option<String>,
    pub notional: Option<String>,
    pub filled_qty: String,
    pub submitted_at: Option<String>,
}
#[derive(Serialize, Deserialize)]
pub struct Activity {
    pub id: String,
    pub activity_type: String,
    pub transaction_time: Option<String>,
    pub date: Option<String>,
    pub symbol: Option<String>,
    pub qty: Option<String>,
    pub price: Option<String>,
    pub net_amount: Option<String>,
}

#[derive(Serialize)]
struct Snapshot {
    provider: &'static str,
    environment: &'static str,
    access: &'static str,
    state: &'static str,
    fetched_at_ms: u64,
    account: Account,
    positions: Vec<Position>,
    orders: Vec<Order>,
    activities: Vec<Activity>,
    recent_limit: u32,
}

fn decimal(value: &str) -> bool {
    let unsigned = value.strip_prefix('-').unwrap_or(value);
    let mut parts = unsigned.split('.');
    let integer = parts.next().unwrap_or("");
    let fraction = parts.next();
    !integer.is_empty()
        && integer.bytes().all(|b| b.is_ascii_digit())
        && fraction.is_none_or(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
        && parts.next().is_none()
        && value.len() <= 128
}

fn normalize(
    account: Value,
    positions: Value,
    orders: Value,
    activities: Value,
) -> Result<Snapshot, &'static str> {
    let account: Account = serde_json::from_value(account).map_err(|_| "invalid_response")?;
    let positions: Vec<Position> =
        serde_json::from_value(positions).map_err(|_| "invalid_response")?;
    let orders: Vec<Order> = serde_json::from_value(orders).map_err(|_| "invalid_response")?;
    let activities: Vec<Activity> =
        serde_json::from_value(activities).map_err(|_| "invalid_response")?;
    let mut numbers = vec![
        account.cash.as_str(),
        account.equity.as_str(),
        account.buying_power.as_str(),
    ];
    for p in &positions {
        numbers.push(&p.qty);
        numbers.extend(p.market_value.as_deref());
        numbers.extend(p.unrealized_pl.as_deref());
    }
    for o in &orders {
        numbers.push(&o.filled_qty);
        numbers.extend(o.qty.as_deref());
        numbers.extend(o.notional.as_deref());
    }
    for a in &activities {
        numbers.extend(a.qty.as_deref());
        numbers.extend(a.price.as_deref());
        numbers.extend(a.net_amount.as_deref());
    }
    if !numbers.into_iter().all(decimal) || account.status.is_empty() || account.currency.len() != 3
    {
        return Err("invalid_response");
    }
    Ok(Snapshot {
        provider: "alpaca",
        environment: "paper",
        access: "read_only",
        state: "connected",
        fetched_at_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64,
        account,
        positions,
        orders,
        activities,
        recent_limit: 50,
    })
}

pub struct PaperReader {
    client: Client,
    credentials_path: PathBuf,
    // Serializes refreshes and briefly caches both success and failure to bound request volume.
    cache: Mutex<Option<(std::time::Instant, StatusCode, Value)>>,
}

impl PaperReader {
    pub fn new(credentials_path: PathBuf) -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: Client::builder()
                .https_only(true)
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(8))
                .build()?,
            credentials_path,
            cache: Mutex::new(None),
        })
    }

    async fn get(&self, resource: Resource, headers: &HeaderMap) -> Result<Value, &'static str> {
        let response = self
            .client
            .get(format!("{PAPER_ORIGIN}{}", resource.path()))
            .headers(headers.clone())
            .send()
            .await
            .map_err(|_| "connection_failed")?;
        let status = response.status().as_u16();
        if status != 200 {
            return Err(match status {
                401 | 403 => "credentials_rejected",
                429 => "rate_limited",
                _ => "provider_unavailable",
            });
        }
        let mut response = response;
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "connection_failed")? {
            if bytes.len() + chunk.len() > MAX_BODY {
                return Err("invalid_response");
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| "invalid_response")
    }

    async fn fetch(&self) -> Result<Snapshot, &'static str> {
        let bytes = std::fs::read(&self.credentials_path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                "not_configured"
            } else {
                "invalid_credentials"
            }
        })?;
        if bytes.len() > 2048 {
            return Err("invalid_credentials");
        }
        let credentials: Credentials =
            serde_json::from_slice(&bytes).map_err(|_| "invalid_credentials")?;
        let headers = credentials.headers()?;
        let (account, positions, orders, activities) = tokio::try_join!(
            self.get(Resource::Account, &headers),
            self.get(Resource::Positions, &headers),
            self.get(Resource::Orders, &headers),
            self.get(Resource::Activities, &headers),
        )?;
        normalize(account, positions, orders, activities)
    }
}

async fn snapshot(
    State(reader): State<Arc<PaperReader>>,
) -> (
    StatusCode,
    [(header::HeaderName, &'static str); 1],
    Json<Value>,
) {
    let mut cache = reader.cache.lock().await;
    if let Some((at, status, body)) = &*cache {
        if at.elapsed() < Duration::from_secs(5) {
            return (
                *status,
                [(header::CACHE_CONTROL, "no-store")],
                Json(body.clone()),
            );
        }
    }
    let (status, body) = match reader.fetch().await {
        Ok(data) => (
            StatusCode::OK,
            serde_json::to_value(data).expect("snapshot is serializable"),
        ),
        Err(code) => (
            if code == "not_configured" {
                StatusCode::OK
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            },
            json!({"provider":"alpaca", "environment":"paper", "access":"read_only", "state":code}),
        ),
    };
    *cache = Some((std::time::Instant::now(), status, body.clone()));
    (status, [(header::CACHE_CONTROL, "no-store")], Json(body))
}

pub fn router(reader: Arc<PaperReader>) -> Router {
    Router::new().route("/healthz", get(|| async { Json(json!({"status":"ok","service":"paper-connector","environment":"paper","access":"read_only"})) }))
        .route("/paper/account", get(snapshot)).with_state(reader)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account() -> Value {
        json!({"status":"ACTIVE","currency":"USD","cash":"1000.1234","equity":"990.1234","buying_power":"1000","trading_blocked":false,"account_blocked":false,"secret_extra":"must not escape"})
    }

    #[test]
    fn preserves_decimal_precision_and_omits_unrequested_fields() {
        let result = normalize(account(), json!([]), json!([]), json!([])).unwrap();
        let body = serde_json::to_value(result).unwrap();
        assert_eq!(body["account"]["cash"], "1000.1234");
        assert_eq!(body["environment"], "paper");
        assert_eq!(body["access"], "read_only");
        assert!(body["account"].get("secret_extra").is_none());
    }

    #[test]
    fn rejects_missing_account_flags_and_invalid_numbers() {
        let mut input = account();
        input.as_object_mut().unwrap().remove("trading_blocked");
        assert!(normalize(input, json!([]), json!([]), json!([])).is_err());
        for value in ["NaN", "Infinity", "", "1e3", "1.2.3"] {
            let mut input = account();
            input["cash"] = json!(value);
            assert!(normalize(input, json!([]), json!([]), json!([])).is_err());
        }
        assert!(normalize(account(), json!({}), json!([]), json!([])).is_err());
    }

    #[test]
    fn credentials_are_sensitive_and_cannot_inject_headers() {
        let headers = Credentials {
            key_id: "paper-test".into(),
            secret_key: "test-secret".into(),
        }
        .headers()
        .unwrap();
        assert!(headers["APCA-API-SECRET-KEY"].is_sensitive());
        assert!(Credentials {
            key_id: "bad\r\nheader".into(),
            secret_key: "test".into()
        }
        .headers()
        .is_err());
    }

    #[tokio::test]
    async fn missing_keys_are_explicit_and_write_routes_do_not_exist() {
        let reader = Arc::new(
            PaperReader::new(PathBuf::from("/nonexistent-paper-poc/credentials.json")).unwrap(),
        );
        assert!(matches!(reader.fetch().await, Err("not_configured")));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server =
            tokio::spawn(async move { axum::serve(listener, router(reader)).await.unwrap() });
        let client = Client::builder().no_proxy().build().unwrap();
        let base = format!("http://{address}");
        let response = client
            .get(format!("{base}/paper/account"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let body: Value = response.json().await.unwrap();
        assert_eq!(body["state"], "not_configured");
        assert!(body.get("account").is_none());
        assert_eq!(
            client
                .post(format!("{base}/paper/account"))
                .send()
                .await
                .unwrap()
                .status(),
            405
        );
        assert_eq!(
            client
                .post(format!("{base}/v2/orders"))
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
        server.abort();
    }
}
