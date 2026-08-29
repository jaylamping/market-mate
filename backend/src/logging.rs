use serde_json::{json, Value};

use crate::receipt::utc_checkpoint_time_now;
use crate::secrets::{credential_shaped_name, secret_run_length};

const REDACTED_KEY: &str = "[REDACTED:credential-shaped-key]";
const REDACTED_SECRET: &str = "[REDACTED:secret-shaped]";
const REDACTED_URL_PASSWORD: &str = "[REDACTED:url-password]";
const REDACTED_PRIVATE_KEY: &str = "[REDACTED:private-key]";

pub fn log_event(service: &str, level: &str, event: &str, fields: &Value) {
    eprintln!("{}", format_event(service, level, event, fields));
}

pub fn format_event(service: &str, level: &str, event: &str, fields: &Value) -> String {
    let mut object = redact_fields(fields)
        .as_object()
        .cloned()
        .unwrap_or_default();
    object.insert("ts".into(), json!(utc_checkpoint_time_now()));
    object.insert("level".into(), json!(level));
    object.insert("service".into(), json!(service));
    object.insert("event".into(), json!(event));
    Value::Object(object).to_string()
}

pub fn redact_fields(fields: &Value) -> Value {
    match fields {
        Value::Object(entries) => Value::Object(
            entries
                .iter()
                .map(|(key, value)| {
                    if credential_shaped_name(key).is_some() {
                        (key.clone(), json!(REDACTED_KEY))
                    } else {
                        (key.clone(), redact_fields(value))
                    }
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(redact_fields).collect()),
        Value::String(text) => json!(redact_text(text)),
        other => other.clone(),
    }
}

pub fn redact_text(input: &str) -> String {
    let without_url_passwords = redact_url_passwords(input);
    let without_private_keys = redact_private_key_blocks(&without_url_passwords);
    redact_secret_runs(&without_private_keys)
}

fn redact_url_passwords(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(position) = rest.find("://") {
        let scheme_end = position + 3;
        output.push_str(&rest[..scheme_end]);
        rest = &rest[scheme_end..];
        let authority_end = crate::secrets::url_authority_span(rest);
        let authority = &rest[..authority_end];
        if let Some(colon_index) = crate::secrets::url_userinfo_password_index(authority) {
            output.push_str(&authority[..colon_index + 1]);
            output.push_str(REDACTED_URL_PASSWORD);
            output.push('@');
            output.push_str(&authority[authority.rfind('@').expect("index verified") + 1..]);
        } else {
            output.push_str(authority);
        }
        rest = &rest[authority_end..];
    }
    output.push_str(rest);
    output
}

fn redact_private_key_blocks(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(begin_index) = rest.find("-----BEGIN") {
        output.push_str(&rest[..begin_index]);
        let after_begin = &rest[begin_index..];
        let end_index = after_begin.find("-----END");
        match end_index.and_then(|relative| {
            after_begin[relative + 8..]
                .find("-----")
                .map(|end_marker| relative + 8 + end_marker + 5)
        }) {
            Some(stop) => {
                output.push_str(REDACTED_PRIVATE_KEY);
                rest = &after_begin[stop..];
            }
            None => {
                output.push_str(REDACTED_PRIVATE_KEY);
                rest = "";
                break;
            }
        }
    }
    output.push_str(rest);
    output
}

fn redact_secret_runs(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut output = String::with_capacity(input.len());
    let mut index = 0;
    while index < chars.len() {
        if let Some(length) = secret_run_length(&chars[index..]) {
            output.push_str(REDACTED_SECRET);
            index += length;
        } else {
            output.push(chars[index]);
            index += 1;
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_format_is_single_line_json_with_required_fields() {
        let line = format_event("backend", "info", "test.event", &json!({"count": 1}));
        let parsed: Value = serde_json::from_str(&line).expect("log line must be valid JSON");
        assert_eq!(parsed["level"], "info");
        assert_eq!(parsed["service"], "backend");
        assert_eq!(parsed["event"], "test.event");
        assert_eq!(parsed["count"], 1);
        assert_eq!(line.matches('\n').count(), 0);
        assert!(parsed["ts"].as_str().unwrap().ends_with('Z'));
    }

    #[test]
    fn envelope_keys_cannot_be_overwritten_by_fields() {
        let line = format_event(
            "backend",
            "info",
            "test.spoof",
            &json!({"level": "forged", "event": "fake", "ts": "0", "service": "other"}),
        );
        let parsed: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(parsed["level"], "info");
        assert_eq!(parsed["event"], "test.spoof");
        assert_eq!(parsed["service"], "backend");
        assert_ne!(parsed["ts"], "0");
    }

    #[test]
    fn credential_shaped_keys_are_redacted() {
        let line = format_event(
            "backend",
            "info",
            "test.event",
            &json!({"api_key": "sk-abcdef0123456789abcdef", "plain": "visible"}),
        );
        let parsed: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(parsed["api_key"], REDACTED_KEY);
        assert_eq!(parsed["plain"], "visible");
    }

    #[test]
    fn nested_fields_are_redacted() {
        let fields = json!({"request": {"headers": {"Authorization": "Bearer eyJhbGciOiJIUzI1NiJ9.eyJhIjoiYiJ9.c2ln"}, "size": 10}});
        let redacted = redact_fields(&fields);
        assert_eq!(
            redacted["request"]["headers"]["Authorization"],
            REDACTED_KEY
        );
        assert_eq!(redacted["request"]["size"], 10);
    }

    #[test]
    fn url_passwords_are_redacted() {
        assert_eq!(
            redact_text("postgres://mm:local-only@postgres:5432/market_mate"),
            format!("postgres://mm:{REDACTED_URL_PASSWORD}@postgres:5432/market_mate")
        );
        assert_eq!(
            redact_text("https://user:hunter2@example.com/path?q=1"),
            format!("https://user:{REDACTED_URL_PASSWORD}@example.com/path?q=1")
        );
        assert_eq!(
            redact_text("http://custody:8081"),
            "http://custody:8081",
            "authority without @ must not be treated as credentials"
        );
    }

    #[test]
    fn private_key_blocks_are_redacted() {
        let input =
            "key=-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----\ntrailing";
        assert_eq!(
            redact_text(input),
            format!("key={REDACTED_PRIVATE_KEY}\ntrailing")
        );
        assert_eq!(
            redact_text("-----BEGIN OPENSSH PRIVATE KEY----- no end marker"),
            REDACTED_PRIVATE_KEY
        );
    }

    #[test]
    fn secret_shaped_runs_are_redacted() {
        let jwt =
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c";
        assert_eq!(redact_text(jwt), REDACTED_SECRET);
        assert_eq!(
            redact_text("AKIAIOSFODNN7EXAMPLE is an aws key"),
            format!("{REDACTED_SECRET} is an aws key")
        );
        assert_eq!(
            redact_text("token ghp_0123456789abcdef0123456789abcdef1234 end"),
            format!("token {REDACTED_SECRET} end")
        );
        assert_eq!(redact_text(&"a".repeat(64)), REDACTED_SECRET);
        assert_eq!(redact_text("abc123def456"), "abc123def456");
        assert_eq!(
            redact_text("2026-08-29T00:00:00.000000Z"),
            "2026-08-29T00:00:00.000000Z"
        );
    }

    #[test]
    fn formatted_events_never_emit_secret_shaped_values() {
        let hex_secret = "9f2c5a1e7b3d4f6a8c0e2b4d6f8a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1d3f5a";
        let token = "ghp_0123456789abcdef0123456789abcdef1234";
        let line = format_event(
            "backend",
            "error",
            "test.leak",
            &json!({
                "DATABASE_URL": format!("postgres://mm:{hex_secret}@db/market"),
                "detail": format!("failed with credential {token}"),
                "raw_key": hex_secret
            }),
        );
        assert!(!line.contains(hex_secret), "{line}");
        assert!(!line.contains(token), "{line}");
        assert!(line.contains(REDACTED_URL_PASSWORD));
        assert!(line.contains(REDACTED_SECRET));
    }

    #[test]
    fn scanner_blocked_shapes_are_always_redacted() {
        let blocked_values = [
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c",
            "AKIAIOSFODNN7EXAMPLE",
            "ghp_0123456789abcdef0123456789abcdef1234",
            "sk-abcdef0123456789abcdef01234567890123",
            "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2",
        ];
        for value in blocked_values {
            assert!(
                crate::secrets::credential_shaped_value("SOME_NAME", value).is_some(),
                "{value} should be blocked by the scanner"
            );
            let redacted = redact_text(value);
            assert_eq!(redacted, REDACTED_SECRET, "{value} must be fully redacted");
        }
    }
}
