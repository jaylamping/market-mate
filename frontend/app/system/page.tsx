import { WorkspacePage } from "../WorkspacePage";

export const metadata = { title: "System | Market Mate" };

export default function Page() {
  return <WorkspacePage title="System" description="Service health, evidence integrity, and audit history." activePage="/system">
    <section className="workspace-panel" aria-labelledby="integrity-heading">
      <header className="panel-heading"><div><h2 id="integrity-heading">Evidence integrity</h2><p>Signed checkpoints and audit-history coverage.</p></div><a className="text-link" href="/surfaces#checkpoint-pack">Inspect coverage</a></header>
      <header className="panel-heading"><div><h2>Evidence details</h2><p>Preserved research records and snapshots.</p></div><a className="text-link" href="/surfaces">Browse evidence</a></header>
      <div className="chart-empty"><h2>Service health and audit history</h2><p>Dedicated service monitoring and an audit-history browser will be added here.</p></div>
    </section>
  </WorkspacePage>;
}
