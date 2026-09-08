//! Quota truth comes from provider usage APIs polled every five minutes; local counters fill the gaps.
//! Parsers tolerate missing fields: an unrecognized body marks the window `unknown`, never `ok`.
use super::adapter::Transport;
use super::log;
use super::registry::{read_credentials, Provider};
use chrono::{DateTime, TimeZone, Utc};
use serde_json::{json, Value};
use std::time::Instant;
use tokio_postgres::Client;

#[derive(Debug, Clone, PartialEq)]
pub struct WindowSample {
    pub window: &'static str,
    pub percent_used: f64,
    pub status: &'static str,
    pub resets_at: Option<DateTime<Utc>>,
}
fn epoch_ms(value: &Value) -> Option<DateTime<Utc>> {
    let ms = value
        .as_i64()
        .or_else(|| value.as_str().and_then(|s| s.parse::<i64>().ok()))?;
    if ms <= 0 {
        return None;
    }
    Utc.timestamp_millis_opt(ms).single()
}
fn rfc3339(value: &Value) -> Option<DateTime<Utc>> {
    value
        .as_str()
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|t| t.with_timezone(&Utc))
        .or_else(|| epoch_ms(value))
}
fn percent(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| {
            value
                .as_str()
                .and_then(|s| s.trim_end_matches('%').parse().ok())
        })
        .filter(|p| p.is_finite() && *p >= 0.0)
        .map(|p| p.min(100.0))
}
fn status_for(percent_used: f64, raw: Option<&str>) -> &'static str {
    match raw.map(str::to_ascii_lowercase).as_deref() {
        Some("rate_limited") | Some("limited") | Some("exceeded") | Some("exhausted") => {
            "rate_limited"
        }
        _ if percent_used >= 100.0 => "rate_limited",
        _ => "ok",
    }
}

/// Z.ai `GET /api/monitor/usage/quota/limit`: `data.limits[]` with `TOKENS_LIMIT` buckets keyed by
/// `unit` (3 = 5h, 6 = weekly); `TIME_LIMIT` is the monthly MCP tool cap and is ignored for routing.
pub fn parse_zai(body: &Value) -> Vec<WindowSample> {
    let mut samples = Vec::new();
    for limit in body["data"]["limits"].as_array().into_iter().flatten() {
        if limit["type"] != "TOKENS_LIMIT" {
            continue;
        }
        let window = match (limit["unit"].as_i64(), limit["number"].as_i64()) {
            (Some(3), _) => "rolling_5h",
            (Some(6), _) => "weekly",
            (None, Some(5)) => "rolling_5h",
            (None, Some(1)) => "weekly",
            _ => continue,
        };
        let Some(percent_used) = percent(&limit["percentage"]) else {
            continue;
        };
        samples.push(WindowSample {
            window,
            percent_used,
            status: status_for(percent_used, None),
            resets_at: epoch_ms(&limit["nextResetTime"]),
        });
    }
    samples
}
/// OpenCode Go `GET /usage`: `usage.{rolling,weekly,monthly}.{status,percent,resetsAt}`.
pub fn parse_opencode(body: &Value) -> Vec<WindowSample> {
    let usage = body.get("usage").unwrap_or(body);
    let mut samples = Vec::new();
    for (key, window) in [
        ("rolling", "rolling_5h"),
        ("weekly", "weekly"),
        ("monthly", "monthly"),
    ] {
        let entry = &usage[key];
        let Some(percent_used) =
            percent(&entry["percent"]).or_else(|| percent(&entry["percentage"]))
        else {
            continue;
        };
        samples.push(WindowSample {
            window,
            percent_used,
            status: status_for(percent_used, entry["status"].as_str()),
            resets_at: rfc3339(&entry["resetsAt"]).or_else(|| rfc3339(&entry["resets_at"])),
        });
    }
    samples
}
/// Cheaper Inference `GET /v1/usage/daily` (no dates = trailing 30 days): `spend_usd` against the
/// persisted `settings.monthly_budget_usd`. The budget is the spending policy; no budget, no sample.
pub fn parse_cheaper_inference(settings: &Value, body: &Value) -> Vec<WindowSample> {
    let budget = settings["monthly_budget_usd"]
        .as_str()
        .and_then(|s| s.parse::<f64>().ok())
        .or_else(|| settings["monthly_budget_usd"].as_f64())
        .filter(|b| b.is_finite() && *b > 0.0);
    let spend = body["spend_usd"]
        .as_str()
        .and_then(|s| s.parse::<f64>().ok())
        .or_else(|| body["spend_usd"].as_f64())
        .filter(|s| s.is_finite() && *s >= 0.0);
    let (Some(budget), Some(spend)) = (budget, spend) else {
        return Vec::new();
    };
    let percent_used = ((spend / budget) * 100.0).clamp(0.0, 100.0);
    vec![WindowSample {
        window: "monthly",
        percent_used,
        status: status_for(percent_used, None),
        resets_at: None,
    }]
}
pub fn parse_usage(provider: &Provider, body: &Value) -> Vec<WindowSample> {
    match provider.settings["usage_format"]
        .as_str()
        .unwrap_or(provider.id.as_str())
    {
        "zai" => parse_zai(body),
        "opencode-go" | "opencode" => parse_opencode(body),
        "cheaper_inference" | "cheaper-inference" => {
            parse_cheaper_inference(&provider.settings, body)
        }
        _ => {
            let mut samples = parse_opencode(body);
            if samples.is_empty() {
                samples = parse_zai(body);
            }
            samples
        }
    }
}

