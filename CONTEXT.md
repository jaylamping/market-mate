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

**Order Risk Class**:
The deterministic classification of an Order Plan from its before/after Position Risk, Lifecycle Funding Requirement, protection, and obligations: Risk Increasing when any material measure or obligation rises; Risk Neutral when none rises or weakens; or Risk Reducing only when every approved risk measure falls without creating a new material tail.
_Avoid_: buy or sell, open or close, order side

**Risk-Reducing Order**:
An Order Plan classified as Risk Reducing by the Safety Kernel rather than by its side or broker open/close label. It may use a separately certified degraded-liquidity path but cannot proceed through a halt, missing market, uncertain custody, or unbounded economics.
_Avoid_: sell order, closing order, emergency market order

**Order Admission Policy**:
The immutable versioned global liquidity, quote-quality, session, atomicity, execution, cost, and market-impact floors an Order Plan must satisfy before submission. A Strategy Version may impose stricter requirements but cannot weaken them.
_Avoid_: strategy preference, broker validation, editable thresholds

**Admission Quote**:
The fresh, identity-certified, entitled, two-sided, positive-size, firm and executable market observation used for an Order Admission decision, with its source, native and receipt times, sequence state, session, conditions and displayed size. Indicative, delayed, stale, crossed, locked, halted, auction or otherwise non-executable observations are not Admission Quotes.
_Avoid_: current price, midpoint, last trade

**Execution Friction**:
The complete estimated economic drag of entering and later reducing a Risk Position, including bid/ask spread, slippage, market impact, commissions, fees and stressed exit costs. It must fit both Position Risk and conservative expected-edge budgets.
_Avoid_: commission, spread, actual P&L

**Exit Capacity**:
The evidence that a Minimum Executable Unit can be reduced under its intended and stressed market, liquidity, package, lifecycle and timing conditions without breaching its Risk Policy. Assumed future liquidity or current entry depth alone is insufficient.
_Avoid_: current volume, open interest, sell button

**Liquidity State**:
The deterministic order-admission state of a Tradable Instrument or package: Admission Eligible when every hard gate passes; Admission Degraded when new exposure is blocked but a certified Risk-Reducing Order may remain possible; Unscorable when executable economics cannot be established; Disputed when required evidence conflicts; or Unavailable when no supported executable market exists.
_Avoid_: liquid or illiquid, volume tier, trading status

**Order Capacity Reservation**:
The full planned Position Risk, Lifecycle Funding Requirement, cash, collateral, and portfolio capacity held from Risk Approval until every related order, fill, cancel, correction, and unknown state becomes terminal and reconciled. Partial fills or cancel requests do not release it early.
_Avoid_: buying-power estimate, filled amount, temporary hold

**Atomic Package Unit**:
The smallest complete multi-leg execution quantity that preserves every approved leg ratio, defined-loss relationship, and package economic limit. A partial fill is acceptable only when it consists exclusively of complete Atomic Package Units.
_Avoid_: option leg, partial spread, all-or-none order

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

**Option Package**:
The accounting and lifecycle grouping of the independently recorded option legs arising from one approved multi-leg structure. Package economics, costs, collateral, and performance must equal their attributable leg evidence and never replace it.
_Avoid_: single option position, net fill, synthetic security

**Collateral Encumbrance**:
A time-stamped restriction on cash, securities, or buying power imposed for an open exposure or obligation. It constrains order authority but is not a Cash Movement or Ledger Posting unless an actual charge or transfer occurs.
_Avoid_: cash spent, margin loan, Trading Cost

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

**Reconciliation State**:
The evidence status of one comparison between ledger history and Custody State: Matched, Expected Timing Difference, Evidence Pending, Explained Adjustment, or Reconciliation Break. A matching aggregate cannot conceal mismatched components.
_Avoid_: reconciliation passed, sync status, approximate match

**Pending Classification**:
A temporary balanced-ledger destination for a broker-observed economic amount whose nature is not yet supported by sufficient evidence. It is excluded from P&L and usable capital until resolved by an evidenced Ledger Correction.
_Avoid_: miscellaneous adjustment, suspense profit, Evidence Pending

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
The broker-reconciled, append-only balanced book of every accepted economic event affecting the Brokerage Account. It preserves source precision and never commingles Paper activity.
_Avoid_: wallet balance, transaction history

**Paper Ledger**:
The append-only balanced book of simulated economic events in a Paper Account, kept structurally comparable to but strictly separate from the Capital Ledger and bounded by its Environment Epoch.
_Avoid_: test Capital Ledger, fake money

**Ledger Event**:
An immutable accepted economic fact within exactly one Execution Environment that produces one balanced group of Ledger Postings and links to its source evidence, effective times, and any correction lineage.
_Avoid_: broker transaction, Venue Event, log entry

**Ledger Posting**:
One debit or credit assigning an exact amount or instrument quantity to a named ledger account as part of a balanced Ledger Event. A posting has no independent economic meaning outside its group.
_Avoid_: transaction, cash movement, database row

**Ledger Correction**:
A linked balanced reversal, replacement, or evidenced adjustment that changes the current accounting interpretation without editing or deleting the original Ledger Event.
_Avoid_: manual edit, overwrite, make-it-match entry

**Accounting Restatement**:
A new version of derived positions, lots, P&L, risk, or reports produced after a Ledger Correction or newly accepted evidence. Prior versions and their validity intervals remain auditable.
_Avoid_: revised history, corrected ledger, current report

**Accounting Policy Version**:
An immutable version of the account taxonomy, event-to-posting rules, lot selection, fee allocation, basis overlays, reconciliation classifications, and projection rules used to interpret ledger evidence. A new version never silently rewrites prior results.
_Avoid_: accounting settings, current logic, mutable chart of accounts

**Accounting Invariant**:
A non-negotiable identity that every accepted ledger state and deterministic replay must satisfy, including balanced events, complete lineage, environment isolation, lot-to-position equality, cash/equity reconciliation, and package-to-leg equality.
_Avoid_: validation warning, expected discrepancy, accounting test

**Order Commitment**:
A reversible control-state reservation of buying power, cash, collateral, or instrument quantity for an open Venue Order. It constrains authority but is not a Ledger Posting unless an actual economic charge or execution occurs.
_Avoid_: cash balance, fill, liability

**Settlement State**:
The separately tracked status of a contractual cash or instrument obligation, including its execution, trade, contractual-settlement, and actual-settlement times. Settlement does not erase the earlier economic event.
_Avoid_: order status, fill status, available cash

**Custody State**:
The Execution Venue's current claim about assets, cash, liabilities, orders, and obligations held for the Brokerage Account at a particular observation time. It is external fact to reconcile, not permission to rewrite ledger history.
_Avoid_: Capital Ledger, broker truth, current balance

**Basis Pending**:
The evidence state of an owned lot whose acquisition date, economic cost basis, or tax basis is missing or disputed. It blocks new exposure in the instrument but never prevents necessary risk reduction.
_Avoid_: zero basis, estimated basis, unreconciled position

**Position Lot**:
An independently traceable quantity of one instrument created or transformed by a specific execution, exercise, assignment, transfer, reinvestment, corporate action, or correction. Partial disposition preserves the identity of the unconsumed remainder.
_Avoid_: average position, ticker holding, order

**Management Transfer**:
A time-stamped change in which Strategy Version or containment authority manages existing exposure without changing its originating strategy, Ledger Events, Position Lots, or lifetime attribution.
_Avoid_: strategy reassignment, performance reset, new position

**Roll Workflow**:
A linked workflow containing independently accounted closing and opening executions. It preserves the realized result of the closed exposure and the new basis and risk of the replacement exposure.
_Avoid_: rolled position, deferred loss, single transaction

**Economic Basis**:
The actual capital and attributable Trading Costs assigned to a Position Lot for economic performance, independent of tax-only adjustments.
_Avoid_: purchase price, Tax Basis, market value

