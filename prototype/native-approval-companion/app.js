// Throwaway prototype: native iOS Approval Companion deltas.
// ?variant=A — Ceremony Ledger | B — Device Sanctuary | C — Resilient Inbox
// Simulated state only. No persistence, credentials, or authority.

const state = {
  asOf: "23 AUG 2026 · 09:47 CT",
  webPrototype: "/prototype/audit-dashboard-transparency/?variant=A",
  distribution: {
    decision: "Paid Apple Developer Program required for Live authority",
    path: "TestFlight private beta → later private distribution · App Attest + Associated Domains + APNs",
    rejected: "SideStore / StikDebug / LiveContainer / LocalDevVPN / 7-day Personal Team — PROHIBITED for Live (see ios-zero-fee-sideloading-chain-security-assessment.md)",
    builds: [
      { label: "Paper prototype", channel: "Direct Xcode Personal Team", authority: "PAPER + read-only ONLY", expiry: "7-day profile · reinstall required", banner: "PAPER — NO LIVE AUTHORITY" },
      { label: "Live companion", channel: "Paid Developer Program · TestFlight", authority: "Proposal approval only · no broker credential", expiry: "Managed renewal · App Attest required", banner: "LIVE proposal approval · server-authoritative" },
    ],
  },
  gates: [
    { id: "G1", label: "Paid program & entitlements", state: "SATISFIED", detail: "APNs, Associated Domains, App Attest proven in build" },
    { id: "G2", label: "Device binding + attestation", state: "SATISFIED", detail: "Secure Enclave key · App Attest challenge · 09:12 CT" },
    { id: "G3", label: "Current iOS + security patch", state: "SATISFIED", detail: "iOS 26.4 · security content verified" },
    { id: "G4", label: "Fresh passkey + proposal signature", state: "REQUIRED PER APPROVAL", detail: "No blanket authority · one-time challenge" },
  ],
  proposals: [
    {
      id: "PI-204", root: "ROOT-PRINCIPAL-077", env: "LIVE", type: "LIVE AUTHORITY",
      title: "Promote SV-031.8 to $250 exposure ceiling",
      scope: "SV-031.8 · LIVE-ALPHA-01 · one account",
      evidence: "PB-031.8 · 90 Paper days · parity PC-09",
      challenge: "c7f3…9a12 · PI-204 · 09:46:31Z · $250 · Sentinel v41 · nonce 88319",
      expiry: "Expires 24 AUG 16:00 CT · 6h 12m remaining",
      cooling: "17h 42m cooling-off complete",
      maxLoss: "$18 modeled incremental",
      status: "READY FOR REVIEW", tone: "danger",
      children: ["Broker certification BC-14 · satisfied", "Tax evidence TE-08 · satisfied", "Principal Live grant · pending"],
    },
    {
      id: "PI-205", root: "ROOT-PRINCIPAL-078", env: "PAPER", type: "PROVIDER COST",
      title: "Add certified OPRA history tier",
      scope: "Research + Paper data entitlement",
      evidence: "Cost case CC-071 · source SC-19",
      challenge: "a01e…44b8 · PI-205 · 60-day $64/mo · SC-19",
      expiry: "Expires in 2d 06h",
      cooling: "No cooling-off required",
      maxLoss: "No Live exposure",
      status: "BUNDLED REVIEW", tone: "info",
      children: ["Entitlement review · satisfied", "Deletion contract · satisfied", "Cost expansion · pending"],
    },
    {
      id: "PI-198", root: "ROOT-PRINCIPAL-071", env: "LIVE", type: "RESUME LIVE",
      title: "Resume after reconciliation incident",
      scope: "All Live risk-increasing activity",
      evidence: "INC-104 · bundle incomplete",
      challenge: "expired · superseded 09:46:31 CT",
      expiry: "SUPERSEDED", cooling: "N/A",
      maxLoss: "—",
      status: "SUPERSEDED — CANNOT ACT", tone: "muted",
      children: ["Ledger reconciliation · stale", "Broker certainty · failed", "Resume authority · superseded"],
    },
  ],
  devices: [
    { id: "DEV-IP15-01", model: "iPhone 15 · iOS 26.4", enrolled: "14 AUG 2026", key: "Secure Enclave P-256 · LA .biometryCurrentSet", attest: "App Attest · counter 41", state: "BOUND · CURRENT BIOMETRIC", last: "09:47:02 · APNs token current" },
    { id: "DEV-IP13-ARCH", model: "iPhone 13 · iOS 26.4 (archived)", enrolled: "02 JUL 2026", key: "REVOKED 19 AUG", attest: "Revoked", state: "REVOKED · LOST DEVICE 19 AUG", last: "Revocation receipt 19 AUG 22:14" },
  ],
  scenarios: [
    { id: "lost", title: "Lost / compromised device", trigger: "Principal reports loss in web app or broker runbook", effect: "Server revokes device key + session · APNs token invalidated · proposals remain server-pending", recovery: "Browser (passkey) remains authoritative · new device re-enrolls via fresh WebAuthn + App Attest · old signatures rejected by counter" },
    { id: "biometric", title: "Face ID re-enrollment / appearance change", trigger: "iOS biometric set changes", effect: "Secure Enclave key with .biometryCurrentSet invalidates automatically · signing fails closed", recovery: "Re-create proposal key after fresh passkey step-up · server requires new attestation · no silent fallback to passcode-only" },
    { id: "reinstall", title: "App reinstall / phone replacement", trigger: "App deleted or new phone", effect: "Keychain + Enclave key absent · App Attest key absent · app shows UNBOUND", recovery: "Re-enroll: passkey login → App Attest challenge → new Enclave key → server binds new device ID · old device marked superseded" },
    { id: "osupdate", title: "iOS update / jailbreak signal", trigger: "OS version change or integrity signal", effect: "Device marked RE-CERTIFY · Live approvals fenced until check passes", recovery: "Automated integrity + version gate · server re-validates entitlements (get-task-allow=false) · Principal notified" },
  ],
  notifications: [
    { channel: "APNs", label: "Native push", status: "PRIMARY", latency: "p95 4.2s", note: "aps-environment production · token per device", fallback: "If APNs fails: Web Push + Slack + SMS fire independently" },
    { channel: "Web Push", label: "Home Screen web app", status: "REDUNDANT", latency: "p95 8.1s", note: "Safari 16.4+ Home Screen · no Developer Program needed", fallback: "Shares same proposal challenge · same expiry" },
    { channel: "Slack", label: "Slack DM", status: "REDUNDANT", latency: "p95 6.4s", note: "No secret in message · link is universal, not bearer", fallback: "Link requires auth; copy is useless without session" },
    { channel: "SMS", label: "SMS fallback", status: "REDUNDANT", latency: "p95 9.8s", note: "Last fallback · no actionable secret", fallback: "Same expiry + replay protection" },
  ],
  universalLinks: {
    good: "https://app.marketmate.example.com/proposal/PI-204?c=c7f3...9a12  →  opens installed companion via Associated Domains (applinks) → exact challenge re-fetched from server",
    copied: "Copied URL pasted in another browser → server requires fresh passkey assertion → stale/modified/expired challenge fails closed",
    expired: "Expired challenge → server returns 410 + reason · companion shows EXPIRED · no approval possible",
  },
  degraded: [
    { id: "D1", title: "APNs outage (15m)", state: "DEGRADED — APNs 0/3 delivered", impact: "Proposals still reachable via Web Push + Slack + SMS; companion inbox still authoritative on open", action: "Retry APNs with backoff; do not claim delivery; Principal checks web inbox" },
    { id: "D2", title: "Device offline / backgrounded", state: "PENDING — device has not fetched", impact: "Server holds proposal; expiry still ticks; no optimistic success", action: "Foreground fetch on open; Slack/SMS remain; offline does not extend expiry" },
    { id: "D3", title: "Stale price / policy version", state: "REJECTED — server re-evaluation failed", impact: "Server rejects even a valid Face ID signature if quote or Sentinel policy moved", action: "Show REJECTED with reason; require new proposal; never silently approve prior economics" },
    { id: "D4", title: "Replay / concurrent approval", state: "REJECTED — one-time challenge consumed", impact: "Second tap or replayed assertion is rejected; exactly one approval ever counts", action: "Idempotent result; show immutable approval record" },
  ],
  ceremony: {
    proposalId: "PI-204",
    steps: [
      { id: "s1", label: "Fetch exact proposal + challenge", status: "done", detail: "GET /proposals/PI-204 · challenge c7f3…9a12 · expiry 24 AUG 16:00" },
      { id: "s2", label: "Fresh passkey assertion (userVerification=required)", status: "pending", detail: "Safari/WebAuthn or native passkey · bound to relying party + challenge" },
      { id: "s3", label: "Face ID → Secure Enclave sign(challenge)", status: "pending", detail: "P-256 · .biometryCurrentSet · assertion counter increments" },
      { id: "s4", label: "POST /approvals {assertion, signature, counter} → server re-evaluates", status: "pending", detail: "Re-checks expiry, policy, quote, custody, idempotency → then mutates authority" },
    ],
  },
};

