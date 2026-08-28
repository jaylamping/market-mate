// Throwaway prototype: Approval Companion UI v2 — three structural variants.
// ?variant=A — Focus Stack | B — Morning Brief | C — Console Tabs
// Contract source: #51 resolution (comment 5457607795). Simulated state only.
// No persistence, no credentials, no real signing, no authority.

const state = {
  asOf: "Aug 28, 2026 · 4:47 PM CT",
  env: "LIVE",
  riskState: "NORMAL",
  authority: "Per-order approval · grant expires Sep 24",
  gates: [
    { id: 1, name: "Paid program & entitlements", ok: true, note: "APNs · Associated Domains · App Attest proven in build" },
    { id: 2, name: "Device binding + attestation", ok: true, note: "Secure Enclave key · App Attest challenge 08-12" },
    { id: 3, name: "Current iOS + security patch", ok: true, note: "iOS 26.1 · security content verified" },
    { id: 4, name: "Fresh passkey + proposal signature", ok: true, note: "Per session · no standing authority" },
  ],
  device: { name: "iPhone 17 Pro", os: "iOS 26.1", key: "Secure Enclave · biometry-current", recovery: "Web-authoritative" },
  push: { degraded: false, lastSync: "2 min ago" },
  proposals: [
    { id: "PI-204", env: "LIVE", kind: "Order plan", title: "Sell to open 1 AAPL put spread", change: "Open defined-risk position · max loss $185", scope: "AAPL · Oct 16 240/250 put spread", evidence: "Cycle 2026-08-28 · 6 indicators", expiry: "22 min", maxLoss: "$185 (1.9% equity)", policy: "Risk Policy v7 · Options Contract v2" },
    { id: "PI-205", env: "LIVE", kind: "Order plan", title: "Close MSFT vertical at 0.42 limit", change: "Reduce exposure · realized +$310 est.", scope: "MSFT · Sep 5 spread · 1 unit", evidence: "Liquidity gate passed · spread 0.03", expiry: "8 min", maxLoss: "n/a — reducing", policy: "Risk Policy v7" },
    { id: "PI-206", env: "PAPER", kind: "Strategy", title: "Admit Strategy v12 to Paper", change: "New paper-only sleeve · no live effect", scope: "earnings-drift v12 · 5 symbols", evidence: "Walk-forward 3/3 · holdout sealed", expiry: "48 hrs", maxLoss: "Paper only", policy: "Strategy Governance v3" },
  ],
  alerts: [
    { id: "AL-91", sev: "warning", title: "APNs delivery delayed", body: "Push latency 4m over threshold. Companion is polling foreground; Slack + SMS redundancy active. Approvals unaffected — queue is server-side.", ack: false },
    { id: "AL-90", sev: "critical", title: "Reconciliation drift resolved", body: "Broker drift of $0.04 self-cleared on venue event replay. No action needed; recorded for transparency.", ack: true },
  ],
  activity: [
    { ts: "4:41 PM", text: "Research Snapshot recorded — cycle 2026-08-28 complete, 40 members" },
    { ts: "4:12 PM", text: "Safety Kernel recomputed — Risk State NORMAL, no reservations" },
    { ts: "3:58 PM", text: "You signed PI-203 — CLOSE NKE position (Decision Record DR-1187)" },
    { ts: "2:30 PM", text: "Paper calibration job finished — conservative overlay within bounds" },
  ],
};

/* ---------- tiny dom helpers ---------- */
const $app = document.getElementById("app");
const $overlays = document.getElementById("overlays");
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const envLabel = (env) => `<span class="env-label env-${env.toLowerCase()}">${env}</span>`;
const riskTone = () => ({ NORMAL: "tone-normal", WARNING: "tone-warning", FROZEN: "tone-live", HALTED: "tone-live" }[state.riskState] || "tone-neutral");

