import { FlaskConical, Radio } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { AppSidebar } from "./AppSidebar";

export function EnvironmentPage({ environment }: { environment: "Live" | "Paper" }) {
  const Icon = environment === "Live" ? Radio : FlaskConical;
  return <div className="supervisory-overview" data-display-only="true" data-order-authority="none">
    <a className="skip-link" href="#environment-main">Skip to {environment.toLowerCase()}</a>
    <AppSidebar activePage={environment === "Live" ? "/live" : "/paper"} />
    <main className="overview-main" id="environment-main" tabIndex={-1}>
      <header className="page-header"><div><h1>{environment}</h1><p>{environment === "Live" ? "Your live trading workspace." : "Your paper trading workspace."}</p></div><Badge variant="outline">Coming soon</Badge></header>
      <section className="workspace-panel" aria-labelledby="environment-status">
        <div className="chart-empty"><Icon aria-hidden="true" /><h2 id="environment-status">{environment} workspace coming soon</h2><p>This page is ready to build out. No {environment.toLowerCase()} account data is connected here yet.</p></div>
      </section>
    </main>
  </div>;
}