let selectedProposal = state.proposals[0].id;
let ceremonyState = "idle"; // idle | passkey | faceid | submitting | success | fail
let ceremonyFailReason = null;
let selectedDeviceScenario = "lost";
let selectedDegraded = "D1";

const variants = [
  { key: "A", name: "Ceremony Ledger", render: VariantA },
  { key: "B", name: "Device Sanctuary", render: VariantB },
  { key: "C", name: "Resilient Inbox", render: VariantC },
];

function currentVariant() {
  const raw = new URLSearchParams(location.search).get("variant");
  const found = variants.find(v => v.key === raw);
  return found || variants[0];
}
function setVariant(key) {
  const url = new URL(location.href);
  url.searchParams.set("variant", key);
  history.replaceState(null, "", url.toString());
  render();
}
function envLabel(env) {
  const cls = env.includes("LIVE") ? "env-live" : env.includes("PAPER") ? "env-paper" : "env-research";
  return `<span class="env-label ${cls}">${env}</span>`;
}
function pill(label, tone="neutral"){ return `<span class="status-pill tone-${tone}">${label}</span>`; }

function shellShell(children){
  return `
  <div class="shell">
    <div class="shell-header">
      <a class="brand" href="?variant=${currentVariant().key}"><span class="brand-mark">MM</span><span>MARKET MATE<small>NATIVE COMPANION — THROWAWAY</small></span></a>
      <div class="header-meta">
        <small>${state.asOf} · ${currentVariant().key} — ${currentVariant().name}</small>
        <a class="web-anchor" href="${state.webPrototype}">↗ Web prototype (authoritative contract)</a>
      </div>
    </div>
    <div class="distribution-strip">
      <div>
        <strong>${state.distribution.decision}</strong>
        <p>${state.distribution.path} · <b>Entitlements verified:</b> Associated Domains (applinks + webcredentials) · APNs (aps-environment) · App Attest · <code>get-task-allow=false</code></p>
        <p style="margin-top:6px; color:#a59c90;">Rejected for Live: ${state.distribution.rejected}</p>
      </div>
      <div style="display:grid; gap:6px;">
        ${state.distribution.builds.map(b=>`<div class="mini-card" style="min-width:240px;"><h4>${b.label} · ${pill(b.authority.includes("PAPER")?"paper only":"live approval", b.authority.includes("PAPER")?"neutral":"danger")}</h4><p>${b.channel} · ${b.expiry}</p><p><b>${b.banner}</b></p></div>`).join("")}
      </div>
    </div>
    <div class="truth-strip">
      ${envLabel("LIVE")} <b>Companion never owns canonical state.</b>  Strategy · Risk · Ledger · Execution · Authorization remain server-side in Sentinel/Engine/Gateway. The app only authenticates and signs an exact one-time proposal challenge.
      <span style="margin-left:auto; color:#7f8d82;">Deep links are universal links, not bearer tokens — copied URLs require auth + fresh assertion.</span>
    </div>
    <div class="activation-gates">
      ${state.gates.map(g=>`<article><span>${g.id} · ${g.state}</span><strong>${g.label}</strong><small>${g.detail}</small></article>`).join("")}
    </div>
    <div class="variant-wrap" id="prototype-main" tabindex="-1">
      ${children}
    </div>
  </div>`;
}

