# Market Mate

Market Mate is an autonomous, self-directed trading system for a single individual. It is planned to operate only within explicit risk, compliance, and authority boundaries.

## Participants and accounts

**Principal**:
The individual who owns the brokerage account, supplies capital, and sets the system's authority and risk boundaries.
_Avoid_: customer, client, account owner

**Brokerage Account**:
The Principal's live account at a regulated broker, which holds real cash and securities and is the sole source of live order execution.
_Avoid_: wallet, exchange account

**Paper Account**:
A simulated account whose orders, positions, balances, and outcomes contain no real cash or securities.
_Avoid_: demo Brokerage Account, test wallet

**Execution Environment**:
The explicit boundary classifying an action and all of its records as either Paper or Live. Paper and Live records are never commingled, even when shown together.
_Avoid_: mode, account type

**Trust Zone**:
A workload boundary with its own identity, secret scope, network policy, queues, data permissions, and audit controls. Trust Zones may initially share a physical host, but authority never follows from co-location.
_Avoid_: server, container name

**Application Administration**:
Principal-facing control over Market Mate policies, proposals, deployments, alerts, strategies, and operational state through authenticated, authorized workflows. It never implies unrestricted host, cloud-account, secret, or database access.
_Avoid_: cloud administration, root access, admin panel

**Infrastructure Administration**:
Separately authenticated control over the cloud account, host, identity and access management, network perimeter, key custody, and privileged recovery. It is not exposed as a general capability through Market Mate.
_Avoid_: application settings, Principal dashboard

**Execution Venue**:
The external broker or simulator that accepts orders for an Execution Environment. Paper and Live execution may use different venues.
_Avoid_: platform, broker API

**Trade Intent**:
The venue-neutral economic action proposed by a Strategy Version, including instruments, structure, direction, sizing, price economics, timing, lifecycle expectations, and required capabilities. It is not an executable broker payload.
_Avoid_: order, signal

**Order Plan**:
The fully specified, venue-neutral execution plan derived from a Trade Intent, including exact instruments, leg ratios, quantities, net economics, limits, timing, lifecycle handling, required capabilities, and the narrow adaptations an adapter may perform.
_Avoid_: broker request, strategy idea

**Risk Decision**:
The Safety Kernel's immutable approval or rejection of one exact Order Plan against a specified Risk Policy and broker-reconciled account snapshot. Any economic plan change requires a new Risk Decision.
_Avoid_: risk score, model approval

**Venue Order**:
The exact authenticated payload an adapter transmits to an Execution Venue for an approved Order Plan, linked to the venue, environment, adapter version, and client identity.
_Avoid_: Order Plan, Trade Intent

**Venue Event**:
An immutable raw and normalized observation from an Execution Venue about order, execution, account, correction, or lifecycle state, preserving both venue and receipt timing.
_Avoid_: log entry, current status

**Execution Result**:
The reconciled outcome of an Order Plan, including executions, fees, positions, cash effects, deviations, uncertainty, and links to all Venue Events and ledger entries.
_Avoid_: fill, P&L

**Broken Package Exposure**:
An unexpected state in which one or more legs of an Order Plan intended to execute atomically become live without the complete approved package. It invokes immediate options containment and cannot be normalized as a successful spread.
_Avoid_: partial fill, temporary position

**Venue Capability Manifest**:
The versioned, evidence-backed declaration of which instrument, order, data, lifecycle, reconciliation, and operational capabilities a particular Execution Venue, account, environment, and adapter version currently certify.
_Avoid_: feature list, supported broker

**Capability Certification Status**:
The evidence scope assigned to one venue capability: Paper Certified, Live Certified, Supervised Only, Uncertified, or Inapplicable. Paper Certified never implies Live Certified.
_Avoid_: supported, available

**Capability Provision**:
How a venue capability is supplied: Venue Native or Deterministically Emulated. Provision is independent of certification scope and must identify the responsible venue or deterministic module.
_Avoid_: certification status, fallback

**Environment Epoch**:
A bounded continuity interval for one Execution Environment and venue account state. A venue reset, destructive migration, or unrecoverable continuity break begins a new epoch without rewriting the prior Paper or Capital Ledger history.
_Avoid_: session, reset counter

**Reconciliation Break**:
An unexplained disagreement among raw venue evidence, Market Mate's normalized ledger, and the venue's current account/position state. It freezes new exposure until resolved or contained.
_Avoid_: sync error, stale balance

