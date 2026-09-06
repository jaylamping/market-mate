use backend::paper::{router, PaperReader};
use std::{path::PathBuf, sync::Arc};

#[tokio::main]
async fn main() {
    let reader = PaperReader::new(PathBuf::from("/var/lib/alpaca-paper/credentials.json"))
        .expect("paper HTTP client initialization failed");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8082")
        .await
        .expect("paper connector bind failed");
    axum::serve(listener, router(Arc::new(reader)))
        .await
        .expect("paper connector stopped");
}
