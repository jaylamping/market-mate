use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio_postgres::GenericClient;

pub const TRACER_DOMAIN: &str = "market-mate-tracer-data-v1";
pub const PREREGISTRATION_DOMAIN: &str = "market-mate-preregistration-v1";
pub const TRACER_SNAPSHOT_KIND: &str = "tracer_inline";
pub const TRACER_SYMBOLS: [&str; 5] = ["MMM", "AAPL", "MSFT", "XOM", "JPM"];
const TRADING_DAYS: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TracerRun {
    pub run_id: String,
    pub symbols: Vec<String>,
    pub snapshot_id: String,
    pub snapshot_kind: String,
    pub snapshot_digest: String,
    pub preregistration_id: String,
    pub spec: Value,
    pub spec_digest: String,
    pub evaluation_id: String,
    pub result: Value,
    pub result_digest: String,
    pub audit_positions: Value,
}

fn derive_u32(symbol: &str, day: usize, field: &str) -> u32 {
    let digest = Sha256::digest(format!("{TRACER_DOMAIN}|{symbol}|{day}|{field}").as_bytes());
    u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]])
}

pub fn synthetic_eod_bars(symbol: &str) -> Value {
    let mut bars = Vec::with_capacity(TRADING_DAYS);
    for day in 0..TRADING_DAYS {
        bars.push(json!({
            "trading_day": day + 1,
            "open_cents": 5_000 + (derive_u32(symbol, day, "open") % 2_000),
            "close_bps_change": (derive_u32(symbol, day, "close") % 601) as i64 - 300,
            "volume": 100_000 + derive_u32(symbol, day, "volume") % 900_000,
        }));
    }
    json!({ "symbol": symbol, "bars": bars })
}

pub fn synthetic_edgar_summary(symbol: &str) -> Value {
    json!({
        "symbol": symbol,
        "filing_count": 1 + derive_u32(symbol, 0, "filings") % 4,
        "filing_forms": ["10-Q", "8-K"],
        "earnings_surprise_bps": (derive_u32(symbol, 0, "surprise") % 2_001) as i64 - 1_000,
    })
}

pub fn build_snapshot_payload(symbols: &[&str]) -> Value {
    let eod: Vec<Value> = symbols
        .iter()
        .map(|symbol| synthetic_eod_bars(symbol))
        .collect();
    let edgar: Vec<Value> = symbols
        .iter()
        .map(|symbol| synthetic_edgar_summary(symbol))
        .collect();
    json!({
        "eod": eod,
        "edgar": edgar,
        "symbols": symbols,
    })
}

pub fn toy_evaluation_spec(symbols: &[&str]) -> Value {
    json!({
        "experiment_key": "wu06-tracer-toy",
        "hypothesis": "Symbols with higher synthetic earnings surprise show higher synthetic EOD return over the tracer window",
        "data_source": "research_snapshot[tracer_inline]",
        "symbols": symbols,
        "window": {"trading_days": TRADING_DAYS, "kind": "synthetic_chronological"},
        "estimator": "mean_return_difference_bps",
        "groups": {"top": 2, "bottom": 2, "rank_by": "earnings_surprise_bps"},
        "comparator": "zero_difference",
        "stopping_rule": "single_pass",
        "multiplicity": "none",
        "determinism": "sha256_derived_synthetic_data",
    })
}

