//! Worker-side facade over the agent driver HTTP API. Keeps the admit → take_permit → send shape the
//! incubator workers already use, so cutting a worker over is a type change, not a rewrite.
use serde_json::{json, Value};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

pub struct Permit {
    /// Driver intent id; one per dispatch key.
    pub id: String,
    pub attempt_id: String,
    pub key: String,
    pub purpose: String,
    /// The request the driver will send (route model applied, protocol shaped).
    pub request: Value,
    pub original_hash: String,
    pub created: Instant,
    pub reserve_nanos: i64,
    pub trigger: String,
    pub route: Value,
    pub pricing: Value,
    pub policy_revision: Value,
}

pub fn agent_for_purpose(purpose: &str) -> &'static str {
    match purpose {
        "research" | "manual" => "research_scout",
        "ticket_creator" => "ticket_creator",
        "similarity" => "similarity",
        "evaluation" => "evaluator",
        "refinement" => "refiner",
        "experiment" => "experiment",
        "setup" => "ticket_creator",
        _ => "research_scout",
    }
}
pub fn base_url() -> Result<String, &'static str> {
    let url = std::env::var("AGENT_DRIVER_URL").map_err(|_| "agent_driver_unconfigured")?;
    if !(url.starts_with("http://") || url.starts_with("https://")) || url.len() > 200 {
        return Err("agent_driver_unconfigured");
    }
    Ok(url.trim_end_matches('/').to_string())
}
fn http(timeout: Option<Duration>) -> Result<reqwest::Client, &'static str> {
    let mut builder = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(3));
    if let Some(timeout) = timeout {
        builder = builder.timeout(timeout);
    }
    builder.build().map_err(|_| "client_unavailable")
}

