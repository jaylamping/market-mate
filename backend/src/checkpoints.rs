use crate::receipt::{chain_digest, verify_receipt_signature, CheckpointReceipt};
use http_body_util::{BodyExt, Full};
use hyper::{
    body::Bytes,
    header::CONTENT_TYPE,
    http::uri::Uri,
    Method, Request,
};
use hyper_util::{
    client::legacy::{connect::HttpConnector, Client as HttpClient},
    rt::TokioExecutor,
};
use serde::Serialize;
use tokio_postgres::Client;

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
        let response = self
            .http
            .request(request)
            .await
            .map_err(|error| format!("custody request failed: {error}"))?;
        if !response.status().is_success() {
            return Err(format!(
                "custody responded with status {}",
                response.status()
            ));
        }
        let bytes = response
            .into_body()
            .collect()
            .await
            .map_err(|error| format!("custody response body failed: {error}"))?
            .to_bytes();
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

#[derive(Debug, Clone, Serialize)]
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

async fn chain_state(client: &Client) -> Result<(bool, i64, Option<i64>), String> {
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
    let base = RestoreVerification {
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

    let mut previous_index: Option<i64> = None;
    for receipt in &receipts {
        let checkpoint_index = receipt.checkpoint_index;
        if let Some(previous) = previous_index {
            if checkpoint_index <= previous {
                return failure(
                    Some(checkpoint_index),
                    "checkpoint_index_sequence",
                    format!("receipt index {checkpoint_index} does not follow {previous}"),
                    &base,
                );
            }
        }
        previous_index = Some(checkpoint_index);

        if let Err(error) = verify_receipt_signature(receipt) {
            return failure(Some(checkpoint_index), "signature_invalid", error, &base);
        }
        if receipt.public_key != custody_public_key {
            return failure(
                Some(checkpoint_index),
                "custody_key_mismatch",
                "receipt was signed by a key other than current custody key".into(),
                &base,
            );
        }

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
        let Some(head_hash) = head_hash else {
            return failure(
                Some(checkpoint_index),
                "chain_position_missing",
                format!(
                    "chain position {} is absent from the database",
                    receipt.chain_position
                ),
                &base,
            );
        };
        let expected_digest = chain_digest(receipt.chain_position, &head_hash);
        if expected_digest != receipt.chain_digest {
            return failure(
                Some(checkpoint_index),
                "chain_digest_mismatch",
                format!(
                    "receipt binds digest {} but chain position {} now hashes to {expected_digest}",
                    receipt.chain_digest, receipt.chain_position
                ),
                &base,
            );
        }

        let mirror: Option<String> = match client
            .query_opt(
                "SELECT signature FROM audit_checkpoint WHERE checkpoint_index = $1",
                &[&checkpoint_index],
            )
            .await
        {
            Ok(row) => row.map(|row| row.get::<_, String>(0)),
            Err(error) => {
                return failure(
                    Some(checkpoint_index),
                    "chain_unreadable",
                    format!("checkpoint mirror query failed: {error}"),
                    &base,
                );
            }
        };
        match mirror {
            Some(signature) if signature == receipt.signature => {}
            Some(_) => {
                return failure(
                    Some(checkpoint_index),
                    "mirror_mismatch",
                    format!("audit_checkpoint row {checkpoint_index} diverges from custody"),
                    &base,
                );
            }
            None => {
                return failure(
                    Some(checkpoint_index),
                    "mirror_missing",
                    format!("audit_checkpoint row {checkpoint_index} is absent"),
                    &base,
                );
            }
        }
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
        receipts_checked: receipts.len() as i64,
        chain_valid,
        chain_checked_events,
        head_position,
        first_failure: None,
    }
}

pub async fn current_head(
    client: &Client,
) -> Result<(i64, String), String> {
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