pub fn evaluate_toy_spec(payload: &Value) -> Result<Value, String> {
    let symbols = payload
        .get("symbols")
        .and_then(Value::as_array)
        .ok_or("snapshot payload lacks symbols")?;
    let edgar = payload
        .get("edgar")
        .and_then(Value::as_array)
        .ok_or("snapshot payload lacks edgar summaries")?;
    let eod = payload
        .get("eod")
        .and_then(Value::as_array)
        .ok_or("snapshot payload lacks eod bars")?;

    if symbols.len() < 4 || edgar.len() != symbols.len() || eod.len() != symbols.len() {
        return Err("snapshot payload does not carry the five tracer symbols".into());
    }

    let mut surprise_by_symbol = std::collections::BTreeMap::new();
    for summary in edgar {
        let symbol = summary
            .get("symbol")
            .and_then(Value::as_str)
            .ok_or("edgar summary lacks symbol")?;
        let surprise = summary
            .get("earnings_surprise_bps")
            .and_then(Value::as_i64)
            .ok_or("edgar summary lacks earnings_surprise_bps")?;
        surprise_by_symbol.insert(symbol.to_string(), surprise);
    }

    let mut window_return_by_symbol = std::collections::BTreeMap::new();
    for bars in eod {
        let symbol = bars
            .get("symbol")
            .and_then(Value::as_str)
            .ok_or("eod block lacks symbol")?;
        let bar_list = bars
            .get("bars")
            .and_then(Value::as_array)
            .ok_or("eod block lacks bars")?;
        let first_close_bps_change = bar_list
            .first()
            .and_then(|bar| bar.get("close_bps_change"))
            .and_then(Value::as_i64)
            .ok_or("eod bar lacks close_bps_change")?;
        let last_close_bps_change = bar_list
            .last()
            .and_then(|bar| bar.get("close_bps_change"))
            .and_then(Value::as_i64)
            .ok_or("eod bar lacks close_bps_change")?;
        let total = bar_list
            .iter()
            .map(|bar| {
                bar.get("close_bps_change")
                    .and_then(Value::as_i64)
                    .ok_or_else(|| "eod bar lacks close_bps_change".to_string())
            })
            .sum::<Result<i64, String>>()?;
        window_return_by_symbol.insert(
            symbol.to_string(),
            json!({
                "cumulative_bps": total,
                "first_close_bps_change": first_close_bps_change,
                "last_close_bps_change": last_close_bps_change,
            }),
        );
    }

    if surprise_by_symbol.len() != symbols.len() || window_return_by_symbol.len() != symbols.len() {
        return Err("snapshot payload symbol coverage is incomplete".into());
    }

    let mut ranked: Vec<(&String, &i64)> = surprise_by_symbol.iter().collect();
    ranked.sort_by(|left, right| right.1.cmp(left.1).then(left.0.cmp(right.0)));

    let top: Vec<&String> = ranked.iter().take(2).map(|(symbol, _)| *symbol).collect();
    let bottom: Vec<&String> = ranked
        .iter()
        .skip(ranked.len() - 2)
        .map(|(symbol, _)| *symbol)
        .collect();

    let top_mean = mean_of(&top, &window_return_by_symbol)?;
    let bottom_mean = mean_of(&bottom, &window_return_by_symbol)?;
    let difference = top_mean - bottom_mean;

    Ok(json!({
        "estimator": "mean_return_difference_bps",
        "group_top": {"symbols": top, "mean_cumulative_bps": top_mean},
        "group_bottom": {"symbols": bottom, "mean_cumulative_bps": bottom_mean},
        "difference_bps": difference,
        "decision": if difference > 0 { "positive" } else { "non_positive" },
        "window_returns": window_return_by_symbol,
    }))
}

fn mean_of(
    symbols: &[&String],
    window_return_by_symbol: &std::collections::BTreeMap<String, Value>,
) -> Result<i64, String> {
    let sum: i64 = symbols
        .iter()
        .map(|symbol| {
            window_return_by_symbol
                .get(*symbol)
                .and_then(|entry| entry.get("cumulative_bps"))
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("missing window return for {symbol}"))
        })
        .sum::<Result<i64, String>>()?;
    Ok(sum / symbols.len() as i64)
}

pub fn content_digest(domain: &str, canonical: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain.as_bytes());
    hasher.update(b"|");
    hasher.update(canonical.as_bytes());
    hex::encode(hasher.finalize())
}

