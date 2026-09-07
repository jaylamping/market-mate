//! Account-wide admission precedes workflow intent; each permit authorizes one send.
use axum::{
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Instant;
use tokio_postgres::Client;

pub(crate) struct Permit {
    pub id: String,
    pub key: String,
    pub purpose: String,
    pub request: Value,
    pub original_hash: String,
    pub created: Instant,
    pub reserve_nanos: i64,
    pub trigger: String,
}

pub(crate) fn limit_scope(detail: &Value) -> &'static str {
    if detail["http_status"] != 429 {
        return "none";
    }
    match detail["rate_limit_limit"]
        .as_str()
        .and_then(|s| s.parse::<u64>().ok())
    {
        Some(20) => "minute",
        Some(50 | 1000) => "daily",
        Some(_) => "unknown",
        None if detail["provider_limit_source"] == "provider"
            || detail["serving_provider"]
                .as_str()
                .is_some_and(|s| !s.is_empty()) =>
        {
            "provider"
        }
        _ => "unknown",
    }
}

fn retry_hint(detail: &Value) -> Option<i64> {
    let now = Utc::now();
    let retry = detail["retry_after"].as_str().and_then(|s| {
        s.parse::<i64>()
            .ok()
            .filter(|v| *v >= 0)
            .and_then(|v| v.checked_mul(1000))
            .or_else(|| {
                DateTime::parse_from_rfc2822(s)
                    .ok()
                    .map(|v| (v.with_timezone(&Utc) - now).num_milliseconds().max(0))
            })
    });
    let reset = detail["rate_limit_reset"]
        .as_str()
        .and_then(|s| s.parse::<i64>().ok())
        .and_then(|v| {
            // Preserve credible epoch seconds or milliseconds; never interpret a small count as an epoch.
            let millis = if v > 1_000_000_000_000 {
                v
            } else if v > 1_000_000_000 {
                v.checked_mul(1000)?
            } else {
                return None;
            };
            let delay = millis.checked_sub(now.timestamp_millis())?;
            (delay >= 0 && delay <= 7 * 86_400_000).then_some(delay)
        });
    retry
        .into_iter()
        .chain(reset)
        .max()
        .map(|v| v.clamp(1000, 7 * 86_400_000))
}

pub(crate) fn retry_millis(detail: &Value) -> i64 {
    retry_hint(detail).unwrap_or(60_000)
}

fn price_nanos(value: &Value) -> Result<i64, &'static str> {
    let price = value
        .as_str()
        .ok_or("price_unavailable")?
        .parse::<f64>()
        .map_err(|_| "price_unavailable")?;
    if !price.is_finite() || price < 0.0 || price > 1.0 {
        return Err("price_unavailable");
    }
    Ok((price * 1_000_000_000.0).ceil() as i64)
}

fn reserve_cost(request: &Value, pricing: &Value) -> Result<i64, &'static str> {
    let prices = pricing.as_object().ok_or("price_unavailable")?;
    let prompt = price_nanos(&pricing["prompt"])?;
    let completion = price_nanos(&pricing["completion"])?;
    for (kind, price) in prices {
        if !["prompt", "completion"].contains(&kind.as_str()) && price_nanos(price)? != 0 {
            return Err("unsupported_paid_price");
        }
    }
    let messages = request["messages"]
        .as_array()
        .ok_or("invalid_paid_request")?;
    if messages.iter().any(|m| !m["content"].is_string())
        || request.get("tools").is_some()
        || request.get("plugins").is_some()
    {
        return Err("unsupported_paid_request");
    }
    let output = request
        .get("max_tokens")
        .or_else(|| request.get("max_completion_tokens"))
        .and_then(Value::as_i64)
        .filter(|n| *n > 0 && *n <= 2048)
        .ok_or("unbounded_paid_output")?;
    // Text bytes bound token count conservatively, with explicit chat-format overhead.
    let input = (serde_json::to_vec(messages)
        .map_err(|_| "invalid_paid_request")?
        .len() as i64)
        .checked_add(4096 + messages.len() as i64 * 256)
        .ok_or("cost_overflow")?;
    input
        .checked_mul(prompt)
        .and_then(|v| {
            completion
                .checked_mul(output)
                .and_then(|o| v.checked_add(o))
        })
        .ok_or("cost_overflow")
}

