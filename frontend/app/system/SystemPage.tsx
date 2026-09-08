"use client";
import {MarketDataIntegration} from "./MarketDataIntegration";
import { WorkspacePage } from "../WorkspacePage";
import { IntegrationSection, IntegrationDisclosure } from "@/components/IntegrationSection";
import { RefreshQueries } from "../RefreshQueries";
import { useQuery } from "@tanstack/react-query";
import { paperQuery } from "../../lib/api-queries";
import { providersQuery, parseProviderStatus, type Provider } from "@/lib/agents";
import { connected } from "../paper/model";


export function SystemPage() {
  const query = useQuery(paperQuery);
  const providers = useQuery(providersQuery);
  const paper = query.isError ? { state: "connector_unavailable" } : query.data ?? { state: "loading" };
  const setup:Record<string,string>={zai:"python3 scripts/setup_zai.py","opencode-go":"python3 scripts/setup_opencode.py","openrouter-free":"python3 scripts/setup_openrouter.py","openrouter-paid":"python3 scripts/setup_openrouter.py",cursor:"python3 scripts/setup_cursor.py","cheaper-inference":"python3 scripts/setup_cheaper_inference.py"};
  return <WorkspacePage title="System" description="Service health, evidence integrity, and audit history." activePage="/system">
    <section className="workspace-panel mb-6" id="integrations" aria-labelledby="integrations-heading">
      <header className="panel-heading"><div><h2 id="integrations-heading">Integrations</h2><p>Connections to trading venues, data, and AI providers.</p></div><RefreshQueries label="Refresh connections" queryKeys={[paperQuery.queryKey, providersQuery.queryKey]} /></header>
      <IntegrationSection provider="alpaca" description="Paper account · Read-only POC · Free Paper access" state={paper.state} action={{href:"/paper",label:"Open Paper account"}}>
        {connected(paper) ? <p>Account data was fetched successfully. Live trading is not connected.</p> : <p>{paper.state === "not_configured" ? "Save your Paper API keys to connect your simulated account." : "Account data is unavailable. Check the connector and your Paper credentials, then refresh."}</p>}
        <IntegrationDisclosure title="Set up or replace Paper credentials">
            <p>Create a free Alpaca account and generate keys from the Paper dashboard. Enter them only through the local setup command.</p>
            <code className="break-all text-xs">python3 scripts/setup_alpaca_paper.py</code>
            <p>Run from the Market Mate project folder. Input is hidden; credentials are stored in a private Docker volume. Refresh after five seconds.</p>
            <a className="text-link" href="https://app.alpaca.markets/signup" target="_blank" rel="noreferrer">Open Alpaca signup</a>
        </IntegrationDisclosure>
      </IntegrationSection>
      <MarketDataIntegration />
      {providers.isError?<p role="alert" className="p-6">Provider status unavailable.</p>:providers.data?.map(provider=><ProviderIntegration key={provider.id} provider={provider} command={setup[provider.id]}/>)}
    </section>
    <section className="workspace-panel" aria-labelledby="integrity-heading">
      <header className="panel-heading"><div><h2 id="integrity-heading">Evidence integrity</h2><p>Signed checkpoints and audit-history coverage.</p></div><a className="text-link" href="/surfaces#checkpoint-pack">Inspect coverage</a></header>
      <header className="panel-heading"><div><h2>Evidence details</h2><p>Preserved research records and snapshots.</p></div><a className="text-link" href="/surfaces">Browse evidence</a></header>
      <div className="chart-empty"><h2>Service health and audit history</h2><p>Dedicated service monitoring and an audit-history browser will be added here.</p></div>
    </section>
  </WorkspacePage>;
}

function ProviderIntegration({provider:p,command}:{provider:Provider;command?:string}) {
  const status=useQuery({queryKey:["api","providers",p.id,"status"],queryFn:async({signal})=>parseProviderStatus(await (await fetch(`/api/providers/${p.id}/status`,{signal})).json()),refetchInterval:60_000});
  const state=status.isError?"unavailable":status.data?.state??p.state.probe_state??"loading";
  return <IntegrationSection provider={p.id} description={`${p.kind} provider · ${p.protocol==="none"?"Catalog only":"Agent driver"}`} state={state} action={{href:"/agents",label:"Configure agents"}}><p>{p.id==="cursor"?"Catalog only, no inference":p.credential_state==="configured"?"Credentials configured.":"Credentials not configured."}</p>{command&&<IntegrationDisclosure title="Setup"><p>Run locally from the project folder.</p><code>{command}</code></IntegrationDisclosure>}</IntegrationSection>
}
