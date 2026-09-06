import { Bot, CircleDollarSign, FlaskConical, LayoutDashboard, LockKeyhole, Radio, Settings, ShieldCheck } from "lucide-react";
import { ThemePicker } from "./ThemeProvider";

export type SidebarPage = "/" | "/live" | "/paper" | "/incubator" | "/finances" | "/system" | "/settings";

export function AppSidebar({ details = false, activePage = "/" }: { details?: boolean; activePage?: SidebarPage }) {
  const selectedPage = details ? "/system" : activePage;
  const links = [
    ["Overview", "/", LayoutDashboard],
    ["Live", "/live", Radio],
    ["Paper", "/paper", FlaskConical],
    ["Incubator", "/incubator", Bot],
    ["Finances", "/finances", CircleDollarSign],
    ["System", "/system", ShieldCheck],
    ["Settings", "/settings", Settings],
  ] as const;
  return <aside className="overview-sidebar">
    <a className="overview-brand" href="/" aria-label="Market Mate overview"><span className="brand-mark" aria-hidden="true">M</span><strong>Market Mate</strong></a>
    <nav className="overview-nav" aria-label="Supervisory views">
      {links.map(([label, href, Icon]) => <a key={label} href={href} className={`nav-item${href === selectedPage ? " is-active" : ""}`} aria-current={href === selectedPage ? details ? "location" : "page" : undefined}><Icon aria-hidden="true" /><span>{label}</span></a>)}
    </nav>
    <div className="sidebar-bottom">
      <ThemePicker />
      <div className="environment-card"><FlaskConical aria-hidden="true"/><div><strong>Local Research</strong><span>Stage 1 · Display only</span></div></div>
      <p className="sidebar-authority"><LockKeyhole aria-hidden="true"/>Zero order authority</p>
    </div>
  </aside>;
}
