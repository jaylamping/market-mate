//! Bounded local-research downloads. Provider facts are not registered entitlement lineage.
use chrono::{DateTime, Datelike, NaiveDate, TimeZone, Timelike, Utc};
use chrono_tz::America::New_York;
use reqwest::{
    header::{HeaderMap, HeaderValue},
    Client,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, value::RawValue, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};

const ENDPOINT: &str = "https://data.alpaca.markets/v2/stocks/bars";
const MAX_BODY: usize = 2_000_000;
const MAX_PAGES: usize = 64;
const MAX_ATTEMPTS: usize = 4;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PanelRequest {
    schema_version: u32,
    symbols: Vec<String>,
    sessions: Vec<NaiveDate>,
    benchmark: String,
    symbol_asof: NaiveDate,
    cash: CashAssumption,
    spec: crate::momentum::Spec,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum CashAssumption {
    ZeroInterest,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DownloadError {
    InvalidRequest,
    InvalidCredentials,
    Transport,
    AccessDenied,
    RateLimited,
    ProviderUnavailable,
    ProviderRejected,
    InvalidResponse,
    ResourceLimit,
    InvalidPrice,
    IncompleteCoverage,
    DuplicateObservation,
    UnexpectedObservation,
    IncompatiblePanel,
}
impl std::fmt::Display for DownloadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for DownloadError {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Credentials {
    key_id: String,
    secret_key: String,
}
impl Credentials {
    fn headers(&self) -> Result<HeaderMap, DownloadError> {
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("APCA-API-KEY-ID", &self.key_id),
            ("APCA-API-SECRET-KEY", &self.secret_key),
        ] {
            if value.is_empty()
                || value.len() > 512
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
            {
                return Err(DownloadError::InvalidCredentials);
            }
            let mut header =
                HeaderValue::from_str(value).map_err(|_| DownloadError::InvalidCredentials)?;
            header.set_sensitive(true);
            headers.insert(name, header);
        }
        Ok(headers)
    }
}

impl PanelRequest {
    fn validate(&self, now: DateTime<Utc>) -> Result<(), DownloadError> {
        let valid_symbol = |s: &str| {
            !s.is_empty()
                && s.len() <= 16
                && s.bytes()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b".-".contains(&b))
        };
        if self.schema_version != 1
            || !(4..=32).contains(&self.symbols.len())
            || self.symbols.iter().any(|s| !valid_symbol(s))
            || !valid_symbol(&self.benchmark)
            || self.symbols.iter().collect::<BTreeSet<_>>().len() != self.symbols.len()
            || !(3..=60).contains(&self.sessions.len())
            || !self.spec.valid()
            || self.sessions.len() <= self.spec.lookback_sessions + 1
            || self.symbols.len() % self.spec.quantile_count != 0
        {
            return Err(DownloadError::InvalidRequest);
        }
        let today = now.with_timezone(&New_York).date_naive();
        if self.symbol_asof.year() < 2016
            || self.symbol_asof > today
            || self
                .sessions
                .iter()
                .any(|d| d.year() < 2016 || *d >= today || d.weekday().number_from_monday() > 5)
            || self.sessions.windows(2).any(|pair| pair[0] >= pair[1])
            || (*self.sessions.last().unwrap() - self.sessions[0]).num_days() > 120
        {
            return Err(DownloadError::InvalidRequest);
        }
        Ok(())
    }
    fn symbols(&self) -> BTreeSet<String> {
        self.symbols
            .iter()
            .cloned()
            .chain(std::iter::once(self.benchmark.clone()))
            .collect()
    }
    fn query(&self) -> Vec<(&'static str, String)> {
        let start = New_York
            .from_local_datetime(&self.sessions[0].and_hms_opt(0, 0, 0).unwrap())
            .single()
            .unwrap();
        let end = New_York
            .from_local_datetime(
                &self
                    .sessions
                    .last()
                    .unwrap()
                    .and_hms_opt(23, 59, 59)
                    .unwrap(),
            )
            .single()
            .unwrap();
        vec![
            (
                "symbols",
                self.symbols().into_iter().collect::<Vec<_>>().join(","),
            ),
            ("timeframe", "1Day".into()),
            ("feed", "sip".into()),
            ("adjustment", "all".into()),
            ("currency", "USD".into()),
            ("sort", "asc".into()),
            ("limit", "10000".into()),
            ("start", start.to_rfc3339()),
            ("end", end.to_rfc3339()),
            ("asof", self.symbol_asof.to_string()),
        ]
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(transparent)]
struct Price(Box<RawValue>);

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ProviderBar {
    t: String,
    o: Price,
    h: Price,
    l: Price,
    c: Price,
    v: u64,
}
#[derive(Deserialize)]
struct Page {
    bars: BTreeMap<String, Vec<ProviderBar>>,
    next_page_token: Option<String>,
}

// Accept at most six decimal places and round half up to cents. Reject unsupported
// representations rather than silently introducing a floating-point conversion.
fn micro_price(n: &Price) -> Result<i64, DownloadError> {
    let text = n.0.get();
    let mut parts = text.split('.');
    let whole = parts.next().unwrap_or("");
    let fraction = parts.next().unwrap_or("");
    if parts.next().is_some()
        || whole.is_empty()
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || fraction.len() > 6
        || !fraction.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(DownloadError::InvalidPrice);
    }
    let whole: i64 = whole.parse().map_err(|_| DownloadError::InvalidPrice)?;
    let fraction: i64 = format!("{fraction:0<6}")
        .parse()
        .map_err(|_| DownloadError::InvalidPrice)?;
    let value = whole
        .checked_mul(1_000_000)
        .and_then(|x| x.checked_add(fraction))
        .ok_or(DownloadError::InvalidPrice)?;
    if value <= 0 || value > 10_000_000_000_000 {
        return Err(DownloadError::InvalidPrice);
    }
    Ok(value)
}
fn cents(n: &Price) -> Result<i64, DownloadError> {
    let result = (micro_price(n)? + 5_000) / 10_000;
    if !(1..=1_000_000_000).contains(&result) {
        return Err(DownloadError::InvalidPrice);
    }
    Ok(result)
}
fn session(bar: &ProviderBar) -> Result<NaiveDate, DownloadError> {
    let time = DateTime::parse_from_rfc3339(&bar.t)
        .map_err(|_| DownloadError::InvalidResponse)?
        .with_timezone(&New_York);
    if time.hour() != 0 || time.minute() != 0 || time.second() != 0 || time.nanosecond() != 0 {
        return Err(DownloadError::InvalidResponse);
    }
    let (o, h, l, c) = (
        micro_price(&bar.o)?,
        micro_price(&bar.h)?,
        micro_price(&bar.l)?,
        micro_price(&bar.c)?,
    );
    if l > o || l > c || h < o || h < c || h < l || bar.v > i64::MAX as u64 {
        return Err(DownloadError::InvalidPrice);
    }
    Ok(time.date_naive())
}

pub struct AlpacaDailyClient {
    client: Client,
    headers: HeaderMap,
    endpoint: String,
    pace: Duration,
}
impl AlpacaDailyClient {
    pub fn new(credentials: Credentials) -> Result<Self, DownloadError> {
        Ok(Self {
            client: Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(30))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .map_err(|_| DownloadError::Transport)?,
            headers: credentials.headers()?,
            endpoint: ENDPOINT.into(),
            pace: Duration::from_millis(350),
        })
    }
    async fn page(&self, query: &[(&str, String)]) -> Result<Page, DownloadError> {
        for attempt in 0..MAX_ATTEMPTS {
            tokio::time::sleep(self.pace).await;
            let response = self
                .client
                .get(&self.endpoint)
                .headers(self.headers.clone())
                .query(query)
                .send()
                .await;
            let mut response = match response {
                Ok(r) => r,
                Err(_) if attempt + 1 < MAX_ATTEMPTS => {
                    self.backoff(attempt, None).await?;
                    continue;
                }
                Err(_) => return Err(DownloadError::Transport),
            };
            let status = response.status().as_u16();
            if status == 429 || (500..=599).contains(&status) {
                if attempt + 1 == MAX_ATTEMPTS {
                    return Err(if status == 429 {
                        DownloadError::RateLimited
                    } else {
                        DownloadError::ProviderUnavailable
                    });
                }
                self.backoff(
                    attempt,
                    response
                        .headers()
                        .get("retry-after")
                        .and_then(|h| h.to_str().ok()),
                )
                .await?;
                continue;
            }
            if status == 401 || status == 403 {
                return Err(DownloadError::AccessDenied);
            }
            if status != 200 {
                return Err(DownloadError::ProviderRejected);
            }
            if response
                .content_length()
                .is_some_and(|n| n > MAX_BODY as u64)
            {
                return Err(DownloadError::ResourceLimit);
            }
            let mut body = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| DownloadError::Transport)?
            {
                if body.len() + chunk.len() > MAX_BODY {
                    return Err(DownloadError::ResourceLimit);
                }
                body.extend_from_slice(&chunk);
            }
            let value: Value =
                serde_json::from_slice(&body).map_err(|_| DownloadError::InvalidResponse)?;
            if value.get("code").is_some()
                || value.get("message").is_some()
                || value.get("error").is_some()
            {
                return Err(DownloadError::ProviderRejected);
            }
            return serde_json::from_slice(&body).map_err(|_| DownloadError::InvalidResponse);
        }
        Err(DownloadError::ProviderUnavailable)
    }
    async fn backoff(
        &self,
        attempt: usize,
        retry_after: Option<&str>,
    ) -> Result<(), DownloadError> {
        let fallback = Duration::from_millis(500 * (1 << attempt) + rand::random::<u64>() % 200);
        let duration = match retry_after {
            Some(value) => {
                let seconds = value
                    .parse::<u64>()
                    .ok()
                    .or_else(|| {
                        DateTime::parse_from_rfc2822(value).ok().map(|d| {
                            (d.with_timezone(&Utc) - Utc::now()).num_seconds().max(0) as u64
                        })
                    })
                    .ok_or(DownloadError::RateLimited)?;
                if seconds > 60 {
                    return Err(DownloadError::RateLimited);
                }
                Duration::from_secs(seconds)
            }
            None => fallback,
        };
        tokio::time::sleep(duration).await;
        Ok(())
    }
    pub async fn download(&self, request: &PanelRequest) -> Result<Value, DownloadError> {
        request.validate(Utc::now())?;
        let started_at = Utc::now().to_rfc3339();
        let mut query = request.query();
        let mut tokens = BTreeSet::new();
        let mut observations = BTreeMap::new();
        let symbols = request.symbols();
        for page_number in 1..=MAX_PAGES {
            let page = self.page(&query).await?;
            for (symbol, bars) in page.bars {
                if !symbols.contains(&symbol) {
                    return Err(DownloadError::UnexpectedObservation);
                }
                for bar in bars {
                    let date = session(&bar)?;
                    if !request.sessions.contains(&date) {
                        return Err(DownloadError::UnexpectedObservation);
                    }
                    if observations.insert((symbol.clone(), date), bar).is_some() {
                        return Err(DownloadError::DuplicateObservation);
                    }
                }
            }
            match page.next_page_token {
                Some(token) => {
                    if token.is_empty() || token.len() > 4096 || !tokens.insert(token.clone()) {
                        return Err(DownloadError::InvalidResponse);
                    }
                    query.retain(|(key, _)| *key != "page_token");
                    query.push(("page_token", token));
                }
                None => return package(request, observations, started_at, page_number),
            }
        }
        Err(DownloadError::ResourceLimit)
    }
}