pub(crate) async fn read(db: &Client) -> Result<Value, &'static str> {
    db.query_one("SELECT read_openrouter_capacity()", &[])
        .await
        .map(|r| r.get(0))
        .map_err(|_| "capacity_unavailable")
}

fn paid_trigger(
    status: &Value,
    primary: &str,
    purpose: &str,
    recovery: bool,
) -> Option<&'static str> {
    let p = &status["policy"];
    if purpose == "ticket_creator" {
        return (!recovery && !primary.ends_with(":free") && p["paid_enabled"] == true)
            .then_some("paid_primary");
    }
    if purpose == "manual" {
        return (!primary.ends_with(":free")).then_some("manual");
    }
    if p["paid_enabled"] != true {
        return None;
    }
    if recovery {
        return (p["paid_finish_on_429"] == true).then_some("finish_after_429");
    }
    if p["prefer_free_models"] == false {
        return Some("paid_primary");
    }
    if status["free_used"].as_i64().is_some_and(|n| n >= 1000) || status["daily_limited"] == true {
        return Some("daily_free_exhausted");
    }
    if status["free_outage"] == true && p["paid_outage_enabled"] == true {
        return Some("free_capacity_unavailable");
    }
    None
}

fn paid_candidates<'a>(policy: &'a Value, purpose: &str) -> Vec<&'a str> {
    let role = match purpose {
        "research" | "refinement" => "research",
        "setup" => "setup",
        "experiment" => "experiment",
        _ => "default",
    };
    let mut candidates = Vec::new();
    for model in [
        policy["paid_role_models"][role].as_str(),
        policy["paid_role_models"]["default"].as_str(),
        policy["paid_model"].as_str(),
    ]
    .into_iter()
    .flatten()
    .chain(
        policy["paid_models"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str),
    ) {
        if policy["paid_models"]
            .as_array()
            .is_some_and(|models| models.iter().any(|v| v == model))
            && !candidates.contains(&model)
        {
            candidates.push(model);
        }
    }
    candidates
}

pub(crate) async fn admit(
    db: &Client,
    key: &str,
    request: &Value,
    purpose: &str,
) -> Result<Option<Permit>, &'static str> {
    let result = admit_route(db, key, request, purpose, false).await;
    match result {
        Err(reason)
            if !matches!(
                reason,
                "capacity_unavailable"
                    | "capacity_queue_unavailable"
                    | "capacity_admission_unavailable"
                    | "capacity_attempt_already_dispatched"
            ) =>
        {
            db.query_one("SELECT defer_openrouter_capacity($1,$2)", &[&key, &reason])
                .await
                .map_err(|_| "capacity_queue_unavailable")?;
            Ok(None)
        }
        other => other,
    }
}