**Parity Observation**:
A versioned comparison of one Order Plan's previewed, simulated, Paper, and Live behavior across acknowledgement, rejection, fill, slippage, fees, buying power, lifecycle timing, and reconciliation. It measures transferability and never grants order authority.
_Avoid_: matched trade, proof of identical execution

**Execution Evidence Ensemble**:
The versioned, reliability-weighted combination of qualified Paper Venue models, the Conservative Simulation Overlay, and later Live-calibrated execution models used to judge whether strategy economics transfer across execution assumptions. Weights reflect fidelity and independence, not reported profit.
_Avoid_: simulator average, best backtest

**Execution Evidence Disputed**:
A state in which qualified members of the Execution Evidence Ensemble materially disagree about net edge or transferability. It requires additional evidence and cannot be resolved by selecting the most favorable member.
_Avoid_: mixed signal, majority loss

**Ensemble Reweighting Cycle**:
The weekly process that uses matured out-of-sample execution-fidelity evidence to propose a challenger Execution Evidence Ensemble without mutating the active ensemble or optimizing weights against strategy profit.
_Avoid_: online weight update, best-model selection

**Promotion Bundle**:
The signed immutable collection of strategy, model, parameter, risk, order-contract, instrument, data, adapter-interface, capability, ensemble, test, and evidence versions approved for Paper-to-Live promotion. Live deployment may bind certified environment details but may not rebuild its economic logic.
_Avoid_: deployment package, production configuration

**Venue Certification**:
The versioned evidence that a specific Execution Venue and account satisfy the required capabilities, permissions, costs, security, lifecycle behavior, reconciliation, and failure handling for an approved scope.
_Avoid_: broker support, API availability

**Certification Candidate**:
An Execution Venue selected for written review and executable testing but not yet authorized to receive live orders.
_Avoid_: selected broker, supported broker

**Certified Live Venue**:
A specific Execution Venue, account, adapter version, and approved capability scope that currently hold valid Venue Certification for live use.
_Avoid_: brokerage, integrated broker

**Capital Ledger**:
The broker-reconciled, append-only account of every monetary event affecting the Brokerage Account, recorded at currency-minor-unit precision.
_Avoid_: wallet balance, transaction history

**Paper Ledger**:
The append-only account of simulated monetary and position events in a Paper Account, kept structurally comparable to but strictly separate from the Capital Ledger.
_Avoid_: test Capital Ledger, fake money

**Cash Movement**:
A debit or credit recorded in the Capital Ledger, such as funding, withdrawal, premium, proceeds, commission, fee, dividend, interest, exercise, assignment, or settlement. A Cash Movement is not by itself a profit or loss.
_Avoid_: gain, loss, transaction

**Operating Cost**:
An expense required to research, host, observe, or operate Market Mate that is funded separately from the Brokerage Account but included in fully loaded performance reporting.
_Avoid_: trading loss, portfolio fee

**Capability-Adjusted Cost**:
The complete recurring and usage-based cost of an Execution Venue relative to the certified capabilities Market Mate will actually use, including commissions, exchange and regulatory fees, market data, infrastructure burden, and expected execution friction.
_Avoid_: commission rate, cheapest broker

**Operational Usability**:
The human and engineering effort required to safely operate an Execution Venue, including emergency controls, broker-interface clarity, account administration, documentation, diagnostics, support responsiveness, and routine adapter maintenance.
_Avoid_: developer experience, ease of use

## Trading and control

**Investment Universe**:
The securities and derivatives the system is permitted to consider and trade. The initial intended universe is stocks and listed options.
_Avoid_: market, assets

**Coverage Universe**:
The versioned, bounded set of securities for which the system maintains current research and sentiment evidence. Its system-selected membership targets 40 qualifying members and has a normal discretionary ceiling of 50. Mandatory Holdings and the separately bounded Principal-Pinned Overlay do not consume those system-selected slots.
_Avoid_: watchlist, tracked stocks, scrape list

**Discovery Pool**:
The broader, versioned set of potentially qualifying U.S. securities that receives inexpensive screening for possible admission to the Coverage Universe but does not receive full sentiment collection or trade consideration.
_Avoid_: Coverage Universe, all stocks

**Coverage Stage**:
The current role of a security within the Coverage Universe: Research Candidate, Trade Eligible, Mandatory Holding, or Exit Monitoring. A stage controls research and new-exposure eligibility but never overrides the Risk Policy.
_Avoid_: watchlist tier, trading status

**Research Candidate**:
A Coverage Universe member receiving the full Market Research Cycle while evidence is accumulated; it cannot receive new exposure.
_Avoid_: potential trade, watch-only stock

