//! Closed, resource-bounded diagnostic. No tools, network, optimization, or qualification.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Spec {
    pub runner: String,
    pub lookback_sessions: usize,
    pub quantile_count: usize,
    pub one_way_cost_bps: i64,
    pub borrow_bps_per_session: i64,
}
impl Spec {
    pub fn valid(&self) -> bool {
        self.runner == "momentum_v1"
            && (1..=5).contains(&self.lookback_sessions)
            && (2..=10).contains(&self.quantile_count)
            && (0..=100).contains(&self.one_way_cost_bps)
            && (0..=100).contains(&self.borrow_bps_per_session)
    }
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Bar {
    session: String,
    open_cents: i64,
    close_cents: i64,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Series {
    symbol: String,
    bars: Vec<Bar>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Dataset {
    dataset_class: String,
    symbols: Vec<String>,
    sessions: Vec<String>,
    series: Vec<Series>,
    benchmark: Vec<Bar>,
    cash_bps: Vec<i64>,
}
impl Dataset {
    pub fn parse(v: &Value) -> Result<Self, &'static str> {
        if v.to_string().len() > 240000 {
            return Err("dataset_exceeds_resource_bound");
        }
        let d: Self = serde_json::from_value(v.clone()).map_err(|_| "invalid_momentum_dataset")?;
        let n = d.sessions.len();
        if !["fixture", "observed"].contains(&d.dataset_class.as_str())
            || !(4..=32).contains(&d.symbols.len())
            || !(3..=60).contains(&n)
            || d.series.len() != d.symbols.len()
            || d.benchmark.len() != n
            || d.cash_bps.len() != n
            || d.cash_bps.iter().any(|v| !(-1000..=1000).contains(v))
        {
            return Err("invalid_momentum_dataset");
        }
        let mut names = std::collections::BTreeSet::new();
        for s in &d.symbols {
            if s.is_empty()
                || s.len() > 16
                || !s
                    .bytes()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b".-".contains(&b))
                || !names.insert(s)
            {
                return Err("invalid_symbol_universe");
            }
        }
        for (i, date) in d.sessions.iter().enumerate() {
            if !valid_date(date) || date.len() != 10 || (i > 0 && date <= &d.sessions[i - 1]) {
                return Err("invalid_session_order");
            }
        }
        let valid_bars = |bars: &Vec<Bar>| {
            bars.len() == n
                && bars.iter().zip(&d.sessions).all(|(b, date)| {
                    &b.session == date
                        && (1..=1_000_000_000).contains(&b.open_cents)
                        && (1..=1_000_000_000).contains(&b.close_cents)
                })
        };
        if !valid_bars(&d.benchmark) {
            return Err("incomplete_benchmark");
        }
        let mut series = std::collections::BTreeSet::new();
        for s in &d.series {
            if !names.contains(&s.symbol) || !series.insert(&s.symbol) || !valid_bars(&s.bars) {
                return Err("incomplete_price_coverage");
            }
        }
        Ok(d)
    }
    pub fn metadata(&self) -> Value {
        json!({"dataset_class":self.dataset_class,"symbols":self.symbols,"sessions":self.sessions,"benchmark":"supplied open/close series; adjustments are not certified","coverage":"complete rectangular open/close panel"})
    }
}
fn valid_date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10
        || b[4] != b'-'
        || b[7] != b'-'
        || b.iter()
            .enumerate()
            .any(|(i, c)| i != 4 && i != 7 && !c.is_ascii_digit())
    {
        return false;
    }
    let y = s[..4].parse::<u32>().unwrap();
    let m = s[5..7].parse::<usize>().unwrap();
    let d = s[8..].parse::<u32>().unwrap();
    let days = [
        31,
        if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) {
            29
        } else {
            28
        },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    y > 0 && (1..=12).contains(&m) && d > 0 && d <= days[m - 1]
}
fn change(exit: i64, entry: i64) -> i64 {
    ((exit as i128 - entry as i128) * 10000 / entry as i128) as i64
}
pub(crate) fn evaluate(spec: &Spec, data: &Dataset) -> Result<Value, &'static str> {
    if !spec.valid()
        || data.sessions.len() <= spec.lookback_sessions + 1
        || data.symbols.len() % spec.quantile_count != 0
    {
        return Err("unsupported_momentum_spec_for_dataset");
    }
    let count = data.symbols.len() / spec.quantile_count;
    let mut days = vec![];
    for t in spec.lookback_sessions..data.sessions.len() - 1 {
        let mut ranked = data.series.iter().collect::<Vec<_>>();
        ranked.sort_by(|a, b| {
            let ar = a.bars[t].close_cents as i128
                * b.bars[t - spec.lookback_sessions].close_cents as i128;
            let br = b.bars[t].close_cents as i128
                * a.bars[t - spec.lookback_sessions].close_cents as i128;
            ar.cmp(&br).then(a.symbol.cmp(&b.symbol))
        });
        let shorts = &ranked[..count];
        let longs = &ranked[ranked.len() - count..];
        let portfolio = |open: bool| -> i64 {
            let mut sum = 0i64;
            for (side, stocks) in [(1i64, longs), (-1, shorts)] {
                for s in stocks {
                    let entry = if open {
                        s.bars[t + 1].open_cents
                    } else {
                        s.bars[t].close_cents
                    };
                    sum += side * change(s.bars[t + 1].close_cents, entry);
                }
            }
            sum / (2 * count) as i64
        };
        let close = portfolio(false);
        let next_open = portfolio(true);
        // Equal long/short gross exposure totals one; each day fully closes and reopens.
        let costs = 2 * spec.one_way_cost_bps + (spec.borrow_bps_per_session + 1) / 2;
        days.push(json!({"signal_session":data.sessions[t],"exit_session":data.sessions[t+1],"longs":longs.iter().map(|s|&s.symbol).collect::<Vec<_>>(),"shorts":shorts.iter().map(|s|&s.symbol).collect::<Vec<_>>(),"close_reference_gross_bps":close,"close_reference_net_bps":close-costs,"next_open_gross_bps":next_open,"next_open_net_bps":next_open-costs,"cost_bps":costs,"benchmark_next_open_bps":change(data.benchmark[t+1].close_cents,data.benchmark[t+1].open_cents),"cash_bps":data.cash_bps[t+1]}));
    }
    let mean = |field: &str| {
        days.iter().map(|d| d[field].as_i64().unwrap()).sum::<i64>() / days.len() as i64
    };
    Ok(
        json!({"engine":"momentum_v1","outcome":"diagnostic_only","dataset_class":data.dataset_class,"sessions_evaluated":days.len(),"mean_close_reference_net_bps":mean("close_reference_net_bps"),"mean_next_open_net_bps":mean("next_open_net_bps"),"mean_benchmark_next_open_bps":mean("benchmark_next_open_bps"),"mean_cash_bps":mean("cash_bps"),"days":days,"limitations":["A bounded diagnostic, not a test of the full research plan or evidence of profitability.","Close reference is optimistic and not an executable signal-time fill assumption; its holding interval differs from next-open entry.","No statistical significance, bootstrap, parameter search, financing or capacity qualification is performed.","Input prices must already be consistently adjusted and point-in-time appropriate; this engine does not certify data provenance.","Mean daily basis-point returns use deterministic integer truncation, not compounded portfolio returns."]}),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    pub(crate) fn fixture() -> Value {
        let sessions = vec!["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"];
        let symbols = vec!["A", "B", "C", "D"];
        json!({"dataset_class":"fixture","symbols":symbols,"sessions":sessions,"series":symbols.iter().enumerate().map(|(i,s)|json!({"symbol":s,"bars":sessions.iter().enumerate().map(|(t,d)|json!({"session":d,"open_cents":10000+(i as i64-1)*t as i64*100,"close_cents":10000+(i as i64-1)*t as i64*200})).collect::<Vec<_>>()})).collect::<Vec<_>>(),"benchmark":sessions.iter().map(|d|json!({"session":d,"open_cents":10000,"close_cents":10010})).collect::<Vec<_>>(),"cash_bps":[0,0,0,0]})
    }
    #[test]
    fn closed_diagnostic_is_deterministic_and_costs_reduce_returns() {
        let d = Dataset::parse(&fixture()).unwrap();
        let mut s = Spec {
            runner: "momentum_v1".into(),
            lookback_sessions: 1,
            quantile_count: 2,
            one_way_cost_bps: 0,
            borrow_bps_per_session: 0,
        };
        let a = evaluate(&s, &d).unwrap();
        assert_eq!(a, evaluate(&s, &d).unwrap());
        assert_eq!(a["days"][0]["longs"], json!(["C", "D"]));
        assert_eq!(a["days"][0]["shorts"], json!(["A", "B"]));
        s.one_way_cost_bps = 5;
        let b = evaluate(&s, &d).unwrap();
        assert_eq!(
            a["mean_next_open_net_bps"].as_i64().unwrap()
                - b["mean_next_open_net_bps"].as_i64().unwrap(),
            10
        );
        assert_eq!(b["outcome"], "diagnostic_only");
        assert_eq!(b["days"][0]["next_open_net_bps"], 186);
        assert_eq!(b["days"][1]["next_open_net_bps"], 281);
        assert_eq!(b["mean_next_open_net_bps"], 233);
    }
    #[test]
    fn missing_prices_and_untrusted_extra_fields_fail() {
        let mut d = fixture();
        d["series"][0]["bars"][1]["open_cents"] = json!(0);
        assert!(Dataset::parse(&d).is_err());
        let mut d = fixture();
        d["code"] = json!("run me");
        assert!(Dataset::parse(&d).is_err());
    }
}
