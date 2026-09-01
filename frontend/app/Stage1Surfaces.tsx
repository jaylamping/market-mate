export type NotRecorded = {
  recorded: false;
  state: "not_recorded";
  detail: string;
};

export type Qualification =
  | NotRecorded
  | {
      recorded: true;
      status: "passed" | "failed";
      strategy_version_digest: string;
      window_count: number;
      eis: number;
      eis_floor: number;
      meets_eis_floor: boolean;
      lcb_vs_cash_bps: number;
      lcb_vs_sp500_bps: number | null;
      sp500_comparator_required: boolean;
      meets_cash_floor: boolean;
      meets_sp500_floor: boolean | null;
      net_mean_return_bps: number;
      failure_reasons: string[];
      result_digest: string;
      as_of: string;
      receipt_time: string;
    };

export type Cost =
  | NotRecorded
  | {
      recorded: true;
      envelope_key: string;
      register: {
        entries: number;
        monthly_spent_cents: string;
        year_one_spent_cents: string;
        monthly_state: string;
        year_one_state: string;
        monthly_hard_ceiling_cents: string;
        year_one_hard_ceiling_cents: string;
      };
      as_of: string;
    };

export type CostModel =
  | NotRecorded
  | {
      recorded: true;
      model_key: string;
      vendor_set_key: string;
      within_caps: boolean;
      required_decision: string | null;
      monthly_projected_cents: number;
      year_one_projected_cents: number;
      monthly_escalation: string;
      year_one_escalation: string;
      monthly_hard_ceiling_cents: number;
      year_one_hard_ceiling_cents: number;
      as_of: string;
    };

export type Stage1SurfacesModel = {
  environment: "local_research";
  order_authority: false;
  checkpoints_verified: boolean;
  stage: {
    badge: string;
    stage: 1;
    name: string;
    display_only: true;
    order_authority: "none";
  };
  qualification: Qualification;
  cost: Cost;
  cost_model: CostModel;
  snapshots: {
    recorded: boolean;
    manifest_count: number;
    snapshot_count: number;
    latest_manifests: Array<{
      cycle_key: string;
      cycle_kind: string;
      cycle_as_of: string;
      expected_snapshot_count: number;
      completed_snapshot_count: number;
      completion_state: string;
      evidence_state: string;
    }>;
  };
  checkpoint_pack: {
    recorded: boolean;
    checkpoint_count: number;
    verified_position: number | null;
    head_position: number | null;
    pending_events: number | null;
    state:
      | "CHECKPOINT UNVERIFIED"
      | "CHECKPOINT PENDING"
      | "CHECKPOINT VERIFIED";
  };
};

function toneFor(state: string): string {
  if (state === "CHECKPOINT VERIFIED" || state === "passed" || state === "ok") {
    return "tone-good";
  }
  if (
    state === "CHECKPOINT UNVERIFIED" ||
    state === "failed" ||
    state === "exceeded"
  ) {
    return "tone-danger";
  }
  return "tone-warn";
}

function money(cents: string | number): string {
  return `$${(Number(cents) / 100).toFixed(2)}`;
}

function NotRecordedMessage({ detail }: { detail: string }) {
  return (
    <p className="empty" data-recorded="false">
      {detail}
    </p>
  );
}