function proposalCard(p){
  const isLive = p.env==="LIVE";
  const selected = p.id===selectedProposal;
  return `
  <article class="proposal-card ${isLive?"is-live":"is-paper"}" style="${selected?"outline:1px solid var(--acid);":""}">
    <header>${envLabel(p.env)}<span style="font-size:7px; letter-spacing:.08em; opacity:.55;">${p.type} · ${p.status}</span></header>
    <h3>${p.title}</h3>
    <p>${p.scope} · ${p.evidence}</p>
    <dl class="proposal-meta">
      <div><dt>Proposal</dt><dd><b>${p.id}</b> · root ${p.root} · Challenge <code>${p.challenge}</code></dd></div>
      <div><dt>Expiry</dt><dd>${p.expiry} · ${p.cooling} · Max incremental loss ${p.maxLoss}</dd></div>
      <div><dt>Exact change</dt><dd>${p.id==="PI-204"?"Enables new Live exposure up to $250 under existing Sentinel policy (no policy weakening).":"No Live write authority — entitlement only."}</dd></div>
      <div><dt>Children</dt><dd>${p.children.join(" · ")}</dd></div>
    </dl>
    <div class="ceremony-steps">
      ${p.status.includes("SUPERSEDED")? pill("SUPERSEDED — immutable", "danger") : p.status.includes("READY")? '<span class="step done">Proposal fetched</span><span class="step pending">Fresh auth + Enclave</span><span class="step pending">Server re-eval</span>' : '<span class="step done">Bundle ready</span><span class="step pending">Sign</span>'}
    </div>
    ${p.status.includes("SUPERSEDED")? `<div class="rejected-note">Server-authoritative result: superseded at 09:46:31 CT by new containment intent. No approval possible — even a valid biometric signature is rejected.</div>`:""}
    <div class="card-actions">
      <button type="button" class="btn ${selected?"btn-primary":"btn-ghost"}" data-select-proposal="${p.id}">${selected?"Selected":"Select"}</button>
      ${p.status.includes("SUPERSEDED")? `<button type="button" class="btn btn-ghost" data-toast="Superseded proposals have no approval control — inspect the immutable result in the web prototype.">Inspect immutable result</button>` : `<button type="button" class="btn btn-ghost" data-open-ceremony="${p.id}">Review &amp; sign (simulated)</button>`}
    </div>
  </article>`;
}

