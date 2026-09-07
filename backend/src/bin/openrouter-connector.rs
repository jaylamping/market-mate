use backend::openrouter::{router, OpenRouterReader};
use std::{path::PathBuf, sync::Arc};
#[tokio::main]
async fn main() {
    let reader = OpenRouterReader::new(
        PathBuf::from("/var/lib/openrouter/credentials.json"),
        PathBuf::from("/var/lib/model-policy/policy.json"),
    )
    .expect("OpenRouter HTTP client initialization failed");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8083")
        .await
        .expect("OpenRouter connector bind failed");
    axum::serve(listener, router(Arc::new(reader)))
        .await
        .expect("OpenRouter connector stopped");
}