**Tax Basis**:
The separately maintained basis of a Position Lot after applicable tax adjustments, linked to but never substituted for Economic Basis or strategy performance.
_Avoid_: Economic Basis, broker-reported profit, market value

**Containment Exposure**:
An actual position or obligation that violates normal initiation policy because of assignment, exercise, broken-package execution, correction, or other lifecycle event. It remains fully recorded and managed only through approved containment and risk-reducing actions.
_Avoid_: hidden position, approved exception, temporary discrepancy

**Cash Movement**:
A debit or credit recorded in the Capital Ledger, such as funding, withdrawal, premium, proceeds, commission, fee, dividend, interest, exercise, assignment, or settlement. A Cash Movement is not by itself a profit or loss.
_Avoid_: gain, loss, transaction

**Capital Contribution**:
A Cash Movement from the Principal into the Brokerage Account that increases invested capital but is excluded from realized P&L and contribution-adjusted performance.
_Avoid_: deposit profit, revenue, gain

**Opening Capital Event**:
The signed inception event that establishes observed cash, positions, obligations, and imported lot evidence when a ledger begins, offset to Principal-contributed capital without inventing prior trading P&L.
_Avoid_: initial profit, historical backfill, reset balance

**Capital Withdrawal**:
A Cash Movement from the Brokerage Account to the Principal that decreases invested capital but is excluded from realized P&L and contribution-adjusted performance. Market Mate may observe it but cannot initiate it.
_Avoid_: trading loss, expense, drawdown

**Realized P&L**:
The cost-inclusive economic result recognized when an event closes or settles all or part of an exposure under the applicable accounting contract. Funding, transfers, buying-power changes, and price marks are excluded.
_Avoid_: cash proceeds, account growth, sale price

**Unrealized P&L**:
A reproducible, time-stamped estimate of the cost-inclusive value change remaining in open exposure under a specified valuation policy. It is derived evidence and never rewrites historical Ledger Postings.
_Avoid_: guaranteed gain, cash balance, realized P&L

**Trading Cost**:
A commission, exchange charge, regulatory charge, exercise or assignment fee, or other execution-related amount separately recorded as a Cash Movement and attributed to the economic activity that incurred it.
_Avoid_: Operating Cost, hidden slippage, trading loss

**Tax Lot**:
The Capital Ledger unit of tax basis, quantity, acquisition time, holding period, and later adjustments for one acquired position in a security or option; Paper Ledger lots may mirror the shape but are never tax evidence.
_Avoid_: position, fill, average cost

**Specific Identification**:
The lot-selection method that uses the particular Tax Lots named in a trade-time instruction and confirmed in writing by the broker; without that identification, FIFO is the default for ordinary stock.
_Avoid_: best-lot picker, average cost, tax-optimized allocation

**Wash-Sale Adjustment**:
The append-only record of a wash-sale loss disallowance and, when legally applicable, the resulting basis increase and holding-period tacking on replacement Tax Lots; an IRA or Roth IRA replacement receives no basis add-back.
_Avoid_: wash-sale ignore, broker 1099-B as final

**Section 1256 Contract**:
A listed nonequity option or other contract that federal law marks to market and generally splits 60% long-term and 40% short-term; ordinary listed equity options held by a non-dealer individual are not Section 1256 Contracts.
_Avoid_: all options, index option without classification

**Operating Cost**:
An expense required to research, host, observe, or operate Market Mate that is funded separately from the Brokerage Account but included in fully loaded performance reporting.
_Avoid_: trading loss, portfolio fee

**Operating Cost Envelope**:
The Principal-approved prospective cash-spending authority for Market Mate, expressed as stage targets, category soft caps, an aggregate monthly hard ceiling, a first-year ceiling, and escalation thresholds. It excludes Trading Capital and imputed development labor; unused category capacity may move within the aggregate ceiling, while any new vendor, annual commitment, upgrade, exceptional acquisition, or ceiling increase requires fresh Principal approval.
_Avoid_: trading budget, expense estimate, automatic spending authority

**Portfolio Performance**:
The contribution-adjusted economic performance of Trading Capital after Trading Costs, execution friction, interest, exercise, assignment, and settlement effects, but before separately funded Operating Costs.
_Avoid_: account balance, fully loaded economics, gross return

**Fully Loaded Experiment Economics**:
Portfolio Performance reduced by every actual cash Operating Cost for the same reporting period, with development effort reported separately as time rather than imputed expense.
_Avoid_: strategy return, portfolio P&L, hidden infrastructure cost

**Capability-Adjusted Cost**:
The complete recurring and usage-based cost of an Execution Venue relative to the certified capabilities Market Mate will actually use, including commissions, exchange and regulatory fees, market data, infrastructure burden, and expected execution friction.
_Avoid_: commission rate, cheapest broker

**Operational Usability**:
The human and engineering effort required to safely operate an Execution Venue, including emergency controls, broker-interface clarity, account administration, documentation, diagnostics, support responsiveness, and routine adapter maintenance.
_Avoid_: developer experience, ease of use

## Trading and control

**Issuer**:
The legal entity whose obligations or ownership interests give rise to one or more Securities. An Issuer is not interchangeable with any ticker, share class, listing, or option underlying.
_Avoid_: company ticker, stock, instrument

**Security**:
A distinct class of financial rights associated with an Issuer, such as one class of common stock or an ADR, independent of where or under which symbol it is listed.
_Avoid_: issuer, ticker, exchange listing

**Exchange Listing**:
The time-bounded admission of one Security to trading on a particular venue, with its own listing identity, symbol history, currency, status, and lifecycle.
_Avoid_: stock, ticker, issuer

**Tradable Instrument**:
The exact, immutable economic object an Order Plan may reference, such as a specific Exchange Listing or listed option contract. Trade eligibility requires a certified mapping from every venue or data-provider identifier to this identity.
_Avoid_: ticker, company, vendor symbol

**Symbol Alias**:
A display or vendor symbol associated with an Issuer, Security, Exchange Listing, or Tradable Instrument only for a declared source and validity interval. Symbol changes add aliases; later reuse by an unrelated object never reuses identity.
_Avoid_: canonical identifier, permanent ticker, instrument key

**Option Deliverable Version**:
The immutable, effective-dated terms defining what one option contract unit delivers, including underlying or cash components, quantities, multiplier, settlement, and official adjustment evidence. A changed deliverable creates a new version without rewriting the contract's prior terms.
_Avoid_: option symbol, adjusted ticker, current multiplier

**Security Master**:
The versioned, provider-neutral authority that relates Issuers, Securities, Exchange Listings, Tradable Instruments, Symbol Aliases, option terms, deliverable versions, and vendor or venue identifiers to their evidence and validity intervals.
_Avoid_: ticker table, broker symbol list, current universe

**Instrument Mapping**:
The versioned relationship between one source-, venue-, or broker-native identifier and a canonical Security Master identity for a declared validity interval. Its lifecycle is Proposed, Corroborated, Certified, Suspended, or Retired; only Certified mappings may support orders.
_Avoid_: ticker match, database join, permanent vendor ID

**Security Master Policy Version**:
An immutable definition of identifier sources, fact-specific authority, matching and evidence requirements, time semantics, corporate-action behavior, correction handling, certification tests, and restoration gates. Agents may propose a successor with replay evidence but cannot activate it.
_Avoid_: editable mapping rules, current source priority, agent configuration

**Instrument Identity Break**:
A material unresolved conflict or gap in the identity, terms, listing, deliverable, or cross-provider mapping of a Tradable Instrument. It prohibits new or increased exposure while preserving unambiguous risk-reducing management of existing obligations.
_Avoid_: symbol mismatch, warning, manual mapping

**Corporate Action Case**:
The immutable evidence and lifecycle record for an event that may alter a Security, Exchange Listing, Tradable Instrument, entitlement, quantity, cash flow, basis, or option deliverable. Its state progresses from Rumored, Announced, Terms Pending, Authoritatively Confirmed, Effective, and Broker Reconciled to Final without erasing earlier knowledge states.
_Avoid_: split adjustment, current corporate action, overwritten instrument

