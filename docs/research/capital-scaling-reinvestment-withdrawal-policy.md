# Capital scaling, reinvestment, and withdrawal policy

Decision record for [issue #37](https://github.com/jaylamping/market-mate/issues/37) (Autonomous Options Trading Blueprint map). This policy governs what happens after restricted live validation: whether the Principal adds capital, how Market Mate may increase deployed exposure, and how authority retreats. It consumes the [staged validation contract](./staged-validation-and-restricted-live-rollout.md), #31's Capital Expansion Eligibility, #34's loss-budget machinery, #5's account containment, #44's scale tiers, #30's grant rules, and #33's lifecycle headroom.

## Fixed boundary (from the ticket)

Every withdrawal is initiated outside Market Mate by the Principal. Market Mate may model eligibility, observe and reconcile the broker event, update ledgers, benchmarks, reserves, and performance, and automatically reduce deployed authority; it can never expose or invoke a withdrawal action.

## Scaling gate (repeatability evidence)

- Per Strategy Version: #31 Capital Expansion Eligibility verbatim — ≥12 months fully reconciled Live evidence, ≥100 matured independent Risk Positions, EIS ≥50, adverse-condition evidence, and none of its failure conditions (strategy-caused hard Risk Policy breach, unresolved Reconciliation Break, max drawdown ≥10%, negative conservative downside-risk-adjusted performance, dependence on one unrepeatable winner); eligibility expires after 30 calendar days or immediately on material new evidence, drawdown, reconciliation failure, dependency change, or quarantine.
- Portfolio-level addendum at account level: zero containment events and continuously clean reconciliation across the same window.

## Scaling Steps (increments, cadence, authorization)

- Each expansion is a distinct Principal-approved **Scaling Step** — never automatic: at most 2× current Trading Capital per step, at least 90 calendar days between steps.
- Every step requires, current at the step (not historical): re-passed #31 eligibility, fresh #44 scale-tier evidence for every strategy that will deploy more, a fresh Principal Authorization Decision, and the Scaling Reserve (below) intact.
- Profits raise equity but are redeployed only within *existing* certified limits — current Strategy Scale Tiers, #5 position/aggregate caps, #33 Lifecycle Funding headroom. Profits never advance a tier or widen an Authority Grant (#30), and growing equity never satisfies #31's sample-size floors.

## Scaling Reserve

Before any Scaling Step — and continuously — the account holds unencumbered cash ≥ the larger of:

1. #5's utilization headroom: 25% of equity (the inverse of the 75% Capital Utilization ceiling);
2. options collateral plus #33 Lifecycle Funding headroom floors for all enabled capabilities.

A reserve shortfall blocks scaling and new exposure; it never triggers liquidation to restore the reserve.

## Drawdown-recovery precondition

A Scaling Step additionally requires: no active Watch or Quarantine anywhere in the account, and account drawdown recovered to within 5% of its high-water mark (#5's warn level). Containment states clear only per #46's one-level-per-day recovery pacing.

## Withdrawal rule

- Eligible source: realized, reconciled, settled net profits only — never capital needed by enabled capabilities.
- Certified minimum: a withdrawal must leave Trading Capital ≥ every enabled capability's certified minimum capital (the Executable Capital Feasibility minimums from the stage contract).
- **Withdrawal Eligibility Model**: the system may compute eligibility and flags ineligibility *before* the Principal acts; it never exposes or invokes the withdrawal.
- After the broker event lands, Market Mate observes and reconciles it, updates ledgers, benchmarks, reserves, and performance, and automatically reduces deployed authority to restore headroom — never auto-liquidates to fund the withdrawal.
- External cash flows (contributions and withdrawals) never count as performance (#31); withdrawals are recorded in the Capital Ledger and never commingled with Paper records (#16).

## Automatic de-scaling (exhaustive triggers)

Deployed exposure or Strategy Scale Tier reduces automatically, dependency-scoped per #46, on any of:

1. #34 Wind-Down (100% Strategy Loss Budget) or any Quarantine (75%, or an immediate trigger);
2. #30 Live Strategy Authority Grant expiry into containment (no grace period);
3. #21 capability quarantine (parity envelope breach, recertification lapse);
4. #44 evidence-tier degradation for the strategy's scale;
5. #5 account-level containment (10% freeze, 15% halt, 5% daily / 8% rolling-week freeze).

Restoration is always Principal-approved after cause-specific revalidation (#34); never automatic. Live authority is never auto-restored (#30, #34).

## Economic Qualification gate (Operating Costs)

This policy defines the gate and does not pull the trigger:

- **Economic Qualification (account-level)** = ≥12 months of Live evidence with net excess return above cash after Trading Costs and fully loaded Operating-Cost reporting within the #41 caps.
- Reaching it merely *enables* a separate Principal decision on whether Operating Costs enter future performance economics.
- Until then: Operating Costs stay manually funded outside Trading Capital, fully loaded reporting continues (#24, #31), and automated payment, reimbursement, or allocation of Operating Costs remains out of scope for this blueprint.

## Glossary

CONTEXT.md gains **Scaling Step**, **Scaling Reserve**, and **Withdrawal Eligibility Model**; existing **Economic Qualification** and **Capital Expansion Eligibility** remain compatible and unchanged.

## Effect on other decisions

- Resolves #37. The blueprint's remaining open child is [Research Evidence MVP module-level acceptance criteria and deployable work units](https://github.com/jaylamping/market-mate/issues/78), with [Native Approval Companion interface and activation contract](https://github.com/jaylamping/market-mate/issues/51) claimed on a live session.
- No map fog item graduates: the separate Operating-Costs decision remains out of scope per the map, now with its gate defined here.