function phonePreview(){
  const proposal = state.proposals.find(p=>p.id===state.ceremony.proposalId) || state.proposals[0];
  const steps = state.ceremony.steps;
  const stepTone = (s)=>{
    if(ceremonyState==="idle") return s.id==="s1"?"done":"pending";
    if(ceremonyState==="passkey") return s.id==="s1"?"done":s.id==="s2"?"pending":"pending";
    if(ceremonyState==="faceid") return s.id==="s1"?"done":s.id==="s2"?"done":s.id==="s3"?"pending":"pending";
    if(ceremonyState==="submitting") return s.id==="s4"?"pending":"done";
    if(ceremonyState==="success") return "done";
    if(ceremonyState==="fail") return s.id==="s4"?"blocked":"done";
    return "pending";
  };
  return `
  <div class="phone ceremony-phone">
    <div class="phone-notch"></div>
    <div class="phone-screen">
      <div class="phone-topbar"><span>09:47</span><b>MARKET MATE</b><span>◼︎ 87%</span></div>
      <div style="padding:10px; display:grid; gap:8px;">
        <div class="mini-card" style="border-left:3px solid ${proposal.env==="LIVE"?"var(--red)":"var(--paper-env)"};">
          <h4>${envLabel(proposal.env)} ${proposal.title}</h4>
          <p>${proposal.id} · ${proposal.scope}</p>
          <p style="font-family:ui-monospace,monospace; font-size:7px; word-break:break-all; margin-top:6px;">Challenge: ${proposal.challenge}</p>
          <p style="margin-top:6px;">Expiry: ${proposal.expiry}</p>
        </div>
        <div class="mini-card">
          <h4>Signing ceremony</h4>
          <div style="display:grid; gap:6px; margin-top:8px;">
            ${steps.map(s=>{
              const tone = stepTone(s);
              return `<div style="display:grid; grid-template-columns:18px 1fr; gap:8px; padding:8px; border:1px solid ${tone==="done"?"rgba(155,220,66,.35)":tone==="blocked"?"rgba(255,98,89,.45)":"#1f2926"}; background:${tone==="done"?"rgba(155,220,66,.06)":tone==="blocked"?"rgba(255,98,89,.06)":"#0a0f0e"};">
                <span style="width:14px; height:14px; border-radius:50%; display:grid; place-items:center; font-size:9px; background:${tone==="done"?"#9bdc42":tone==="blocked"?"var(--red)":tone==="pending"?"var(--amber)":"#1f2926"}; color:${tone==="pending"?"#111":"#fff"};">${tone==="done"?"✓":tone==="blocked"?"✕":"•"}</span>
                <span><b style="font-size:8px;">${s.label}</b><br><small style="color:#8e9a90; font-size:7px;">${s.detail}</small></span>
              </div>`;
            }).join("")}
          </div>
          ${ceremonyState==="fail"? `<div class="rejected-note" style="margin-top:8px;">✕ ${ceremonyFailReason}</div>` : ""}
          ${ceremonyState==="success"? `<div style="margin-top:8px; padding:8px; border:1px solid rgba(155,220,66,.4); background: rgba(155,220,66,.08); font-size:8px;">✓ Server confirmed. Approval is immutable. Counter incremented. Duplicate replay would be rejected.</div>` : ""}
        </div>
        <div class="face-id mini-card">
          <div class="ring">◉</div>
          <strong>${ceremonyState==="faceid"?"Face ID — look at iPhone":ceremonyState==="passkey"?"Passkey assertion…":ceremonyState==="submitting"?"Signing with Secure Enclave…":ceremonyState==="success"?"Signed &amp; attested":"Ready to approve"}</strong>
          <p>${ceremonyState==="faceid" ? "User verification required · .biometryCurrentSet · key is nonexportable" : ceremonyState==="passkey" ? "WebAuthn userVerification=required · bound to relying party + exact challenge" : ceremonyState==="submitting" ? "P-256 signature over one-time challenge + App Attest counter" : "Fresh assertion + Enclave signature + server re-evaluation — never blanket authority."}</p>
          <div class="mono">App Attest counter: 42 → 43 · get-task-allow=false</div>
          <div style="display:flex; gap:6px; margin-top:10px; justify-content:center;">
            <button type="button" class="btn btn-primary" data-ceremony-step style="min-width:140px;">${ceremonyState==="idle"?"Begin ceremony":ceremonyState==="passkey"?"Simulate Face ID":ceremonyState==="faceid"?"Sign with Enclave":ceremonyState==="submitting"?"Submitting…":ceremonyState==="success"?"Done — reset":ceremonyState==="fail"?"Retry":"Continue"}</button>
            <button type="button" class="btn btn-ghost" data-ceremony-reset>Reset</button>
          </div>
          <p style="margin-top:8px; font-size:7px; color:#6d796f;">Try failures: <a href="#" data-fail="expired" style="color:var(--cyan);">expired</a> · <a href="#" data-fail="modified" style="color:var(--cyan);">modified</a> · <a href="#" data-fail="replay" style="color:var(--cyan);">replay</a> · <a href="#" data-fail="revoked" style="color:var(--cyan);">revoked</a></p>
        </div>
      </div>
    </div>
  </div>`;
}

function VariantA(){
  return shellShell(`
    <div style="display:flex; align-items:baseline; justify-content:space-between; gap:12px; margin-bottom:10px;">
      <div><span class="eyebrow">Variant A — Ceremony Ledger</span><h1 style="margin-top:4px; font-size:24px; letter-spacing:-.03em;">Every approval is a fresh Face ID + Enclave signature over an exact challenge.</h1><p style="margin-top:6px; color:#9aa69c; font-size:9px; max-width:760px; line-height:1.5;">No blanket authority. The companion fetches the exact proposal, requires a fresh passkey assertion, performs Face ID-gated Secure Enclave signing, then posts the assertion + signature + App Attest counter for server-side re-evaluation. The phone never decides — the server does, and may still reject.</p></div>
      <small style="color:#7f8d82; font-size:7px; white-space:nowrap;">Tap “Review & sign” to drive the simulated ceremony. Phone on the right mirrors the device sheet.</small>
    </div>
    <div class="ceremony-grid">
      <div class="ceremony-ledger">
        ${state.proposals.map(proposalCard).join("")}
        <div class="mini-card" style="border-color: rgba(200,255,69,.25);">
          <h4>What the signature binds</h4>
          <p>Proposal ID + instrument/legs + quantity + limit price + max loss + expiry + Sentinel policy version + one-time nonce. A signature over “approve PI-204” without those fields is not valid.</p>
          <div class="challenge-box">sign( P-256 Enclave key · challenge=${state.proposals.find(p=>p.id===selectedProposal)?.challenge} · counter=43 ) — server verifies: challenge freshness, policy version, quote age, custody, idempotency, and that counter > last seen.</div>
          <p style="margin-top:8px; color:#7f8d82; font-size:7px;">Entitlements in shipped build: <code>aps-environment=production</code> · <code>com.apple.developer.associated-domains=applinks:app.marketmate.example.com, webcredentials:app.marketmate.example.com</code> · <code>com.apple.developer.devicecheck.appattest-environment=production</code> · <code>get-task-allow=false</code></p>
        </div>
      </div>
      ${phonePreview()}
    </div>
  `);
}

