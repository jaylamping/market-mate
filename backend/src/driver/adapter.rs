//! Protocol adapters. Every provider speaks OpenAI Chat Completions or Responses; provider quirks
//! are small hooks here so callers never branch on a provider id.
use super::registry::{authorization, read_credentials, Model, Provider};
use crate::openrouter_request::Capabilities;
use reqwest::{header::HeaderValue, Client};
use serde_json::{json, Value};
use std::time::Duration;

/// Outcome of one provider call before worker-level parsing.
#[derive(Debug)]
pub struct Completion {
    pub state: &'static str,
    /// Normalized Chat Completions shaped body on success, bounded diagnostics otherwise.
    pub detail: Value,
}

pub fn client(timeout_secs: u64) -> Result<Client, &'static str> {
    Client::builder()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(timeout_secs))
        .build()
        .map_err(|_| "client_unavailable")
}

fn output_limit(fields: &serde_json::Map<String, Value>) -> Result<u64, &'static str> {
    fields
        .get("max_tokens")
        .or_else(|| fields.get("max_completion_tokens"))
        .or_else(|| fields.get("max_output_tokens"))
        .and_then(Value::as_u64)
        .filter(|n| *n > 0 && *n <= 200_000)
        .ok_or("invalid_output_limit")
}
/// Shape a worker request for a protocol. OpenRouter-only fields (`provider`, `max_price`) are
/// dropped for other providers; catalog capabilities still gate optional formatting when known.
pub fn shape_request(
    protocol: &str,
    capabilities: Option<&Capabilities>,
    request: &Value,
) -> Result<Value, &'static str> {
    if request.get("tools").is_some() || request.get("tool_choice").is_some() {
        return Err("tool_calls_not_permitted");
    }
    let shaped = match capabilities {
        Some(c) if c.supported_parameters.is_some() => c.adapt(request)?,
        _ => request.clone(),
    };
    let mut shaped = shaped;
    let fields = shaped.as_object_mut().ok_or("invalid_model_request")?;
    let limit = output_limit(fields)?;
    match protocol {
        "openai_chat" => {
            if capabilities.is_none() {
                fields.remove("provider");
                fields.remove("reasoning");
                fields.remove("max_completion_tokens");
                fields.insert("max_tokens".into(), json!(limit));
            }
            fields.remove("max_price");
            Ok(shaped)
        }
        "openai_responses" => {
            let messages = fields
                .remove("messages")
                .and_then(|m| m.as_array().cloned())
                .ok_or("invalid_model_request")?;
            let mut instructions = Vec::new();
            let mut input = Vec::new();
            for message in messages {
                let content = message["content"]
                    .as_str()
                    .map(str::to_string)
                    .ok_or("invalid_model_request")?;
                match message["role"].as_str() {
                    Some("system") | Some("developer") => instructions.push(content),
                    Some(role @ ("user" | "assistant")) => {
                        input.push(json!({"role":role,"content":content}))
                    }
                    _ => return Err("invalid_model_request"),
                }
            }
            let mut out = serde_json::Map::new();
            out.insert(
                "model".into(),
                fields.get("model").cloned().unwrap_or(Value::Null),
            );
            if !instructions.is_empty() {
                out.insert("instructions".into(), json!(instructions.join("\n\n")));
            }
            out.insert("input".into(), Value::Array(input));
            out.insert("max_output_tokens".into(), json!(limit));
            if let Some(t) = fields.get("temperature") {
                out.insert("temperature".into(), t.clone());
            }
            if let Some(format) = fields.get("response_format") {
                let text_format = match format["type"].as_str() {
                    Some("json_schema") => {
                        json!({"type":"json_schema","name":format["json_schema"]["name"].as_str().unwrap_or("response"),
                        "schema":format["json_schema"]["schema"],"strict":format["json_schema"]["strict"].as_bool().unwrap_or(true)})
                    }
                    Some("json_object") => json!({"type":"json_object"}),
                    _ => json!({"type":"text"}),
                };
                out.insert("text".into(), json!({"format":text_format}));
            }
            if fields.get("stream") == Some(&json!(true)) {
                out.insert("stream".into(), json!(true));
            }
            out.insert("store".into(), json!(false));
            Ok(Value::Object(out))
        }
        super::cursor_agent::PROTOCOL => super::cursor_agent::shape(fields, limit),
        _ => Err("protocol_unsupported"),
    }
}

