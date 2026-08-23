// Three throwaway variants of the Principal Audit Dashboard, switchable via ?variant=.
// Simulated state only: no persistence, authentication, brokerage connection, or authority.

const state = {
  asOf: "23 AUG 2026 · 09:47:18 CT",
  selectedEnvironment: "LIVE",
  selectedDecision: "DR-L-01842",
  emergencyState: "PARTIAL",
  risk: {
    LIVE: {
      state: "CONTAINED — PARTIAL CONFIRMATION",
      detail: "New exposure blocked locally; broker cancellation confirmation missing for 1 order.",
      lastReconciled: "09:46:52 CT · 26s ago",
      epoch: "LIVE-US-01 / E-0041",
      tone: "danger",
    },
    PAPER: {
      state: "NOMINAL — QUALIFIED SIMULATION",
      detail: "Paper venue and ledger agree through event 8,841.",
      lastReconciled: "09:47:10 CT · 8s ago",
      epoch: "PAPER-US-02 / E-0198",
      tone: "good",
    },
  },
  accounts: {
    LIVE: {
      equity: "$1,086.42",
      cash: "$614.29",
      exposure: "$472.13",
      pnl: "+$12.74",
      benchmark: "+$8.19",
      costs: "$4.63",
      buyingPower: "$614.29",
      openOrders: "1 cancellation uncertain",
    },
    PAPER: {
      equity: "$1,241.86",
      cash: "$318.08",
      exposure: "$923.78",
      pnl: "+$168.18",
      benchmark: "+$94.70",
      costs: "$31.44",
      buyingPower: "$1,482.71 simulated",
      openOrders: "2 active · 1 planned",
    },
  },
  decisions: [
    {
      id: "DR-L-01842",
      environment: "LIVE",
      time: "09:46:31",
      subject: "Cancel remaining IWM call-spread exit",
      strategy: "SV-031.8 · Sleeve LIVE-ALPHA-01",
      disposition: "ATTEMPTED",
      execution: "RECONCILIATION PENDING",
      outcome: "EVALUATION PENDING",
      expected: "+$1.10 to +$4.30 avoided loss",
      modeledLoss: "$18.00 max incremental",
      baseline: "No Action: order may rest 14m longer",
      observed: "Broker acknowledgement absent after 22s",
      gate: "SENTINEL: CONTAINMENT REQUIRED",
      attempt: "AA-L-4413 · request accepted locally",
      evidence: "RS-20260823-OPEN-04 · quote 09:46:29 · hash 74a…c01",
      correction: "CURRENT",
      tone: "danger",
    },
    {
      id: "DR-L-01841",
      environment: "LIVE",
      time: "09:42:08",
      subject: "Do not add exposure after spread widening",
      strategy: "SV-031.8 · Sleeve LIVE-ALPHA-01",
      disposition: "REJECTED",
      execution: "NO ORDER CREATED",
      outcome: "EVALUATION PENDING",
      expected: "−$0.82 median after cost",
      modeledLoss: "$22.00",
      baseline: "Best permitted alternative: wait for spread ≤ $0.08",
      observed: "No action; spread remains $0.13",
      gate: "LIQUIDITY POLICY: DENIED",
      attempt: "None — rejected before attempt",
      evidence: "QB-883104 · OPRA executable quote · hash 08b…11e",
      correction: "CURRENT",
      tone: "warn",
    },
    {
      id: "DR-P-08839",
      environment: "PAPER",
      time: "09:38:14",
      subject: "Open defined-risk SPY put spread",
      strategy: "SV-044.2 · Sleeve PAPER-MACRO-04",
      disposition: "COMPLETED",
      execution: "RECONCILED",
      outcome: "OUTCOME INDETERMINATE",
      expected: "+$7.20 median · 63% P(net positive)",
      modeledLoss: "$34.00",
      baseline: "No Action: $0 expected · best alternate +$3.10 median",
      observed: "+$5.42 before simulated venue timed out",
      gate: "PAPER GRANT PG-771 · ALL GATES PASSED",
      attempt: "AA-P-9921 · complete before venue evidence gap",
      evidence: "RS-20260823-MACRO-02 · SIM-OVERLAY-19.3",
      correction: "REPLAY UNAVAILABLE",
      tone: "indeterminate",
    },
    {
      id: "DR-P-08838",
      environment: "PAPER",
      time: "09:32:41",
      subject: "Close QQQ calendar before event window",
      strategy: "SV-027.5 · Sleeve PAPER-EVENT-02",
      disposition: "COMPLETED",
      execution: "RECONCILED",
      outcome: "COMPLETE · HORIZON 1 OF 3",
      expected: "+$4.80 median",
      modeledLoss: "$11.00",
      baseline: "No Action: −$2.40 median event risk",
      observed: "+$6.12 net at first horizon",
      gate: "OPTIONS LIFECYCLE: EXIT REQUIRED",
      attempt: "AA-P-9920 · filled with conservative slippage",
      evidence: "OL-2930 · Paper Ledger events 8831–8836",
      correction: "CURRENT",
      tone: "good",
    },
    {
      id: "DR-P-08837",
      environment: "PAPER",
      time: "09:28:07",
      subject: "Replace DIA limit after quote moved",
      strategy: "SV-040.1 · Sleeve PAPER-AUCTION-01",
      disposition: "CANCELLED",
      execution: "RECONCILED",
      outcome: "COMPLETE",
      expected: "+$2.20 median",
      modeledLoss: "$16.00",
      baseline: "No Action: preserve cash",
      observed: "$0.00 · quote no longer met admission policy",
      gate: "QUOTE QUALITY: REPLACEMENT DENIED",
      attempt: "AA-P-9918 cancelled; AA-P-9919 never admitted",
      evidence: "QB-883072 · event-time map ET-81",
      correction: "SUPERSEDED EVIDENCE · corrected view agrees",
      tone: "neutral",
    },
  ],
  proposals: [
    {
      id: "PI-204",
      root: "ROOT-PRINCIPAL-077",
      type: "LIVE AUTHORITY",
      environment: "LIVE",
      title: "Promote SV-031.8 to $250 exposure ceiling",
      scope: "SV-031.8 · LIVE-ALPHA-01 · one account",
      evidence: "PB-031.8 · 90 Paper days · parity certificate PC-009",
      expiry: "Expires 24 AUG · 16:00 CT",
      cooling: "17h 42m cooling-off complete",
      auth: "Fresh passkey required · not yet satisfied",
      change: "Enables new Live exposure up to $250 under existing Sentinel policy",
      status: "READY FOR REVIEW",
      children: ["Broker certification BC-14 · satisfied", "Tax evidence TE-08 · satisfied", "Principal Live grant · pending"],
      tone: "danger",
    },
    {
      id: "PI-205",
      root: "ROOT-PRINCIPAL-078",
      type: "PROVIDER COST",
      environment: "RESEARCH + PAPER",
      title: "Add certified OPRA history tier",
      scope: "Research and Paper data entitlement · no Live write authority",
      evidence: "Cost case CC-071 · backlog attribution · source contract SC-19",
      expiry: "Expires in 2d 06h",
      cooling: "No cooling-off required",
      auth: "Current session sufficient after final review",
      change: "Raises provider-cost ceiling by $64/month for 60 days",
      status: "BUNDLED REVIEW",
      children: ["Entitlement review · satisfied", "Deletion contract · satisfied", "Cost expansion · pending"],
      tone: "info",
    },
    {
      id: "PI-198",
      root: "ROOT-PRINCIPAL-071",
      type: "RESUME LIVE",
      environment: "LIVE",
      title: "Resume after reconciliation incident",
      scope: "All Live risk-increasing activity",
      evidence: "INC-104 · reconciliation bundle incomplete",
      expiry: "Superseded 09:46:31 CT",
      cooling: "N/A",
      auth: "Fresh passkey was satisfied at 09:31:02",
      change: "Would have returned Live Risk State to Normal",
      status: "SUPERSEDED — CANNOT ACT",
      children: ["Ledger reconciliation · stale", "Broker certainty · failed", "Resume authority · superseded"],
      tone: "muted",
    },
  ],
  blocked: [
    {
      id: "BW-119",
      scope: "LIVE · Account …8841 · order ORD-L-449 · IWM 205/207 call spread",
      hazard: "Broker cancellation state cannot be confirmed",
      policy: "SK-CONTAIN-04 · uncertain working order",
      began: "09:46:31 CT · 47s",
      owner: "Sentinel Reconciliation Service",
      next: "Broker-native open-order query or authenticated runbook check",
      checkpoint: "09:48:00 CT",
      escalation: "Principal + broker-native emergency runbook BR-02",
      safe: "Research, Paper, ledger inspection, and risk-reducing broker confirmation remain available",
      global: "No — exact order and dependent sleeve only",
    },
    {
      id: "BW-116",
      scope: "PAPER · SV-044.2 · outcome horizon H1 · SPY spread",
      hazard: "Simulated venue payload timed out after economically promising interval",
      policy: "OUTCOME-EVIDENCE-07 · no success inference from missing terminal evidence",
      began: "09:39:02 CT · 8m 16s",
      owner: "Paper Evaluation Service",
      next: "Preserve interval; price a linked exact-method retry",
      checkpoint: "10:00 CT",
      escalation: "Testing Budget review if retry cost exceeds $18",
      safe: "Exploratory analysis and a linked Research/Paper retry remain available; no Live replay",
      global: "No — exact evaluation horizon only",
    },
    {
      id: "BW-108",
      scope: "RESEARCH · Source family NEWS-03 · 7 Research Snapshots",
      hazard: "Licensed source issued a correction without a complete affected-record list",
      policy: "EVIDENCE-CHANGE-03 · expand to smallest proven-complete closure",
      began: "08:52:10 CT",
      owner: "Evidence Control Service",
      next: "Complete dependency closure and append Corrected Decision Views",
      checkpoint: "11:30 CT",
      escalation: "Quarantine dependent Strategy Versions if closure remains ambiguous",
      safe: "Unrelated source families and disjoint Strategy Sleeves continue",
      global: "No — 7 snapshots and 2 dependent versions",
    },
  ],
  alerts: [
    { id: "AL-778", severity: "CRITICAL", environment: "LIVE", title: "Cancellation certainty missing", state: "DELIVERED · ACK REQUIRED", channel: "In-app + SMS", time: "09:46:36", acknowledged: false },
    { id: "AL-776", severity: "HIGH", environment: "PAPER", title: "Outcome evidence timed out", state: "ACKNOWLEDGED 09:41:12", channel: "In-app", time: "09:39:04", acknowledged: true },
    { id: "AL-772", severity: "INFO", environment: "RESEARCH", title: "Daily Research Snapshot complete", state: "INFORMATIONAL", channel: "In-app", time: "09:15:00", acknowledged: true },
  ],
  coverage: [
    { symbol: "SPY", tier: "CORE", state: "CURRENT", snapshot: "09:44:10", holding: "PAPER" },
    { symbol: "IWM", tier: "CORE", state: "CURRENT", snapshot: "09:44:22", holding: "LIVE" },
    { symbol: "QQQ", tier: "CORE", state: "CURRENT", snapshot: "09:44:31", holding: "PAPER" },
    { symbol: "DIA", tier: "CORE", state: "CURRENT", snapshot: "09:44:39", holding: "NONE" },
    { symbol: "AAPL", tier: "ACTIVE", state: "CURRENT", snapshot: "09:43:58", holding: "NONE" },
    { symbol: "XLF", tier: "ACTIVE", state: "SOURCE CORRECTION", snapshot: "08:52:10", holding: "NONE" },
  ],
  research: {
    id: "RS-20260823-DAILY-01",
    state: "COMPLETE WITH 1 QUARANTINED SOURCE FAMILY",
    asOf: "09:15:00 CT",
    coverage: "40 admitted · 6 shown · 40 refreshed",
    evidence: "18,442 normalized observations · 3 conflicts preserved",
    next: "Scheduled refresh 24 AUG · 08:55 CT",
  },
  operatingBudget: {
    proposals: "7 / 12 noncritical this week",
    review: "38m estimated · 90m weekly limit",
    renewals: "2 due within 14 days",
    alerts: "3 high-impact · 1 unacknowledged",
    backlog: "0 breached proposal SLAs",
    cost: "$184 / $250 monthly ceiling",
  },
  emergencyStates: {
    PENDING: "Request durably accepted; broker and ledger confirmation still pending.",
    CONFIRMED: "Broker, ledger, reservations, and Risk State all confirm containment.",
    PARTIAL: "Local containment confirmed; one broker-side order remains uncertain.",
    FAILED: "Request failed; no success is claimed and broker-native runbook is active.",
    OFFLINE: "Gateway cannot reach the authoritative service; local UI is not authoritative.",
    STALE: "Displayed evidence is older than the permitted action threshold.",
    "ALREADY CONTAINED": "No new change was needed; existing containment is verified.",
    SUPERSEDED: "A newer emergency intent or incident state replaced this request.",
  },
};

