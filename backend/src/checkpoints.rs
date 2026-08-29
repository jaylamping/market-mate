use crate::receipt::{
    chain_digest, parse_checkpoint_time, validate_receipt_shape, verify_receipt_signature,
    CheckpointReceipt,
};
use http_body_util::{BodyExt, Full};
use hyper::{body::Bytes, header::CONTENT_TYPE, http::uri::Uri, Method, Request};
use hyper_util::{
    client::legacy::{connect::HttpConnector, Client as HttpClient},
    rt::TokioExecutor,
};
use serde::Serialize;
use std::time::Duration;
use tokio::time::timeout;
use tokio_postgres::Client;

const CUSTODY_HTTP_TIMEOUT: Duration = Duration::from_secs(5);
type HttpJsonClient = HttpClient<HttpConnector, Full<Bytes>>;

#[derive(Clone)]
pub struct CustodyClient {
    base_url: String,
    http: std::sync::Arc<HttpJsonClient>,
}

impl CustodyClient {
    pub fn new(base_url: String) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            http: std::sync::Arc::new(HttpClient::builder(TokioExecutor::new()).build_http()),
        }
    }

    async fn request_json(
        &self,
        method: Method,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, String> {
        let uri: Uri = format!("{}{}", self.base_url, path)
            .parse()
            .map_err(|error| format!("custody URL is invalid: {error}"))?;
        let mut builder = Request::builder().method(method).uri(uri);
        if body.is_some() {
            builder = builder.header(CONTENT_TYPE, "application/json");
        }
        let request = builder
            .body(Full::new(Bytes::from(
                body.map(|value| value.to_string()).unwrap_or_default(),
            )))
            .map_err(|error| format!("custody request could not be built: {error}"))?;

        let response = match timeout(CUSTODY_HTTP_TIMEOUT, self.http.request(request)).await {
            Ok(Ok(response)) => response,
            Ok(Err(error)) => return Err(format!("custody request failed: {error}")),
            Err(_) => return Err("custody request timed out".to_string()),
        };

        if !response.status().is_success() {
            return Err(format!(
                "custody responded with status {}",
                response.status()
            ));
        }

        let bytes_future = response.into_body().collect();
        let bytes = match timeout(CUSTODY_HTTP_TIMEOUT, bytes_future).await {
            Ok(Ok(collected)) => collected.to_bytes(),
            Ok(Err(error)) => return Err(format!("custody response body failed: {error}")),
            Err(_) => return Err("custody response body timed out".to_string()),
        };

        serde_json::from_slice(&bytes)
            .map_err(|error| format!("custody response body was invalid JSON: {error}"))
    }

    pub async fn public_key(&self) -> Result<String, String> {
        let body = self.request_json(Method::GET, "/public-key", None).await?;
        body.get("public_key")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| "custody public-key response lacked public_key".to_string())
    }

    pub async fn receipts(&self) -> Result<Vec<CheckpointReceipt>, String> {
        let body = self.request_json(Method::GET, "/receipts", None).await?;
        serde_json::from_value(body)
            .map_err(|error| format!("custody receipts body was invalid: {error}"))
    }

    pub async fn sign(
        &self,
        chain_position: i64,
        chain_digest: &str,
    ) -> Result<CheckpointReceipt, String> {
        let body = self
            .request_json(
                Method::POST,
                "/sign",
                Some(serde_json::json!({
                    "chain_position": chain_position,
                    "chain_digest": chain_digest,
                })),
            )
            .await?;
        serde_json::from_value(body)
            .map_err(|error| format!("custody sign response was invalid: {error}"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RestoreFailure {
    pub checkpoint_index: Option<i64>,
    pub reason: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RestoreVerification {
    pub pending: bool,
    pub valid: bool,
    pub verified_at: Option<String>,
    pub custody_public_key: Option<String>,
    pub receipts_checked: i64,
    pub chain_valid: bool,
    pub chain_checked_events: i64,
    pub head_position: Option<i64>,
    pub first_failure: Option<RestoreFailure>,
}

impl RestoreVerification {
    pub fn pending() -> Self {
        Self {
            pending: true,
            valid: false,
            verified_at: None,
            custody_public_key: None,
            receipts_checked: 0,
            chain_valid: false,
            chain_checked_events: 0,
            head_position: None,
            first_failure: None,
        }
    }

    fn failed(reason: &str, detail: String) -> Self {
        Self {
            pending: false,
            valid: false,
            verified_at: None,
            custody_public_key: None,
            receipts_checked: 0,
            chain_valid: false,
            chain_checked_events: 0,
            head_position: None,
            first_failure: Some(RestoreFailure {
                checkpoint_index: None,
                reason: reason.to_string(),
                detail,
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditCheckpointRow {
    pub checkpoint_index: i64,
    pub chain_position: i64,
    pub chain_digest: String,
    pub checkpoint_time: String,
    pub signature: String,
}

pub fn verify_single_receipt_logic(
    receipt: &CheckpointReceipt,
    expected_index: i64,
    custody_public_key: &str,
    event_hash_at_pos: Option<&str>,
    mirror_row: Option<&AuditCheckpointRow>,
) -> Result<Option<AuditCheckpointRow>, (String, String)> {
    if receipt.checkpoint_index != expected_index {
        return Err((
            "checkpoint_index_sequence".to_string(),
            format!(
                "receipt index {} does not match expected {}",
                receipt.checkpoint_index, expected_index
            ),
        ));
    }

    if let Err(error) = verify_receipt_signature(receipt) {
        return Err(("signature_invalid".to_string(), error));
    }

    if receipt.public_key != custody_public_key {
        return Err((
            "custody_key_mismatch".to_string(),
            "receipt was signed by a key other than current custody key".to_string(),
        ));
    }

    let Some(head_hash) = event_hash_at_pos else {
        return Err((
            "chain_position_missing".to_string(),
            format!(
                "chain position {} is absent from the database",
                receipt.chain_position
            ),
        ));
    };

    let expected_digest = chain_digest(receipt.chain_position, head_hash);
    if expected_digest != receipt.chain_digest {
        return Err((
            "chain_digest_mismatch".to_string(),
            format!(
                "receipt binds digest {} but chain position {} now hashes to {expected_digest}",
                receipt.chain_digest, receipt.chain_position
            ),
        ));
    }

    match mirror_row {
        Some(mirror) => {
            if mirror.signature != receipt.signature
                || mirror.chain_position != receipt.chain_position
                || mirror.chain_digest != receipt.chain_digest
                || mirror.checkpoint_time != receipt.checkpoint_time
            {
                return Err((
                    "mirror_mismatch".to_string(),
                    format!(
                        "audit_checkpoint row {} diverges from custody receipt",
                        receipt.checkpoint_index
                    ),
                ));
            }
            Ok(None)
        }
        None => {
            // Receipt is valid and verified against the chain, but DB mirror row was lost/dropped:
            // return row to backfill/reconcile.
            Ok(Some(AuditCheckpointRow {
                checkpoint_index: receipt.checkpoint_index,
                chain_position: receipt.chain_position,
                chain_digest: receipt.chain_digest.clone(),
                checkpoint_time: receipt.checkpoint_time.clone(),
                signature: receipt.signature.clone(),
            }))
        }
    }
}

pub async fn chain_state(client: &Client) -> Result<(bool, i64, Option<i64>), String> {
    let row = client
        .query_one(
            "SELECT row_to_json(r) FROM verify_audit_event_chain() AS r",
            &[],
        )
        .await
        .map_err(|error| format!("chain verification query failed: {error}"))?;
    let state: serde_json::Value = row.get(0);
    let chain_valid = state
        .get("valid")
        .and_then(serde_json::Value::as_bool)
        .ok_or_else(|| "chain verification lacked valid".to_string())?;
    let chain_checked_events = state
        .get("checked_events")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| "chain verification lacked checked_events".to_string())?;
    let head_position = client
        .query_one("SELECT max(chain_position) FROM audit_event", &[])
        .await
        .map_err(|error| format!("chain head query failed: {error}"))?
        .get(0);
    Ok((chain_valid, chain_checked_events, head_position))
}

fn failure(
    checkpoint_index: Option<i64>,
    reason: &str,
    detail: String,
    base: &RestoreVerification,
) -> RestoreVerification {
    RestoreVerification {
        pending: false,
        valid: false,
        verified_at: base.verified_at.clone(),
        custody_public_key: base.custody_public_key.clone(),
        receipts_checked: base.receipts_checked,
        chain_valid: base.chain_valid,
        chain_checked_events: base.chain_checked_events,
        head_position: base.head_position,
        first_failure: Some(RestoreFailure {
            checkpoint_index,
            reason: reason.to_string(),
            detail,
        }),
    }
}

pub async fn run_restore_verification(
    client: &Client,
    custody: &CustodyClient,
) -> RestoreVerification {
    let custody_public_key = match custody.public_key().await {
        Ok(public_key) => public_key,
        Err(error) => return RestoreVerification::failed("custody_unavailable", error),
    };
    let receipts = match custody.receipts().await {
        Ok(receipts) => receipts,
        Err(error) => {
            return RestoreVerification::failed("custody_unavailable", error);
        }
    };

    let (chain_valid, chain_checked_events, head_position) = match chain_state(client).await {
        Ok(state) => state,
        Err(error) => return RestoreVerification::failed("chain_unreadable", error),
    };

    let mut base = RestoreVerification {
        pending: false,
        valid: false,
        verified_at: None,
        custody_public_key: Some(custody_public_key.clone()),
        receipts_checked: 0,
        chain_valid,
        chain_checked_events,
        head_position,
        first_failure: None,
    };

    if !chain_valid {
        return failure(
            None,
            "chain_invalid",
            "verify_audit_event_chain reported the stored chain is broken".into(),
            &base,
        );
    }

    // Bidirectional surplus check: ensure DB doesn't contain unexpected extra mirror rows
    let mirror_count: i64 = match client
        .query_one("SELECT count(*) FROM audit_checkpoint", &[])
        .await
    {
        Ok(row) => row.get(0),
        Err(error) => {
            return RestoreVerification::failed(
                "chain_unreadable",
                format!("mirror count query failed: {error}"),
            );
        }
    };

    if mirror_count > receipts.len() as i64 {
        return failure(
            None,
            "surplus_mirrors_detected",
            format!(
                "audit_checkpoint table contains {} rows but custody holds only {}",
                mirror_count,
                receipts.len()
            ),
            &base,
        );
    }

    let mut expected_index = 1i64;
    for receipt in &receipts {
        let checkpoint_index = receipt.checkpoint_index;

        let head_hash: Option<String> = match client
            .query_opt(
                "SELECT event_hash FROM audit_event WHERE chain_position = $1",
                &[&receipt.chain_position],
            )
            .await
        {
            Ok(row) => row.map(|row| row.get::<_, String>(0)),
            Err(error) => {
                return failure(
                    Some(checkpoint_index),
                    "chain_unreadable",
                    format!("checkpoint replay query failed: {error}"),
                    &base,
                );
            }
        };

        let mirror_row: Option<AuditCheckpointRow> = match client
            .query_opt(
                "SELECT checkpoint_index, chain_position, chain_digest,
                        to_char(checkpoint_time AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'),
                        signature
                   FROM audit_checkpoint WHERE checkpoint_index = $1",
                &[&checkpoint_index],
            )
            .await
        {
            Ok(row) => row.map(|r| AuditCheckpointRow {
                checkpoint_index: r.get(0),
                chain_position: r.get(1),
                chain_digest: r.get(2),
                checkpoint_time: r.get(3),
                signature: r.get(4),
            }),
            Err(error) => {
                return failure(
                    Some(checkpoint_index),
                    "chain_unreadable",
                    format!("checkpoint mirror query failed: {error}"),
                    &base,
                );
            }
        };

        match verify_single_receipt_logic(
            receipt,
            expected_index,
            &custody_public_key,
            head_hash.as_deref(),
            mirror_row.as_ref(),
        ) {
            Ok(Some(_to_backfill)) => {
                // Auto-reconcile missing mirror row
                let parsed_time = match parse_checkpoint_time(&receipt.checkpoint_time) {
                    Ok(time) => time,
                    Err(error) => {
                        return failure(Some(checkpoint_index), "timestamp_invalid", error, &base);
                    }
                };
                let reconcile_lineage = serde_json::json!({
                    "source": "backend-restore-reconciliation",
                    "entitlement_version": "local-v1"
                });

                let insert_result = client
                    .execute(
                        "INSERT INTO audit_checkpoint (
                            checkpoint_index, chain_position, chain_digest, checkpoint_time,
                            signature, source_lineage, receipt_time, record_environment
                        ) VALUES (
                            $1, $2, $3, $4, $5, $6, now(), 'local_research'
                        )",
                        &[
                            &receipt.checkpoint_index,
                            &receipt.chain_position,
                            &receipt.chain_digest,
                            &parsed_time,
                            &receipt.signature,
                            &reconcile_lineage,
                        ],
                    )
                    .await;

                if let Err(error) = insert_result {
                    return failure(
                        Some(checkpoint_index),
                        "mirror_reconciliation_failed",
                        format!("could not backfill mirror row: {error}"),
                        &base,
                    );
                }
                eprintln!(
                    "reconciled missing audit_checkpoint mirror row for receipt {checkpoint_index}"
                );
            }
            Ok(None) => {}
            Err((reason, detail)) => {
                return failure(Some(checkpoint_index), &reason, detail, &base);
            }
        }

        expected_index += 1;
        base.receipts_checked += 1;
    }

    let verified_at: String = match client
        .query_one(
            "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')",
            &[],
        )
        .await
    {
        Ok(row) => row.get(0),
        Err(error) => {
            return RestoreVerification::failed(
                "chain_unreadable",
                format!("verification clock query failed: {error}"),
            );
        }
    };

    RestoreVerification {
        pending: false,
        valid: true,
        verified_at: Some(verified_at),
        custody_public_key: base.custody_public_key,
        receipts_checked: base.receipts_checked,
        chain_valid,
        chain_checked_events,
        head_position,
        first_failure: None,
    }
}

pub async fn current_head(client: &Client) -> Result<(i64, String), String> {
    let row = client
        .query_one(
            "SELECT max(chain_position), current_chain_digest() FROM audit_event",
            &[],
        )
        .await
        .map_err(|error| format!("chain head query failed: {error}"))?;
    let position: Option<i64> = row.get(0);
    let digest: Option<String> = row.get(1);
    let position = position.ok_or("the audit chain is empty; nothing to checkpoint")?;
    let digest = digest.ok_or("the audit chain is empty; nothing to checkpoint")?;
    Ok((position, digest))
}

pub async fn execute_checkpoint_flow(
    client: &Client,
    custody: &CustodyClient,
) -> Result<(CheckpointReceipt, i64), (axum::http::StatusCode, String)> {
    let (chain_valid, _, _) = chain_state(client).await.map_err(|error| {
        (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            format!("chain verification failed: {error}"),
        )
    })?;

    if !chain_valid {
        return Err((
            axum::http::StatusCode::CONFLICT,
            "the audit chain does not verify; checkpoint refused".to_string(),
        ));
    }

    let (chain_position, digest) = current_head(client).await.map_err(|error| {
        (
            axum::http::StatusCode::CONFLICT,
            format!("cannot checkpoint empty chain: {error}"),
        )
    })?;

    let custody_public_key = custody.public_key().await.map_err(|error| {
        (
            axum::http::StatusCode::BAD_GATEWAY,
            format!("custody public key check failed: {error}"),
        )
    })?;

    let receipt = custody
        .sign(chain_position, &digest)
        .await
        .map_err(|error| {
            (
                axum::http::StatusCode::BAD_GATEWAY,
                format!("custody sign failed: {error}"),
            )
        })?;

    // Boundary validation: verify the custody response before writing anything
    if let Err(error) = validate_receipt_shape(&receipt) {
        return Err((
            axum::http::StatusCode::BAD_GATEWAY,
            format!("custody returned malformed receipt: {error}"),
        ));
    }
    if let Err(error) = verify_receipt_signature(&receipt) {
        return Err((
            axum::http::StatusCode::BAD_GATEWAY,
            format!("custody signature verification failed: {error}"),
        ));
    }
    if receipt.public_key != custody_public_key {
        return Err((
            axum::http::StatusCode::BAD_GATEWAY,
            "custody receipt signed by unexpected key".to_string(),
        ));
    }
    if receipt.chain_position != chain_position || receipt.chain_digest != digest {
        return Err((
            axum::http::StatusCode::BAD_GATEWAY,
            "custody receipt does not match requested chain position or digest".to_string(),
        ));
    }

    let checkpoint_time = parse_checkpoint_time(&receipt.checkpoint_time).map_err(|error| {
        (
            axum::http::StatusCode::BAD_GATEWAY,
            format!("custody issued an invalid timestamp: {error}"),
        )
    })?;

    let lineage = serde_json::json!({
        "source": "backend-checkpoint",
        "entitlement_version": "local-v1"
    });

    let payload = serde_json::json!({
        "checkpoint_index": receipt.checkpoint_index,
        "chain_position": receipt.chain_position,
        "chain_digest": receipt.chain_digest,
        "checkpoint_time": receipt.checkpoint_time,
    });

    let insert = client
        .query_one(
            "INSERT INTO audit_checkpoint (
                checkpoint_index, chain_position, chain_digest, checkpoint_time,
                signature, source_lineage, receipt_time, record_environment
            ) VALUES (
                $1, $2, $3, $4, $5, $6, now(), 'local_research'
            ) RETURNING checkpoint_index",
            &[
                &receipt.checkpoint_index,
                &receipt.chain_position,
                &receipt.chain_digest,
                &checkpoint_time,
                &receipt.signature,
                &lineage,
            ],
        )
        .await;

    if let Err(error) = insert {
        return Err((
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            format!("checkpoint mirror insert failed: {error}"),
        ));
    }

    let event_id = format!("checkpoint-{}", receipt.checkpoint_index);
    let audit = client
        .query_one(
            "SELECT chain_position FROM append_audit_event(
                $1,
                'audit.checkpoint_created',
                now(),
                $2,
                $3,
                now(),
                'local_research'
            )",
            &[&event_id, &payload, &lineage],
        )
        .await;

    let audit_position = match audit {
        Ok(row) => row.get::<_, i64>(0),
        Err(error) => {
            return Err((
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("checkpoint audit append failed: {error}"),
            ));
        }
    };

    Ok((receipt, audit_position))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::receipt::{sign_receipt, utc_checkpoint_time_now};
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;

    fn test_setup() -> (SigningKey, String, CheckpointReceipt, AuditCheckpointRow) {
        let key = SigningKey::generate(&mut OsRng);
        let pub_hex = hex::encode(key.verifying_key().to_bytes());
        let time = utc_checkpoint_time_now();
        let digest = chain_digest(
            3,
            "0000000000000000000000000000000000000000000000000000000000000000",
        );
        let receipt = sign_receipt(&key, 1, 3, digest.clone(), time.clone());
        let mirror = AuditCheckpointRow {
            checkpoint_index: 1,
            chain_position: 3,
            chain_digest: digest,
            checkpoint_time: time,
            signature: receipt.signature.clone(),
        };
        (key, pub_hex, receipt, mirror)
    }

    #[test]
    fn single_receipt_matching_mirror_passes() {
        let (_, pub_hex, receipt, mirror) = test_setup();
        let hash = "0000000000000000000000000000000000000000000000000000000000000000";
        let res = verify_single_receipt_logic(&receipt, 1, &pub_hex, Some(hash), Some(&mirror));
        assert_eq!(res, Ok(None));
    }

    #[test]
    fn single_receipt_missing_mirror_triggers_reconciliation() {
        let (_, pub_hex, receipt, _) = test_setup();
        let hash = "0000000000000000000000000000000000000000000000000000000000000000";
        let res = verify_single_receipt_logic(&receipt, 1, &pub_hex, Some(hash), None);
        assert!(matches!(res, Ok(Some(backfill)) if backfill.checkpoint_index == 1));
    }

    #[test]
    fn single_receipt_index_sequence_mismatch() {
        let (_, pub_hex, receipt, mirror) = test_setup();
        let hash = "0000000000000000000000000000000000000000000000000000000000000000";
        let res = verify_single_receipt_logic(&receipt, 2, &pub_hex, Some(hash), Some(&mirror));
        assert_eq!(res.unwrap_err().0, "checkpoint_index_sequence");
    }

    #[test]
    fn single_receipt_key_mismatch() {
        let (_, _, receipt, mirror) = test_setup();
        let other_key = SigningKey::generate(&mut OsRng);
        let other_pub = hex::encode(other_key.verifying_key().to_bytes());
        let hash = "0000000000000000000000000000000000000000000000000000000000000000";
        let res = verify_single_receipt_logic(&receipt, 1, &other_pub, Some(hash), Some(&mirror));
        assert_eq!(res.unwrap_err().0, "custody_key_mismatch");
    }

    #[test]
    fn single_receipt_missing_chain_position() {
        let (_, pub_hex, receipt, mirror) = test_setup();
        let res = verify_single_receipt_logic(&receipt, 1, &pub_hex, None, Some(&mirror));
        assert_eq!(res.unwrap_err().0, "chain_position_missing");
    }

    #[test]
    fn single_receipt_chain_digest_mismatch() {
        let (_, pub_hex, receipt, mirror) = test_setup();
        let wrong_hash = "1111111111111111111111111111111111111111111111111111111111111111";
        let res =
            verify_single_receipt_logic(&receipt, 1, &pub_hex, Some(wrong_hash), Some(&mirror));
        assert_eq!(res.unwrap_err().0, "chain_digest_mismatch");
    }

    #[test]
    fn single_receipt_mirror_divergence() {
        let (_, pub_hex, receipt, mut mirror) = test_setup();
        mirror.signature = "aa".repeat(64);
        let hash = "0000000000000000000000000000000000000000000000000000000000000000";
        let res = verify_single_receipt_logic(&receipt, 1, &pub_hex, Some(hash), Some(&mirror));
        assert_eq!(res.unwrap_err().0, "mirror_mismatch");
    }
}
