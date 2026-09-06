import { Activity, Archive, CircleDollarSign, FlaskConical, LayoutDashboard, LockKeyhole, ShieldCheck } from "lucide-react";
import { ThemePicker } from "./ThemeProvider";

export function AppSidebar({ details = false }: { details?: boolean }) {
  const links = [
    ["Overview", "/", LayoutDashboard],
    ["Attention", "/#attention", Activity],
    ["Qualification", "/surfaces#qualification-progress", FlaskConical],
    ["Costs", "/surfaces#cost-vs-caps", CircleDollarSign],
    ["Evidence", "/#evidence", Archive],
    ["Custody", "/surfaces#checkpoint-pack", ShieldCheck],
  ] as const;
  return <aside className="overview-sidebar">
    <a className="overview-brand" href="/" aria-label="Market Mate overview"><span className="brand-mark" aria-hidden="true">M</span><strong>Market Mate</strong></a>
    <nav className="overview-nav" aria-label="Supervisory views">
      {links.map(([label, href, Icon], index) => <a key={label} href={href} className={`nav-item${index === 0 && !details ? " is-active" : ""}`} aria-current={index === 0 && !details ? "page" : undefined}><Icon aria-hidden="true" /><span>{label}</span></a>)}
    </nav>
    <div className="sidebar-bottom">
      <a className={`nav-item${details ? " is-active" : ""}`} href="/surfaces" aria-current={details ? "page" : undefined}><Archive aria-hidden="true"/><span>Evidence details</span></a>
      <ThemePicker />
      <div className="environment-card"><FlaskConical aria-hidden="true"/><div><strong>Local Research</strong><span>Stage 1 · Display only</span></div></div>
      <p className="sidebar-authority"><LockKeyhole aria-hidden="true"/>Zero order authority</p>
    </div>
  </aside>;
}
