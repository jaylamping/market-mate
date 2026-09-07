use backend::market_data_connection::{router, worker, Connection};
use std::{path::PathBuf, sync::Arc};
#[tokio::main]
async fn main() {
    let s = Arc::new(
        Connection::new(PathBuf::from("/var/lib/market-data/credentials.json"))
            .with_existing_credentials(PathBuf::from("/var/lib/alpaca-paper/credentials.json")),
    );
    tokio::spawn(worker(s.clone()));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8087")
        .await
        .expect("market data bind failed");
    axum::serve(listener, router(s))
        .await
        .expect("market data service stopped");
}
