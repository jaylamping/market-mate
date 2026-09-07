//! Cursor Cloud Agents as an inference provider. Cursor exposes no chat-completions endpoint; a
//! no-repo cloud agent (`POST /v1/agents` without `repos`) runs the prompt on a Cursor VM and the
//! terminal run carries the final assistant text in `result`. This module shapes a worker request
//! into that call, polls the run to a terminal state, and folds the reply back into the Chat
//! Completions shape every worker parser already understands.
//!
//! Reference: https://cursor.com/docs/cloud-agent/api/endpoints (Create An Agent, Get A Run,
//! Get Agent Usage, Archive An Agent). Auth accepts Bearer, which the registry already produces.
use super::adapter::{classify_status, error_detail, Completion, Transport};
use super::log;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

pub const PROTOCOL: &str = "cursor_agent";
const DEFAULT_RUN_TIMEOUT_SECS: u64 = 600;
const DEFAULT_POLL_SECS: u64 = 5;

/// Flatten chat messages into one prompt. Cursor agents take free text, so the JSON contract that
/// `response_format` would enforce elsewhere is stated in the prompt instead.
pub fn shape(fields: &serde_json::Map<String, Value>, limit: u64) -> Result<Value, &'static str> {
    let model = fields
        .get("model")
        .and_then(Value::as_str)
        .filter(|m| !m.is_empty())
        .ok_or("invalid_model_request")?;
    let messages = fields
        .get("messages")
        .and_then(Value::as_array)
        .ok_or("invalid_model_request")?;
    let mut sections: Vec<String> = Vec::new();
    let mut turns = 0;
    for message in messages {
        let content = message["content"].as_str().ok_or("invalid_model_request")?;
        match message["role"].as_str() {
            Some("system") | Some("developer") => sections.push(content.to_string()),
            Some("user") => {
                turns += 1;
                sections.push(content.to_string());
            }
            Some("assistant") => sections.push(format!("Your earlier reply:\n{content}")),
            _ => return Err("invalid_model_request"),
        }
    }
    if turns == 0 {
        return Err("invalid_model_request");
    }
    sections.push(
        "You have no repository for this task. Do not create files, branches, or pull requests; answer in your final message only.".to_string(),
    );
    if let Some(format) = fields.get("response_format") {
        match format["type"].as_str() {
            Some("json_schema") => sections.push(format!(
                "Reply with exactly one JSON object and nothing else: no prose, no code fences. It must validate against this JSON Schema:\n{}",
                format["json_schema"]["schema"]
            )),
            Some("json_object") => sections
                .push("Reply with exactly one JSON object and nothing else.".to_string()),
            _ => (),
        }
    }
    sections.push(format!("Keep the final reply under {limit} tokens."));
    let text = sections.join("\n\n");
    if text.len() > 200_000 {
        return Err("invalid_model_request");
    }
    let name: String = format!(
        "market-mate {}",
        fields
            .get("purpose")
            .and_then(Value::as_str)
            .unwrap_or("dispatch")
    )
    .chars()
    .take(100)
    .collect();
    Ok(json!({"model":{"id":model},"prompt":{"text":text},"name":name}))
}

fn setting_secs(settings: &Value, key: &str, default: u64) -> u64 {
    settings[key]
        .as_u64()
        .filter(|n| (1..=3600).contains(n))
        .unwrap_or(default)
}

/// Strip a single ```json fence so JSON-contract parsers see the object itself.
pub fn strip_fences(text: &str) -> &str {
    let trimmed = text.trim();
    let Some(rest) = trimmed.strip_prefix("```") else {
        return trimmed;
    };
    let rest = rest.strip_prefix("json").unwrap_or(rest);
    let rest = rest.trim_start_matches(['\r', '\n']);
    rest.strip_suffix("```").map(str::trim).unwrap_or(trimmed)
}

/// Chat Completions shape for a terminal run so `classify_native` and worker parsers apply unchanged.
pub fn normalize(model: &str, agent_id: &str, run: &Value, usage: &Value) -> Value {
    let text = strip_fences(run["result"].as_str().unwrap_or_default());
    let totals = &usage["totals"];
    json!({
        "id":agent_id,"model":model,"object":"chat.completion",
        "choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":text}}],
        "usage":{"prompt_tokens":totals["inputTokens"],"completion_tokens":totals["outputTokens"],"total_tokens":totals["totalTokens"],
            "cache_read_tokens":totals["cacheReadTokens"],"cost":Value::Null},
        "cursor":{"agent_id":agent_id,"run_id":run["id"],"duration_ms":run["durationMs"]}
    })
}

