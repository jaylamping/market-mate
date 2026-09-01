export type LedgerEvent = {
  chain_position: number;
  event_id: string;
  event_type: string;
  event_time: string;
  record_environment: string;
  trusted: boolean;
  distrust_reason: string | null;
};

export type LedgerException = {
  kind: string;
  position: number | null;
  reason: string;
  detail: string;
};

export type CommandLedgerModel = {
  variant: string;
  environment: string;
  order_authority: boolean;
  checkpoints_verified: boolean;
  chain: {
    valid: boolean;
    checked_events: number;
    break_position: number | null;
    reason: string | null;
  };
  checkpoint_count: number;
  system_truth: {
    environment: string;
    state: string;
    detail: string;
    head_position: number | null;
    as_of: string;
    order_authority: string;
  };
  exceptions: LedgerException[];
  tape: LedgerEvent[];
};

function toneFor(state: string): string {
  if (state === "CHAIN VERIFIED") return "tone-good";
  if (state === "CHAIN DISTRUSTED") return "tone-danger";
  return "tone-warn";
}

export function CommandLedger({ ledger }: { ledger: CommandLedgerModel }) {
  const distrusted = !ledger.chain.valid || !ledger.checkpoints_verified;
  const breakPosition = ledger.chain.break_position;
  return (
    <div
      id="command-ledger"
      className="variant-a"
      data-variant={ledger.variant}
      data-chain-valid={String(ledger.chain.valid)}
      data-checkpoints-verified={String(ledger.checkpoints_verified)}
      data-order-authority={String(ledger.order_authority)}
      data-break-position={breakPosition == null ? "" : String(breakPosition)}
    >
      <aside className="command-sidebar" aria-label="Command ledger views">
        <div className="brand-sidebar">
          <strong>MARKET MATE</strong>
          <small>COMMAND LEDGER</small>
        </div>
        <nav aria-label="Control room views">
          <div className="side-nav-button is-active">
            <span>01</span>
            <strong>Home / Dashboard</strong>
            <small>system truth + tape</small>
          </div>
          <a href="/surfaces" className="side-nav-button">
            <span>02</span>
            <strong>Stage-1 surfaces</strong>
            <small>WU-46</small>
          </a>
        </nav>
        <div className="sidebar-foot">
          <span className="env-label">LOCAL RESEARCH</span>
          <strong>Zero order authority</strong>
          <small>Display-only command ledger. Checkpoints verified before trusted display.</small>
        </div>
      </aside>
      <main id="command-main" className="command-main" tabIndex={-1}>
        <header className="command-header">
          <div>
            <span className="eyebrow">VARIANT A / COMMAND LEDGER</span>
            <h1>System truth before activity.</h1>
          </div>
          <div>
            <strong>{ledger.system_truth.as_of}</strong>
            <small>Signed audit chain · local_research</small>
          </div>
        </header>
        <section
          id="system-truth-header"
          className={`truth-bar${distrusted ? " is-distrusted" : ""}`}
          aria-label="Authoritative system truth"
          data-state={ledger.system_truth.state}
        >
          <div>
            <span className="env-label">{ledger.system_truth.environment}</span>{" "}
            <span className={`status-pill ${toneFor(ledger.system_truth.state)}`}>
              {ledger.system_truth.state}
            </span>
          </div>
          <p>{ledger.system_truth.detail}</p>
          <dl>
            <div>
              <dt>Head</dt>
              <dd>{ledger.system_truth.head_position ?? "none"}</dd>
            </div>
            <div>
              <dt>Checkpoints</dt>
              <dd>{ledger.checkpoint_count}</dd>
            </div>
            <div>
              <dt>Authority</dt>
              <dd>{ledger.system_truth.order_authority}</dd>
            </div>
          </dl>
        </section>
        <div className="command-grid">
          <section className="command-section" aria-label="Dense audit tape">
            <div className="section-title">
              <div>
                <span>SIGNED AUDIT TAPE</span>
                <h2>Dense command ledger</h2>
              </div>
              <b>{ledger.tape.length} events</b>
            </div>
            <table id="audit-tape" className="audit-tape">
              <thead>
                <tr>
                  <th>Position</th>
                  <th>Type</th>
                  <th>Time</th>
                  <th>Trust</th>
                </tr>
              </thead>
              <tbody>
                {ledger.tape.map((event) => (
                  <tr
                    key={event.chain_position}
                    data-chain-position={event.chain_position}
                    data-trusted={String(event.trusted)}
                    className={event.trusted ? "" : "is-distrusted"}
                  >
                    <td>{event.chain_position}</td>
                    <td>
                      <strong>{event.event_type}</strong>
                    </td>
                    <td>{event.event_time}</td>
                    <td>
                      {event.trusted
                        ? "trusted"
                        : event.distrust_reason ?? "untrusted"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
          <aside
            id="exception-rail"
            className="command-section exception-rail"
            aria-label="Exception rail"
            data-count={ledger.exceptions.length}
            data-break-position={breakPosition == null ? "" : String(breakPosition)}
          >
            <div className="section-title">
              <div>
                <span>EXCEPTION RAIL</span>
                <h2>Distrusted range</h2>
              </div>
              <b>{ledger.exceptions.length}</b>
            </div>
            {ledger.exceptions.length === 0 ? (
              <p className="empty">No exceptions. Chain and checkpoints verify.</p>
            ) : (
              ledger.exceptions.map((item, index) => (
                <article
                  key={`${item.kind}-${index}`}
                  data-exception-kind={item.kind}
                  data-exception-position={item.position == null ? "" : String(item.position)}
                >
                  <strong>
                    {item.kind}
                    {item.position == null ? "" : ` @ ${item.position}`}
                  </strong>
                  <small>
                    {item.reason}: {item.detail}
                  </small>
                </article>
              ))
            )}
          </aside>
        </div>
      </main>
    </div>
  );
}