async fn admit_route(
    db: &Client,
    key: &str,
    request: &Value,
    purpose: &str,
    recovery: bool,
) -> Result<Option<Permit>, &'static str> {
    db.query_one(
        "SELECT enqueue_openrouter_capacity($1,$2,$3)",
        &[&key, request, &purpose],
    )
    .await
    .map_err(|_| "capacity_queue_unavailable")?;
    let status = read(db).await?;
    let policy = &status["policy"];
    let primary = request["model"].as_str().ok_or("model_unavailable")?;
    let campaign_free: bool = db
        .query_one("SELECT incubator_campaign_free_work($1)", &[&key])
        .await
        .map_err(|_| "capacity_unavailable")?
        .get(0);
    let trigger = if campaign_free {
        "free"
    } else {
        paid_trigger(&status, primary, purpose, recovery).unwrap_or("free")
    };
    if recovery && trigger != "finish_after_429" {
        return Ok(None);
    }
    let mut actual = request.clone();
    let mut reserve = 0_i64;
    if trigger != "free" && trigger != "manual" {
        let candidates = if purpose == "ticket_creator" {
            if !policy["paid_models"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|m| m == primary)
            {
                return Err("paid_model_not_selected");
            }
            vec![primary]
        } else {
            paid_candidates(policy, purpose)
        };
        let selected = candidates
            .iter()
            .copied()
            .find(|model| {
                !status["models"].as_array().into_iter().flatten().any(|m| {
                    m["model"] == *model
                        && m["cooldown_until"]
                            .as_str()
                            .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
                            .is_some_and(|t| t.with_timezone(&Utc) > Utc::now())
                })
            })
            .or_else(|| candidates.first().copied())
            .ok_or("paid_model_not_selected")?;
        let (provider, _, prices, _) =
            crate::incubator::prepare_model_with_spend(selected, true).await?;
        actual["model"] = json!(selected);
        actual = provider.adapt_request(&actual)?;
        let pricing = serde_json::to_value(prices).map_err(|_| "price_unavailable")?;
        reserve = reserve_cost(&actual, &pricing)?;
        actual["provider"]["max_price"] = json!({"prompt":pricing["prompt"].as_str().unwrap().parse::<f64>().map_err(|_|"price_unavailable")?*1_000_000.0,"completion":pricing["completion"].as_str().unwrap().parse::<f64>().map_err(|_|"price_unavailable")?*1_000_000.0});
    } else if trigger == "free" && !primary.ends_with(":free") {
        return Err("automated_paid_model_not_enabled");
    }
    let model = actual["model"].as_str().ok_or("model_unavailable")?;
    let result: Value = db
        .query_one(
            "SELECT try_openrouter_capacity($1,$2,$3,$4,$5)",
            &[&key, &model, &reserve, &trigger, &actual],
        )
        .await
        .map_err(|_| "capacity_admission_unavailable")?
        .get(0);
    match result["status"].as_str() {
        Some("admitted") => Ok(Some(Permit {
            id: result["attempt_id"]
                .as_str()
                .ok_or("capacity_receipt_missing")?
                .into(),
            key: key.into(),
            purpose: purpose.into(),
            request: actual,
            original_hash: crate::migrate::checksum(&request.to_string()),
            created: Instant::now(),
            reserve_nanos: reserve,
            trigger: trigger.into(),
        })),
        Some("blocked") => {
            let reason = result["reason"].as_str().unwrap_or("capacity_blocked");
            db.query_one("SELECT defer_openrouter_capacity($1,$2)", &[&key, &reason])
                .await
                .map_err(|_| "capacity_queue_unavailable")?;
            Ok(None)
        }
        Some("waiting") => Ok(None),
        _ => Err("capacity_attempt_already_dispatched"),
    }
}

pub(crate) async fn recover(
    original: &Permit,
    request: &Value,
    ordinal: u8,
) -> Result<Option<Permit>, &'static str> {
    if original.purpose == "manual"
        || original.purpose == "ticket_creator"
        || !original.request["model"]
            .as_str()
            .is_some_and(|m| m.ends_with(":free"))
        || !(1..=2).contains(&ordinal)
    {
        return Ok(None);
    }
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| "capacity_unavailable")?;
    let campaign_free: bool = db
        .client
        .query_one("SELECT incubator_campaign_free_work($1)", &[&original.key])
        .await
        .map_err(|_| "capacity_unavailable")?
        .get(0);
    if campaign_free {
        return Ok(None);
    }
    let status = read(&db.client).await?;
    if status["policy"]["paid_enabled"] != true
        || status["policy"]["paid_finish_on_429"] != true
        || status["policy"]["paid_max_fallback_attempts"]
            .as_u64()
            .unwrap_or(0)
            < u64::from(ordinal)
    {
        return Ok(None);
    }
    let key = format!("{}:paid:{ordinal}", original.key);
    // A bounded active-request recovery is not an independently scheduled job.
    // Cancel if not immediately eligible; future workflow work still prefers free.
    let mut result = admit_route(&db.client, &key, request, &original.purpose, true).await;
    if matches!(result, Ok(None)) {
        let status = read(&db.client).await?;
        if let Some(wait) = status["waiting"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|w| w["key"] == key && w["reason"] == "paid_pacing")
        {
            let millis = wait["next_eligible_at"]
                .as_str()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|t| (t.with_timezone(&Utc) - Utc::now()).num_milliseconds());
            if let Some(millis) = millis.filter(|m| *m > 0 && *m <= 12_000) {
                tokio::time::sleep(std::time::Duration::from_millis(millis as u64 + 50)).await;
                result = admit_route(&db.client, &key, request, &original.purpose, true).await;
            }
        }
    }
    if !matches!(result, Ok(Some(_))) {
        db.client
            .query_one("SELECT cancel_openrouter_capacity($1)", &[&key])
            .await
            .map_err(|_| "capacity_queue_unavailable")?;
    }
    result
}

