//! Restart-safe, on-demand acquisition. Provider data remains local to this worker.
use crate::market_data::{AlpacaDailyClient, PanelRequest};
use axum::{extract::Path, http::StatusCode, routing::get, Json, Router};
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DataRequest {
    calendar: String,
    symbols: Vec<String>,
    start: NaiveDate,
    end: NaiveDate,
    benchmark: String,
    symbol_asof: NaiveDate,
    cash: String,
}

pub(crate) async fn tick(
    db: &tokio_postgres::Client,
    source: &str,
    provider: &AlpacaDailyClient,
) -> Result<bool, &'static str> {
    db.query_one(
        "SELECT queue_market_data_acquisitions($1::text::uuid)",
        &[&source],
    )
    .await
    .map_err(|_| "queue_unavailable")?;
    let job: Option<Value> = db
        .query_one(
            "SELECT claim_market_data_acquisition($1::text::uuid)",
            &[&source],
        )
        .await
        .map_err(|_| "claim_unavailable")?
        .get(0);
    let Some(job) = job else { return Ok(false) };
    let id = job["experiment_id"].as_i64().ok_or("invalid_job")?;
    let token = job["lease_token"].as_str().ok_or("invalid_job")?;
    let request: PanelRequest =
        serde_json::from_value(job["request"].clone()).map_err(|_| "invalid_job")?;
    let cache = db
        .query_one(
            "SELECT read_market_data_acquisition_cache($1,$2::text::uuid)",
            &[&id, &token],
        )
        .await;
    let outcome = match cache {
        Ok(row) => match tokio::time::timeout(
            Duration::from_secs(120),
            provider.acquire(&request, &row.get::<_, Value>(0)),
        )
        .await
        {
            Ok(Ok(bundle)) => {
                match db
                    .query_one(
                        "SELECT finish_market_data_acquisition($1,$2::text::uuid,$3)::text",
                        &[&id, &token, &bundle],
                    )
                    .await
                {
                    Ok(_) => return Ok(true),
                    Err(_) => "commit_rejected".to_string(),
                }
            }
            Ok(Err(error)) => error.to_string(),
            Err(_) => "download_timeout".to_string(),
        },
        Err(_) => "commit_rejected".to_string(),
    };
    db.query_one(
        "SELECT fail_market_data_acquisition($1,$2::text::uuid,$3)",
        &[&id, &token, &outcome],
    )
    .await
    .map_err(|_| "failure_record_unavailable")?;
    Ok(true)
}

/// LISTEN provides prompt handoff; periodic draining recovers missed notifications
/// and expired leases after process or database restarts.
pub async fn run(
    url: &str,
    source: &str,
    provider: &AlpacaDailyClient,
    once: bool,
) -> Result<(), &'static str> {
    let (db, mut connection) = tokio_postgres::connect(url, tokio_postgres::NoTls)
        .await
        .map_err(|_| "database_unavailable")?;
    let (tx, mut rx) = tokio::sync::mpsc::channel(1);
    let task = tokio::spawn(async move {
        while let Some(message) = std::future::poll_fn(|cx| connection.poll_message(cx)).await {
            match message {
                Ok(tokio_postgres::AsyncMessage::Notification(_)) => {
                    let _ = tx.try_send(());
                }
                Err(_) => break,
                _ => {}
            }
        }
    });
    struct Guard(tokio::task::JoinHandle<()>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let _guard = Guard(task);
    db.batch_execute("LISTEN incubator_experiment")
        .await
        .map_err(|_| "listener_unavailable")?;
    loop {
        if tick(&db, source, provider).await? && !once {
            continue;
        }
        if once {
            return Ok(());
        }
        tokio::select! {
            value = rx.recv() => if value.is_none() { return Err("listener_disconnected"); },
            _ = tokio::time::sleep(Duration::from_secs(30)) => {}
        }
    }
}

async fn status(Path(id): Path<i64>) -> Result<Json<Value>, StatusCode> {
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    let value: Option<Value> = db
        .client
        .query_one("SELECT read_market_data_acquisition($1)", &[&id])
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?
        .get(0);
    Ok(Json(value.unwrap_or(Value::Null)))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Control {
    action: String,
}
async fn control(
    Path(id): Path<i64>,
    Json(input): Json<Control>,
) -> Result<Json<Value>, StatusCode> {
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    db.client
        .query_one(
            "SELECT control_market_data_acquisition($1,$2)",
            &[&id, &input.action],
        )
        .await
        .map_err(|_| StatusCode::CONFLICT)?;
    Ok(Json(json!({"accepted":true})))
}
pub fn router() -> Router {
    Router::new().route("/workflow/{id}/acquisition", get(status).post(control))
}

#[cfg(test)]
mod tests;