fn clean(text: &str, secret: Option<&str>) -> String {
    let redacted = match secret.filter(|k| !k.is_empty()) {
        Some(key) => text.replace(key, "[redacted]"),
        None => text.to_string(),
    };
    redacted
        .chars()
        .filter(|c| !c.is_control())
        .take(2000)
        .collect()
}
/// Bounded, credential-free diagnostics for a non-2xx provider reply.
pub fn error_detail(
    status: u16,
    headers: &reqwest::header::HeaderMap,
    body: &Value,
    secret: Option<&str>,
) -> Value {
    let mut detail = crate::incubator::provider_error_detail(status, headers, body, secret);
    // Z.ai and other Chat-compatible vendors return {"error":{"code":"1302","message":...}}.
    let code = body["error"]["code"]
        .as_str()
        .map(str::to_string)
        .or_else(|| body["error"]["code"].as_i64().map(|c| c.to_string()))
        .or_else(|| body["code"].as_i64().map(|c| c.to_string()));
    if let Some(code) = code.filter(|c| c.len() <= 32) {
        detail["provider_code"] = json!(clean(&code, secret));
    }
    if detail.get("provider_message").is_none() {
        if let Some(text) = body["message"]
            .as_str()
            .or_else(|| body["error"].as_str())
            .filter(|t| !t.trim().is_empty())
        {
            detail["provider_message"] = json!(clean(text, secret));
        }
    }
    detail
}
/// HTTP status plus provider code decide whether the request was rejected or its fate is unknown.
pub fn classify_status(status: u16, detail: &Value) -> &'static str {
    let code = detail["provider_code"].as_str().unwrap_or_default();
    if status == 429 || code == "1302" || code == "1305" {
        return "failed";
    }
    if [400, 401, 402, 403, 404, 413, 422].contains(&status) {
        return "failed";
    }
    "indeterminate"
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
/// Fold a Responses API body into the Chat Completions shape workers already parse.
pub fn normalize_responses(value: &Value) -> Result<Value, &'static str> {
    if value.get("error").is_some_and(|e| !e.is_null()) {
        return Ok(
            json!({"id":safe_id(&value["id"]),"model":safe_id(&value["model"]),"error":value["error"],"choices":[]}),
        );
    }
    let mut text = String::new();
    let mut tool_calls = false;
    for item in value["output"].as_array().into_iter().flatten() {
        match item["type"].as_str() {
            Some("message") => {
                for part in item["content"].as_array().into_iter().flatten() {
                    if let Some(t) = part["text"].as_str() {
                        text.push_str(t);
                    }
                    if part["type"] == "refusal" {
                        if let Some(t) = part["refusal"].as_str() {
                            text.push_str(t);
                        }
                    }
                }
            }
            Some("function_call") | Some("tool_call") => tool_calls = true,
            _ => (),
        }
    }
    let status = value["status"].as_str().unwrap_or("completed");
    let finish = match (status, value["incomplete_details"]["reason"].as_str()) {
        ("completed", _) => "stop",
        (_, Some("max_output_tokens")) => "length",
        _ => "incomplete",
    };
    let usage = &value["usage"];
    let mut message = json!({"role":"assistant","content":text});
    if tool_calls {
        message["tool_calls"] = json!([]);
    }
    Ok(json!({
        "id":safe_id(&value["id"]),"model":safe_id(&value["model"]),"object":"chat.completion",
        "choices":[{"index":0,"finish_reason":finish,"message":message}],
        "usage":{"prompt_tokens":usage["input_tokens"],"completion_tokens":usage["output_tokens"],"total_tokens":usage["total_tokens"],"cost":usage["cost"]}
    }))
}

