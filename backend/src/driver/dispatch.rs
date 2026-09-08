//! Dispatch lifecycle: admit (SQL route walk or OpenRouter delegation), send or stream, classify, record.
use super::adapter::{shape_request, Transport};
use super::log;
use super::openrouter::OpenRouterTransport;
use super::registry::{parse_providers, Model, Provider};
use crate::openrouter_capacity::Permit;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio_postgres::Client;

pub type Db = crate::incubator_requests::Database;
pub async fn database() -> Result<Db, &'static str> {
    crate::incubator_requests::database()
        .await
        .map_err(|_| "database_unavailable")
}
pub fn sql_reason(e: &tokio_postgres::Error, fallback: &'static str) -> &'static str {
    match e.as_db_error().map(|d| d.message()) {
        Some("dispatch_key_conflict") => "dispatch_key_conflict",
        Some("invalid_dispatch_request") => "invalid_dispatch_request",
        Some("invalid_dispatch_outcome") => "invalid_dispatch_outcome",
        Some("unknown_provider") => "unknown_provider",
        Some("invalid_provider_patch") => "invalid_provider_patch",
        Some("unknown_provider_window") => "unknown_provider_window",
        Some("invalid_agent_patch") => "invalid_agent_patch",
        Some("invalid_agent_routes") => "invalid_agent_routes",
        Some("unknown_api_window") => "unknown_api_window",
        Some("delegated_attempt_not_expected") => "delegated_attempt_not_expected",
        _ => fallback,
    }
}

#[derive(Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct DispatchRequest {
    pub key: String,
    pub agent_id: String,
    pub purpose: String,
    pub request: Value,
    #[serde(default)]
    pub allow_paid: bool,
    #[serde(default)]
    pub parent_attempt_id: Option<String>,
    /// Worker-pinned model: the route walk only considers routes serving this id.
    #[serde(default)]
    pub model: Option<String>,
}

enum Channel {
    Native {
        transport: Arc<Transport>,
        model: String,
        shaped: Value,
        kind: String,
    },
    OpenRouter {
        transport: Arc<OpenRouterTransport>,
        permit: Permit,
        request: Value,
    },
}
struct Pending {
    attempt_id: String,
    key: String,
    created: Instant,
    channel: Channel,
}
/// A stream handed to a worker; the worker reports the outcome once it has read the body.
struct Streaming {
    attempt_id: String,
    key: String,
    started: Instant,
    provider_id: String,
    permit: Option<Permit>,
}

