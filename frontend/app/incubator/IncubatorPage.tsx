"use client";
import { useQuery } from "@tanstack/react-query";
import { Bot, ChevronDown } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { ModelLink } from "@/components/ModelLink";
import { incubatorQuery } from "@/lib/api-queries";
import { AppSidebar } from "../AppSidebar";
import { RefreshQueries } from "../RefreshQueries";
import { costLabel, stateLabel, type Run, type Report } from "./model";

function time(value: string) { return new Date(value).toLocaleString(); }
function reportList(title: string, items: string[], ordered = false) {
  const List=ordered ? "ol" : "ul";
  return <section className="space-y-2"><h3 className="font-medium">{title}</h3><List className={`${ordered ? "list-decimal" : "list-disc"} space-y-2 pl-5 text-sm text-muted-foreground`}>{items.map((item,i)=><li key={i}>{ordered ? item.replace(/^\s*\d{1,3}[.)]\s+/, "") : item}</li>)}</List></section>;
}
function ResearchReport({report}:{report:Report}) {
  return <div className="space-y-6 break-words">
    <section className="space-y-2"><h3 className="font-medium">Hypothesis</h3><p className="text-sm leading-relaxed">{report.hypothesis}</p></section>
    <div className="grid gap-6 lg:grid-cols-2">{reportList("Evidence needed",report.evidence_gaps)}{reportList("Proposed experiment",report.experiment,true)}</div>
    <section className="space-y-2"><h3 className="font-medium">Reject the hypothesis if…</h3><p className="text-sm text-muted-foreground">{report.falsification_rule}</p></section>
    {reportList("Limitations",report.limitations)}
  </div>;
}
export function RunCard({run,open}:{run:Run;open:boolean}) {
  const label=stateLabel(run), dispatch=run.events.find(e=>e.state==="dispatched");
  const elapsed=dispatch && ["completed","failed"].includes(run.state) ? Math.max(0,Math.round((Date.parse(run.updated_at)-Date.parse(dispatch.at))/1000)) : null;
  return <details open={open} className="workspace-panel group min-w-0 p-5 md:p-6">
    <summary className="flex cursor-pointer list-none flex-wrap items-center justify-between gap-3 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring">
      <div className="min-w-0 space-y-1"><p className="text-xs text-muted-foreground">{run.config.agent_name} · {time(run.created_at)}</p><h2 className="font-medium">{run.config.input.title}</h2></div>
      <span className="flex items-center gap-3"><Badge variant="outline">{label}</Badge><ChevronDown className="size-4 transition-transform group-open:rotate-180" aria-hidden="true"/></span>
    </summary>
    <div className="mt-6 space-y-6">
      <dl className="grid min-w-0 grid-cols-2 gap-4 border-y border-border py-4 text-sm lg:grid-cols-4">
        <div className="min-w-0"><dt className="text-xs text-muted-foreground">Model</dt><dd className="mt-1 break-all"><ModelLink provider="openrouter" id={run.config.model} name={run.config.model}/></dd></div>
        <div><dt className="text-xs text-muted-foreground">Reported cost</dt><dd className="mt-1 font-medium tabular-nums">{costLabel(run.detail.usage.cost_usd)}</dd></div>
        <div><dt className="text-xs text-muted-foreground">Input / output tokens</dt><dd className="mt-1 tabular-nums">{run.detail.usage.prompt_tokens ?? "—"} / {run.detail.usage.completion_tokens ?? "—"}</dd></div>
        <div><dt className="text-xs text-muted-foreground">Request duration</dt><dd className="mt-1">{elapsed === null ? "Not established" : `${elapsed}s`}</dd></div>
      </dl>
      {run.detail.reason && <p role="status" className="rounded-md border border-border p-3 text-sm">{reasonText(run.detail.reason)}</p>}
      {label === "Outcome unknown" && <p className="text-sm text-muted-foreground">The provider may have accepted this request. No automatic retry will occur; the research lane stays paused for reconciliation.</p>}
      {run.detail.report ? <ResearchReport report={run.detail.report}/> : <p className="text-sm text-muted-foreground">{run.state === "admitted" || label === "Researching" ? "Waiting for the bounded research request to finish. Progress refreshes automatically." : "No completed research report is available for this run."}</p>}
      {run.detail.response_text && run.state !== "completed" && <details className="rounded-md border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Unvalidated response{run.detail.response_truncated ? " (truncated)" : ""}</summary><div className="mt-3 space-y-3"><p className="text-sm text-muted-foreground">{run.detail.validation_error ?? "This response did not produce an accepted report."}</p><pre className="whitespace-pre-wrap break-words text-xs">{run.detail.response_text}</pre></div></details>}
      <details className="rounded-md border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Assignment and provenance</summary><div className="mt-4 space-y-4 break-words text-sm text-muted-foreground">
        <p>{run.config.input.text}</p>
        <p>Original project-authored brief · One request · {run.config.limits.max_output_tokens.toLocaleString()} maximum output tokens · {run.config.limits.timeout_seconds}s request timeout · ${run.config.limits.max_cost_usd} spending limit</p>
        <dl className="space-y-2">{run.detail.fallback_of&&<div><dt>Fallback for run</dt><dd className="break-all">{run.detail.fallback_of}</dd></div>}<div><dt>Run</dt><dd className="break-all">{run.run_key}</dd></div><div><dt>Assignment</dt><dd className="break-all">{run.assignment_id}</dd></div><div><dt>Generation</dt><dd className="break-all">{run.detail.generation_id ?? "Unavailable"}</dd></div><div><dt>Returned model / serving provider</dt><dd className="break-all">{run.detail.returned_model ?? "Unavailable"} / {run.detail.serving_provider ?? "Unavailable"}</dd></div><div><dt>Whitelist revision</dt><dd>{dispatch?.detail.policy_revision ?? "Not dispatched"}</dd></div><div><dt>Request SHA-256</dt><dd className="break-all">{dispatch?.detail.request_sha256 ?? "Not dispatched"}</dd></div></dl>
      </div></details>
      <section className="space-y-3"><h3 className="text-sm font-medium">Run history</h3><ol className="space-y-2">{run.events.map(e=><li key={e.sequence} className="flex flex-wrap justify-between gap-2 border-l-2 border-border pl-3 text-sm"><span>{({admitted:"Assignment recorded",dispatched:"Dispatch intent recorded",completed:"Report recorded",failed:"Run failed",indeterminate:"Outcome unknown"})[e.state]}</span><time className="text-xs text-muted-foreground" dateTime={e.at}>{time(e.at)}</time></li>)}</ol></section>
    </div>
  </details>;
}
function reasonText(reason:string) {
  const messages:Record<string,string>={ model_not_whitelisted:"The selected model was not on the saved whitelist. No request was sent.",zero_spend_budget_denied:"The model did not meet this run’s $0 spending limit. No request was sent.",model_policy_changed:"The whitelist changed during preparation. No request was sent.",provider_http_error:"The provider returned an error. Its status is preserved in the run record.",incomplete_response:"The response ended before a complete report was available.",invalid_report:"The response did not match the required report structure.",unexpected_model:"The provider returned a different model than requested.",unexpected_provider_charge:"The provider reported a charge despite the $0 request limit. The lane is paused for reconciliation." };
  return messages[reason] ?? `Run stopped: ${reason.replaceAll("_"," ")}.`;
}
export function IncubatorPage() {
  const query=useQuery(incubatorQuery);
  return <div className="supervisory-overview" data-display-only="true" data-order-authority="none"><a className="skip-link" href="#incubator-main">Skip to incubator</a><AppSidebar activePage="/incubator"/>
    <main className="overview-main" id="incubator-main" tabIndex={-1}>
      <header className="page-header"><div><h1>Incubator</h1><p>Research assignments, progress, and preserved results.</p></div><div className="flex flex-wrap items-center gap-3"><Badge variant="outline">Local Research · POC</Badge><RefreshQueries label="Refresh runs" queryKeys={[incubatorQuery.queryKey]}/></div></header>
      <p className="text-sm text-muted-foreground">Research planning only. Reports propose hypotheses and experiments; they contain no validated performance or trading approval.</p>
      {query.isError && <p role="alert" className="workspace-panel p-4">Run history is unavailable. {query.data ? "The history below may be outdated." : "Refresh to try again."}</p>}
      {query.isPending && <p role="status" className="workspace-panel p-6">Loading research runs…</p>}
      {query.data?.length === 0 && <section className="workspace-panel"><div className="chart-empty"><Bot aria-hidden="true"/><h2>No research runs yet</h2><p>The first bounded assignment will appear here when the local research runner starts.</p><a href="/agents" className="text-primary underline underline-offset-4">View approved models</a></div></section>}
      <div className="space-y-4">{query.data?.map((run,index)=><RunCard key={run.run_key} run={run} open={index===0}/>)}</div>
      {!!query.data?.length && <p className="text-xs text-muted-foreground">Latest {query.data.length} runs, up to 100. Missing usage remains unavailable.</p>}
    </main>
  </div>;
}
