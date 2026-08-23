# Audit Dashboard Transparency Prototype

Three structurally different Principal-facing audit dashboard variants, switchable through `?variant=`, on the disposable `/prototype/audit-dashboard-transparency/` route.

This is a read-only interaction prototype. It uses simulated in-memory state, performs no persistence, authentication, brokerage action, approval, or authority change, and intentionally lives outside the production architecture.

## Run

From the repository root:

```bash
python3 -m http.server 4174
```

Open [http://localhost:4174/prototype/audit-dashboard-transparency/?variant=A](http://localhost:4174/prototype/audit-dashboard-transparency/?variant=A).

- `A` — Command Ledger: functional left-rail views ordered Home/Dashboard, Live Trading, Paper Trading, Incubator, Decision Records, Research, proposals, blocked work, and alerts
- `B` — Principal Brief: mobile-first decisions and system truth
- `C` — Twin Environments: read-only Paper/Live comparison

Use the floating arrows or keyboard left/right arrows to switch variants. Use the environment controls, Decision Record rows, proposal-review buttons, alert acknowledgement, and emergency controls to inspect simulated states. Arrow-key switching does not intercept keys while an input, textarea, select, or editable control has focus.

## Question

Which information hierarchy best lets the Principal distinguish Paper from Live, understand economic and authority state, inspect exact evidence, and safely act on proposals, alerts, and emergency controls without hiding uncertainty or reporting optimistic success?