pub trait ProviderClient {
    fn protocol(&self) -> &'static str;
    fn endpoint(&self, base_url: &str) -> String;
    fn normalize(&self, body: Value) -> Result<Value, &'static str>;
}
pub struct OpenAiChat;
pub struct OpenAiResponses;
impl ProviderClient for OpenAiChat {
    fn protocol(&self) -> &'static str {
        "openai_chat"
    }
    fn endpoint(&self, base_url: &str) -> String {
        format!("{}/chat/completions", base_url.trim_end_matches('/'))
    }
    fn normalize(&self, body: Value) -> Result<Value, &'static str> {
        if body.get("choices").is_none() && body.get("error").is_none() {
            return Err("invalid_provider_response");
        }
        Ok(body)
    }
}
impl ProviderClient for OpenAiResponses {
    fn protocol(&self) -> &'static str {
        "openai_responses"
    }
    fn endpoint(&self, base_url: &str) -> String {
        format!("{}/responses", base_url.trim_end_matches('/'))
    }
    fn normalize(&self, body: Value) -> Result<Value, &'static str> {
        normalize_responses(&body)
    }
}
/// Cursor Cloud Agents: create-and-poll, so `normalize` is never reached through the buffered path
/// and streaming is unsupported; see `cursor_agent`.
pub struct CursorAgent;
impl ProviderClient for CursorAgent {
    fn protocol(&self) -> &'static str {
        super::cursor_agent::PROTOCOL
    }
    fn endpoint(&self, base_url: &str) -> String {
        format!("{}/agents", base_url.trim_end_matches('/'))
    }
    fn normalize(&self, _body: Value) -> Result<Value, &'static str> {
        Err("protocol_unsupported")
    }
}
pub fn adapter_for(protocol: &str) -> Result<Box<dyn ProviderClient + Send + Sync>, &'static str> {
    match protocol {
        "openai_chat" => Ok(Box::new(OpenAiChat)),
        "openai_responses" => Ok(Box::new(OpenAiResponses)),
        super::cursor_agent::PROTOCOL => Ok(Box::new(CursorAgent)),
        _ => Err("protocol_unsupported"),
    }
}

