import { OpenRouterBalance } from "@/components/OpenRouterBalance";
import { ModelsTable } from "./ModelsTable";
import { cursorModelsQuery, cursorPolicyQuery, cursorStatusQuery } from "@/lib/api-queries";
import { openrouterBalanceQuery, openrouterModelsQuery, openrouterPolicyQuery } from "@/lib/api-queries";
import { IntegrationDisclosure } from "@/components/IntegrationSection";
import { WorkspacePage } from "../WorkspacePage";
import { RefreshQueries } from "../RefreshQueries";
import { Badge } from "@/components/ui/badge";
export const metadata = { title: "Agents | Market Mate" };
export default function Page() {
  return <WorkspacePage title="Agents" description="Configure the providers, models, and identities behind your agents." activePage="/agents">
    <section className="workspace-panel mb-6" aria-labelledby="agents-models">
      <header className="panel-heading"><div><h2 id="agents-models">Models</h2><p>Choose the models available to future agent tasks.</p></div><RefreshQueries label="Refresh models" queryKeys={[openrouterBalanceQuery.queryKey, openrouterModelsQuery.queryKey, openrouterPolicyQuery.queryKey, cursorModelsQuery.queryKey, cursorPolicyQuery.queryKey, cursorStatusQuery.queryKey]} /></header>
      <div className="grid min-w-0 gap-5 p-6">
        <div className="flex flex-wrap items-center justify-between gap-3"><OpenRouterBalance/><a href="/system#integrations" className="text-link">Manage connections</a></div>
        <IntegrationDisclosure title="Configure models"><ModelsTable/></IntegrationDisclosure>
      </div>
    </section>
    <section className="workspace-panel" aria-labelledby="agents-config"><header className="panel-heading"><div><h2 id="agents-config">Agent configuration</h2><p>Future controls for how your agents work.</p></div><Badge variant="outline">Planned</Badge></header><dl className="grid gap-6 p-6 sm:grid-cols-2"><div><dt className="font-medium">Provider priority</dt><dd className="mt-1 text-sm text-muted-foreground">Rank connected providers and define fallback preferences.</dd></div><div><dt className="font-medium">Model exclusions</dt><dd className="mt-1 text-sm text-muted-foreground">Add explicit blacklists alongside the approved model whitelist.</dd></div><div><dt className="font-medium">Usage limits</dt><dd className="mt-1 text-sm text-muted-foreground">Set request and spending limits for agent work.</dd></div><div><dt className="font-medium">Personas</dt><dd className="mt-1 text-sm text-muted-foreground">Define roles, instructions, and task-level model preferences.</dd></div></dl><div className="border-t px-6 py-4"><a className="text-link" href="/incubator">Track agent progress in Incubator</a></div></section>
  </WorkspacePage>;
}