/* ---------- system-truth header (verbatim contract from #18) ---------- */
function truthHeader() {
  return `
  <div class="statusbar"><span>9:41</span><span class="glyphs">▮▮▮ ᯤ ▭</span></div>
  <header class="truth">
    <div class="truth-row">
      <div class="brand"><span class="brand-mark">MM</span><span><b>MARKET MATE</b><small>Approval Companion</small></span></div>
      <div class="truth-spacer"></div>
      <span class="chip ${riskTone()}" id="chip-risk" title="Risk State is server-owned. Tap for trust detail."><span class="dot"></span>${state.riskState}</span>
      <span class="chip ${state.env === "LIVE" ? "tone-live" : "tone-paper"}">${state.env}</span>
    </div>
    <div class="trust-line" id="trust-line">
      <span class="sync-dot ${state.push.degraded ? "bad" : ""}"></span>
      <span><b>Gates 4/4</b> · 1 device · ${state.push.degraded ? "push degraded — polling" : "synced " + state.push.lastSync}</span>
      <span class="dot-sep"></span><span>authority: <b>per-order approval</b></span>
    </div>
  </header>`;
}

/* ---------- sheet plumbing ---------- */
function openSheet(html) {
  $overlays.innerHTML = `<div class="sheet-backdrop" id="backdrop"><div class="sheet" role="dialog" aria-modal="true">
    <div class="grabber"></div><button class="close-x" id="sheet-x" aria-label="Close">✕</button><div id="sheet-body">${html}</div>
  </div></div>`;
  requestAnimationFrame(() => document.getElementById("backdrop").classList.add("open"));
  document.getElementById("backdrop").addEventListener("click", (e) => { if (e.target.id === "backdrop") closeSheet(); });
  document.getElementById("sheet-x").addEventListener("click", closeSheet);
}
function setSheetBody(html) {
  const b = document.getElementById("sheet-body");
  if (b) b.innerHTML = html;
}
function closeSheet() {
  const b = document.getElementById("backdrop");
  if (!b) return;
  b.classList.remove("open");
  setTimeout(() => { $overlays.innerHTML = ""; render(); }, 220);
}

/* ---------- approval signing ceremony (the moment, per #51) ---------- */
function runCeremony(p, onDone) {
  const nonce = "nonce_7f3a…e91c · binds " + p.id + " · " + p.policy;
  const stages = [
    `<div class="ceremony-stage center"><div class="spinner"></div><p class="subtle">Fetching exact proposal from server…</p><p class="note">Never a cached copy — what you sign is what executes.</p></div>`,
    `<div class="ceremony-stage center"><div class="big-icon faceid">🔒</div><p><b>Face ID — approve signing</b></p><p class="subtle" style="margin-top:6px">Secure Enclave key · biometry-current</p></div>`,
    `<div class="ceremony-stage"><p class="caps">Signature</p><h2 style="margin-top:8px">Signing one-time challenge</h2><div class="nonce" style="margin-top:14px">${esc(nonce)}</div><p class="note">The signature covers proposal ID, scope, quantity, max loss, expiry, and policy version. The device holds no authority — the server chooses to trust this key.</p></div>`,
    `<div class="ceremony-stage center"><div class="spinner"></div><p class="subtle">Server verifying assertion & App Attest counter…</p></div>`,
    `<div class="ceremony-stage center"><div class="big-icon ok">✓</div><p><b>Recorded — Decision Record</b></p><p class="subtle" style="margin-top:6px">${esc(p.id)} · DR-1188 · ${new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</p><p class="note">Server-authoritative. The companion owns none of the result.</p><button class="btn btn-primary" id="c-done">Done</button></div>`,
  ];
  const draw = (i) => {
    setSheetBody(`
      <span class="caps">Approval Signing Ceremony</span>
      <h2 style="margin-top:6px">${esc(p.env)} · ${esc(p.title)}</h2>
      <div class="ceremony-steps">${stages.map((_, idx) => `<span class="${idx <= i ? "done" : ""}"></span>`).join("")}</div>
      ${stages[i]}`);
    const done = document.getElementById("c-done");
    if (done) done.addEventListener("click", () => { closeSheet(); onDone(); });
  };
  draw(0);
  const delays = [700, 1300, 1200, 1100];
  let t = 300;
  delays.forEach((d, idx) => { t += d; setTimeout(() => draw(idx + 1), t); });
}