const variants = [
  { key: "A", name: "Command Ledger", render: VariantA },
  { key: "B", name: "Principal Brief", render: VariantB },
  { key: "C", name: "Twin Environments", render: VariantC },
];

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function envClass(environment) {
  if (environment.includes("LIVE")) return "env-live";
  if (environment.includes("PAPER")) return "env-paper";
  return "env-research";
}

function envLabel(environment) {
  return `<span class="env-label ${envClass(environment)}">${environment}</span>`;
}

function statusPill(label, tone = "neutral") {
  return `<span class="status-pill tone-${tone}">${label}</span>`;
}

function prototypeHeader(active = "Audit") {
  return `
    <header class="global-header">
      <a class="brand" href="?variant=${currentVariant().key}" aria-label="Market Mate Audit prototype home">
        <span class="brand-mark">MM</span>
        <span>MARKET MATE<small>PRINCIPAL CONTROL PLANE</small></span>
      </a>
      <nav aria-label="Primary prototype navigation">
        ${["Home", "Audit", "Proposals", "Alerts", "Settings"].map((item) => `<button type="button" class="nav-button ${item === active ? "is-active" : ""}" data-toast="${item} navigation is illustrative in this prototype.">${item}</button>`).join("")}
      </nav>
      <div class="principal-state">
        <span class="presence-dot" aria-hidden="true"></span>
        <span><strong>Principal session</strong><small>Read verified · fresh auth absent</small></span>
      </div>
    </header>`;
}

