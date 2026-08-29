use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use backend::receipt::{
    is_lower_hex, sign_receipt, utc_checkpoint_time_now, validate_receipt_shape,
    verify_receipt_signature, CheckpointReceipt,
};
use ed25519_dalek::SigningKey;
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

const DEFAULT_PORT: u16 = 8081;
const RECEIPTS_FILE: &str = "receipts.jsonl";
const KEY_FILE: &str = "signing-key.json";

#[derive(Deserialize)]
struct SignRequest {
    chain_position: i64,
    chain_digest: String,
}

struct CustodyFileState {
    next_index: i64,
    max_chain_position: i64,
}

struct CustodyState {
    signing_key: SigningKey,
    receipts_path: PathBuf,
    inner: Mutex<CustodyFileState>,
}

#[derive(Serialize, Deserialize)]
struct KeyFile {
    algorithm: String,
    public_key: String,
    private_key: String,
}

fn load_or_create_key(data_dir: &Path) -> SigningKey {
    let key_path = data_dir.join(KEY_FILE);
    match fs::read_to_string(&key_path) {
        Ok(contents) => {
            let key_file: KeyFile = serde_json::from_str(&contents)
                .unwrap_or_else(|error| panic!("custody key file is corrupt: {error}"));
            if key_file.algorithm != "ed25519"
                || !is_lower_hex(&key_file.private_key, 32)
                || !is_lower_hex(&key_file.public_key, 32)
            {
                panic!("custody key file does not hold a valid ed25519 keypair");
            }
            let private_bytes: [u8; 32] = hex::decode(&key_file.private_key)
                .ok()
                .and_then(|bytes| bytes.try_into().ok())
                .expect("custody private key must decode to 32 bytes");
            let signing_key = SigningKey::from_bytes(&private_bytes);
            let public = hex::encode(signing_key.verifying_key().to_bytes());
            if public != key_file.public_key {
                panic!("custody key file public_key does not match its private_key");
            }
            signing_key
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let signing_key = SigningKey::generate(&mut OsRng);
            let key_file = KeyFile {
                algorithm: "ed25519".to_string(),
                public_key: hex::encode(signing_key.verifying_key().to_bytes()),
                private_key: hex::encode(signing_key.to_bytes()),
            };
            let serialized =
                serde_json::to_string_pretty(&key_file).expect("key file must serialize");

            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                let mut file = fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .mode(0o600)
                    .open(&key_path)
                    .unwrap_or_else(|err| {
                        panic!(
                            "custody could not create key file at {}: {err}",
                            key_path.display()
                        )
                    });
                file.write_all(serialized.as_bytes())
                    .and_then(|_| file.sync_all())
                    .unwrap_or_else(|err| {
                        panic!(
                            "custody could not write key file at {}: {err}",
                            key_path.display()
                        )
                    });
            }

            #[cfg(not(unix))]
            {
                fs::write(&key_path, serialized).unwrap_or_else(|err| {
                    panic!(
                        "custody could not write key file at {}: {err}",
                        key_path.display()
                    )
                });
            }

            signing_key
        }
        Err(error) => {
            panic!(
                "custody could not read signing key at {}: {error}",
                key_path.display()
            );
        }
    }
}

fn load_and_validate_receipts(
    receipts_path: &Path,
    expected_public_key: &str,
) -> (Vec<CheckpointReceipt>, i64, i64) {
    let contents = match fs::read_to_string(receipts_path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return (Vec::new(), 1, 0),
        Err(error) => panic!(
            "custody receipts file {} is unreadable: {error}",
            receipts_path.display()
        ),
    };

    let mut receipts = Vec::new();
    let mut next_index = 1i64;
    let mut max_chain_position = 0i64;

    for line in contents.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let receipt: CheckpointReceipt = serde_json::from_str(line).unwrap_or_else(|error| {
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
        if let Err(error) = verify_receipt_signature(&receipt) {
            panic!(
                "custody receipts file {} signature failed validation: {error}",
                receipts_path.display()
            );
        }
        if receipt.public_key != expected_public_key {
            panic!(
                "custody receipt {} public key {} does not match current custody key {}",
                receipt.checkpoint_index, receipt.public_key, expected_public_key
            );
        }
        if receipt.checkpoint_index != next_index {
            panic!(
                "custody receipts file is not a contiguous sequence: expected index {next_index}, found {}",
                receipt.checkpoint_index
            );
        }

        next_index += 1;
        max_chain_position = max_chain_position.max(receipt.chain_position);
        receipts.push(receipt);
    }

    (receipts, next_index, max_chain_position)
}

async fn healthz() -> &'static str {
    "ok"
}

