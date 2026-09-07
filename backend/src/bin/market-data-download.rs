use backend::market_data::{AlpacaDailyClient, Credentials, PanelRequest};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
};

fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>, &'static str> {
    let mut data = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| "input_unreadable")?
        .take(limit + 1)
        .read_to_end(&mut data)
        .map_err(|_| "input_unreadable")?;
    if data.len() as u64 > limit {
        return Err("input_too_large");
    }
    Ok(data)
}

fn save_new(path: &Path, bytes: &[u8]) -> Result<(), &'static str> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let temp = parent.join(format!(".market-data-{:016x}.tmp", rand::random::<u64>()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temp).map_err(|_| "output_unwritable")?;
    let result = (|| {
        file.write_all(bytes).map_err(|_| "output_write_failed")?;
        file.sync_all().map_err(|_| "output_write_failed")?;
        fs::hard_link(&temp, path).map_err(|_| "output_exists_or_unwritable")?;
        Ok(())
    })();
    drop(file);
    let _ = fs::remove_file(temp);
    result
}

async fn run() -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 1 && args[0] == "--help" {
        println!("Usage: market-data-download REQUEST.json OUTPUT.json\nSet MARKET_DATA_CREDENTIALS_FILE to a private JSON file containing key_id and secret_key.\nDownloads a validated local panel; does not register or attach an experiment. Existing output is never overwritten.");
        return Ok(());
    }
    if args.len() != 2 {
        return Err("expected_request_and_output_paths; use --help".into());
    }
    let output = Path::new(&args[1]);
    if output.try_exists().map_err(|_| "output_unreadable")? {
        return Err("output_exists".into());
    }
    let request: PanelRequest = serde_json::from_slice(&read_bounded(Path::new(&args[0]), 32_000)?)
        .map_err(|_| "invalid_request_json")?;
    let secret = std::env::var_os("MARKET_DATA_CREDENTIALS_FILE")
        .ok_or("credentials_file_not_configured")?;
    let secret_path = Path::new(&secret);
    let metadata = fs::metadata(secret_path).map_err(|_| "credentials_unreadable")?;
    if !metadata.is_file() {
        return Err("credentials_must_be_regular_file".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err("credentials_file_must_be_private".into());
        }
    }
    let credentials: Credentials = serde_json::from_slice(&read_bounded(secret_path, 4096)?)
        .map_err(|_| "invalid_credentials_json")?;
    let client = AlpacaDailyClient::new(credentials).map_err(|e| e.to_string())?;
    let result = client.download(&request).await.map_err(|e| e.to_string())?;
    let mut bytes = serde_json::to_vec_pretty(&result).map_err(|_| "output_encoding_failed")?;
    bytes.push(b'\n');
    save_new(output, &bytes)?;
    println!("download_saved; registration_pending");
    Ok(())
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("market_data_download_failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn output_is_private_and_never_overwritten() {
        let directory =
            std::env::temp_dir().join(format!("market-data-write-{}", rand::random::<u64>()));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("panel.json");
        save_new(&path, b"original").unwrap();
        assert!(save_new(&path, b"replacement").is_err());
        assert_eq!(fs::read(&path).unwrap(), b"original");
        assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