function globalTruthBar(compact = false) {
  const live = state.risk.LIVE;
  return `
    <section class="truth-bar ${compact ? "is-compact" : ""}" aria-label="Authoritative system truth">
      <div>${envLabel("LIVE")} ${statusPill(live.state, "danger")}</div>
      <p>${live.detail}</p>
      <dl>
        <div><dt>Last reconciliation</dt><dd>${live.lastReconciled}</dd></div>
        <div><dt>Environment epoch</dt><dd>${live.epoch}</dd></div>
      </dl>
      <button type="button" class="truth-action" data-emergency="freeze">Emergency controls</button>
    </section>`;
}

function accountMetrics(environment) {
  const account = state.accounts[environment];
  return `
    <div class="metric-grid" aria-label="${environment} account metrics">
      <article><span>Equity</span><strong>${account.equity}</strong><small>${environment} account</small></article>
      <article><span>Cash</span><strong>${account.cash}</strong><small>broker-reconciled</small></article>
      <article><span>Open exposure</span><strong>${account.exposure}</strong><small>${account.openOrders}</small></article>
      <article><span>Net P&amp;L</span><strong>${account.pnl}</strong><small>cash/S&amp;P: ${account.benchmark}</small></article>
      <article><span>Loaded costs</span><strong>${account.costs}</strong><small>allocated + trading</small></article>
    </div>`;
}

function environmentTabs() {
  return `
    <div class="environment-tabs" role="group" aria-label="Select one environment">
      ${["LIVE", "PAPER"].map((env) => `<button type="button" class="environment-tab ${state.selectedEnvironment === env ? "is-active" : ""}" data-environment="${env}" aria-pressed="${state.selectedEnvironment === env}">${envLabel(env)} <span>${state.risk[env].state}</span></button>`).join("")}
    </div>`;
}

function decisionsTable(environment = null, limit = state.decisions.length) {
  const decisions = state.decisions.filter((decision) => !environment || decision.environment === environment).slice(0, limit);
  return `
    <div class="data-table-wrap">
      <table class="decision-table">
        <thead><tr><th>Time / record</th><th>Environment / subject</th><th>Disposition</th><th>Expected vs observed</th><th>Decisive gate</th></tr></thead>
        <tbody>
          ${decisions.map((decision) => `
            <tr class="tone-row-${decision.tone}">
              <td><time>${decision.time}</time><button type="button" class="record-link" data-decision="${decision.id}">${decision.id}</button></td>
              <td>${envLabel(decision.environment)}<strong>${decision.subject}</strong><small>${decision.strategy}</small></td>
              <td>${statusPill(decision.disposition, decision.tone)}<small>${decision.execution}</small></td>
              <td><strong>${decision.expected}</strong><small>${decision.observed}</small></td>
              <td><strong>${decision.gate}</strong><small>${decision.outcome}</small></td>
            </tr>`).join("")}
        </tbody>
      </table>
    </div>`;
}

function proposalRows(limit = state.proposals.length) {
  return state.proposals.slice(0, limit).map((proposal) => `
    <article class="proposal-row tone-edge-${proposal.tone}">
      <header>${envLabel(proposal.environment)}<span>${proposal.type}</span></header>
      <h3>${proposal.title}</h3>
      <p>${proposal.change}</p>
      <dl>
        <div><dt>Scope</dt><dd>${proposal.scope}</dd></div>
        <div><dt>State</dt><dd>${proposal.status}</dd></div>
        <div><dt>Expiry</dt><dd>${proposal.expiry}</dd></div>
      </dl>
      <button type="button" data-proposal="${proposal.id}">${proposal.status.includes("SUPERSEDED") ? "Inspect immutable result" : "Review exact proposal"}</button>
    </article>`).join("");
}

