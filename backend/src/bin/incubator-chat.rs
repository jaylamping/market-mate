#[tokio::main]
async fn main() {
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8085")
        .await
        .expect("chat bind failed");
    axum::serve(listener, backend::incubator_chat::router())
        .await
        .expect("chat service stopped");
}
