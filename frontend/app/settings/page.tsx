import { ThemePicker } from "../ThemeProvider";
import { WorkspacePage } from "../WorkspacePage";

export const metadata = { title: "Settings | Market Mate" };

export default function Page() {
  return <WorkspacePage title="Settings" description="Preferences and configuration." activePage="/settings">
    <section className="workspace-panel" aria-labelledby="appearance-heading">
      <header className="panel-heading"><div><h2 id="appearance-heading">Appearance</h2><p>Choose light, dark, or your system theme. Saved in this browser.</p></div><ThemePicker /></header>
      <div className="chart-empty"><h2>More settings to come</h2><p>Additional preferences and configuration will be added as the workspaces take shape.</p></div>
    </section>
  </WorkspacePage>;
}