**Principal-Nominated Candidate**:
A security the Principal manually requests for research. It enters as a Research Candidate and receives no exemption from evidence, quality, diversification, or promotion requirements.
_Avoid_: manual position, approved stock

**Principal-Pinned Overlay**:
The set of at most five Principal-Nominated Candidates that receive full Coverage Universe research without consuming system-selected capacity. Each pin has a 30-day review date. Pinning affects research retention only and cannot grant Trade Eligible status, bypass evidence controls, or prevent mandatory safety demotion.
_Avoid_: unlimited watchlist, manual approval

**Trade Eligible**:
A Coverage Universe member that currently satisfies the approved admission and data-quality contract and may be considered by Strategy Versions for new exposure, subject to every remaining validation and risk control.
_Avoid_: buy list, approved trade

**Coverage Capability**:
A separately evaluated permission describing whether a Trade Eligible security may be considered for stock exposure, options exposure, or both. Stock Eligible and Options Eligible capabilities never authorize an order by themselves.
_Avoid_: asset type, trade approval

**Coverage Fitness Score**:
The daily nonpredictive ranking of a security's data quality, stock-market execution feasibility, research observability, diversification contribution, and operational stability. It governs scarce research capacity, not expected return or trade direction.
_Avoid_: opportunity score, stock rating

**Coverage Policy Version**:
A fixed, reviewable version of the rules that define Discovery Pool membership, Coverage Fitness scoring, capacity, stages, capabilities, promotion, demotion, replacement, manual pins, and enhanced-risk treatment. A version cannot modify or promote itself.
_Avoid_: watchlist settings, adaptive universe

**Enhanced-Risk Security**:
An OTC, penny, or otherwise manipulation- or infrastructure-sensitive security that requires stronger identity, reporting, quote, liquidity, settlement, and forward-evidence gates plus tighter utilization limits. It remains research/paper-only until separately authorized.
_Avoid_: excluded security, speculative pick

**Mandatory Holding**:
A security with an open position or unresolved exercise, assignment, settlement, corporate-action, or other account obligation. It remains in the Coverage Universe regardless of capacity or eligibility for new exposure.
_Avoid_: portfolio ticker, permanent member

**Exit Monitoring**:
A Coverage Stage for a security whose position has closed but whose settlement, reconciliation, tax, lifecycle, or post-exit evidence remains incomplete. It cannot receive new exposure unless separately promoted to Trade Eligible.
_Avoid_: removed holding, archive

**Market Research Cycle**:
A scheduled process, run at least once per trading day, that refreshes point-in-time evidence for the Coverage Universe across approved market, fundamental, event, options, sentiment, macroeconomic, liquidity, and portfolio-risk dimensions.
_Avoid_: stock scan, daily scrape, trading strategy

**Research Snapshot**:
The immutable, time-stamped result of a Market Research Cycle for a security or the portfolio, including source lineage, data quality, indicator changes, uncertainty, and comparisons with prior snapshots.
_Avoid_: research report, agent summary

**Core Indicator**:
A canonical descriptive or risk measure that may appear in a Research Snapshot but does not, by itself, claim predictive value or authorize a trade.
_Avoid_: signal, alpha factor

**Experimental Indicator**:
A versioned hypothesis about predictive information that may be researched but cannot influence live orders until validated and promoted through a Strategy Version.
_Avoid_: Core Indicator, proven signal

**Autonomous Execution**:
Order placement without per-order human approval, but only through the Principal's preset authority and non-bypassable risk boundaries.
_Avoid_: unattended trading, unrestricted automation

**Authority Grant**:
A versioned, expiring Principal approval defining which autonomous component may perform which actions, in which environments, strategies, schedules, tools, and capital/risk limits, with required evidence, monitoring, notifications, and rollback. A component cannot approve or broaden its own grant.
_Avoid_: permission flag, agent trust

**Operational Notification**:
A non-authoritative message sent to an approved external communication channel, such as Slack, to inform the Principal of a threshold, incident, approval request, or recovery state. It may link to Market Mate but cannot itself approve, reject, resume, or alter trading authority.
_Avoid_: approval, audit record, command

**Approval Companion**:
An optional Principal client, such as a native mobile application, that presents server-fetched evidence, sends Operational Notifications, invokes emergency containment, and cryptographically submits a Principal Authorization Decision. It owns no strategy, risk, ledger, execution, or canonical authorization state.
_Avoid_: mobile trading engine, second backend, biometric approval

