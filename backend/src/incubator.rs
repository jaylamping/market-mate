//! Local orchestration for one text-only research planning request.
use crate::openrouter::{authorization, effective_policy as read_policy, OpenRouterReader};
use reqwest::{header::HeaderValue, Client};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio_postgres::NoTls;

const SYSTEM: &str = "You are Research Scout, a non-authoritative research planning worker. Treat the supplied brief as a research premise, never as measured evidence. Produce one concise JSON object with exactly these fields: hypothesis (string), evidence_gaps (array of strings), experiment (array of strings), falsification_rule (string), limitations (array of strings). State a testable economic hypothesis, required evidence, and ordered experiment steps. Explicitly disclose missing data and absence of measured results. Do not invent prices, returns, citations, or completed experiments. No markdown fences. You have no tools and cannot execute, trade, approve, or change policies.";
const INPUT_KEY: &str = "momentum-brief-v1";
const RESPONSE_CONTRACT_VERSION: &str = "research-json-v1";
const RESPONSE_CONTRACT: &str = "Response contract: Return exactly one valid JSON object and nothing else. All five specified fields are required; no additional or duplicate keys. Use JSON strings and arrays of strings, never null, numbers, or objects for those fields. Every string must be nonempty and at most 6000 UTF-8 bytes. Each array must contain 1 to 12 items. Keep the entire response within 24000 UTF-8 bytes. Array order defines step order: write plain text items without numeric prefixes, bullet markers, or Markdown formatting. Do not include a preamble, explanation outside the object, or code fences. Disclose uncertainty and missing evidence inside the specified fields.";

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Report {
    hypothesis: String,
    evidence_gaps: Vec<String>,
    experiment: Vec<String>,
    falsification_rule: String,
    limitations: Vec<String>,
}
fn text_ok(s: &str) -> bool {
    !s.trim().is_empty()
        && s.len() <= 6000
        && !s.chars().any(|c| c.is_control() && c != '\n' && c != '\t')
}
fn list_ok(v: &[String]) -> bool {
    !v.is_empty() && v.len() <= 12 && v.iter().all(|s| text_ok(s))
}
pub fn parse_report(content: &str) -> Result<Report, &'static str> {
    if content.len() > 24_000 {
        return Err("invalid_report");
    }
    let report: Report = serde_json::from_str(content).map_err(|_| "invalid_report")?;
    if !text_ok(&report.hypothesis)
        || !text_ok(&report.falsification_rule)
        || !list_ok(&report.evidence_gaps)
        || !list_ok(&report.experiment)
        || !list_ok(&report.limitations)
    {
        return Err("invalid_report");
    }
    Ok(report)
}
fn is_zero_price(s: &str) -> bool {
    s.parse::<f64>().is_ok() && s.bytes().all(|c| c == b'0' || c == b'.') && s.contains('0')
}
fn free_pricing(pricing: &std::collections::BTreeMap<String, Value>) -> bool {
    ["prompt", "completion"]
        .iter()
        .all(|k| pricing.contains_key(*k))
        && pricing
            .values()
            .all(|v| v.as_str().is_some_and(is_zero_price))
}
fn payload(model: &str, brief: &str) -> Value {
    json!({"model":model,"messages":[{"role":"system","content":format!("{SYSTEM}\n\n{RESPONSE_CONTRACT}")},{"role":"user","content":brief}],
        "max_tokens":2048,"stream":false,"provider":{"allow_fallbacks":false,"require_parameters":true,
        "max_price":{"prompt":0,"completion":0}},"response_format":{"type":"json_object"}})
}
fn safe_id(value: &Value) -> Value {
    value
        .as_str()
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 256
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._:/-".contains(&b))
        })
        .map_or(Value::Null, |s| json!(s))
}
fn usage(value: &Value) -> Value {
    let u = &value["usage"];
    let cost = u["cost"].as_f64().filter(|n| n.is_finite() && *n >= 0.0);
    json!({"prompt_tokens":u["prompt_tokens"].as_u64(),"completion_tokens":u["completion_tokens"].as_u64(),
        "total_tokens":u["total_tokens"].as_u64(),"cost_usd":cost})
}
fn completion(value: Value, requested_model: &str) -> (&'static str, Value) {
    let mut detail = json!({"generation_id":safe_id(&value["id"]),"returned_model":safe_id(&value["model"]),
        "serving_provider":safe_id(&value["provider"]),"usage":usage(&value)});
    if let Some(content) = value["choices"][0]["message"]["content"].as_str() {
        // Preserve invalid output as inert text so a failure remains inspectable.
        let mut end = content.len().min(24_000);
        while !content.is_char_boundary(end) {
            end -= 1;
        }
        detail["response_text"] = json!(&content[..end]);
        detail["response_truncated"] = json!(end < content.len());
    }
    let model = value["model"].as_str().unwrap_or_default();
    let reason = if value.get("error").is_some() {
        Some("provider_error")
    } else if model != requested_model && Some(model) != requested_model.strip_suffix(":free") {
        Some("unexpected_model")
    } else if value["choices"][0]["finish_reason"] != "stop" {
        Some("incomplete_response")
    } else if value["choices"][0]["message"].get("tool_calls").is_some() {
        Some("unexpected_tool_call")
    } else {
        None
    };
    if detail["usage"]["cost_usd"]
        .as_f64()
        .is_some_and(|cost| cost > 0.0)
    {
        detail["reason"] = json!("unexpected_provider_charge");
        return ("indeterminate", detail);
    }
    if let Some(reason) = reason {
        detail["reason"] = json!(reason);
        return ("failed", detail);
    }
    match value["choices"][0]["message"]["content"]
        .as_str()
        .ok_or("invalid_report")
        .and_then(parse_report)
    {
        Ok(report) => {
            detail["report"] = json!(report);
            ("completed", detail)
        }
        Err(reason) => {
            detail["reason"] = json!(reason);
            detail["validation_error"] = json!(serde_json::from_str::<Report>(
                value["choices"][0]["message"]["content"]
                    .as_str()
                    .unwrap_or_default()
            )
            .err()
            .map(|e| e.to_string().chars().take(300).collect::<String>())
            .unwrap_or_else(|| {
                "Report exceeded text/list bounds or contained empty fields".into()
            }));
            ("failed", detail)
        }
    }
}