function openProposalCeremony(id) {
  const p = state.proposals.find((x) => x.id === id);
  if (!p) return;
  openSheet(`
    <span class="caps">Exact proposal · ${esc(p.id)}</span>
    <h2 style="margin-top:6px">${esc(p.title)}</h2>
    <div style="margin-top:8px">${envLabel(p.env)}<span style="font-size:11px;color:var(--text-3);margin-left:8px">${esc(p.kind)} · expires in ${esc(p.expiry)}</span></div>
    <div class="change">${esc(p.change)}</div>
    <dl class="facts">
      <div><dt>Exact scope</dt><dd>${esc(p.scope)}</dd></div>
      <div><dt>Max loss</dt><dd>${esc(p.maxLoss)}</dd></div>
      <div><dt>Evidence</dt><dd>${esc(p.evidence)}</dd></div>
      <div><dt>Policy</dt><dd>${esc(p.policy)}</dd></div>
    </dl>
    <label class="check-row"><input type="checkbox" id="understand"> I am signing an exact, immutable proposal. Only the server-authoritative result changes authority.</label>
    <button class="btn btn-primary" id="c-go" disabled>Begin signing ceremony</button>
    <button class="btn btn-ghost" id="c-later">Not now</button>`);
  const go = document.getElementById("c-go");
  document.getElementById("understand").addEventListener("change", (e) => { go.disabled = !e.target.checked; });
  document.getElementById("c-later").addEventListener("click", closeSheet);
  go.addEventListener("click", () => {
    runCeremony(p, () => {
      state.proposals = state.proposals.filter((x) => x.id !== id);
      state.activity.unshift({ ts: "now", text: `You signed ${id} — ${p.title}`, dot: true });
    });
  });
}

/* ---------- emergency sheet (signed requests; server owns Risk State) ---------- */
function openEmergency(mode = null) {
  if (!mode) {
    openSheet(`
      <span class="caps">Emergency restrictions — signed requests</span>
      <h2 style="margin-top:6px">Risk State: <span style="color:${state.riskState === "NORMAL" ? "var(--ok)" : "var(--warn)"}">${state.riskState}</span></h2>
      <p class="note">Your signature submits a <b>request</b>. The server-side Safety Kernel executes it and owns all Risk State. Containment never waits for a reply (#36, #46). A local request is never reported as success.</p>
      <div class="section-gap"></div>
      <button class="btn btn-danger" id="em-freeze">Request Freeze Live</button>
      <button class="btn btn-danger" id="em-halt">Request Halt Live</button>
      <button class="btn btn-ghost" id="em-ack">Acknowledge all alerts</button>`);
    document.getElementById("em-freeze").addEventListener("click", () => openEmergency("Freeze Live"));
    document.getElementById("em-halt").addEventListener("click", () => openEmergency("Halt Live"));
    document.getElementById("em-ack").addEventListener("click", () => { state.alerts.forEach((a) => (a.ack = true)); closeSheet(); });
    return;
  }
  openSheet(`
    <span class="caps">Emergency restriction — confirm target</span>
    <h2 style="margin-top:6px">Request ${esc(mode)}</h2>
    <div class="change" style="border-color:rgba(255,93,93,.4);background:var(--danger-bg)">Exact target: <b>LIVE · Account …8841</b> — not Paper.</div>
    <label class="check-row"><input type="checkbox" id="em-understand"> I confirm the exact target and that this signs a one-time emergency challenge.</label>
    <button class="btn btn-danger" id="em-go" disabled>Sign emergency request</button>
    <button class="btn btn-ghost" id="em-cancel">Back</button>`);
  const goBtn = document.getElementById("em-go");
  document.getElementById("em-understand").addEventListener("change", (e) => (goBtn.disabled = !e.target.checked));
  document.getElementById("em-cancel").addEventListener("click", () => openEmergency(null));
  goBtn.addEventListener("click", () => {
    runCeremony({ id: "EMERGENCY", env: "LIVE", kind: mode, title: mode + " — signed request", policy: "Safety Kernel · Emergency Restrictions" }, () => {
      state.riskState = mode === "Freeze Live" ? "FROZEN" : "HALTED";
      state.activity.unshift({ ts: "now", text: `You signed ${mode} request — Safety Kernel executing`, dot: true });
    });
  });
}

