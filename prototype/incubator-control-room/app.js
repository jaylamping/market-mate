const state = {
  asOf: "22 AUG · 14:32:08 CT",
  environment: "SIMULATED RESEARCH + PAPER STATE",
  spheres: [
    { name: "Incubator", state: "Market open", detail: "164 assignments · 38 opportunities", tone: "lime" },
    { name: "Engine", state: "Nominal", detail: "p95 dispatch 4.2s", tone: "blue" },
    { name: "Sentinel", state: "Enforcing", detail: "2 denials · controls intact", tone: "amber" },
    { name: "Gateway", state: "Online", detail: "2 exact decisions queued", tone: "violet" },
  ],
  metrics: [
    { label: "Net validated profit velocity", value: "+$11.4k", unit: "expected annual net / day", delta: "+18% · 30d" },
    { label: "Validated backlog", value: "$428k", unit: "portfolio-incremental", delta: "6 survivors" },
    { label: "Median falsification", value: "3h 18m", unit: "wall-clock", delta: "−42m" },
    { label: "Research capacity", value: "86%", unit: "of approved envelope", delta: "20% mutation held" },
  ],
  desks: [
    { id: "thesis", short: "THESIS", name: "Market Intelligence & Thesis", active: 23, shots: 8, pressure: 64, posture: "76% AGG/EXT", contribution: "+$68k", state: "open", note: "Scanning regime breaks and neglected catalysts. Three new opportunities survived cheap scouts." },
    { id: "quant", short: "QUANT", name: "Quantitative Research & Experimentation", active: 31, shots: 11, pressure: 88, posture: "70% AGG/EXT", contribution: "+$144k", state: "hot", note: "Independent reproduction queue is the current critical path; two survivors are competing for a capacity tranche." },
    { id: "data", short: "DATA", name: "Data & Feature Research", active: 26, shots: 7, pressure: 72, posture: "73% AGG/EXT", contribution: "+$51k", state: "open", note: "Alternative feature family admitted. One vendor lineage is quarantined from promotion-bound work." },
    { id: "strategy", short: "BUILD", name: "Strategy Incubation", active: 28, shots: 6, pressure: 93, posture: "71% AGG/EXT", contribution: "+$112k", state: "hot", note: "Two exact Strategy Versions are freezing; neither receives Paper authority from this desk." },
    { id: "portfolio", short: "CAPITAL", name: "Portfolio & Capital Efficiency", active: 17, shots: 4, pressure: 48, posture: "65% AGG/EXT", contribution: "+$38k", state: "open", note: "Testing whether the lead survivor adds value after overlap, capital cost, and conservative aggregation." },
    { id: "execution", short: "EXEC", name: "Execution Edge & Paper Trading", active: 21, shots: 5, pressure: 78, posture: "72% AGG/EXT", contribution: "+$83k", state: "open", note: "Paper sleeve P-18 is reconciling. A second exact version awaits a Sentinel admission result." },
    { id: "challenge", short: "CHALLENGE", name: "Economic Evaluation & Challenge", active: 18, shots: 9, pressure: 81, posture: "89% SKEP/ADV", contribution: "+$27k", state: "hot", note: "Blinded reviewers are attacking cost sensitivity and evaluator independence on two dockets." },
  ],
  opportunities: [
    {
      id: "AO-184",
      rank: "01",
      name: "Opening-auction imbalance decay",
      thesis: "Auction dislocations may persist after the first print when liquidity replenishment fragments.",
      stage: "Independent reproduction",
      status: "scaling",
      probability: 84,
      contribution: "+$126k",
      cost: "$3.8k",
      clock: "07:42",
      lease: "4 leases",
      swarm: ["Mako · Aggressive", "Voltage · Aggressive", "Witching Hour · Extreme", "Null · Skeptical"],
      dissent: "Cost edge collapses above 1.7× median spread; targeted recheck in progress.",
      artifact: "REPRO-184-C · sealed 14:28",
    },
    {
      id: "AO-219",
      rank: "02",
      name: "Cross-venue quote exhaustion",
      thesis: "Venue-specific depletion may lead consolidated price response over sub-minute horizons.",
      stage: "Swarm",
      status: "running",
      probability: 67,
      contribution: "+$91k",
      cost: "$2.1k",
      clock: "01:18",
      lease: "4 leases",
      swarm: ["Sparks · Aggressive", "Rook · Aggressive", "Bad Idea Dept. · Extreme", "Brake · Skeptical"],
      dissent: "Potential shared feature failure path across two proponents.",
      artifact: "KILL-219-A · challenge admitted 14:31",
    },
    {
      id: "AO-207",
      rank: "03",
      name: "Regime-conditioned residual reversal",
      thesis: "Residual reversal may survive costs only during constrained volatility/liquidity regimes.",
      stage: "Strategy incubation",
      status: "hold",
      probability: 58,
      contribution: "+$74k",
      cost: "$6.4k",
      clock: "18:46",
      lease: "6 leases",
      swarm: ["Tremor · Aggressive", "Sidecar · Balanced", "Acid Test · Adversarial"],
      dissent: "Portfolio overlap estimate is unresolved; no capacity scale until discriminating test lands.",
      artifact: "DISSENT-207-P · immutable 13:56",
    },
    {
      id: "AO-233",
      rank: "04",
      name: "Cash–futures basis micro-window",
      thesis: "Short-lived basis normalization may remain after realistic queue and hedge latency.",
      stage: "Seed",
      status: "mutation",
      probability: 31,
      contribution: "+$39k",
      cost: "$0.6k",
      clock: "00:24",
      lease: "1 lease",
      swarm: ["Gremlin · Extreme"],
      dissent: "Wildcard shot; no independent evidence yet.",
      artifact: "SHOT-233-01 · checkpoint due 14:44",
    },
    {
      id: "AO-176",
      rank: "05",
      name: "Surface dislocation after macro release",
      thesis: "Relative surface repricing may lag after scheduled macro shocks.",
      stage: "Paper qualification",
      status: "sentinel",
      probability: 81,
      contribution: "+$98k",
      cost: "$8.2k",
      clock: "42:11",
      lease: "3 leases",
      swarm: ["Mako · Aggressive", "Ledgerless · Aggressive", "Hammer · Adversarial"],
      dissent: "Economic dissent resolved; exact bundle is at external control admission.",
      artifact: "PQB-SV176.4 · hash 91f…c02",
    },
  ],
  artifacts: [
    { time: "14:31:52", type: "KILL CLAIM", id: "KILL-219-A", title: "Shared feature dependency may invalidate independence", lane: "Challenge", impact: "AO-219 held at Swarm pending targeted recheck", tone: "red" },
    { time: "14:30:17", type: "WORK LEASE", id: "WL-233-01", title: "Extreme mutation admitted for basis micro-window", lane: "Engine", impact: "$600 · 20m checkpoint · stop at $1.2k", tone: "violet" },
    { time: "14:28:04", type: "REPRODUCTION", id: "REPRO-184-C", title: "Third failure path reproduces after-cost edge", lane: "Quant", impact: "P(positive net) 84% · capacity scale eligible", tone: "lime" },
    { time: "14:22:39", type: "SENTINEL DENIAL", id: "DEN-176-02", title: "Paper scope narrowed: venue entitlement absent", lane: "Sentinel", impact: "Bundle preserved · revised scope may re-enter", tone: "amber" },
    { time: "14:18:11", type: "MATERIAL DISSENT", id: "DISSENT-207-P", title: "Portfolio overlap could erase 38–61% of contribution", lane: "Capital", impact: "One discriminating test funded · 5h remaining", tone: "red" },
    { time: "14:12:43", type: "CAPACITY RELEASE", id: "PREEMPT-198", title: "Weak descendant stopped below 20% threshold", lane: "Engine", impact: "18.4 compute-hours returned to Alpha Market", tone: "blue" },
    { time: "14:04:20", type: "STRATEGY FREEZE", id: "SV-194.7", title: "Exact behavior frozen for qualification", lane: "Build", impact: "No authority · evidence docket assembling", tone: "cyan" },
  ],
  attention: [
    {
      id: "CAP-204",
      kind: "SPEND + CAPACITY",
      urgency: "Decision · expires in 06:14",
      title: "Add a second independent reproduction provider",
      ask: "$18,000 / month · 30-day trial · hard cap",
      why: "Six profitable survivors are queued behind an independence bottleneck. Matched trial forecasts +$31k expected annual net contribution per wall-clock day.",
      boundary: "No new data entitlement or trading authority. Automatic rollback at 80% probability of harm.",
      evidence: "12 comparable cohorts · 82% P(net positive) · $54k maximum trial spend",
      tone: "violet",
    },
    {
      id: "AUTH-119",
      kind: "PAPER SCOPE",
      urgency: "Decision · bundled review",
      title: "Extend approved Paper instrument scope",
      ask: "Add 9 index-option series · expires after 21 days",
      why: "SV-176.4 passed economic review, but Sentinel correctly denied the current bundle because its venue entitlement does not cover the requested scope.",
      boundary: "Paper only. Exact Strategy Version and capital envelope remain unchanged. Rejection does not stop Research.",
      evidence: "Immutable proposal · Sentinel checks 14/15 passing · entitlement is sole unmet gate",
      tone: "amber",
    },
  ],
  incidents: [
    { id: "INC-044", state: "CONTAINED", title: "Correlated provider outputs", scope: "11 assignments · 2 evidence closures", mode: "Provider isolated", next: "25% restoration check 15:00" },
    { id: "INC-039", state: "RECOVERING", title: "Paper ledger reconciliation lag", scope: "Sleeve P-18 only", mode: "Paper containment only", next: "Exact reconciliation 14:38" },
  ],
  paper: [
    { id: "SV-176.4", name: "Macro surface lag", state: "SENTINEL DENIED", detail: "scope revision available", tone: "amber" },
    { id: "SV-188.2", name: "Auction refill", state: "EVIDENCE ARENA", detail: "19h review clock", tone: "cyan" },
    { id: "SV-161.9", name: "Residual hedge", state: "PAPER ACTIVE", detail: "grant 09h 44m", tone: "lime" },
  ],
};