function VariantB(){
  const scenario = state.scenarios.find(s=>s.id===selectedDeviceScenario);
  return shellShell(`
    <div style="display:flex; align-items:baseline; justify-content:space-between; gap:12px; margin-bottom:10px;">
      <div><span class="eyebrow">Variant B — Device Sanctuary</span><h1 style="margin-top:4px; font-size:24px; letter-spacing:-.03em;">Devices are bound, attestable, and individually revocable. The server is the source of truth.</h1><p style="margin-top:6px; color:#9aa69c; font-size:9px; max-width:760px; line-height:1.5;">Each device generates its own nonexportable Enclave key (kSecAttrTokenIDSecureEnclave + .biometryCurrentSet). The app proves build integrity with App Attest. Loss, biometric change, reinstall, OS update, and jailbreak each have a rehearsed fail-closed path. The browser (passkey) is always a recovery rail.</p></div>
      <small style="color:#7f8d82; font-size:7px;">Pick a scenario below to inspect the timeline + phone state.</small>
    </div>
    <div class="sanctuary-grid">
      ${state.devices.map(d=>`
        <div class="device-card" style="${d.state.includes("REVOKED")?"border-color: rgba(255,98,89,.45); background: rgba(255,98,89,.04);":""}">
          <h3>${d.id} — ${d.model}</h3>
          <p style="margin-top:4px; font-size:8px;">${pill(d.state.includes("BOUND")?"BOUND":"REVOKED", d.state.includes("BOUND")?"good":"danger")} <span style="font-size:7px; color:#7f8d82;">Enrolled ${d.enrolled}</span></p>
          <dl class="kv">
            <div><dt>Enclave key</dt><dd>${d.key}</dd></div>
            <div><dt>App Attest</dt><dd>${d.attest}</dd></div>
            <div><dt>Last activity</dt><dd>${d.last}</dd></div>
          </dl>
          <div class="device-actions">
            ${d.state.includes("BOUND")? `<button type="button" class="btn btn-ghost" data-toast="Revocation is server-side and immediate — device key + session + APNs token invalidated.">Simulate revoke</button><button type="button" class="btn btn-ghost" data-toast="Biometric re-enrollment invalidates any .biometryCurrentSet Enclave key — signing fails closed until re-enrollment.">Simulate biometric change</button>` : `<span class="badge" style="color:var(--red); border-color: var(--red);">No approvals possible</span>`}
          </div>
        </div>
      `).join("")}
    </div>
    <div style="display:grid; grid-template-columns: 360px 1fr; gap:12px; margin-top:12px;">
      <div class="phone">
        <div class="phone-notch"></div>
        <div class="phone-screen">
          <div class="phone-topbar"><span>09:47</span><b>MARKET MATE</b><span>◼︎</span></div>
          <div style="padding:12px; display:grid; gap:10px;">
            ${selectedDeviceScenario==="lost"? `
              <div class="mini-card" style="border-color: rgba(255,98,89,.4); background: rgba(255,98,89,.06);"><h4>Device revoked</h4><p>This device can no longer approve. Use your browser or another bound device. Proposals remain pending on the server.</p>
              <div style="display:flex; gap:6px; margin-top:8px;"><span class="badge" style="color:var(--red);">REVOKED 19 AUG</span><span class="badge" style="color:#9aa59c;">Browser recovery available</span></div></div>
              <div class="mini-card"><h4>What still works</h4><p>Web app (passkey) · other bound device · broker-native runbook. No proposal was auto-approved.</p></div>
            `: selectedDeviceScenario==="biometric"? `
              <div class="mini-card" style="border-color: rgba(255,186,92,.45); background: rgba(255,186,92,.06);"><h4>Biometric changed</h4><p>Face ID set changed — Enclave key with .biometryCurrentSet is now invalid. Signing fails closed.</p>
              <div style="margin-top:8px; padding:8px; border:1px dashed #2b352e; background:#0a0f0e; font-size:7px; font-family:ui-monospace,monospace;">SecAccessControl .biometryCurrentSet → SecItemCopyMatching returns errSecAuthFailed (-25293). Key must be regenerated.</div></div>
              <div class="mini-card"><h4>Recovery</h4><p>Fresh passkey step-up → generate new Enclave key → new App Attest attestation → server binds new key. Old signatures rejected by counter.</p></div>
            `: selectedDeviceScenario==="reinstall"? `
              <div class="mini-card"><h4>App reinstalled</h4><p>Keychain + Enclave key absent. App shows <b>UNBOUND</b>. No cached proposal can be approved.</p>
              <div style="margin-top:8px; padding:8px; border:1px solid #1f2926; background:#0a0f0e; font-size:8px;">State: UNBOUND — tap “Bind this device” to re-enroll.</div></div>
              <button type="button" class="btn btn-primary" style="width:100%;" data-toast="Re-enrollment: passkey → App Attest challenge → Enclave key → server binding.">Bind this device (simulated)</button>
            `: `
              <div class="mini-card" style="border-color: rgba(255,186,92,.45);"><h4>iOS updated / integrity signal</h4><p>Device flagged RE-CERTIFY. Live approvals fenced until version + integrity gates pass.</p>
              <div style="margin-top:8px; padding:8px; border-left:3px solid var(--amber); background: rgba(255,186,92,.06); font-size:8px;">Gate: current iOS + get-task-allow=false + App Attest still valid. Auto-check runs on app foreground.</div></div>
              <div class="mini-card"><h4>Still safe while fenced</h4><p>Research + Paper continue. Existing containment holds. Web approvals still work if they pass the same gates.</p></div>
            `}
          </div>
        </div>
      </div>
      <div>
        <div style="display:flex; gap:6px; flex-wrap:wrap;">
          ${state.scenarios.map(s=>`<button type="button" class="btn ${s.id===selectedDeviceScenario?"btn-primary":"btn-ghost"}" data-scenario="${s.id}">${s.title}</button>`).join("")}
        </div>
        <div class="timeline">
          <article><span class="dot"></span><div><strong style="font-size:11px;">Enrollment (once per device)</strong><p style="margin-top:4px; color:#8e9a90; font-size:8px; line-height:1.5;">Paid build installed via TestFlight → App Attest attestation → Secure Enclave key generation (biometryCurrentSet) → server binds deviceId + public key + App Attest keyId. Private key never leaves Enclave. 1Password/hardware-key recovery is via browser passkey, not the Enclave key — Enclave keys are not backup-restorable.</p></div></article>
          <article><span class="dot ${scenario.id==="biometric"?"warn":scenario.id==="lost"?"bad":""}"></span><div><strong style="font-size:11px;">${scenario.title}</strong><p style="margin-top:4px; color:#8e9a90; font-size:8px; line-height:1.5;"><b style="color:#e8eee9;">Trigger:</b> ${scenario.trigger}<br><b style="color:#e8eee9;">Effect:</b> ${scenario.effect}<br><b style="color:#e8eee9;">Recovery:</b> ${scenario.recovery}</p></div></article>
          <article><span class="dot"></span><div><strong style="font-size:11px;">Browser remains the recovery rail</strong><p style="margin-top:4px; color:#8e9a90; font-size:8px; line-height:1.5;">Web app uses Safari passkey (Face ID) + Web Push. Native loss never blocks emergency Freeze — Freeze is also available via broker-native runbook BR-02. Revocation propagates to all Gateway sessions in &lt; 60s.</p></div></article>
        </div>
        <div class="policy-strip">
          <article><strong>Key custody</strong><p>Nonexportable Enclave key. kSecAttrAccessControl with .biometryCurrentSet. No export, no cloud backup, no passcode fallback.</p></article>
          <article><strong>Attestation</strong><p>App Attest is a risk signal, not proof of uncompromised OS (Apple). Server validates challenge, keyId, counter, and bundle. Free builds lack it.</p></article>
          <article><strong>Revocation</strong><p>One tap in web app or API call revokes device. APNs token + session + key binding all invalidated. New device needs fresh ceremony.</p></article>
        </div>
      </div>
    </div>
  `);
}

