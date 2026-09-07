# Automatic daily market data: source investigation

Research date: 2026-09-07. Planning evidence only; this document neither approves a source nor authorizes spending. Scope: an owner-only, local US equity momentum experiment, currently requiring a small daily panel, benchmark observations, and an explicit cash-return series.

## Recommendation

**Start with Alpaca Basic historical SIP as the leading free technical candidate.** Review the applicable account terms during setup. This investigation did not establish every archival/replay permission; that is uncertainty, not proof that personal local storage is prohibited. The owner explicitly requested a proportionate personal-project approach, so exhaustive artifact certification is not proposed as a prerequisite to the prototype.

**Tiingo Power is the clearest paid alternative to investigate**, with documented adjusted OHLC and explicit paid-plan persistence rules. Its cancellation-triggered deletion obligation makes it a poor fit for permanent archives unless a separate retention agreement is obtained. A paid subscription is not blanket permission for every artifact class.

The broader `CONTEXT.md` policy is stricter than this personal Local Research proposal. See the [implementation plan](automatic-experiment-data-plan.md) for the narrow simplification requested by the owner. Future Paper/Live qualifications are outside this plan.

## Comparison

| Source | Current technical offer | Rights and retention finding | Fit |
| --- | --- | --- | --- |
| Alpaca Basic | Free; US stocks/ETFs; history since 2016; 200 historical requests/minute. Historical consolidated SIP is available when `end` is at least 15 minutes old; free real-time data is IEX only. | Personal/non-commercial API use is documented. Reviewed terms do not expressly grant durable research archives/replay. Customer agreement section 30 restricts reproduction without written consent. Confirm exact Basic historical SIP permissions and applicable exchange agreements. | First technical choice, conditional on rights. |
| Massive Stocks Basic | Free; two years; end-of-day; all US tickers; five calls/minute; corporate actions. | Terms default to display use and prohibit non-display and derivative investment-strategy use absent a license. Retention permissions were not established. | Do not activate for this worker under default terms. |
| Tiingo Starter / Power | Starter free; Power $30/month or $300/year. Starter lists 500 unique symbols/month, 50 requests/hour, 1,000/day; Power 10,000/hour and 100,000/day. History advertised as 30+ years. | Starter/trial forbids durable storage. Eligible paid plans permit persistence while active, subject to their terms; ending/downgrading requires deletion from local stores, logs, archives, and backups. | Paid fallback after entitlement review; reject free for registered panels. |
| Alpha Vantage | Free 25 requests/day; compact raw daily series returns latest 100 points. Daily Adjusted is premium. | Terms explicitly accommodate private individual investment analysis, research, testing, and monitoring. Full retention/replay and termination rights remain unspecified in reviewed terms. | Free tier cannot finish a 32-stock-plus-benchmark refresh in one day with one call/symbol; adjustment and rights gaps remain. |
| Yahoo / yfinance | Open-source client for Yahoo endpoints. | Yahoo terms prohibit automated collection without prior express permission; the client is not a data license. No adequate archival grant established. | Do not use as unattended default or silent fallback. |