const variants = [
  { key: "A", name: "Floor Map", render: VariantA },
  { key: "B", name: "Opportunity Tape", render: VariantB },
  { key: "C", name: "Principal Lens", render: VariantC },
];

const icon = {
  incubator: "◉",
  engine: "⌁",
  sentinel: "⬡",
  gateway: "◇",
  arrow: "↗",
};

function metricCards() {
  return state.metrics
    .map(
      (metric, index) => `
        <article class="metric-card metric-${index + 1}">
          <span>${metric.label}</span>
          <strong>${metric.value}</strong>
          <small>${metric.unit}</small>
          <em>${metric.delta}</em>
        </article>`,
    )
    .join("");
}

function sphereList(active = "Incubator") {
  return state.spheres
    .map(
      (sphere) => `
        <li class="sphere-item ${sphere.name === active ? "is-active" : ""}">
          <span class="sphere-icon tone-${sphere.tone}">${icon[sphere.name.toLowerCase()]}</span>
          <div>
            <strong>${sphere.name}</strong>
            <span>${sphere.state}</span>
            <small>${sphere.detail}</small>
          </div>
        </li>`,
    )
    .join("");
}

function deskCards() {
  return state.desks
    .map(
      (desk) => `
        <button class="desk-card state-${desk.state}" type="button" data-desk="${desk.id}">
          <span class="desk-kicker">${desk.short}</span>
          <strong>${desk.name}</strong>
          <div class="desk-stats">
            <span><b>${desk.active}</b> active</span>
            <span><b>${desk.shots}</b> shots</span>
          </div>
          <div class="pressure-bar"><i style="width: ${desk.pressure}%"></i></div>
          <div class="desk-footer"><span>${desk.posture}</span><b>${desk.contribution}</b></div>
        </button>`,
    )
    .join("");
}

