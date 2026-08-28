# Native Approval Companion — Prototype (throwaway)

Three structurally different native-iOS delta explorations, switchable via `?variant=`, on the disposable `/prototype/native-approval-companion/` route.

This prototype owns **only native iOS deltas** above the accepted responsive Home Screen web contract. The web prototype at `/prototype/audit-dashboard-transparency/` remains authoritative for the shared proposal/alert/emergency interaction contract. This companion never owns canonical strategy, risk, ledger, execution, or authorization state.

## Run

From repository root:

```bash
python3 -m http.server 4174
```

Open [http://localhost:4174/prototype/native-approval-companion/?variant=A](http://localhost:4174/prototype/native-approval-companion/?variant=A)

- `A` — Ceremony Ledger: per-proposal Face ID/Secure Enclave signing ceremony
- `B` — Device Sanctuary: binding, trust, loss, biometric-change, and reinstall
- `C` — Resilient Inbox: APNs, universal links, and degraded notification handling

Use floating arrows or keyboard ←/→ to switch. Arrow keys are ignored while typing in inputs.

## Question

What concrete native-iOS flows provide safe Principal visibility and approvals — distribution, device binding & attestation, Secure Enclave/Face ID proposal signing, APNs & universal links, compromised/lost-device & reinstall recovery, biometric-change behavior, degraded handling, and activation gates — without duplicating server-side authority?

## Non-goals

No persistence, no broker credentials, no order authority, no real signing. Simulated state only. Distribution assumes paid Apple Developer Program; free sideload/JIT chains are explicitly rejected per `docs/research/ios-zero-fee-sideloading-chain-security-assessment.md`.
