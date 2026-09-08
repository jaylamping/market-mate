//! Local orchestration for one text-only research planning request.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;
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
fn research_report_schema() -> Value {
    json!({"type":"object","additionalProperties":false,
        "required":["hypothesis","evidence_gaps","experiment","falsification_rule","limitations"],
        "properties":{"hypothesis":{"type":"string"},"falsification_rule":{"type":"string"},
            "evidence_gaps":{"type":"array","items":{"type":"string"}},"experiment":{"type":"array","items":{"type":"string"}},
            "limitations":{"type":"array","items":{"type":"string"}}}})
}
fn coerce_report_field(key: &str, field: &Value) -> Option<Value> {
    match key {
        "hypothesis" | "falsification_rule" => field.as_str().map(|_| field.clone()),
        "evidence_gaps" | "experiment" | "limitations" => {
            if field.as_array().is_some() {
                Some(field.clone())
            } else {
                field.as_str().map(|s| json!([s]))
            }
        }
        _ => None,
    }
}
fn contract_report(value: Value) -> Option<Value> {
    let object = value.as_object()?;
    let mut out = serde_json::Map::new();
    for key in [
        "hypothesis",
        "evidence_gaps",
        "experiment",
        "falsification_rule",
        "limitations",
    ] {
        out.insert(key.to_string(), coerce_report_field(key, object.get(key)?)?);
    }
    Some(Value::Object(out))
}
fn research_report_json(raw: &str) -> Option<Value> {
    let body = crate::incubator_output::enclosing_json(raw);
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        if let Some(report) = contract_report(value) {
            return Some(report);
        }
    }
    crate::incubator_output::first_json_object(body)
        .and_then(|body| serde_json::from_str(body).ok())
        .and_then(contract_report)
}
pub fn parse_report(content: &str) -> Result<Report, &'static str> {
    if content.len() > 24_000 {
        return Err("invalid_report");
    }
    let report: Report =
        serde_json::from_value(research_report_json(content).ok_or("invalid_report")?)
            .map_err(|_| "invalid_report")?;
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
pub(crate) fn payload(model: &str, brief: &str) -> Value {
    json!({"model":model,"messages":[{"role":"system","content":format!("{SYSTEM}\n\n{RESPONSE_CONTRACT}")},{"role":"user","content":brief}],
        "max_tokens":2048,"stream":false,"reasoning":{"enabled":false},"provider":{"allow_fallbacks":true,"require_parameters":true,
        "max_price":{"prompt":0,"completion":0}},"response_format":crate::incubator_output::response_format("research_scout",research_report_schema())})
}
fn research_brief(input: &Value) -> Result<String, &'static str> {
    let title = input["title"].as_str().ok_or("input_unavailable")?;
    let text = input["text"].as_str().ok_or("input_unavailable")?;
    Ok(format!("Title: {title}\n\nRequest:\n{text}"))
}
fn assignment_payload(model: &str, brief: &str, manual: bool) -> Value {
    let mut request = payload(model, brief);
    if manual {
        request["provider"]
            .as_object_mut()
            .unwrap()
            .remove("max_price");
    }
    request
}
pub(crate) fn provider_error_detail(
    status: u16,
    headers: &reqwest::header::HeaderMap,
    body: &Value,
    secret: Option<&str>,
) -> Value {
    let mut detail = json!({"reason":"provider_http_error","http_status":status});
    let clean = |text: &str| {
        let redacted = match secret.filter(|key| !key.is_empty()) {
            Some(key) => text.replace(key, "[redacted]"),
            None => text.to_string(),
        };
        redacted
            .chars()
            .filter(|c| !c.is_control())
            .take(2000)
            .collect::<String>()
    };
    for (key, value) in [
        ("provider_message", &body["error"]["message"]),
        (
            "provider_error_type",
            &body["error"]["metadata"]["error_type"],
        ),
        (
            "provider_limit_source",
            &body["error"]["metadata"]["limit_source"],
        ),
        ("provider_remedy", &body["error"]["metadata"]["remedy_hint"]),
        (
            "serving_provider",
            &body["error"]["metadata"]["provider_name"],
        ),
    ] {
        if let Some(text) = value.as_str().filter(|v| !v.trim().is_empty()) {
            let text = clean(text);
            if !text.trim().is_empty() {
                detail[key] = json!(text);
            }
        }
    }
    for (key, header) in [
        ("retry_after", "retry-after"),
        ("rate_limit_reset", "x-ratelimit-reset"),
        ("rate_limit_remaining", "x-ratelimit-remaining"),
        ("rate_limit_limit", "x-ratelimit-limit"),
    ] {
        if let Some(text) = headers.get(header).and_then(|v| v.to_str().ok()) {
            let text = clean(text);
            if !text.trim().is_empty() {
                detail[key] = json!(text);
            }
        }
    }
    detail
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
pub(crate) fn completion(value: Value, requested_model: &str) -> (&'static str, Value) {
    completion_with_spend(value, requested_model, false)
}
fn manual_completion(value: Value, requested_model: &str) -> (&'static str, Value) {
    completion_with_spend(value, requested_model, true)
}
fn completion_with_spend(
    value: Value,
    requested_model: &str,
    manual: bool,
) -> (&'static str, Value) {
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
    if !manual
        && requested_model.ends_with(":free")
        && detail["usage"]["cost_usd"]
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

/// Workers hold no provider credentials; the agent driver admits, routes, sends, and records.
pub(crate) type OpenRouter = crate::driver::client::Dispatcher;

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
    let policy =
        crate::model_routing::stored(std::path::Path::new("/var/lib/model-policy/routing.json"))?;
    let default_route = policy.as_ref().and_then(default_route).cloned();
    let research_route = policy
        .as_ref()
        .and_then(|p| role_route(p, "research"))
        .cloned();
    let existing = if let Some(run) = existing {
        if run["config"]["campaign_model_spend"] == true {
            if let Some(route) = &research_route {
                if route.model_id.ends_with(":free") {
                    Some(
                        db.query_one(
                            "SELECT reroute_incubator_campaign_research($1,$2)",
                            &[&key, &route.model_id],
                        )
                        .await
                        .map_err(|_| "database_unavailable")?
                        .get(0),
                    )
                } else {
                    Some(run)
                }
            } else {
                Some(run)
            }
        } else {
            Some(run)
        }
    } else {
        None
    };
    let primary = if let Some(existing) = &existing {
        let stored = existing["config"]["model"].as_str().ok_or("invalid_run")?;
        if !model.is_empty() && model != stored {
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
        if existing["archived"] == true {
            return Ok(existing.clone());
        }
        if existing["state"] == "failed" && existing["research_retry_available"] == true {
            event(
                db,
                key,
                "research_retry",
                json!({"reason":"Automatic Research Scout retry after an unusable reply."}),
            )
            .await?;
        } else if ["completed", "failed", "indeterminate"]
            .contains(&existing["state"].as_str().unwrap_or_default())
        {
            return Ok(existing.clone());
        }
        stored
    } else if model.is_empty() {
        let route = research_route
            .as_ref()
            .ok_or("default_model_not_configured")?;
        route.model_id.as_str()
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
pub(crate) fn default_route(
    policy: &crate::model_routing::RoutingPolicy,
) -> Option<&crate::model_routing::Route> {
    policy
        .models
        .iter()
        .find(|m| Some(&m.model_id) == policy.default_model.as_ref())?
        .routes
        .first()
}
pub(crate) fn role_route<'a>(
    policy: &'a crate::model_routing::RoutingPolicy,
    role: &str,
) -> Option<&'a crate::model_routing::Route> {
    let selected = match role {
        "research" => policy.research_model.as_ref(),
        "setup" => policy.setup_model.as_ref(),
        "experiment" => policy.experiment_model.as_ref(),
        _ => None,
    }
    .or(policy.default_model.as_ref());
    policy
        .models
        .iter()
        .find(|m| Some(&m.model_id) == selected)?
        .routes
        .first()
}
fn should_fallback(
    result: &Value,
    route: Option<&crate::model_routing::Route>,
    primary: &str,
) -> bool {
    result["state"] == "failed"
        && route.is_some_and(|r| r.model_id != primary && r.model_id.ends_with(":free"))
}
pub(crate) async fn prepare_model(
    model: &str,
) -> Result<
    (
        OpenRouter,
        u64,
        std::collections::BTreeMap<String, Value>,
        Vec<crate::model_routing::Route>,
    ),
    &'static str,
> {
    prepare_model_with_spend(model, false).await
}
/// Build a dispatcher for a worker-pinned model. Approval and spending authority live in the
/// driver's agent routes and the OpenRouter capacity policy; `manual` only widens `allow_paid`.
pub(crate) async fn prepare_model_with_spend(
    model: &str,
    manual: bool,
) -> Result<
    (
        OpenRouter,
        u64,
        std::collections::BTreeMap<String, Value>,
        Vec<crate::model_routing::Route>,
    ),
    &'static str,
> {
    let provider = OpenRouter::new(model, manual)?;
    let pricing = if model.ends_with(":free") {
        std::collections::BTreeMap::from([
            ("prompt".to_string(), json!("0")),
            ("completion".to_string(), json!("0")),
        ])
    } else {
        std::collections::BTreeMap::new()
    };
    let routes = vec![crate::model_routing::Route {
        provider: "agent-driver".into(),
        model_id: model.into(),
    }];
    Ok((provider, 0, pricing, routes))
}

async fn run_once(
    db: &tokio_postgres::Client,
    key: &str,
    model: &str,
    fallback_of: Option<&str>,
) -> Result<Value, &'static str> {
    let existing: Option<Value> = db
        .query_one("SELECT read_incubator_agent_run($1)", &[&key])
        .await
        .map_err(|_| "database_unavailable")?
        .get(0);
    let run = if let Some(run) = existing {
        run
    } else {
        db.query_one(
            "SELECT admit_incubator_agent_run($1,$2,$3)",
            &[&key, &model, &INPUT_KEY],
        )
        .await
        .map_err(|_| "admission_denied_check_identity_input_or_existing_run")?
        .get(0)
    };
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
        Some("preparing") => {
            return event(
                db,
                key,
                "failed",
                json!({"reason":"interrupted_before_dispatch", "fallback_of":fallback_of}),
            )
            .await
        }
        Some("admitted") | Some("research_retry") => (),
        _ => return Ok(run),
    }
    let manual = run["config"]["manual_model_spend"] == true;
    let campaign = run["config"]["campaign_model_spend"] == true;
    let paid = manual || campaign || !model.ends_with(":free");
    let retrying = run["events"]
        .as_array()
        .is_some_and(|events| events.iter().any(|e| e["state"] == "research_retry"));
    let capacity_key = if retrying {
        format!("research:{key}:retry")
    } else {
        format!("research:{key}")
    };
    let prepared = async {
        let (provider, revision, pricing, routes) = prepare_model_with_spend(model, paid).await?;
        let brief = research_brief(&run["config"]["input"])?;
        let request = provider.adapt_request(&assignment_payload(model, &brief, paid))?;
        Ok::<_, &'static str>((provider, request, revision, pricing, routes))
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
    if !provider
        .admit(
            db,
            &capacity_key,
            &request,
            if manual { "manual" } else { "research" },
        )
        .await?
    {
        return Ok(run);
    }
    event(db, key, "preparing", json!({"fallback_of":fallback_of})).await?;
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
    let (state, mut detail) = if paid {
        provider.send_with_parser(&request, manual_completion).await
    } else {
        provider.send(&request).await
    };
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
        assert!(parse_report(&r.to_string()).is_ok());
        let mut r = report();
        r["evidence_gaps"] = json!([]);
        assert!(parse_report(&r.to_string()).is_err());
        assert!(parse_report(&"x".repeat(24_001)).is_err());
    }
    #[test]
    fn provider_errors_keep_bounded_diagnostics_and_retry_hint_without_credentials() {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(
            "retry-after",
            reqwest::header::HeaderValue::from_static("30"),
        );
        let body = json!({"error":{"message":"Upstream throttled secret-key","metadata":{"error_type":"rate_limit_exceeded","provider_name":"Meta","raw":"sensitive raw response"}}});
        let detail = provider_error_detail(429, &headers, &body, Some("secret-key"));
        assert_eq!(detail["http_status"], 429);
        assert_eq!(detail["retry_after"], "30");
        assert_eq!(detail["serving_provider"], "Meta");
        assert_eq!(detail["provider_message"], "Upstream throttled [redacted]");
        assert!(!detail.to_string().contains("sensitive raw response"));
        assert!(!detail.to_string().contains("secret-key"));
        let long = provider_error_detail(
            400,
            &headers,
            &json!({"error":{"message":"x".repeat(3000)}}),
            None,
        );
        assert_eq!(long["provider_message"].as_str().unwrap().len(), 2000);
    }
    #[test]
    fn research_request_includes_the_question_from_the_title() {
        let brief = research_brief(
            &json!({"title":"Why does an investor like this business?","text":"I must know"}),
        )
        .unwrap();
        let request = assignment_payload("vendor/model", &brief, true);
        assert_eq!(
            request["messages"][1]["content"],
            "Title: Why does an investor like this business?\n\nRequest:\nI must know"
        );
        assert!(research_brief(&json!({"text":"Missing question"})).is_err());
    }
    #[test]
    fn paid_usage_is_parsed_while_transport_admission_owns_spend_authorization() {
        let manual = assignment_payload("vendor/paid", "brief", true);
        assert!(manual["provider"].get("max_price").is_none());
        assert_eq!(manual["provider"]["allow_fallbacks"], true);
        assert_eq!(manual["max_tokens"], 2048);
        let automatic = assignment_payload("vendor/paid", "brief", false);
        assert_eq!(automatic["provider"]["max_price"]["prompt"], 0);
        assert_eq!(automatic["provider"]["allow_fallbacks"], true);
        assert!(manual.get("models").is_none());
        let response = json!({"model":"vendor/paid","usage":{"cost":0.02},
            "choices":[{"finish_reason":"stop","message":{"content":report().to_string()}}]});
        assert_eq!(completion(response.clone(), "vendor/paid").0, "completed");
        let (state, detail) = manual_completion(response, "vendor/paid");
        assert_eq!(state, "completed");
        assert_eq!(detail["usage"]["cost_usd"], 0.02);
    }
    #[test]
    fn request_is_bounded_with_provider_fallback_but_no_tools_or_model_substitution() {
        let p = payload("vendor/model:free", "brief");
        assert_eq!(p["provider"]["allow_fallbacks"], true);
        assert_eq!(p["provider"]["max_price"]["prompt"], 0);
        assert_eq!(p["max_tokens"], 2048);
        assert!(p.get("tools").is_none());
        assert!(p.get("models").is_none());
        assert_eq!(p["response_format"]["type"], "json_schema");
        assert_eq!(
            p["response_format"]["json_schema"]["name"],
            "research_scout"
        );
        assert_eq!(p["reasoning"]["enabled"], false);
        assert_eq!(p["provider"]["require_parameters"], true);
        assert!(p["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains(RESPONSE_CONTRACT));
    }
    #[test]
    fn formatting_repair_keeps_source_and_still_rejects_missing_fields() {
        let valid = report().to_string();
        let mut missing = report();
        missing.as_object_mut().unwrap().remove("experiment");
        let mut wrong_type = report();
        wrong_type["experiment"] = json!("1. Test it");
        for content in [
            format!("```json\n{valid}\n```"),
            format!("Here is the report: {valid}"),
            format!("{valid} {{}}"),
            wrong_type.to_string(),
        ] {
            let response = json!({"model":"vendor/model","choices":[{"finish_reason":"stop","message":{"content":content}}]});
            let (state, detail) = completion(response, "vendor/model");
            assert_eq!(state, "completed", "{content}");
            assert_eq!(detail["response_text"], content);
            assert!(detail.get("report").is_some());
        }
        let response = json!({"model":"vendor/model","choices":[{"finish_reason":"stop","message":{"content":missing.to_string()}}]});
        let (state, detail) = completion(response, "vendor/model");
        assert_eq!(state, "failed");
        assert_eq!(detail["reason"], "invalid_report");
        assert_eq!(detail["response_text"], missing.to_string());
        assert!(detail.get("report").is_none());
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