function opportunityDetail(opportunity = state.opportunities[0]) {
  return `
    <div class="detail-heading">
      <div><span>${opportunity.id} · ${opportunity.stage}</span><h3>${opportunity.name}</h3></div>
      <strong class="probability">${opportunity.probability}%<small>P(net +)</small></strong>
    </div>
    <p class="detail-thesis">${opportunity.thesis}</p>
    <div class="detail-grid">
      <div><span>Contribution</span><strong>${opportunity.contribution}</strong></div>
      <div><span>Spent</span><strong>${opportunity.cost}</strong></div>
      <div><span>Wall clock</span><strong>${opportunity.clock}</strong></div>
      <div><span>Competition</span><strong>${opportunity.lease}</strong></div>
    </div>
    <div class="swarm-line">${opportunity.swarm.map((member) => `<span>${member}</span>`).join("")}</div>
    <div class="dissent-line"><b>Material dissent</b><span>${opportunity.dissent}</span></div>
    <footer><span>Latest admitted artifact</span><strong>${opportunity.artifact}</strong></footer>`;
}

function VariantA() {
  return `
    <div class="variant variant-a">
      <aside class="a-sidebar">
        <a class="brand brand-dark" href="?variant=A" aria-label="Market Mate prototype home">
          <span class="brand-mark">MM</span><span>MARKET MATE<small>CONTROL PLANE</small></span>
        </a>
        <p class="nav-label">Four spheres</p>
        <ul class="sphere-list">${sphereList()}</ul>
        <div class="view-contract">
          <span>VIEW CONTRACT</span>
          <strong>Artifacts over chatter</strong>
          <p>Agent messages, tool traces, and token streams stay hidden. Controls and decisions stay immutable.</p>
        </div>
      </aside>

      <section class="a-workspace">
        <header class="a-header">
          <div><span class="eyebrow">INCUBATOR / FLOOR</span><h1>Research market is open.</h1></div>
          <div class="header-state"><span class="pulse-dot"></span><strong>ACCELERATED</strong><small>${state.asOf}</small></div>
        </header>
        <div class="environment-banner"><span>${state.environment}</span><b>No Live authority</b></div>
        <section class="a-metrics" aria-label="Incubator metrics">${metricCards()}</section>

        <div class="a-main-grid">
          <section class="floor-panel panel-dark">
            <div class="panel-heading">
              <div><span>MANAGERLESS TOPOLOGY</span><h2>Seven economic desks</h2></div>
              <div class="posture-mix"><i></i><span><b>70%</b> attack</span><span><b>20%</b> challenge</span><span><b>10%</b> verify</span></div>
            </div>
            <div class="floor-canvas">
              <div class="floor-lines" aria-hidden="true"></div>
              <div class="desk-grid">${deskCards()}</div>
              <div class="alpha-market-core"><span>ALPHA MARKET</span><strong>38</strong><small>open opportunities</small></div>
            </div>
          </section>

          <aside class="a-attention panel-light">
            <div class="panel-heading compact"><div><span>GATEWAY</span><h2>Needs the Principal</h2></div><b>2</b></div>
            ${state.attention
              .map(
                (item) => `<button class="attention-row" type="button" data-prototype-action="${item.id}">
                  <span class="attention-kind tone-${item.tone}">${item.kind}</span>
                  <strong>${item.title}</strong><small>${item.ask}</small>
                  <footer><span>${item.urgency}</span><b>${icon.arrow}</b></footer>
                </button>`,
              )
              .join("")}
            <div class="external-control">
              <span>${icon.sentinel} SENTINEL · EXTERNAL</span>
              <strong>Controls intact</strong>
              <p>2 denials preserved. Nothing inside the Incubator can negotiate or override them.</p>
            </div>
          </aside>

          <section class="a-detail panel-dark" data-detail-panel>${opportunityDetail()}</section>

          <section class="a-incidents panel-light">
            <div class="panel-heading compact"><div><span>ENGINE ROUTING</span><h2>Contained, still moving</h2></div><b>2</b></div>
            ${state.incidents
              .map(
                (incident) => `<article class="incident-row"><span>${incident.state}</span><div><strong>${incident.title}</strong><small>${incident.scope} · ${incident.mode}</small></div><b>${incident.next}</b></article>`,
              )
              .join("")}
          </section>
        </div>
      </section>
    </div>`;
}