/// One credentialed connection to a provider endpoint.
pub struct Transport {
    pub provider: Provider,
    client: Client,
    auth: HeaderValue,
    secret: String,
}
impl Transport {
    pub fn open(provider: &Provider, timeout_secs: u64) -> Result<Self, &'static str> {
        let (auth, secret) = read_credentials(std::path::Path::new(&provider.credential_path))
            .map_err(|_| "credentials_unavailable")?;
        Ok(Self {
            provider: provider.clone(),
            client: client(timeout_secs)?,
            auth,
            secret,
        })
    }
    pub fn secret(&self) -> Option<&str> {
        Some(self.secret.as_str())
    }
    fn request(&self, method: reqwest::Method, url: &str) -> reqwest::RequestBuilder {
        let mut builder = self
            .client
            .request(method, url)
            .header("Authorization", self.auth.clone())
            .header("Accept", "application/json");
        for (key, value) in self.provider.settings["headers"]
            .as_object()
            .into_iter()
            .flatten()
        {
            if let Some(v) = value.as_str() {
                builder = builder.header(key.as_str(), v);
            }
        }
        builder
    }
    pub async fn get_json(&self, url: &str, cap: usize) -> Result<Value, &'static str> {
        let mut response = self
            .request(reqwest::Method::GET, url)
            .send()
            .await
            .map_err(|_| "connection_failed")?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "connection_failed")? {
            if bytes.len() + chunk.len() > cap {
                return Err("invalid_response");
            }
            bytes.extend_from_slice(&chunk);
        }
        match status {
            200 => serde_json::from_slice(&bytes).map_err(|_| "invalid_response"),
            401 => Err("credentials_rejected"),
            403 => Err("plan_not_active"),
            429 => Err("rate_limited"),
            _ => Err("provider_unavailable"),
        }
    }
    /// POST a JSON body and return status, headers, and the parsed reply (Null when not JSON).
    pub async fn post_json(
        &self,
        url: &str,
        body: &Value,
        cap: usize,
    ) -> Result<(u16, reqwest::header::HeaderMap, Value), &'static str> {
        let mut response = self
            .request(reqwest::Method::POST, url)
            .json(body)
            .send()
            .await
            .map_err(|_| "provider_acceptance_unknown")?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let mut bytes = Vec::new();
        while let Ok(Some(chunk)) = response.chunk().await {
            if bytes.len() + chunk.len() > cap {
                break;
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok((
            status,
            headers,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        ))
    }
    /// Start the provider call; the caller owns the body so streaming and buffered reads share one path.
    pub async fn start(
        &self,
        model: &str,
        shaped: &Value,
    ) -> Result<reqwest::Response, &'static str> {
        if self.provider.protocol_for(model) == super::cursor_agent::PROTOCOL {
            return Err("streaming_unsupported");
        }
        let adapter = adapter_for(self.provider.protocol_for(model))?;
        self.request(
            reqwest::Method::POST,
            &adapter.endpoint(&self.provider.base_url),
        )
        .json(shaped)
        .send()
        .await
        .map_err(|_| "provider_acceptance_unknown")
    }
    pub async fn complete(&self, model: &str, shaped: &Value) -> Completion {
        if self.provider.protocol_for(model) == super::cursor_agent::PROTOCOL {
            return super::cursor_agent::complete(self, shaped).await;
        }
        let adapter = match adapter_for(self.provider.protocol_for(model)) {
            Ok(a) => a,
            Err(reason) => {
                return Completion {
                    state: "failed",
                    detail: json!({"reason":reason}),
                }
            }
        };
        let mut response = match self.start(model, shaped).await {
            Ok(r) => r,
            Err(reason) => {
                return Completion {
                    state: "indeterminate",
                    detail: json!({"reason":reason}),
                }
            }
        };
        let status = response.status().as_u16();
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
            let detail = error_detail(status, &headers, &body, self.secret());
            return Completion {
                state: classify_status(status, &detail),
                detail,
            };
        }
        let mut bytes = Vec::new();
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) if bytes.len() + chunk.len() <= 256_000 => {
                    bytes.extend_from_slice(&chunk)
                }
                Ok(None) => break,
                _ => {
                    return Completion {
                        state: "indeterminate",
                        detail: json!({"reason":"response_unavailable_or_too_large"}),
                    }
                }
            }
        }
        let body: Value = match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(_) => {
                return Completion {
                    state: "indeterminate",
                    detail: json!({"reason":"invalid_provider_response"}),
                }
            }
        };
        match adapter.normalize(body) {
            Ok(response) => Completion {
                state: "completed",
                detail: json!({"http_status":status,"response":response}),
            },
            Err(reason) => Completion {
                state: "indeterminate",
                detail: json!({"reason":reason}),
            },
        }
    }
    pub async fn catalog(&self) -> Result<Vec<Model>, &'static str> {
        let url = match (
            &self.provider.catalog_url,
            self.provider.catalog_source.as_str(),
        ) {
            (Some(url), "live") => url.clone(),
            _ => return Ok(super::registry::static_models(&self.provider)),
        };
        let body = self.get_json(&url, 4_000_000).await?;
        Ok(super::registry::catalog_models(&self.provider, &body))
    }
}
/// Cheap connectivity probe: credentials present, catalog or usage endpoint answers.
pub async fn probe(provider: &Provider) -> Result<&'static str, &'static str> {
    if provider.kind == "catalog_only" {
        let (auth, _) = read_credentials(std::path::Path::new(&provider.credential_path))?;
        let url = provider.status_url.clone().ok_or("not_configured")?;
        let response = client(8)?
            .get(url)
            .header("Authorization", auth)
            .send()
            .await
            .map_err(|_| "connection_failed")?;
        return match response.status().as_u16() {
            200 => Ok("connected"),
            401 | 403 => Err("credentials_rejected"),
            429 => Err("rate_limited"),
            _ => Err("provider_unavailable"),
        };
    }
    let transport = Transport::open(provider, 8).map_err(|_| "not_configured")?;
    let url = provider
        .usage_url
        .clone()
        .or_else(|| provider.catalog_url.clone())
        .or_else(|| provider.status_url.clone())
        .ok_or("not_configured")?;
    transport
        .get_json(&url, 4_000_000)
        .await
        .map(|_| "connected")
}
pub fn header_for_probe(key: &str) -> Result<HeaderValue, &'static str> {
    authorization(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> Value {
        json!({"model":"glm-5.3-flash","messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"Hi"}],
            "max_tokens":2048,"temperature":0.2,"provider":{"allow_fallbacks":true,"max_price":{"prompt":0}},
            "response_format":{"type":"json_schema","json_schema":{"name":"report","strict":true,"schema":{"type":"object"}}}})
    }
    #[test]
    fn chat_shaping_without_catalog_drops_openrouter_fields_and_keeps_bounds() {
        let shaped = shape_request("openai_chat", None, &request()).unwrap();
        assert!(shaped.get("provider").is_none());
        assert_eq!(shaped["max_tokens"], 2048);
        assert_eq!(shaped["response_format"]["type"], "json_schema");
        assert_eq!(shaped["messages"], request()["messages"]);
        let mut tools = request();
        tools["tools"] = json!([]);
        assert_eq!(
            shape_request("openai_chat", None, &tools).unwrap_err(),
            "tool_calls_not_permitted"
        );
        let mut unbounded = request();
        unbounded["max_tokens"] = json!(0);
        assert_eq!(
            shape_request("openai_chat", None, &unbounded).unwrap_err(),
            "invalid_output_limit"
        );
    }
    #[test]
    fn responses_shaping_moves_system_to_instructions_and_schema_to_text_format() {
        let shaped = shape_request("openai_responses", None, &request()).unwrap();
        assert_eq!(shaped["instructions"], "Be brief.");
        assert_eq!(shaped["input"], json!([{"role":"user","content":"Hi"}]));
        assert_eq!(shaped["max_output_tokens"], 2048);
        assert_eq!(shaped["text"]["format"]["type"], "json_schema");
        assert_eq!(shaped["text"]["format"]["name"], "report");
        assert_eq!(shaped["store"], false);
        assert!(shaped.get("messages").is_none() && shaped.get("provider").is_none());
    }
    #[test]
    fn catalog_capabilities_still_gate_optional_formatting() {
        let c: Capabilities =
            serde_json::from_value(json!({"supported_parameters":["max_tokens"]})).unwrap();
        let shaped = shape_request("openai_chat", Some(&c), &request()).unwrap();
        assert!(shaped.get("response_format").is_none());
        assert_eq!(shaped["provider"], request()["provider"]);
    }
    #[test]
    fn responses_body_normalizes_to_chat_shape() {
        let body = json!({"id":"resp_1","model":"muse-spark-1.3-contributor","status":"completed",
            "output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\"a\":1}"}]}],
            "usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}});
        let chat = normalize_responses(&body).unwrap();
        assert_eq!(chat["choices"][0]["message"]["content"], "{\"a\":1}");
        assert_eq!(chat["choices"][0]["finish_reason"], "stop");
        assert_eq!(chat["usage"]["prompt_tokens"], 10);
        assert!(chat["choices"][0]["message"].get("tool_calls").is_none());
        let truncated = json!({"id":"r","model":"m","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]});
        assert_eq!(
            normalize_responses(&truncated).unwrap()["choices"][0]["finish_reason"],
            "length"
        );
        let with_tool = json!({"id":"r","model":"m","status":"completed","output":[{"type":"function_call","name":"x"}]});
        assert!(
            normalize_responses(&with_tool).unwrap()["choices"][0]["message"]
                .get("tool_calls")
                .is_some()
        );
    }
    #[test]
    fn provider_codes_classify_rate_limits_and_redact_secrets() {
        let headers = reqwest::header::HeaderMap::new();
        let body = json!({"error":{"code":"1302","message":"too many requests for key sk-secret"}});
        let detail = error_detail(200, &headers, &body, Some("sk-secret"));
        assert_eq!(detail["provider_code"], "1302");
        assert_eq!(
            detail["provider_message"],
            "too many requests for key [redacted]"
        );
        assert_eq!(classify_status(200, &detail), "failed");
        assert_eq!(classify_status(503, &json!({})), "indeterminate");
        assert_eq!(classify_status(403, &json!({})), "failed");
        let go = json!({"error":"No active Go plan"});
        assert_eq!(
            error_detail(403, &headers, &go, None)["provider_message"],
            "No active Go plan"
        );
    }
    #[test]
    fn adapters_build_protocol_endpoints() {
        assert_eq!(
            adapter_for("openai_chat")
                .unwrap()
                .endpoint("https://opencode.ai/zen/go/v1/"),
            "https://opencode.ai/zen/go/v1/chat/completions"
        );
        assert_eq!(
            adapter_for("openai_responses")
                .unwrap()
                .endpoint("https://opencode.ai/zen/go/v1"),
            "https://opencode.ai/zen/go/v1/responses"
        );
        assert!(adapter_for("anthropic_messages").is_err());
    }
}
