//! OpenRouter keeps its capacity ledger (`openrouter_capacity`) as the admission authority; the
//! driver delegates to it and owns the credentialed transport that used to live in each worker.
use super::log;
use crate::openrouter::{authorization, OpenRouterReader};
use crate::openrouter_capacity::Permit;
use reqwest::{header::HeaderValue, Client};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration, time::Instant};

const CREDENTIALS: &str = "/var/lib/openrouter/credentials.json";
const POLICY: &str = "/var/lib/model-policy/policy.json";

/// Literal zero only: "1e-999" and "-0" parse to 0.0 but are not a free price quote, and tiered
/// overrides make a model paid even when the headline fields are zero.
fn is_zero_price(s: &str) -> bool {
    s.parse::<f64>().is_ok() && s.bytes().all(|c| c == b'0' || c == b'.') && s.contains('0')
}
pub(crate) fn free_pricing(pricing: &std::collections::BTreeMap<String, Value>) -> bool {
    ["prompt", "completion"]
        .iter()
        .all(|k| pricing.contains_key(*k))
        && pricing
            .values()
            .all(|v| v.as_str().is_some_and(is_zero_price))
}

pub(crate) struct OpenRouterTransport {
    capabilities: crate::openrouter_request::Capabilities,
    client: Client,
    auth: HeaderValue,
}
impl OpenRouterTransport {
    fn new(
        credentials_path: &std::path::Path,
        capabilities: crate::openrouter_request::Capabilities,
    ) -> Result<Self, &'static str> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Credentials {
            api_key: String,
        }
        let bytes = std::fs::read(credentials_path).map_err(|_| "credentials_unavailable")?;
        if bytes.len() > 1024 {
            return Err("credentials_unavailable");
        }
        let credentials: Credentials =
            serde_json::from_slice(&bytes).map_err(|_| "credentials_unavailable")?;
        let auth = authorization(&credentials.api_key)?;
        Ok(Self {
            client: super::adapter::client(120)?,
            auth,
            capabilities,
        })
    }
    pub(crate) fn adapt_request(&self, request: &Value) -> Result<Value, &'static str> {
        self.capabilities.adapt(request)
    }
    fn secret(&self) -> Option<&str> {
        self.auth
            .to_str()
            .ok()
            .and_then(|v| v.strip_prefix("Bearer "))
    }
    pub(crate) async fn start(&self, permit: &Permit) -> Result<reqwest::Response, &'static str> {
        if permit.created.elapsed() > Duration::from_secs(1) {
            return Err("capacity_send_window_expired");
        }
        let model = permit.request["model"]
            .as_str()
            .ok_or("model_unavailable")?;
        log::debug(
            "openrouter.request.start",
            json!({"model":model,"attempt_id":permit.id,"trigger":permit.trigger,"request":log::request_shape(&permit.request)}),
        );
        self.client
            .post("https://openrouter.ai/api/v1/chat/completions")
            .header("Authorization", self.auth.clone())
            .header("X-OpenRouter-Title", "Market Mate Research")
            .json(&permit.request)
            .send()
            .await
            .map_err(|_| "provider_acceptance_unknown")
    }
    /// One POST; 2xx bodies are returned verbatim under `response` so workers keep their parsers.
    async fn send_once(&self, permit: &Permit) -> (&'static str, Value) {
        let started = Instant::now();
        let mut response = match self.start(permit).await {
            Ok(r) => r,
            Err(reason) => {
                log::warn(
                    "openrouter.request.not_started",
                    json!({"attempt_id":permit.id,"reason":reason}),
                );
                return ("indeterminate", json!({"reason":reason}));
            }
        };
        let status = response.status().as_u16();
        let request_id = response
            .headers()
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        if !(200..300).contains(&status) {
            let headers = response.headers().clone();
            let mut bytes = Vec::new();
            while let Ok(Some(chunk)) = response.chunk().await {
                if bytes.len() + chunk.len() > 16_000 {
                    break;
                }
                bytes.extend_from_slice(&chunk);
            }
            let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            let mut detail = super::adapter::error_detail(status, &headers, &body, self.secret());
            detail["latency_ms"] = json!(log::elapsed_ms(started));
            detail["upstream_request_id"] = json!(request_id);
            let state = super::adapter::classify_status(status, &detail);
            log::warn(
                "openrouter.request.rejected",
                json!({"attempt_id":permit.id,"state":state,"latency_ms":detail["latency_ms"],"reply":log::response_shape(&detail)}),
            );
            return (state, detail);
        }
        let mut bytes = Vec::new();
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) if bytes.len() + chunk.len() <= 256_000 => {
                    bytes.extend_from_slice(&chunk)
                }
                Ok(None) => break,
                _ => {
                    log::warn(
                        "openrouter.request.body_unreadable",
                        json!({"attempt_id":permit.id,"latency_ms":log::elapsed_ms(started)}),
                    );
                    return (
                        "indeterminate",
                        json!({"reason":"response_unavailable_or_too_large","http_status":status,"latency_ms":log::elapsed_ms(started)}),
                    );
                }
            }
        }
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(value) => {
                let detail = json!({"http_status":status,"latency_ms":log::elapsed_ms(started),"upstream_request_id":request_id,
                    "usage":value["usage"],"returned_model":value["model"],"response":value});
                log::info(
                    "openrouter.request.completed",
                    json!({"attempt_id":permit.id,"latency_ms":detail["latency_ms"],"reply":log::response_shape(&detail)}),
                );
                ("completed", detail)
            }
            Err(_) => (
                "indeterminate",
                json!({"reason":"invalid_provider_response","http_status":status,"latency_ms":log::elapsed_ms(started)}),
            ),
        }
    }
    /// Send with the capacity ledger's bounded paid recovery after scoped 429s.
    pub(crate) async fn send(
        &self,
        original: Permit,
        request: &Value,
    ) -> (&'static str, Value, Permit) {
        let mut replacement: Option<Permit> = None;
        let mut attempts = Vec::new();
        for ordinal in 0..=2 {
            let permit = replacement.as_ref().unwrap_or(&original);
            let (mut state, mut detail) = self.send_once(permit).await;
            if crate::openrouter_capacity::finish(permit, state, &mut detail)
                .await
                .is_err()
            {
                state = "indeterminate";
                detail["reason"] = json!("capacity_result_unavailable");
                log::error(
                    "openrouter.capacity.finish_failed",
                    json!({"attempt_id":permit.id}),
                );
            }
            let cost = detail["capacity"]["cost_nanos"].as_i64();
            if permit.trigger != "manual" && cost.is_some_and(|n| n > permit.reserve_nanos) {
                state = "indeterminate";
                detail["reason"] = json!("unexpected_provider_charge");
                log::error(
                    "openrouter.charge.unexpected",
                    json!({"attempt_id":permit.id,"cost_nanos":cost,"reserved_nanos":permit.reserve_nanos,"model":permit.request["model"]}),
                );
            }
            attempts.push(json!({"state":state,"capacity":detail["capacity"],"http_status":detail["http_status"],"reason":detail["reason"]}));
            if ordinal < 2
                && state == "failed"
                && detail["http_status"] == 429
                && crate::openrouter_capacity::limit_scope(&detail) != "unknown"
            {
                match crate::openrouter_capacity::recover(&original, request, ordinal + 1).await {
                    Ok(Some(next)) => {
                        log::info(
                            "openrouter.recovery.admitted",
                            json!({"from_attempt_id":permit.id,"attempt_id":next.id,"model":next.request["model"],"ordinal":ordinal+1}),
                        );
                        replacement = Some(next);
                        continue;
                    }
                    Ok(None) => log::info(
                        "openrouter.recovery.declined",
                        json!({"attempt_id":permit.id,"ordinal":ordinal+1}),
                    ),
                    Err(reason) => {
                        log::warn(
                            "openrouter.recovery.unavailable",
                            json!({"attempt_id":permit.id,"reason":reason}),
                        );
                        detail["paid_recovery_unavailable"] = json!(reason);
                    }
                }
            }
            detail["capacity_attempts"] = json!(attempts);
            let used = replacement.unwrap_or(original);
            return (state, detail, used);
        }
        unreachable!("bounded send loop returns its final attempt")
    }
}