#[derive(Default)]
pub struct Driver {
    pending: Mutex<HashMap<String, Pending>>,
    streaming: Mutex<HashMap<String, Streaming>>,
    catalogs: Mutex<HashMap<String, (Instant, Vec<Model>)>>,
    /// Woken after any rate-limit reply so the quota poller re-samples immediately.
    pub repoll: tokio::sync::Notify,
}
impl Driver {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub async fn providers(&self, db: &Client) -> Result<Vec<Provider>, &'static str> {
        let value: Value = db
            .query_one("SELECT read_providers()", &[])
            .await
            .map_err(|_| "registry_unavailable")?
            .get(0);
        Ok(parse_providers(&value))
    }
    pub async fn provider(&self, db: &Client, id: &str) -> Result<Provider, &'static str> {
        self.providers(db)
            .await?
            .into_iter()
            .find(|p| p.id == id)
            .ok_or("unknown_provider")
    }
    /// Catalog with a ten-minute cache; static catalogs never hit the network.
    pub async fn catalog(&self, provider: &Provider) -> Result<Vec<Model>, &'static str> {
        if let Some((at, models)) = self.catalogs.lock().unwrap().get(&provider.id) {
            if at.elapsed() < Duration::from_secs(600) {
                return Ok(models.clone());
            }
        }
        let started = Instant::now();
        let models = if provider.catalog_source == "live" && provider.catalog_url.is_some() {
            Transport::open(provider, 20)?.catalog().await?
        } else {
            super::registry::static_models(provider)
        };
        log::info(
            "catalog.refreshed",
            json!({"provider":provider.id,"models":models.len(),"source":provider.catalog_source,"latency_ms":log::elapsed_ms(started)}),
        );
        self.catalogs
            .lock()
            .unwrap()
            .insert(provider.id.clone(), (Instant::now(), models.clone()));
        Ok(models)
    }
    pub fn forget_catalog(&self, provider_id: &str) {
        self.catalogs.lock().unwrap().remove(provider_id);
    }

    /// Admit one dispatch. Returns the SQL admission envelope plus, when admitted, the request the
    /// driver will actually send so workers can record it before the only POST.
    pub async fn admit(&self, db: &Client, input: &DispatchRequest) -> Result<Value, &'static str> {
        let started = Instant::now();
        let mut result: Value = db
            .query_one(
                "SELECT admit_dispatch($1,$2,$3,$4,$5,$6,$7)",
                &[
                    &input.key,
                    &input.agent_id,
                    &input.purpose,
                    &input.request,
                    &input.allow_paid,
                    &input.parent_attempt_id,
                    &input.model,
                ],
            )
            .await
            .map_err(|e| sql_reason(&e, "admission_unavailable"))?
            .get(0);
        let status = result["status"].as_str().unwrap_or("").to_string();
        let intent_id = result["intent_id"].as_str().unwrap_or("").to_string();
        log::info(
            "dispatch.admission",
            json!({"key":input.key,"agent":input.agent_id,"purpose":input.purpose,"status":status,"intent_id":intent_id,
                "route":result["route"],"skipped":result["skipped"],"reason":result["reason"],"held_until":result["held_until"],
                "pinned_model":input.model,"allow_paid":input.allow_paid,"latency_ms":log::elapsed_ms(started)}),
        );
        match status.as_str() {
            "admitted" => {
                if self.pending.lock().unwrap().contains_key(&intent_id) {
                    return Ok(result);
                }
                let route = result["route"].clone();
                match self.prepare_native(db, input, &route).await {
                    Ok((provider, model, shaped)) => {
                        result["request"] = shaped.clone();
                        result["provider_kind"] = json!(provider.provider.kind);
                        self.pending.lock().unwrap().insert(
                            intent_id.clone(),
                            Pending {
                                attempt_id: result["attempt_id"].as_str().unwrap_or("").into(),
                                key: input.key.clone(),
                                created: Instant::now(),
                                channel: Channel::Native {
                                    kind: provider.provider.kind.clone(),
                                    transport: provider,
                                    model,
                                    shaped,
                                },
                            },
                        );
                        Ok(result)
                    }
                    Err(reason) => {
                        log::warn(
                            "dispatch.prepare_failed",
                            json!({"intent_id":intent_id,"route":route,"reason":reason}),
                        );
                        let attempt = result["attempt_id"].as_str().unwrap_or("").to_string();
                        let _ = db
                            .query_one(
                                "SELECT record_dispatch_outcome($1,$2,$3,$4)",
                                &[
                                    &attempt,
                                    &"failed",
                                    &json!({"reason":reason,"dispatched":false}),
                                    &None::<i64>,
                                ],
                            )
                            .await;
                        Ok(
                            json!({"status":"failed","intent_id":intent_id,"attempt_id":attempt,"reason":reason,"route":route}),
                        )
                    }
                }
            }
            "delegate" => self.delegate(db, input, result).await,
            _ => Ok(result),
        }
    }
    async fn prepare_native(
        &self,
        db: &Client,
        input: &DispatchRequest,
        route: &Value,
    ) -> Result<(Arc<Transport>, String, Value), &'static str> {
        let provider_id = route["provider_id"].as_str().ok_or("route_invalid")?;
        let model = route["model_id"]
            .as_str()
            .ok_or("route_invalid")?
            .to_string();
        let provider = self.provider(db, provider_id).await?;
        let catalog = self.catalog(&provider).await.unwrap_or_default();
        let listed = catalog.iter().find(|m| m.id == model);
        if provider.catalog_source == "live" && !catalog.is_empty() && listed.is_none() {
            return Err("model_unavailable");
        }
        let mut request = input.request.clone();
        request["model"] = json!(model);
        let protocol = provider.protocol_for(&model).to_string();
        let capabilities = listed
            .map(|m| &m.capabilities)
            .filter(|c| c.supported_parameters.is_some());
        let mut shaped = shape_request(&protocol, capabilities, &request)?;
        if protocol == super::cursor_agent::PROTOCOL {
            shaped["name"] = json!(format!("market-mate {} {}", input.agent_id, input.purpose)
                .chars()
                .take(100)
                .collect::<String>());
        }
        let transport = Arc::new(Transport::open(&provider, 120)?);
        log::debug(
            "dispatch.prepared",
            json!({"key":input.key,"provider":provider_id,"model":model,"protocol":protocol,"request":log::request_shape(&shaped)}),
        );
        Ok((transport, model, shaped))
    }
    async fn delegate(
        &self,
        db: &Client,
        input: &DispatchRequest,
        mut result: Value,
    ) -> Result<Value, &'static str> {
        let intent_id = result["intent_id"].as_str().unwrap_or("").to_string();
        let model = result["route"]["model_id"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let manual = input.purpose == "manual";
        let prepared =
            super::openrouter::prepare_model_with_spend(&model, input.allow_paid || manual).await;
        let (transport, revision, pricing, _) = match prepared {
            Ok(v) => v,
            Err(reason) => {
                log::warn(
                    "dispatch.openrouter.prepare_failed",
                    json!({"intent_id":intent_id,"model":model,"reason":reason}),
                );
                return self
                    .hold(db, &intent_id, &format!("blocked:{reason}"), 300)
                    .await;
            }
        };
        let mut request = input.request.clone();
        request["model"] = json!(model);
        let adapted = match transport.adapt_request(&request) {
            Ok(v) => v,
            Err(reason) => {
                return self
                    .hold(db, &intent_id, &format!("blocked:{reason}"), 300)
                    .await
            }
        };
        let permit = match crate::openrouter_capacity::admit(
            db,
            &input.key,
            &adapted,
            &input.purpose,
        )
        .await
        {
            Ok(Some(permit)) => permit,
            Ok(None) => {
                let status = crate::openrouter_capacity::read(db)
                    .await
                    .unwrap_or(Value::Null);
                let waiting = status["waiting"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|w| w["key"] == input.key)
                    .cloned()
                    .unwrap_or(Value::Null);
                let reason = waiting["reason"].as_str().unwrap_or("openrouter_waiting");
                log::info(
                    "dispatch.openrouter.waiting",
                    json!({"intent_id":intent_id,"key":input.key,"reason":reason,"next_eligible_at":waiting["next_eligible_at"]}),
                );
                return self
                    .hold(db, &intent_id, &format!("openrouter:{reason}"), 60)
                    .await;
            }
            Err(reason) => {
                log::warn(
                    "dispatch.openrouter.admission_failed",
                    json!({"intent_id":intent_id,"reason":reason}),
                );
                return self
                    .hold(db, &intent_id, &format!("openrouter:{reason}"), 60)
                    .await;
            }
        };
        let sha = crate::migrate::checksum(&permit.request.to_string());
        let recorded: Value = db
            .query_one(
                "SELECT record_delegated_attempt($1,$2,$3)",
                &[&intent_id, &permit.id, &sha],
            )
            .await
            .map_err(|e| sql_reason(&e, "admission_unavailable"))?
            .get(0);
        result["status"] = json!("admitted");
        result["attempt_id"] = recorded["attempt_id"].clone();
        result["request"] = permit.request.clone();
        result["openrouter_attempt_id"] = json!(permit.id);
        result["trigger"] = json!(permit.trigger);
        result["reserve_nanos"] = json!(permit.reserve_nanos);
        result["policy_revision"] = json!(revision);
        result["pricing"] = json!(pricing);
        result["provider_kind"] = json!(if permit.trigger == "free" {
            "free"
        } else {
            "paid"
        });
        log::info(
            "dispatch.openrouter.admitted",
            json!({"intent_id":intent_id,"attempt_id":result["attempt_id"],"openrouter_attempt_id":permit.id,"model":permit.request["model"],"trigger":permit.trigger,"reserve_nanos":permit.reserve_nanos}),
        );
        self.pending.lock().unwrap().insert(
            intent_id,
            Pending {
                attempt_id: result["attempt_id"].as_str().unwrap_or("").into(),
                key: input.key.clone(),
                created: Instant::now(),
                channel: Channel::OpenRouter {
                    transport: Arc::new(transport),
                    permit,
                    request: adapted,
                },
            },
        );
        Ok(result)
    }
    async fn hold(
        &self,
        db: &Client,
        intent_id: &str,
        reason: &str,
        seconds: i64,
    ) -> Result<Value, &'static str> {
        let until = (chrono::Utc::now() + chrono::Duration::seconds(seconds)).to_rfc3339();
        db.query_one(
            "SELECT hold_dispatch($1,$2::timestamptz,$3)",
            &[&intent_id, &until, &reason],
        )
        .await
        .map(|r| r.get(0))
        .map_err(|_| "admission_unavailable")
    }

    fn take(&self, intent_id: &str) -> Result<Pending, &'static str> {
        let pending = self
            .pending
            .lock()
            .unwrap()
            .remove(intent_id)
            .ok_or("dispatch_permit_required")?;
        if pending.created.elapsed() > Duration::from_secs(30) {
            return Err("dispatch_send_window_expired");
        }
        Ok(pending)
    }
    /// Perform the provider call for an admitted intent and record its outcome.
    pub async fn send(&self, db: &Client, intent_id: &str) -> Result<Value, &'static str> {
        let pending = match self.take(intent_id) {
            Ok(p) => p,
            Err(reason) => {
                log::warn(
                    "dispatch.send.rejected",
                    json!({"intent_id":intent_id,"reason":reason}),
                );
                return Ok(
                    json!({"state":"indeterminate","detail":{"reason":reason,"dispatched":false}}),
                );
            }
        };
        let started = Instant::now();
        let _ = db
            .query("SELECT mark_dispatched($1)", &[&pending.attempt_id])
            .await;
        let (state, mut detail, cost) = match pending.channel {
            Channel::Native {
                transport,
                model,
                shaped,
                kind,
            } => {
                let completion = transport.complete(&model, &shaped).await;
                let (state, detail) =
                    classify_native(completion.state, completion.detail, &model, &kind);
                (state, detail, None)
            }
            Channel::OpenRouter {
                transport,
                permit,
                request,
            } => {
                let (state, detail, _) = transport.send(permit, &request).await;
                let cost = detail["capacity"]["cost_nanos"].as_i64();
                (state, detail, cost)
            }
        };
        detail["latency_ms"] = json!(log::elapsed_ms(started));
        detail["attempt_id"] = json!(pending.attempt_id);
        if detail["http_status"] == 429
            || matches!(
                detail["provider_code"].as_str(),
                Some("1302") | Some("1305")
            )
        {
            self.repoll.notify_one();
        }
        let stored = stored_detail(&detail);
        if let Err(e) = db
            .query_one(
                "SELECT record_dispatch_outcome($1,$2,$3,$4)",
                &[&pending.attempt_id, &state, &stored, &cost],
            )
            .await
        {
            log::error(
                "dispatch.outcome.record_failed",
                json!({"intent_id":intent_id,"attempt_id":pending.attempt_id,"error":sql_reason(&e,"outcome_unavailable")}),
            );
        }
        log::info(
            "dispatch.outcome",
            json!({"intent_id":intent_id,"attempt_id":pending.attempt_id,"key":pending.key,"state":state,"latency_ms":detail["latency_ms"],"cost_nanos":cost,"reply":log::response_shape(&detail)}),
        );
        Ok(
            json!({"state":state,"detail":detail,"intent_id":intent_id,"attempt_id":pending.attempt_id}),
        )
    }
    /// Start the provider call and hand the raw upstream response to the worker (SSE passthrough).
    pub async fn stream(
        &self,
        db: &Client,
        intent_id: &str,
    ) -> Result<reqwest::Response, &'static str> {
        let pending = self.take(intent_id)?;
        let _ = db
            .query("SELECT mark_dispatched($1)", &[&pending.attempt_id])
            .await;
        let (response, provider_id, permit) = match pending.channel {
            Channel::Native {
                transport,
                model,
                mut shaped,
                ..
            } => {
                shaped["stream"] = json!(true);
                let response = transport.start(&model, &shaped).await;
                (response, transport.provider.id.clone(), None)
            }
            Channel::OpenRouter {
                transport, permit, ..
            } => {
                let response = transport.start(&permit).await;
                (response, "openrouter".to_string(), Some(permit))
            }
        };
        match response {
            Ok(response) => {
                log::info(
                    "dispatch.stream.started",
                    json!({"intent_id":intent_id,"attempt_id":pending.attempt_id,"provider":provider_id,"http_status":response.status().as_u16()}),
                );
                self.streaming.lock().unwrap().insert(
                    intent_id.to_string(),
                    Streaming {
                        attempt_id: pending.attempt_id,
                        key: pending.key,
                        started: Instant::now(),
                        provider_id,
                        permit,
                    },
                );
                Ok(response)
            }
            Err(reason) => {
                log::warn(
                    "dispatch.stream.not_started",
                    json!({"intent_id":intent_id,"reason":reason}),
                );
                let _ = db
                    .query_one(
                        "SELECT record_dispatch_outcome($1,$2,$3,$4)",
                        &[
                            &pending.attempt_id,
                            &"indeterminate",
                            &json!({"reason":reason}),
                            &None::<i64>,
                        ],
                    )
                    .await;
                Err(reason)
            }
        }
    }
    /// Worker-reported outcome for a streamed dispatch (or a cancellation before send).
    pub async fn outcome(
        &self,
        db: &Client,
        intent_id: &str,
        state: &str,
        mut detail: Value,
    ) -> Result<Value, &'static str> {
        if !["completed", "failed", "indeterminate", "cancelled"].contains(&state) {
            return Err("invalid_dispatch_outcome");
        }
        let cancelled = self.pending.lock().unwrap().remove(intent_id);
        if let Some(pending) = cancelled {
            if let Channel::OpenRouter { permit, .. } = pending.channel {
                let _ = db
                    .query_one("SELECT cancel_openrouter_capacity($1)", &[&permit.key])
                    .await;
            }
            log::info(
                "dispatch.cancelled_before_send",
                json!({"intent_id":intent_id,"attempt_id":pending.attempt_id,"state":state}),
            );
            let stored = stored_detail(&detail);
            return db
                .query_one(
                    "SELECT record_dispatch_outcome($1,$2,$3,$4)",
                    &[&pending.attempt_id, &"cancelled", &stored, &None::<i64>],
                )
                .await
                .map(|r| r.get(0))
                .map_err(|e| sql_reason(&e, "outcome_unavailable"));
        }
        let streaming = self
            .streaming
            .lock()
            .unwrap()
            .remove(intent_id)
            .ok_or("dispatch_not_streaming")?;
        let mut cost = None;
        if let Some(permit) = &streaming.permit {
            if crate::openrouter_capacity::finish(permit, state, &mut detail)
                .await
                .is_err()
            {
                detail["capacity_result_unavailable"] = json!(true);
            }
            cost = detail["capacity"]["cost_nanos"].as_i64();
        }
        detail["latency_ms"] = json!(log::elapsed_ms(streaming.started));
        let stored = stored_detail(&detail);
        log::info(
            "dispatch.stream.outcome",
            json!({"intent_id":intent_id,"attempt_id":streaming.attempt_id,"key":streaming.key,"provider":streaming.provider_id,"state":state,"latency_ms":detail["latency_ms"],"cost_nanos":cost,"reply":log::response_shape(&detail)}),
        );
        db.query_one(
            "SELECT record_dispatch_outcome($1,$2,$3,$4)",
            &[&streaming.attempt_id, &state, &stored, &cost],
        )
        .await
        .map(|r| r.get(0))
        .map_err(|e| sql_reason(&e, "outcome_unavailable"))
    }
    /// Drop admitted-but-never-sent permits and stale streams; SQL marks their attempts indeterminate.
    pub async fn sweep(&self, db: &Client) {
        let stale: Vec<(String, String, Option<String>)> = {
            let mut pending = self.pending.lock().unwrap();
            let keys: Vec<_> = pending
                .iter()
                .filter(|(_, p)| p.created.elapsed() > Duration::from_secs(120))
                .map(|(k, _)| k.clone())
                .collect();
            keys.into_iter()
                .filter_map(|k| {
                    pending.remove(&k).map(|p| {
                        (
                            k,
                            p.attempt_id,
                            match p.channel {
                                Channel::OpenRouter { permit, .. } => Some(permit.key),
                                _ => None,
                            },
                        )
                    })
                })
                .collect()
        };
        for (intent_id, attempt_id, capacity_key) in stale {
            log::warn(
                "dispatch.permit.expired",
                json!({"intent_id":intent_id,"attempt_id":attempt_id}),
            );
            if let Some(key) = capacity_key {
                let _ = db
                    .query_one("SELECT cancel_openrouter_capacity($1)", &[&key])
                    .await;
            }
            let _ = db
                .query_one(
                    "SELECT record_dispatch_outcome($1,$2,$3,$4)",
                    &[
                        &attempt_id,
                        &"failed",
                        &json!({"reason":"dispatch_send_window_expired","dispatched":false}),
                        &None::<i64>,
                    ],
                )
                .await;
        }
        self.streaming
            .lock()
            .unwrap()
            .retain(|_, s| s.started.elapsed() < Duration::from_secs(900));
        match db.query_one("SELECT expire_dispatch_attempts()", &[]).await {
            Ok(row) => {
                let expired: i32 = row.get(0);
                if expired > 0 {
                    log::warn("dispatch.attempts.expired", json!({"count":expired}));
                }
            }
            Err(_) => log::error("dispatch.sweep.failed", json!({})),
        }
    }
}

