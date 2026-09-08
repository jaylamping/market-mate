//! HTTP surface of the agent driver. Workers dispatch here; the frontend reads and edits config here.
use super::dispatch::{database, sql_reason, DispatchRequest, Driver};
use super::log;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Instant};

type ApiError = (StatusCode, Json<Value>);
fn error(status: StatusCode, reason: &str) -> ApiError {
    (status, Json(json!({"error":reason})))
}
fn unavailable(reason: &str) -> ApiError {
    error(StatusCode::SERVICE_UNAVAILABLE, reason)
}
fn conflict(reason: &str) -> ApiError {
    error(StatusCode::CONFLICT, reason)
}
fn bad_request(reason: &str) -> ApiError {
    error(StatusCode::BAD_REQUEST, reason)
}
fn from_sql(e: tokio_postgres::Error) -> ApiError {
    if matches!(e.code(), Some(code) if code == &tokio_postgres::error::SqlState::INVALID_PARAMETER_VALUE || code == &tokio_postgres::error::SqlState::CHECK_VIOLATION)
    {
        return bad_request("invalid_configuration");
    }
    let reason = sql_reason(&e, "database_unavailable");
    if reason == "database_unavailable" {
        unavailable(reason)
    } else {
        conflict(reason)
    }
}
fn id_ok(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
async fn json_call(
    sql: &str,
    params: &[&(dyn tokio_postgres::types::ToSql + Sync)],
) -> Result<Value, ApiError> {
    let db = database().await.map_err(unavailable)?;
    db.client
        .query_one(sql, params)
        .await
        .map(|r| r.get(0))
        .map_err(from_sql)
}

async fn healthz() -> Json<Value> {
    Json(json!({"status":"ok","service":"agent-driver"}))
}

async fn dispatch(
    State(driver): State<Arc<Driver>>,
    Json(input): Json<DispatchRequest>,
) -> Result<Json<Value>, ApiError> {
    if input.key.is_empty()
        || input.key.len() > 200
        || !id_ok(&input.agent_id)
        || !id_ok(&input.purpose)
    {
        return Err(bad_request("invalid_dispatch_request"));
    }
    let db = database().await.map_err(unavailable)?;
    driver
        .admit(&db.client, &input)
        .await
        .map(Json)
        .map_err(|reason| match reason {
            "dispatch_key_conflict" | "invalid_dispatch_request" => conflict(reason),
            _ => unavailable(reason),
        })
}
async fn read_dispatch(Path(id): Path<String>) -> Result<Json<Value>, ApiError> {
    let value = json_call("SELECT read_dispatch($1)", &[&id]).await?;
    if value.is_null() {
        return Err(error(StatusCode::NOT_FOUND, "unknown_dispatch"));
    }
    Ok(Json(value))
}
async fn read_dispatch_by_key(
    Query(q): Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let key = q.get("key").ok_or_else(|| bad_request("key_required"))?;
    let value = json_call("SELECT read_dispatch_by_key($1)", &[key]).await?;
    if value.is_null() {
        return Err(error(StatusCode::NOT_FOUND, "unknown_dispatch"));
    }
    Ok(Json(value))
}
async fn send(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = database().await.map_err(unavailable)?;
    driver
        .send(&db.client, &id)
        .await
        .map(Json)
        .map_err(unavailable)
}
async fn stream(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let db = database().await.map_err(unavailable)?;
    let upstream = driver
        .stream(&db.client, &id)
        .await
        .map_err(|reason| match reason {
            "dispatch_permit_required" | "dispatch_send_window_expired" => conflict(reason),
            _ => unavailable(reason),
        })?;
    let status =
        StatusCode::from_u16(upstream.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut response = Response::builder().status(status);
    for name in [header::CONTENT_TYPE, header::RETRY_AFTER] {
        if let Some(value) = upstream.headers().get(&name) {
            response = response.header(name, value.clone());
        }
    }
    for name in [
        "x-ratelimit-reset",
        "x-ratelimit-remaining",
        "x-ratelimit-limit",
        "x-request-id",
    ] {
        if let Some(value) = upstream.headers().get(name) {
            response = response.header(name, value.clone());
        }
    }
    // reqwest is built without the `stream` feature; relay chunks through a channel instead.
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<axum::body::Bytes, std::io::Error>>(16);
    tokio::spawn(async move {
        let mut upstream = upstream;
        loop {
            match upstream.chunk().await {
                Ok(Some(chunk)) => {
                    if tx.send(Ok(chunk)).await.is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(_) => {
                    let _ = tx
                        .send(Err(std::io::Error::other("upstream_stream_failed")))
                        .await;
                    break;
                }
            }
        }
    });
    response
        .header(header::CACHE_CONTROL, HeaderValue::from_static("no-store"))
        .body(Body::from_stream(
            tokio_stream::wrappers::ReceiverStream::new(rx),
        ))
        .map_err(|_| unavailable("stream_unavailable"))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Outcome {
    state: String,
    #[serde(default)]
    detail: Value,
}
async fn outcome(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
    Json(input): Json<Outcome>,
) -> Result<Json<Value>, ApiError> {
    let db = database().await.map_err(unavailable)?;
    let detail = if input.detail.is_object() {
        input.detail
    } else {
        json!({})
    };
    driver
        .outcome(&db.client, &id, &input.state, detail)
        .await
        .map(Json)
        .map_err(|reason| match reason {
            "invalid_dispatch_outcome" => bad_request(reason),
            "dispatch_not_streaming" => conflict(reason),
            _ => unavailable(reason),
        })
}

async fn providers(State(driver): State<Arc<Driver>>) -> Result<Json<Value>, ApiError> {
    let db = database().await.map_err(unavailable)?;
    let rows = driver.providers(&db.client).await.map_err(unavailable)?;
    Ok(Json(
        json!({"providers":rows.iter().map(|p| p.to_json()).collect::<Vec<_>>()}),
    ))
}
#[derive(Deserialize)]
struct Revisioned {
    expected_revision: i64,
    #[serde(flatten)]
    patch: serde_json::Map<String, Value>,
}
async fn save_provider(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
    Json(input): Json<Revisioned>,
) -> Result<Json<Value>, ApiError> {
    if !id_ok(&id) {
        return Err(bad_request("unknown_provider"));
    }
    let patch = Value::Object(input.patch);
    let result = json_call(
        "SELECT save_provider($1,$2,$3)",
        &[&id, &input.expected_revision, &patch],
    )
    .await?;
    log::info(
        "config.provider.saved",
        json!({"provider":id,"status":result["status"],"revision":result["revision"],"patch":patch}),
    );
    if result["status"] == "conflict" {
        return Err(conflict("provider_revision_conflict"));
    }
    driver.forget_catalog(&id);
    Ok(Json(result))
}
async fn provider_models(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = database().await.map_err(unavailable)?;
    let provider = driver
        .provider(&db.client, &id)
        .await
        .map_err(|r| error(StatusCode::NOT_FOUND, r))?;
    let models = driver.catalog(&provider).await.map_err(unavailable)?;
    Ok(Json(
        json!({"provider":id,"catalog_source":provider.catalog_source,"models":models}),
    ))
}
async fn provider_status(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = database().await.map_err(unavailable)?;
    let provider = driver
        .provider(&db.client, &id)
        .await
        .map_err(|r| error(StatusCode::NOT_FOUND, r))?;
    if provider.usage_url.is_some() {
        let _ = super::quota::poll_provider(&db.client, &provider).await;
    } else {
        super::quota::probe_provider(&db.client, &provider).await;
    }
    let refreshed = driver
        .provider(&db.client, &id)
        .await
        .map_err(unavailable)?;
    Ok(Json(
        json!({"provider":refreshed.id,"state":refreshed.state["probe_state"].as_str().unwrap_or("unknown"),
        "checked_at":refreshed.state["probe_at"],"last_error":refreshed.state["last_error"],"credential_state":refreshed.credential_state(),
        "windows":refreshed.windows,"enabled":refreshed.enabled,"kind":refreshed.kind}),
    ))
}
async fn provider_usage(
    State(driver): State<Arc<Driver>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = database().await.map_err(unavailable)?;
    let provider = driver
        .provider(&db.client, &id)
        .await
        .map_err(|r| error(StatusCode::NOT_FOUND, r))?;
    let samples: Value = db
        .client
        .query_one(
            "SELECT coalesce(jsonb_agg(jsonb_build_object('window',window_name,'percent_used',percent_used,'status',status,'resets_at',resets_at,'observed_at',receipt_time) ORDER BY receipt_time DESC),'[]') FROM (SELECT * FROM provider_usage_sample WHERE provider_id=$1 ORDER BY receipt_time DESC LIMIT 200) s",
            &[&id],
        )
        .await
        .map(|r| r.get(0))
        .unwrap_or(json!([]));
    Ok(Json(
        json!({"provider":id,"windows":provider.windows,"samples":samples}),
    ))
}

async fn agents() -> Result<Json<Value>, ApiError> {
    let value = json_call("SELECT read_agents()", &[]).await?;
    Ok(Json(json!({"agents":value})))
}
async fn agent(Path(id): Path<String>) -> Result<Json<Value>, ApiError> {
    let value = json_call("SELECT read_agents()", &[]).await?;
    value
        .as_array()
        .and_then(|a| a.iter().find(|x| x["id"] == id.as_str()).cloned())
        .map(Json)
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "unknown_agent"))
}
async fn save_agent(
    Path(id): Path<String>,
    Json(input): Json<Revisioned>,
) -> Result<Json<Value>, ApiError> {
    if !id_ok(&id) {
        return Err(bad_request("invalid_agent_id"));
    }
    let patch = Value::Object(input.patch);
    if let Some(routes) = patch["routes"].as_array() {
        for route in routes {
            let model = route["model_id"].as_str().unwrap_or_default();
            let provider = route["provider_id"].as_str().unwrap_or_default();
            if model.is_empty() || model.len() > 256 || !id_ok(provider) {
                return Err(bad_request("invalid_agent_routes"));
            }
        }
    }
    let result = json_call(
        "SELECT save_agent($1,$2,$3,$4)",
        &[&id, &input.expected_revision, &patch, &"ui"],
    )
    .await?;
    log::info(
        "config.agent.saved",
        json!({"agent":id,"status":result["status"],"revision":result["revision"],"routes":patch["routes"].as_array().map(Vec::len),"enabled":patch["enabled"],"priority":patch["priority"],"hold_at_pct":patch["hold_at_pct"]}),
    );
    if result["status"] == "conflict" {
        return Err(conflict("agent_revision_conflict"));
    }
    Ok(Json(result))
}
async fn usage_summary() -> Result<Json<Value>, ApiError> {
    json_call("SELECT read_usage_summary()", &[])
        .await
        .map(Json)
}
async fn model_workspace() -> Result<Json<Value>, ApiError> {
    json_call("SELECT read_model_workspace()", &[])
        .await
        .map(Json)
}
async fn save_model(
    Query(q): Query<HashMap<String, String>>,
    Json(input): Json<Revisioned>,
) -> Result<Json<Value>, ApiError> {
    let id = q
        .get("id")
        .ok_or_else(|| bad_request("model_id_required"))?;
    let value = json_call(
        "SELECT save_model_policy($1,$2,$3)",
        &[id, &input.expected_revision, &Value::Object(input.patch)],
    )
    .await?;
    if value["status"] == "conflict" {
        return Err(conflict("model_revision_conflict"));
    }
    Ok(Json(value))
}
async fn save_fallbacks(Json(input): Json<Revisioned>) -> Result<Json<Value>, ApiError> {
    let models = input
        .patch
        .get("models")
        .ok_or_else(|| bad_request("models_required"))?;
    let value = json_call(
        "SELECT save_model_fallbacks($1,$2)",
        &[&input.expected_revision, models],
    )
    .await?;
    if value["status"] == "conflict" {
        return Err(conflict("fallback_revision_conflict"));
    }
    Ok(Json(value))
}
async fn model_requests(Query(q): Query<HashMap<String, String>>) -> Result<Json<Value>, ApiError> {
    let id = q
        .get("id")
        .ok_or_else(|| bad_request("model_id_required"))?;
    json_call("SELECT read_model_requests($1)", &[id])
        .await
        .map(Json)
}
async fn revisions(Query(q): Query<HashMap<String, String>>) -> Result<Json<Value>, ApiError> {
    let limit: i32 = q.get("limit").and_then(|l| l.parse().ok()).unwrap_or(50);
    let value = json_call("SELECT read_config_revisions($1)", &[&limit]).await?;
    Ok(Json(json!({"revisions":value})))
}

async fn access_log(request: Request<Body>, next: Next) -> Response {
    let started = Instant::now();
    let method = request.method().clone();
    let path = request.uri().path().to_string();
    let response = next.run(request).await;
    let status = response.status().as_u16();
    let level = if status >= 500 {
        "warn"
    } else if path == "/healthz" {
        "debug"
    } else {
        "info"
    };
    log::log(
        level,
        "http.request",
        json!({"method":method.as_str(),"path":path,"status":status,"latency_ms":log::elapsed_ms(started)}),
    );
    response
}
pub fn router(driver: Arc<Driver>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/dispatch", post(dispatch).get(read_dispatch_by_key))
        .route("/dispatch/{id}", get(read_dispatch))
        .route("/dispatch/{id}/send", post(send))
        .route("/dispatch/{id}/stream", post(stream))
        .route("/dispatch/{id}/outcome", post(outcome))
        .route("/providers", get(providers))
        .route("/providers/{id}", axum::routing::put(save_provider))
        .route("/providers/{id}/models", get(provider_models))
        .route("/providers/{id}/status", get(provider_status))
        .route("/providers/{id}/usage", get(provider_usage))
        .route("/agents", get(agents))
        .route("/models", get(model_workspace).put(save_model))
        .route("/models/fallbacks", axum::routing::put(save_fallbacks))
        .route("/models/requests", get(model_requests))
        .route("/agents/{id}", get(agent).put(save_agent))
        .route("/usage/summary", get(usage_summary))
        .route("/config/revisions", get(revisions))
        .with_state(driver)
        .merge(crate::openrouter_capacity::router())
        .layer(middleware::from_fn(access_log))
}
/// Background loops: usage polls (5 min, or immediately after a 429), probes (10 min), sweeps (30 s).
pub async fn run_background(driver: Arc<Driver>) {
    let mut probe_tick = 0_u32;
    loop {
        match database().await {
            Ok(db) => {
                if let Ok(providers) = driver.providers(&db.client).await {
                    for provider in providers.iter().filter(|p| p.enabled) {
                        if provider.usage_url.is_some() {
                            let _ = super::quota::poll_provider(&db.client, provider).await;
                        } else if probe_tick % 2 == 0 {
                            super::quota::probe_provider(&db.client, provider).await;
                        }
                    }
                }
                driver.sweep(&db.client).await;
            }
            Err(reason) => log::error("background.database_unavailable", json!({"reason":reason})),
        }
        probe_tick = probe_tick.wrapping_add(1);
        let mut waited = 0_u64;
        // Sweep every 30 s; leave the loop early for a usage re-poll after a rate limit.
        loop {
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(30)) => {
                    waited += 30;
                    if let Ok(db) = database().await { driver.sweep(&db.client).await; }
                    if waited >= 300 { break; }
                }
                _ = driver.repoll.notified() => {
                    log::info("quota.repoll.requested", json!({}));
                    break;
                }
            }
        }
    }
}
impl IntoResponse for super::adapter::Completion {
    fn into_response(self) -> Response {
        Json(json!({"state":self.state,"detail":self.detail})).into_response()
    }
}
