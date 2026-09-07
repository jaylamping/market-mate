use backend::market_data::{AlpacaDailyClient, Credentials};
use std::{io::Read, time::Duration};

async fn run() -> Result<(), &'static str> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--help"] {
        println!("Usage: market-data-acquire [--once]\nSet MARKET_DATA_DATABASE_URL, MARKET_DATA_SOURCE_ID and MARKET_DATA_CREDENTIALS_FILE. Runs on-demand acquisition for explicit waiting Setup requests. No scheduler, source certification or trading endpoints.");
        return Ok(());
    }
    if !args.is_empty() && args != ["--once"] {
        return Err("invalid_arguments");
    }
    let url = std::env::var("MARKET_DATA_DATABASE_URL").map_err(|_| "database_not_configured")?;
    let source = std::env::var("MARKET_DATA_SOURCE_ID").map_err(|_| "source_not_configured")?;
    let path =
        std::env::var_os("MARKET_DATA_CREDENTIALS_FILE").ok_or("credentials_not_configured")?;
    let file = std::fs::File::open(path).map_err(|_| "credentials_unreadable")?;
    let metadata = file.metadata().map_err(|_| "credentials_unreadable")?;
    if !metadata.is_file() {
        return Err("credentials_must_be_regular_file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err("credentials_file_must_be_private");
        }
    }
    let mut bytes = Vec::new();
    file.take(4097)
        .read_to_end(&mut bytes)
        .map_err(|_| "credentials_unreadable")?;
    if bytes.len() > 4096 {
        return Err("credentials_too_large");
    }
    let credentials: Credentials =
        serde_json::from_slice(&bytes).map_err(|_| "invalid_credentials")?;
    let provider = AlpacaDailyClient::new(credentials).map_err(|_| "invalid_credentials")?;
    loop {
        let result =
            backend::market_data_acquisition::run(&url, &source, &provider, !args.is_empty()).await;
        if !args.is_empty() {
            return result;
        }
        if let Err(code) = result {
            eprintln!("market_data_acquisition: {code}");
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}
#[tokio::main]
async fn main() {
    if let Err(code) = run().await {
        eprintln!("market_data_acquisition: {code}");
        std::process::exit(1);
    }
}