**Identity-Continuous Symbol Change**:
A change limited to a time-bounded Symbol Alias for which authoritative evidence establishes uninterrupted Security, Exchange Listing, and economic identity across every required provider. Any simultaneous change in class, listing, rights, settlement, or economics is a reorganization instead.
_Avoid_: rename by matching ticker, new instrument, merger

**Adjusted Option Contract**:
An existing option contract whose official Option Deliverable Version changed after a corporate action. It remains an actively managed obligation but is exit-only by default until its terms, liquidity, broker support, and lifecycle behavior are separately certified for new exposure.
_Avoid_: ordinary option, renamed contract, automatically tradeable adjustment

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

**Indicator Definition**:
The immutable versioned meaning of one indicator, including its purpose, inputs, sources, units, calculation, adjustment and time semantics, horizons, freshness, missingness, valid range, and ownership. A semantic change creates a new definition rather than rewriting prior observations.
_Avoid_: formula, dashboard setting, current calculation

**Indicator Observation**:
The reproducible value or evidence state produced for one Indicator Definition, security or portfolio scope, and as-of time, with pinned source observations, lineage, calculation version, precision, freshness, and correction status.
_Avoid_: current value, data point, signal

**Indicator Observation State**:
The non-interchangeable availability state of an Indicator Observation: Current, Stale, Expired, Missing, Incomplete, Source Disputed, Invalidated, or Not Applicable. Missing, disputed, and invalidated observations never become neutral values.
_Avoid_: status flag, valid-or-invalid, default value

**Freshness Class**:
A versioned evidence-timing contract defining when an Indicator Observation is current, stale, expired, incomplete, or awaiting an authoritative update for its operational purpose. An Indicator Definition may impose a stricter limit but cannot silently relax its class.
_Avoid_: cache TTL, update frequency, recent data

**Core Indicator**:
A canonical descriptive or risk measure that may appear in a Research Snapshot but does not, by itself, claim predictive value or authorize a trade. A separately safety-certified Core Indicator may reduce or deny authority through a deterministic Risk Policy.
_Avoid_: signal, alpha factor

**Experimental Indicator**:
A versioned hypothesis about predictive information, potentially derived from Core Indicators, that may be researched but can influence orders only as an explicitly validated input to a Strategy Version. It never becomes a universally predictive Core Indicator.
_Avoid_: Core Indicator, proven signal

**Indicator Evidence Stage**:
The bounded use permitted for an Experimental Indicator: Registered, Data Certified, Research Qualified, Paper Eligible, or Strategy Eligible. Live use derives only from a separately promoted consuming Strategy Version and never from the indicator stage alone.
_Avoid_: indicator approval, proven feature, live signal

**Release Holdout**:
A sealed, chronologically latest evidence segment reserved for one promotion decision and accessed only through a controlled Holdout Evaluation. After that decision it becomes ordinary historical evidence and cannot approve later feature or threshold refinements.
_Avoid_: test set, reusable benchmark, final backtest

**Holdout Evaluation**:
The logged one-time assessment of an Experiment Registration against a Release Holdout, returning only its preregistered metrics, uncertainty, slices, and gate results. A failed evaluation still consumes the holdout.
_Avoid_: test query, holdout exploration, final tuning

**Experiment Registration**:
The immutable preregistered contract for one promotable test, including its hypothesis, rationale, target, horizon, universe, versions, metrics, baseline, planned search, evidence windows, costs, risks, stopping rule, promotion gate, Experiment Family, and testing-budget reservation.
_Avoid_: experiment note, backtest configuration, result record

**Experiment Family**:
The multiple-testing group of experiments that share an economic thesis, prediction target, horizon, substantially overlapping evidence, or correlated feature and parameter neighborhood. It cannot be renamed or split after results are known to evade its testing budget.
_Avoid_: project folder, strategy name, winning trials

**Experiment Trial**:
One reproducible scheduled or started execution of an Experiment Registration, including successful, null, failed, invalid, aborted, and infrastructure-interrupted outcomes. A result-bearing attempt remains part of the evidence record even when unattractive.
_Avoid_: successful run, backtest result, discarded attempt

**Exploratory Analysis**:
Research that may generate hypotheses but cannot support promotion, confidence claims, or testing-budget renewal. Any discovered hypothesis requires a fresh Experiment Registration and untouched or forward evidence.
_Avoid_: preliminary validation, informal backtest, free trial

**Desk Role**:
The single bounded function an Incubator Agent Assignment performs: Thesis and Research, Evidence and Data, Strategy and Portfolio, Paper Execution and Operations, Risk and Safety, Evaluation and Challenge, or Control Tower and Operations. It defines responsibility and permitted output types, not identity, seniority, independence, or authority.
_Avoid_: agent personality, job title, permission set, organizational rank

**Strategy Thesis**:
A versioned economic hypothesis explaining why, where, and under which conditions a potentially exploitable behavior may exist, used to organize related research and strategy lineage without specifying complete trading behavior or granting execution authority.
_Avoid_: Strategy Version, trade idea, ticker opinion, guaranteed edge

**Incubator Agent Assignment**:
An immutable, expiring unit of work binding one objective, Desk Role, primary Strategy Thesis, Research Posture version, workload identity, permitted evidence, allowed actions and outputs, resource reservations, Execution Environment, stopping rule, and lineage. A worker may receive multiple separate assignments, but an assignment cannot combine proposer and evaluator duties in one promotion chain.
_Avoid_: persistent agent identity, job description, prompt, authority grant

**Assignment Run**:
One admitted execution attempt of an unchanged Incubator Agent Assignment, recorded as Running, Blocked, Completed, Failed, Cancelled, Expired, or Fenced with its own identity, timing, inputs, outputs, costs, and terminal reason. An exact retry creates a new run, while a changed objective, evidence scope, posture, budget, capability, or output contract requires a new assignment.
_Avoid_: assignment, agent session, overwritten retry, successful attempt

**Child Assignment**:
An Incubator Agent Assignment proposed from another assignment and admitted independently by Engine within approved policy and the parent reservation, with its own identity, posture, budget lineage, expiry, and Effective Assignment Capability. Parentage carries work lineage but never permissions or authority.
_Avoid_: subagent session, delegated authority, inherited role, shared budget

**Effective Assignment Capability**:
The strict intersection of an Incubator Agent Assignment, worker capability, Trust Zone, Execution Environment, budget, entitlement, and governing policy. Engine may create assignments autonomously inside that intersection, but neither Engine nor an agent may use assignment creation or delegation to expand authority.
_Avoid_: role permission, inherited authority, agent discretion, Principal delegation

**Assignment Capability Credential**:
A short-lived non-composable credential binding one assignment, run, workload identity, Trust Zone, Execution Environment, exact operation and resource scope, budget lineage, and expiry. Every receiving service recomputes authorization, multiple credentials cannot be unioned, and Incubator identities remain unable to reach Live services at network, identity, credential, and application-policy layers.
_Avoid_: API key, agent token, delegated authority, ambient credential

**Research Assignment**:
An Incubator Agent Assignment that may read approved evidence, conduct registered Research Sandbox trials, append immutable results, reproduce and challenge work, and prepare indicator, model, code, and Draft Strategy Proposals. It cannot alter canonical evidence, merge, deploy, change lifecycle state, access broker credentials, or write to Paper or Live services.
_Avoid_: autonomous developer, Paper worker, strategy authority, unrestricted research

**Paper Execution Assignment**:
An Incubator Agent Assignment that may operate, observe, reconcile, and contain one exact Paper Authorized Strategy Version within its approved Paper scope and return findings to Research as evidence. It cannot modify the running Strategy Version, promote it, create Live eligibility, or receive Live authority.
_Avoid_: paper researcher, simulated Live authority, mutable strategy runner, broker agent