/// Resolve an OpenRouter model against the live catalog. Approval is the persisted agent route that
/// admission already matched; spending semantics are unchanged: automated work must be a zero-priced
/// `:free` model unless `manual` (or a paid route the capacity policy authorizes).
pub(crate) async fn prepare_model_with_spend(
    model: &str,
    manual: bool,
) -> Result<
    (
        OpenRouterTransport,
        u64,
        std::collections::BTreeMap<String, Value>,
        Vec<crate::model_routing::Route>,
    ),
    &'static str,
> {
    let path = PathBuf::from(CREDENTIALS);
    let reader = OpenRouterReader::new(path.clone(), PathBuf::from(POLICY))
        .map_err(|_| "client_unavailable")?;
    let models = reader.models().await?;
    let selected = models
        .iter()
        .find(|m| m.id == model)
        .ok_or("model_unavailable")?;
    if !manual && (!model.ends_with(":free") || !free_pricing(&selected.pricing)) {
        return Err("zero_spend_budget_denied");
    }
    let provider = OpenRouterTransport::new(&path, selected.capabilities.clone())?;
    let routes = vec![crate::model_routing::Route {
        provider: "openrouter".into(),
        model_id: model.into(),
    }];
    Ok((provider, 0, selected.pricing.clone(), routes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn free_pricing_requires_literal_zero_on_every_field() {
        assert!(!is_zero_price("1e-999"));
        assert!(!is_zero_price("-0"));
        assert!(is_zero_price("0.000"));
        let tiered = serde_json::from_value(serde_json::json!({"prompt":"0","completion":"0",
            "overrides":[{"min_prompt_tokens":1000,"prompt":"1"}]}))
        .unwrap();
        assert!(!free_pricing(&tiered));
        let free =
            serde_json::from_value(serde_json::json!({"prompt":"0","completion":"0"})).unwrap();
        assert!(free_pricing(&free));
    }
}