/* ---------- trust sheet (gates + binding visible, not plumbing) ---------- */
function openTrust() {
  openSheet(`
    <span class="caps">Trust — Companion Activation Gates</span>
    <h2 style="margin-top:6px">4/4 gates pass</h2>
    ${state.gates.map((g) => `<div class="gate-row"><span class="gate-mark">✓</span><span><b>${esc(g.name)}</b><small>${esc(g.note)}</small></span></div>`).join("")}
    <div class="section-gap"></div><span class="caps">Device binding</span>
    <div class="device-line"><span>${esc(state.device.name)}</span><small>${esc(state.device.os)} · ${esc(state.device.key)}</small></div>
    <div class="device-line"><span>Recovery authority<small>${esc(state.device.recovery)} — revoke / re-enroll from the web; never requires this device</small></span></div>
    <div class="device-line"><span>Push delivery</span><small>${state.push.degraded ? "DEGRADED — polling foreground; Slack/SMS redundant (#36)" : "APNs healthy · doorbell-only payloads"}</small></div>
    <p class="note">The companion never owns canonical strategy, risk, ledger, execution, or authorization state. It authenticates and signs; the server executes and records.</p>`);
}

/* ---------- scenario sheet (prototype-only explorer) ---------- */
function openScenarios() {
  openSheet(`
    <span class="caps">Prototype scenarios</span>
    <h2 style="margin-top:6px">Push the state around</h2>
    <p class="note">Throwaway-only controls to feel the empty state, degradation, and escalation.</p>
    <div class="section-gap"></div>
    <button class="btn btn-ghost" id="sc-push">${state.push.degraded ? "Restore" : "Degrade"} push delivery</button>
    <button class="btn btn-ghost" id="sc-ack">Acknowledge all alerts</button>
    <button class="btn btn-ghost" id="sc-drain">Clear all proposals (empty state)</button>
    <button class="btn btn-ghost" id="sc-refill">Restore proposal queue</button>
    <button class="btn btn-ghost" id="sc-risk">Toggle Risk State WARNING/NORMAL</button>`);
  document.getElementById("sc-push").addEventListener("click", () => { state.push.degraded = !state.push.degraded; state.push.lastSync = "just now"; closeSheet(); });
  document.getElementById("sc-ack").addEventListener("click", () => { state.alerts.forEach((a) => (a.ack = true)); closeSheet(); });
  document.getElementById("sc-drain").addEventListener("click", () => { state._backup = state.proposals; state.proposals = []; closeSheet(); });
  document.getElementById("sc-refill").addEventListener("click", () => { if (state._backup) state.proposals = state._backup; closeSheet(); });
  document.getElementById("sc-risk").addEventListener("click", () => { state.riskState = state.riskState === "NORMAL" ? "WARNING" : "NORMAL"; closeSheet(); });
}

/* ================= VARIANT A — FOCUS STACK ================= */
function VariantA() {
  const p = state.proposals[0];
  const rest = state.proposals.length - 1;
  return `
  <div class="body">
    ${state.push.degraded ? `<div class="degraded-banner">⚠ Push degraded — polling on foreground. Queue is server-side.</div>` : ""}
    ${p ? `
    <div style="margin-top:22px"><span class="caps">Needs your signature</span></div>
    <article class="card" data-proposal="${p.id}">
      <div class="card-head">${envLabel(p.env)}<span class="caps" style="letter-spacing:1px">${esc(p.kind)} · ${esc(p.id)} · expires ${esc(p.expiry)}</span></div>
      <h3>${esc(p.title)}</h3>
      <div class="change">${esc(p.change)}</div>
      <dl class="facts">
        <div><dt>Exact scope</dt><dd>${esc(p.scope)}</dd></div>
        <div><dt>Max loss</dt><dd>${esc(p.maxLoss)}</dd></div>
        <div><dt>Evidence</dt><dd>${esc(p.evidence)}</dd></div>
        <div><dt>Policy</dt><dd>${esc(p.policy)}</dd></div>
      </dl>
      <div class="btn-row">
        <button class="btn btn-primary" data-open="${esc(p.id)}">Review & sign</button>
        <button class="btn btn-ghost" data-later="${esc(p.id)}">Not now</button>
      </div>
    </article>
    ${rest > 0 ? `<div class="peek" data-open="${esc(state.proposals[1].id)}"><span class="subtle" style="font-size:13px"><b style="color:var(--text)">${rest}</b> more waiting</span><span class="dots">${Array.from({ length: Math.min(rest, 3) }, (_, i) => `<i class="${i === 0 ? "on" : ""}"></i>`).join("")}</span></div>` : ""}
    ` : `
    <div class="focus-empty">
      <div class="big-icon ok">✓</div>
      <h2>All clear</h2>
      <p class="subtle" style="margin-top:8px">Nothing needs your signature.<br>The queue is server-side and re-syncs on open.</p>
    </div>`}
    <div class="section-gap"></div>
    <span class="caps">Watching</span>
    <article class="card" style="padding:14px 16px">
      <div class="card-head"><span style="font-size:13.5px;font-weight:600">Risk containment</span><span class="chip ${riskTone()}"><span class="dot"></span>${state.riskState}</span></div>
      <p class="subtle" style="font-size:12.5px;margin-top:8px">${esc(state.authority)}</p>
    </article>
  </div>
  <button class="shield-fab" id="shield" title="Emergency restrictions">🛡</button>`;
}