function VariantB() {
  return `
    <div class="variant variant-b">
      <header class="b-header">
        <a class="brand brand-terminal" href="?variant=B"><span class="brand-mark">M/</span><span>ALPHA MARKET</span></a>
        <div class="terminal-status"><span>INCUBATOR: OPEN</span><span>ENGINE: NOMINAL</span><span>SENTINEL: ENFORCING</span><span>GATEWAY: 2</span></div>
        <div class="b-time"><strong>14:32</strong><span>22 AUG 2026 · CT</span></div>
      </header>
      <div class="b-warning"><span>${state.environment}</span><span>READ: ADMITTED ARTIFACTS</span><span>RAW CHAT: HIDDEN</span><b>LIVE: UNREACHABLE</b></div>

      <main class="b-shell">
        <aside class="market-book">
          <div class="terminal-title"><div><span>01</span><h1>Opportunity book</h1></div><small>Ranked by marginal economic value · not agent status</small></div>
          <div class="book-columns"><span>ID / OPPORTUNITY</span><span>P+</span><span>STAGE</span></div>
          <div class="opportunity-book">
            ${state.opportunities
              .map(
                (opportunity, index) => `<button type="button" class="book-row ${index === 0 ? "is-selected" : ""}" data-opportunity="${opportunity.id}">
                  <span class="rank">${opportunity.rank}</span>
                  <span class="book-name"><b>${opportunity.id}</b><strong>${opportunity.name}</strong><small>${opportunity.lease} · ${opportunity.clock}</small></span>
                  <span class="book-prob">${opportunity.probability}<i>%</i></span>
                  <span class="stage-tag status-${opportunity.status}">${opportunity.stage}</span>
                </button>`,
              )
              .join("")}
          </div>
          <section class="book-detail" data-detail-panel>${opportunityDetail()}</section>
        </aside>

        <section class="artifact-tape">
          <div class="terminal-title"><div><span>02</span><h2>Economic artifact tape</h2></div><small>Every row changes state; no activity theater</small></div>
          <div class="tape-head"><span>TIME</span><span>TYPE / ARTIFACT</span><span>ECONOMIC EFFECT</span></div>
          <div class="tape-list">
            ${state.artifacts
              .map(
                (artifact) => `<article class="tape-row tone-border-${artifact.tone}">
                  <time>${artifact.time}</time>
                  <div><span>${artifact.type} · ${artifact.id}</span><strong>${artifact.title}</strong><small>${artifact.lane}</small></div>
                  <p>${artifact.impact}</p>
                </article>`,
              )
              .join("")}
          </div>
          <div class="diagnostic-strip">
            <article><span>PROFIT</span><strong>+$428k</strong><small>incremental backlog</small></article>
            <article><span>VELOCITY</span><strong>3h 18m</strong><small>median falsification</small></article>
            <article><span>RELIABILITY</span><strong>74%</strong><small>reproduction survival</small></article>
            <article><span>COST + FRICTION</span><strong>$1.9k</strong><small>per resolved thesis</small></article>
          </div>
        </section>

        <aside class="b-rail">
          <section class="rail-block gateway-block">
            <div class="rail-heading"><span>03</span><div><strong>Gateway queue</strong><small>Exact decisions only</small></div><b>2</b></div>
            ${state.attention
              .map(
                (item) => `<button type="button" class="rail-decision" data-prototype-action="${item.id}"><span>${item.id} · ${item.kind}</span><strong>${item.title}</strong><small>${item.urgency}</small><b>${icon.arrow}</b></button>`,
              )
              .join("")}
          </section>
          <section class="rail-block pressure-block">
            <div class="rail-heading"><span>04</span><div><strong>Queue pressure</strong><small>Engine allocation</small></div></div>
            ${state.desks
              .slice()
              .sort((a, b) => b.pressure - a.pressure)
              .slice(0, 5)
              .map((desk) => `<div class="pressure-row"><span>${desk.short}</span><i><b style="width:${desk.pressure}%"></b></i><strong>${desk.pressure}</strong></div>`)
              .join("")}
          </section>
          <section class="rail-block paper-block">
            <div class="rail-heading"><span>05</span><div><strong>Paper boundary</strong><small>Exact versions</small></div></div>
            ${state.paper.map((item) => `<div class="paper-row"><span class="tone-${item.tone}">●</span><div><strong>${item.id}</strong><small>${item.name}</small></div><b>${item.state}</b></div>`).join("")}
          </section>
        </aside>
      </main>
    </div>`;
}

