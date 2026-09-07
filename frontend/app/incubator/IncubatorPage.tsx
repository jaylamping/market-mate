"use client";
import { useQuery } from "@tanstack/react-query";
import { Bot, ArrowUpRight, CheckCircle2, XCircle, Clock3, CircleDashed, X } from "lucide-react";
import { Dialog, Tabs } from "radix-ui";
import {OriginBadge} from "./OriginBadge";
import {Experiments} from "./Experiments";
import {ReportEvaluation,EvaluationSummary} from "./EvaluationView";
import {getWorkflow,workflowKey,type Evaluation} from "./evaluation";
import {ResearchReport,reportList} from "./ResearchReport";
import { RunChat } from "./RunChat";
import type { Conversation } from "@/lib/incubator-chat";
import { useEffect, useState } from "react";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { ModelLink } from "@/components/ModelLink";
import { incubatorQuery } from "@/lib/api-queries";
import { AppSidebar } from "../AppSidebar";
import { RefreshQueries } from "../RefreshQueries";
import { costLabel, parseRuns, stateLabel, type Run } from "./model";

import { AddAssignment } from "./AddAssignment";
import { WorkflowTimeline } from "./WorkflowTimeline";
import { useIncubatorStream } from "./useIncubatorStream";

function time(value: string) { return new Date(value).toLocaleString(); }
function RunDetails({run}:{run:Run}) {
  const label=stateLabel(run), dispatch=run.events.find(e=>e.state==="dispatched");
  const elapsed=dispatch && ["completed","failed"].includes(run.state) ? Math.max(0,Math.round((Date.parse(run.updated_at)-Date.parse(dispatch.at))/1000)) : null;
  return <div className="space-y-6">
      <dl className="grid min-w-0 grid-cols-2 gap-4 border-y border-border py-4 text-sm lg:grid-cols-4">
        <div className="min-w-0"><dt className="text-xs text-muted-foreground">Model</dt><dd className="mt-1 break-all"><ModelLink provider="openrouter" id={run.config.model} name={run.config.model}/></dd></div>
        <div><dt className="text-xs text-muted-foreground">Reported cost</dt><dd className="mt-1 font-medium tabular-nums">{costLabel(run.detail.usage.cost_usd)}</dd></div>
        <div><dt className="text-xs text-muted-foreground">Input / output tokens</dt><dd className="mt-1 tabular-nums">{run.detail.usage.prompt_tokens ?? "—"} / {run.detail.usage.completion_tokens ?? "—"}</dd></div>
        <div><dt className="text-xs text-muted-foreground">Request duration</dt><dd className="mt-1">{elapsed === null ? "Not established" : `${elapsed}s`}</dd></div>
      </dl>
      {run.detail.reason && <p role="status" className="rounded-md border border-border p-3 text-sm">{reasonText(run.detail.reason)}</p>}
      {label === "Outcome unknown" && <p className="text-sm text-muted-foreground">The provider may have accepted this request. No automatic retry will occur; the research lane stays paused for reconciliation.</p>}
      {run.detail.report ? <ResearchReport report={run.detail.report}/> : <p className="text-sm text-muted-foreground">{(run.state === "admitted" || run.state === "preparing") || label === "Researching" ? "Waiting for the bounded research request to finish. Progress refreshes automatically." : "No completed research report is available for this run."}</p>}
      {run.detail.response_text && run.state !== "completed" && <details className="rounded-md border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Unvalidated response{run.detail.response_truncated ? " (truncated)" : ""}</summary><div className="mt-3 space-y-3"><p className="text-sm text-muted-foreground">{run.detail.validation_error ?? "This response did not produce an accepted report."}</p><pre className="whitespace-pre-wrap break-words text-xs">{run.detail.response_text}</pre></div></details>}
      <details className="rounded-md border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Assignment and provenance</summary><div className="mt-4 space-y-4 break-words text-sm text-muted-foreground">
        <p>{run.config.input.text}</p>
        <p>Original project-authored brief · One request · {run.config.limits.max_output_tokens.toLocaleString()} maximum output tokens · {run.config.limits.timeout_seconds}s request timeout · ${run.config.limits.max_cost_usd} spending limit</p>
        <dl className="space-y-2">{run.detail.fallback_of&&<div><dt>Fallback for run</dt><dd className="break-all">{run.detail.fallback_of}</dd></div>}<div><dt>Run</dt><dd className="break-all">{run.run_key}</dd></div><div><dt>Assignment</dt><dd className="break-all">{run.assignment_id}</dd></div><div><dt>Generation</dt><dd className="break-all">{run.detail.generation_id ?? "Unavailable"}</dd></div><div><dt>Returned model / serving provider</dt><dd className="break-all">{run.detail.returned_model ?? "Unavailable"} / {run.detail.serving_provider ?? "Unavailable"}</dd></div><div><dt>Whitelist revision</dt><dd>{dispatch?.detail.policy_revision ?? "Not dispatched"}</dd></div><div><dt>Request SHA-256</dt><dd className="break-all">{dispatch?.detail.request_sha256 ?? "Not dispatched"}</dd></div></dl>
      </div></details>
      <section className="space-y-3"><h3 className="text-sm font-medium">Run history</h3><ol className="space-y-2">{run.events.map(e=><li key={e.sequence} className="flex flex-wrap justify-between gap-2 border-l-2 border-border pl-3 text-sm"><span>{({admitted:"Assignment queued",preparing:"Preparing model and request",dispatched:"Dispatch intent recorded",completed:"Report recorded",failed:"Run failed",indeterminate:"Outcome unknown"})[e.state]}</span><time className="text-xs text-muted-foreground" dateTime={e.at}>{time(e.at)}</time></li>)}</ol></section>
  </div>;
}
function RunStatus({run}:{run:Run}) {
  const label=stateLabel(run);
  const color=label==="Report ready"?"var(--good)":label==="Failed"?"var(--destructive)":label==="Outcome unknown"?"var(--warning)":label==="Researching"?"var(--primary)":"var(--muted-foreground)";
  const Icon=label==="Report ready"?CheckCircle2:label==="Failed"?XCircle:label==="Preparing"?CircleDashed:Clock3;
  return <Badge variant="outline" className="gap-1.5" style={{color,borderColor:`color-mix(in srgb, ${color} 35%, transparent)`,backgroundColor:`color-mix(in srgb, ${color} 10%, transparent)`}}><Icon className="size-3" aria-hidden="true"/>{label}</Badge>;
}
export function RunCard({run,initiallyOpen=false,initialVersion="current",evaluation,evaluationHistory=[]}:{run:Run;initiallyOpen?:boolean;initialVersion?:string;evaluation?:Evaluation;evaluationHistory?:Evaluation[]}) {
  const [open,setOpen]=useState(initiallyOpen),[version,setVersion]=useState(initialVersion);
  const conversation=useQuery({queryKey:["incubator-chat",run.run_key],enabled:open,queryFn:async()=>{const r=await fetch(`/api/incubator/runs/${encodeURIComponent(run.run_key)}/chat`,{cache:"no-store"});if(!r.ok)throw Error("Plan history unavailable");return await r.json() as Conversation;}});
  const revisions=conversation.data?.plan?.revisions??[],current=revisions.at(-1);
  const selected=version==="current"?current:revisions.find(r=>String(r.revision)===version);
  const viewedRun=selected?{...run,detail:{...run.detail,report:selected.report}}:run;
  return <Dialog.Root open={open} onOpenChange={setOpen}><Dialog.Trigger asChild>
    <button type="button" className="group flex min-h-72 w-full min-w-0 flex-col items-start rounded-xl border border-border bg-card p-5 text-left text-card-foreground transition-colors hover:border-primary/60 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring" aria-label={`Open ${run.config.input.title}, ${stateLabel(run)}, ${time(run.created_at)}`}>
      <span className="flex w-full items-center justify-between gap-2"><RunStatus run={run}/><ArrowUpRight className="size-4 text-muted-foreground transition-colors group-hover:text-primary" aria-hidden="true"/></span>
      <span className="mt-3"><OriginBadge origin={run.created_by??"local_runner"}/></span>
      <span className="mt-5 line-clamp-3 text-base font-medium leading-snug">{run.config.input.title}</span>
      <span className="mt-3 line-clamp-2 break-all text-xs text-muted-foreground">{run.config.model}</span>
      <span className="mt-auto block w-full space-y-1 border-t border-border pt-3 text-xs text-muted-foreground"><span className="block">{run.config.agent_name}</span><time className="block tabular-nums" dateTime={run.created_at}>{time(run.created_at)}</time></span>
      <div className="mt-3 h-8 w-full text-xs text-primary">{evaluation?<EvaluationSummary evaluation={evaluation}/>:<span className="text-muted-foreground">{run.state==="failed"?"Evaluation not reached":"Evaluation follows research"}</span>}</div><WorkflowTimeline run={run} evaluation={evaluation} compact/>
    </button>
  </Dialog.Trigger><Dialog.Portal><Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/><Dialog.Content className="fixed left-1/2 top-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-6xl -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border bg-background text-foreground shadow-xl focus:outline-none">
    <div className="grid shrink-0 gap-5 border-b border-border p-5 pr-16 sm:p-6 sm:pr-16 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.8fr)]"><div><div className="mb-3"><RunStatus run={run}/></div><Dialog.Title className="text-lg font-semibold leading-snug sm:text-xl">{run.config.input.title}</Dialog.Title><Dialog.Description className="mt-2 text-sm text-muted-foreground">{run.config.agent_name} · {time(run.created_at)}</Dialog.Description></div><WorkflowTimeline run={run} evaluation={evaluation}/><Dialog.Close asChild><button type="button" aria-label="Close run details" className="absolute right-3 top-3 grid min-h-11 min-w-11 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring"><X className="size-5" aria-hidden="true"/></button></Dialog.Close></div>
    <Tabs.Root defaultValue="report" className="flex h-[min(72dvh,50rem)] min-h-0 flex-col">
      <Tabs.List aria-label="Run view" className="flex shrink-0 gap-5 border-b border-border px-5 sm:px-6">{["Report","Chat"].map(label=><Tabs.Trigger key={label} value={label.toLowerCase()} className="min-h-11 border-b-2 border-transparent px-1 text-sm text-muted-foreground outline-none data-[state=active]:border-primary data-[state=active]:text-foreground focus-visible:ring-2 focus-visible:ring-ring">{label}</Tabs.Trigger>)}</Tabs.List>
      <Tabs.Content value="report" className="min-h-0 overflow-y-auto overscroll-contain p-5 sm:p-6">{conversation.isError&&<p role="alert" className="mb-4 text-sm text-destructive">Plan revisions could not be refreshed. The displayed version may be outdated.</p>}{!!revisions.length&&<div className="mb-5 flex flex-wrap items-center justify-between gap-3"><label className="flex items-center gap-2 text-sm">Plan version<select aria-label="Plan version" value={version} onChange={e=>setVersion(e.target.value)} className="min-h-11 rounded-md border border-input bg-background px-3"><option value="current">Current · Revision {current?.revision}</option><option value="original">Original report</option>{revisions.slice(0,-1).map(r=><option value={r.revision} key={r.revision}>Revision {r.revision}</option>)}</select></label>{selected&&<span className="text-xs text-muted-foreground">Updated from chat · {time(selected.created_at)}</span>}</div>}<ReportEvaluation evaluations={evaluationHistory.length?evaluationHistory:evaluation?[evaluation]:[]} revision={selected?.revision??0}/><RunDetails run={viewedRun}/></Tabs.Content>
      <Tabs.Content value="chat" className="min-h-0 flex-1 overflow-hidden"><div className="grid h-full min-h-0 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)]"><aside className="hidden overflow-y-auto border-r border-border p-6 lg:block"><h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">{current?`Current hypothesis · Revision ${current.revision}`:"Original hypothesis"}</h3><p className="text-sm leading-relaxed">{current?.report.hypothesis??run.detail.report?.hypothesis??run.config.input.text}</p>{run.detail.report&&<div className="mt-6">{reportList("Proposed experiment",current?.report.experiment??run.detail.report.experiment,true)}</div>}</aside><RunChat run={run}/></div></Tabs.Content>
    </Tabs.Root>
  </Dialog.Content></Dialog.Portal></Dialog.Root>;
}
function reasonText(reason:string) {
  const messages:Record<string,string>={ model_not_whitelisted:"The selected model was not on the saved whitelist. No request was sent.",zero_spend_budget_denied:"The model did not meet this run’s $0 spending limit. No request was sent.",model_policy_changed:"The whitelist changed during preparation. No request was sent.",provider_http_error:"The provider returned an error. Its status is preserved in the run record.",incomplete_response:"The response ended before a complete report was available.",invalid_report:"The response did not match the required report structure.",unexpected_model:"The provider returned a different model than requested.",unexpected_provider_charge:"The provider reported a charge despite the $0 request limit. The lane is paused for reconciliation." };
  return messages[reason] ?? `Run stopped: ${reason.replaceAll("_"," ")}.`;
}
export function IncubatorPage() {
  const query=useQuery(incubatorQuery);
  const workflow=useQuery({queryKey:workflowKey,queryFn:getWorkflow});
  const evaluations=workflow.data??[];
  const evaluationFor=(key:string)=>evaluations.filter(e=>e.run_key===key).sort((a,b)=>b.revision-a.revision)[0];
  const connected=useIncubatorStream();
  const [linkedRevision,setLinkedRevision]=useState("current");
  const [linkedRun,setLinkedRun]=useState<Run|null>(null),[linkError,setLinkError]=useState("");
  useEffect(()=>{
    const key=new URL(window.location.href).searchParams.get("run");
    if(!key)return;
    const revision=new URL(window.location.href).searchParams.get("revision");
    if(revision!==null&&/^\d+$/.test(revision))setLinkedRevision(revision==="0"?"original":revision);
    fetch(`/api/incubator/runs/${encodeURIComponent(key)}`,{cache:"no-store"}).then(async r=>{if(!r.ok)throw Error();return r.json();})
      .then(run=>setLinkedRun(parseRuns({environment:"local_research",artifact_kind:"research_planning",runs:[run]})[0]))
      .catch(()=>setLinkError("The linked assignment could not be loaded."));
  },[]);
  const [search,setSearch]=useState(""),[status,setStatus]=useState("all");
  const runs=query.data??[];
  const visibleRuns=runs.filter(run=>(status==="all"||stateLabel(run)===status)&&[run.config.agent_name,run.config.model,run.config.input.title,run.run_key].join(" ").toLowerCase().includes(search.toLowerCase()));
  return <div className="supervisory-overview" data-display-only="false" data-order-authority="none"><a className="skip-link" href="#incubator-main">Skip to incubator</a><AppSidebar activePage="/incubator"/>
    <main className="overview-main" id="incubator-main" tabIndex={-1}>
      <header className="page-header">
        <div><div className="flex items-center gap-3"><h1>Incubator</h1><Badge variant="outline" role="status" title="Workflow connection" className={connected?"gap-1.5 border-[var(--good)]/35 text-[var(--good)]":"gap-1.5 text-muted-foreground"}><span aria-hidden="true" className={`size-1.5 rounded-full ${connected?"bg-[var(--good)]":"bg-muted-foreground"}`}/>{connected?"Live":"Connecting"}</Badge></div><p>Research assignments, progress, and preserved results.</p></div>
        <div className="ml-auto flex shrink-0 flex-wrap items-center justify-end gap-3"><RefreshQueries label="Refresh runs" iconOnly queryKeys={[incubatorQuery.queryKey,workflowKey]}/><AddAssignment/></div>
      </header>
      <p className="mb-6 max-w-4xl pt-2 text-sm leading-relaxed text-muted-foreground">Research planning only. Reports propose hypotheses and experiments; they contain no validated performance or trading approval.</p>
      {linkError&&<p role="alert" className="mb-4 text-sm text-destructive">{linkError}</p>}
      {linkedRun&&<div className="hidden"><RunCard run={runs.find(r=>r.run_key===linkedRun.run_key)??linkedRun} evaluation={evaluationFor(linkedRun.run_key)} evaluationHistory={evaluations.filter(e=>e.run_key===linkedRun.run_key)} initialVersion={linkedRevision} initiallyOpen/></div>}
      <h2 className="mb-5 text-xl font-semibold">Research</h2>
      {workflow.isError&&<p role="alert" className="mb-4 text-sm text-destructive">Evaluation history is unavailable. Displayed workflow may be outdated.</p>}
      {query.isError && <p role="alert" className="workspace-panel p-4">Run history is unavailable. {query.data ? "The history below may be outdated." : "Refresh to try again."}</p>}
      {query.isPending && <p role="status" className="workspace-panel p-6">Loading research runs…</p>}
      {query.data?.length === 0 && <section className="workspace-panel"><div className="chart-empty"><Bot aria-hidden="true"/><h2>No research runs yet</h2><p>The first bounded assignment will appear here when the local research runner starts.</p><a href="/agents" className="text-primary underline underline-offset-4">View approved models</a></div></section>}
      {!!runs.length&&<div className="mb-5 flex flex-wrap items-center gap-3"><Input className="min-w-0 flex-1 basis-64 sm:max-w-md" aria-label="Search runs" placeholder="Search agents, models, or runs…" value={search} onChange={e=>setSearch(e.target.value)}/><label className="flex items-center gap-2 text-sm text-muted-foreground">Status<select className="min-h-11 rounded-md border border-input bg-background px-3 py-2 text-foreground" value={status} onChange={e=>setStatus(e.target.value)}><option value="all">All statuses ({runs.length})</option>{["Assigned","Preparing","Researching","Report ready","Failed","Outcome unknown"].map(label=><option key={label} value={label}>{label} ({runs.filter(run=>stateLabel(run)===label).length})</option>)}</select></label></div>}
      <div className="grid grid-cols-[repeat(auto-fill,minmax(min(100%,14rem),15rem))] gap-4">{visibleRuns.map(run=><RunCard key={run.run_key} run={run} evaluation={evaluationFor(run.run_key)} evaluationHistory={evaluations.filter(e=>e.run_key===run.run_key)}/>)}</div>
      {!!runs.length&&!visibleRuns.length&&<p className="rounded-xl border border-dashed border-border px-5 py-10 text-sm text-muted-foreground">No runs match your search and status filter.</p>}
      {!!query.data?.length && <p className="pb-6 pt-6 text-xs leading-relaxed text-muted-foreground">Showing {visibleRuns.length} of {query.data.length} assignments · All active work and the latest 100 finished runs.</p>}
      <Experiments evaluations={evaluations}/>
    </main>
  </div>;
}