fn package(
    request: &PanelRequest,
    observations: BTreeMap<(String, NaiveDate), ProviderBar>,
    started_at: String,
    pages: usize,
) -> Result<Value, DownloadError> {
    if observations.len() != request.symbols().len() * request.sessions.len() {
        return Err(DownloadError::IncompleteCoverage);
    }
    let bars_for = |symbol: &str| -> Result<Vec<Value>, DownloadError> {
        request
            .sessions
            .iter()
            .map(|date| {
                let b = observations
                    .get(&(symbol.to_string(), *date))
                    .ok_or(DownloadError::IncompleteCoverage)?;
                Ok(json!({"session":date,"open_cents":cents(&b.o)?,"close_cents":cents(&b.c)?}))
            })
            .collect()
    };
    let series = request
        .symbols
        .iter()
        .map(|s| Ok(json!({"symbol":s,"bars":bars_for(s)?})))
        .collect::<Result<Vec<_>, DownloadError>>()?;
    let panel = json!({"dataset_class":"observed","symbols":request.symbols,"sessions":request.sessions,
        "series":series,"benchmark":bars_for(&request.benchmark)?,"cash_bps":vec![0;request.sessions.len()]});
    let data =
        crate::momentum::Dataset::parse(&panel).map_err(|_| DownloadError::IncompatiblePanel)?;
    crate::momentum::evaluate(&request.spec, &data)
        .map_err(|_| DownloadError::IncompatiblePanel)?;
    let request_bytes = serde_json::to_vec(request).map_err(|_| DownloadError::InvalidRequest)?;
    let request_digest = hex::encode(Sha256::digest(&request_bytes));
    let payload_digest = hex::encode(Sha256::digest(
        serde_json::to_vec(&panel).map_err(|_| DownloadError::InvalidResponse)?,
    ));
    Ok(
        json!({"schema":"market_mate_daily_download_v1","request":request,"request_sha256":request_digest,
        "panel_sha256":payload_digest,"panel":panel,"source_facts":{
            "provider":"alpaca","feed":"sip","currency":"USD","adjustment":"all",
            "normalization":"decimal_max_6_places_half_up_cents_v1","started_at":started_at,
            "received_at":Utc::now().to_rfc3339(),"pages":pages,"symbol_asof":request.symbol_asof,
            "historical_availability":"unknown; retrospective download","benchmark_symbol":request.benchmark,
            "cash":"assumed_zero_interest","registered":false},
        "observations":observations.into_iter().map(|((symbol,date),bar)| json!({"symbol":symbol,"session":date,"bar":bar})).collect::<Vec<_>>() }),
    )
}

#[cfg(test)]
mod tests;