**Assignment Handoff**:
An immutable transfer envelope binding source and destination assignments, artifact hashes, evidence snapshot and lineage, contamination state, dissent, unresolved assumptions, resource use, remaining work, and expiry. The receiving assignment recomputes its own Effective Assignment Capability because permissions and authority never travel through a handoff.
_Avoid_: chat message, authority delegation, shared memory, copied prompt

**Canonical Artifact Admission**:
The typed service boundary that schema-validates and appends an assignment output to a canonical store without granting the producing agent mutable access. Corrections create linked superseding records rather than rewriting accepted evidence, models, experiments, strategies, or decisions.
_Avoid_: file write, agent merge, database permission, mutable correction

**Assignment Fence**:
The immediate revocation of an Assignment Run and its capabilities after stale scope, budget breach, lost entitlement, gate violation, contamination, or other invalidating condition, with affected outputs and dependency descendants quarantined by lineage. Audit evidence is preserved, unused capacity is released, unrelated work continues, and recovery requires an explicit clean run or assignment.
_Avoid_: process kill, retry, global shutdown, evidence deletion

**Strategy Freeze Candidate**:
A non-authoritative request to transform one Draft Strategy Proposal into a complete immutable Strategy Version by deterministically pinning every rule and dependency, validating completeness, and calculating its content identity. Only the controlled freezing service may create the registry object, and freezing grants no Paper or Live authority.
_Avoid_: Strategy Version, deployment request, agent-created registry entry, promotion

**Research Sandbox**:
An isolated, non-authoritative environment in which agents may read approved unprivileged evidence, create disposable working files, append constrained experiment results, and prepare reviewable proposals. It has no broker credentials or ability to deploy, merge, alter canonical evidence or policy, or write to Paper or Live services.
_Avoid_: development server, Paper environment, safe production

**Research Code Proposal**:
Agent-authored executable code offered for review from a Research Sandbox. It grants no runtime or deployment authority; any merge, dependency change, deployment, or broader write capability requires a proposal-bound Principal Authorization Decision.
_Avoid_: autonomous code change, Strategy Version, approved implementation

**Research Budget**:
The versioned limits on experiment families, trials, compute, data spending, concurrency, and reserved evidence that bound autonomous research. An agent may propose an expansion, but only a Principal Authorization Decision can activate it.
_Avoid_: cloud budget, agent discretion, experiment quota

**Research Capacity Reservation**:
A time-bounded allocation of approved agents, tokens, compute, data spending, concurrency, and Principal attention to one identified work item, including its budget lineage and next checkpoint. Actual use is attributed to that work and unused capacity returns to its source budget.
_Avoid_: queue slot, cost estimate, blanket capacity

**Research Posture**:
An immutable versioned parameter vector bound to one Incubator assignment over search breadth, novelty tolerance, contrarianism, disconfirmation intensity, fan-out, depth, pruning speed, resource-request appetite, escalation sensitivity, and communication detail. It governs research behavior without changing evidence, risk, spending, or authority gates; any effect on traded universe, prediction target, horizon, entry, exit, sizing, portfolio construction, execution, or live treatment belongs to a new Strategy Version; a different posture requires a separately identified assignment, and posture diversity never establishes Evaluator Independence.
_Avoid_: agent personality, risk appetite, trading aggression, prompt style

**Research Posture Profile**:
A named canonical Research Posture vector selected from Passive Observer, Conservative Verifier, Balanced Investigator, Aggressive Explorer, Extreme Frontier, Skeptical Reviewer, or Adversarial Red Team. Each name resolves to one immutable versioned vector rather than subjective agent discretion or presentation style.
_Avoid_: personality label, prompt preset, model identity, Desk Role

**Aggressive Research Posture**:
An Incubator Research Posture that spends approved research capacity rapidly on broader, more novel, contrarian, and highly parallel investigation while pruning weak branches quickly and escalating promising work. Its aggression applies only to research behavior and never changes evidence, promotion, risk, spending, or trading authority.
_Avoid_: risk appetite, larger positions, lower evidence threshold, unlimited resources

**Research Posture Allocation**:
The Engine's logged distribution of Research Capacity Reservations across posture families, defaulting discovery work to 70% aggressive or extreme exploration, 20% skeptical or adversarial challenge, and 10% balanced or conservative verification. Passive Observer receives no standing capacity, and every promotion-bound thesis still requires aggressive generation, adversarial challenge, and an independently qualified evaluator.
_Avoid_: fixed headcount, authority allocation, evaluator independence, permanent staffing

**Passive Observer**:
A trigger-driven Research Posture used for change detection, prerequisite waiting, anomaly monitoring, and no-action control comparisons without standing Incubator capacity or responsibility for primary alpha generation.
_Avoid_: default researcher, approval role, idle agent, human Principal

**Research Posture Trial**:
An Engine-run comparison of a new immutable posture vector against canonical profiles within matched task classes and at most ten percent of already approved Incubator capacity. It grants no new spending, entitlement, evidence, or trading authority; a gate or authority violation suspends it immediately, while a profile materially dominated after thirty comparable assignments is retired unless it retains a proven specialist niche.
_Avoid_: Strategy Trial, unrestricted tuning, Principal approval bypass, live experiment

**Research Posture Performance**:
The matched-task record of economic information gain, useful-hypothesis yield, challenge survival, reproducibility, wall-clock latency, resource and Principal-attention cost, duplication, and rework used to retain, specialize, or retire a Research Posture Profile. Simulated profit alone is not a sufficient posture score.
_Avoid_: agent leaderboard, raw P&L, token efficiency, popularity

**Presentation Persona**:
Non-authoritative presentation metadata that gives an Incubator worker a stable name, tone, vocabulary, and UI identity without changing evidence selection, conclusions, confidence, resources, behavior, or authority.
_Avoid_: Research Posture, agent identity, evaluator independence, decision logic

**Velocity Objective**:
The standing objective to maximize expected economic value and uncertainty reduction delivered as reproducible decisions per wall-clock time by safely scaling approved agents, concurrency, tokens, compute, data, automation, and spending. It remains subordinate to Research Budget, Testing Budget, entitlements, evidence independence, Principal Operational Budget, and authority controls.
_Avoid_: trade frequency, unrestricted spending, agent count, move fast and break things

**Control Capacity Reserve**:
Resource headroom unavailable to Incubator workloads that preserves Safety Kernel, lifecycle, reconciliation, evidence-control, alerting, and Principal Gateway operation during saturation or failure.
_Avoid_: spare research capacity, idle waste, shared burst pool

**Capacity Expansion Proposal**:
An immutable Principal Gateway proposal to increase an existing resource envelope, binding the bottleneck, measured evidence, expected velocity and economic gain, incremental and maximum cost, scope, expiry, alternatives, and rollback. It grants no capacity until accepted by a Principal Authorization Decision.
_Avoid_: automatic budget increase, capacity warning, agent request

**Capacity Trial**:
A bounded challenger evaluation of an unproven model, provider feature, or compute class against an incumbent using decision latency, reproducibility, rework, independence, and cost. It grants no fleet-wide capacity or new vendor, entitlement, or spending authority.
_Avoid_: production rollout, free benchmark, automatic upgrade

**Incubator Resource Policy**:
The immutable versioned rules that translate the Velocity Objective, work priority, approved budgets, expected critical-path benefit, independence, liveness, and Control Capacity Reserve into Research Capacity Reservations, scale changes, and Capacity Expansion Proposals. It never creates data, spending, or trading authority.
_Avoid_: autoscaling settings, queue configuration, unlimited research mandate

**Testing Budget**:
The finite statistical error allowance assigned to an Experiment Family or hierarchy, including its confirmatory hypotheses, sequential looks, amendments, and dependence corrections. It is distinct from compute or spending authority and cannot be renewed using the same exhausted evidence.
_Avoid_: Research Budget, trial count, significance threshold

**Global Testing Ledger**:
The immutable cross-family record of hypotheses, trials, evidence overlap, testing-budget consumption, holdout access, corrections, and promotion outcomes used to prevent related searches from claiming false independence.
_Avoid_: experiment dashboard, successful-results list, model registry

