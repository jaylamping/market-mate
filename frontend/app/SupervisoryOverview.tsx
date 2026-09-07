import { surfacesQuery } from "@/lib/api-queries";
import { Activity, AlertTriangle, ArrowUpRight, Check, ChevronRight, CircleDollarSign, FlaskConical, LockKeyhole, ShieldCheck, TrendingUp } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { AppSidebar } from "./AppSidebar";
import { EvidenceBrowser } from "./EvidenceBrowser";
import { RefreshQueries } from "./RefreshQueries";
import type { Stage1SurfacesModel } from "./Stage1Surfaces";
import { attentionItems, comparatorFloors, custodyTrusted, displayTime, money, qualificationMeasures, type Tone } from "./overview-model";

function StateChip({ children, tone }: { children: React.ReactNode; tone: Tone }) {
  const Icon = tone === "good" ? Check : tone === "danger" || tone === "warning" ? AlertTriangle : Activity;
  return <Badge variant="outline" className={`state-chip state-${tone}`}><Icon aria-hidden="true"/>{children}</Badge>;
}

function Summary({ title, value, children, icon: Icon, href }: { title: string; value: string; children: React.ReactNode; icon: typeof Activity; href: string }) {
  return <section className="summary-section"><header><h2>{title}</h2><Icon aria-hidden="true"/></header><strong className="summary-value">{value}</strong>{children}<a className="summary-link" href={href}>Inspect {title.toLowerCase()} <ArrowUpRight aria-hidden="true"/></a></section>;
}

function PerformanceGraphic({ surfaces }: { surfaces: Stage1SurfacesModel }) {
  const q = surfaces.qualification;
  if (!q.recorded) return <div className="chart-empty"><FlaskConical aria-hidden="true"/><strong>No qualification report</strong><p>{q.detail}</p></div>;
  const measures = qualificationMeasures(q);
  const maximum = Math.max(1, ...measures.map(m => Math.abs(m.value ?? 0)));
  return <div className="performance-visual"><div className="chart-axis" aria-hidden="true"><span>Below zero</span><span>0 bps</span><span>Above zero</span></div><dl className="performance-bars">{measures.map(m => <div className="performance-row" key={m.label}><dt>{m.label}</dt><dd><div className="bar-track" aria-hidden="true">{m.value !== null && <span className={`bar-fill${m.value < 0 ? " bar-negative" : ""}`} style={{ left: `${m.value < 0 ? 50 - Math.abs(m.value) / maximum * 50 : 50}%`, width: `${Math.abs(m.value) / maximum * 50}%` }}/>}</div><span className="bar-value">{m.value === null ? m.unavailable : `${m.value > 0 ? "+" : ""}${m.value} bps`}</span></dd></div>)}</dl></div>;
}

