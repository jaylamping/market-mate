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
fn authorization(key: &str) -> Result<HeaderValue, &'static str> {
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
    json!({"provider":"cursor","state":state,"model_policy":"whitelist","inference_enabled":false})
}
fn normalize(value: Value) -> Result<Value, &'static str> {
    if !value.get("apiKeyName").is_some_and(Value::is_string)
        || !value.get("createdAt").is_some_and(Value::is_string)
    {
        return Err("invalid_response");
    }
    let mut body = envelope("connected");
    body["checked_at_ms"] = json!(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64);
    Ok(body)
}
pub struct CursorReader {
    client: Client,
    path: PathBuf,
    cache: Mutex<Option<(Instant, Value)>>,
    policy_path: PathBuf,
    policy_lock: Mutex<()>,
    models_cache: Mutex<Option<(Instant, Vec<Model>, Vec<u8>)>>,
}
impl CursorReader {
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
            .get("https://api.cursor.com/v1/me")
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
    State(reader): State<Arc<CursorReader>>,
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
pub fn router(reader: Arc<CursorReader>) -> Router {
    Router::new()
        .route(
            "/healthz",
            get(|| async { Json(json!({"status":"ok","service":"cursor-connector"})) }),
        )
        .route("/cursor/status", get(status))
        .route("/cursor/models", get(models))
        .route("/cursor/policy", get(policy).put(save_policy))
        .with_state(reader)
}
#[derive(Clone, Serialize, Deserialize)]
struct Model {
    id: String,
    name: String,
}
fn catalog(value: Value) -> Result<Vec<Model>, &'static str> {
    let rows = value
        .get("items")
        .and_then(Value::as_array)
        .ok_or("invalid_catalog")?;
    let mut models = Vec::new();
    for row in rows {
        let id = row
            .get("id")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty() && v.len() <= 256)
            .ok_or("invalid_catalog")?;
        let name = row
            .get("displayName")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
            .ok_or("invalid_catalog")?;
        if ["auto", "auto-smart", "default"].contains(&id) {
            continue;
        }
        models.push(Model {
            id: id.into(),
            name: name.into(),
        });
    }
    models.sort_by(|a, b| a.id.cmp(&b.id));
    models.dedup_by(|a, b| a.id == b.id);
    Ok(models)
}
impl CursorReader {
    async fn models(&self) -> Result<Vec<Model>, &'static str> {
        let bytes = std::fs::read(&self.path).map_err(|_| "not_configured")?;
        if bytes.len() > 1024 {
            return Err("invalid_credentials");
        }
        let credentials: Credentials =
            serde_json::from_slice(&bytes).map_err(|_| "invalid_credentials")?;
        let credential_bytes = bytes.clone();
        let auth = authorization(&credentials.api_key)?;
        let mut cache = self.models_cache.lock().await;
        if let Some((at, models, key_bytes)) = &*cache {
            if *key_bytes == bytes && at.elapsed() < Duration::from_secs(300) {
                return Ok(models.clone());
            }
        }
        let mut response = self
            .client
            .get("https://api.cursor.com/v1/models")
            .header(header::AUTHORIZATION, auth)
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
        *cache = Some((Instant::now(), models.clone(), credential_bytes));
        Ok(models)
    }
}
#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Policy {
    revision: u64,
    allowed_models: Vec<String>,
}
fn read_policy(path: &std::path::Path) -> Result<Policy, &'static str> {
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
async fn models(State(reader): State<Arc<CursorReader>>) -> ApiReply {
    match reader.models().await {
        Ok(models) => reply(StatusCode::OK, json!({"models":models})),
        Err(code) => reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    }
}
async fn policy(State(reader): State<Arc<CursorReader>>) -> ApiReply {
    match crate::model_routing::stored(std::path::Path::new("/var/lib/routing-policy/routing.json"))
    {
        Ok(Some(policy)) => {
            return reply(
                StatusCode::OK,
                json!(crate::model_routing::provider_policy(&policy, "cursor")),
            )
        }
        Err(code) => return reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
        Ok(None) => {}
    }
    match read_policy(&reader.policy_path) {
        Ok(policy) => reply(StatusCode::OK, json!(policy)),
        Err(code) => reply(StatusCode::SERVICE_UNAVAILABLE, json!({"error":code})),
    }
}
async fn save_policy(
    State(reader): State<Arc<CursorReader>>,
    Json(requested): Json<Policy>,
) -> ApiReply {
    let _guard = reader.policy_lock.lock().await;
    if std::path::Path::new("/var/lib/routing-policy/routing.json").exists() {
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
mod tests {
    use super::*;
    #[test]
    fn validates_and_projects_cursor_metadata() {
        let body=normalize(json!({"apiKeyName":"private","createdAt":"2026-09-06","userEmail":"private@example.com"})).unwrap();
        assert_eq!(body["state"], "connected");
        assert!(!body.to_string().contains("private"));
        assert!(normalize(json!({"data":{"usage":0}})).is_err());
        assert!(authorization("bad\r\nheader").is_err());
        assert!(authorization("crsr_test-key").unwrap().is_sensitive());
        let models=catalog(json!({"items":[{"id":"composer-2","displayName":"Composer"},{"id":"auto","displayName":"Auto"}]})).unwrap();
        assert_eq!(models.len(), 1);
        assert!(catalog(json!({"items":[{"id":"broken"}]})).is_err());
        assert!(next_policy(
            &Policy::default(),
            Policy {
                revision: 0,
                allowed_models: vec!["unknown".into()]
            },
            &models
        )
        .is_err());
        assert!(next_policy(
            &Policy::default(),
            Policy {
                revision: 1,
                allowed_models: vec![]
            },
            &models
        )
        .is_err());
    }
    #[tokio::test]
    async fn routes_persist_policy_and_never_launch_agents() {
        let dir = std::env::temp_dir().join(format!(
            "cursor-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let reader =
            Arc::new(CursorReader::new(dir.join("key.json"), dir.join("policy.json")).unwrap());
        assert!(matches!(reader.check().await, Err("not_configured")));
        let credentials = br#"{"api_key":"synthetic-test"}"#.to_vec();
        std::fs::write(&reader.path, &credentials).unwrap();
        *reader.models_cache.lock().await = Some((
            Instant::now(),
            vec![Model {
                id: "composer-2".into(),
                name: "Composer".into(),
            }],
            credentials,
        ));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server =
            tokio::spawn(async move { axum::serve(listener, router(reader)).await.unwrap() });
        let client = Client::builder().no_proxy().build().unwrap();
        let url = format!("http://{address}/cursor/policy");
        let response = client
            .put(&url)
            .json(&json!({"revision":0,"allowed_models":["composer-2"]}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        assert_eq!(
            read_policy(&dir.join("policy.json"))
                .unwrap()
                .allowed_models,
            vec!["composer-2"]
        );
        assert_eq!(
            client
                .put(&url)
                .json(&json!({"revision":0,"allowed_models":[]}))
                .send()
                .await
                .unwrap()
                .status(),
            409
        );
        for route in ["/v1/agents", "/cursor/agents", "/chat/completions"] {
            assert_eq!(
                client
                    .post(format!("http://{address}{route}"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                404
            );
        }
        server.abort();
        std::fs::remove_dir_all(dir).unwrap();
    }
}