function VariantC(){
  return shellShell(`
    <div style="display:flex; align-items:baseline; justify-content:space-between; gap:12px; margin-bottom:10px;">
      <div><span class="eyebrow">Variant C — Resilient Inbox</span><h1 style="margin-top:4px; font-size:24px; letter-spacing:-.03em;">APNs is primary. Nothing depends on a single notification channel.</h1><p style="margin-top:6px; color:#9aa69c; font-size:9px; max-width:760px; line-height:1.5;">A proposal is notified over four independent rails (APNs + Web Push + Slack + SMS) and deep-linked via Associated Domains universal links. The link is not a bearer token — it only navigates. Every open re-fetches the exact challenge from the server. If any rail fails, the inbox is still authoritative on open.</p></div>
      <small style="color:#7f8d82; font-size:7px;">Tap a notification card to inspect its payload + routing. Toggle degraded cards to see fail-closed behavior.</small>
    </div>
    <div class="inbox-grid">
      <div>
        <div class="section-title"><div><span>NOTIFICATION RAILS</span><h2>Four rails, one proposal</h2></div><b>All carry no secret</b></div>
        <table class="channel-table">
          <thead><tr><th>Channel</th><th>Role</th><th>Latency</th><th>What’s in the message</th></tr></thead>
          <tbody>
            ${state.notifications.map(n=>`<tr><td><b>${n.channel}</b><br><small style="color:#7f8d82;">${n.label}</small></td><td>${pill(n.status, n.status==="PRIMARY"?"info":"neutral")}</td><td>${n.latency}</td><td>${n.note}<br><small style="color:#7f8d82;">${n.fallback}</small></td></tr>`).join("")}
          </tbody>
        </table>
        <div class="channel-cards">
          ${[
            { icon:"🍎", title:"APNs — PI-204 ready for review", meta:"09:46:33 · aps-environment production", body:"Market Mate: PI-204 — Promote SV-031.8 to $250 (LIVE). Tap to review.", badge:"APNs" },
            { icon:"🌐", title:"Web Push — same proposal", meta:"09:46:35 · Home Screen app", body:"Same challenge · same expiry. Open the Home Screen app if the native app is unavailable.", badge:"Web Push" },
            { icon:"💬", title:"Slack — fallback delivery", meta:"09:46:36 · #ops-private", body:"PI-204 is waiting. Link: app.marketmate.example.com/proposal/PI-204 (auth required).", badge:"Slack" },
            { icon:"💬", title:"SMS — final fallback", meta:"09:46:38 · +1 ••• ••42", body:"Market Mate: PI-204 pending. Expiry 16:00 CT. Link requires login.", badge:"SMS" },
          ].map(c=>`
            <div class="channel-card">
              <div class="channel-icon">${c.icon}</div>
              <div><strong style="font-size:10px;">${c.title}</strong><br><small style="color:#7f8d82; font-size:7px;">${c.meta}</small><p style="margin-top:4px; font-size:8px; color:#9aa69c;">${c.body}</p></div>
              <span class="status-pill tone-info" style="height: fit-content;">${c.badge}</span>
            </div>
          `).join("")}
        </div>
        <div class="deep-link" style="margin-top:10px;">
          <strong>Universal link contract (Associated Domains)</strong><br>
          <span style="color:#9aa69c;">Good open:</span> <code>${state.universalLinks.good}</code><br>
          <span style="color:#9aa69c;">Copied URL:</span> <code>${state.universalLinks.copied}</code><br>
          <span style="color:#9aa69c;">Expired:</span> <code>${state.universalLinks.expired}</code>
          <p style="margin-top:6px; color:#8e9a90;">Links use <code>applinks:app.marketmate.example.com</code> + <code>webcredentials</code> for passkey. Entitlements absent in free Personal Team builds — another reason Live requires paid program.</p>
        </div>
      </div>
      <div>
        <div class="section-title"><div><span>DEGRADED OPERATION</span><h2>Fail-closed, not silent</h2></div><b>Tap to inspect</b></div>
        <div class="degraded-list">
          ${state.degraded.map(d=>`
            <article class="${d.id===selectedDegraded?"bad":d.state.includes("REJECTED")?"bad":d.state.includes("DEGRADED")?"":""}">
              <div style="display:flex; justify-content:space-between; gap:8px;"><strong style="font-size:10px;">${d.title}</strong><span class="badge" style="color:var(--amber);">${d.state.split(" — ")[0]}</span></div>
              <p style="margin-top:6px; color:#8e9a90; font-size:8px;">${d.state}</p>
              <p style="margin-top:6px; font-size:8px;"><b>Impact:</b> ${d.impact}</p>
              <p style="margin-top:4px; font-size:8px;"><b>Handling:</b> ${d.action}</p>
              <button type="button" class="btn btn-ghost" data-degraded="${d.id}" style="margin-top:8px; width:100%;">${d.id===selectedDegraded?"Selected":"Inspect"}</button>
            </article>
          `).join("")}
        </div>
        <div class="phone" style="margin-top:12px; max-width:100%;">
          <div class="phone-notch"></div>
          <div class="phone-screen">
            <div class="phone-topbar"><span>09:47</span><b>INBOX</b><span>◼︎</span></div>
            <div class="phone-list">
              <div class="mini-card" style="border-left:3px solid var(--red);"><h4>${envLabel("LIVE")} PI-204 · Promote SV-031.8</h4><p>Challenge c7f3…9a12 · Expires 16:00 CT · Max loss $18</p><p style="margin-top:6px; display:flex; gap:4px; flex-wrap:wrap;">${pill("APNs ✓","info")} ${pill("Slack ✓","neutral")} ${pill("SMS ✓","neutral")} ${pill("Tap to re-fetch","neutral")}</p></div>
              <div class="mini-card" style="opacity:.6;"><h4>${envLabel("PAPER")} PI-205 · OPRA tier</h4><p>No Live authority · bundled review</p></div>
              <div class="mini-card" style="opacity:.35;"><h4>${envLabel("LIVE")} PI-198 · Resume Live</h4><p>SUPERSEDED — cannot act</p></div>
            </div>
            <div style="padding:10px; border-top:1px solid #1f2926; display:flex; gap:6px;">
              <button type="button" class="btn btn-primary" style="flex:1;" data-toast="Inbox is always server-fetched on open — pull to refresh re-validates every proposal’s expiry + counter.">Pull to refresh (re-fetch)</button>
              <button type="button" class="btn btn-ghost" data-toast="Offline: inbox shows cached proposal + STALE banner. Approval controls are disabled until fresh fetch succeeds.">Go offline (simulated)</button>
            </div>
            <p style="padding:0 10px 10px; color:#6d796f; font-size:7px; line-height:1.4;">Inbox content is never trusted from the push payload. Push only wakes the app; the app fetches the authoritative proposal from Gateway before enabling Face ID.</p>
          </div>
        </div>
      </div>
    </div>
  `);
}

