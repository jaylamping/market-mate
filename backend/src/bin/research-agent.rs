#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if !(2..=3).contains(&args.len()) {
        eprintln!("usage: research-agent RUN_KEY [APPROVED_MODEL_ID]");
        std::process::exit(2);
    }
    match backend::incubator::run(&args[1], args.get(2).map(String::as_str).unwrap_or("")).await {
        Ok(run) => {
            println!(
                "{}",
                serde_json::json!({"run_key":run["run_key"],"state":run["state"],"detail":run["detail"]})
            );
            if run["state"] != "completed" {
                std::process::exit(1);
            }
        }
        Err(reason) => {
            eprintln!("{}", serde_json::json!({"error":reason}));
            std::process::exit(1);
        }
    }
}