async fn append_tracer_event<C: GenericClient>(
    client: &C,
    event_id: &str,
    event_type: &str,
    payload: &Value,
) -> Result<i64, String> {
    let lineage = json!({
        "source": "backend-tracer",
        "entitlement_version": "tracer-inline-v1"
    });
    let row = client
        .query_one(
            "SELECT chain_position FROM append_audit_event(
                $1, $2, now(), $3, $4, now(), 'local_research'
            )",
            &[&event_id, &event_type, payload, &lineage],
        )
        .await
        .map_err(|error| format!("tracer audit append {event_type} failed: {error}"))?;
    Ok(row.get(0))
}

pub async fn run_tracer<C: GenericClient>(client: &mut C) -> Result<TracerRun, String> {
    let transaction = client
        .transaction()
        .await
        .map_err(|error| format!("could not open tracer transaction: {error}"))?;
    let client = &transaction;
    let symbols = TRACER_SYMBOLS.to_vec();

    let run_id: String = client
        .query_one("SELECT gen_random_uuid()::text", &[])
        .await
        .map_err(|error| format!("could not allocate tracer run id: {error}"))?
        .get(0);

    let payload = build_snapshot_payload(&symbols);
    let lineage = json!({
        "source": "inline-tracer",
        "entitlement_version": "tracer-inline-v1"
    });

    let snapshot_row = client
        .query_one(
            "INSERT INTO research_snapshot (
                snapshot_kind, payload, payload_digest,
                source_lineage, receipt_time, record_environment
            ) VALUES (
                $1, $2, encode(digest($2::jsonb::text, 'sha256'), 'hex'),
                $3, now(), 'local_research'
            ) RETURNING snapshot_id::text, payload_digest",
            &[&TRACER_SNAPSHOT_KIND, &payload, &lineage],
        )
        .await
        .map_err(|error| format!("snapshot insert failed: {error}"))?;
    let snapshot_id: String = snapshot_row.get(0);
    let snapshot_digest: String = snapshot_row.get(1);

    let spec = toy_evaluation_spec(&symbols);
    let registration_row = client
        .query_one(
            "INSERT INTO experiment_preregistration (
                experiment_key, spec, spec_digest,
                source_lineage, receipt_time, record_environment
            ) VALUES (
                'wu06-tracer-toy',
                $1,
                encode(digest('market-mate-preregistration-v1|' || $1::jsonb::text, 'sha256'), 'hex'),
                $2, now(), 'local_research'
            ) RETURNING registration_id::text, spec_digest",
            &[&spec, &lineage],
        )
        .await
        .map_err(|error| format!("preregistration insert failed: {error}"))?;
    let preregistration_id: String = registration_row.get(0);
    let spec_digest: String = registration_row.get(1);

    let result = evaluate_toy_spec(&payload)?;
    let evaluation_row = client
        .query_one(
            "INSERT INTO evaluation_result (
                registration_id, snapshot_id, result, result_digest,
                source_lineage, receipt_time, record_environment
            ) VALUES (
                ($1::text)::uuid, ($2::text)::uuid, $3,
                encode(digest($3::jsonb::text, 'sha256'), 'hex'),
                $4, now(), 'local_research'
            ) RETURNING result_id::text, result_digest",
            &[&preregistration_id, &snapshot_id, &result, &lineage],
        )
        .await
        .map_err(|error| format!("evaluation insert failed: {error}"))?;
    let evaluation_id: String = evaluation_row.get(0);
    let result_digest: String = evaluation_row.get(1);

    let snapshot_position = append_tracer_event(
        client,
        &format!("tracer-snapshot-{run_id}"),
        "tracer.snapshot_captured",
        &json!({
            "run_id": run_id,
            "snapshot_id": snapshot_id,
            "snapshot_digest": snapshot_digest,
            "snapshot_kind": TRACER_SNAPSHOT_KIND,
            "symbols": &symbols,
        }),
    )
    .await?;

    let preregistration_position = append_tracer_event(
        client,
        &format!("tracer-preregistration-{run_id}"),
        "tracer.preregistration_created",
        &json!({
            "run_id": run_id,
            "registration_id": preregistration_id,
            "spec_digest": spec_digest,
            "experiment_key": "wu06-tracer-toy",
        }),
    )
    .await?;

    let evaluation_position = append_tracer_event(
        client,
        &format!("tracer-evaluation-{run_id}"),
        "tracer.evaluation_recorded",
        &json!({
            "run_id": run_id,
            "result_id": evaluation_id,
            "result_digest": result_digest,
            "registration_id": preregistration_id,
            "snapshot_id": snapshot_id,
            "decision": result.get("decision"),
        }),
    )
    .await?;

    let report = TracerRun {
        run_id,
        symbols: symbols.iter().map(|symbol| symbol.to_string()).collect(),
        snapshot_id,
        snapshot_kind: TRACER_SNAPSHOT_KIND.to_string(),
        snapshot_digest,
        preregistration_id,
        spec,
        spec_digest,
        evaluation_id,
        result,
        result_digest,
        audit_positions: json!({
            "snapshot_captured": snapshot_position,
            "preregistration_created": preregistration_position,
            "evaluation_recorded": evaluation_position,
        }),
    };

    transaction
        .commit()
        .await
        .map_err(|error| format!("could not commit tracer run: {error}"))?;

    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_data_is_deterministic_per_symbol() {
        assert_eq!(synthetic_eod_bars("MMM"), synthetic_eod_bars("MMM"));
        assert_ne!(synthetic_eod_bars("MMM"), synthetic_eod_bars("AAPL"));
        assert_eq!(
            synthetic_edgar_summary("XOM"),
            synthetic_edgar_summary("XOM")
        );
        assert_ne!(
            synthetic_edgar_summary("XOM"),
            synthetic_edgar_summary("JPM")
        );
    }

    #[test]
    fn payload_is_canonical_and_complete() {
        let first = build_snapshot_payload(&TRACER_SYMBOLS);
        let second = build_snapshot_payload(&TRACER_SYMBOLS);
        assert_eq!(first, second, "payload generation must be deterministic");
        let canonical = serde_json::to_string(&first).unwrap();
        assert_eq!(
            content_digest("market-mate-snapshot-v1", &canonical),
            content_digest("market-mate-snapshot-v1", &canonical)
        );
        assert_eq!(first["symbols"].as_array().unwrap().len(), 5);
        assert_eq!(first["eod"].as_array().unwrap().len(), 5);
        assert_eq!(first["edgar"].as_array().unwrap().len(), 5);
    }

    #[test]
    fn toy_evaluation_is_deterministic_and_complete() {
        let payload = build_snapshot_payload(&TRACER_SYMBOLS);
        let first = evaluate_toy_spec(&payload).unwrap();
        let second = evaluate_toy_spec(&payload).unwrap();
        assert_eq!(first, second);
        assert!(first.get("group_top").is_some());
        assert!(first.get("group_bottom").is_some());
        assert!(first.get("difference_bps").is_some());
        assert!(first.get("decision").is_some());
    }

    #[test]
    fn toy_evaluation_fails_closed_on_incomplete_payload() {
        assert!(evaluate_toy_spec(&json!({})).is_err());
        assert!(evaluate_toy_spec(&json!({"symbols": ["A"]})).is_err());
    }

    #[test]
    fn toy_evaluation_decision_tracks_group_difference() {
        let payload = build_snapshot_payload(&TRACER_SYMBOLS);
        let result = evaluate_toy_spec(&payload).unwrap();
        let top = result["group_top"]["mean_cumulative_bps"].as_i64().unwrap();
        let bottom = result["group_bottom"]["mean_cumulative_bps"]
            .as_i64()
            .unwrap();
        let decision = result["decision"].as_str().unwrap();
        assert_eq!(
            decision,
            if top - bottom > 0 {
                "positive"
            } else {
                "non_positive"
            }
        );
        assert_eq!(result["difference_bps"].as_i64().unwrap(), top - bottom);
    }
}