function blockedRows(limit = state.blocked.length) {
  return state.blocked.slice(0, limit).map((item) => `
    <details class="blocked-row">
      <summary>
        <span><b>${item.id}</b>${envLabel(item.scope.split(" · ")[0])}</span>
        <strong>${item.hazard}</strong>
        <small>${item.scope}</small>
        <em>${item.checkpoint}</em>
      </summary>
      <dl>
        <div><dt>Controlling policy</dt><dd>${item.policy}</dd></div>
        <div><dt>Began</dt><dd>${item.began}</dd></div>
        <div><dt>Owner</dt><dd>${item.owner}</dd></div>
        <div><dt>Next evidence/action</dt><dd>${item.next}</dd></div>
        <div><dt>Escalation</dt><dd>${item.escalation}</dd></div>
        <div><dt>Safe work still available</dt><dd>${item.safe}</dd></div>
        <div><dt>Global block?</dt><dd>${item.global}</dd></div>
      </dl>
    </details>`).join("");
}

function alertsList(limit = state.alerts.length) {
  return state.alerts.slice(0, limit).map((alert) => `
    <article class="alert-row severity-${alert.severity.toLowerCase()}">
      <div><span>${alert.severity}</span>${envLabel(alert.environment)}</div>
      <strong>${alert.title}</strong>
      <small>${alert.time} · ${alert.channel} · ${alert.state}</small>
      ${alert.acknowledged ? statusPill("ACKNOWLEDGED", "good") : `<button type="button" data-alert="${alert.id}">Acknowledge in Market Mate</button>`}
    </article>`).join("");
}

function coverageTable() {
  return `
    <div class="coverage-head">
      <div><span>DAILY RESEARCH SNAPSHOT</span><strong>${state.research.id}</strong></div>
      ${statusPill(state.research.state, "warn")}
    </div>
    <dl class="snapshot-meta">
      <div><dt>Frozen as of</dt><dd>${state.research.asOf}</dd></div>
      <div><dt>Coverage</dt><dd>${state.research.coverage}</dd></div>
      <div><dt>Evidence</dt><dd>${state.research.evidence}</dd></div>
      <div><dt>Next cycle</dt><dd>${state.research.next}</dd></div>
    </dl>
    <div class="data-table-wrap compact-table"><table><thead><tr><th>Symbol</th><th>Tier</th><th>Evidence state</th><th>Snapshot</th><th>Holding</th></tr></thead><tbody>
      ${state.coverage.map((item) => `<tr><td><strong>${item.symbol}</strong></td><td>${item.tier}</td><td>${item.state}</td><td>${item.snapshot}</td><td>${item.holding}</td></tr>`).join("")}
    </tbody></table></div>`;
}

function operatingBudget() {
  return `
    <div class="budget-grid">
      ${Object.entries(state.operatingBudget).map(([key, value]) => `<article><span>${key}</span><strong>${value}</strong></article>`).join("")}
    </div>`;
}

function commandSidebar(active = "Audit tape") {
  return `
    <aside class="command-sidebar">
      <a class="brand brand-sidebar" href="?variant=A"><span class="brand-mark">MM</span><span>MARKET MATE<small>AUDIT CONTROL</small></span></a>
      <nav aria-label="Audit sections">
        ${["System truth", "Audit tape", "Decision records", "Ledgers", "Research", "Proposals", "Blocked work", "Alerts", "Emergency"].map((item, index) => `<button type="button" class="side-nav-button ${item === active ? "is-active" : ""}" data-toast="${item} is represented on this single prototype route."><span>${String(index + 1).padStart(2, "0")}</span>${item}</button>`).join("")}
      </nav>
      <div class="sidebar-foot">
        ${envLabel("LIVE")}
        <strong>Risk State: Contained</strong>
        <small>${state.risk.LIVE.lastReconciled}</small>
        <button type="button" data-emergency="freeze">Open emergency controls</button>
      </div>
    </aside>`;
}

function VariantA() {
  const env = state.selectedEnvironment;
  return `
    <div class="variant variant-a">
      ${commandSidebar()}
      <main id="prototype-main" class="command-main" tabindex="-1">
        <header class="command-header">
          <div><span class="eyebrow">PRINCIPAL / AUDIT TAPE</span><h1>System truth before activity.</h1></div>
          <div><strong>${state.asOf}</strong><small>Projection WM-8841 · rebuild current</small></div>
        </header>
        ${globalTruthBar()}
        <section class="command-section">
          <div class="section-title"><div><span>ACCOUNT TRUTH</span><h2>${env} economic state</h2></div>${environmentTabs()}</div>
          ${accountMetrics(env)}
        </section>
        <div class="command-grid">
          <section class="command-section ledger-panel">
            <div class="section-title"><div><span>ECONOMIC ARTIFACT TAPE</span><h2>${env} actions and decisions</h2></div><button type="button" class="text-button" data-toast="Filters are simulated; exact record drill-down is active.">Filter tape</button></div>
            ${decisionsTable(env)}
          </section>
          <aside class="command-section proposal-panel">
            <div class="section-title"><div><span>SERVER-AUTHORITATIVE GRAPH</span><h2>Proposal inbox</h2></div><b>${state.proposals.length}</b></div>
            ${proposalRows(2)}
          </aside>
          <section class="command-section blocked-panel">
            <div class="section-title"><div><span>PROCESS LIVENESS</span><h2>Blocked work queue</h2></div><b>${state.blocked.length} exact scopes</b></div>
            ${blockedRows()}
          </section>
          <section class="command-section research-panel">
            <div class="section-title"><div><span>POINT-IN-TIME INPUTS</span><h2>Coverage and research</h2></div><button type="button" class="text-button" data-toast="Raw licensed payload inspection would require entitlement.">Evidence graph</button></div>
            ${coverageTable()}
          </section>
          <section class="command-section alert-panel">
            <div class="section-title"><div><span>OPERATOR ALERTS</span><h2>Delivery and acknowledgement</h2></div><b>1 needs action</b></div>
            ${alertsList()}
          </section>
          <section class="command-section budget-panel">
            <div class="section-title"><div><span>PRINCIPAL OPERATIONAL BUDGET</span><h2>Human throughput</h2></div><b>No breached limits</b></div>
            ${operatingBudget()}
          </section>
        </div>
      </main>
    </div>`;
}

