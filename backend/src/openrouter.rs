//! Credential validation only. Model inference is deliberately not exposed.
use axum::{
    extract::State,
    http::{header, StatusCode},
    routing::get,
    Json, Router,
};
use reqwest::{header::HeaderValue, Client};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::Mutex;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    api_key: String,
}
pub(crate) fn authorization(key: &str) -> Result<HeaderValue, &'static str> {
    if key.is_empty()
        || key.len() > 512
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err("invalid_credentials");
    }
    let mut value =
        HeaderValue::from_str(&format!("Bearer {key}")).map_err(|_| "invalid_credentials")?;
    value.set_sensitive(true);
    Ok(value)
}
fn envelope(state: &str) -> Value {
    json!({"provider":"openrouter","state":state,"model_policy":"whitelist","inference_enabled":false})
}
fn normalize(value: Value) -> Result<Value, &'static str> {
    let data = value.get("data").ok_or("invalid_response")?;
    let free = data
        .get("is_free_tier")
        .and_then(Value::as_bool)
        .ok_or("invalid_response")?;
    let usage = data
        .get("usage")
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite() && *v >= 0.0)
        .ok_or("invalid_response")?;
    let mut body = envelope("connected");
    body["is_free_tier"] = json!(free);
    body["key_usage_credits"] = json!(usage);
    body["checked_at_ms"] = json!(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64);
    Ok(body)
}
pub struct OpenRouterReader {
    client: Client,
    path: PathBuf,
    cache: Mutex<Option<(Instant, Value)>>,
    balance_cache: Mutex<Option<(Instant, Value)>>,
    policy_path: PathBuf,
    policy_lock: Mutex<()>,
    models_cache: Mutex<Option<(Instant, Vec<Model>)>>,
}
impl OpenRouterReader {
    pub fn new(path: PathBuf, policy_path: PathBuf) -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: Client::builder()
                .https_only(true)
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(8))
                .build()?,
            path,
            policy_path,
            balance_cache: Mutex::new(None),
            policy_lock: Mutex::new(()),
            models_cache: Mutex::new(None),
            cache: Mutex::new(None),
        })
    }
    async fn check(&self) -> Result<Value, &'static str> {
        let bytes = std::fs::read(&self.path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "not_configured"
            } else {
                "invalid_credentials"
            }
        })?;
        if bytes.len() > 1024 {
            return Err("invalid_credentials");
        }
        let credentials: Credentials =
            serde_json::from_slice(&bytes).map_err(|_| "invalid_credentials")?;
        let mut response = self
            .client
            .get("https://openrouter.ai/api/v1/key")
            .header(header::AUTHORIZATION, authorization(&credentials.api_key)?)
            .send()
            .await
            .map_err(|_| "connection_failed")?;
        match response.status().as_u16() {
            200 => (),
            401 | 403 => return Err("credentials_rejected"),
            429 => return Err("rate_limited"),
            _ => return Err("provider_unavailable"),
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "connection_failed")? {
            if bytes.len() + chunk.len() > 64_000 {
                return Err("invalid_response");
            }
            bytes.extend_from_slice(&chunk);
        }
        normalize(serde_json::from_slice(&bytes).map_err(|_| "invalid_response")?)
    }
}
async fn status(
    State(reader): State<Arc<OpenRouterReader>>,
) -> ([(header::HeaderName, &'static str); 1], Json<Value>) {
    let mut cache = reader.cache.lock().await;
    if let Some((at, body)) = &*cache {
        let ttl = if body["state"] == "rate_limited" {
            60
        } else {
            5
        };
        if at.elapsed() < Duration::from_secs(ttl) {
            return ([(header::CACHE_CONTROL, "no-store")], Json(body.clone()));
        }
    }
    let body = reader.check().await.unwrap_or_else(envelope);
    *cache = Some((Instant::now(), body.clone()));
    ([(header::CACHE_CONTROL, "no-store")], Json(body))
}
pub fn router(reader: Arc<OpenRouterReader>) -> Router {
    Router::new()
        .route(
            "/healthz",
            get(|| async { Json(json!({"status":"ok","service":"openrouter-connector"})) }),
        )
        .route("/openrouter/status", get(status))
        .route("/openrouter/balance", get(balance))
        .route("/openrouter/models", get(models))
        .route("/openrouter/policy", get(policy).put(save_policy))
        .route("/openrouter/routing", get(routing).put(save_routing))
        .with_state(reader)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn projects_only_safe_fields_and_rejects_invalid_metadata() {
        let body = normalize(json!({"data":{"is_free_tier":true,"usage":0,"label":"private-key-name","secret":"private"}})).unwrap();
        assert_eq!(body["state"], "connected");
        assert_eq!(body["model_policy"], "whitelist");
        assert!(!body.to_string().contains("private"));
        assert!(normalize(json!({"data":{"is_free_tier":"true","usage":0}})).is_err());
        assert!(normalize(json!({"data":{"is_free_tier":true,"usage":-1}})).is_err());
        assert!(authorization("bad\r\nheader").is_err());
        assert!(authorization("test-key").unwrap().is_sensitive());
    }
    #[tokio::test]
    async fn setup_state_is_truthful_and_generation_routes_do_not_exist() {
        let reader = Arc::new(
            OpenRouterReader::new(
                PathBuf::from("/nonexistent-openrouter/credentials.json"),
                PathBuf::from("/nonexistent-openrouter/policy.json"),
            )
            .unwrap(),
        );
        assert!(matches!(reader.check().await, Err("not_configured")));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server =
            tokio::spawn(async move { axum::serve(listener, router(reader)).await.unwrap() });
        let client = Client::builder().no_proxy().build().unwrap();
        let response = client
            .get(format!("http://{address}/openrouter/status"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let body: Value = response.json().await.unwrap();
        assert_eq!(body["state"], "not_configured");
        assert_eq!(body["inference_enabled"], false);
        for path in [
            "/chat/completions",
            "/api/v1/chat/completions",
            "/openrouter/generate",
        ] {
            assert_eq!(
                client
                    .post(format!("http://{address}{path}"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                404
            );
        }
        assert_eq!(
            client
                .post(format!("http://{address}/openrouter/status"))
                .send()
                .await
                .unwrap()
                .status(),
            405
        );
        server.abort();
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Model {
    #[serde(flatten)]
    pub(crate) capabilities: crate::openrouter_request::Capabilities,
    pub(crate) id: String,
    name: String,
    context_length: u64,
    #[serde(default)]
    created: Option<u64>,
    pub(crate) pricing: std::collections::BTreeMap<String, Value>,
}
fn catalog(value: Value) -> Result<Vec<Model>, &'static str> {
    let rows = value
        .get("data")
        .and_then(Value::as_array)
        .ok_or("invalid_catalog")?;
    let mut result = Vec::new();
    for row in rows {
        // Routers can select an unapproved model, so only concrete model IDs are selectable.
        let model: Model = match serde_json::from_value(row.clone()) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if model.id.starts_with("openrouter/")
            || model.id.is_empty()
            || model.id.len() > 256
            || model.context_length == 0
        {
            continue;
        }
        let valid = ["prompt", "completion"].iter().all(|key| {
            model
                .pricing
                .get(*key)
                .and_then(Value::as_str)
                .and_then(|v| v.parse::<f64>().ok())
                .is_some_and(|v| v.is_finite() && v >= 0.0)
        });
        if valid {
            result.push(model);
        }
    }
    if result.is_empty() {
        return Err("invalid_catalog");
    }
    result.sort_by(|a, b| a.id.cmp(&b.id));
    result.dedup_by(|a, b| a.id == b.id);
    Ok(result)
}
impl OpenRouterReader {
    pub(crate) async fn models(&self) -> Result<Vec<Model>, &'static str> {
        let mut cache = self.models_cache.lock().await;
        if let Some((at, models)) = &*cache {
            if at.elapsed() < Duration::from_secs(300) {
                return Ok(models.clone());
            }
        }
        let mut response = self
            .client
            .get("https://openrouter.ai/api/v1/models")
            .send()
            .await
            .map_err(|_| "catalog_unavailable")?;
        if !response.status().is_success() {
            return Err("catalog_unavailable");
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "catalog_unavailable")? {
            if bytes.len() + chunk.len() > 10_000_000 {
                return Err("invalid_catalog");
            }
            bytes.extend_from_slice(&chunk);
        }
        let models = catalog(serde_json::from_slice(&bytes).map_err(|_| "invalid_catalog")?)?;
        *cache = Some((Instant::now(), models.clone()));
        Ok(models)
    }
}
#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    pub(crate) revision: u64,
    pub(crate) allowed_models: Vec<String>,
}
pub(crate) fn read_policy(path: &std::path::Path) -> Result<Policy, &'static str> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| "policy_unavailable"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Policy::default()),
        Err(_) => Err("policy_unavailable"),
    }
}
fn next_policy(
    current: &Policy,
    mut requested: Policy,
    models: &[Model],
) -> Result<Policy, (StatusCode, &'static str)> {
    if requested.revision != current.revision {
        return Err((StatusCode::CONFLICT, "policy_conflict"));
    }
    if requested.allowed_models.len() > 100
        || requested
            .allowed_models
            .iter()
            .any(|id| !models.iter().any(|m| &m.id == id) && !current.allowed_models.contains(id))
    {
        return Err((StatusCode::BAD_REQUEST, "invalid_model_selection"));
    }
    requested.allowed_models.sort();
    requested.allowed_models.dedup();
    requested.revision = current
        .revision
        .checked_add(1)
        .ok_or((StatusCode::CONFLICT, "policy_conflict"))?;
    Ok(requested)
}
type ApiReply = (
    StatusCode,
    [(header::HeaderName, &'static str); 1],
    Json<Value>,
);
fn reply(status: StatusCode, value: Value) -> ApiReply {
    (status, [(header::CACHE_CONTROL, "no-store")], Json(value))
}
async fn models(State(reader): State<Arc<OpenRouterReader>>) -> ApiReply {
    match reader.models().await {
        Ok(models) => reply(StatusCode::OK, json!({"models":models})),
        Err(code) => reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    }
}
async fn policy(State(reader): State<Arc<OpenRouterReader>>) -> ApiReply {
    match effective_policy(&reader.policy_path) {
        Ok(policy) => reply(StatusCode::OK, json!(policy)),
        Err(code) => reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    }
}
async fn save_policy(
    State(reader): State<Arc<OpenRouterReader>>,
    Json(requested): Json<Policy>,
) -> ApiReply {
    let _guard = reader.policy_lock.lock().await;
    if reader.policy_path.with_file_name("routing.json").exists() {
        return reply(
            StatusCode::CONFLICT,
            json!({"error":"use_model_preferences"}),
        );
    }
    let current = match read_policy(&reader.policy_path) {
        Ok(value) => value,
        Err(code) => return reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    };
    let models = match reader.models().await {
        Ok(value) => value,
        Err(code) => return reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    };
    let next = match next_policy(&current, requested, &models) {
        Ok(value) => value,
        Err((status, code)) => return reply(status, json!({"error":code})),
    };
    let temp = reader.policy_path.with_extension("json.new");
    let saved = std::fs::write(
        &temp,
        serde_json::to_vec(&next).expect("policy serializable"),
    )
    .and_then(|_| std::fs::rename(&temp, &reader.policy_path));
    if saved.is_err() {
        return reply(
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error":"policy_save_failed"}),
        );
    }
    reply(StatusCode::OK, json!(next))
}

#[cfg(test)]
mod policy_tests {
    use super::*;
    #[test]
    fn tiered_pricing_preserves_models_and_nested_cost_metadata() {
        let pricing = json!({"prompt":"0.0000002","completion":"0.0000012",
            "overrides":[{"min_prompt_tokens":272000,"prompt":"0.0000004"}]});
        let models = catalog(json!({"data":[{"id":"openai/gpt-5.6-luna",
            "name":"GPT-5.6 Luna","context_length":1050000,"pricing":pricing}]}))
        .unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(json!(models[0].pricing), pricing);
    }
    #[test]
    fn whitelist_allows_paid_and_free_but_rejects_unknown_and_stale_writes() {
        let models = catalog(json!({"data":[
            {"id":"vendor/free:free","name":"Free","context_length":1000,"pricing":{"prompt":"0","completion":"0"}},
            {"id":"vendor/paid","name":"Paid","context_length":1000,"pricing":{"prompt":"0.01","completion":"0.02"}},
            {"id":"openrouter/auto","name":"Router","context_length":1000,"pricing":{"prompt":"0","completion":"0"}}
        ]})).unwrap();
        assert_eq!(models.len(), 2);
        let current = Policy::default();
        let next = next_policy(
            &current,
            Policy {
                revision: 0,
                allowed_models: vec!["vendor/paid".into(), "vendor/free:free".into()],
            },
            &models,
        )
        .unwrap_or_else(|_| panic!("concrete models should be allowed"));
        assert_eq!(next.allowed_models.len(), 2);
        assert_eq!(next.revision, 1);
        assert!(matches!(
            next_policy(&next, Policy::default(), &models),
            Err((StatusCode::CONFLICT, _))
        ));
        assert!(next_policy(
            &current,
            Policy {
                revision: 0,
                allowed_models: vec!["unapproved/unknown".into()]
            },
            &models
        )
        .is_err());
        assert!(next_policy(
            &current,
            Policy {
                revision: 0,
                allowed_models: vec!["openrouter/auto".into()]
            },
            &models
        )
        .is_err());
        let dir = std::env::temp_dir().join(format!("mm-model-policy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("policy.json");
        std::fs::write(&path, serde_json::to_vec(&next).unwrap()).unwrap();
        assert_eq!(
            read_policy(&path).unwrap().allowed_models,
            next.allowed_models
        );
        std::fs::write(&path, b"broken").unwrap();
        assert!(read_policy(&path).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]
mod route_tests {
    use super::*;
    #[tokio::test]
    async fn save_route_persists_and_rejects_conflicting_revision() {
        let dir = std::env::temp_dir().join(format!("mm-model-route-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("policy.json");
        let reader =
            Arc::new(OpenRouterReader::new(dir.join("credentials.json"), path.clone()).unwrap());
        let models=catalog(json!({"data":[{"id":"vendor/model","name":"Paid","context_length":1000,"pricing":{"prompt":"0.01","completion":"0.02"}}]})).unwrap();
        *reader.models_cache.lock().await = Some((Instant::now(), models));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server =
            tokio::spawn(async move { axum::serve(listener, router(reader)).await.unwrap() });
        let client = Client::builder().no_proxy().build().unwrap();
        let url = format!("http://{address}/openrouter/policy");
        let update = json!({"revision":0,"allowed_models":["vendor/model"]});
        assert_eq!(
            client
                .put(&url)
                .json(&update)
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        assert_eq!(
            read_policy(&path).unwrap().allowed_models,
            vec!["vendor/model"]
        );
        assert_eq!(
            client
                .put(&url)
                .json(&update)
                .send()
                .await
                .unwrap()
                .status(),
            409
        );
        let invalid = json!({"revision":1,"allowed_models":["unknown/model"]});
        assert_eq!(
            client
                .put(&url)
                .json(&invalid)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
        assert_eq!(read_policy(&path).unwrap().revision, 1);
        assert_eq!(
            client
                .put(&url)
                .json(&json!({"revision":1,"allowed_models":[]}))
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        assert!(read_policy(&path).unwrap().allowed_models.is_empty());
        server.abort();
        std::fs::remove_dir_all(dir).unwrap();
    }
}

fn normalize_balance(value: Value) -> Result<Value, &'static str> {
    let data = value.get("data").ok_or("invalid_response")?;
    let credits = data
        .get("total_credits")
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite() && *v >= 0.0)
        .ok_or("invalid_response")?;
    let usage = data
        .get("total_usage")
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite() && *v >= 0.0)
        .ok_or("invalid_response")?;
    let remaining = credits - usage;
    if !remaining.is_finite() {
        return Err("invalid_response");
    }
    Ok(
        json!({"state":"available","balance_usd":remaining,"checked_at_ms":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64}),
    )
}
impl OpenRouterReader {
    async fn balance(&self) -> Result<Value, &'static str> {
        let path = self.path.with_file_name("management.json");
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                std::fs::read(&self.path).map_err(|_| "not_configured")?
            }
            Err(_) => return Err("invalid_credentials"),
        };
        if bytes.len() > 1024 {
            return Err("invalid_credentials");
        }
        let credentials: Credentials =
            serde_json::from_slice(&bytes).map_err(|_| "invalid_credentials")?;
        let mut response = self
            .client
            .get("https://openrouter.ai/api/v1/credits")
            .header(header::AUTHORIZATION, authorization(&credentials.api_key)?)
            .send()
            .await
            .map_err(|_| "unavailable")?;
        match response.status().as_u16() {
            200 => (),
            401 | 403 => return Err("management_key_required"),
            429 => return Err("rate_limited"),
            _ => return Err("unavailable"),
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "unavailable")? {
            if bytes.len() + chunk.len() > 64_000 {
                return Err("invalid_response");
            }
            bytes.extend_from_slice(&chunk);
        }
        normalize_balance(serde_json::from_slice(&bytes).map_err(|_| "invalid_response")?)
    }
}
async fn balance(
    State(reader): State<Arc<OpenRouterReader>>,
) -> ([(header::HeaderName, &'static str); 1], Json<Value>) {
    let mut cache = reader.balance_cache.lock().await;
    if let Some((at, body)) = &*cache {
        if at.elapsed() < Duration::from_secs(60) {
            return ([(header::CACHE_CONTROL, "no-store")], Json(body.clone()));
        }
    }
    let body = reader
        .balance()
        .await
        .unwrap_or_else(|state| json!({"state":state}));
    *cache = Some((Instant::now(), body.clone()));
    ([(header::CACHE_CONTROL, "no-store")], Json(body))
}
#[cfg(test)]
mod balance_tests {
    use super::*;
    #[test]
    fn balance_uses_account_totals_and_preserves_zero_and_negative() {
        assert_eq!(
            normalize_balance(json!({"data":{"total_credits":100.5,"total_usage":25.75}})).unwrap()
                ["balance_usd"],
            74.75
        );
        assert_eq!(
            normalize_balance(json!({"data":{"total_credits":0,"total_usage":0}})).unwrap()
                ["balance_usd"],
            0.0
        );
        assert_eq!(
            normalize_balance(json!({"data":{"total_credits":1,"total_usage":2}})).unwrap()
                ["balance_usd"],
            -1.0
        );
        assert!(normalize_balance(json!({"data":{"usage":0,"limit_remaining":100}})).is_err());
        assert!(
            normalize_balance(json!({"data":{"total_credits":100,"total_usage":null}})).is_err()
        );
    }
}

pub(crate) fn effective_policy(path: &std::path::Path) -> Result<Policy, &'static str> {
    match crate::model_routing::stored(&path.with_file_name("routing.json"))? {
        Some(policy) => Ok(crate::model_routing::provider_policy(&policy, "openrouter")),
        None => read_policy(path),
    }
}
async fn routing(State(reader): State<Arc<OpenRouterReader>>) -> ApiReply {
    match crate::model_routing::read(
        &reader.policy_path.with_file_name("routing.json"),
        &reader.policy_path,
        std::path::Path::new("/var/lib/cursor-policy/policy.json"),
    ) {
        Ok(policy) => reply(StatusCode::OK, json!(policy)),
        Err(code) => reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    }
}
async fn save_routing(
    State(reader): State<Arc<OpenRouterReader>>,
    Json(requested): Json<crate::model_routing::RoutingPolicy>,
) -> ApiReply {
    let _guard = reader.policy_lock.lock().await;
    let path = reader.policy_path.with_file_name("routing.json");
    let current = match crate::model_routing::read(
        &path,
        &reader.policy_path,
        std::path::Path::new("/var/lib/cursor-policy/policy.json"),
    ) {
        Ok(p) => p,
        Err(code) => return reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    };
    let (or_models, cursor_models) = tokio::join!(reader.models(), routing_cursor_models());
    let mut available: Vec<crate::model_routing::Route> = or_models
        .unwrap_or_default()
        .into_iter()
        .map(|m| crate::model_routing::Route {
            provider: "openrouter".into(),
            model_id: m.id,
        })
        .collect();
    available.extend(cursor_models.unwrap_or_default());
    let latest = match crate::model_routing::read(
        &path,
        &reader.policy_path,
        std::path::Path::new("/var/lib/cursor-policy/policy.json"),
    ) {
        Ok(p) => p,
        Err(code) => return reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    };
    if latest != current {
        return reply(
            StatusCode::CONFLICT,
            json!({"error":"routing_policy_conflict"}),
        );
    }
    let next = match crate::model_routing::validate(&current, requested, &available) {
        Ok(p) => p,
        Err(code) => {
            return reply(
                if code == "routing_policy_conflict" {
                    StatusCode::CONFLICT
                } else {
                    StatusCode::BAD_REQUEST
                },
                json!({"error":code}),
            )
        }
    };
    match crate::model_routing::write(&path, &next) {
        Ok(()) => reply(StatusCode::OK, json!(next)),
        Err(code) => reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    }
}

async fn routing_cursor_models() -> Result<Vec<crate::model_routing::Route>, ()> {
    let client = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(9))
        .build()
        .map_err(|_| ())?;
    let mut response = client
        .get("http://cursor-connector:8084/cursor/models")
        .send()
        .await
        .map_err(|_| ())?;
    if !response.status().is_success() {
        return Err(());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| ())? {
        if bytes.len() + chunk.len() > 1_000_000 {
            return Err(());
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| ())?;
    Ok(value["models"]
        .as_array()
        .ok_or(())?
        .iter()
        .filter_map(|m| m["id"].as_str())
        .map(|id| crate::model_routing::Route {
            provider: "cursor".into(),
            model_id: id.into(),
        })
        .collect())
}