/// Uniform post-transport classification for non-OpenRouter providers.
pub fn classify_native(
    state: &'static str,
    mut detail: Value,
    model: &str,
    kind: &str,
) -> (&'static str, Value) {
    if state != "completed" {
        return (state, detail);
    }
    let response = detail["response"].clone();
    if response.get("error").is_some_and(|e| !e.is_null()) {
        detail["reason"] = json!("provider_error");
        detail["provider_message"] = response["error"]["message"].clone();
        return ("failed", detail);
    }
    let returned = response["model"].as_str().unwrap_or_default();
    if !returned.is_empty() && returned != model && !returned.starts_with(model) {
        detail["reason"] = json!("unexpected_model");
        detail["returned_model"] = json!(returned);
        return ("failed", detail);
    }
    let cost = response["usage"]["cost"].as_f64().filter(|c| c.is_finite());
    if kind != "paid" && cost.is_some_and(|c| c > 0.0) {
        detail["reason"] = json!("unexpected_provider_charge");
        return ("indeterminate", detail);
    }
    detail["usage"] = response["usage"].clone();
    detail["returned_model"] = json!(returned);
    (state, detail)
}
/// What the ledger keeps: everything except the model's text, which workers store in their own events.
pub fn stored_detail(detail: &Value) -> Value {
    let mut stored = detail.clone();
    if let Some(response) = stored.get_mut("response") {
        let content_chars = response["choices"][0]["message"]["content"]
            .as_str()
            .map(str::len);
        *response = json!({"id":response["id"],"model":response["model"],"finish_reason":response["choices"][0]["finish_reason"],"usage":response["usage"],"content_chars":content_chars});
    }
    if let Some(fields) = stored.as_object_mut() {
        for key in [
            "authority",
            "lifecycle_state",
            "execution_authority",
            "paper",
            "live",
            "broker",
        ] {
            fields.remove(key);
        }
    }
    stored
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_classification_flags_model_swaps_and_charges_on_subscriptions() {
        let ok = json!({"http_status":200,"response":{"model":"glm-5.3-flash","choices":[{"finish_reason":"stop","message":{"content":"x"}}],"usage":{"total_tokens":3}}});
        let (state, detail) =
            classify_native("completed", ok.clone(), "glm-5.3-flash", "subscription");
        assert_eq!(state, "completed");
        assert_eq!(detail["usage"]["total_tokens"], 3);
        let mut swapped = ok.clone();
        swapped["response"]["model"] = json!("glm-5.3");
        assert_eq!(
            classify_native("completed", swapped, "glm-5.3-flash", "subscription").0,
            "failed"
        );
        let mut charged = ok.clone();
        charged["response"]["usage"]["cost"] = json!(0.001);
        let (state, detail) =
            classify_native("completed", charged.clone(), "glm-5.3-flash", "free");
        assert_eq!(
            (state, detail["reason"].as_str()),
            ("indeterminate", Some("unexpected_provider_charge"))
        );
        assert_eq!(
            classify_native("completed", charged, "glm-5.3-flash", "paid").0,
            "completed"
        );
        assert_eq!(
            classify_native("indeterminate", json!({"reason":"x"}), "m", "free").0,
            "indeterminate"
        );
    }
    #[test]
    fn stored_detail_keeps_usage_but_never_model_text() {
        let detail = json!({"http_status":200,"latency_ms":5,"response":{"id":"g","model":"m","choices":[{"finish_reason":"stop","message":{"content":"private"}}],"usage":{"total_tokens":1}},"live":true});
        let stored = stored_detail(&detail);
        assert_eq!(stored["response"]["content_chars"], 7);
        assert_eq!(stored["response"]["usage"]["total_tokens"], 1);
        assert!(!stored.to_string().contains("private"));
        assert!(stored.get("live").is_none());
    }
}