function briefActionCard() {
  const critical = state.alerts.find((alert) => !alert.acknowledged);
  return `
    <article class="brief-action critical-action">
      <header><span>DO THIS FIRST</span>${envLabel("LIVE")}</header>
      <h2>Containment is local, but one broker order is still uncertain.</h2>
      <p>The system has blocked new Live exposure. It has not claimed the broker cancellation succeeded.</p>
      <dl>
        <div><dt>Risk State</dt><dd>${state.risk.LIVE.state}</dd></div>
        <div><dt>Unmet gate</dt><dd>Broker-native open-order confirmation</dd></div>
        <div><dt>Alert</dt><dd>${critical.id} · ${critical.state}</dd></div>
      </dl>
      <div class="button-row">
        <button type="button" class="primary-danger" data-emergency="freeze">Inspect containment</button>
        ${critical.acknowledged ? "" : `<button type="button" class="secondary" data-alert="${critical.id}">Acknowledge alert</button>`}
      </div>
    </article>`;
}

function VariantB() {
  return `
    <div class="variant variant-b">
      ${prototypeHeader("Home")}
      <main id="prototype-main" class="brief-main" tabindex="-1">
        <section class="brief-intro">
          <div><span class="eyebrow">PRINCIPAL BRIEF · ${state.asOf}</span><h1>One uncertain Live order needs your attention.</h1><p>Everything else can wait. Paper results, research, costs, and proposals remain visible below without competing with the current containment fact.</p></div>
          <div class="brief-count"><strong>1</strong><span>required action</span><small>2 proposals can wait</small></div>
        </section>
        ${briefActionCard()}
        <section class="brief-section">
          <div class="section-title"><div><span>YOUR AUTHORITY</span><h2>Proposal inbox</h2></div><button type="button" class="text-button" data-toast="Equivalent proposal prompts are deduplicated by root intent.">View graph rules</button></div>
          <div class="brief-proposals">${proposalRows()}</div>
        </section>
        <section class="brief-section">
          <div class="section-title"><div><span>MONEY, KEPT SEPARATE</span><h2>Paper and Live at a glance</h2></div><small>Comparative view is read-only</small></div>
          <div class="brief-money">
            ${["LIVE", "PAPER"].map((env) => `<article><header>${envLabel(env)}${statusPill(state.risk[env].state, state.risk[env].tone)}</header>${accountMetrics(env)}<button type="button" data-environment-jump="${env}">Inspect ${env} Decision Records</button></article>`).join("")}
          </div>
        </section>
        <div class="brief-two-column">
          <section class="brief-section">
            <div class="section-title"><div><span>WHAT THE SYSTEM DID</span><h2>Recent Decision Records</h2></div><small>Exact evidence on open</small></div>
            <div class="brief-records">
              ${state.decisions.slice(0, 4).map((decision) => `<button type="button" class="brief-record" data-decision="${decision.id}"><span><time>${decision.time}</time>${envLabel(decision.environment)}</span><strong>${decision.subject}</strong><small>${decision.id} · ${decision.disposition}</small><em>${decision.expected}<b>${decision.observed}</b></em></button>`).join("")}
            </div>
          </section>
          <section class="brief-section">
            <div class="section-title"><div><span>WHAT CAN STILL MOVE</span><h2>Blocked work</h2></div><small>Safe work stays available</small></div>
            ${blockedRows()}
          </section>
        </div>
        <section class="brief-section research-brief">
          <div class="section-title"><div><span>TODAY'S EVIDENCE</span><h2>Coverage Universe</h2></div><small>Point-in-time snapshot</small></div>
          ${coverageTable()}
        </section>
        <section class="brief-section">
          <div class="section-title"><div><span>YOUR ATTENTION CAPACITY</span><h2>Operational budget</h2></div><small>Batch when authority does not change</small></div>
          ${operatingBudget()}
        </section>
      </main>
    </div>`;
}

function environmentColumn(environment) {
  const risk = state.risk[environment];
  const decisions = state.decisions.filter((decision) => decision.environment === environment);
  return `
    <section class="twin-column twin-${environment.toLowerCase()}" aria-label="${environment} environment">
      <header class="twin-head">
        <div>${envLabel(environment)}<h2>${environment} environment</h2><small>${risk.epoch}</small></div>
        ${statusPill(risk.state, risk.tone)}
      </header>
      <p class="twin-truth">${risk.detail}</p>
      ${accountMetrics(environment)}
      <div class="twin-section-title"><span>ACTIVE + PLANNED ACTIONS</span><b>${decisions.length}</b></div>
      <div class="twin-decisions">
        ${decisions.map((decision) => `<button type="button" data-decision="${decision.id}" class="twin-record tone-edge-${decision.tone}"><span>${decision.time} · ${decision.id}</span><strong>${decision.subject}</strong><small>${decision.disposition} · ${decision.execution}</small><dl><div><dt>Expected</dt><dd>${decision.expected}</dd></div><div><dt>Observed</dt><dd>${decision.observed}</dd></div></dl></button>`).join("")}
      </div>
      <div class="twin-section-title"><span>ENVIRONMENT CONTROLS</span><b>Exact scope</b></div>
      <div class="twin-controls">
        ${environment === "LIVE" ? `<button type="button" class="primary-danger" data-emergency="freeze">Freeze Live</button><button type="button" class="secondary" data-emergency="resume">Resume Live gates</button>` : `<button type="button" class="secondary" data-toast="Paper pause is simulated; it cannot affect Live.">Pause Paper only</button><button type="button" class="secondary" data-toast="Paper reset requires a new Environment Epoch and preserves history.">Inspect reset contract</button>`}
      </div>
    </section>`;
}