function decisionCard(item, index) {
  return `
    <article class="decision-card tone-edge-${item.tone}">
      <header><span>${String(index + 1).padStart(2, "0")} · ${item.kind}</span><b>${item.urgency}</b></header>
      <h2>${item.title}</h2>
      <p class="decision-ask">${item.ask}</p>
      <div class="decision-reason"><span>WHY NOW</span><p>${item.why}</p></div>
      <dl><div><dt>Immutable boundary</dt><dd>${item.boundary}</dd></div><div><dt>Evidence</dt><dd>${item.evidence}</dd></div></dl>
      <footer>
        <button type="button" class="secondary-button" data-prototype-action="inspect-${item.id}">Inspect exact proposal</button>
        <button type="button" class="primary-button" data-prototype-action="decide-${item.id}">Review decision</button>
      </footer>
    </article>`;
}

function VariantC() {
  return `
    <div class="variant variant-c">
      <header class="c-header">
        <a class="brand brand-light" href="?variant=C"><span class="brand-mark">M</span><span>Market Mate<small>Principal Gateway</small></span></a>
        <div class="c-header-center"><span class="healthy-dot"></span><strong>Autonomy healthy</strong><small>Last immutable update ${state.asOf}</small></div>
        <button class="principal-avatar" type="button" data-prototype-action="principal-profile"><span>JL</span><small>Principal</small></button>
      </header>

      <main class="c-main">
        <section class="c-intro">
          <div><span class="eyebrow">YOUR ATTENTION</span><h1>Two decisions. The floor keeps moving.</h1><p>Ordinary competition, failures, stalls, and reallocations stay autonomous. Gateway interrupts only when your exact authority is required.</p></div>
          <div class="attention-clock"><span>NEXT BUNDLE</span><strong>06:14</strong><small>one decision is time-sensitive</small></div>
        </section>

        <section class="decision-stack" aria-label="Principal decisions">
          ${state.attention.map(decisionCard).join("")}
        </section>

        <section class="autonomy-section">
          <div class="section-heading"><div><span>READ-ONLY PULSE</span><h2>What is happening without you</h2></div><button type="button" class="text-button" data-prototype-action="open-floor">Open full floor <b>↗</b></button></div>
          <div class="pulse-grid">
            <article class="autonomy-map">
              <div class="sphere-orbit">
                <div class="orbit-ring ring-outer"></div><div class="orbit-ring ring-inner"></div>
                <div class="orbit-node node-incubator"><span>INCUBATOR</span><strong>164</strong><small>assignments</small></div>
                <div class="orbit-node node-engine"><span>ENGINE</span><strong>4.2s</strong><small>p95 dispatch</small></div>
                <div class="orbit-node node-sentinel"><span>SENTINEL</span><strong>2</strong><small>denials held</small></div>
                <div class="orbit-node node-gateway"><span>GATEWAY</span><strong>2</strong><small>decisions</small></div>
                <div class="orbit-core"><strong>+$11.4k</strong><span>NET VALIDATED<br />PROFIT VELOCITY</span></div>
              </div>
            </article>
            <article class="autonomy-summary">
              <header><div><span>INCUBATOR</span><h3>Aggressive by default</h3></div><b>70 / 20 / 10</b></header>
              <div class="mix-bar"><i></i><i></i><i></i></div>
              <div class="summary-stats"><div><span>Open opportunities</span><strong>38</strong></div><div><span>Mutation reserve</span><strong>20%</strong></div><div><span>Validated survivors</span><strong>6</strong></div><div><span>Paper active</span><strong>1</strong></div></div>
              <p>No manager queue. Engine clears the Alpha Market; Sentinel remains outside it.</p>
            </article>
            <article class="exceptions-summary">
              <header><span>MATERIAL EXCEPTIONS</span><b>2 contained</b></header>
              ${state.incidents
                .map((incident) => `<div class="exception-row"><span>${incident.state}</span><div><strong>${incident.title}</strong><small>${incident.scope}</small></div><b>${incident.next}</b></div>`)
                .join("")}
              <footer><span>Gateway interruption policy</span><strong>No action required</strong></footer>
            </article>
          </div>
        </section>

        <section class="c-paper">
          <div class="section-heading"><div><span>IMMUTABLE BOUNDARY</span><h2>Research → exact Paper versions</h2></div><span class="paper-note">No shortcut to Live</span></div>
          <div class="paper-track">
            ${state.paper
              .map((item, index) => `<article><span class="track-index">0${index + 1}</span><div><strong>${item.id} · ${item.name}</strong><small>${item.detail}</small></div><b class="tone-${item.tone}">${item.state}</b></article>`)
              .join("")}
          </div>
        </section>
      </main>
      <footer class="c-footer"><span>${state.environment}</span><span>Raw agent chatter remains hidden</span><span>Controls and decisions are immutable</span></footer>
    </div>`;
}

