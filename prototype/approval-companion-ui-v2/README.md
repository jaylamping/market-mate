# Approval Companion UI v2 — Prototype (throwaway)

Three structurally different, **proposal-centric** UI takes for the native iOS Approval Companion, switchable via `?variant=`, on the disposable `/prototype/approval-companion-ui-v2/` route.

Designed from the locked architecture contract in [#51](https://github.com/jaylamping/market-mate/issues/51) (resolution comment 5457607795). The v1 three-variant prototype at `/prototype/native-approval-companion/` is **superseded for structure** (ceremony-as-spine / sanctuary-as-spine / inbox-as-spine were rejected); v1 remains the asset that pinned distribution facts and activation gates.

## Run

From repository root:

```bash
python3 -m http.server 4174
```

Open [http://localhost:4174/prototype/approval-companion-ui-v2/?variant=A](http://localhost:4174/prototype/approval-companion-ui-v2/?variant=A)

- `A` — Focus Stack: one decision on screen at a time; everything else collapsed to a count; designed empty state
- `B` — Morning Brief: single editorial page by reading order (needs you → watching → recently recorded)
- `C` — Console Tabs: permanent iOS tab bar — Approvals / Status / Alerts / Trust, everything has a home

Floating arrows or keyboard ←/→ switch variants. The **SIM** pill (top-right) drives scenarios: degrade push, clear queue (empty state), escalate Risk State.

## Contract fidelity (all variants)

- System-truth header carried over verbatim from the accepted web contract (#18): environment, Risk State, authority, gates 4/4, one-device binding, sync status. Tap it for the trust sheet.
- Approval Signing Ceremony is a **modal moment**, never the spine: fetch fresh → Face ID → sign one-time nonce → server verify → Decision Record.
- Full emergency from phone: shield FAB → signed Freeze/Halt requests (exact-target confirmation + ceremony); device never owns Risk State.
- Activation gates and device binding are visible states, not plumbing.
- Push degradation, pull fallback, web-authoritative recovery surfaced honestly (SIM → degrade push).

## Non-goals

No persistence, no broker credentials, no order authority, no real signing. Simulated state only.