async fn fetch_usage(provider: &Provider, url: &str) -> Result<Value, &'static str> {
    // Z.ai's monitor endpoint wants the bare key; everything else takes a Bearer token.
    if provider.settings["usage_auth"] == "raw" {
        let (_, key) = read_credentials(std::path::Path::new(&provider.credential_path))?;
        let mut value =
            reqwest::header::HeaderValue::from_str(&key).map_err(|_| "invalid_credentials")?;
        value.set_sensitive(true);
        let mut response = super::adapter::client(15)?
            .get(url)
            .header("Authorization", value)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|_| "connection_failed")?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "connection_failed")? {
            if bytes.len() + chunk.len() > 200_000 {
                return Err("invalid_response");
            }
            bytes.extend_from_slice(&chunk);
        }
        return match status {
            200 => serde_json::from_slice(&bytes).map_err(|_| "invalid_response"),
            401 => Err("credentials_rejected"),
            403 => Err("plan_not_active"),
            429 => Err("rate_limited"),
            _ => Err("provider_unavailable"),
        };
    }
    Transport::open(provider, 15)?.get_json(url, 200_000).await
}

/// Poll one provider; every window becomes a `provider_usage_sample`. Failures record a probe state
/// and leave the last good sample to age into `unknown`, so routing degrades to local counters.
pub async fn poll_provider(db: &Client, provider: &Provider) -> Result<usize, &'static str> {
    let Some(url) = provider.usage_url.as_deref() else {
        return Ok(0);
    };
    let started = Instant::now();
    let body = match fetch_usage(provider, url).await {
        Ok(body) => body,
        Err(reason) => {
            log::warn(
                "quota.poll.failed",
                json!({"provider":provider.id,"reason":reason,"latency_ms":log::elapsed_ms(started)}),
            );
            let state = probe_state_for(reason);
            let _ = db
                .query(
                    "SELECT record_provider_probe($1,$2,$3)",
                    &[&provider.id, &state, &reason],
                )
                .await;
            return Err(reason);
        }
    };
    let samples = parse_usage(provider, &body);
    if samples.is_empty() {
        log::warn(
            "quota.poll.unparsed",
            json!({"provider":provider.id,"keys":body.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>()),"latency_ms":log::elapsed_ms(started)}),
        );
        let _ = db
            .query(
                "SELECT record_provider_probe($1,$2,$3)",
                &[&provider.id, &"connected", &"usage_unparsed"],
            )
            .await;
        return Ok(0);
    }
    let mut recorded = 0;
    for sample in &samples {
        let percent = sample.percent_used;
        match db
            .query_one(
                "SELECT record_usage_sample($1,$2,$3::text::numeric,$4,$5::text::timestamptz)",
                &[
                    &provider.id,
                    &sample.window,
                    &format!("{percent:.2}"),
                    &sample.status,
                    &sample.resets_at.map(|t| t.to_rfc3339()),
                ],
            )
            .await
        {
            Ok(row) => {
                let status: Value = row.get(0);
                recorded += 1;
                log::info(
                    "quota.sample",
                    json!({"provider":provider.id,"window":sample.window,"percent_used":percent,"status":sample.status,"resets_at":sample.resets_at,
                        "elapsed_pct":status["elapsed_pct"],"over_threshold":status["over_threshold"],"over_pace":status["over_pace"]}),
                );
            }
            Err(e) => log::warn(
                "quota.sample.rejected",
                json!({"provider":provider.id,"window":sample.window,"error":super::dispatch::sql_reason(&e,"sample_unavailable"),"detail":crate::logging::redact_text(&e.to_string()).chars().take(300).collect::<String>()}),
            ),
        }
    }
    let _ = db
        .query(
            "SELECT record_provider_probe($1,$2,$3)",
            &[&provider.id, &"connected", &None::<String>],
        )
        .await;
    log::debug(
        "quota.poll.completed",
        json!({"provider":provider.id,"windows":recorded,"latency_ms":log::elapsed_ms(started)}),
    );
    Ok(recorded)
}
/// Probe providers without a usage API so `/system` can show credential and reachability state.
/// Map a probe or poll failure onto the persisted `provider_state.probe_state` vocabulary. A
/// provider without readable credentials is `not_configured`, which the route walk skips.
fn probe_state_for(reason: &str) -> &'static str {
    match reason {
        "not_configured" | "invalid_credentials" | "credentials_unavailable" => "not_configured",
        "credentials_rejected" => "credentials_rejected",
        "plan_not_active" => "plan_not_active",
        "rate_limited" => "rate_limited",
        _ => "unreachable",
    }
}

