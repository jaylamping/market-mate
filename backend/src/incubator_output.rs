//! Bounded provider evidence and strict envelopes for non-authoritative JSON tasks.
use serde_json::{json, Value};

pub(crate) fn diagnostics(value: &Value) -> Value {
    let mut detail = json!({"usage":value["usage"],"generation_id":value["id"],
        "returned_model":value["model"],"finish_reason":value["choices"][0]["finish_reason"]});
    if let Some(content) = value["choices"][0]["message"]["content"].as_str() {
        let mut end = content.len().min(12_000);
        while !content.is_char_boundary(end) {
            end -= 1;
        }
        while serde_json::to_string(&content[..end]).unwrap().len() > 16_000 {
            end -= 1;
            while !content.is_char_boundary(end) {
                end -= 1;
            }
        }
        detail["response_text"] = json!(&content[..end]);
        detail["response_truncated"] = json!(end < content.len());
    }
    detail
}

pub(crate) fn content<'a>(
    value: &'a Value,
    requested: &str,
    limit: usize,
) -> Result<&'a str, String> {
    let returned = value["model"].as_str().unwrap_or_default();
    let choice = &value["choices"][0];
    if value.get("error").is_some_and(|e| !e.is_null()) {
        return Err("Provider returned an error envelope.".into());
    }
    if returned != requested && Some(returned) != requested.strip_suffix(":free") {
        return Err("Returned model does not match the authorized model.".into());
    }
    if choice["finish_reason"] != "stop" {
        return Err(format!(
            "Response did not finish normally (finish_reason: {}).",
            choice["finish_reason"]
        ));
    }
    if choice["message"]
        .get("tool_calls")
        .is_some_and(|v| !v.is_null() && v.as_array().is_none_or(|a| !a.is_empty()))
    {
        return Err("Tool calls are not permitted for this response.".into());
    }
    let content = choice["message"]["content"]
        .as_str()
        .ok_or("Response content must be a JSON string.")?;
    if content.len() > limit {
        return Err(format!("Response exceeds the {limit}-byte limit."));
    }
    Ok(content)
}

pub(crate) fn response_format(name: &str, schema: Value) -> Value {
    json!({"type":"json_schema","json_schema":{"name":name,"strict":true,"schema":schema}})
}