struct OpenRouter {
    client: Client,
    auth: HeaderValue,
}
impl OpenRouter {
    fn new(credentials_path: &std::path::Path) -> Result<Self, &'static str> {
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
        let client = Client::builder()
            .https_only(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(120))
            .build()
            .map_err(|_| "client_unavailable")?;
        Ok(Self { client, auth })
    }
    async fn send(&self, request: &Value) -> (&'static str, Value) {
        let response = self
            .client
            .post("https://openrouter.ai/api/v1/chat/completions")
            .header("Authorization", self.auth.clone())
            .header("X-OpenRouter-Title", "Market Mate Research POC")
            .json(request)
            .send()
            .await;
        let mut response = match response {
            Ok(r) => r,
            Err(_) => {
                return (
                    "indeterminate",
                    json!({"reason":"provider_acceptance_unknown"}),
                )
            }
        };
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            // Explicit request rejection is terminal; server/proxy failures may follow acceptance.
            let state = if [400, 401, 402, 403, 404, 413, 422, 429].contains(&status) {
                "failed"
            } else {
                "indeterminate"
            };
            return (
                state,
                json!({"reason":"provider_http_error","http_status":status}),
            );
        }
        let mut bytes = Vec::new();
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) if bytes.len() + chunk.len() <= 64_000 => {
                    bytes.extend_from_slice(&chunk)
                }
                Ok(None) => break,
                _ => {
                    return (
                        "indeterminate",
                        json!({"reason":"response_unavailable_or_too_large"}),
                    )
                }
            }
        }
        match serde_json::from_slice(&bytes) {
            Ok(value) => completion(value, request["model"].as_str().unwrap_or_default()),
            Err(_) => (
                "indeterminate",
                json!({"reason":"invalid_provider_response"}),
            ),
        }
    }
}

