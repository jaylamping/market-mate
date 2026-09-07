"use client";
import { OpenRouterBalance } from "@/components/OpenRouterBalance";
import { useQuery } from "@tanstack/react-query";
import { IntegrationSection, IntegrationDisclosure } from "@/components/IntegrationSection";
import { openrouterStatusQuery } from "../../lib/api-queries";

export function OpenRouterIntegration() {
  const status = useQuery(openrouterStatusQuery);
  const state = status.isError ? "unavailable" : status.data?.state ?? "loading";
  return <IntegrationSection provider="openrouter" description="AI models · Explicit whitelist" state={state} metric={<OpenRouterBalance/>} action={{href:"/agents",label:"Configure models"}}>
    <p className="text-sm text-muted-foreground">{state === "connected" ? "API key verified. Agent execution is not connected yet." : state === "not_configured" ? "Add an API key to connect OpenRouter. Choose approved models on the Agents page." : state === "loading" ? "Checking the OpenRouter connection…" : state === "rate_limited" ? "OpenRouter is limiting checks. Wait a minute, then refresh." : "Could not verify the API key. Check the connector or replace the key, then refresh."}</p>
    <IntegrationDisclosure title="Set up or replace OpenRouter API key"><a className="text-link" href="https://openrouter.ai/settings/keys" target="_blank" rel="noreferrer">Create an OpenRouter key</a><p>Create a dedicated Market Mate key, then run this command from the project folder. Input is hidden and stored privately in Docker.</p><code className="break-all text-xs">python3 scripts/setup_openrouter.py</code><p>Refresh after five seconds. Never paste your key into chat.</p></IntegrationDisclosure>
    <IntegrationDisclosure id="openrouter-balance" title="Account balance access"><p>Balance is your total remaining OpenRouter account credit in USD. If your regular key cannot read it, create a separate management key and save it with the command below. It is used only to read account credits.</p><code className="break-all text-xs">python3 scripts/setup_openrouter_balance.py</code><p>Run from the project folder. Input is hidden; refresh after one minute.</p><a href="https://openrouter.ai/settings/credits" target="_blank" rel="noreferrer" className="text-link">Open OpenRouter credits</a></IntegrationDisclosure>
  </IntegrationSection>;
}