async fn public_key(State(state): State<Arc<CustodyState>>) -> Json<serde_json::Value> {
    Json(json!({
        "algorithm": "ed25519",
        "public_key": hex::encode(state.signing_key.verifying_key().to_bytes()),
    }))
}

async fn receipts(State(state): State<Arc<CustodyState>>) -> Json<Vec<CheckpointReceipt>> {
    let _guard = state.inner.lock().expect("custody lock must not poison");
    let contents = fs::read_to_string(&state.receipts_path).unwrap_or_default();
    let receipts: Vec<CheckpointReceipt> = contents
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("stored receipts must parse"))
        .collect();
    Json(receipts)
}

async fn sign(
    State(state): State<Arc<CustodyState>>,
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

    let mut inner = state.inner.lock().expect("custody lock must not poison");
    if request.chain_position < inner.max_chain_position {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({
                "error": format!(
                    "chain_position {} is less than previously signed high-water mark {}",
                    request.chain_position, inner.max_chain_position
                )
            })),
        );
    }

    let checkpoint_index = inner.next_index;
    let checkpoint_time = utc_checkpoint_time_now();
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
    let record = format!("{line}\n");

    file.write_all(record.as_bytes())
        .and_then(|_| file.sync_all())
        .unwrap_or_else(|error| {
            panic!(
                "custody could not persist receipt {}: {error}",
                checkpoint_index
            )
        });

    // Advance durable index and high-water mark only after successful write and sync
    inner.next_index += 1;
    inner.max_chain_position = inner.max_chain_position.max(request.chain_position);

    (
        StatusCode::CREATED,
        Json(serde_json::to_value(receipt).unwrap()),
    )
}

#[tokio::main]
async fn main() {
    let data_dir = PathBuf::from(
        std::env::var("CUSTODY_DATA_DIR").unwrap_or_else(|_| "/var/lib/custody".to_string()),
    );
    fs::create_dir_all(&data_dir).unwrap_or_else(|error| {
        panic!(
            "custody data dir {} is unusable: {error}",
            data_dir.display()
        )
    });
    let receipts_path = data_dir.join(RECEIPTS_FILE);

    let signing_key = load_or_create_key(&data_dir);
    let public_key_hex = hex::encode(signing_key.verifying_key().to_bytes());
    let (_receipts, next_index, max_chain_position) =
        load_and_validate_receipts(&receipts_path, &public_key_hex);

    let port: u16 = std::env::var("CUSTODY_PORT")
        .ok()
        .and_then(|port| port.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let state = Arc::new(CustodyState {
        signing_key,
        receipts_path,
        inner: Mutex::new(CustodyFileState {
            next_index,
            max_chain_position,
        }),
    });

    eprintln!(
        "custody listening on 0.0.0.0:{port}; next index {next_index}, max position {max_chain_position}"
    );

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
        let formatted = utc_checkpoint_time_now();
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
        let public_key_hex = hex::encode(key.verifying_key().to_bytes());
        let receipts_path = dir.join(RECEIPTS_FILE);
        let first = sign_receipt(&key, 1, 3, "aa".repeat(32), utc_checkpoint_time_now());
        let second = sign_receipt(&key, 2, 4, "bb".repeat(32), utc_checkpoint_time_now());
        for receipt in [&first, &second] {
            let mut file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&receipts_path)
                .unwrap();
            let line = format!("{}\n", serde_json::to_string(receipt).unwrap());
            file.write_all(line.as_bytes()).unwrap();
        }
        let (_, next_index, max_pos) = load_and_validate_receipts(&receipts_path, &public_key_hex);
        assert_eq!(next_index, 3);
        assert_eq!(max_pos, 4);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn custody_fails_on_mismatched_receipt_key_at_boot() {
        let dir = std::env::temp_dir().join(format!("custody-test-key-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let key1 = SigningKey::generate(&mut OsRng);
        let key2 = SigningKey::generate(&mut OsRng);
        let public_key2_hex = hex::encode(key2.verifying_key().to_bytes());
        let receipts_path = dir.join(RECEIPTS_FILE);
        let first = sign_receipt(&key1, 1, 3, "aa".repeat(32), utc_checkpoint_time_now());
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&receipts_path)
            .unwrap();
        let line = format!("{}\n", serde_json::to_string(&first).unwrap());
        file.write_all(line.as_bytes()).unwrap();

        let result = std::panic::catch_unwind(|| {
            load_and_validate_receipts(&receipts_path, &public_key2_hex);
        });
        assert!(result.is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