async fn event(
    db: &tokio_postgres::Client,
    key: &str,
    state: &str,
    detail: Value,
) -> Result<Value, &'static str> {
    db.query_one(
        "SELECT record_incubator_agent_event($1,$2,$3)",
        &[&key, &state, &detail],
    )
    .await
    .map(|r| r.get(0))
    .map_err(|_| "event_persistence_failed_no_retry")
}

pub async fn run(key: &str, model: &str) -> Result<Value, &'static str> {
    let url = std::env::var("DATABASE_URL").map_err(|_| "database_unconfigured")?;
    let (db, connection) =
        tokio::time::timeout(Duration::from_secs(5), tokio_postgres::connect(&url, NoTls))
            .await
            .map_err(|_| "database_unavailable")?
            .map_err(|_| "database_unavailable")?;
    let connection_task = tokio::spawn(async move {
        let _ = connection.await;
    });
    let result = run_with_database(&db, key, model).await;
    drop(db);
    connection_task.abort();
    result
}

async fn run_with_database(
    db: &tokio_postgres::Client,
    key: &str,
    model: &str,
) -> Result<Value, &'static str> {
    db.batch_execute("SET statement_timeout='5s'; SET lock_timeout='3s'")
        .await
        .map_err(|_| "database_unavailable")?;
    let locked: bool = db
        .query_one("SELECT pg_try_advisory_lock(53002)", &[])
        .await
        .map_err(|_| "database_unavailable")?
        .get(0);
    if !locked {
        return Err("research_lane_busy");
    }
    let existing: Option<Value> = db
        .query_one("SELECT read_incubator_agent_run($1)", &[&key])
        .await
        .map_err(|_| "database_unavailable")?
        .get(0);
    if let Some(existing) = existing {
        let stored_model = existing["config"]["model"].as_str().ok_or("invalid_run")?;
        if !model.is_empty() && model != stored_model {
            return Err("run_key_model_mismatch");
        }
        let child: Option<Value> = db
            .query_one("SELECT read_incubator_agent_fallback($1)", &[&key])
            .await
            .map_err(|_| "database_unavailable")?
            .get(0);
        if let Some(child) = child {
            return run_once(
                db,
                child["run_key"].as_str().ok_or("invalid_run")?,
                child["config"]["model"].as_str().ok_or("invalid_run")?,
                Some(key),
            )
            .await;
        }
        return run_once(db, key, stored_model, None).await;
    }
    let policy =
        crate::model_routing::stored(std::path::Path::new("/var/lib/model-policy/routing.json"))?;
    let default_route = policy.as_ref().and_then(default_route).cloned();
    let primary = if model.is_empty() {
        let default = default_route
            .as_ref()
            .ok_or("default_model_not_configured")?;
        if default.provider != "openrouter" {
            return Err("preferred_provider_execution_unavailable");
        }
        default.model_id.as_str()
    } else {
        model
    };
    let result = run_once(db, key, primary, None).await?;
    if should_fallback(&result, default_route.as_ref(), primary)
        && crate::model_routing::stored(std::path::Path::new("/var/lib/model-policy/routing.json"))?
            == policy
    {
        let route = default_route.unwrap();
        let child_key = format!("fallback-{}", crate::migrate::checksum(key));
        let revision = policy.as_ref().unwrap().revision as i64;
        db.query_one(
            "SELECT admit_incubator_agent_fallback($1,$2,$3,$4)",
            &[&key, &child_key, &route.model_id, &revision],
        )
        .await
        .map_err(|_| "fallback_admission_failed_no_retry")?;
        return run_once(db, &child_key, &route.model_id, Some(key)).await;
    }
    Ok(result)
}
fn default_route(
    policy: &crate::model_routing::RoutingPolicy,
) -> Option<&crate::model_routing::Route> {
    policy
        .models
        .iter()
        .find(|m| Some(&m.model_id) == policy.default_model.as_ref())?
        .routes
        .first()
}
fn should_fallback(
    result: &Value,
    route: Option<&crate::model_routing::Route>,
    primary: &str,
) -> bool {
    result["state"] == "failed"
        && route.is_some_and(|r| {
            r.provider == "openrouter" && r.model_id != primary && r.model_id.ends_with(":free")
        })
}
async fn run_once(
    db: &tokio_postgres::Client,
    key: &str,
    model: &str,
    fallback_of: Option<&str>,
) -> Result<Value, &'static str> {
    let row = db
        .query_one(
            "SELECT admit_incubator_agent_run($1,$2,$3)",
            &[&key, &model, &INPUT_KEY],
        )
        .await
        .map_err(|_| "admission_denied_check_identity_input_or_existing_run")?;
    let run: Value = row.get(0);
    match run["state"].as_str() {
        Some("dispatched") => {
            return event(
                db,
                key,
                "indeterminate",
                json!({"reason":"interrupted_after_dispatch_no_retry","fallback_of":fallback_of}),
            )
            .await
        }
        Some("admitted") => (),
        _ => return Ok(run),
    }
    let path = PathBuf::from("/var/lib/openrouter/credentials.json");
    let policy_path = PathBuf::from("/var/lib/model-policy/policy.json");
    let prepared = async {
        let routing_path = policy_path.with_file_name("routing.json");
        let routing = crate::model_routing::stored(&routing_path)?;
        let routes = if let Some(policy) = &routing {
            let preference = policy
                .models
                .iter()
                .find(|m| m.model_id == crate::model_routing::canonical("openrouter", model))
                .ok_or("model_not_whitelisted")?;
            let first = preference.routes.first().ok_or("model_not_whitelisted")?;
            if first.provider != "openrouter" {
                return Err("preferred_provider_execution_unavailable");
            }
            if first.model_id != model {
                return Err("model_not_whitelisted");
            }
            preference.routes.clone()
        } else {
            vec![crate::model_routing::Route {
                provider: "openrouter".into(),
                model_id: model.into(),
            }]
        };
        let policy = read_policy(&policy_path)?;
        if !policy.allowed_models.iter().any(|m| m == model) {
            return Err("model_not_whitelisted");
        }
        let reader = OpenRouterReader::new(path.clone(), policy_path.clone())
            .map_err(|_| "client_unavailable")?;
        let models = reader.models().await?;
        let selected = models
            .iter()
            .find(|m| m.id == model)
            .ok_or("model_unavailable")?;
        if !model.ends_with(":free") || !free_pricing(&selected.pricing) {
            return Err("zero_spend_budget_denied");
        }
        let provider = OpenRouter::new(&path)?;
        let brief = run["config"]["input"]["text"]
            .as_str()
            .ok_or("input_unavailable")?;
        let request = payload(model, brief);
        // Snapshot the latest saved policy at the final admission boundary.
        let current = read_policy(&policy_path)?;
        if crate::model_routing::stored(&routing_path)? != routing
            || current.revision != policy.revision
            || !current.allowed_models.iter().any(|m| m == model)
        {
            return Err("model_policy_changed");
        }
        Ok((
            provider,
            request,
            current.revision,
            selected.pricing.clone(),
            routes,
        ))
    }
    .await;
    let (provider, request, revision, pricing, routes) = match prepared {
        Ok(v) => v,
        Err(reason) => {
            return event(
                db,
                key,
                "failed",
                json!({"reason":reason,"fallback_of":fallback_of}),
            )
            .await
        }
    };
    // The dispatch intent commits before the only POST. A crash here sacrifices
    // liveness rather than risking a second accepted generation.
    event(
        db,
        key,
        "dispatched",
        json!({"fallback_of":fallback_of,"policy_revision":revision,"provider_priority":routes,"pricing":pricing,"response_contract_version":RESPONSE_CONTRACT_VERSION,
        "request":request,"request_sha256":crate::migrate::checksum(&request.to_string())}),
    )
    .await?;
    let (state, mut detail) = provider.send(&request).await;
    detail["fallback_of"] = json!(fallback_of);
    event(db, key, state, detail).await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fallback_is_bounded_to_confirmed_failures_and_a_different_executable_model() {
        let route = crate::model_routing::Route {
            provider: "openrouter".into(),
            model_id: "vendor/backup:free".into(),
        };
        assert!(should_fallback(
            &json!({"state":"failed"}),
            Some(&route),
            "vendor/primary:free"
        ));
        for state in ["completed", "indeterminate", "dispatched", "admitted"] {
            assert!(!should_fallback(
                &json!({"state":state}),
                Some(&route),
                "vendor/primary:free"
            ));
        }
        assert!(!should_fallback(
            &json!({"state":"failed"}),
            Some(&route),
            &route.model_id
        ));
        assert!(!should_fallback(
            &json!({"state":"failed"}),
            None,
            "vendor/primary:free"
        ));
        let cursor = crate::model_routing::Route {
            provider: "cursor".into(),
            model_id: "backup".into(),
        };
        assert!(!should_fallback(
            &json!({"state":"failed"}),
            Some(&cursor),
            "vendor/primary:free"
        ));
    }
    fn report() -> Value {
        json!({"hypothesis":"A testable premise","evidence_gaps":["No observations"],"experiment":["Preregister then test"],"falsification_rule":"Reject after costs","limitations":["No empirical evidence"]})
    }
    #[test]
    fn schema_rejects_empty_extra_and_oversized_output() {
        assert!(parse_report(&report().to_string()).is_ok());
        let mut r = report();
        r["authority"] = json!(true);
        assert!(parse_report(&r.to_string()).is_err());
        let mut r = report();
        r["evidence_gaps"] = json!([]);
        assert!(parse_report(&r.to_string()).is_err());
        assert!(parse_report(&"x".repeat(24_001)).is_err());
    }
    #[test]
    fn request_is_bounded_and_has_no_tools_or_fallback() {
        let p = payload("vendor/model:free", "brief");
        assert_eq!(p["provider"]["allow_fallbacks"], false);
        assert_eq!(p["provider"]["max_price"]["prompt"], 0);
        assert_eq!(p["max_tokens"], 2048);
        assert!(p.get("tools").is_none());
        assert_eq!(p["response_format"]["type"], "json_object");
        assert_eq!(p["provider"]["require_parameters"], true);
        assert!(p["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains(RESPONSE_CONTRACT));
        assert!(!is_zero_price("1e-999"));
        assert!(!is_zero_price("-0"));
        assert!(is_zero_price("0.000"));
        let tiered = serde_json::from_value(json!({"prompt":"0","completion":"0",
            "overrides":[{"min_prompt_tokens":1000,"prompt":"1"}]}))
        .unwrap();
        assert!(!free_pricing(&tiered));
    }
    #[test]
    fn formatting_violations_fail_without_repair_or_losing_source() {
        let valid = report().to_string();
        let mut missing = report();
        missing.as_object_mut().unwrap().remove("experiment");
        let mut wrong_type = report();
        wrong_type["experiment"] = json!("1. Test it");
        let duplicate = valid.replacen('{', "{\"hypothesis\":\"duplicate\",", 1);
        for content in [
            format!("```json\n{valid}\n```"),
            format!("Here is the report: {valid}"),
            format!("{valid} {{}}"),
            missing.to_string(),
            wrong_type.to_string(),
            duplicate,
        ] {
            let response = json!({"model":"vendor/model","choices":[{"finish_reason":"stop","message":{"content":content}}]});
            let (state, detail) = completion(response, "vendor/model");
            assert_eq!(state, "failed");
            assert_eq!(detail["reason"], "invalid_report");
            assert_eq!(detail["response_text"], content);
            assert!(detail.get("report").is_none());
        }
    }
    #[test]
    fn usage_is_truthful_and_bad_provider_output_never_completes() {
        let mut r = json!({"id":"gen-1","model":"vendor/model","choices":[{"finish_reason":"stop","message":{"content":report().to_string()}}]});
        let (state, detail) = completion(r.clone(), "vendor/model:free");
        assert_eq!(state, "completed");
        assert!(detail["usage"]["cost_usd"].is_null());
        r["usage"] = json!({"cost":0.001});
        assert_eq!(
            completion(r.clone(), "vendor/model:free").0,
            "indeterminate"
        );
        r["usage"] = json!({"cost":0});
        r["choices"][0]["finish_reason"] = json!("length");
        assert_eq!(
            completion(r.clone(), "vendor/model:free").1["reason"],
            "incomplete_response"
        );
        r["model"] = json!("other/model");
        assert_eq!(
            completion(r, "vendor/model:free").1["reason"],
            "unexpected_model"
        );
    }
}