**Experiment Lineage**:
The immutable parent-child path connecting economic theses, indicators, strategy rules, portfolio sizing, execution parameters, amendments, corrections, and promoted versions across every related search. Moving a hypothesis between layers does not reset its Testing Budget or evidence history.
_Avoid_: experiment folder, model ancestry, strategy version history

**Primary Promotion Metric**:
The preregistered principal measure and minimum economically meaningful effect that an Experiment Trial must satisfy after multiplicity, costs, uncertainty, and risk constraints. Secondary metrics cannot replace its failure.
_Avoid_: best metric, headline result, optimization score

**Effective Independent Sample Size**:
The uncertainty-relevant opportunity count after accounting for shared issuers, events, time periods, positions, legs, evidence clusters, and other dependence. It is reported alongside the larger raw observation count.
_Avoid_: trade count, row count, sample size

**Experiment Report**:
The periodic complete account of successful, null, failed, invalid, and stopped Experiment Trials, including costs, Testing Budget consumption, uncertainty, lessons, and linked evidence. It cannot present only promoted results.
_Avoid_: winners list, research update, promotion PR

**Indicator Deprecation**:
The immutable retirement state that blocks new consumers while preserving an Indicator Definition, its observations, and its historical decision lineage. Existing consumers must migrate, use a validated fallback, or enter quarantine.
_Avoid_: indicator deletion, rename, silent replacement

**Indicator Dependency**:
A declared reliance by an indicator or Strategy Version on specified evidence, classified as Hard when unavailable evidence disables dependent use or Soft when a separately validated degraded path exists. Safety dependencies remain fail-closed unless a Risk Policy defines a more conservative substitute.
_Avoid_: optional field, default value, fallback source

**Degraded Indicator Path**:
The separately validated behavior a Strategy Version may use when a Soft Indicator Dependency is unavailable, including its substitution or omission rule, reduced evidence state, and risk limits. It cannot weaken a safety constraint.
_Avoid_: best effort, last-known-good, silent fallback

**Evidence Change Type**:
The canonical classification of a change affecting source evidence: Factual Correction when replacement evidence is supplied; Retraction when evidence remains retainable but is no longer reliable; Rights Restriction or Required Deletion when permitted storage or use narrows; Source Unavailability when future collection stops without disproving prior evidence; or Provenance Dispute when identity, timing, or lineage cannot be certified. Uncertain classification takes the most restrictive plausible treatment.
_Avoid_: bad data, source update, deletion flag

**Evidence Control Event**:
The immutable record that an Evidence Change Type has affected identified evidence and initiated containment before correction, rebuilding, or permitted deletion. It preserves the affected lineage and decision impact without itself retaining prohibited source content.
_Avoid_: cleanup job, row deletion, source alert

**Evidence Dependency Closure**:
The complete transitive set of normalized observations, Research Snapshots, indicators, embeddings, models, experiments, Strategy Versions, promotion evidence, forecasts, and Decision Records that consumed affected evidence. Ambiguous lineage expands to the smallest enclosing scope proven complete.
_Avoid_: direct references, affected rows, best-effort impact

**Evidence Change Materiality**:
The demonstrated impact of an Evidence Change Type on observations, assessments, forecasts, qualification gates, risk decisions, or historical conclusions. No Impact requires deterministic proof that none changed; unknown impact is Material, while a Required Deletion applies regardless of economic impact.
_Avoid_: important update, small correction, judgment call

**Entitlement Artifact Matrix**:
The Data Entitlement classification of permitted access, transformation, retention, correction, and deletion for each artifact class derived from a source, including raw content, normalized fields, aggregates, summaries, features, embeddings, prompts, model artifacts, hashes, logs, caches, replicas, exports, and backups. An unspecified artifact class is not permitted evidence.
_Avoid_: source license, derived-data exception, general API rights

**Evidence Purge State**:
The non-interchangeable deletion state of affected evidence: Requested, Contained and Unavailable for Use, Active Stores Purged, Backup Expiration Pending, Verified Fully Purged, or Purge Failed or Disputed. Containment ends permitted use; only the applicable verified terminal state establishes deletion completion.
_Avoid_: deleted flag, missing row, cleanup complete

**Replay Availability State**:
The current ability to reconstruct an artifact or decision from evidence that remains legally and operationally available: Reproducible, Reproducible with Corrected Evidence, Degraded Replay, or Replay Unavailable. It never changes the historical Decision-Time View.
_Avoid_: valid decision, reproducibility passed, data missing

**Non-Content Audit Envelope**:
The maximum contractually permitted metadata that may survive deletion of source evidence, potentially including the Evidence Change Type and time, governing entitlement version, affected internal lineage, decision references, containment actions, Evidence Purge State, and Replay Availability State. It excludes content, reconstructable derivatives, and hashes unless their retention is explicitly permitted.
_Avoid_: deletion archive, redacted content, evidence copy

**Evidence Deletion Manifest**:
The immutable Evidence Control Event inventory of every affected canonical record, object version, vector, cache, replica, log, export, derived artifact, and backup, together with its controller, applicable deadline, Evidence Purge State, attempt history, and permitted completion proof. A deletion request or current-query miss is not completion evidence.
_Avoid_: cleanup list, delete response, retention report

**Evidence Revalidation**:
The deterministic rebuilding and qualification of corrected or cleanly retained evidence and every affected derivative through new versioned artifacts and preregistered trials. It never rewrites invalidated trials, restores their Testing Budget, or automatically restores Live authority.
_Avoid_: rerun, refresh model, clear quarantine

**Source Compliance Incident**:
An Evidence Control Event requiring immediate Principal escalation because it affects a Live order, open position, Live Strategy Authority Grant, deletion deadline, purge verification, or restoration of prohibited evidence. Research-only No Impact corrections remain visible without becoming incidents.
_Avoid_: data warning, source alert, research update

**Source Correction Coverage**:
The certified ability to discover an Approved Source's revisions, retractions, deletions, and sequence gaps through its strongest supported compliance stream, revision or removal interface, sequence feed, and periodic inventory reconciliation. Inadequate or disputed coverage prevents strategy-grade use.
_Avoid_: update polling, source freshness, webhook configured

**Managed Evidence Export**:
An entitlement-permitted, logged, expiring copy whose exact contents, destination, controller, and deletion obligations remain inside the Evidence Dependency Closure and Evidence Deletion Manifest. Evidence that cannot remain locatable and purgeable is not exportable.
_Avoid_: download, report file, data extract

**Evidence Integrity Certification**:
The demonstrated ability to contain, correct, purge, restore, and revalidate affected evidence across canonical stores, derived indexes, caches, replicas, exports, models, and backups without resurrecting prohibited use. Daily integrity checks, weekly Paper drills, monthly recertification, and material-change recertification provide distinct evidence.
_Avoid_: deletion test, backup test, compliance checkbox

**Evidence Tombstone Barrier**:
The canonical prohibition checked before ingest, replay, restoration, cache fill, index construction, or other renewed availability of contained or deleted evidence. A late copy remains rejected; legitimately republished evidence enters as a newly entitled version linked to, but never clearing, the prior tombstone.
_Avoid_: deleted-ID list, duplicate filter, restore cleanup

**Purge Completion Evidence**:
The contract-appropriate proof that an Evidence Deletion Manifest target reached its asserted Evidence Purge State, using deterministic verification for controlled systems and provider operation evidence plus follow-up verification for managed systems. Request acceptance alone is not completion.
_Avoid_: success response, missing search result, provider promise

**Evaluation Restatement**:
The appended recalculation of a previously published research, forecast, experiment, or model evaluation after corrected evidence, showing the changed inputs, metrics, uncertainty, and conclusions without overwriting the as-issued evaluation. When permitted evidence no longer supports recalculation, the evaluation becomes invalidated and Replay Unavailable.
_Avoid_: corrected score, updated backtest, replaced result