fn failure(state: &'static str, reason: &str, extra: Value) -> Completion {
    let mut detail = json!({"reason":reason});
    if let Some(fields) = extra.as_object() {
        for (k, v) in fields {
            detail[k] = v.clone();
        }
    }
    Completion { state, detail }
}

/// Create the agent, poll its initial run to a terminal state, read usage, archive.
pub async fn complete(transport: &Transport, shaped: &Value) -> Completion {
    let started = Instant::now();
    let base = transport.provider.base_url.trim_end_matches('/');
    let model = shaped["model"]["id"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let (status, headers, body) = match transport
        .post_json(&format!("{base}/agents"), shaped, 64_000)
        .await
    {
        Ok(reply) => reply,
        Err(reason) => return failure("indeterminate", reason, Value::Null),
    };
    if !(200..300).contains(&status) {
        let detail = error_detail(status, &headers, &body, transport.secret());
        return Completion {
            state: classify_status(status, &detail),
            detail,
        };
    }
    let agent_id = body["agent"]["id"]
        .as_str()
        .or_else(|| body["id"].as_str())
        .unwrap_or_default()
        .to_string();
    let run_id = body["run"]["id"]
        .as_str()
        .or_else(|| body["latestRunId"].as_str())
        .unwrap_or_default()
        .to_string();
    if agent_id.is_empty() || run_id.is_empty() {
        return failure(
            "indeterminate",
            "invalid_provider_response",
            json!({"http_status":status}),
        );
    }
    log::info(
        "cursor.agent.created",
        json!({"agent_id":agent_id,"run_id":run_id,"model":model,"latency_ms":log::elapsed_ms(started)}),
    );
    let settings = &transport.provider.settings;
    let deadline = Duration::from_secs(setting_secs(
        settings,
        "run_timeout_secs",
        DEFAULT_RUN_TIMEOUT_SECS,
    ));
    let poll = Duration::from_secs(setting_secs(
        settings,
        "poll_interval_secs",
        DEFAULT_POLL_SECS,
    ));
    let run_url = format!("{base}/agents/{agent_id}/runs/{run_id}");
    let mut polls = 0u32;
    let mut misses = 0u32;
    let run = loop {
        tokio::time::sleep(poll).await;
        polls += 1;
        match transport.get_json(&run_url, 256_000).await {
            Ok(run) => {
                misses = 0;
                match run["status"].as_str().unwrap_or_default() {
                    "FINISHED" => break run,
                    "ERROR" => {
                        log::warn(
                            "cursor.run.error",
                            json!({"agent_id":agent_id,"run_id":run_id,"polls":polls}),
                        );
                        return failure(
                            "failed",
                            "provider_error",
                            json!({"cursor":{"agent_id":agent_id,"run_id":run_id,"status":"ERROR"},"provider_message":run["error"].as_str().unwrap_or("run ended in ERROR")}),
                        );
                    }
                    "CANCELLED" | "EXPIRED" => {
                        return failure(
                            "indeterminate",
                            "provider_run_terminated",
                            json!({"cursor":{"agent_id":agent_id,"run_id":run_id,"status":run["status"]}}),
                        );
                    }
                    _ => (),
                }
            }
            Err(reason) => {
                misses += 1;
                log::debug(
                    "cursor.run.poll_failed",
                    json!({"agent_id":agent_id,"run_id":run_id,"reason":reason,"misses":misses}),
                );
                if misses >= 6 {
                    return failure(
                        "indeterminate",
                        "provider_acceptance_unknown",
                        json!({"cursor":{"agent_id":agent_id,"run_id":run_id},"poll_error":reason}),
                    );
                }
            }
        }
        if started.elapsed() > deadline {
            log::warn(
                "cursor.run.timeout",
                json!({"agent_id":agent_id,"run_id":run_id,"polls":polls,"deadline_secs":deadline.as_secs()}),
            );
            let _ = transport
                .post_json(&format!("{run_url}/cancel"), &json!({}), 16_000)
                .await;
            return failure(
                "indeterminate",
                "provider_run_timeout",
                json!({"cursor":{"agent_id":agent_id,"run_id":run_id,"cancel_requested":true}}),
            );
        }
    };
    let usage = transport
        .get_json(
            &format!("{base}/agents/{agent_id}/usage?runId={run_id}"),
            64_000,
        )
        .await
        .unwrap_or(Value::Null);
    if settings["archive_after_run"].as_bool().unwrap_or(true) {
        let _ = transport
            .post_json(
                &format!("{base}/agents/{agent_id}/archive"),
                &json!({}),
                16_000,
            )
            .await;
    }
    let response = normalize(&model, &agent_id, &run, &usage);
    log::info(
        "cursor.run.finished",
        json!({"agent_id":agent_id,"run_id":run_id,"polls":polls,"duration_ms":run["durationMs"],"latency_ms":log::elapsed_ms(started),"reply":log::response_shape(&json!({"response":response}))}),
    );
    Completion {
        state: "completed",
        detail: json!({"http_status":status,"response":response}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fields(value: Value) -> serde_json::Map<String, Value> {
        value.as_object().unwrap().clone()
    }
    #[test]
    fn prompt_carries_system_user_and_the_json_contract_without_repo_side_effects() {
        let shaped = shape(
            &fields(json!({"model":"grok-4.6","messages":[{"role":"system","content":"You research."},{"role":"user","content":"Question?"}],
                "response_format":{"type":"json_schema","json_schema":{"name":"r","schema":{"type":"object"}}},"purpose":"research"})),
            2048,
        )
        .unwrap();
        assert_eq!(shaped["model"]["id"], "grok-4.6");
        let text = shaped["prompt"]["text"].as_str().unwrap();
        assert!(text.starts_with("You research.\n\nQuestion?"));
        assert!(text.contains("Do not create files, branches, or pull requests"));
        assert!(text.contains("{\"type\":\"object\"}"));
        assert!(text.contains("under 2048 tokens"));
        assert_eq!(shaped["name"], "market-mate research");
        assert!(shaped.get("repos").is_none());
        assert!(shape(
            &fields(json!({"model":"m","messages":[{"role":"system","content":"only"}]})),
            10
        )
        .is_err());
        assert!(shape(
            &fields(json!({"model":"m","messages":[{"role":"tool","content":"x"}]})),
            10
        )
        .is_err());
    }
    #[test]
    fn terminal_run_folds_into_chat_completion_shape_with_fences_removed() {
        let run = json!({"id":"run-1","agentId":"bc-1","status":"FINISHED","durationMs":12357,"result":"```json\n{\"hypothesis\":\"x\"}\n```"});
        let usage = json!({"totals":{"inputTokens":100,"outputTokens":20,"cacheWriteTokens":0,"cacheReadTokens":5,"totalTokens":125}});
        let out = normalize("grok-4.6", "bc-1", &run, &usage);
        assert_eq!(
            out["choices"][0]["message"]["content"],
            "{\"hypothesis\":\"x\"}"
        );
        assert_eq!(out["choices"][0]["finish_reason"], "stop");
        assert_eq!(out["model"], "grok-4.6");
        assert_eq!(out["usage"]["prompt_tokens"], 100);
        assert_eq!(out["usage"]["completion_tokens"], 20);
        assert!(out["usage"]["cost"].is_null());
        assert_eq!(out["cursor"]["run_id"], "run-1");
        assert_eq!(strip_fences("plain"), "plain");
        assert_eq!(strip_fences("```\n{}\n```"), "{}");
        assert_eq!(strip_fences("```json {\"a\":1}"), "```json {\"a\":1}");
    }
    #[test]
    fn timeouts_are_bounded_and_default_when_settings_are_absent_or_absurd() {
        assert_eq!(setting_secs(&json!({}), "run_timeout_secs", 600), 600);
        assert_eq!(
            setting_secs(&json!({"run_timeout_secs":120}), "run_timeout_secs", 600),
            120
        );
        assert_eq!(
            setting_secs(&json!({"run_timeout_secs":0}), "run_timeout_secs", 600),
            600
        );
        assert_eq!(
            setting_secs(&json!({"run_timeout_secs":99999}), "run_timeout_secs", 600),
            600
        );
    }
}