**Principal Authorization Decision**:
The Principal's authenticated, step-up-verified approval or rejection of an exact, immutable proposal within Market Mate, including proposal identity, scope, expiry, evidence, and resulting authority change. A message acknowledgement or external-channel interaction is not a Principal Authorization Decision.
_Avoid_: Slack approval, notification acknowledgement, button click

**Authenticator Recovery**:
The containment process that revokes all active sessions and replaces or re-enrolls a suspected compromised Principal authenticator before a fresh authenticated session may be established. It does not preserve pending approvals or prior session authority.
_Avoid_: password change, session refresh, device trust

**Safety Kernel**:
The deterministic authority that approves or rejects every order against the current Risk Policy and cannot be modified or bypassed by a Strategy Version.
_Avoid_: AI risk agent, safety prompt

**Options Lifecycle Engine**:
The dedicated deterministic authority that continuously controls options-specific exposure and lifecycle risk, including multi-leg integrity, exercise, assignment, expiration, and related underlying positions.
_Avoid_: options strategy, options bot

**Circuit Breaker**:
A non-bypassable automated halt on trading when a defined account-level loss or other risk boundary is reached; resumption requires the Principal's intervention.
_Avoid_: stop loss, pause button

**Risk Policy**:
The versioned set of limits and mandatory controls that bound Autonomous Execution, including loss, position, concentration, and event-exposure limits.
_Avoid_: guardrails, configuration

**Risk State**:
The account-wide authority state derived by the Safety Kernel from the current Risk Policy, account evidence, and containment conditions; it determines which risk-increasing or risk-reducing actions remain permitted.
_Avoid_: trading mode, alert level

**Recovery State**:
A fail-closed operational state entered after restoration, material integrity failure, or suspected host compromise. It permits verification, evidence preservation, broker reconciliation, and approved recovery work but grants no new Live exposure authority.
_Avoid_: maintenance mode, restored Live, temporary pause

**Live Resumption**:
The Principal-authorized transition from Recovery State back to Live eligibility after all mandatory automated integrity, notification, Safety Kernel, and broker-reconciliation checks pass. It restores no broader authority than existed before the incident.
_Avoid_: restart, unpause, acknowledgement

**Drawdown**:
The decline in broker-reconciled account equity from its contribution-adjusted high-water mark, including realized and unrealized P&L and all trading costs.
_Avoid_: realized loss, cash decline

**Position Risk**:
The conservative, cost-inclusive loss attributed to one position under its approved worst modeled outcome, including option assignment and gap assumptions where applicable.
_Avoid_: purchase price, position size

**Capital Utilization**:
The share of broker-reconciled account equity committed as security value, option premium, or collateral. It is distinct from Position Risk and aggregate modeled loss.
_Avoid_: exposure, invested percentage

**Strategy Version**:
A fixed, reviewable version of the rules that generate trade candidates and determine their sizing, entry, management, and exit.
_Avoid_: algorithm update, bot behavior

**Strategy Quarantine**:
A state that prohibits a Strategy Version from initiating new exposure after its evidence, calibration, data quality, or live behavior violates an approved threshold.
_Avoid_: pause, poor performance

**Performance Objective**:
The versioned, net-of-cost criteria used to judge Market Mate against cash/no-trade and a contemporaneous S&P 500 total-return benchmark without implying guaranteed outperformance.
_Avoid_: profit target, average market return

**Earnings-Direction Model**:
A Strategy Version that produces a calibrated probability that a security will move up or down after a specified earnings event, and may inform whether an option position may remain open through that event.
_Avoid_: earnings prediction, sentiment score

**Approved Source**:
A publisher, feed, or public-data endpoint whose content the Principal has authorized for collection and whose terms permit the system's intended access, retention, and analysis.
_Avoid_: website, scraper target

**Source Registry**:
The closed, versioned authority listing every source and the exact access, purpose, transformation, retention, display, deletion, rate, cost, and account scope currently permitted. Only an active entry may supply strategy evidence.
_Avoid_: URL list, available websites

**Core Source**:
An active Source Registry entry queried routinely for the Coverage Universe.
_Avoid_: trusted source, primary source

**Extended Source**:
An active Source Registry entry queried only when Core Sources provide insufficient evidence because its cost, latency, authority, or usage constraints make routine collection undesirable.
_Avoid_: fallback scraper, unrestricted search

**Sentiment Model**:
A versioned model that converts time-stamped observations from Approved Sources into a calibrated, horizon-specific assessment of market attitude toward a security. Its output is supporting evidence, not permission to trade.
_Avoid_: scraper, mood score, stock rating