**Source Offboarding**:
The controlled termination of an Approved Source or Data Entitlement, including collection shutdown, dependent-use containment, final artifact inventory, permitted export or deletion, credential and job revocation, backup-expiration tracking, and preservation of only the permitted Non-Content Audit Envelope.
_Avoid_: cancel subscription, delete API key, disable source

**Source Disputed**:
An evidence state in which approved sources materially disagree or cannot be reconciled under the applicable Indicator Definition. The disagreement remains visible and dependent predictive use is unavailable until resolved or explicitly validated for that state.
_Avoid_: average value, source error, choose-best-provider

**Source Event Time**:
The source-reported instant at which an economic, market, filing, or venue event occurred, preserved with its native precision and distinct from when it was published, received, processed, or made effective.
_Avoid_: record timestamp, received time, trading date

**Publication Time**:
The source-reported instant at which it disseminated, posted, filed, or accepted evidence. It does not prove when a provider made the evidence queryable or when Market Mate received it.
_Avoid_: availability time, receipt time, event time

**Evidence Availability Time**:
The earliest certified instant at which a particular provider made evidence obtainable under the applicable Data Entitlement. When it cannot be established, it remains unknown rather than being inferred from Publication Time.
_Avoid_: publication time, backfilled timestamp, assumed availability

**Evidence Receipt Time**:
The instant Market Mate first received a particular delivery of evidence. It is the conservative knowledge boundary when Evidence Availability Time is unknown and never makes later corrections historically knowable.
_Avoid_: event time, processed time, provider timestamp

**Effective Time**:
The instant at which an identity, term, status, entitlement, or Corporate Action Case begins to govern, independent of when it was announced, published, or received.
_Avoid_: announcement date, knowledge time, settlement date

**Venue Session Calendar**:
The versioned venue- and product-specific definition of session dates and tradability intervals, including regular and extended hours, auctions, rotations, early closes, holidays, halts, and resumptions in an explicit IANA time zone.
_Avoid_: weekday schedule, market-open flag, fixed Eastern offset

**Adjusted Market Data View**:
A derived, versioned interpretation of raw observations under a declared split, dividend, or total-return adjustment policy, Corporate Action Case set, and knowledge boundary. It never overwrites raw observations or silently mixes adjustment regimes.
_Avoid_: corrected price history, raw market data, universal adjusted close

**Decision-Time View**:
The reconstruction of the evidence, definitions, availability, and corrections actually known when a historical decision occurred. Later knowledge cannot replace it.
_Avoid_: current history, corrected backtest, reconstructed rationale

**Corrected Research View**:
The current append-only interpretation of evidence after accepted corrections, linked to the affected historical observations, experiments, and decisions without changing their Decision-Time View.
_Avoid_: rewritten history, current truth, backfilled decision

**Autonomous Execution**:
Order placement without per-order human approval, but only through the Principal's preset authority and non-bypassable risk boundaries.
_Avoid_: unattended trading, unrestricted automation

**Authority Grant**:
A versioned, expiring Principal approval defining which autonomous component may perform which actions, in which environments, strategies, schedules, tools, and capital/risk limits, with required evidence, monitoring, notifications, and rollback. A component cannot approve or broaden its own grant.
_Avoid_: permission flag, agent trust

**Live Strategy Authority Grant**:
An Authority Grant binding one exact Live Eligible Strategy Version to its environment, venue, Strategy Sleeve, instruments, capabilities, schedule, capital and risk limits, Preauthorized Strategy Fallback, and earliest applicable expiry. Initially it expires no later than 30 calendar days and immediately on required certification expiry or evidence invalidation.
_Avoid_: strategy approval, permanent authorization, deployment status

**Live Authority Renewal**:
The Principal's authenticated approval to continue an unchanged Live Strategy Authority Grant after fresh automated evidence, compatibility, certification, and reconciliation checks pass. It never rebuilds evidence, widens scope, or cures an invalidated gate.
_Avoid_: auto-renewal, new promotion, session refresh

**Operational Notification**:
A non-authoritative message sent to an approved external communication channel, such as Slack, to inform the Principal of a threshold, incident, approval request, or recovery state. It may link to Market Mate but cannot itself approve, reject, resume, or alter trading authority.
_Avoid_: approval, audit record, command

**Principal Gateway**:
The isolated authority and communication boundary that authenticates the Principal, presents exact immutable proposals and alerts, records proposal-bound Principal Authorization Decisions and emergency restrictions, and exposes approved read-only operational state. It owns no strategy, risk, ledger, execution, or ability to override the Safety Kernel or broaden an Authority Grant.
_Avoid_: mobile backend, Engine API, admin portal, approval bot

**Approval Companion**:
An optional Principal client, such as a native mobile application, that communicates only through the Principal Gateway to present server-fetched evidence, receive Operational Notifications, invoke emergency containment, and cryptographically submit a Principal Authorization Decision. It owns no strategy, risk, ledger, execution, or canonical authorization state.
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
The greatest applicable cost-inclusive loss for a Risk Position among its contractually defined maximum, deterministic stress, conservative liquidation, exercise/assignment and settlement, and broken-protection or lifecycle outcomes. Broker margin and buying-power treatment are separate constraints and cannot reduce it.
_Avoid_: purchase price, position size, margin requirement

**Risk Position**:
All economically linked lots and option legs within one Strategy Sleeve and underlying exposure that rely on the same protection or exit thesis. Splitting an idea across orders, lots, expirations, or agents does not create additional Position Risk capacity.
_Avoid_: broker position row, order, option leg

**Risk Offset Credit**:
The reduction in a Risk Position's modeled loss recognized only for protection inside the same certified economic package whose identity, enforceability, matching terms, liquidity, execution, and reconciliation remain valid through the stress horizon. Proposed, disputed, cross-strategy, or unavailable protection receives no credit.
_Avoid_: diversification benefit, correlation hedge, intended protection

**Risk Valuation**:
The reproducible conservative estimate of a Risk Position's loss under its deterministic adverse execution, market, liquidity, and lifecycle scenarios. It is distinct from current accounting value, forecast probability, broker margin, and reported P&L.
_Avoid_: position mark, expected loss, margin requirement

**Effective Position Risk Limit**:
The most restrictive current allowance among the percentage Risk Policy, Strategy Scale Tier, Authority Grant dollar scope, remaining portfolio and cluster capacity, liquidity capacity, and broker collateral constraints.
_Avoid_: five-percent allowance, target position size, buying power

**Strategy Scale Tier**:
The evidence- and Principal-approved Position Risk authority currently earned by one Strategy Version: Observation, Restricted Live 1, Restricted Live 2, or Mature Live. Account profits or contributions may increase equity but cannot advance the tier or widen its Authority Grant automatically.
_Avoid_: account size, strategy confidence, automatic compounding

**Aggregate Standalone Risk**:
The sum of every Risk Position's standalone Position Risk without diversification credit. It governs the portfolio's normal and absolute aggregate modeled-risk limits even when the individual worst outcomes are not simultaneous.
_Avoid_: portfolio VaR, net exposure, scenario loss

**Scenario Portfolio Loss**:
The greatest cost-inclusive loss of the whole portfolio under one coherent deterministic market, liquidity, correlation, and lifecycle scenario. It complements but never replaces Aggregate Standalone Risk.
_Avoid_: sum of position risks, expected portfolio loss, diversification benefit

**Lifecycle Funding Requirement**:
The greatest temporary cash, collateral, buying-power, delivery, fee, and settlement capacity required to survive the certified exercise, assignment, expiration, and corporate-action paths of a Risk Position. Passing Position Risk does not imply that this separate requirement passes.
_Avoid_: maximum loss, margin requirement, premium paid

**Risk Scenario Contract**:
The immutable versioned set of structural, fixed-grid, empirical, market, liquidity, correlation, execution, and lifecycle scenarios and calculation semantics used to produce Risk Valuation. Historical or learned challengers may add conservatism but cannot remove its structural loss floors.
_Avoid_: risk model, forecast distribution, current stress settings