function comparisonDeltas() {
  return `
    <aside class="delta-rail" aria-label="Read-only environment comparison">
      <header><span>READ-ONLY</span><strong>COMPARISON</strong><small>No cross-environment action</small></header>
      <article><span>Net P&amp;L delta</span><strong>+$155.44 Paper</strong><small>Not evidence of Live portability</small></article>
      <article><span>Cost delta</span><strong>+$26.81 Paper</strong><small>Simulation includes overlay 19.3</small></article>
      <article><span>Open exposure</span><strong>+$451.65 Paper</strong><small>Separate capital and reservations</small></article>
      <article class="delta-warning"><span>Parity state</span><strong>DEGRADED</strong><small>Live broker certainty absent; no favorable netting</small></article>
      <article><span>Benchmark windows</span><strong>Aligned 20d / 60d</strong><small>Point-in-time cohort only</small></article>
    </aside>`;
}

function VariantC() {
  return `
    <div class="variant variant-c">
      ${prototypeHeader("Audit")}
      <main id="prototype-main" class="twin-main" tabindex="-1">
        <header class="twin-title">
          <div><span class="eyebrow">ENVIRONMENT PARITY / AUDIT</span><h1>Never confuse simulated money with real money.</h1></div>
          <div><strong>${state.asOf}</strong><small>Comparison is read-only · independent ledgers</small></div>
        </header>
        <div class="twin-grid">
          ${environmentColumn("PAPER")}
          ${comparisonDeltas()}
          ${environmentColumn("LIVE")}
        </div>
        <div class="twin-bottom">
          <section class="twin-shared-section">
            <div class="section-title"><div><span>SERVER-AUTHORITATIVE PROPOSAL GRAPH</span><h2>Authority changes</h2></div><b>No inferred parent approval</b></div>
            <div class="twin-proposals">${proposalRows()}</div>
          </section>
          <section class="twin-shared-section">
            <div class="section-title"><div><span>BLOCKED WORK QUEUE</span><h2>Exact scopes and safe continuations</h2></div><b>${state.blocked.length}</b></div>
            ${blockedRows()}
          </section>
          <section class="twin-shared-section twin-coverage">
            <div class="section-title"><div><span>SHARED RESEARCH, EXPLICIT CONSUMERS</span><h2>Coverage and snapshot</h2></div><b>Read-only evidence</b></div>
            ${coverageTable()}
          </section>
          <section class="twin-shared-section twin-alerts">
            <div class="section-title"><div><span>ALERT ROUTING</span><h2>Authoritative acknowledgements</h2></div><b>Containment never waits</b></div>
            ${alertsList()}
          </section>
        </div>
      </main>
    </div>`;
}

function currentVariant() {
  const key = new URLSearchParams(window.location.search).get("variant")?.toUpperCase() || "A";
  return variants.find((variant) => variant.key === key) || variants[0];
}

function switcherMarkup(variant) {
  return `
    <div class="prototype-switcher" role="group" aria-label="Prototype variant switcher">
      <button type="button" class="switcher-arrow" data-cycle="-1" aria-label="Previous prototype variant">←</button>
      <div class="switcher-label"><span>THROWAWAY VARIANT</span><strong>${variant.key} — ${variant.name}</strong></div>
      <button type="button" class="switcher-arrow" data-cycle="1" aria-label="Next prototype variant">→</button>
    </div>`;
}

function render() {
  const variant = currentVariant();
  $("#app").innerHTML = variant.render() + switcherMarkup(variant) + `<div class="prototype-toast" role="status" aria-live="polite"></div>`;
  bindEvents();
}

function cycleVariant(direction) {
  const current = currentVariant();
  const index = variants.findIndex((variant) => variant.key === current.key);
  const next = variants[(index + direction + variants.length) % variants.length];
  const url = new URL(window.location.href);
  url.searchParams.set("variant", next.key);
  window.history.replaceState({}, "", url);
  render();
  announce(`Prototype variant ${next.key}, ${next.name}`);
}

function showToast(message) {
  const toast = $(".prototype-toast");
  if (!toast) return;
  toast.textContent = message;
  toast.classList.add("is-visible");
  window.clearTimeout(showToast.timeout);
  showToast.timeout = window.setTimeout(() => toast.classList.remove("is-visible"), 3000);
}

function announce(message) {
  $("#prototype-live").textContent = message;
}

function closeDialog() {
  const dialog = $("#prototype-dialog");
  if (!dialog) return;
  dialog.close();
  dialog.remove();
}

function openDialog(content, label, onBind) {
  $("#dialog-root").innerHTML = `<dialog id="prototype-dialog" class="prototype-dialog" aria-label="${label}"><div class="dialog-shell">${content}</div></dialog>`;
  const dialog = $("#prototype-dialog");
  $$('[data-close-dialog]', dialog).forEach((button) => button.addEventListener("click", closeDialog));
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) closeDialog();
  });
  dialog.showModal();
  if (onBind) onBind(dialog);
}

