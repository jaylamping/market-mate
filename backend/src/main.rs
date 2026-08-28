use axum::{http::StatusCode, routing::get, Json, Router};
use std::time::Duration;
use tokio::time::timeout;
use tokio_postgres::NoTls;

const DATABASE_READINESS_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(serde::Serialize)]
struct Health {
    status: &'static str,
    service: &'static str,
    environment: &'static str,
}

async fn healthz() -> Json<Health> {
    Json(Health {
        status: "ok",
        service: "backend",
        environment: "local-research",
    })
}

#[derive(serde::Serialize)]
struct Readiness {
    status: &'static str,
    service: &'static str,
    database: bool,
}

/// Readiness requires PostgreSQL to authenticate and answer a trivial query.
async fn readyz() -> (StatusCode, Json<Readiness>) {
    let database = database_is_ready().await;
    let status = if database { "ok" } else { "unavailable" };
    let code = if database {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        code,
        Json(Readiness {
            status,
            service: "backend",
            database,
        }),
    )
}

async fn database_is_ready() -> bool {
    let Ok(database_url) = std::env::var("DATABASE_URL") else {
        return false;
    };

    let readiness = async {
        let (client, connection) = tokio_postgres::connect(&database_url, NoTls).await?;
        tokio::spawn(async move {
            if let Err(error) = connection.await {
                eprintln!("PostgreSQL readiness connection failed: {error}");
            }
        });
        client.simple_query("SELECT 1").await?;
        Ok::<(), tokio_postgres::Error>(())
    };

    matches!(
        timeout(DATABASE_READINESS_TIMEOUT, readiness).await,
        Ok(Ok(()))
    )
}

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080")
        .await
        .expect("backend listener must bind");
    axum::serve(listener, app)
        .await
        .expect("backend server must run");
}