**Minimum Executable Unit**:
The smallest venue-supported quantity of an exact Tradable Instrument or complete atomic package whose executable economics, costs, collateral, lifecycle funding, liquidity, Position Risk, and portfolio effects can be evaluated. If it exceeds any applicable limit, the candidate is ineligible at current equity.
_Avoid_: minimum order size, cheapest contract, fractional option

**Capital Utilization**:
The share of broker-reconciled account equity committed as security value, option premium, or collateral. It is distinct from Position Risk and aggregate modeled loss.
_Avoid_: exposure, invested percentage

**Draft Strategy Proposal**:
A mutable, non-authoritative strategy design that may be revised during research but cannot enter Paper or Live execution. Freezing its complete behavior and dependencies creates a Strategy Version.
_Avoid_: Strategy Version, experimental live rule, draft deployment

**Strategy Version**:
An immutable, content-addressed version of the complete declarative rules and pinned dependencies that generate trade candidates and determine sizing, entry, management, and exit. Changing any behavior or dependency creates a new Strategy Version.
_Avoid_: algorithm update, bot behavior, mutable strategy

**Strategy Lifecycle State**:
The non-interchangeable governance state of a strategy: Draft Strategy Proposal, Frozen Strategy Version, Research Qualified, Paper Authorized, Live Eligible, Live Authorized, Quarantined, Wind-Down, or Retired. Evidence qualification and execution authority remain separate; only the deterministic Engine-controlled transition service may enforce gates and change state, no agent or coalition may direct a transition, and any authority-bearing transition must bind its required Principal Authorization Decision.
_Avoid_: deployment stage, environment flag, confidence level

**Paper Authorized**:
A Strategy Lifecycle State permitting a Strategy Version to operate only in its approved Paper scope after deterministic evidence, safety, and resource gates pass. It grants no Live eligibility or authority.
_Avoid_: paper tested, Live Eligible, simulation mode

**Live Eligible**:
A Strategy Lifecycle State showing that a Strategy Version has passed every required evidence, risk, compliance, and operational gate for a Live proposal but has no Live trading authority until the Principal grants it.
_Avoid_: Live Authorized, approved strategy, ready-to-trade

**Live Authorized**:
A Strategy Lifecycle State in which an authenticated Principal Authorization Decision and current Authority Grant permit an exact Live Eligible Strategy Version to act within a bounded environment, capital, instrument, capability, and time scope.
_Avoid_: Live Eligible, generally approved, production strategy

**Hard Promotion Gate**:
A non-bypassable compliance, risk, reproducibility, entitlement, leakage, or authority condition that every evaluator must pass before a Strategy Version can advance. Neither evaluator consensus nor the Principal can convert a failed gate into a pass.
_Avoid_: reviewer opinion, weighted vote, warning

**Evaluator Independence**:
The degree to which promotion evaluators use genuinely distinct model, implementation, evidence, and reasoning paths. Evaluators with a materially shared failure path count as one vote, and every dissent remains visible.
_Avoid_: agent count, model name count, unanimous text

**Strategy Promotion Review**:
The evidence-bound review that first enforces every Hard Promotion Gate, then requires complete reproducibility/provenance/leakage, risk/execution/lifecycle, and economics/robustness/benchmark review with at least two genuinely independent supporting evaluation paths and no material unresolved dissent. Dissent yields Needs More Evidence rather than majority override.
_Avoid_: majority vote, agent approval, promotion score

**Strategy Registry**:
The append-only catalog of immutable Strategy Versions, their lifecycle transitions, lineage, pinned dependencies, Promotion Bundles, review outcomes, authority history, quarantine, rollback, supersession, and retirement. Registry admission grants no execution authority.
_Avoid_: strategy repository, deployed strategies, winners list

**Strategy Lineage**:
The immutable family relationship among Strategy Versions that implement the same economic strategy thesis. Multiple versions may run in separate Paper sleeves, but initially only one version in a lineage may open new Live exposure in one Brokerage Account.
_Avoid_: Experiment Family, deployment branch, strategy name

**Strategy Change Class**:
The revalidation scope assigned to a proposed change: Non-Behavioral for append-only annotation or correction without a new version; Mechanical Compatibility for unchanged economics requiring a new version, targeted validation, and complete regression/safety checks; or Economic Behavior for any model, evidence, threshold, universe, instrument, sizing, trade, cost, risk, or fallback change requiring a new version and full promotion evidence. Uncertainty defaults to Economic Behavior.
_Avoid_: patch size, semantic version number, reviewer discretion

**Strategy Evidence PR**:
The reviewable proposal linking a Strategy Version to its complete preregistration, trials, failures, reproducibility manifest, Promotion Bundle, independent reviews, and Paper findings. Agents may maintain a draft, but a Live promotion becomes mergeable only after every gate passes and the Principal approves the exact Promotion Bundle; merge alone never grants authority.
_Avoid_: deployment PR, Live approval, code review only

**Promotion Rejection**:
The Principal's recorded refusal of an exact Promotion Bundle, including the reason and notification cooldown. It grants no authority, does not rewrite evidence, and cannot repeatedly re-request approval without a Principal request, materially new evidence, or expiry of the defined cooldown.
_Avoid_: failed strategy, quarantine, dismissed alert

**Principal Strategy Containment**:
The Principal's always-available authority-reducing action to revoke a Strategy Version's grant, quarantine it, reject renewal, or request Strategy Wind-Down. It cannot waive failed evidence, skip lifecycle obligations, force an unsafe action, or broaden authority.
_Avoid_: manual override, forced pass, discretionary trade

**Strategy Transition Record**:
The signed, append-only, idempotent record that atomically identifies one Strategy Version lifecycle transition, its prior and resulting states, evidence, gates, authority, actor, time, and linked artifacts. Partial updates in dependent systems never imply that the transition succeeded.
_Avoid_: status update, deployment event, database flag

**Strategy State Divergence**:
An incident in which required registry, evidence, PR, deployment, or authority surfaces disagree about a Strategy Lifecycle State. The effective state becomes the most restrictive consistently supported state, and affected promotion or new exposure remains frozen until reconciliation.
_Avoid_: eventual consistency, stale UI, assume success

**Strategy Sleeve**:
The ledger and risk-attribution scope that assigns each economic allocation, intent, order, fill, cost, position contribution, and outcome to one Strategy Version while remaining subordinate to aggregate portfolio controls.
_Avoid_: brokerage subaccount, ticker position, agent wallet

**Portfolio Intent Resolution**:
The deterministic pre-order process that compares simultaneous Strategy Sleeve intents and may conservatively net or reject conflicts without inventing a new economic trade, self-crossing, or silently transferring position ownership between strategies.
_Avoid_: strategy vote, order merge, portfolio optimization

**Cross-Strategy Intent Conflict**:
A condition in which separate Strategy Sleeves request opposing or economically overlapping actions that cannot be executed without hidden interference or counterfactual attribution. Initially, opposing intents are rejected; internal crossing is prohibited.
_Avoid_: natural hedge, free netting, internal fill

**Aggregated Strategy Order**:
One venue order combining identical same-direction intents only after each Strategy Sleeve's allocation is fixed. Resulting fills, fees, slippage, cash, positions, and outcomes are apportioned deterministically from that pre-submission allocation.
_Avoid_: net order, shared position, post-fill allocation

**Strategy Dependency Invalidation**:
The event raised when a pinned model, indicator, source, instrument definition, policy, or venue capability becomes unusable or materially corrected. It quarantines affected use unless an already validated degraded path applies; substitution requires a new Strategy Version and proportionate evidence.
_Avoid_: automatic upgrade, dependency refresh, latest-version migration

**Strategy Quarantine**:
A state that prohibits a Strategy Version from initiating new exposure after its evidence, calibration, data quality, or live behavior violates an approved threshold.
_Avoid_: pause, poor performance

**Strategy Rollback**:
An audited authority transition from one Strategy Version to a prior version that independently remains compatible, certified, and eligible under current evidence and policies. Rollback never rewrites either version or bypasses a fresh authority check.
_Avoid_: undo deployment, restore old code, automatic downgrade