pub(crate) async fn finish(
    permit: &Permit,
    state: &str,
    detail: &mut Value,
) -> Result<(), &'static str> {
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| "capacity_unavailable")?;
    let cost = detail["usage"]["cost"]
        .as_f64()
        .or_else(|| detail["usage"]["cost_usd"].as_f64())
        .or_else(|| detail["provider"]["usage"]["cost"].as_f64());
    let cost = cost
        .filter(|v| v.is_finite() && *v >= 0.0 && *v < 1e6)
        .map(|v| (v * 1e9).ceil() as i64);
    let outcome = json!({"state":state,"cost_nanos":cost,"http_status":detail["http_status"],"limit_scope":limit_scope(detail),"retry_ms":retry_millis(detail),"retry_hint_valid":retry_hint(detail).is_some()});
    db.client
        .query_one(
            "SELECT finish_openrouter_capacity($1,$2)",
            &[&permit.id, &outcome],
        )
        .await
        .map_err(|_| "capacity_result_unavailable")?;
    detail["capacity"] = json!({"attempt_id":permit.id,"model":permit.request["model"],"trigger":permit.trigger,"reserved_nanos":permit.reserve_nanos,"cost_nanos":cost});
    Ok(())
}

type ApiError = (StatusCode, Json<Value>);
fn error(reason: &str) -> ApiError {
    (StatusCode::CONFLICT, Json(json!({"error":reason})))
}
async fn status() -> Result<Json<Value>, ApiError> {
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| error("capacity_unavailable"))?;
    read(&db.client).await.map(Json).map_err(error)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Save {
    expected_revision: i64,
    policy: Value,
}
async fn save(Json(mut input): Json<Save>) -> Result<Json<Value>, ApiError> {
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| error("capacity_unavailable"))?;
    let routing =
        crate::model_routing::stored(std::path::Path::new("/var/lib/model-policy/routing.json"))
            .map_err(error)?
            .ok_or_else(|| error("model_policy_unavailable"))?;
    let routes: Vec<_> = routing
        .models
        .iter()
        .flat_map(|m| &m.routes)
        .filter(|r| r.provider == "openrouter")
        .collect();
    input.policy["free_models"] = json!(routes
        .iter()
        .filter(|r| r.model_id.ends_with(":free"))
        .map(|r| &r.model_id)
        .collect::<Vec<_>>());
    if input.policy["paid_enabled"] == true {
        let models = input.policy["paid_models"]
            .as_array()
            .filter(|m| !m.is_empty())
            .ok_or_else(|| error("paid_fallback_not_selected"))?;
        for model in models {
            let model = model
                .as_str()
                .ok_or_else(|| error("paid_fallback_not_selected"))?;
            if model.ends_with(":free")
                || model.starts_with("openrouter/")
                || !routes.iter().any(|r| r.model_id == model)
                || (input.policy["prefer_free_models"] != false
                    && input.policy["paid_model_open_weights_confirmed"] != true)
            {
                return Err(error("approved_open_weight_model_required"));
            }
            crate::incubator::prepare_model_with_spend(model, true)
                .await
                .map_err(error)?;
        }
    }
    let result: Value = db
        .client
        .query_one(
            "SELECT save_openrouter_capacity($1,$2)",
            &[&input.expected_revision, &input.policy],
        )
        .await
        .map_err(|_| error("invalid_capacity_policy"))?
        .get(0);
    if result["status"] == "conflict" {
        return Err(error("capacity_policy_conflict"));
    }
    Ok(Json(result))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Burst {
    requests: i64,
}
async fn burst(Json(input): Json<Burst>) -> Result<Json<Value>, ApiError> {
    if input.requests < 1 || input.requests > 100 {
        return Err(error("burst_must_be_between_1_and_100"));
    }
    let db = crate::incubator_requests::database()
        .await
        .map_err(|_| error("capacity_unavailable"))?;
    let state = read(&db.client).await.map_err(error)?;
    let revision = state["policy"]["revision"]
        .as_i64()
        .ok_or_else(|| error("capacity_unavailable"))?;
    let mut policy = state["policy"].clone();
    policy["burst_remaining"] = json!(input.requests);
    let value: Value = db
        .client
        .query_one(
            "SELECT save_openrouter_capacity($1,$2)",
            &[&revision, &policy],
        )
        .await
        .map_err(|_| error("capacity_policy_conflict"))?
        .get(0);
    Ok(Json(value))
}
pub fn router() -> Router {
    Router::new()
        .route("/capacity", get(status).put(save))
        .route("/capacity/burst", post(burst))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ticket_creator_keeps_the_selected_model_and_never_recovers_on_another() {
        let status = json!({"policy":{"paid_enabled":true,"prefer_free_models":false,"paid_finish_on_429":true},"daily_limited":true});
        assert_eq!(
            paid_trigger(&status, "v/creator:free", "ticket_creator", false),
            None
        );
        assert_eq!(
            paid_trigger(&status, "v/creator", "ticket_creator", false),
            Some("paid_primary")
        );
        assert_eq!(
            paid_trigger(&status, "v/creator:free", "ticket_creator", true),
            None
        );
    }
    #[test]
    fn preference_switch_controls_automated_routing_but_never_manual_selection() {
        let mut status = json!({"free_used":0,"daily_limited":false,"free_outage":false,"policy":{"prefer_free_models":true,"paid_enabled":false,"paid_finish_on_429":false}});
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", false),
            None
        );
        status["policy"]["prefer_free_models"] = json!(false);
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", false),
            None
        );
        assert_eq!(
            paid_trigger(&status, "vendor/paid", "manual", false),
            Some("manual")
        );
        status["policy"]["paid_enabled"] = json!(true);
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", false),
            Some("paid_primary")
        );
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "manual", false),
            None
        );
        status["policy"]["prefer_free_models"] = json!(true);
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", false),
            None
        );
        status["daily_limited"] = json!(true);
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", false),
            Some("daily_free_exhausted")
        );
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", true),
            None
        );
        status["policy"]["paid_finish_on_429"] = json!(true);
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "research", true),
            Some("finish_after_429")
        );
        assert_eq!(
            paid_trigger(&status, "vendor/model:free", "manual", true),
            None
        );
    }

    #[test]
    fn paid_role_models_resolve_in_order_and_require_allowlisting() {
        let policy = json!({"paid_role_models":{"research":"v/research","setup":"v/setup","experiment":"v/disallowed","default":"v/shared"},"paid_model":"v/primary","paid_models":["v/primary","v/shared","v/research","v/setup"]});
        assert_eq!(
            paid_candidates(&policy, "research"),
            vec!["v/research", "v/shared", "v/primary", "v/setup"]
        );
        assert_eq!(paid_candidates(&policy, "refinement")[0], "v/research");
        assert_eq!(paid_candidates(&policy, "setup")[0], "v/setup");
        assert_eq!(paid_candidates(&policy, "experiment")[0], "v/shared");
        assert_eq!(paid_candidates(&policy, "similarity")[0], "v/shared");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "requires a fresh isolated capacity acceptance database"]
    async fn capacity_concurrent_admission() {
        async fn connect(url: &str) -> Client {
            let (client, connection) = tokio_postgres::connect(url, tokio_postgres::NoTls)
                .await
                .unwrap();
            tokio::spawn(async move {
                connection.await.unwrap();
            });
            client
        }
        let url = std::env::var("DATABASE_URL").unwrap();
        let admin = connect(&url).await;
        admin.batch_execute("UPDATE openrouter_capacity_control SET policy=policy||'{\"mode\":\"burst\"}',next_start=clock_timestamp(); INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment) SELECT 'race-seed:'||g,'race-seed:'||g,'v/free:free',true,0,0,'legacy_inventory',clock_timestamp()-interval '30 seconds','{\"source\":\"openrouter_capacity\",\"entitlement_version\":\"local-research-v1\"}','local_research' FROM generate_series(1,19)g; INSERT INTO openrouter_capacity_result(attempt_id,outcome,receipt_time,source_lineage,record_environment) SELECT attempt_id,'{\"state\":\"completed\",\"cost_nanos\":0}',clock_timestamp(),source_lineage,record_environment FROM openrouter_capacity_attempt WHERE key LIKE 'race-seed:%';").await.unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(25));
        let mut tasks = Vec::new();
        for n in 0..25 {
            let db = connect(&url).await;
            db.batch_execute("SET ROLE incubator_runner").await.unwrap();
            let barrier = barrier.clone();
            tasks.push(tokio::spawn(async move {
                let key = format!("race:{n}");
                let request = crate::incubator::payload("v/free:free", "Capacity test.");
                db.query_one(
                    "SELECT enqueue_openrouter_capacity($1,$2,'research')",
                    &[&key, &request],
                )
                .await
                .unwrap();
                barrier.wait().await;
                let result: Value = db
                    .query_one(
                        "SELECT try_openrouter_capacity($1,'v/free:free',0,'free',$2)",
                        &[&key, &request],
                    )
                    .await
                    .unwrap()
                    .get(0);
                result
            }));
        }
        let mut admitted = 0;
        for task in tasks {
            let result = task.await.unwrap();
            if result["status"] == "admitted" {
                admitted += 1;
            } else {
                assert_eq!(result["status"], "waiting");
            }
        }
        assert_eq!(
            admitted, 1,
            "one remaining minute slot cannot be claimed twice"
        );
        let state = read(&admin).await.unwrap();
        assert_eq!(state["minute_used"], 20);
        assert_eq!(state["in_flight"], 1);
        println!("capacity concurrent admission: 25 contenders, 1 permit, 20 minute commitments");
    }

    #[test]
    fn rate_limit_scope_and_retry_hints_do_not_turn_every_429_into_paid_overflow() {
        assert_eq!(
            limit_scope(&json!({"http_status":429,"rate_limit_limit":"20"})),
            "minute"
        );
        assert_eq!(
            limit_scope(&json!({"http_status":429,"rate_limit_limit":"1000"})),
            "daily"
        );
        assert_eq!(
            limit_scope(&json!({"http_status":429,"serving_provider":"fixture"})),
            "provider"
        );
        assert_eq!(limit_scope(&json!({"http_status":429})), "unknown");
        assert_eq!(retry_millis(&json!({"retry_after":"90"})), 90_000);
        assert_eq!(retry_millis(&json!({"retry_after":"garbage"})), 60_000);
    }

    #[test]
    fn paid_reservations_include_full_input_and_output_and_reject_unknown_prices() {
        let request = json!({"messages":[{"role":"user","content":"hello"}],"max_tokens":2048});
        let pricing = json!({"prompt":"0.0000001","completion":"0.0000002","request":"0"});
        let cost = reserve_cost(&request, &pricing).unwrap();
        assert!(cost >= 409_600);
        assert!(reserve_cost(&request, &json!({"prompt":"0"})).is_err());
        assert!(reserve_cost(&request, &json!({"prompt":"NaN","completion":"0"})).is_err());
        assert!(reserve_cost(
            &request,
            &json!({"prompt":"0","completion":"0","image":"0.01"})
        )
        .is_err());
    }
}
