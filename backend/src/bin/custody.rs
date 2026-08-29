use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use backend::receipt::{
    is_lower_hex, sign_receipt, utc_checkpoint_time_now, validate_receipt_shape,
    CheckpointReceipt,
};
use ed25519_dalek::SigningKey;
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{fs, io::Write, path::PathBuf, sync::Mutex};

const DEFAULT_PORT: u16 = 8081;
const RECEIPTS_FILE: &str = "receipts.jsonl";
const KEY_FILE: &str = "signing-key.json";

#[derive(Deserialize)]
struct SignRequest {
    chain_position: i64,
    chain_digest: String,
}

struct CustodyState {
    signing_key: SigningKey,
    receipts_path: PathBuf,
    write_lock: Mutex<()>,
    next_index: Mutex<i64>,
}

#[derive(Serialize, Deserialize)]
struct KeyFile {
    algorithm: String,
    public_key: String,
    private_key: String,
}

fn checkpoint_time_now() -> String {
    utc_checkpoint_time_now()
}

fn load_or_create_key(data_dir: &PathBuf) -> SigningKey {
    let key_path = data_dir.join(KEY_FILE);
    if let Ok(contents) = fs::read_to_string(&key_path) {
        let key_file: KeyFile = serde_json::from_str(&contents)
            .unwrap_or_else(|error| panic!("custody key file is corrupt: {error}"));
        if key_file.algorithm != "ed25519"
            || !is_lower_hex(&key_file.private_key, 32)
            || !is_lower_hex(&key_file.public_key, 32)
        {
            panic!("custody key file does not hold a valid ed25519 keypair");
        }        let private_bytes: [u8; 32] = hex::decode(&key_file.private_key)
            .ok()
            .and_then(|bytes| bytes.try_into().ok())
            .expect("custody private key must decode to 32 bytes");
        let signing_key = SigningKey::from_bytes(&private_bytes);
        let public = hex::encode(signing_key.verifying_key().to_bytes());
        if public != key_file.public_key {
            panic!("custody key file public_key does not match its private_key");
        }
        return signing_key;
    }

    let signing_key = SigningKey::generate(&mut OsRng);
    let key_file = KeyFile {
        algorithm: "ed25519".to_string(),
        public_key: hex::encode(signing_key.verifying_key().to_bytes()),
        private_key: hex::encode(signing_key.to_bytes()),
    };
    let serialized = serde_json::to_string_pretty(&key_file).expect("key file must serialize");
    fs::write(&key_path, serialized).unwrap_or_else(|error| {
        panic!(
            "custody could not persist its signing key at {}: {error}",
            key_path.display()
        )
    });
    if cfg!(unix) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600))
            .expect("custody key file permissions must be enforced");
    }
    signing_key
}

fn load_next_index(receipts_path: &PathBuf) -> i64 {
    let contents = match fs::read_to_string(receipts_path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return 1,
        Err(error) => panic!(
            "custody receipts file {} is unreadable: {error}",
            receipts_path.display()
        ),
    };
    let mut next_index = 1i64;
    for line in contents.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let receipt: CheckpointReceipt = serde_json::from_str(line)
            .unwrap_or_else(|error| {
                panic!(
                    "custody receipts file {} is corrupt at line {line}: {error}",
                    receipts_path.display()
                )
            });
        if let Err(error) = validate_receipt_shape(&receipt) {
            panic!(
                "custody receipts file {} failed shape validation: {error}",
                receipts_path.display()
            );
        }
        if receipt.checkpoint_index != next_index {
            panic!(
                "custody receipts file is not a contiguous sequence: expected index {next_index}, found {}",
                receipt.checkpoint_index
            );
        }
        next_index += 1;
    }
    next_index
}

async fn healthz() -> &'static str {
    "ok"
}

async fn public_key(State(state): State<std::sync::Arc<CustodyState>>) -> Json<serde_json::Value> {
    Json(json!({
        "algorithm": "ed25519",
        "public_key": hex::encode(state.signing_key.verifying_key().to_bytes()),
    }))
}

async fn receipts(
    State(state): State<std::sync::Arc<CustodyState>>,
) -> Json<Vec<CheckpointReceipt>> {
    let _guard = state.write_lock.lock().expect("custody lock must not poison");
    let contents = fs::read_to_string(&state.receipts_path).unwrap_or_default();
    let receipts: Vec<CheckpointReceipt> = contents
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("stored receipts must parse"))
        .collect();
    Json(receipts)
}