**Preauthorized Strategy Fallback**:
An exact prior Strategy Version and tighter-or-equal authority scope named in the current Authority Grant for automatic rollback after fresh compatibility, certification, reconciliation, and non-increasing-risk checks pass. Without it, quarantine remains contained until the Principal decides.
_Avoid_: last known good, automatic version selection, emergency override

**Strategy Supersession**:
The immutable relationship declaring that a newer Strategy Version replaces an older one for future consideration. It grants no authority, performs no automatic migration, and does not erase the older version's evidence or history.
_Avoid_: rollout, upgrade, overwrite

**Strategy Retirement**:
The permanent terminal state that prevents a Strategy Version from receiving new authority while preserving its evidence, decisions, and lineage. Returning the economic idea requires a new Strategy Version and new evidence.
_Avoid_: pause, quarantine, delete strategy

**Strategy Wind-Down**:
An exit-only Strategy Lifecycle State that blocks new exposure while the Strategy Version completes its pinned order, position, assignment, settlement, reconciliation, and ledger obligations. Retirement cannot become final until every obligation is closed.
_Avoid_: retired strategy, liquidation command, quarantine

**Strategy Factory Cycle**:
The weekly bounded process that reviews daily evidence and registered questions, deduplicates against lineage, and prioritizes candidate generation by information value, safety relevance, independence, uncertainty reduction, applicability, and cost rather than preliminary profit. Immediate evidence may trigger quarantine or registration but not production retuning.
_Avoid_: daily retraining, profit leaderboard, unlimited search

**Performance Objective**:
The versioned, net-of-cost criteria used to judge Market Mate against cash/no-trade and a contemporaneous S&P 500 total-return benchmark without implying guaranteed outperformance.
_Avoid_: profit target, average market return

**Model Version**:
An immutable, content-addressed predictive or descriptive model with pinned inputs, training evidence, parameters, calibration, validation, and runtime contract. It may produce evidence or forecasts but cannot size, authorize, or execute a trade by itself.
_Avoid_: Strategy Version, live strategy, model deployment

**Earnings-Direction Model**:
A Model Version that produces a calibrated probability that a security will move up or down after a specified earnings event. A separately validated Strategy Version may consume it when deciding whether and how an option position may remain open through that event.
_Avoid_: earnings prediction, sentiment score

**Approved Source**:
A publisher, feed, or public-data endpoint whose content the Principal has authorized for collection and whose terms permit the system's intended access, retention, and analysis.
_Avoid_: website, scraper target

**Data Entitlement**:
The written, account- and plan-specific permission governing how Market Mate may access, automate, process, retain, replay, derive from, display, correct, delete, and terminate use of a source's data. Ambiguous or unsupported rights permit sandbox inspection only and cannot support strategy evidence.
_Avoid_: API key, subscription, public availability

**Promotion-Grade Market Data**:
Point-in-time market data whose coverage, timing, bid/ask fidelity, lineage, retention rights, capacity, and correction behavior are certified for the exact strategy evidence it supports. Delayed, indicative, IEX-only, last-trade-only, midpoint-only, or rights-ambiguous data may aid development but cannot establish Paper economics or Live eligibility.
_Avoid_: available quote, broker feed, real-time-looking data

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
A Principal-facing alerting workflow rooted in one Alert Event and its evidence, severity, environment, deadline, containment, acknowledgement, deliveries, required action, and resolution.
_Avoid_: text message, notification

**Alert Event**:
The canonical immutable record of one condition requiring Principal awareness or action, independent of how many channels attempt to deliver it. It links severity, environment, evidence, deadline, containment, acknowledgement, and resolution.
_Avoid_: Slack message, SMS, push notification

**Alert Delivery**:
One channel-specific attempt to communicate an Alert Event, including destination class, attempt time, provider outcome, and delivery evidence. It carries no trading or approval authority.
_Avoid_: Alert Event, acknowledgement, approval link

**Principal Alert Acknowledgement**:
The Principal's authenticated confirmation in Market Mate that the exact current version of an Alert Event has been seen. It may reduce repeated delivery but never proves remediation, changes authority, or removes containment.
_Avoid_: Slack reaction, provider receipt, incident resolution

**Alert Resolution**:
The evidence-backed state showing that an Alert Event's triggering condition and required remediation have completed. It is distinct from acknowledgement and from any separate Live Resumption decision.
_Avoid_: alert dismissed, message read, trading resumed

**Alert Severity**:
The operational urgency assigned to an Alert Event: Critical, Action Required, Warning, or Informational. It is distinct from incident severity and determines routing, acknowledgement, repetition, and escalation.
_Avoid_: incident SEV, notification channel, model confidence

**Alert Policy Version**:
An immutable version of severity assignment, channel preference, fallback, acknowledgement deadlines, repetition, correlation, quiet hours, digest, maintenance, containment linkage, and non-bypassable routing minimums.
_Avoid_: notification settings, mutable preferences, contact list

**Alert Correlation Group**:
A root-cause grouping that reduces repetitive external delivery while preserving each underlying occurrence and each Execution Environment's independent Alert Event, severity, containment, acknowledgement, and resolution.
_Avoid_: deduplicated alert, combined Paper/Live incident, suppressed event

**Maintenance Window**:
A bounded, Principal-approved interval naming the component, environment, expected effects, and rollback in which only specifically predicted noncritical deliveries may be suppressed. Unexpected or Critical conditions remain alertable.
_Avoid_: alerts off, mute period, quiet hours

**Stage Applicability Matrix**:
The authoritative mapping of each control and service to Local Research, Local Paper, Cloud Paper, Restricted Live, and Autonomous Live as required, prohibited, deferred, or inherited, with its Trust Zone, authority, evidence, owner, failure scope, and recovery gate. A later-stage control cannot block an earlier stage where it provides no safety benefit.
_Avoid_: one universal readiness checklist, Live controls everywhere

**Planning Claim**:
A time-bounded advisory reservation of one planning item that records the claimant, expected artifact, working branch or worktree when applicable, next checkpoint, and latest observable activity. It is audited after 24 hours of inactivity and retained only when live work or a usable artifact is verified.
_Avoid_: permanent assignment, ownership lock

**Decision Liveness Record**:
The operational record for blocked planning work: exact blocked scope, hazard, dependency, owner, next action or evidence, checkpoint or expiry, escalation path, and safe work that may continue. A timeout escalates but never grants authority or converts a failed gate into a pass.
_Avoid_: blocked label, waiting for safety

**Safety Control Case**:
The versioned justification for one safety control, including its hazard, applicable stage and scope, enforcement action, evidence, owner, recovery path, expected benefit, false-positive and Principal-attention burden, Operating Cost, dependencies, review cadence, and merge or retirement criteria.
_Avoid_: safety best practice, permanent control by default

**Principal Operational Budget**:
The bounded amount of noncritical proposal volume, review time, certification work, and alert load Market Mate may impose on the Principal before discretionary affected work queues or pauses. Critical incidents and containment are not suppressed by this budget, and expanding it requires authenticated Principal approval.
_Avoid_: approval quota that suppresses emergencies, unlimited review burden

**Certification Lease**:
A scoped, expiring certification for one capability whose renewal evidence starts before expiry, may reuse unchanged automated evidence, and remains independently revocable even when presented in a bundled Principal review. Expiry disables only dependent scope and never passes automatically.
_Avoid_: monthly global recertification, silent grace period

**Emergency Restriction**:
A temporary scope-narrowing state activated only by an already-approved deterministic trigger. It records the policy, hazard, scope, start, review deadline, and release evidence; reaching the deadline escalates and preserves containment rather than automatically loosening it.
_Avoid_: agent-created policy activation, automatic timeout release

**Economic Evaluation Family**:
A genuinely independent strategy-review path for economics, robustness, and benchmark value. Reviewers sharing a model, dataset, implementation, or evaluator failure path count as one family when mixture-of-experts consensus is computed.
_Avoid_: agent count, model-name count, correlated vote
