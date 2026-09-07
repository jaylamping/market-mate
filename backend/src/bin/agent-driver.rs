use backend::driver::{api, bootstrap, dispatch, log};
use serde_json::json;

#[tokio::main]
async fn main() {
    let driver = dispatch::Driver::new();
    match dispatch::database().await {
        Ok(db) => match bootstrap::import_if_empty(&db.client).await {
            Ok(n) => log::info("bootstrap.completed", json!({"agents_imported":n})),
            Err(reason) => log::warn("bootstrap.failed", json!({"reason":reason})),
        },
        Err(reason) => log::error("startup.database_unavailable", json!({"reason":reason})),
    }
    tokio::spawn(api::run_background(driver.clone()));
    let bind = std::env::var("AGENT_DRIVER_BIND").unwrap_or_else(|_| "0.0.0.0:8083".into());
    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .expect("agent driver bind failed");
    log::info("startup.listening", json!({"bind":bind}));
    axum::serve(listener, api::router(driver))
        .await
        .expect("agent driver stopped");
}
