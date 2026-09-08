"use client";
import { MarketDataIntegration } from "../system/MarketDataIntegration";
import { WorkspacePage } from "../WorkspacePage";
import {
  IntegrationSection,
  IntegrationDisclosure,
} from "@/components/IntegrationSection";
import { RefreshQueries } from "../RefreshQueries";
import { useQuery } from "@tanstack/react-query";
import { paperQuery } from "../../lib/api-queries";
import {
  providersQuery,
  parseProviderStatus,
  type Provider,
} from "@/lib/agents";
import { Button } from "@/components/ui/button";
import { useWorkspaceState } from "@/components/WorkspaceState";
import { connected } from "../paper/model";

export function IntegrationsPage() {
  const query = useQuery(paperQuery);
  const providers = useQuery(providersQuery);
  const paper = query.isError
    ? { state: "connector_unavailable" }
    : (query.data ?? { state: "loading" });
  const setup: Record<string, string> = {
    zai: "python3 scripts/setup_zai.py",
    "opencode-go": "python3 scripts/setup_opencode.py",
    "openrouter-free": "python3 scripts/setup_openrouter.py",
    "openrouter-paid": "python3 scripts/setup_openrouter.py",
    cursor: "python3 scripts/setup_cursor.py",
    "cheaper-inference": "python3 scripts/setup_cheaper_inference.py",
  };
  return (
    <WorkspacePage
      title="Integrations"
      description="Accounts, credentials, and shared provider settings."
      activePage="/integrations"
    >
      <section
        className="workspace-panel mb-6"
        id="integrations"
        aria-labelledby="integrations-heading"
      >
        <header className="panel-heading">
          <div>
            <h2 id="integrations-heading">Integrations</h2>
            <p>Connections to trading venues, data, and AI providers.</p>
          </div>
          <RefreshQueries
            label="Refresh connections"
            queryKeys={[paperQuery.queryKey, providersQuery.queryKey]}
          />
        </header>
        <IntegrationSection
          provider="alpaca"
          name="Alpaca"
          description="Paper account · Read-only POC · Free Paper access"
          state={paper.state}
          action={{ href: "/paper", label: "Open Paper account" }}
        >
          {connected(paper) ? (
            <p>
              Account data was fetched successfully. Live trading is not
              connected.
            </p>
          ) : (
            <p>
              {paper.state === "not_configured"
                ? "Save your Paper API keys to connect your simulated account."
                : "Account data is unavailable. Check the connector and your Paper credentials, then refresh."}
            </p>
          )}
          <IntegrationDisclosure title="Set up or replace Paper credentials">
            <p>
              Create a free Alpaca account and generate keys from the Paper
              dashboard. Enter them only through the local setup command.
            </p>
            <code className="break-all text-xs">
              python3 scripts/setup_alpaca_paper.py
            </code>
            <p>
              Run from the Market Mate project folder. Input is hidden;
              credentials are stored in a private Docker volume. Refresh after
              five seconds.
            </p>
            <a
              className="text-link"
              href="https://app.alpaca.markets/signup"
              target="_blank"
              rel="noreferrer"
            >
              Open Alpaca signup
            </a>
          </IntegrationDisclosure>
        </IntegrationSection>
        <MarketDataIntegration />
        {providers.isError ? (
          <p role="alert" className="p-6">
            Provider status unavailable.
          </p>
        ) : (
          providers.data?.map((provider) => (
            <ProviderIntegration
              key={provider.id}
              provider={provider}
              command={setup[provider.id]}
            />
          ))
        )}
      </section>
    </WorkspacePage>
  );
}

function ProviderIntegration({
  provider: p,
  command,
}: {
  provider: Provider;
  command?: string;
}) {
  const open = useWorkspaceState((s) => s.open);
  const status = useQuery({
    queryKey: ["api", "providers", p.id, "status"],
    queryFn: async ({ signal }) =>
      parseProviderStatus(
        await (await fetch(`/api/providers/${p.id}/status`, { signal })).json(),
      ),
    refetchInterval: 60_000,
  });
  const state = status.isError
    ? "unavailable"
    : (status.data?.state ?? p.state.probe_state ?? "loading");
  return (
    <>
      <IntegrationSection
        provider={p.id}
        name={p.display_name}
        description={`${p.kind} provider · ${p.protocol === "none" ? "Catalog only" : "Agent driver"}`}
        state={state}
        action={{ href: "/agents", label: "Configure agents" }}
      >
        <p>
          {p.protocol === "none"
            ? "Catalog only, no inference"
            : p.credential_state === "configured"
              ? "Credentials configured."
              : "Credentials not configured."}
        </p>
        <Button
          variant="outline"
          onClick={() => open({ kind: "provider", id: p.id })}
        >
          Account usage and settings
        </Button>
        {command && (
          <IntegrationDisclosure title="Setup">
            <p>Run locally from the project folder.</p>
            <code>{command}</code>
          </IntegrationDisclosure>
        )}
      </IntegrationSection>
    </>
  );
}
