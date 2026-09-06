import type { ReactNode } from "react";
import { AppSidebar, type SidebarPage } from "./AppSidebar";

export function WorkspacePage({ title, description, activePage, children }: {
  title: string;
  description: string;
  activePage: SidebarPage;
  children: ReactNode;
}) {
  return <div className="supervisory-overview" data-display-only="true" data-order-authority="none">
    <a className="skip-link" href="#workspace-main">Skip to {title.toLowerCase()}</a>
    <AppSidebar activePage={activePage} />
    <main className="overview-main" id="workspace-main" tabIndex={-1}>
      <header className="page-header"><div><h1>{title}</h1><p>{description}</p></div></header>
      {children}
    </main>
  </div>;
}
