#[tokio::main]
async fn main() {
    tokio::spawn(backend::incubator_requests::worker());
    tokio::spawn(backend::incubator_evaluation::worker());
    let listener = tokio::net::TcpListener::bind(
        std::env::var("INCUBATOR_REQUESTS_BIND").unwrap_or_else(|_| "0.0.0.0:8086".into()),
    )
    .await
    .expect("request service bind failed");
    axum::serve(listener, backend::incubator_requests::router())
        .await
        .expect("request service stopped");
}