export function Stage1Surfaces({ surfaces }: { surfaces: Stage1SurfacesModel }) {
  const qualification = surfaces.qualification;
  const cost = surfaces.cost;
  const costModel = surfaces.cost_model;
  const pack = surfaces.checkpoint_pack;
  const trusted = surfaces.checkpoints_verified && pack.state === "CHECKPOINT VERIFIED";

  return (
    <div
      id="stage1-surfaces"
      className="variant-a"
      data-environment={surfaces.environment}
      data-order-authority={surfaces.stage.order_authority}
      data-display-only="true"
      data-checkpoints-verified={String(surfaces.checkpoints_verified)}
      data-trusted={String(trusted)}
    >
      <aside className="command-sidebar" aria-label="Dashboard views">
        <div className="brand-sidebar">
          <strong>MARKET MATE</strong>
          <small>STAGE-1 SURFACES</small>
        </div>
        <nav aria-label="Control room views">
          <a href="/" className="side-nav-button">
            <span>01</span>
            <strong>Home / Dashboard</strong>
            <small>system truth + tape</small>
          </a>
          <div className="side-nav-button is-active">
            <span>02</span>
            <strong>Stage-1 surfaces</strong>
            <small>qualification + evidence</small>
          </div>
        </nav>
        <div className="sidebar-foot">
          <span className="env-label">LOCAL RESEARCH</span>
          <strong>Zero order authority</strong>
          <small>
            Display-only surfaces. Read-only, localhost-bound, and unable to
            submit orders or write evidence.
          </small>
        </div>
      </aside>

      <main id="command-main" className="command-main" tabIndex={-1}>
        <header className="command-header">
          <div>
            <span className="eyebrow">STAGE-1 SURFACES / DISPLAY ONLY</span>
            <h1>Qualification, cost, and custody at a glance.</h1>
          </div>
          <div className="header-status">
            <strong>{surfaces.environment}</strong>
            <small>Read-only / localhost-bound / zero order authority</small>
          </div>
        </header>

        <section
          id="stage-badge"
          className={`truth-bar${trusted ? "" : " is-distrusted"}`}
          data-stage={surfaces.stage.stage}
          data-display-only="true"
          data-order-authority="none"
        >
          <div>
            <span className="env-label">{surfaces.stage.badge}</span>
          </div>
          <p>
            {trusted
              ? "Checkpoint-verified stage-1 evidence. This surface is display-only."
              : pack.state === "CHECKPOINT PENDING"
                ? "Signed checkpoints verify, but newer material evidence is pending custody coverage. All projected evidence is displayed as untrusted."
                : "Checkpoints are not verified. All projected evidence is displayed as untrusted."}
          </p>
          <dl>
            <div>
              <dt>Surface</dt>
              <dd>display-only</dd>
            </div>
            <div>
              <dt>Authority</dt>
              <dd>none</dd>
            </div>
          </dl>
        </section>

        <div className="surface-grid">
          <section
            id="qualification-progress"
            className={`command-section surface-wide${trusted ? "" : " is-distrusted"}`}
            data-trusted={String(trusted)}
            data-recorded={String(qualification.recorded)}
            data-status={qualification.recorded ? qualification.status : qualification.state}
          >
            <div className="section-title">
              <div>
                <span>RESEARCH QUALIFICATION</span>
                <h2>Qualification progress</h2>
              </div>
              {qualification.recorded ? (
                <span className={`status-pill ${toneFor(qualification.status)}`}>
                  {qualification.status}
                </span>
              ) : (
                <b>0 reports</b>
              )}
            </div>
            {qualification.recorded ? (
              <table className="surface-table">
                <tbody>
                  <tr data-gate="windows">
                    <th>Walk-forward windows</th>
                    <td>{qualification.window_count} / 3 minimum</td>
                  </tr>
                  <tr data-gate="eis">
                    <th>EIS vs floor</th>
                    <td data-meets={String(qualification.meets_eis_floor)}>
                      {qualification.eis} / {qualification.eis_floor}
                      <span
                        className={`status-pill ${qualification.meets_eis_floor ? "tone-good" : "tone-danger"}`}
                      >
                        {qualification.meets_eis_floor ? "MEETS FLOOR" : "BELOW FLOOR"}
                      </span>
                    </td>
                  </tr>
                  <tr data-gate="lcb_cash">
                    <th>LCB vs cash</th>
                    <td data-meets={String(qualification.meets_cash_floor)}>
                      {qualification.lcb_vs_cash_bps} bps / floor 0
                    </td>
                  </tr>
                  <tr data-gate="lcb_sp500">
                    <th>LCB vs S&amp;P 500</th>
                    <td data-meets={String(qualification.meets_sp500_floor)}>
                      {qualification.sp500_comparator_required
                        ? `${qualification.lcb_vs_sp500_bps} bps / hard floor 0`
                        : "not applicable"}
                    </td>
                  </tr>
                  <tr>
                    <th>Net mean return</th>
                    <td>{qualification.net_mean_return_bps} bps</td>
                  </tr>
                  <tr><th>Report as of</th><td>{qualification.as_of}</td></tr>
                </tbody>
              </table>
            ) : (
              <NotRecordedMessage detail={qualification.detail} />
            )}
          </section>

          <section
            id="checkpoint-pack"
            className={`command-section${trusted ? "" : " is-distrusted"}`}
            data-trusted={String(trusted)}
            data-state={pack.state}
            data-recorded={String(pack.recorded)}
          >
            <div className="section-title">
              <div>
                <span>CHECKPOINT PACK</span>
                <h2>Custody coverage</h2>
              </div>
              <span className={`status-pill ${toneFor(pack.state)}`}>{pack.state}</span>
            </div>
            <dl className="surface-list">
              <div><dt>Checkpoints</dt><dd>{pack.checkpoint_count}</dd></div>
              <div><dt>Verified position</dt><dd>{pack.verified_position ?? "none"}</dd></div>
              <div><dt>Chain head</dt><dd>{pack.head_position ?? "none"}</dd></div>
              <div><dt>Pending events</dt><dd>{pack.pending_events ?? "unverified"}</dd></div>
            </dl>
          </section>

          <section
            id="cost-vs-caps"
            className={`command-section surface-wide${trusted ? "" : " is-distrusted"}`}
            data-trusted={String(trusted)}
            data-recorded={String(cost.recorded || costModel.recorded)}
            data-within-caps={costModel.recorded ? String(costModel.within_caps) : ""}
          >
            <div className="section-title">
              <div>
                <span>OPERATING COSTS</span>
                <h2>Cost vs caps</h2>
              </div>
              {costModel.recorded ? (
                <span className={`status-pill ${costModel.within_caps ? "tone-good" : "tone-danger"}`}>
                  {costModel.within_caps ? "WITHIN CAPS" : "OVER CAPS"}
                </span>
              ) : (
                <b>no model</b>
              )}
            </div>
            {cost.recorded ? (
              <table className="surface-table">
                <tbody>
                  <tr><th>Envelope</th><td>{cost.envelope_key}</td></tr>
                  <tr><th>Register as of</th><td>{cost.as_of}</td></tr>
                  <tr data-surface="register-month">
                    <th>Registered month</th>
                    <td data-state={cost.register.monthly_state}>
                      {money(cost.register.monthly_spent_cents)} / {money(cost.register.monthly_hard_ceiling_cents)}
                    </td>
                  </tr>
                  <tr data-surface="register-year">
                    <th>Registered year one</th>
                    <td data-state={cost.register.year_one_state}>
                      {money(cost.register.year_one_spent_cents)} / {money(cost.register.year_one_hard_ceiling_cents)}
                    </td>
                  </tr>
                  {costModel.recorded ? (
                    <>
                      <tr data-surface="model-month">
                        <th>Projected month</th>
                        <td data-escalation={costModel.monthly_escalation}>
                          {money(costModel.monthly_projected_cents)} / {money(costModel.monthly_hard_ceiling_cents)}
                        </td>
                      </tr>
                      <tr><th>Model as of</th><td>{costModel.as_of}</td></tr>
                      <tr data-surface="model-year">
                        <th>Projected year one</th>
                        <td data-escalation={costModel.year_one_escalation}>
                          {money(costModel.year_one_projected_cents)} / {money(costModel.year_one_hard_ceiling_cents)}
                        </td>
                      </tr>
                      <tr>
                        <th>Required decision</th>
                        <td data-required-decision={costModel.required_decision ?? ""}>
                          {costModel.required_decision ?? "none"}
                        </td>
                      </tr>
                    </>
                  ) : null}
                </tbody>
              </table>
            ) : (
              <NotRecordedMessage detail={cost.detail} />
            )}
          </section>

          <section
            id="snapshot-browser"
            className={`command-section surface-full${trusted ? "" : " is-distrusted"}`}
            data-trusted={String(trusted)}
            tabIndex={0}
            data-recorded={String(surfaces.snapshots.recorded)}
            data-manifest-count={surfaces.snapshots.manifest_count}
          >
            <div className="section-title">
              <div>
                <span>RESEARCH SNAPSHOTS</span>
                <h2>Snapshot browser</h2>
              </div>
              <b>{surfaces.snapshots.manifest_count} cycles</b>
            </div>
            {surfaces.snapshots.recorded ? (
              <table className="surface-table">
                <caption>Latest research cycle manifests</caption>
                <thead>
                  <tr><th>Cycle</th><th>Kind</th><th>As of</th><th>Completion</th><th>Evidence</th></tr>
                </thead>
                <tbody>
                  {surfaces.snapshots.latest_manifests.map((manifest) => (
                    <tr
                      key={manifest.cycle_key}
                      data-cycle-key={manifest.cycle_key}
                      data-completion-state={manifest.completion_state}
                    >
                      <td>{manifest.cycle_key}</td>
                      <td>{manifest.cycle_kind}</td>
                      <td>{manifest.cycle_as_of}</td>
                      <td>{manifest.completed_snapshot_count}/{manifest.expected_snapshot_count} {manifest.completion_state}</td>
                      <td>{manifest.evidence_state}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="empty" data-recorded="false">No research cycle manifests have been recorded yet.</p>
            )}
            <p className="surface-note">{surfaces.snapshots.snapshot_count} snapshots on record</p>
          </section>
        </div>
      </main>
    </div>
  );
}
