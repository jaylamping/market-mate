import { WorkspacePage } from "../WorkspacePage";
import { AgentDriver } from "./AgentDriver";
export const metadata = { title: "Agents | Market Mate" };
export default function Page() {
  return <WorkspacePage title="Agents" description="Configure providers, personas, and tiered routes." activePage="/agents"><AgentDriver/></WorkspacePage>;
}
