# Paper Execution Venue selection and fidelity requirements

Research date: 2026-08-16
Scope: paper/sandbox API support for Market Mate's U.S. stock and defined-risk options workflow, evaluated independently of the eventual Live Execution Venue. The intended account begins with approximately $1,000 of trading capital.
Method: current first-party broker and API documentation only. A documented API capability is **not** treated as evidence that a simulator models live execution realistically.

## Decision summary

No platform should be certified as the sole source of paper-profitability evidence from documentation alone.

The strongest decision-ready path is a **two-layer paper program**:

1. **Qualify Alpaca first as the primary automated Paper Execution Venue candidate.** It has cloud-suitable key authentication, separate paper endpoints, paper options enabled by default, API multi-leg options, resettable balances, order streams, and the most explicit public fill specification in this group. Its specification also identifies serious optimism: no market impact, information leakage, latency slippage, queue position, price improvement, regulatory fees, or dividends; quantities are not constrained by displayed NBBO size; eligible orders receive randomly sized partial fills only 10% of the time. Therefore Alpaca can certify orchestration, controls, event handling, and reproducibility, but raw paper P&L cannot certify strategy profitability. Full OPRA data currently costs $99/month; the free options feed is indicative rather than actual OPRA quotes. [Alpaca paper-trading specification](https://docs.alpaca.markets/us/docs/paper-trading), [Alpaca market-data plans](https://docs.alpaca.markets/us/docs/about-market-data-api), [Alpaca options trading](https://docs.alpaca.markets/us/docs/options-trading)
2. **Qualify IBKR paper as the comparative execution/lifecycle candidate if the Principal is willing to open and fund an IBKR live account and tolerate its API session ceremony.** IBKR documents top-of-book simulated fills, no deep-book access, limited combo trading, no penny fills for U.S. options, and non-live behavior for partial exchange-directed market orders. Paper uses the Web and TWS APIs with “minimal differences,” carries the live account's permissions, and can share live market-data entitlements. Those disclosures make it valuable as an independent comparison, but not necessarily more realistic: combination and complex-order behavior is explicitly limited, and individual Client Portal API authentication requires an interactive gateway session. [IBKR paper-trading account](https://ibkrcampus.com/campus/glossary-terms/paper-trading-account/), [IBKR Client Portal Web API](https://ibkrcampus.com/campus/ibkr-api-page/cpapi-v1/), [IBKR market-data subscriptions](https://ibkrcampus.com/campus/ibkr-api-page/market-data-subscriptions/)

Test all five Principal-selected candidates under the same matrix, but assign narrower roles unless executable evidence changes the result:

- **Tradier:** integration and order-contract sandbox. Its full Trading API, preview, and 2–4-leg mechanics are useful, but sandbox quotes are delayed 15 minutes, no sandbox streaming feed is offered, indices and Greeks are unavailable, and no public first-party fill model was found. It cannot substantiate earnings-timing or profitability claims without an independent point-in-time market replay and conservative fill overlay. [Tradier trading guide](https://docs.tradier.com/docs/trading), [Tradier market data](https://docs.tradier.com/docs/market-data), [Tradier FAQ](https://docs.tradier.com/docs/faq)
- **tastytrade:** API contract and daily lifecycle smoke-test sandbox. It exposes sandbox REST and account-stream hosts plus complex-order, dry-run, margin, balance, position, and transaction primitives. But the sandbox deletes all trades, transactions, positions, and balances every 24 hours and always delays quotes by 15 minutes. Public documentation reviewed does not define its fill algorithm, partial fills, queue treatment, simulated fees, assignment/exercise behavior, or paper/live order parity. It is unsuitable for longitudinal paper performance unless tastytrade supplies a persistent environment or the project treats Market Mate's own immutable ledger as authoritative and separately proves lifecycle continuity. [tastytrade sandbox](https://developer.tastytrade.com/sandbox/), [tastytrade order management](https://developer.tastytrade.com/order-management/), [tastytrade basic API usage](https://developer.tastytrade.com/basic-api-usage/)
- **Schwab/thinkorswim paperMoney:** manual usability and adverse-fidelity reference, not an automated Paper Execution Venue on current evidence. Schwab documents a GUI simulator with equities, options, spreads, resettable virtual funds, and trade history. It also warns that option fills may occur favorably near the midpoint and that paperMoney does not simulate early assignment. Default stock paperMoney data may be delayed 20 minutes. No accessible first-party evidence found in this review shows that the Individual Trader API can place or reconcile paperMoney orders. [Schwab paperMoney options tutorial](https://www.schwab.com/content/thinkorswim-papermoney-simulated-options-trading), [Schwab paperMoney stock tutorial](https://www.schwab.com/content/thinkorswim-papermoney-stock-trading-simulator), [Schwab Individual Trader API product](https://developer.schwab.com/products/trader-api--individual)

The Paper Execution Venue may differ from the Live Execution Venue. Paper qualification is capability-scoped: a venue may qualify for stock order orchestration while options spreads, index options, expiration, or assignment remain uncertified.

## What documentation can and cannot establish

Use three evidence labels throughout certification:

- **Documented:** a current first-party source states the behavior.
- **Observed:** Market Mate produced and retained an executable test artifact.
- **Unknown:** neither of the above exists. Unknown is not a pass, a fail, or permission to infer live parity.

Only an executable result can change a requirement from Documented/Unknown to Observed. Simulator P&L can be accepted as strategy evidence only after the relevant fill, market-data, fee, and lifecycle assumptions are both documented and measured. When a venue behavior is optimistic or unknown, Market Mate must apply an independently versioned conservative simulation overlay or abstain from using that result for promotion.

## Comparative evidence table

| Capability | Alpaca | IBKR | Tradier | tastytrade | Schwab/thinkorswim |
|---|---|---|---|---|---|
| **Paper access prerequisite** | Free Paper Only account available with email; paper API keys are separate. Options enabled by default in paper. | New clients receive paper after live account opening; first-party API material says the regular account must be approved and funded for associated paper/API use. | Tradier Brokerage account and sandbox token. API access is free to brokerage account holders. | Separate sandbox registration and credentials; email must be confirmed within 3 days. | paperMoney is part of thinkorswim; a 30-day Guest Pass exists, and clients have ongoing access. API paper access is unproven. |
| **Cloud/API authentication** | Static paper API key/secret against `paper-api.alpaca.markets`; suitable for a service, subject to secret controls. | Web API paper login uses the unique paper username through Client Portal Gateway. Individual Web API authentication is interactive, 2FA-protected, expires at least daily, and can time out without keepalive. TWS/IB Gateway must be tested separately. | Non-expiring individual bearer token; separate sandbox base URL/token. | Current FAQ states access tokens last 15 minutes; separate sandbox credentials. OAuth/session refresh behavior must be proved from the intended cloud runtime. | GUI login documented. Paper-enabled Individual Trader API authentication and endpoints are unknown. |
| **Stock / fractional** | Stocks and fractional stock API support are documented; paper/live eligibility must be enumerated by asset. | Stocks are supported; fractional permission and paper behavior follow account configuration but require an executable proof for this scope. | Equity orders supported; fractional orders not established in reviewed paper documentation. | Equities and a fractional-stock order schema are present in API docs; sandbox execution must be proved. | Stocks supported in GUI; fractional paper/API support unknown. |
| **Single-leg options / index options** | Single-leg options paper-enabled. A first-party tutorial updated in July 2026 says index options are enabled in paper; the exact eligible contract list must be captured. [Alpaca options API tutorial](https://alpaca.markets/learn/how-to-trade-options-with-alpaca) | U.S. equity and index options supported subject to live permissions and entitlements. | Equity/ETF options supported; sandbox index data is unavailable even though option roots may be discoverable. | Equity options documented; sandbox index-option product availability must be enumerated. | Options supported in GUI; index scope and API access unproven. |
| **Atomic 2–4-leg options** | Level 3 `mleg` paper orders are documented and presented as filling together or not at all. Test 2-, 3-, and 4-leg acceptance and per-leg event reconciliation. | Combination orders exist, but paper documentation says combo trading is limited and complex orders are simulated. Exchange and routing behavior may differ live. | `multileg` supports up to four option legs, debit/credit/even pricing, and preview. Atomic fill semantics are not publicly specified. | Complex orders and dry-runs are documented; maximum legs, atomicity, and sandbox fill semantics need proof. | GUI spread orders demonstrated. Four-leg/API atomicity unproven. |
| **Market-data timeliness** | Paper engine is described as using current best prices. User-visible Basic API data is IEX-only for equities and indicative for options; complete SIP/OPRA is $99/month. Do not assume the observable feed and simulator feed are identical without a timestamped comparison. | Paper can share live user entitlements. API market data usually requires subscriptions and at least $500 plus subscription cost retained in the account. Top-of-book is documented; deep book is not used by the paper simulator. | Sandbox equity/options data delayed 15 minutes; no sandbox stream; indices and Greeks unavailable. | Sandbox quotes always delayed 15 minutes. | Schwab describes real-time simulated data generally, while its stock tutorial says the default may be delayed 20 minutes. Record actual entitlement state. |
| **Published fill model** | Most explicit: marketability against best ask/bid; no displayed-size constraint; random-size partial fills 10% of eligible orders; documented omissions include impact, queue, latency slippage, improvement, fees, and dividends. | Explicit: top-of-book only; limited combos; no U.S. option penny fills; special remainder handling for exchange-directed market orders; missing opposite quote holds market order. | **Unknown.** Full API and delayed quotes do not establish fill price, queue, size, latency, partial fill, or rejection realism. | **Unknown.** Public sandbox docs reviewed specify reset/data behavior, not the fill engine. | Schwab warns option paper fills can be favorably near midpoint. Full queue, latency, partial-fill, and rejection model unknown. |
| **Buying power / margin / fees** | Paper simulates buying-power/PDT checks, but documented omissions include regulatory fees and borrow fees. Exact options margin and all costs must be tested. | Paper inherits live configuration and fluctuates as if trades executed; statements are available. Complex-order/commission parity still needs comparison. | Preview runs validations including buying power and can return cost, fees, commission, and margin change. Whether sandbox values equal live is unknown. | Balance, derivative buying power, order dry-run, and margin dry-run APIs exist. Sandbox correctness and simulated fees are unknown. | GUI provides margin/IRA accounts and virtual buying power; paper commissions/history are visible. API reconciliation is unavailable on current evidence. |
| **Exercise / assignment / expiration / DNE** | APIs and activity types exist. Paper balance/positions update immediately, but paper non-trade activities appear in Activities only the following day; assignment is not sent over order WebSockets and must be polled. | TWS supports exercise APIs and paper shares live permissions, but the simulator's assignment, early exercise, expiration, cash settlement, and event timing are not sufficiently documented for certification. | Dedicated paper exercise/DNE endpoints and assignment/expiration event timing were not found. | Instrument expiration metadata exists; public sandbox exercise/DNE/assignment simulation and event timing remain unknown. | Schwab explicitly says paperMoney does not assign short options early; other API lifecycle behavior is unknown. |
| **Corporate actions** | Activity APIs enumerate splits, dividends, mergers, symbol changes, reorganizations, and option corporate actions, but the paper specification says dividends are not simulated. Test each supported paper event. | Reporting and account updates exist; paper corporate-action simulation and timing require proof. | No adequate sandbox corporate-action simulation contract found. | Transactions/positions exist; sandbox corporate-action simulation not documented. Daily deletion prevents multi-day continuity. | GUI behavior may be observable; API paper event contract unknown. |
| **Order/account events and reconciliation** | WebSocket trade updates plus REST orders, positions, and account activities. Options non-trade events require polling; activities distinguish fills, corrections, busts, fees, assignments, exercises, expiries, cash settlement, and corporate actions. | Web/TWS APIs expose order/account/trade data and paper statements/Flex Queries. Session resets, endpoint pacing, and multiple P&L update schedules require reconciliation tests. | REST order/account endpoints and order statuses exist; sandbox streaming is absent, so polling is required. | Sandbox account WebSocket plus REST orders, balances, positions, transactions; daily reset means the broker ceases to be a durable ledger. | GUI history/export exists. No proven paper API event or reconciliation path. |
| **Persistence and reset** | User may reset/delete paper accounts; resetting requires new API credentials. The initial balance can be configured/reset. Retention guarantees should be confirmed. | Starts at $1,000,000. Client Portal can reset paper equity; an IBKR Student Lab guide explicitly permits a manually entered amount, but applicability to the intended individual account must be proved. Daily statements and Flex Queries are available. | Reset controls and retention guarantees not found in reviewed docs. | **Hard 24-hour reset:** trades, transactions, positions, and balances are deleted; users/accounts remain. | Virtual funds/positions can be reset; history/export documented. Retention guarantee unknown. |
| **Rate limits / maintenance** | Market-data plan documents 200 requests/minute Basic and 10,000/minute Plus for historical data; Trading API and WebSocket limits/maintenance must be captured during qualification. | Web API global 10 requests/second plus stricter endpoint pacing; nightly `/iserver` reset and Saturday maintenance. | Sandbox 60 requests/minute; no delayed sandbox streaming. | Current public numerical rate limits and maintenance commitments were not found; failed-login bursts can block an IP for about eight hours. | Paper/API rate limits and maintenance unknown. |
| **Paper/live API parity** | Same end-to-end Trading API except live routing; Alpaca explicitly lists simulation omissions. Strong contract parity, incomplete economic parity. | Web/TWS APIs usable in paper with “minimal differences,” but IBKR separately documents important simulator limitations. | Sandbox supports the full Trading API, but market data/streaming and fill behavior materially differ. | Similar REST/account-stream surfaces, but daily reset and delayed data are material differences; further parity unknown. | paperMoney mirrors thinkorswim UI, not proven Individual Trader API parity. |
| **Usability** | Best documented service ergonomics: keys, resettable accounts, dashboard, SDKs, REST/WebSocket. | Richest reporting and product breadth, but gateway/session/permissions/data setup creates the highest operating burden. | Simple bearer token and REST contract; delayed polling-only sandbox makes realistic testing cumbersome. | Good API primitives and dedicated public sandbox; daily state deletion makes longitudinal testing operationally costly. | Best manual strategy-learning GUI of the group; unusable as an autonomous venue until API paper access is proven. |
| **Paper cost relevant to $1,000 experiment** | Free Basic paper/data, but full real-time SIP/OPRA currently $99/month (an operating cost equal to 9.9% of initial trading capital each month, though operating costs are funded separately). | Paper included with an opened/funded live account. Market-data API subscriptions may require $500 account equity plus subscription charges. | API/sandbox included for brokerage account holders; delayed data only. | Sandbox registration available; current public documentation does not establish a separate sandbox fee. | paperMoney included for clients; 30-day Guest Pass available. API uncertainty dominates price. |

## Venue-specific findings and unknowns

### Alpaca

Documented strengths:

- A Paper Only account is available without funding and paper trading uses separate API credentials/endpoints. Alpaca describes paper as the same end-to-end system except that an exchange does not receive the order. [Paper trading](https://docs.alpaca.markets/us/docs/paper-trading)
- The fill specification makes several assumptions testable: orders become fill-eligible at the best ask/bid; displayed size is ignored; random partial fills occur 10% of the time; and the simulator omits impact, leakage, latency slippage, queue priority, improvement, fees, and dividends. These omissions must be converted into conservative, versioned penalties rather than buried in a disclaimer. [Paper trading](https://docs.alpaca.markets/us/docs/paper-trading)
- Multi-leg Level 3 is available in paper, and Alpaca states combined option legs execute simultaneously rather than legging. [Multi-leg options in paper](https://docs.alpaca.markets/us/v1.1/changelog/multi-leg-level-3-options-trading-in-paper), [Level 3 options](https://docs.alpaca.markets/us/docs/options-level-3-trading)
- Options non-trade activities include assignment, expiration, and exercise. In paper, balances and positions update immediately but those activities are synchronized to the Activities endpoint only the next day; assignment is not an order-WebSocket event. [Options trading](https://docs.alpaca.markets/us/docs/options-trading), [Account activities](https://docs.alpaca.markets/us/docs/account-activities)
- The Basic plan is free but exposes only IEX equities and indicative options. Algo Trader Plus costs $99/month and adds consolidated equities plus OPRA. [Market-data plans](https://docs.alpaca.markets/us/docs/about-market-data-api)

Material unknowns or limitations:

- Whether the paper fill engine for options uses actual OPRA NBBO, the account's visible indicative feed, or a separate internal feed is not stated clearly enough in the first-party specification. Capture simultaneous engine events and OPRA observations.
- Multi-leg fill-price construction, improvement, partial execution at the leg-event level, cancel/replace races, and behavior under crossed/locked/stale markets need measurement.
- Regulatory fees, dividends, market impact, latency slippage, and queue position are explicitly absent. A raw paper Sharpe ratio, win rate, or earnings return is not promotion-grade evidence.
- Corporate-action activity types exist, but paper dividends are explicitly not simulated; the set/timing of other simulated corporate actions requires proof.
- A paper reset rotates credentials, creating a testable operational recovery requirement. [Market Data FAQ](https://docs.alpaca.markets/us/docs/market-data-faq)

### Interactive Brokers

Documented strengths:

- IBKR explicitly documents its simulator's construction: top-of-book fills only, no deep-book access, limited combo trading, no penny fills for U.S. options, special handling of partially executed exchange-directed market orders, and held market orders when no opposite quote exists. [Paper Trading Account](https://ibkrcampus.com/campus/glossary-terms/paper-trading-account/)
- Web and TWS APIs work with paper accounts with minimal functional differences. Paper uses the live account's permissions, base currency, and other configuration; market-data entitlements can be shared from the live username. [Paper Trading Account](https://ibkrcampus.com/campus/glossary-terms/paper-trading-account/), [Market Data Subscriptions](https://ibkrcampus.com/campus/ibkr-api-page/market-data-subscriptions/)
- Paper equity can be reset in Client Portal. An IBKR Student Trading Lab guide explicitly allows an `Other` manually entered amount, which would permit a $1,000 bankroll test, but the certification must prove that option is also available to this intended individual account. Daily statements and customizable Flex Queries support independent reconciliation. [Paper Trading Account Reset](https://www.ibkrguides.com/student-trading-lab-student/en-us/account-reset.htm), [Portal for a Paper Trading Account](https://www.ibkrguides.com/orgportal/portalforpapertradingaccount.htm)

Material unknowns or limitations:

- “Minimal differences” is not an execution-fidelity guarantee; IBKR simultaneously states that combo/complex-order behavior is limited or simulated.
- Early assignment, exercise, DNE, expiration, cash settlement, fee, and corporate-action simulation semantics/timing are not documented sufficiently for the Options Lifecycle Engine.
- Client Portal Gateway authentication is incompatible with mature unattended cloud operation for an individual account: interactive login and 2FA are required, the brokerage session resets daily and idles out unless tickled, and a username can maintain only one active brokerage session. [Client Portal Web API](https://ibkrcampus.com/campus/ibkr-api-page/cpapi-v1/)
- Most API market data needs paid entitlements; IBKR documents an opened Pro account and $500 in equity in addition to subscription cost as prerequisites. [Market Data Subscriptions](https://ibkrcampus.com/campus/ibkr-api-page/market-data-subscriptions/)
- Web API is capped at 10 requests/second globally with lower limits for some reconciliation endpoints; brokerage functions reset nightly. [Web API operations](https://ibkrcampus.com/campus/ibkr-api-page/webapi-doc/)

### Tradier

Documented strengths:

- Individual users receive separate live and sandbox bearer tokens, and individual tokens do not expire. Sandbox supports the full Trading API with paper money. [Tradier authentication](https://docs.tradier.com/docs/authentication), [Tradier trading](https://docs.tradier.com/docs/trading)
- The order API supports equities, single-leg options, and up to four pure-option legs. `preview=true` executes validations including buying-power checks and can return commission, fees, cost, and margin change. [Tradier trading](https://docs.tradier.com/docs/trading)
- Sandbox is rate-limited to 60 requests/minute. [Tradier rate limits](https://docs.tradier.com/docs/rate-limiting)

Material unknowns or limitations:

- Sandbox equities and options data are delayed 15 minutes, index data and Greeks are unavailable, and Tradier provides no delayed streaming endpoint. [Tradier market data](https://docs.tradier.com/docs/market-data), [Tradier FAQ](https://docs.tradier.com/docs/faq)
- No current first-party page found in this review defines the sandbox fill-price rule, size/liquidity constraint, queue position, partial fills, latency, price improvement, simulated fees, or rejection differences.
- Four-leg submission is not proof of atomic simulated fill or live atomic routing.
- Paper exercise, assignment, expiration, DNE, cash settlement, and corporate-action simulation/event timing remain unknown.
- Sandbox reset controls, persistence guarantees, and history retention are not publicly specified in the reviewed documentation.

### tastytrade

Documented strengths:

- tastytrade supplies a dedicated certification sandbox REST base URL and account-stream WebSocket host. Its API exposes balances, positions, transactions, orders, complex orders, order dry-runs, and margin dry-runs. [Sandbox](https://developer.tastytrade.com/sandbox/), [Basic API Usage](https://developer.tastytrade.com/basic-api-usage/), [Order Management](https://developer.tastytrade.com/order-management/), [Margin Requirements API](https://developer.tastytrade.com/open-api-spec/margin-requirements/)
- The current API FAQ says access tokens last 15 minutes, and separate sandbox/production credentials are required. It also documents an approximately eight-hour IP block after excessive failed logins. [API FAQ](https://developer.tastytrade.com/faq/)
- Instrument data includes exercise style, settlement, contract multiplier, expiration, and closing-only status; account authority values distinguish owner, trade-only, and read-only. [Basic API Usage](https://developer.tastytrade.com/basic-api-usage/)

Material unknowns or limitations:

- Every 24 hours the sandbox deletes trades, transactions, positions, and balances. That is incompatible with native multi-day/multi-week strategy accounting and options lifecycle tests. [Sandbox](https://developer.tastytrade.com/sandbox/)
- Quotes are always delayed 15 minutes. [Sandbox](https://developer.tastytrade.com/sandbox/)
- No current public first-party fill specification was found for price, NBBO relation, size, queue, partial fills, latency, improvement, or fees.
- Exact complex-order leg limits/atomicity, sandbox assignment/expiration/exercise/DNE behavior, corporate actions, numerical rate limits, maintenance windows, and live parity remain unproven.

### Schwab/thinkorswim paperMoney

Documented strengths:

- paperMoney supports simulated equities/options and spread entry, provides virtual margin and IRA accounts, exposes trade history/P&L, supports export, and permits resets. [Options tutorial](https://www.schwab.com/content/thinkorswim-papermoney-simulated-options-trading), [Practice Trading](https://www.schwab.com/learn/story/practice-trading-risk-free-with-papermoney)
- Schwab offers paperMoney through thinkorswim clients and a 30-day Guest Pass. [thinkorswim Guest Pass](https://international.schwab.com/trading/thinkorswim/guestpass)

Material unknowns or limitations:

- Schwab warns that paper option orders may receive favorable midpoint fills as spreads widen and that short options are not assigned early. These are direct disqualifiers for treating unadjusted paperMoney options results as live-profitability evidence. [Options tutorial](https://www.schwab.com/content/thinkorswim-papermoney-simulated-options-trading)
- The stock tutorial shows data may be delayed 20 minutes by default, while other Schwab pages describe real-time simulated data. Entitlement state must be captured per test. [Stock tutorial](https://www.schwab.com/content/thinkorswim-papermoney-stock-trading-simulator), [paperMoney overview](https://international.schwab.com/thinkorswim/paper-money-trading)
- No accessible first-party evidence reviewed connects the Individual Trader API to paperMoney order submission, events, balances, positions, or statements. Without that proof, paperMoney cannot be an autonomous Paper Execution Venue.
- Partial fills, queue, latency, rejections, fees, exercise/expiration beyond no early assignment, corporate actions, API rate limits, and paper/live API parity remain unknown.

## Qualification and fidelity test matrix

Run the same tests against every candidate. Preserve both successful and failed cases. Use liquid and deliberately illiquid test instruments without treating any test symbol as an investment recommendation.

| Test family | Required experiment | Passing evidence | Hard-gate consequence |
|---|---|---|---|
| **Access and cloud auth** | Authenticate from the intended cloud runtime; rotate/revoke credentials; survive expiration, restart, 2FA/session, and maintenance behavior. | Timestamped auth logs, documented renewal process, revocation proof, recovery time, no withdrawal-capable credential where the platform supports least privilege. | Cannot qualify for autonomous paper if recurring human login is required; may qualify as supervised comparison only. |
| **$1,000 bankroll** | Set/reset the paper account to exactly $1,000; verify cash, equity, buying power, margin mode, options level, and PDT behavior. | Before/after account snapshots and broker UI/statement. | If exact balance cannot be represented, adapter must enforce a shadow $1,000 sub-ledger and prove all admission decisions use it. |
| **Instrument identity** | Enumerate stocks, fractionals, equity options, index options, adjusted contracts, multipliers, exercise/settlement style, expirations, and tradability. | Immutable contract snapshot tied to every order. | Unknown identity or settlement blocks the affected capability. |
| **Order schema** | Preview and submit stock, fractional, long option, 2-leg vertical, 3-leg, and 4-leg defined-risk orders; test market/limit, GTC/day, cancel/replace, duplicate client IDs, malformed orders, and closed-market rejection. | Raw requests/responses, broker/client/leg IDs, validation and rejection codes. | No 4-leg/atomic proof blocks multi-leg qualification, not stock qualification. |
| **Atomicity** | Submit marketable and nonmarketable 2–4-leg orders; cancel during transitions; disconnect during execution. | Proof that the venue either fills the package atomically or exposes every leg/partial state without creating hidden naked exposure. | Any undocumented legging or irreconcilable state blocks Options Engine qualification. |
| **Quote alignment** | Capture venue-visible quotes and an independent licensed SIP/OPRA stream at submission, acknowledgement, and fill. Include locked, crossed, wide, stale, and one-sided markets. | Nanosecond/millisecond timestamps, entitlement metadata, feed/exchange fields, clock offset. | Delayed/indicative data cannot certify event-timed profitability. |
| **Fill-price model** | Place passive and aggressive limits at bid, midpoint, ask, inside/outside spread; repeat across spread/liquidity buckets. | Empirical fill probability, price distribution, and time-to-fill by quote state; compare to published rule. | Undocumented/unmeasurable models require conservative overlay and cannot alone certify profit. |
| **Displayed size and partial fills** | Submit quantities below, equal to, and above displayed size; create cancel/replace races. | Full transition ledger showing quantities, per-leg fills, timestamps, remaining quantity, and terminal state. | Impossible fills must be penalized or excluded from strategy evidence. |
| **Latency and outage** | Inject client/network latency, drop streams, retry POSTs, exceed rate limits, cross scheduled maintenance, and recover after missed events. | No duplicate order, deterministic idempotency, successful snapshot/stream reconciliation, measured recovery objective. | Duplicate/unknown orders or unrecoverable drift blocks qualification. |
| **Rejections and buying power** | Exhaust stock/options buying power; breach $1,000 Risk Policy; submit unsupported contracts/price increments/expiration orders. | Preview and submit agree within defined tolerance; rejection reason is deterministic; Safety Kernel fails closed. | Silent acceptance, inconsistent risk state, or unavailable buying-power evidence blocks capability. |
| **Fees and economics** | Compare preview, fill, transaction ledger, and statement for commissions, exchange/OCC/ORF/CAT/regulatory fees and interest. | Every cent reconciles; omissions are explicit in a versioned conservative fee overlay. | Raw paper P&L is unusable if missing costs are neither measured nor overlaid. |
| **Options lifecycle** | Hold long/short legs through early-assignment windows and expiration; exercise, DNE, ITM/OTM expiry, insufficient buying power, and cash settlement. | Timed order/account/activity/position/cash events and expected Safety Kernel response. | Missing or next-day-only events must be modeled; unobserved lifecycle blocks live-like certification. |
| **Corporate actions** | Test split, special dividend, merger, symbol change, adjusted option, halt/delisting where the sandbox supports them. | Position/cost-basis/instrument remap and financial ledger reconcile. | Unsupported cases remain explicitly uncertified and require replay fixtures. |
| **Persistence/reset** | Run across at least 20 consecutive trading sessions and two expirations; restart services; reset venue; rotate keys. | Market Mate ledger reconstructs state before broker mutation and records a new environment epoch after reset. | Daily broker deletion disqualifies venue-native longitudinal accounting. |
| **Paper/live parity** | On the eventual Live Venue only and after Principal approval, run smallest permitted live orders paired with same-day paper cases. | Distribution of acknowledgement, rejection, fill, slippage, fees, margin, and lifecycle differences. | Paper certification never substitutes for minimum-size live certification. |
| **Usability/operator burden** | Principal completes credential setup, balance reset, data entitlement, incident recovery, statement retrieval, and kill procedure. | Timed task completion, error count, required human touchpoints, screenshots, and documented support path. | Recurrent human intervention may restrict the venue to supervised use even if API tests pass. |

## Minimum evidence bundle

A Paper Execution Venue capability cannot be certified until one versioned bundle contains:

1. Venue, environment, adapter commit, API/schema version, test-suite version, account configuration, option permissions, $1,000 shadow/actual bankroll, data subscriptions, fee schedule, and test dates.
2. Current first-party documentation snapshots or durable links for authentication, endpoints, rate limits, maintenance, market-data entitlement, fill assumptions, paper/live differences, and lifecycle behavior.
3. Written broker answers for every material Unknown, including whether four-leg orders are atomic in the simulator and how assignment/expiration are represented.
4. Redacted raw HTTP/WebSocket requests and responses, headers carrying rate-limit state, client IDs, venue IDs, leg/execution IDs, rejection messages, and synchronized timestamps.
5. Independent licensed SIP/OPRA quote observations around every options submission/fill used in fidelity analysis, including feed name and entitlement.
6. REST snapshot/stream reconciliation results after planned disconnects, rate limiting, duplicate retries, maintenance, and service restarts.
7. Account snapshots and broker statements/reports proving cash, positions, buying power, fees, adjustments, and P&L reconcile to Market Mate's cent-level ledger.
8. At least 20 consecutive trading sessions of adapter qualification, 100 stock order attempts, 100 single-leg option attempts, and 100 multi-leg attempts across marketability/liquidity buckets. This is an adapter/fidelity minimum, not the separate duration/sample required for Strategy Version promotion.
9. At least two tested expiration cycles plus every lifecycle/corporate-action case the venue supports; unsupported cases are listed rather than synthesized as passes.
10. A measured paper-versus-live delta report before any strategy relies on paper evidence for Live authorization.
11. Operator usability record: setup/recovery time, manual steps, incidents, support responses, cost, and failed attempts.
12. A signed certification result listing each capability as Paper Certified, Supervised Only, Uncertified, or Inapplicable, with an expiry trigger for API, simulator, fee, entitlement, authentication, margin, routing, or lifecycle changes. Paper Certified never implies Live Certified.

## Hard gates and scoring

### Hard gates

These gates apply per capability. Failure does not prevent a venue from serving a narrower, explicitly labeled role.

1. Intended cloud runtime can authenticate and recover without exposing credentials or creating unbounded order authority.
2. Every submitted order has stable client/venue identity, deterministic idempotency, observable terminal state, and snapshot reconciliation.
3. Actual or shadow buying power is constrained to the $1,000 bankroll and the same Risk Policy used for future Live trading.
4. The affected instrument/order class is supported, and multi-leg qualification proves package atomicity or fully observable legging behavior.
5. Market-data source and timeliness are known; delayed/indicative data cannot be represented as live NBBO.
6. Fill behavior is either documented and empirically confirmed or replaced by a conservative, versioned overlay. Unknown optimism is a failure.
7. All omitted fees/costs are conservatively applied and every cent reconciles.
8. Required exercise, assignment, expiration, DNE, and corporate-action events are observable in time for the Safety Kernel, or the affected lifecycle capability remains uncertified.
9. Tests, state, and evidence are reproducible across the required window even if the venue resets.
10. The dashboard labels simulator limitations and Paper/Live differences; paper results cannot be shown as expected live returns.

Schwab currently fails Gate 1 for automated paper on public evidence. tastytrade's native environment fails Gate 9 for longitudinal accounting because of the daily deletion, though Market Mate can still qualify a narrow daily API contract. Tradier cannot pass Gates 5–6 for profitability evidence from its sandbox alone. Alpaca and IBKR still require execution of all gates.

### Weighted score after hard gates

Score each capability from 0–5 and publish both the raw result and evidence confidence. Missing evidence scores zero rather than receiving an estimate.

| Weight | Dimension |
|---:|---|
| 25% | Measured execution fidelity: bid/ask relation, size, partial fills, latency, rejections, conservative bias, and paper/live delta |
| 20% | Options and lifecycle fidelity: atomic 2–4-leg behavior, buying power, exercise, assignment, expiration, DNE, cash settlement, corporate actions |
| 15% | Event completeness and reconciliation: identifiers, streams, replay, corrections/busts, statements, cent-level ledger agreement |
| 15% | Cloud operability and resilience: authentication, rate limits, maintenance, reset/persistence, incident recovery |
| 10% | Market-data quality and entitlement transparency |
| 10% | Principal/developer usability: setup, documentation, dashboard, support, recovery burden |
| 5% | Capability-adjusted operating cost, including data and required account funding |

Do not collapse evidence confidence into the same number. Report, for example, `4.0/5 capability, 60% evidence coverage`; an attractive feature with unknown simulator behavior must remain visibly uncertain.

## Recommended qualification sequence

1. **Alpaca first:** establish the common adapter contract, $1,000 balance, stock/single-leg/multi-leg tests, event reconciliation, and explicit conservative fill/fee overlay. Run one cohort on Basic and one on paid OPRA only if the data-budget decision authorizes the $99/month operating cost.
2. **Tradier second:** exercise the same contract to expose portability and broker-specific rejection/preview differences. Restrict conclusions to API/safety behavior unless fill questions receive written answers and pass independent replay checks.
3. **tastytrade third:** run within a single sandbox epoch, deliberately cross the 24-hour reset, and prove Market Mate preserves an immutable external ledger and creates a new environment epoch. Do not call this a longitudinal Paper Venue unless tastytrade changes or documents persistent access.
4. **IBKR fourth:** after Principal-approved account opening/funding, reset paper equity to $1,000, link entitlements, test Web and/or TWS API operations, and use it as a cross-venue fill/lifecycle comparison. Classify the Client Portal path as supervised while interactive daily authentication remains.
5. **Schwab/thinkorswim fifth:** complete a manual GUI/usability and adverse-fill study. Ask Schwab in writing whether Individual Trader API paperMoney access exists. Unless documented and proved, do not build a paper adapter or count GUI results as automated certification.
6. **Cross-venue calibration:** submit matched, non-manipulative paper orders around the same synchronized quote states; compare fill eligibility, time, price, partials, margin, and events. A strategy passes only under the most conservative credible result or the separately validated internal replay overlay—not the most favorable venue.
7. **Minimum-size live calibration:** after the broader paper-validation gate and explicit Principal approval, compare smallest permitted live orders to paper. This is required even if the Paper and Live Execution Venues differ.

## Newly surfaced decisions

1. **Conservative Simulation Overlay contract:** define the independent fill, latency, queue, impact, partial-fill, fee, assignment, and corporate-action rules used whenever a broker simulator is optimistic or unknown. Decide whether the overlay is a mandatory second opinion for every Strategy Version.
2. **Paper qualification duration versus Strategy promotion duration:** this report proposes 20 sessions/100 attempts per order class for adapter qualification, but the full paper-trading promotion gate still needs its own chronological duration, sample-size, regime, and drawdown requirements.
3. **Market-data entitlement and budget:** decide whether the $99/month Alpaca OPRA plan and IBKR subscriptions provide enough incremental evidence for their operating cost, or whether a provider-neutral licensed feed supplies all qualification observations.
4. **IBKR paper-access authority:** decide whether opening/funding an IBKR account solely to access paper and market data is acceptable before a Live Venue is selected; otherwise IBKR remains documentary/supervised only.
5. **tastytrade environment role:** decide whether the 24-hour-reset sandbox is worth supporting as an API conformance target, or whether its daily deletion makes it nonessential until a persistent environment is offered.
6. **Schwab paper API proof:** obtain a written first-party answer and approved-app documentation before deciding whether thinkorswim belongs in automated adapter scope or only manual usability/fidelity benchmarking.
7. **Paper certification scope and expiry:** define the exact labels, evidence-coverage floor, review cadence, and automatic invalidation triggers for each certified capability.

## Bottom line

Choose **Alpaca as the first automated qualification candidate**, not as a pre-certified profitability simulator. Add **IBKR paper as the independent comparison** only when its live-account prerequisite and supervised authentication are acceptable. Use **Tradier** and **tastytrade** to test adapter portability and broker-specific contracts within their documented data/reset limits. Treat **thinkorswim paperMoney** as a manual usability and optimistic-fill warning benchmark until Schwab proves paper API access.

For Market Mate, “heavily validated paper trading” should mean agreement across the broker simulator, an independent licensed quote record, a conservative simulation overlay, and later minimum-size live calibration. It must never mean accepting a venue's displayed paper P&L at face value.
