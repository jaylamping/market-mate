# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The Principal: one individual (Kansas-based) who owns the brokerage account, supplies capital, and sets the system's authority and risk boundaries. Their job is to supervise an autonomous trading system — review evidence, approve or deny authority-sensitive proposals, and act on alerts and emergencies — without the system or its agents ever exceeding the authority granted. No other user class exists; the dashboard is owner-only in every stage.

## Product Purpose

Market Mate is an autonomous, self-directed stock-and-options trading system for that single Principal. It discovers, tests, and refines durable economic edge across Research and qualified Paper environments, then executes Live only through a deterministic Safety Kernel with explicit Principal approval of every Live promotion. Success means durable after-cost expected profit earned strictly within explicit risk, compliance, and authority boundaries — with every claim reproducible from preserved evidence.

## Positioning

A single-Principal autonomous trading system built on hard separation of concerns: the Incubator discovers and challenges edge but holds zero authority; Sentinel deterministically enforces the Principal's immutable risk, compliance, and order-admission rules and cannot be bypassed; Engine orchestrates but cannot manufacture spending or trading authority. The dashboard is a display-only audit surface — it can never become an order path. A neighboring product could copy the trading features but not this governance topology.

## Operating Context

- Stage 1 (current): local Research evidence MVP. The dashboard binds to localhost only and is display-only, read-only, and zero-order-authority by configuration guard (`frontend/start.mjs` refuses any other config).
- Stage boundaries close with a Principal go/no-go pack (Economic, Safety, Usability, Maintenance, safe-work-that-continues); no stage auto-advances.
- Domain truth lives in root `CONTEXT.md` (authoritative glossary: Incubator, Sentinel, Engine, Trust Zone, Workload Release, Decision Records, Capital Ledger, etc.). UI terminology must match it.
- Prototype surfaces: `prototype/audit-dashboard-transparency/` (three dashboard variants; A "Command Ledger" implemented in `frontend/` alongside Stage-1 Surfaces) and `prototype/native-approval-companion/` (iOS deltas over the accepted web contract).
- Later stages: public-authenticated web Audit Dashboard, installable mobile web client, Auth0 identity (stage 2), native iOS Approval Companion.

## Capabilities and Constraints

- The dashboard is always display-only and read-only; Principal actions flow only through the authenticated control plane, never the dashboard rendering itself as an order path.
- Paper and Live records are never commingled, even when shown together; every display must carry its Execution Environment.
- The system is a Rust backend (`backend/`) plus a Next.js 16 / React 19 frontend (`frontend/`), PostgreSQL persistence, Docker Compose locally.
- Anti-conflation rules from `CONTEXT.md` bind UI labels: no "dashboard" language that implies control authority, no Paper P&L presented as evidence of profit, no strategy output presented as an executable order.
- Deliberately undecided: timing and design of public-authenticated deployment, the iOS Approval Companion build, and any design beyond the accepted Command Ledger interaction contract.

## Evidence on Hand

- `CONTEXT.md`: full domain glossary and model (authoritative).
- `docs/research/`: staged-validation rollout, stage-1 work units (WU-45/46 define dashboard acceptance), tax-lot and CPA reporting requirements, sentiment-source licensing policy, storage/feasibility studies.
- `prototype/audit-dashboard-transparency/`: three working dashboard variants with accessibility and error-prevention acceptance criteria.
- `prototype/native-approval-companion/`: native iOS deltas over the accepted web interaction contract.
- `.scratch/evidence/wu-46-final/`: captured HTML of the implemented Stage-1 surfaces.
- Absences that must never be fabricated: no testimonials, no third-party customers, no performance claims, no press. Any numbers shown must come from the system's own preserved evidence.

## Product Principles

1. Authority is explicit and earned: every surface states what it can and cannot do, and never implies a power it lacks.
2. Evidence over assertion: show source, lineage, timing, version, and confidence; a claim without preserved evidence is not shown as a claim.
3. Fail closed: missing, stale, tampered, or untrusted evidence is visibly distrusted, never smoothed over.
4. One expert user, not a market: optimize for the Principal's trust, auditability, and low approval fatigue rather than broad appeal.
5. Environments never mix: Paper and Live are distinct at every layer of every view.

## Accessibility & Inclusion

WCAG 2.2 Level AA is the required floor for all UI work, together with the repo's existing accessibility and error-prevention acceptance criteria for authority-sensitive states (proposals, alerts, emergency controls).