export function SupervisoryOverview({ surfaces, loadedAt }: { surfaces: Stage1SurfacesModel; loadedAt: string }) {
  const trusted = custodyTrusted(surfaces);
  const attention = attentionItems(surfaces);
  const q = surfaces.qualification;
  const cost = surfaces.cost;
  const model = surfaces.cost_model;
  const pack = surfaces.checkpoint_pack;
  const trustLabel = trusted ? "Verified" : pack.state === "CHECKPOINT PENDING" && surfaces.checkpoints_verified ? "Pending" : "Unverified";
  return <div className="supervisory-overview" id="supervisory-overview" data-environment="local_research" data-display-only="true" data-order-authority="none" data-trusted={String(trusted)}>
    <a className="skip-link" href="#overview-main">Skip to overview</a><AppSidebar/>
    <main className="overview-main" id="overview-main" tabIndex={-1}>
      <header className="page-header"><div><h1>Supervisory overview</h1><p>Research and acceptance-test evidence, in one place.</p></div><div className="page-actions"><span className="loaded-at">Loaded <time dateTime={loadedAt}>{displayTime(loadedAt)}</time></span><RefreshQueries label="Refresh evidence" queryKeys={[surfacesQuery.queryKey]} /></div></header>
      <div className="authority-strip"><span><FlaskConical aria-hidden="true"/>Local Research</span><span><LockKeyhole aria-hidden="true"/>Order authority: none</span><StateChip tone={trusted ? "good" : trustLabel === "Pending" ? "warning" : "danger"}>Custody {trustLabel.toLowerCase()}</StateChip><span className="coverage-status">{pack.verified_position ?? "Unknown"} / {pack.head_position ?? "unknown"} events covered</span></div>
      {!trusted && <p className="trust-notice"><ShieldCheck aria-hidden="true"/>{trustLabel === "Pending" ? "Newer evidence awaits custody coverage. Recorded results below are not yet trusted." : "Custody is unverified. Do not rely on the displayed evidence until verification is restored."}<a href="/surfaces#checkpoint-pack">Inspect custody <ChevronRight aria-hidden="true"/></a></p>}
      <div className="summary-grid">
        <Summary title="Evidence trust" value={trustLabel} icon={ShieldCheck} href="/surfaces#checkpoint-pack"><p>{trusted ? "Signed coverage is current." : "Verification and coverage are separate checks."}</p><dl className="metric-list"><div><dt>Pending events</dt><dd>{pack.pending_events ?? "Unavailable"}</dd></div><div><dt>Signed checkpoints</dt><dd>{pack.checkpoint_count}</dd></div></dl></Summary>
        <Summary title="Attention" value={`${attention.length} ${attention.length === 1 ? "item" : "items"}`} icon={AlertTriangle} href="#attention"><p>Exceptions in the available evidence.</p><dl className="metric-list"><div><dt>Needs investigation</dt><dd>{attention.filter(i => i.tone === "danger").length}</dd></div><div><dt>Warnings</dt><dd>{attention.filter(i => i.tone === "warning").length}</dd></div></dl></Summary>
        <Summary title="Qualification" value={q.recorded ? q.status === "passed" ? "Recorded pass" : "Recorded failure" : "Not recorded"} icon={TrendingUp} href="/surfaces#qualification-progress"><p>{q.recorded ? `${q.window_count} walk-forward windows · ${trusted ? "custody verified" : "untrusted evidence"}` : "A frozen report has not been recorded."}</p><dl className="metric-list"><div><dt>Effective sample</dt><dd>{q.recorded ? `${q.eis} / ${q.eis_floor}` : "—"}</dd></div><div><dt>Comparator floors</dt><dd>{comparatorFloors(q)}</dd></div></dl></Summary>
        <Summary title="Projected costs" value={model.recorded ? `${money(model.monthly_projected_cents)}/mo` : "Not recorded"} icon={CircleDollarSign} href="/surfaces#cost-vs-caps"><p>{model.recorded ? model.within_caps ? "Projection is within the approved caps." : "Projection exceeds the approved caps." : "No cost model has been recorded."}</p><dl className="metric-list"><div><dt>Monthly cap</dt><dd>{model.recorded ? money(model.monthly_hard_ceiling_cents) : "—"}</dd></div><div><dt>Recorded spend</dt><dd>{cost.recorded ? money(cost.register.monthly_spent_cents) : "Not recorded"}</dd></div></dl></Summary>
      </div>
      <div className="workspace-grid">
        <section className="workspace-panel performance-panel"><header className="panel-heading"><div><h2>Qualification evidence</h2><p>Preserved endpoint measures</p></div><a className="text-link" href="/surfaces#qualification-progress">View report <ArrowUpRight aria-hidden="true"/></a></header><PerformanceGraphic surfaces={surfaces}/><div className="qualification-meta"><span>Effective independent sample <b>{q.recorded ? `${q.eis} / ${q.eis_floor}` : "—"}</b></span><span>Report as of <b>{q.recorded ? displayTime(q.as_of) : "Not recorded"}</b></span></div><p className="panel-note">Research evidence—not realized profit or executable orders. LCB = lower confidence bound.</p></section>
        <section className="workspace-panel attention-panel" id="attention"><header className="panel-heading"><div><h2>Needs attention</h2><p>Highest-impact exceptions first</p></div><Badge variant="secondary">{attention.length}</Badge></header><div className="attention-list">{attention.length ? attention.map((item, i) => <a className="attention-row" href={item.href} key={item.label}><span className={`attention-rank state-${item.tone}`}>{i + 1}</span><span><strong>{item.label}</strong><small>{item.detail}</small><span className={`attention-severity state-${item.tone}`}>{item.tone === "danger" ? "Investigate" : "Warning"}</span></span><ChevronRight aria-hidden="true"/></a>) : <div className="attention-empty"><Check aria-hidden="true"/><strong>No exceptions in available evidence</strong><p>This is a summary of recorded evidence, not a complete system-health check.</p></div>}</div><div className="authority-reminder"><LockKeyhole aria-hidden="true"/><span>Inspection only. This dashboard cannot submit, modify, or cancel orders.</span></div></section>
      </div>
      <EvidenceBrowser snapshots={surfaces.snapshots}/>
      <footer className="overview-footer"><LockKeyhole aria-hidden="true"/>Local Research · Display only · Evidence loads on request<span>Snapshot completion does not establish custody trust.</span></footer>
    </main>
  </div>;
}