/* ================= VARIANT B — MORNING BRIEF ================= */
function VariantB() {
  const live = state.proposals.filter((p) => p.env === "LIVE");
  const paper = state.proposals.filter((p) => p.env !== "LIVE");
  const watch = state.alerts.filter((a) => !a.ack).length;
  return `
  <div class="body">
    <div class="brief-hero">
      <span class="caps">${esc(state.asOf)}</span>
      <h1>${live.length ? "One tap from settled." : "Nothing needs you."}</h1>
      <p>${live.length ? esc(String(live.length)) + " live signature" + (live.length > 1 ? "s" : "") + " waiting. Everything else can wait." : "The queue is server-side and re-syncs whenever you open the companion."}</p>
      <div class="brief-counts">
        <div class="count-pill hot"><b>${state.proposals.length}</b><span>to sign</span></div>
        <div class="count-pill watch"><b>${watch}</b><span>to ack</span></div>
        <div class="count-pill"><b>${paper.length}</b><span>paper</span></div>
      </div>
    </div>
    ${state.push.degraded ? `<div class="degraded-banner">⚠ Push degraded — polling on foreground.</div>` : ""}
    <div class="section-gap"></div><span class="caps">Needs your signature</span>
    ${live.length ? live.map((p) => `
      <article class="card pressable" data-open="${esc(p.id)}">
        <div class="card-head">${envLabel(p.env)}<span class="caps">${esc(p.id)} · ${esc(p.expiry)}</span></div>
        <h3>${esc(p.title)}</h3>
        <div class="change">${esc(p.change)}</div>
        <div class="btn-row"><button class="btn btn-primary" data-open="${esc(p.id)}">Review & sign</button></div>
      </article>`).join("") : `<p class="subtle" style="margin-top:10px;font-size:13.5px">Live queue empty.</p>`}
    ${paper.length ? `<span class="caps" style="display:block;margin-top:16px">Paper queue</span>` + paper.map((p) => `
      <article class="card pressable" data-open="${esc(p.id)}" style="opacity:.85">
        <div class="card-head">${envLabel(p.env)}<span class="caps">${esc(p.id)}</span></div>
        <h3 style="font-size:15px">${esc(p.title)}</h3>
      </article>`).join("") : ""}
    <div class="section-gap"></div><span class="caps">Watching</span>
    <article class="card" style="padding:6px 16px 12px">
      ${state.alerts.map((a) => `<div class="activity-row"><span class="dotmark">${a.ack ? "○" : "●"}</span><span style="flex:1"><b style="font-size:13.5px">${esc(a.title)}</b><br><span class="subtle" style="font-size:12px">${esc(a.body)}</span></span></div>`).join("")}
    </article>
    <div class="section-gap"></div><span class="caps">Recently recorded</span>
    <article class="card" style="padding:6px 16px">
      ${state.activity.slice(0, 4).map((ev) => `<div class="activity-row"><span class="ts">${esc(ev.ts)}</span><span>${ev.dot ? `<span class="dotmark">●</span> ` : ""}${esc(ev.text)}</span></div>`).join("")}
    </article>
  </div>
  <button class="shield-fab" id="shield" title="Emergency restrictions">🛡</button>`;
}

