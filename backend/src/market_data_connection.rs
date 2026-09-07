//! Local-only market data setup. Secrets stay in the connector's private volume.
use crate::market_data::{AlpacaDailyClient, Credentials, PanelRequest};
use axum::{
    extract::{DefaultBodyLimit, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::Read, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::Mutex;
type Error = (StatusCode, Json<Value>);
fn error(code: &str) -> Error {
    (StatusCode::CONFLICT, Json(json!({"error":code})))
}
pub struct Connection {
    path: PathBuf,
    gate: Mutex<()>,
    state: Mutex<String>,
    #[cfg(test)]
    endpoint: Option<String>,
}
impl Connection {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            gate: Mutex::new(()),
            state: Mutex::new("not_configured".into()),
            #[cfg(test)]
            endpoint: None,
        }
    }
    fn client(&self, bytes: &[u8]) -> Result<AlpacaDailyClient, Error> {
        let c: Credentials =
            serde_json::from_slice(bytes).map_err(|_| error("invalid_credentials"))?;
        let c = AlpacaDailyClient::new(c).map_err(|_| error("invalid_credentials"))?;
        #[cfg(test)]
        let c = if let Some(endpoint) = &self.endpoint {
            c.test_endpoint(endpoint.clone())
        } else {
            c
        };
        Ok(c)
    }
    fn load(&self) -> Result<Vec<u8>, Error> {
        let f = std::fs::File::open(&self.path).map_err(|_| error("not_configured"))?;
        let meta = f.metadata().map_err(|_| error("invalid_credentials"))?;
        if !meta.is_file() {
            return Err(error("invalid_credentials"));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if meta.permissions().mode() & 0o077 != 0 {
                return Err(error("credentials_file_must_be_private"));
            }
        }
        let mut bytes = Vec::new();
        f.take(4097)
            .read_to_end(&mut bytes)
            .map_err(|_| error("invalid_credentials"))?;
        if bytes.len() > 4096 {
            return Err(error("invalid_credentials"));
        }
        Ok(bytes)
    }
}
async fn db() -> Result<crate::incubator_requests::Database, Error> {
    crate::incubator_requests::database().await
}
async fn status(State(s): State<Arc<Connection>>) -> Result<Json<Value>, Error> {
    let db = db().await?;
    let settings: Option<Value> = db
        .client
        .query_one("SELECT read_market_data_settings()", &[])
        .await
        .map_err(|_| error("database_unavailable"))?
        .get(0);
    let refresh: Value = db
        .client
        .query_one("SELECT read_market_data_refresh_status()", &[])
        .await
        .map_err(|_| error("database_unavailable"))?
        .get(0);
    Ok(Json(
        json!({"state":s.state.lock().await.clone(),"settings":settings,"refresh":refresh}),
    ))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Setup {
    key_id: String,
    secret_key: String,
    rights_confirmed: bool,
}
fn probe_request() -> PanelRequest {
    serde_json::from_value(json!({"schema_version":1,"symbols":["AAPL","XOM","JPM","NEE"],"sessions":["2026-01-05","2026-01-06","2026-01-07","2026-01-08"],"benchmark":"SPY","symbol_asof":"2026-01-08","cash":"zero_interest","spec":{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":0}})).unwrap()
}
async fn setup(
    State(s): State<Arc<Connection>>,
    Json(input): Json<Setup>,
) -> Result<Json<Value>, Error> {
    if !input.rights_confirmed {
        return Err(error("account_terms_review_required"));
    }
    let _gate = s.gate.lock().await;
    let bytes = serde_json::to_vec(&json!({"key_id":input.key_id,"secret_key":input.secret_key}))
        .map_err(|_| error("invalid_credentials"))?;
    let client = s.client(&bytes)?;
    tokio::time::timeout(Duration::from_secs(20), client.download(&probe_request()))
        .await
        .map_err(|_| error("connection_check_timeout"))?
        .map_err(|e| error(&e.to_string()))?;
    let parent = s
        .path
        .parent()
        .ok_or_else(|| error("credentials_unwritable"))?;
    std::fs::create_dir_all(parent).map_err(|_| error("credentials_unwritable"))?;
    let temp = parent.join(format!(".credentials-{:016x}", rand::random::<u64>()));
    let save = || -> Result<(), Error> {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut f = options
            .open(&temp)
            .map_err(|_| error("credentials_unwritable"))?;
        f.write_all(&bytes)
            .and_then(|_| f.sync_all())
            .map_err(|_| error("credentials_unwritable"))
    };
    if let Err(e) = save() {
        let _ = std::fs::remove_file(&temp);
        return Err(e);
    }
    let result = async {
        let db = db().await?;
        db.client
            .query_one(
                "SELECT setup_personal_market_data($1)::text",
                &[&input.rights_confirmed],
            )
            .await
            .map_err(|_| error("source_configuration_rejected"))?;
        std::fs::rename(&temp, &s.path).map_err(|_| error("credentials_unwritable"))?;
        *s.state.lock().await = "connected".into();
        Ok(Json(json!({"connected":true})))
    }
    .await;
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    enabled: bool,
    refresh_enabled: bool,
}
async fn settings(Json(v): Json<Settings>) -> Result<Json<Value>, Error> {
    db().await?
        .client
        .query_one(
            "SELECT change_market_data_settings($1,$2)",
            &[&v.enabled, &v.refresh_enabled],
        )
        .await
        .map_err(|_| error("settings_rejected"))?;
    Ok(Json(json!({"saved":true})))
}
pub fn router(s: Arc<Connection>) -> Router {
    Router::new()
        .route("/healthz", get(|| async { Json(json!({"status":"ok"})) }))
        .route("/status", get(status))
        .route("/setup", axum::routing::post(setup))
        .route("/settings", axum::routing::post(settings))
        .layer(DefaultBodyLimit::max(8192))
        .with_state(s)
}
pub async fn worker(s: Arc<Connection>) {
    loop {
        let result = work(&s).await;
        if let Err(code) = result {
            *s.state.lock().await = code.into();
        }
        tokio::time::sleep(Duration::from_secs(15)).await;
    }
}
async fn work(s: &Connection) -> Result<(), &'static str> {
    let _gate = s.gate.lock().await;
    let db = db().await.map_err(|_| "database_unavailable")?;
    db.client
        .query_one("SELECT run_market_data_housekeeping()", &[])
        .await
        .map_err(|_| "housekeeping_unavailable")?;
    let cfg: Option<Value> = db
        .client
        .query_one("SELECT read_market_data_settings()", &[])
        .await
        .map_err(|_| "database_unavailable")?
        .get(0);
    let Some(cfg) = cfg else {
        return Err("not_configured");
    };
    if cfg["available"] != true {
        return Err("source_unavailable");
    }
    if cfg["enabled"] != true {
        *s.state.lock().await = "paused".into();
        return Ok(());
    }
    let client = s
        .client(&s.load().map_err(|_| "invalid_credentials")?)
        .map_err(|_| "invalid_credentials")?;
    // A configured credential has passed setup; routine work does not add a probe request.
    *s.state.lock().await = "configured".into();
    let source = cfg["source_id"].as_str().ok_or("invalid_configuration")?;
    for _ in 0..8 {
        if !crate::market_data_acquisition::tick(&db.client, source, &client).await? {
            break;
        }
    }
    refresh(&db.client, &client).await?;
    Ok(())
}
pub(crate) async fn refresh(
    db: &tokio_postgres::Client,
    client: &AlpacaDailyClient,
) -> Result<(), &'static str> {
    db.query_one("SELECT queue_market_data_refreshes()", &[])
        .await
        .map_err(|_| "refresh_unavailable")?;
    let job: Option<Value> = db
        .query_one("SELECT claim_market_data_refresh()", &[])
        .await
        .map_err(|_| "refresh_unavailable")?
        .get(0);
    let Some(j) = job else { return Ok(()) };
    let id = j["experiment_id"].as_i64().ok_or("invalid_refresh")?;
    let end = j["session_end"].as_str().ok_or("invalid_refresh")?;
    let token = j["token"].as_str().ok_or("invalid_refresh")?;
    let request: PanelRequest =
        serde_json::from_value(j["request"].clone()).map_err(|_| "invalid_refresh")?;
    let outcome = tokio::time::timeout(Duration::from_secs(120), client.download(&request)).await;
    if let Ok(Ok(bundle)) = outcome {
        if db
            .query_one(
                "SELECT finish_market_data_refresh($1,$2::text::date,$3::text::uuid,$4)",
                &[&id, &end, &token, &bundle],
            )
            .await
            .is_ok()
        {
            return Ok(());
        }
    }
    db.query_one(
        "SELECT fail_market_data_refresh($1,$2::text::date,$3::text::uuid)",
        &[&id, &end, &token],
    )
    .await
    .map_err(|_| "refresh_unavailable")?;
    Ok(())
}

#[cfg(test)]
mod tests;
