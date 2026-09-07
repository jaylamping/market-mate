//! Structured, redacted driver logs. One JSON line per event; `AGENT_DRIVER_LOG` picks the floor
//! (`debug` shows request/response shapes and every poll; default `info`).
use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::Instant;

const SERVICE: &str = "agent-driver";

fn floor() -> u8 {
    static FLOOR: OnceLock<u8> = OnceLock::new();
    *FLOOR.get_or_init(|| {
        match std::env::var("AGENT_DRIVER_LOG")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str()
        {
            "debug" | "trace" => 0,
            "warn" => 2,
            "error" => 3,
            _ => 1,
        }
    })
}
fn rank(level: &str) -> u8 {
    match level {
        "debug" => 0,
        "info" => 1,
        "warn" => 2,
        _ => 3,
    }
}
pub fn log(level: &str, event: &str, fields: Value) {
    if rank(level) < floor() {
        return;
    }
    crate::logging::log_event(SERVICE, level, event, &fields);
}
pub fn debug(event: &str, fields: Value) {
    log("debug", event, fields);
}
pub fn info(event: &str, fields: Value) {
    log("info", event, fields);
}
pub fn warn(event: &str, fields: Value) {
    log("warn", event, fields);
}
pub fn error(event: &str, fields: Value) {
    log("error", event, fields);
}
pub fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis() as u64
}
/// Bounded description of a request body for logs: shape and sizes, never prompt text.
pub fn request_shape(request: &Value) -> Value {
    let messages = request["messages"]
        .as_array()
        .map(|m| m.len())
        .or_else(|| request["input"].as_array().map(|m| m.len()));
    json!({
        "model": request["model"],
        "messages": messages,
        "bytes": request.to_string().len(),
        "max_tokens": request.get("max_tokens").or_else(|| request.get("max_completion_tokens")).or_else(|| request.get("max_output_tokens")),
        "response_format": request["response_format"]["type"].as_str().or_else(|| request["text"]["format"]["type"].as_str()),
        "stream": request.get("stream").and_then(Value::as_bool).unwrap_or(false),
    })
}
/// Fields worth keeping from a provider reply without echoing the model output.
pub fn response_shape(detail: &Value) -> Value {
    let response = &detail["response"];
    json!({
        "http_status": detail["http_status"],
        "reason": detail["reason"],
        "provider_code": detail["provider_code"],
        "provider_message": detail["provider_message"],
        "retry_after": detail["retry_after"],
        "returned_model": response["model"],
        "finish_reason": response["choices"][0]["finish_reason"],
        "usage": response["usage"],
        "content_chars": response["choices"][0]["message"]["content"].as_str().map(str::len),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shapes_summarize_without_prompt_or_output_text() {
        let shape = request_shape(
            &json!({"model":"m","messages":[{"role":"user","content":"secret prompt"}],"max_tokens":10}),
        );
        assert_eq!(shape["messages"], 1);
        assert_eq!(shape["model"], "m");
        assert!(!shape.to_string().contains("secret prompt"));
        let reply = response_shape(
            &json!({"http_status":200,"response":{"model":"m","choices":[{"finish_reason":"stop","message":{"content":"private answer"}}],"usage":{"total_tokens":3}}}),
        );
        assert_eq!(reply["content_chars"], 14);
        assert_eq!(reply["finish_reason"], "stop");
        assert!(!reply.to_string().contains("private answer"));
    }
}