/* ================= VARIANT C — CONSOLE TABS ================= */
let cTab = "approvals";
function VariantC() {
  const pending = state.proposals.length;
  const alertCard = (a) => `
    <article class="card alert-card ${a.sev === "critical" ? "sev-critical" : ""} ${a.ack ? "alert-acked" : ""}">
      <div class="card-head"><span class="caps">${esc(a.sev)}</span><span class="caps">${esc(a.id)}</span></div>
      <h3 style="font-size:15px">${esc(a.title)}</h3>
      <p class="subtle" style="font-size:12.5px;margin-top:6px">${esc(a.body)}</p>
      ${a.ack ? `<span class="ack-tag">✓ acknowledged — recorded</span>` : `<button class="ack-btn" data-ack="${esc(a.id)}">Acknowledge</button>`}
    </article>`;
  const body = {
    approvals: () => `
      <h1 class="large" style="margin-top:22px">Approvals</h1>
      ${state.push.degraded ? `<div class="degraded-banner">⚠ Push degraded — polling on foreground. Slack/SMS redundant.</div>` : ""}
      <article class="card" style="padding:4px 18px">
      ${state.proposals.length ? state.proposals.map((p) => `
        <div class="queue-row" data-open="${esc(p.id)}">
          ${envLabel(p.env)}
          <div class="q-main"><div class="q-title">${esc(p.title)}</div><div class="q-meta">${esc(p.kind)} · max loss ${esc(p.maxLoss)} · expires ${esc(p.expiry)}</div></div>
          <span class="chev">›</span>
        </div>`).join("") : `<p class="subtle" style="padding:16px 2px;font-size:13.5px">Queue empty — re-syncs on open.</p>`}
      </article>`,
    status: () => `
      <h1 class="large" style="margin-top:22px">Status</h1>
      <div class="tile-grid" style="margin-top:14px">
        <div class="tile"><div class="t-label">Risk state</div><div class="t-val" style="color:var(--ok)">${state.riskState}</div><div class="t-sub">server-owned</div></div>
        <div class="tile"><div class="t-label">Research cycle</div><div class="t-val">Fresh</div><div class="t-sub">2026-08-28 post-close</div></div>
        <div class="tile"><div class="t-label">Reconciliation</div><div class="t-val">Balanced</div><div class="t-sub">through latest venue event</div></div>
        <div class="tile"><div class="t-label">Authority</div><div class="t-val" style="font-size:13px">Per-order</div><div class="t-sub">grant exp. Sep 24</div></div>
      </div>
      <div class="section-gap"></div><span class="caps">Recently recorded</span>
      <article class="card" style="padding:6px 16px">
        ${state.activity.slice(0, 5).map((ev) => `<div class="activity-row"><span class="ts">${esc(ev.ts)}</span><span>${esc(ev.text)}</span></div>`).join("")}
      </article>`,
    alerts: () => `
      <h1 class="large" style="margin-top:22px">Alerts</h1>
      <p class="subtle" style="margin-top:6px;font-size:13.5px">Acknowledgement is authenticated. Critical also rides Slack/SMS (#36) — containment never waits for you.</p>
      ${state.alerts.map(alertCard).join("")}`,
    trust: () => `
      <h1 class="large" style="margin-top:22px">Trust</h1>
      <p class="subtle" style="margin-top:6px;font-size:13.5px">Activation gates and binding are visible states, not plumbing.</p>
      <article class="card" style="padding:6px 16px">
        ${state.gates.map((g) => `<div class="gate-row"><span class="gate-mark">✓</span><span><b>${esc(g.name)}</b><small>${esc(g.note)}</small></span></div>`).join("")}
      </article>
      <div class="section-gap"></div><span class="caps">Device binding</span>
      <article class="card" style="padding:6px 16px">
        <div class="device-line"><span>${esc(state.device.name)}</span></div>
        <div class="device-line"><span>OS</span><span>${esc(state.device.os)}</span></div>
        <div class="device-line"><span>Key</span><span>Secure Enclave · biometry-current</span></div>
        <div class="device-line"><span>Push</span><span>${state.push.degraded ? "DEGRADED — polling" : "APNs healthy"}</span></div>
      </article>
      <p class="note">Recovery, revocation, and re-enrollment are <b>web-authoritative</b> — never possible only on this device. Reinstall re-attests and re-binds.</p>
      <p class="note">The companion never owns canonical strategy, risk, ledger, execution, or authorization state.</p>`,
  }[cTab]();
  return `
  <div class="body">${body}</div>
  <nav class="tabbar">
    <button class="tab ${cTab === "approvals" ? "on" : ""}" data-tab="approvals"><span class="ico">✍️</span>Approvals${pending ? `<span class="badge">${pending}</span>` : ""}</button>
    <button class="tab ${cTab === "status" ? "on" : ""}" data-tab="status"><span class="ico">📊</span>Status</button>
    <button class="tab ${cTab === "alerts" ? "on" : ""}" data-tab="alerts"><span class="ico">🔔</span>Alerts${state.alerts.some((a) => !a.ack) ? `<span class="badge">!</span>` : ""}</button>
    <button class="tab ${cTab === "trust" ? "on" : ""}" data-tab="trust"><span class="ico">🛡️</span>Trust</button>
  </nav>`;
}

