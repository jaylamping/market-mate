use backend::cursor::{router, CursorReader};
use std::{path::PathBuf, sync::Arc};
#[tokio::main]
async fn main() {
    let reader = CursorReader::new(
        PathBuf::from("/var/lib/cursor/credentials.json"),
        PathBuf::from("/var/lib/model-policy/policy.json"),
    )
    .expect("Cursor HTTP client initialization failed");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8084")
        .await
        .expect("Cursor connector bind failed");
    axum::serve(listener, router(Arc::new(reader)))
        .await
        .expect("Cursor connector stopped");
}