pub struct Dispatcher {
    base: String,
    agent: Mutex<Option<String>>,
    model: String,
    manual: bool,
    permit: Mutex<Option<Permit>>,
}
impl Dispatcher {
    pub fn new(model: &str, manual: bool) -> Result<Self, &'static str> {
        if model.is_empty() || model.len() > 256 {
            return Err("model_unavailable");
        }
        Ok(Self {
            base: base_url()?,
            agent: Mutex::new(None),
            model: model.to_string(),
            manual,
            permit: Mutex::new(None),
        })
    }
    /// Pin the agent instead of deriving it from the capacity purpose (owner chat, tests).
    pub fn with_agent(self, agent: &str) -> Self {
        *self.agent.lock().unwrap() = Some(agent.to_string());
        self
    }
    pub fn model(&self) -> &str {
        &self.model
    }
    /// Shaping happens in the driver per protocol; workers keep the OpenAI-style request they build.
    pub fn adapt_request(&self, request: &Value) -> Result<Value, &'static str> {
        if !request.is_object() {
            return Err("invalid_model_request");
        }
        if request.get("tools").is_some() || request.get("tool_choice").is_some() {
            return Err("tool_calls_not_permitted");
        }
        Ok(request.clone())
    }
    async fn post(
        &self,
        path: &str,
        body: &Value,
        timeout: Duration,
    ) -> Result<(u16, Value), &'static str> {
        let mut response = http(Some(timeout))?
            .post(format!("{}{path}", self.base))
            .json(body)
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    "agent_driver_timeout"
                } else {
                    "agent_driver_unavailable"
                }
            })?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "agent_driver_unavailable")?
        {
            if bytes.len() + chunk.len() > 512_000 {
                return Err("agent_driver_response_too_large");
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok((
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        ))
    }
    /// Admission through the driver. `true` means a permit is held and one send is authorized.
    pub async fn admit(
        &self,
        _db: &tokio_postgres::Client,
        key: &str,
        request: &Value,
        purpose: &str,
    ) -> Result<bool, &'static str> {
        let agent = self
            .agent
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| agent_for_purpose(purpose).to_string());
        let mut body = request.clone();
        body.as_object_mut()
            .ok_or("invalid_model_request")?
            .remove("model");
        let (status, result) = self
            .post(
                "/dispatch",
                &json!({"key":key,"agent_id":agent,"purpose":purpose,"request":body,"allow_paid":self.manual,"model":self.model}),
                Duration::from_secs(60),
            )
            .await?;
        if status == 409 {
            return Err(match result["error"].as_str() {
                Some("dispatch_key_conflict") => "capacity_request_changed",
                _ => "capacity_attempt_already_dispatched",
            });
        }
        if status >= 500 || status == 0 {
            return Err("capacity_unavailable");
        }
        match result["status"].as_str() {
            Some("admitted") => {
                let permit = Permit {
                    id: result["intent_id"]
                        .as_str()
                        .ok_or("capacity_receipt_missing")?
                        .into(),
                    attempt_id: result["attempt_id"].as_str().unwrap_or_default().into(),
                    key: key.into(),
                    purpose: purpose.into(),
                    request: if result["request"].is_object() {
                        result["request"].clone()
                    } else {
                        request.clone()
                    },
                    original_hash: crate::migrate::checksum(&request.to_string()),
                    created: Instant::now(),
                    reserve_nanos: result["reserve_nanos"].as_i64().unwrap_or(0),
                    trigger: result["trigger"]
                        .as_str()
                        .map(str::to_string)
                        .unwrap_or_else(|| {
                            result["route"]["tier"]
                                .as_str()
                                .unwrap_or("route")
                                .to_string()
                        }),
                    route: result["route"].clone(),
                    pricing: result["pricing"].clone(),
                    policy_revision: result["policy_revision"].clone(),
                };
                *self.permit.lock().map_err(|_| "capacity_unavailable")? = Some(permit);
                Ok(true)
            }
            Some("held") | Some("blocked") | Some("queued") => Ok(false),
            Some("failed") => Err(result["reason"]
                .as_str()
                .map(leak_reason)
                .unwrap_or("dispatch_failed")),
            Some(_) => Ok(false),
            None => Err("capacity_unavailable"),
        }
    }
    pub fn take_permit(&self, request: &Value) -> Result<Permit, &'static str> {
        let permit = self
            .permit
            .lock()
            .map_err(|_| "capacity_unavailable")?
            .take()
            .ok_or("capacity_permit_required")?;
        if permit.original_hash != crate::migrate::checksum(&request.to_string()) {
            return Err("capacity_request_changed");
        }
        Ok(permit)
    }
    pub fn permit_route(&self) -> Option<Value> {
        self.permit.lock().ok()?.as_ref().map(|p| p.route.clone())
    }
    pub async fn send(&self, request: &Value) -> (&'static str, Value) {
        self.send_with_parser(request, crate::incubator::completion)
            .await
    }
    pub async fn send_with_parser(
        &self,
        request: &Value,
        parse: fn(Value, &str) -> (&'static str, Value),
    ) -> (&'static str, Value) {
        self.send_with_parser_until(request, parse, std::future::pending())
            .await
    }
    /// One buffered send. The driver classifies transport outcomes; the worker parser judges content.
    pub async fn send_with_parser_until(
        &self,
        request: &Value,
        parse: fn(Value, &str) -> (&'static str, Value),
        cancelled: impl std::future::Future<Output = &'static str> + Send,
    ) -> (&'static str, Value) {
        let permit = match self.take_permit(request) {
            Ok(p) => p,
            Err(reason) => return ("indeterminate", json!({"reason":reason,"dispatched":false})),
        };
        let requested_model = permit.request["model"]
            .as_str()
            .unwrap_or(&self.model)
            .to_string();
        let path = format!("/dispatch/{}/send", permit.id);
        let empty = json!({});
        // Cursor cloud-agent routes can run for minutes; the driver bounds the run itself.
        let send = self.post(&path, &empty, Duration::from_secs(960));
        let result = tokio::select! {
            biased;
            reason = cancelled => {
                let mut detail = json!({"reason":reason,"cost_pending":true});
                self.decorate(&mut detail, &permit);
                return ("indeterminate", detail);
            }
            result = send => result,
        };
        let (state, mut detail) = match result {
            Ok((status, body)) if (200..300).contains(&status) => {
                let state = body["state"].as_str().unwrap_or("indeterminate");
                let detail = if body["detail"].is_object() {
                    body["detail"].clone()
                } else {
                    json!({"reason":"invalid_driver_response"})
                };
                match state {
                    "completed" => {
                        let response = detail["response"].clone();
                        let (parsed_state, mut parsed) = parse(response, &requested_model);
                        for key in [
                            "http_status",
                            "latency_ms",
                            "capacity",
                            "capacity_attempts",
                            "upstream_request_id",
                            "attempt_id",
                            "paid_recovery_unavailable",
                        ] {
                            if let Some(v) = detail.get(key) {
                                parsed[key] = v.clone();
                            }
                        }
                        (parsed_state, parsed)
                    }
                    "failed" => ("failed", detail),
                    _ => ("indeterminate", detail),
                }
            }
            Ok((status, body)) => (
                "indeterminate",
                json!({"reason":body["error"].as_str().unwrap_or("agent_driver_error"),"driver_status":status}),
            ),
            Err(reason) => ("indeterminate", json!({"reason":reason})),
        };
        self.decorate(&mut detail, &permit);
        (state, detail)
    }
    fn decorate(&self, detail: &mut Value, permit: &Permit) {
        detail["dispatch"] = json!({"intent_id":permit.id,"attempt_id":permit.attempt_id,"route":permit.route,"trigger":permit.trigger,"reserve_nanos":permit.reserve_nanos});
    }
    /// Streaming send: the driver relays the upstream SSE body; the caller must `finish` afterwards.
    pub async fn start(&self, permit: &Permit) -> Result<reqwest::Response, &'static str> {
        if permit.created.elapsed() > Duration::from_secs(25) {
            return Err("capacity_send_window_expired");
        }
        let response = http(None)?
            .post(format!("{}/dispatch/{}/stream", self.base, permit.id))
            .json(&json!({}))
            .send()
            .await
            .map_err(|_| "provider_acceptance_unknown")?;
        if response.status().as_u16() == 409 || response.status().as_u16() == 503 {
            return Err("provider_acceptance_unknown");
        }
        Ok(response)
    }
    pub fn error_detail(
        &self,
        status: u16,
        headers: &reqwest::header::HeaderMap,
        body: &Value,
    ) -> Value {
        super::adapter::error_detail(status, headers, body, None)
    }
    /// Report the outcome of a streamed dispatch, or cancel an admitted one before sending.
    pub async fn finish(
        &self,
        permit: &Permit,
        state: &str,
        detail: &mut Value,
    ) -> Result<(), &'static str> {
        let stored = super::dispatch::stored_detail(detail);
        let (status, result) = self
            .post(
                &format!("/dispatch/{}/outcome", permit.id),
                &json!({"state":state,"detail":stored}),
                Duration::from_secs(20),
            )
            .await
            .map_err(|_| "capacity_result_unavailable")?;
        if !(200..300).contains(&status) {
            return Err("capacity_result_unavailable");
        }
        detail["dispatch"] = json!({"intent_id":permit.id,"attempt_id":permit.attempt_id,"route":permit.route,"trigger":permit.trigger,"recorded":result["status"]});
        if let Some(cost) = result["cost_nanos"].as_i64() {
            detail["capacity"]["cost_nanos"] = json!(cost);
        }
        Ok(())
    }
}
fn leak_reason(reason: &str) -> &'static str {
    match reason {
        "model_unavailable" => "model_unavailable",
        "tool_calls_not_permitted" => "tool_calls_not_permitted",
        "invalid_output_limit" => "invalid_output_limit",
        "protocol_unsupported" => "protocol_unsupported",
        "credentials_unavailable" => "credentials_unavailable",
        _ => "dispatch_failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn purposes_map_to_agents_and_requests_stay_tool_free() {
        assert_eq!(agent_for_purpose("research"), "research_scout");
        assert_eq!(agent_for_purpose("ticket_creator"), "ticket_creator");
        assert_eq!(agent_for_purpose("evaluation"), "evaluator");
        assert_eq!(agent_for_purpose("nonsense"), "research_scout");
        std::env::set_var("AGENT_DRIVER_URL", "http://agent-driver:8083/");
        let dispatcher = Dispatcher::new("glm-5.3-flash", false).unwrap();
        assert_eq!(dispatcher.base, "http://agent-driver:8083");
        assert!(dispatcher.adapt_request(&json!({"tools":[]})).is_err());
        assert!(dispatcher.adapt_request(&json!({"messages":[]})).is_ok());
        assert_eq!(
            dispatcher.take_permit(&json!({})).err(),
            Some("capacity_permit_required")
        );
    }
}