/* ---------- switcher + router ---------- */
const variants = [
  { key: "A", name: "Focus Stack", render: VariantA },
  { key: "B", name: "Morning Brief", render: VariantB },
  { key: "C", name: "Console Tabs", render: VariantC },
];
const currentVariant = () => variants.find((v) => v.key === new URLSearchParams(location.search).get("variant")) || variants[0];
function setVariant(key) {
  const url = new URL(location.href);
  url.searchParams.set("variant", key);
  history.replaceState(null, "", url);
  render();
}
function render() {
  const v = currentVariant();
  $app.innerHTML = truthHeader() + v.render() + `
  <div class="switcher" id="switcher">
    <button id="sw-prev" aria-label="Previous variant">←</button>
    <span class="vlabel">${v.key} — ${v.name}</span>
    <button id="sw-next" aria-label="Next variant">→</button>
  </div>
  <button class="sim-pill" id="sim-pill">SIM</button>`;
  document.querySelectorAll("[data-open]").forEach((el) => el.addEventListener("click", (e) => { e.stopPropagation(); openProposalCeremony(el.dataset.open); }));
  document.querySelectorAll("[data-ack]").forEach((el) => el.addEventListener("click", (e) => { e.stopPropagation(); const a = state.alerts.find((x) => x.id === el.dataset.ack); if (a) a.ack = true; render(); }));
  document.querySelectorAll("[data-tab]").forEach((el) => el.addEventListener("click", () => { cTab = el.dataset.tab; render(); }));
  document.querySelectorAll("[data-later]").forEach((el) => el.addEventListener("click", (e) => {
    e.stopPropagation();
    const i = state.proposals.findIndex((p) => p.id === el.dataset.later);
    if (i >= 0) { const [p] = state.proposals.splice(i, 1); state.proposals.push(p); }
    render();
  }));
  document.getElementById("sw-prev").addEventListener("click", () => setVariant(variants[(variants.indexOf(currentVariant()) + variants.length - 1) % variants.length].key));
  document.getElementById("sw-next").addEventListener("click", () => setVariant(variants[(variants.indexOf(currentVariant()) + 1) % variants.length].key));
  document.getElementById("sim-pill").addEventListener("click", openScenarios);
  const shield = document.getElementById("shield");
  if (shield) shield.addEventListener("click", openEmergency);
  const trust = document.getElementById("trust-line");
  if (trust) trust.addEventListener("click", openTrust);
  const chip = document.getElementById("chip-risk");
  if (chip) chip.addEventListener("click", openTrust);
}

/* ---------- keyboard ---------- */
document.addEventListener("keydown", (e) => {
  if (/INPUT|TEXTAREA/.test(document.activeElement.tagName) || document.activeElement.isContentEditable) return;
  if (e.key === "ArrowLeft") setVariant(variants[(variants.indexOf(currentVariant()) + variants.length - 1) % variants.length].key);
  if (e.key === "ArrowRight") setVariant(variants[(variants.indexOf(currentVariant()) + 1) % variants.length].key);
});

render();