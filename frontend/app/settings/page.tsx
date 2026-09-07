import { ThemePicker } from "../ThemeProvider";
import { WorkspacePage } from "../WorkspacePage";
import { OpenRouterCapacity } from "@/components/OpenRouterCapacity";

export const metadata = { title: "Settings | Market Mate" };

export default function Page() {
  return <WorkspacePage title="Settings" description="Automated usage and appearance preferences." activePage="/settings">
    <div id="ai-usage"><OpenRouterCapacity/></div>
    <section className="workspace-panel mt-6" aria-labelledby="appearance-heading">
      <header className="panel-heading"><div><h2 id="appearance-heading">Appearance</h2><p>Choose light, dark, or your system theme. Saved in this browser.</p></div><ThemePicker /></header>
    </section>
  </WorkspacePage>;
}