Sources: [Alpaca plans](https://docs.alpaca.markets/us/v1.1/docs/about-market-data-api), [SIP access FAQ](https://docs.alpaca.markets/us/docs/market-data-faq), [Alpaca terms](https://files.alpaca.markets/disclosures/library/TermsAndConditions.pdf), [customer agreement, section 30](https://files.alpaca.markets/disclosures/library/AcctAppMarginAndCustAgmt.pdf); [Massive pricing](https://massive.com/pricing?product=stocks), [market-data terms, sections 1 and 5](https://massive.com/legal/market-data-terms-of-service); [Tiingo pricing](https://www.tiingo.com/about/pricing), [terms, sections 1.6 and 7.3](https://api.tiingo.com/tos/); [Alpha Vantage support](https://www.alphavantage.co/support/), [daily endpoints](https://www.alphavantage.co/documentation/), [terms](https://www.alphavantage.co/terms_of_service/); [yfinance project](https://github.com/ranaroussi/yfinance), [Yahoo terms, section 4](https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html).

Prices and quotas are public-page observations, not account entitlements or tested service guarantees. No API credentials were used. Stooq was not shortlisted because this investigation did not establish suitable primary-source automation and retention permission; downloadable CSVs alone are insufficient.

## Retrieval and price semantics

For a rights-approved Alpaca adapter, use the historical multi-symbol bars endpoint with explicit `feed=sip`, `timeframe=1Day`, currency, start/end, adjustment regime, and symbol `asof`. Complete all pages: the limit applies across symbols and the provider can return fewer records than requested while another page remains. Never rely on a feed default. The `asof` argument resolves symbol identity; it is not a certification of historical information availability. [Historical bars API](https://docs.alpaca.markets/us/reference/stockbars).

Fetch completed sessions on demand for an awaiting ticket; share already permitted observations across compatible requests. Schedule a bounded next-morning catch-up rather than treating market-close arrival as final. Pin the panel after validation; later corrections create a new version and an impact event. Before selecting daily bars as execution-open/close inputs, verify their session/auction construction against the experiment's contract. Daily OHLC should not be assumed to certify executable opening/closing fills.

Keep raw observations and adjustment metadata separate, where permitted. Alpaca exposes raw, split, dividend, spin-off, and combined adjustments. Tiingo exposes raw and adjusted open/close alongside `divCash` and `splitFactor`, with split/dividend adjustment methodology. Massive aggregate adjustment currently covers splits, not dividends; its separate actions endpoints would require extra normalization work. Never combine a raw open with adjusted close. [Alpaca adjustment parameters](https://docs.alpaca.markets/us/reference/stockbars), [Tiingo EOD schema](https://www.tiingo.com/documentation/end-of-day), [Massive adjustment limits](https://massive.com/knowledge-base/article/is-massives-stock-data-adjusted-for-splits-or-dividends).

A current adjusted-history response can contain later-known corrections/actions. Record retrieval time and unknown historical availability honestly. It cannot recreate a decision-time history merely by querying an old date.

## Benchmark and cash dependencies

An ETF such as SPY can be sourced through the same stock/ETF provider, but an ETF return is not the official S&P 500 Total Return series. Use a proxy only if the experiment contract explicitly permits and labels it. Official S&P index data has a separate licensing channel; do not imply equity-feed subscription includes it. [S&P data licensing](https://www.spglobal.com/spdji/en/about-us/data-index-licensing/).

Cash returns require a separate declared methodology and source entitlement. An annual Treasury yield is not a daily realized cash return. A zero-return cash assumption must match the experiment plan and be recorded as an assumption, rather than presented as observed data. Do not silently fill benchmark or cash gaps to make the rectangular panel pass.

## Retention implications

Tiingo's rules demonstrate why a universal permanent-retention setting is unsuitable. Its terms permit only qualifying non-reconstructable Derived Products to survive subscription termination; raw/normalized prices are not automatically such products. Confirm each intended retained output against the actual entitlement. [Tiingo storage and derived-product terms](https://api.tiingo.com/tos/).

Recommended implementation policy, subject to the account's stricter rules:

- Store only fields and dates needed for approved research; do not collect all-market archives speculatively.
- Separate purgeable source payloads and reconstructable derivatives from non-content immutable audit records. Backups must be included in deletion accounting.
- Retain experiment-referenced payloads through their dependency lifecycle only while permitted. An experiment reference never overrides a contractual deletion deadline.
- Apply bounded cleanup to unreferenced observations and successful transient responses; define the exact TTL in the source entitlement instead of hardcoding a universal legal retention period.
- On rights expiry/restriction, contain dependent use immediately, enumerate affected artifacts and backups, purge according to the governing deadline, and verify completion. Mark replay unavailable when inputs must be deleted.
- Do not put provider payloads or keys in Git, general logs, model prompts, or exported reports without explicit artifact-class permission.

## Practical account check

During setup, inspect the applicable account/feed agreement for personal automated research, local storage, and deletion after cancellation. Save the relevant terms/version and account scope. Ask a provider about a material ambiguity if the actual agreement does not answer it; a formal questionnaire covering every artifact class is not required for this personal prototype. Explicit restrictions such as Tiingo free-tier storage and paid cancellation deletion still affect the design. No account agreement was accepted or provider contacted in this task.
