import { Bot } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { AppSidebar } from "../AppSidebar";

export const metadata = { title: "Incubator | Market Mate" };

export default function Page() {
  return <div className="supervisory-overview" data-display-only="true" data-order-authority="none">
    <a className="skip-link" href="#incubator-main">Skip to incubator</a>
    <AppSidebar activePage="/incubator" />
    <main className="overview-main" id="incubator-main" tabIndex={-1}>
      <header className="page-header"><div><h1>Incubator</h1><p>Track your agents, their work, and automated progress over time.</p></div><Badge variant="outline">Coming soon</Badge></header>
      <section className="workspace-panel" aria-labelledby="incubator-status">
        <div className="chart-empty"><Bot aria-hidden="true" /><h2 id="incubator-status">Agent activity will live here</h2><p>A home for agent assignments, ongoing runs, and progress history. Agent activity data is not connected yet.</p></div>
      </section>
    </main>
  </div>;
}
