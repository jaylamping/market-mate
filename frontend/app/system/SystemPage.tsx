"use client";
import { WorkspacePage } from "../WorkspacePage";
import { Badge } from "@/components/ui/badge";
import { RefreshEvidence } from "../RefreshEvidence";
import { useQuery } from "@tanstack/react-query";
import { paperQuery } from "../../lib/api-queries";
import { connected } from "../paper/model";


export function SystemPage() {
  const query = useQuery(paperQuery);
  const paper = query.isError ? { state: "connector_unavailable" } : query.data ?? { state: "loading" };
  const status = connected(paper) ? "Connected" : paper.state === "not_configured" ? "Setup needed" : paper.state === "credentials_rejected" ? "Check credentials" : "Unavailable";
  return <WorkspacePage title="System" description="Service health, evidence integrity, and audit history." activePage="/system">
    <section className="workspace-panel mb-6" id="integrations" aria-labelledby="integrations-heading">
      <header className="panel-heading"><div><h2 id="integrations-heading">Integrations</h2><p>Connections to trading venues and data providers.</p></div><RefreshEvidence /></header>
      <div className="chart-empty">
        <div className="flex items-center gap-3"><h3>Alpaca</h3><Badge variant="outline">{status}</Badge></div>
        <p>Paper account · Read-only POC · Free Paper access</p>
        {connected(paper) ? <p>Account data was fetched successfully. Live trading is not connected.</p> : <p>{paper.state === "not_configured" ? "Save your Paper API keys to connect your simulated account." : "Account data is unavailable. Check the connector and your Paper credentials, then refresh."}</p>}
        <a className="text-link" href="/paper">Open Paper account</a>
        <details className="w-full text-sm">
          <summary className="cursor-pointer text-primary">Set up or replace Paper credentials</summary>
          <div className="grid gap-3 pt-4">
            <p>Create a free Alpaca account and generate keys from the Paper dashboard. Enter them only through the local setup command.</p>
            <code className="break-all text-xs">python3 scripts/setup_alpaca_paper.py</code>
            <p>Run from the Market Mate project folder. Input is hidden; credentials are stored in a private Docker volume. Refresh after five seconds.</p>
            <a className="text-link" href="https://app.alpaca.markets/signup" target="_blank" rel="noreferrer">Open Alpaca signup</a>
          </div>
        </details>
      </div>
    </section>
    <section className="workspace-panel" aria-labelledby="integrity-heading">
      <header className="panel-heading"><div><h2 id="integrity-heading">Evidence integrity</h2><p>Signed checkpoints and audit-history coverage.</p></div><a className="text-link" href="/surfaces#checkpoint-pack">Inspect coverage</a></header>
      <header className="panel-heading"><div><h2>Evidence details</h2><p>Preserved research records and snapshots.</p></div><a className="text-link" href="/surfaces">Browse evidence</a></header>
      <div className="chart-empty"><h2>Service health and audit history</h2><p>Dedicated service monitoring and an audit-history browser will be added here.</p></div>
    </section>
  </WorkspacePage>;
}