**Sentiment Assessment**:
A security-, horizon-, source-family-, and theme-specific distribution over positive, neutral, and negative expressed attitude, accompanied by confidence, coverage, disagreement, freshness, and provenance. It is not a probability of a market-price outcome.
_Avoid_: bullish probability, stock direction score

**Sentiment Balance**:
A derived −100 to +100 summary of a Sentiment Assessment's positive-versus-negative evidence. It is a display and comparison aid, not a probability or trading threshold.
_Avoid_: confidence score, expected return

**Sentiment Evidence State**:
The categorical availability state of a Sentiment Assessment: Sufficient Evidence, Insufficient Evidence, Neutral Evidence, or Conflicting Evidence. Missing or stale evidence never becomes neutral evidence.
_Avoid_: default score, no news is good news

**Strategy-Grade Sentiment**:
A Sentiment Assessment that satisfies the stricter, independently corroborated evidence and validation contract required for a Strategy Version to consume it. Ordinary Sufficient Evidence may remain dashboard- and research-only.
_Avoid_: strong sentiment, trade signal

**Sentiment Confidence**:
The calibrated reliability of a Sentiment Assessment given model performance, evidence coverage, independent diversity, relevance, freshness, agreement, entity-link certainty, and manipulation controls. Confidence is independent of positive or negative polarity.
_Avoid_: conviction, strength of bullishness

**Sentiment Disagreement**:
The separately reported degree to which independent, relevant source families conflict after deduplication. It widens uncertainty and may create Conflicting Evidence rather than being averaged away.
_Avoid_: noise, neutral sentiment

**Sentiment Robustness Suite**:
The append-only, versioned collection of manipulation, ambiguity, duplication, deletion, outage, and prompt-injection cases a Sentiment Model must survive. New failures expand the suite; a model cannot remove or weaken cases to regain approval.
_Avoid_: security examples, one-time red team

**Sentiment Validation Policy Version**:
An immutable version of the data, labeling, split, sample, calibration, robustness, incremental-value, monitoring, and promotion requirements applied to Sentiment Models. GUI edits create a new draft version and never rewrite prior results.
_Avoid_: adjustable pass mark, validation settings

**Nightly Evaluation**:
The first Sentiment Model promotion stage, run after each trading day for dashboard visibility, evidence collection, and security evaluation without any Strategy Version or order authority.
_Avoid_: live sentiment, shadow trading

**Sentiment Model Quarantine**:
A state that prohibits every dependent Strategy Version from opening or increasing exposure after the Sentiment Model's calibration, robustness, source authority, schema, or monitoring evidence violates its approved contract. Existing positions remain under deterministic risk and lifecycle controls.
_Avoid_: bearish sentiment, automatic liquidation

**Monitoring Evidence Pending**:
A temporary state in which delayed ground-truth labels prevent completion of scheduled Sentiment Model monitoring while immediate source, security, schema, coverage, and drift checks still pass. It is not a monitoring pass and expires after a bounded grace period.
_Avoid_: healthy model, missing metrics

**Sentiment Contribution Ledger**:
The deterministic account of how each authorized, deduplicated evidence cluster was included, excluded, weighted, decayed, and combined into a Sentiment Assessment's polarity, confidence, coverage, and disagreement. It is the authoritative explanation beneath any generated summary.
_Avoid_: model rationale, article list

**Data Contract**:
The provider-neutral, point-in-time definition of market, event, and execution data that a Strategy Version may use, including its source entitlement, availability time, instrument identity, and provenance requirements.
_Avoid_: data feed, dataset

**Validation Gate**:
A required review point that a Strategy Version must pass before it may progress from backtesting to paper trading or live execution.
_Avoid_: launch check, approval step

**Decision Record**:
The immutable explanation of a planned, attempted, completed, rejected, or abandoned action, linked to its Execution Environment, evidence, Strategy Version, Risk Policy, forecast, approvals, orders, and resulting ledger events.
_Avoid_: log message, agent thoughts

**Expected P&L**:
A time-stamped, cost-inclusive estimate of an action's possible profit-and-loss distribution over a defined horizon, including downside, assumptions, uncertainty, and model version. It is a forecast, not a promise.
_Avoid_: expected profit, guaranteed return

**Audit Dashboard**:
The Principal-facing web view over Paper and Live historical, current, and planned actions, their separate ledgers, positions, forecasts, outcomes, and Decision Records.
_Avoid_: report, portfolio screen

**Operator Alert**:
A routed notification that identifies an event requiring the Principal's awareness or action, its severity, environment, deadline, current containment state, and acknowledgement status.
_Avoid_: text message, notification