function renderSwitcher(){
  const cur = currentVariant();
  return `
  <div class="prototype-switcher" role="group" aria-label="Variant switcher">
    <button type="button" class="switcher-arrow" aria-label="Previous variant" data-switcher-prev>‹</button>
    <div class="switcher-label"><span>VARIANT ${cur.key} OF ${variants.length}</span><strong>${cur.key} — ${cur.name}</strong></div>
    <button type="button" class="switcher-arrow" aria-label="Next variant" data-switcher-next>›</button>
  </div>`;
}

function renderApp(){
  const cur = currentVariant();
  return cur.render() + renderSwitcher() + `<div class="prototype-toast" id="prototype-toast" role="status" aria-live="polite"></div>`;
}

function render(){
  document.getElementById("app").innerHTML = renderApp();
  document.getElementById("dialog-root").innerHTML = "";
  wire();
}

let toastTimer=null;
function toast(msg){
  const el=document.getElementById("prototype-toast");
  if(!el) return;
  el.textContent=msg; el.classList.add("is-visible");
  clearTimeout(toastTimer);
  toastTimer=setTimeout(()=>el.classList.remove("is-visible"), 2800);
  const live=document.getElementById("prototype-live");
  if(live) live.textContent=msg;
}

function wire(){
  document.querySelectorAll("[data-toast]").forEach(el=>{
    el.addEventListener("click", ()=> toast(el.getAttribute("data-toast")));
  });
  document.querySelectorAll("[data-select-proposal]").forEach(el=>{
    el.addEventListener("click", ()=>{
      selectedProposal = el.getAttribute("data-select-proposal");
      state.ceremony.proposalId = selectedProposal;
      ceremonyState="idle"; ceremonyFailReason=null;
      render();
      toast(`Selected ${selectedProposal} — challenge ${state.proposals.find(p=>p.id===selectedProposal).challenge}`);
    });
  });
  document.querySelectorAll("[data-open-ceremony]").forEach(el=>{
    el.addEventListener("click", ()=>{
      selectedProposal = el.getAttribute("data-open-ceremony");
      state.ceremony.proposalId = selectedProposal;
      ceremonyState="idle"; ceremonyFailReason=null;
      setVariant("A");
      // scroll phone into view on mobile
      toast(`Ceremony ready for ${selectedProposal} — drive it in the phone preview →`);
    });
  });
  document.querySelectorAll("[data-scenario]").forEach(el=>{
    el.addEventListener("click", ()=>{
      selectedDeviceScenario = el.getAttribute("data-scenario");
      render();
    });
  });
  document.querySelectorAll("[data-degraded]").forEach(el=>{
    el.addEventListener("click", ()=>{
      selectedDegraded = el.getAttribute("data-degraded");
      render();
    });
  });
  // ceremony controls
  const stepBtn = document.querySelector("[data-ceremony-step]");
  if(stepBtn){
    stepBtn.addEventListener("click", ()=>{
      if(ceremonyState==="idle"){ ceremonyState="passkey"; }
      else if(ceremonyState==="passkey"){ ceremonyState="faceid"; }
      else if(ceremonyState==="faceid"){ ceremonyState="submitting"; setTimeout(()=>{ // simulate server re-eval
        const proposal = state.proposals.find(p=>p.id===state.ceremony.proposalId);
        if(proposal.status.includes("SUPERSEDED") || proposal.challenge.includes("expired")){
          ceremonyState="fail"; ceremonyFailReason="Proposal superseded/expired — server rejected even though biometrics passed.";
        } else {
          ceremonyState="success";
        }
        render();
      }, 700); }
      else if(ceremonyState==="success" || ceremonyState==="fail"){ ceremonyState="idle"; ceremonyFailReason=null; }
      render();
    });
  }
  const resetBtn = document.querySelector("[data-ceremony-reset]");
  if(resetBtn) resetBtn.addEventListener("click", ()=>{ ceremonyState="idle"; ceremonyFailReason=null; render(); });
  document.querySelectorAll("[data-fail]").forEach(el=>{
    el.addEventListener("click", (e)=>{
      e.preventDefault();
      const kind=el.getAttribute("data-fail");
      const map={ expired:"Proposal expired at 16:00 CT — server returns 410. Face ID never offered.", modified:"Challenge modified in transit — signature over wrong bytes — server rejects.", replay:"One-time challenge already consumed — replay rejected, counter unchanged.", revoked:"Device revoked 19 AUG — session + App Attest key invalidated — approval fenced." };
      ceremonyState="fail"; ceremonyFailReason=map[kind];
      render();
    });
  });
  const prev=document.querySelector("[data-switcher-prev]");
  const next=document.querySelector("[data-switcher-next]");
  if(prev) prev.addEventListener("click", ()=>{
    const idx=variants.findIndex(v=>v.key===currentVariant().key);
    setVariant(variants[(idx-1+variants.length)%variants.length].key);
  });
  if(next) next.addEventListener("click", ()=>{
    const idx=variants.findIndex(v=>v.key===currentVariant().key);
    setVariant(variants[(idx+1)%variants.length].key);
  });
  document.addEventListener("keydown", onKey, { once:true });
}
function onKey(e){
  if(e.target.closest("input, textarea, select, [contenteditable='true']")) return;
  if(e.key==="ArrowLeft"){
    const idx=variants.findIndex(v=>v.key===currentVariant().key);
    setVariant(variants[(idx-1+variants.length)%variants.length].key);
  } else if(e.key==="ArrowRight"){
    const idx=variants.findIndex(v=>v.key===currentVariant().key);
    setVariant(variants[(idx+1)%variants.length].key);
  } else {
    document.addEventListener("keydown", onKey, { once:true });
  }
}

render();
