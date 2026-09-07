//! A finite agenda feeding the existing research workflow.
use crate::incubator_requests::{campaign_check, database, select_role_model, selected_role_model};
use axum::{
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;

type Error = (StatusCode, Json<Value>);
fn storage_error(e: tokio_postgres::Error) -> Error {
    let message = match e.as_db_error().map(|e| e.message()) {
        Some("campaign_changed_refresh") => "Campaign settings changed. Refresh and try again.",
        Some("campaign_backlog_full") => {
            "The backlog is full. Wait for a proposal to leave the queue."
        }
        Some("Only failed or cancelled checks can be retried.") => {
            "Only failed or cancelled checks can be retried."
        }
        Some("Reconcile the uncertain provider request before retrying.") => {
            "Reconcile the uncertain provider request before retrying."
        }
        Some("invalid_campaign_limits") => {
            "Choose 1–100 daily tickets and 1–20 unfinished tickets."
        }
        _ => "Campaign storage is unavailable.",
    };
    (StatusCode::CONFLICT, Json(json!({"error":message})))
}
async fn read() -> Result<Json<Value>, Error> {
    let db = database().await?;
    db.client
        .query_one("SELECT read_incubator_campaign()", &[])
        .await
        .map(|r| Json(r.get(0)))
        .map_err(storage_error)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    enabled: bool,
    daily_limit: i32,
    open_limit: i32,
    revision: i32,
    creator_model: String,
    backlog_limit: i32,
}
async fn save(Json(input): Json<Settings>) -> Result<Json<Value>, Error> {
    let db = database().await?;
    let creator = if !input.enabled {
        input.creator_model.clone()
    } else {
        select_role_model(&input.creator_model, "research", true)?
    };
    db.client
        .query_one(
            "SELECT set_incubator_campaign($1,$2,$3,$4,$5,$6)",
            &[
                &input.enabled,
                &input.daily_limit,
                &input.open_limit,
                &input.revision,
                &creator,
                &input.backlog_limit,
            ],
        )
        .await
        .map(|r| Json(r.get(0)))
        .map_err(storage_error)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Retry {
    ordinal: i32,
    revision: i32,
}
async fn retry(Json(input): Json<Retry>) -> Result<Json<Value>, Error> {
    let db = database().await?;
    db.client
        .query_one(
            "SELECT retry_incubator_campaign($1,$2)",
            &[&input.ordinal, &input.revision],
        )
        .await
        .map(|r| Json(r.get(0)))
        .map_err(storage_error)
}
pub fn router() -> Router {
    Router::new()
        .route("/campaign", get(read).post(save))
        .route("/campaign/retry", post(retry))
}
async fn tick() -> Result<(), String> {
    let db = database().await.map_err(|_| "database_unavailable")?;
    let locked: bool = db
        .client
        .query_one("SELECT pg_try_advisory_lock(60001)", &[])
        .await
        .map_err(|e| e.to_string())?
        .get(0);
    if !locked {
        return Ok(());
    }
    let campaign: Value = db
        .client
        .query_one("SELECT read_incubator_campaign()", &[])
        .await
        .map_err(|e| e.to_string())?
        .get(0);
    let creator = campaign["creator_model"].as_str().unwrap_or_default();
    let model = if creator.is_empty() {
        selected_role_model("", "research").unwrap_or_default()
    } else {
        select_role_model(creator, "research", true).unwrap_or_default()
    };
    let mut first_error = None;
    loop {
        let candidate: Option<Value> = db
            .client
            .query_one("SELECT claim_incubator_campaign($1)", &[&model])
            .await
            .map_err(|e| e.to_string())?
            .get(0);
        let Some(candidate) = candidate else {
            break;
        };
        if let Err(reason) = campaign_check(&db, &candidate).await {
            first_error = Some(reason);
        }
        let ordinal = candidate["ordinal"]
            .as_i64()
            .ok_or("invalid_campaign_candidate")? as i32;
        if let Err(reason) = db
            .client
            .query_one("SELECT finish_incubator_campaign($1)", &[&ordinal])
            .await
            .map_err(|e| e.to_string())
        {
            first_error = Some(reason);
        }
    }
    match first_error {
        Some(reason) => Err(reason),
        None => Ok(()),
    }
}
pub async fn worker() {
    loop {
        if let Err(reason) = tick().await {
            eprintln!("Research campaign: {reason}");
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}