pub async fn probe_provider(db: &Client, provider: &Provider) {
    let started = Instant::now();
    let (state, error) = match super::adapter::probe(provider).await {
        Ok(state) => (state, None),
        Err(reason) => (probe_state_for(reason), Some(reason)),
    };
    log::info(
        "provider.probe",
        json!({"provider":provider.id,"state":state,"error":error,"latency_ms":log::elapsed_ms(started)}),
    );
    let _ = db
        .query(
            "SELECT record_provider_probe($1,$2,$3)",
            &[&provider.id, &state, &error],
        )
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_credentials_record_not_configured_so_the_route_walk_skips_them() {
        assert_eq!(probe_state_for("credentials_unavailable"), "not_configured");
        assert_eq!(probe_state_for("not_configured"), "not_configured");
        assert_eq!(
            probe_state_for("credentials_rejected"),
            "credentials_rejected"
        );
        assert_eq!(probe_state_for("dns_failure"), "unreachable");
    }
    #[test]
    fn zai_limits_map_by_unit_and_ignore_the_mcp_time_limit() {
        let body = json!({"code":200,"data":{"limits":[
            {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":18.5,"nextResetTime":1735000000000_i64},
            {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":100,"nextResetTime":1735500000000_i64},
            {"type":"TIME_LIMIT","unit":5,"percentage":4.0,"usage":300,"nextResetTime":1736000000000_i64}]}});
        let samples = parse_zai(&body);
        assert_eq!(samples.len(), 2);
        assert_eq!(
            (
                samples[0].window,
                samples[0].percent_used,
                samples[0].status
            ),
            ("rolling_5h", 18.5, "ok")
        );
        assert_eq!(
            samples[0].resets_at.unwrap().timestamp_millis(),
            1735000000000
        );
        assert_eq!(
            (samples[1].window, samples[1].status),
            ("weekly", "rate_limited")
        );
        assert!(parse_zai(&json!({"code":401,"msg":"nope"})).is_empty());
    }
    #[test]
    fn cheaper_inference_spend_is_measured_against_the_persisted_budget() {
        let body = json!({"object":"usage.daily","scope":"workspace","currency":"USD","spend_usd":"7.50","total_requests":12});
        let samples = parse_cheaper_inference(&json!({"monthly_budget_usd":"10"}), &body);
        assert_eq!(samples.len(), 1);
        assert_eq!(
            (
                samples[0].window,
                samples[0].percent_used,
                samples[0].status
            ),
            ("monthly", 75.0, "ok")
        );
        assert!(samples[0].resets_at.is_none());
        let over = parse_cheaper_inference(&json!({"monthly_budget_usd":5.0}), &body);
        assert_eq!(
            (over[0].percent_used, over[0].status),
            (100.0, "rate_limited")
        );
        assert!(
            parse_cheaper_inference(&json!({}), &body).is_empty(),
            "no budget means no spend authority"
        );
        assert!(parse_cheaper_inference(&json!({"monthly_budget_usd":"0"}), &body).is_empty());
        assert!(
            parse_cheaper_inference(&json!({"monthly_budget_usd":"10"}), &json!({"error":{}}))
                .is_empty()
        );
    }
    #[test]
    fn opencode_usage_reads_three_windows_with_status_and_reset() {
        let body = json!({"usage":{"rolling":{"status":"ok","percent":12,"resetsAt":"2026-09-07T20:00:00Z"},
            "weekly":{"status":"limited","percent":63,"resetsAt":"2026-09-13T00:00:00Z"},"monthly":{"status":"ok","percent":"40%","resetsAt":null}}});
        let samples = parse_opencode(&body);
        assert_eq!(
            samples.iter().map(|s| s.window).collect::<Vec<_>>(),
            ["rolling_5h", "weekly", "monthly"]
        );
        assert_eq!(samples[1].status, "rate_limited");
        assert_eq!(samples[2].percent_used, 40.0);
        assert!(samples[2].resets_at.is_none());
        assert_eq!(
            samples[0].resets_at.unwrap().to_rfc3339(),
            "2026-09-07T20:00:00+00:00"
        );
        assert!(parse_opencode(&json!({"error":"No active Go plan"})).is_empty());
    }
}