function showToast(message = "Prototype only — no canonical state or authorization was changed.") {
  const toast = document.querySelector("#prototype-toast");
  toast.textContent = message;
  toast.classList.add("is-visible");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("is-visible"), 2800);
}

function bindInteractions() {
  document.querySelectorAll("[data-opportunity]").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll("[data-opportunity]").forEach((row) => row.classList.remove("is-selected"));
      button.classList.add("is-selected");
      const selected = state.opportunities.find((opportunity) => opportunity.id === button.dataset.opportunity);
      const panel = document.querySelector("[data-detail-panel]");
      if (panel && selected) panel.innerHTML = opportunityDetail(selected);
    });
  });

  document.querySelectorAll("[data-desk]").forEach((button) => {
    button.addEventListener("click", () => {
      const desk = state.desks.find((item) => item.id === button.dataset.desk);
      if (!desk) return;
      document.querySelectorAll("[data-desk]").forEach((card) => card.classList.remove("is-selected"));
      button.classList.add("is-selected");
      const panel = document.querySelector("[data-detail-panel]");
      if (panel) {
        panel.innerHTML = `<div class="desk-detail-kicker">DESK ROUTE · ${desk.short}</div><h3>${desk.name}</h3><p class="detail-thesis">${desk.note}</p><div class="detail-grid"><div><span>Assignments</span><strong>${desk.active}</strong></div><div><span>Alpha shots</span><strong>${desk.shots}</strong></div><div><span>Queue pressure</span><strong>${desk.pressure}</strong></div><div><span>Attributed backlog</span><strong>${desk.contribution}</strong></div></div><footer><span>Invariant</span><strong>Routing lane only · no manager · no authority</strong></footer>`;
      }
    });
  });

  document.querySelectorAll("[data-prototype-action]").forEach((button) => {
    button.addEventListener("click", () => showToast());
  });
}