function openDecision(id) {
  const decision = state.decisions.find((item) => item.id === id);
  state.selectedDecision = id;
  openDialog(`
    <header class="dialog-header">
      <div>${envLabel(decision.environment)}<span>DECISION-TIME VIEW · IMMUTABLE</span><h2>${decision.subject}</h2><small>${decision.id} · ${decision.strategy}</small></div>
      <button type="button" class="icon-close" data-close-dialog aria-label="Close Decision Record">×</button>
    </header>
    <section class="dialog-state-line">${statusPill(decision.disposition, decision.tone)}${statusPill(decision.execution, decision.tone)}${statusPill(decision.outcome, decision.tone)}</section>
    <div class="dialog-columns">
      <section>
        <h3>Comparative forecast</h3>
        <dl class="detail-list">
          <div><dt>Expected P&amp;L</dt><dd>${decision.expected}</dd></div>
          <div><dt>Maximum modeled loss</dt><dd>${decision.modeledLoss}</dd></div>
          <div><dt>Required baseline</dt><dd>${decision.baseline}</dd></div>
          <div><dt>Observed so far</dt><dd>${decision.observed}</dd></div>
        </dl>
      </section>
      <section>
        <h3>Authority and evidence</h3>
        <dl class="detail-list">
          <div><dt>Decisive gate</dt><dd>${decision.gate}</dd></div>
          <div><dt>Action Attempt</dt><dd>${decision.attempt}</dd></div>
          <div><dt>Canonical evidence</dt><dd>${decision.evidence}</dd></div>
          <div><dt>Evidence status</dt><dd>${decision.correction}</dd></div>
        </dl>
      </section>
    </div>
    ${decision.outcome.includes("INDETERMINATE") ? `<section class="indeterminate-callout"><strong>Retry rule</strong><p>The original result stays indeterminate. A linked Research or Paper retry may be proposed because preserved pre-failure evidence was promising, but only after the failure is understood, contained, and priced. No automatic Live replay.</p><button type="button" data-toast-dialog="A retry would create a linked evaluation with preserved lineage and fresh Testing Budget where required.">Preview linked retry</button></section>` : ""}
    <details class="history-detail"><summary>Collapsed historical projection row</summary><p>${decision.id} × next preregistered horizon × ${decision.environment} × projection WM-8841. Exact attempts, legs, costs, gates, and artifacts remain linked; export is on demand only.</p></details>
    <footer class="dialog-footer"><span>Private chain-of-thought is not evidence. Restricted source content is explicitly redacted.</span><button type="button" class="secondary" data-close-dialog>Close</button></footer>`,
    `Decision Record ${id}`,
    (dialog) => {
      $$('[data-toast-dialog]', dialog).forEach((button) => button.addEventListener("click", () => showToast(button.dataset.toastDialog)));
    },
  );
}

function openProposal(id) {
  const proposal = state.proposals.find((item) => item.id === id);
  const actionable = !proposal.status.includes("SUPERSEDED");
  openDialog(`
    <header class="dialog-header">
      <div>${envLabel(proposal.environment)}<span>${proposal.type} · ${proposal.id}</span><h2>${proposal.title}</h2><small>Root Principal intent: ${proposal.root}</small></div>
      <button type="button" class="icon-close" data-close-dialog aria-label="Close proposal">×</button>
    </header>
    <section class="proposal-authority-change"><span>EXACT AUTHORITY CHANGE</span><strong>${proposal.change}</strong></section>
    <div class="dialog-columns">
      <section>
        <h3>Proposal contract</h3>
        <dl class="detail-list">
          <div><dt>Exact scope</dt><dd>${proposal.scope}</dd></div>
          <div><dt>Evidence bundle</dt><dd>${proposal.evidence}</dd></div>
          <div><dt>Expiry</dt><dd>${proposal.expiry}</dd></div>
          <div><dt>Cooling-off</dt><dd>${proposal.cooling}</dd></div>
          <div><dt>Authentication</dt><dd>${proposal.auth}</dd></div>
          <div><dt>Server state</dt><dd>${proposal.status}</dd></div>
        </dl>
      </section>
      <section>
        <h3>Rooted proposal graph</h3>
        <ol class="proposal-graph">
          <li><span>ROOT</span><strong>${proposal.root}</strong><small>Original Principal intent</small></li>
          ${proposal.children.map((child, index) => `<li><span>0${index + 1}</span><strong>${child}</strong><small>${index === proposal.children.length - 1 ? "This decision is never inherited from the parent" : "Evidence rolls up; authority does not"}</small></li>`).join("")}
        </ol>
      </section>
    </div>
    ${actionable ? `<section class="confirmation-block"><label><input type="checkbox" data-understand /> I understand this is a simulated review and that only the final server-authoritative result can change authority.</label><div class="button-row"><button type="button" class="secondary" data-proposal-result="REJECTED" disabled>Simulate rejection</button><button type="button" class="primary" data-proposal-result="APPROVED" disabled>Simulate approval</button></div><p data-result-line>No result submitted.</p></section>` : `<section class="superseded-callout"><strong>This proposal cannot act.</strong><p>Its previous authentication and evidence do not revive it. A new root or materially changed child requires a new exact proposal.</p></section>`}
    <footer class="dialog-footer"><span>Prototype-only local state · no authentication or authority</span><button type="button" class="secondary" data-close-dialog>Close</button></footer>`,
    `Proposal ${id}`,
    (dialog) => {
      const checkbox = $("[data-understand]", dialog);
      if (!checkbox) return;
      const resultButtons = $$('[data-proposal-result]', dialog);
      checkbox.addEventListener("change", () => resultButtons.forEach((button) => { button.disabled = !checkbox.checked; }));
      resultButtons.forEach((button) => button.addEventListener("click", () => {
        $("[data-result-line]", dialog).textContent = `SIMULATED CLIENT RESULT: ${button.dataset.proposalResult}. Awaiting server-authoritative confirmation; no authority changed.`;
        announce(`Simulated proposal result ${button.dataset.proposalResult}. No authority changed.`);
      }));
    },
  );
}

function emergencyStateList() {
  return Object.entries(state.emergencyStates).map(([key, description]) => `<button type="button" class="emergency-state-option ${state.emergencyState === key ? "is-active" : ""}" data-emergency-state="${key}"><span>${key}</span><small>${description}</small></button>`).join("");
}

