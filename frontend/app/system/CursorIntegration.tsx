"use client";
import { useQuery } from "@tanstack/react-query";
import { IntegrationSection, IntegrationDisclosure } from "@/components/IntegrationSection";
import { cursorStatusQuery } from "../../lib/api-queries";

export function CursorIntegration() {
  const status = useQuery(cursorStatusQuery);
  const state = status.isError ? "unavailable" : status.data?.state ?? "loading";
  return <IntegrationSection provider="cursor" description="Agent runner · Cursor subscription" state={state} action={{href:"/agents",label:"Configure models"}}>
    <p className="text-sm text-muted-foreground">{state === "connected" ? "API key verified. Agent execution is not connected yet." : state === "not_configured" ? "Add an API key to connect Cursor. Choose approved runner models on the Agents page." : state === "loading" ? "Checking the Cursor connection…" : state === "rate_limited" ? "Cursor is limiting checks. Wait a minute, then refresh." : "Could not verify the API key. Check the connector or replace the key, then refresh."}</p>
    <IntegrationDisclosure title="Set up or replace Cursor API key"><a className="text-link" href="https://cursor.com/dashboard/integrations" target="_blank" rel="noreferrer">Create a Cursor key</a><p>Create a dedicated Market Mate key, then run this command from the project folder. Input is hidden and stored privately in Docker.</p><code className="break-all text-xs">python3 scripts/setup_cursor.py</code><p>Refresh after five seconds. Never paste your key into chat.</p></IntegrationDisclosure>
  </IntegrationSection>;
}