async fn sign(
    State(state): State<std::sync::Arc<CustodyState>>,
    Json(request): Json<SignRequest>,
) -> (StatusCode, Json<serde_json::Value>) {
    if request.chain_position <= 0 {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error": "chain_position must be positive"})),
        );
    }
    if !is_lower_hex(&request.chain_digest, 32) {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error": "chain_digest must be 64 lowercase hex characters"})),
        );
    }

    let _guard = state.write_lock.lock().expect("custody lock must not poison");
    let checkpoint_index = {
        let mut next = state.next_index.lock().expect("custody lock must not poison");
        let index = *next;
        *next += 1;
        index
    };
    let checkpoint_time = checkpoint_time_now();
    let receipt = sign_receipt(
        &state.signing_key,
        checkpoint_index,
        request.chain_position,
        request.chain_digest,
        checkpoint_time,
    );
    if let Err(error) = validate_receipt_shape(&receipt) {
        panic!("custody refused to persist a malformed receipt: {error}");
    }

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&state.receipts_path)
        .unwrap_or_else(|error| {
            panic!(
                "custody could not open {}: {error}",
                state.receipts_path.display()
            )
        });
    let line = serde_json::to_string(&receipt).expect("receipt must serialize");
    file.write_all(line.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .and_then(|_| file.sync_all())
        .unwrap_or_else(|error| {
            panic!(
                "custody could not persist receipt {}: {error}",
                checkpoint_index
            )
        });

    (StatusCode::CREATED, Json(serde_json::to_value(receipt).unwrap()))
}

#[tokio::main]
async fn main() {
    let data_dir = PathBuf::from(
        std::env::var("CUSTODY_DATA_DIR").unwrap_or_else(|_| "/var/lib/custody".to_string()),
    );
    fs::create_dir_all(&data_dir)
        .unwrap_or_else(|error| panic!("custody data dir {} is unusable: {error}", data_dir.display()));
    let receipts_path = data_dir.join(RECEIPTS_FILE);

    let signing_key = load_or_create_key(&data_dir);
    let next_index = load_next_index(&receipts_path);

    let port: u16 = std::env::var("CUSTODY_PORT")
        .ok()
        .and_then(|port| port.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let state = std::sync::Arc::new(CustodyState {
        signing_key,
        receipts_path,
        write_lock: Mutex::new(()),
        next_index: Mutex::new(next_index),
    });

    eprintln!("custody listening on 0.0.0.0:{port}; next checkpoint index {next_index}");

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/public-key", get(public_key))
        .route("/receipts", get(receipts))
        .route("/sign", post(sign))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .expect("custody listener must bind");
    axum::serve(listener, app)
        .await
        .expect("custody server must run");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checkpoint_time_is_fixed_width() {
        let formatted = checkpoint_time_now();
        assert_eq!(formatted.len(), 27, "{formatted}");
        assert!(formatted.ends_with('Z'), "{formatted}");
        assert_eq!(&formatted[10..11], "T", "{formatted}");
        assert_eq!(&formatted[19..20], ".", "{formatted}");
    }

    #[test]
    fn sign_request_validation_rejects_bad_shapes() {
        assert!(!is_lower_hex("ABCD", 2));
        assert!(is_lower_hex("abcd", 2));
    }

    #[test]
    fn custody_signs_and_persists_a_sequence() {
        let dir = std::env::temp_dir().join(format!("custody-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let key = SigningKey::generate(&mut OsRng);
        let receipts_path = dir.join(RECEIPTS_FILE);
        let first = sign_receipt(&key, 1, 3, "aa".repeat(32), checkpoint_time_now());
        let second = sign_receipt(&key, 2, 4, "bb".repeat(32), checkpoint_time_now());
        for receipt in [&first, &second] {
            let mut file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&receipts_path)
                .unwrap();
            file.write_all(serde_json::to_string(receipt).unwrap().as_bytes())
                .unwrap();
            file.write_all(b"\n").unwrap();
        }
        assert_eq!(load_next_index(&receipts_path), 3);
        fs::remove_dir_all(&dir).unwrap();
    }
}