function getVariant() {
  const key = new URLSearchParams(window.location.search).get("variant")?.toUpperCase();
  return variants.find((variant) => variant.key === key) ?? variants[0];
}

function render() {
  const variant = getVariant();
  document.querySelector("#app").innerHTML = variant.render();
  document.querySelector("[data-variant-label]").textContent = `${variant.key} — ${variant.name}`;
  document.title = `${variant.key} — ${variant.name} · Market Mate Prototype`;
  bindInteractions();
  window.scrollTo({ top: 0, behavior: "instant" });
}

function cycleVariant(direction) {
  const current = getVariant();
  const currentIndex = variants.findIndex((variant) => variant.key === current.key);
  const nextIndex = (currentIndex + direction + variants.length) % variants.length;
  const url = new URL(window.location.href);
  url.searchParams.set("variant", variants[nextIndex].key);
  window.history.replaceState({}, "", url);
  render();
}

document.querySelectorAll("[data-direction]").forEach((button) => {
  button.addEventListener("click", () => cycleVariant(button.dataset.direction === "next" ? 1 : -1));
});

window.addEventListener("keydown", (event) => {
  const active = document.activeElement;
  const isEditing = active?.matches("input, textarea, [contenteditable='true']");
  if (isEditing || !["ArrowLeft", "ArrowRight"].includes(event.key)) return;
  event.preventDefault();
  cycleVariant(event.key === "ArrowRight" ? 1 : -1);
});

window.addEventListener("popstate", render);

// This switcher is a local review tool and is suppressed anywhere that is not a local prototype host.
const isLocalPrototype = ["", "localhost", "127.0.0.1"].includes(window.location.hostname);
document.querySelector("#prototype-switcher").hidden = !isLocalPrototype;

render();
