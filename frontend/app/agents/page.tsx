import { OpenRouterBalance } from "@/components/OpenRouterBalance";
import { ModelsTable } from "./ModelsTable";
import { cursorModelsQuery, cursorPolicyQuery, cursorStatusQuery } from "@/lib/api-queries";
import { modelRoutingQuery, openrouterBalanceQuery, openrouterModelsQuery, openrouterPolicyQuery } from "@/lib/api-queries";
import { IntegrationDisclosure } from "@/components/IntegrationSection";
import { WorkspacePage } from "../WorkspacePage";
import { RefreshQueries } from "../RefreshQueries";
import { RoutingEditor } from "./RoutingEditor";
import { AgentConfiguration } from "./AgentConfiguration";
export const metadata = { title: "Agents | Market Mate" };
export default function Page() {
  return <RoutingEditor><WorkspacePage title="Agents" description="Configure the providers, models, and identities behind your agents." activePage="/agents">
    <section className="workspace-panel mb-6" aria-labelledby="agents-models">
      <header className="panel-heading"><div><h2 id="agents-models">Models</h2><p>Choose the models available to future agent tasks.</p></div><RefreshQueries label="Refresh models" queryKeys={[modelRoutingQuery.queryKey, openrouterBalanceQuery.queryKey, openrouterModelsQuery.queryKey, openrouterPolicyQuery.queryKey, cursorModelsQuery.queryKey, cursorPolicyQuery.queryKey, cursorStatusQuery.queryKey]} /></header>
      <div className="grid min-w-0 gap-5 p-6">
        <div className="flex flex-wrap items-center justify-between gap-3"><OpenRouterBalance/><a href="/system#integrations" className="text-link">Manage connections</a></div>
        <IntegrationDisclosure title="Configure models"><ModelsTable/></IntegrationDisclosure>
      </div>
    </section>
    <section className="workspace-panel" aria-labelledby="agents-config"><header className="panel-heading"><div><h2 id="agents-config">Agent configuration</h2><p>Choose the default model for each agent role.</p></div></header><AgentConfiguration/><div className="border-t px-6 py-4"><a className="text-link" href="/incubator">Track agent progress in Incubator</a></div></section>
  </WorkspacePage></RoutingEditor>;
}
