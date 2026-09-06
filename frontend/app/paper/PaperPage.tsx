"use client";
import { Badge } from "@/components/ui/badge";
import { AppSidebar } from "../AppSidebar";
import { RefreshEvidence } from "../RefreshEvidence";
import { connected } from "./model";
import { useQuery } from "@tanstack/react-query";
import { paperQuery } from "../../lib/api-queries";
import { PaperWorkspace } from "./PaperWorkspace";
import { timestamp } from "./presentation";


const messages: Record<string, string> = {
  loading: "Loading your Paper account…",
  not_configured: "Connect your Alpaca Paper account in System → Integrations to see your simulated account here.",
  invalid_credentials: "The stored Paper credentials could not be read. Replace them in System → Integrations.",
  credentials_rejected: "Alpaca rejected the credentials. Check that they belong to your Paper account.",
  rate_limited: "Alpaca is limiting requests. Wait briefly, then refresh.",
  provider_unavailable: "Alpaca could not provide account data. Try refreshing shortly.",
  connection_failed: "The connector could not reach Alpaca. Check connectivity and retry.",
  invalid_response: "Account data failed validation. No balances or positions are displayed.",
  connector_unavailable: "The Paper connector is unavailable. Check the local Docker services and retry.",
};

export function PaperPage() {
  const query = useQuery(paperQuery);
  const state = query.isError ? { state: "connector_unavailable" } : query.data ?? { state: "loading" };
  const data = connected(state) ? state : null;
  return <div className="supervisory-overview" data-display-only="true" data-order-authority="none" data-environment="paper">
    <a className="skip-link" href="#paper-main">Skip to paper</a><AppSidebar activePage="/paper" />
    <main className="overview-main" id="paper-main" tabIndex={-1}>
      <header className="page-header"><div><h1>Paper</h1><p>Your simulated account, positions, and activity.</p></div><div className="page-actions">{data && <span className="loaded-at">Fetched {timestamp(new Date(data.fetched_at_ms).toISOString())}</span>}<RefreshEvidence label="Refresh account" /></div></header>
      <div className="authority-strip"><span>Alpaca Paper</span><Badge variant="outline">{data ? "Connected" : state.state === "not_configured" ? "Not connected" : "Connection unavailable"}</Badge><span>Read-only · No real money</span><a className="text-link" href="/system#integrations">Manage integration</a></div>
      {data ? <PaperWorkspace data={data} /> : <section className="workspace-panel mt-6"><div className="chart-empty"><h2>{state.state === "not_configured" ? "Connect Alpaca Paper" : "Account data unavailable"}</h2><p>{messages[state.state] ?? messages.invalid_response}</p><a className="text-link" href="/system#integrations">Open integration settings</a></div></section>}
      <footer className="overview-footer">Paper POC · Observations are fetched separately, not a reconciled ledger.<span>No order submission from Market Mate</span></footer>
    </main>
  </div>;
}
