import { WorkspacePage } from "../WorkspacePage";

export const metadata = { title: "Finances | Market Mate" };

export default function Page() {
  return <WorkspacePage title="Finances" description="Operating costs, recurring expenses, and tax reporting." activePage="/finances">
    <section className="workspace-panel" aria-labelledby="costs-heading">
      <header className="panel-heading"><div><h2 id="costs-heading">Operating costs</h2><p>Recorded spending, projections, and approved caps.</p></div><a className="text-link" href="/surfaces#cost-vs-caps">View costs</a></header>
      <div className="chart-empty"><h2>Recurring expenses and taxes</h2><p>Subscription tracking, recurring expenses, and tax reporting will be added here.</p></div>
    </section>
  </WorkspacePage>;
}