function openEmergency(mode) {
  const isResume = mode === "resume";
  openDialog(`
    <header class="dialog-header emergency-dialog-head">
      <div>${envLabel("LIVE")}<span>ENVIRONMENT-SPECIFIC EMERGENCY CONTROL</span><h2>${isResume ? "Resume Live gates" : "Freeze Live verification"}</h2><small>Account …8841 · ${state.risk.LIVE.epoch}</small></div>
      <button type="button" class="icon-close" data-close-dialog aria-label="Close emergency controls">×</button>
    </header>
    <section class="emergency-truth">
      <div><span>AUTHORITATIVE RISK STATE</span><strong>${state.risk.LIVE.state}</strong><small>${state.risk.LIVE.lastReconciled}</small></div>
      <p>${state.risk.LIVE.detail}</p>
    </section>
    ${isResume ? `<section class="resume-gates"><h3>Unmet resumption gates</h3><ul><li><b>FAILED</b> Broker open-order certainty</li><li><b>PENDING</b> Exact ledger reconciliation through latest venue event</li><li><b>STALE</b> Previous fresh authentication is bound to superseded proposal PI-198</li><li><b>REQUIRED</b> Principal approval of a new exact Resume Live proposal</li></ul><button type="button" disabled>Request Resume Live — unavailable</button><p>Research, Paper, reconciliation, lifecycle management, and verified risk reduction remain available.</p></section>` : `<section class="freeze-contract"><h3>What Freeze Live means</h3><p>Block new risk-increasing Live activity, cancel eligible working orders, preserve lifecycle and risk-reducing actions, and verify broker, ledger, reservation, and Risk State independently. A local request is never reported as success.</p><label><input type="checkbox" data-freeze-understand /> I confirm the exact target is <strong>LIVE · Account …8841</strong>, not Paper.</label><button type="button" class="primary-danger" data-simulate-freeze disabled>Simulate Freeze Live request</button><p data-freeze-result>No simulated request submitted.</p></section>`}
    <section class="emergency-state-browser"><div><span>STATE WALKTHROUGH</span><h3>Inspect every possible result</h3></div><div class="emergency-state-grid">${emergencyStateList()}</div><output data-emergency-description>${state.emergencyStates[state.emergencyState]}</output></section>
    <section class="broker-runbook"><span>WHEN CONTAINMENT CANNOT BE CONFIRMED</span><strong>Broker-native emergency runbook BR-02</strong><p>Open broker directly using a separately authenticated Principal session; inspect account …8841 and order ORD-L-449; do not infer state from this prototype. Record resulting evidence back through Market Mate when service is restored.</p></section>
    <footer class="dialog-footer"><span>Comparative Paper views cannot invoke this Live control.</span><button type="button" class="secondary" data-close-dialog>Close</button></footer>`,
    `${isResume ? "Resume" : "Freeze"} Live control`,
    (dialog) => {
      const checkbox = $("[data-freeze-understand]", dialog);
      const simulate = $("[data-simulate-freeze]", dialog);
      if (checkbox && simulate) {
        checkbox.addEventListener("change", () => { simulate.disabled = !checkbox.checked; });
        simulate.addEventListener("click", () => {
          state.emergencyState = "PENDING";
          $("[data-freeze-result]", dialog).textContent = "SIMULATED CLIENT REQUEST: PENDING. Awaiting independent broker, ledger, reservation, and Risk State confirmation.";
          $$('[data-emergency-state]', dialog).forEach((button) => button.classList.toggle("is-active", button.dataset.emergencyState === "PENDING"));
          $("[data-emergency-description]", dialog).textContent = state.emergencyStates.PENDING;
          announce("Simulated Freeze Live request pending. No success claimed.");
        });
      }
      $$('[data-emergency-state]', dialog).forEach((button) => button.addEventListener("click", () => {
        state.emergencyState = button.dataset.emergencyState;
        $$('[data-emergency-state]', dialog).forEach((option) => option.classList.toggle("is-active", option === button));
        $("[data-emergency-description]", dialog).textContent = state.emergencyStates[state.emergencyState];
        announce(`Emergency result state ${state.emergencyState}`);
      }));
    },
  );
}

function acknowledgeAlert(id) {
  const alert = state.alerts.find((item) => item.id === id);
  alert.acknowledged = true;
  alert.state = "ACKNOWLEDGED IN MARKET MATE · SIMULATED";
  render();
  announce(`${alert.id} acknowledged in simulated state. Containment did not wait for acknowledgement.`);
}

function bindEvents() {
  $$('[data-cycle]').forEach((button) => button.addEventListener("click", () => cycleVariant(Number(button.dataset.cycle))));
  $$('[data-decision]').forEach((button) => button.addEventListener("click", () => openDecision(button.dataset.decision)));
  $$('[data-proposal]').forEach((button) => button.addEventListener("click", () => openProposal(button.dataset.proposal)));
  $$('[data-emergency]').forEach((button) => button.addEventListener("click", () => openEmergency(button.dataset.emergency)));
  $$('[data-alert]').forEach((button) => button.addEventListener("click", () => acknowledgeAlert(button.dataset.alert)));
  $$('[data-environment]').forEach((button) => button.addEventListener("click", () => {
    state.selectedEnvironment = button.dataset.environment;
    render();
    announce(`${state.selectedEnvironment} environment selected. All account metrics and Decision Records in the section are ${state.selectedEnvironment}.`);
  }));
  $$('[data-environment-jump]').forEach((button) => button.addEventListener("click", () => {
    state.selectedEnvironment = button.dataset.environmentJump;
    const url = new URL(window.location.href);
    url.searchParams.set("variant", "A");
    window.history.replaceState({}, "", url);
    render();
    announce(`Command Ledger opened for ${state.selectedEnvironment}.`);
  }));
  $$('[data-toast]').forEach((button) => button.addEventListener("click", () => showToast(button.dataset.toast)));
}

document.addEventListener("keydown", (event) => {
  const target = event.target;
  if (target.matches("input, textarea, select, [contenteditable='true']") || $("#prototype-dialog")) return;
  if (event.key === "ArrowLeft") cycleVariant(-1);
  if (event.key === "ArrowRight") cycleVariant(1);
});

window.addEventListener("popstate", render);
render();
