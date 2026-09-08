import { WorkspacePage } from "../WorkspacePage";
import { AgentDriver } from "./AgentDriver";
export const metadata = { title: "Agents | Market Mate" };
export default function Page() {
  return <WorkspacePage title="Agents" description="Curate specialist personas and configure their model hierarchy." activePage="/agents"><AgentDriver/></WorkspacePage>;
}
