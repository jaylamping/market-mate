# Staged validation and restricted live-rollout contract

Decision record for [issue #8](https://github.com/jaylamping/market-mate/issues/8) (Autonomous Options Trading Blueprint map). This contract consolidates the staged-validation decision with the prior contracts it consumes. It defines what a Strategy Version must satisfy to progress from backtest through Scrutinized Paper to Principal-approved Restricted Live, and how stages fail, roll back, and re-enter. It supersedes the ticket's original "60–90 days of scrutinized paper trading" phrasing with the conjunctive minimums in the stage-2 exit gate.

## Stage model

Three attributes ride on one five-stage linear spine. "Stage" always means a spine checkpoint; Environment and Authority Tier are per-stage attributes, never independent tracks.

| # | Spine stage | Environment (Stage Applicability Matrix) | Capability Scope | Authority Tier ceiling (Strategy Scale Tier) |
|---|---|---|---|---|
| 1 | Research Evidence MVP | Local Research | any in-scope instrument | n/a — no orders |
| 2 | Qualified Paper MVP | Local Paper, tail on Cloud Paper | per strategy scope | n/a — no live orders |
| 3 | Stock-only Restricted Live | Restricted Live cloud environment | stock only | Observation → Restricted Live 1 → Restricted Live 2 |
| 4 | Options-enabled Restricted Live | Restricted Live cloud environment | stock + defined-risk options | per capability, restart at Observation |
| 5 | Autonomous Live | Restricted Live cloud environment | capability-scoped | Mature Live, per capability |

Each stage contract names its entry evidence, applicable controls, explicit non-applicable controls, stop conditions, the Principal decision, and the safe work that continues after a failure. A stage may conclude that options, sentiment, or another optional capability is ineligible without blocking a narrower safe stage. No stage failure loosens the existing safety policy.

## Stage 1 — Research Evidence MVP (exit gate)

- ≥1 Strategy Version passes Research qualification per #31: ≥3 disjoint chronological walk-forward evaluations + 1 sealed Release Holdout, Effective Independent Sample Size ≥30, one-sided 95% LCB ≥ cash +5 annualized percentage points net of Trading Costs, positive S&P 500 Excess Total Return where #31 makes it a hard comparator.
- Executable Capital Feasibility assessment on the $1,000 bankroll: minimum contract units, collateral, approvals, fees, slippage, assignment exposure, total modeled Position Risk — without weakening safety. If no option structure qualifies, stage 4's stock-only fallback applies (below).
- Data Contract entitlements and Source Registry coverage certified for every strategy input (#9, #11).
- Cost model within the #41 caps ($250/month cash Operating Costs, $2,000 year one).
- Principal go/no-go checkpoint (below).

## Stage 2 — Qualified Paper MVP

**Entry:** Alpaca Paper-Certified for the strategy's capability scope (#20) and the Conservative Simulation Overlay statistically qualified (#48) before any strategy Paper evidence counts toward promotion. The qualifying window may begin on Local Paper, but its final ≥60 calendar days must run on Cloud Paper in the environment lineage that will host Restricted Live, so the promotion bundle is exercised on the target hosting path.

**Exit (conjunctive maximum — both regimes apply):**

- #31 Qualified Paper floors: ≥6 calendar months, ≥50 matured independent Risk Positions, EIS ≥30, qualified adverse-condition evidence (real adverse episode or sealed point-in-time overlay replay; synthetic stress alone insufficient).
- This ticket's floors, standing as minimums beneath #31: ≥60 trading sessions and ≥30 independent matured opportunities, whichever is longer, plus 2 Event Cycles for event-driven strategies.
- All qualifying evidence comes from a Scrutinized Paper segment (glossary). Venue-fidelity minimums (#20: ≥20 consecutive sessions, 100 stock / 100 single-leg / 100 multi-leg attempts, 2 expiration cycles) are tracked as venue evidence, never counted as strategy evidence.
- Paper success is not proof a different Live venue behaves identically; the live-calibration phase below measures the deltas.

## Stage 3 — Stock-only Restricted Live (entry gate, in order)

1. Counsel gate passed (#53, the 8 written-advice questions) and first-Live compliance attestation (#53 trigger a).
2. Live venue capability-certified for stock orders (#20 status: Live Certified).
3. Tier 1 Observation: Live Shadow Evaluation completed first, gate numbers preregistered at Live Eligibility and never tuned after (#30).
4. **Minimum-size live calibration** (first phase, under RL1 per-order approval): ≥10 trading sessions, ≥30 live stock orders, ≥3 executed exits/stops; measures acknowledgement/rejection, fill, slippage, fees, buying-power, and lifecycle deltas vs paper and overlay predictions; any delta beyond the conservative 95% bound triggers #21 parity containment immediately; the calibration report appends to the promotion evidence. The Principal may tighten (never loosen) these defaults at Live Eligibility.
5. Signed, immutable Promotion Bundle deployed into the Live boundary (#21) — never a mode switch of an existing runtime.
6. #44 stress/survivability evidence for the stock scope.
7. Tax gate (stock part): live lot-level accounting with computed taxpayer-side wash sales and a CPA-ready package generated from Live-shaped rehearsal data (#35). Paper artifacts never become tax evidence. CPA professional acceptance is not yet blocking.
8. Safety Kernel in Normal state (#46).

Every restricted live order runs the #21 pre-submit invariants, Live preview, and Conservative Simulation Overlay before submission.

## Stage 4 — Options-enabled Restricted Live (additive entry)

On top of the full stage-3 gate list, for the options capability specifically:

- #33 adversarial Paper certification (broker cutoffs, early assignment, outages, stale clocks, lost notifications, illiquidity, unreachable Principal) and Survivability Policy v1 exercised (60s/5min detection and containment, 24h+next-opportunity unattended bound).
- The options capability enters at Observation and advances one tier at a time per #30, independent of stock's tier. Each new instrument class does the same.
- #28 tax gate: full CPA acceptance before the options capability enables (stock's CPA-ready package upgrades to accepted).
- Options venue capability certification plus a second minimum-size live calibration covering single-leg and multi-leg.
- #44 options stress/lifecycle evidence; Greek-based caps stay deferred to an evidence-gated Risk Policy version.
- Executable Capital Feasibility re-run for options: if no defined-risk structure qualifies at $1,000 without weakening safety, options remain Paper-only and stock-only Restricted Live proceeds — the explicit stock-only fallback.
- Stock-only safe work continues throughout.

## Stage 5 — Autonomous Live

Entry consumes #30 unchanged: advance to Mature Live exactly one tier at a time through preregistered quantitative gates whose numbers are fixed at Live Eligibility, zero unresolved compliance denials, zero containment events, continuous clean reconciliation, Strategy Promotion Review, fresh Principal Authorization Decision; 30-day Live Strategy Authority Grants with renewal evidence starting 7 days before expiry, unrenewed grants expiring directly into containment; revocation anytime without cause; permanent credential/withdrawal/kernel denials at every tier. Authority is capability-scoped: Mature Live may be granted for stock while options remain Paper-only; options autonomy additionally requires options-enabled Restricted Live evidence.

## Principal checkpoints and within-stage cadence

- A Principal go/no-go checkpoint closes every stage boundary with a fixed five-part preregistered pack: **Economic** (net excess-return LCBs; fully loaded cost vs the #41 caps), **Safety** (containment/quarantine/reconciliation/compliance/counsel records), **Usability** (dashboard + alert acceptance by the Principal), **Maintenance** (incident count, operator hours), and a **safe-work-that-continues** statement. Approval is point-in-time; material new evidence reopens the gate; no stage ever auto-advances.
- Within stages: weekly 15-minute Principal review during Paper MVP and both Restricted Live stages (exception-driven agenda: containment events, parity telemetry, qualification progress, cost vs caps); monthly pack refresh during Autonomous Live; containment/quarantine events surface immediately via #36 Operator Alerts regardless of cadence.
- Benchmark reporting per #31 at every boundary: daily chain-linked net TWR vs contemporaneous cash (always required) and S&P 500 total return (hard where #31 requires); external cash flows never count as performance; Paper economics are evidence, reported separately, never commingled with Live portfolio history (#16, #19).

## Failure semantics

- A failed stage never loosens policy and ends in explicit rollback: revoke grants, close exposure risk-reducing only, preserve evidence; the Principal decides retry, retire, or re-scope.
- Research and Paper continue during Live containment unless the failing dependency is shared (dependency-scoped #46 semantics).
- Account-wide Halted (#5 Circuit Breaker) freezes the Live boundary; Paper evidence collection may continue but no promotion or stage-advance decisions issue while the affected scope is Frozen/Halted/Uncertain; recovery paces at most one level per trading day (#46).
- **Stage re-entry:** re-entry requires re-passing that stage's full entry gate with fresh evidence — prior approvals do not survive, and all evidence must respect its expiry (#21 30-day recertification, #31 30-day eligibility expiry).

## Stage-aware Audit Dashboard

Every stage surfaces, display-only (#18/#51 no-authority boundary): current stage + Authority Tier badge, live qualification progress meters (sessions, matured positions, EIS estimate, Event Cycles), parity envelope telemetry, containment/quarantine timeline, fully loaded cost vs caps, and the next checkpoint's evidence pack status.

## Effect on other decisions

- Resolves #8; unblocks [Capital scaling, reinvestment, and withdrawal policy](https://github.com/jaylamping/market-mate/issues/37), whose evidence base (repeatability, drawdown recovery, reserves) now scales from the stage-3/4 gates and #31's Capital Expansion Eligibility floors.
- Graduates the map's final fog item: module-level acceptance criteria and deployable work units are now specifiable for stage 1 only; later-stage implementation remains out of scope until its checkpoint passes.
- Glossary: adds **Event Cycle** and **Scrutinized Paper** to CONTEXT.md.