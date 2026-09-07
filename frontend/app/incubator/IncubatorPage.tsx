"use client";
import { TicketModelBadge } from "./TicketModelBadge";
import { ticketCardStyles } from "./ticket-card-styles";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowUpRight, CheckCircle2, XCircle, Clock3, CircleDashed, X, Archive, ArchiveRestore, LoaderCircle } from "lucide-react";
import { Dialog, Tabs } from "radix-ui";
import {OriginBadge} from "./OriginBadge";
import {Experiments} from "./Experiments";
import {ReportEvaluation,EvaluationSummary} from "./EvaluationView";
import {getWorkflow,workflowKey,researchStatus,researchHasAdvanced,type Evaluation} from "./evaluation";
import {ResearchReport,reportList} from "./ResearchReport";
import { RunChat } from "./RunChat";
import type { Conversation } from "@/lib/incubator-chat";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { ModelLink } from "@/components/ModelLink";
import { incubatorQuery } from "@/lib/api-queries";
import { AppSidebar } from "../AppSidebar";
import { RefreshQueries } from "../RefreshQueries";
import { costLabel, parseRuns, providerErrorLabel, researchTickets, spendingLimitLabel, stateLabel, type Run } from "./model";

import { CampaignBacklog, CampaignDialog, fetchResearchCampaign, researchCampaignQueryKey, type CampaignView } from "./ResearchCampaign";
import { AddAssignment } from "./AddAssignment";
import { WorkflowTimeline } from "./WorkflowTimeline";
import {STREAM_POLL_INTERVAL_MS} from "./stream-connection";
import { useIncubatorStream } from "./useIncubatorStream";

function time(value: string) { return new Date(value).toLocaleString(); }
export function RunDetails({run}:{run:Run}) {
  const label=stateLabel(run), dispatch=run.events.find(e=>e.state==="dispatched");
  const elapsed=dispatch && ["completed","failed"].includes(run.state) ? Math.max(0,Math.round((Date.parse(run.updated_at)-Date.parse(dispatch.at))/1000)) : null;
  const receipt=run.detail.capacity, attempts=run.detail.capacity_attempts??[], model=run.detail.returned_model??receipt?.model??run.config.model;
  const automaticCapacity=!!receipt&&receipt.trigger!=="manual"&&run.config.limits.spend_policy!=="owner_selected_model"&&run.config.limits.spend_policy!=="campaign_selected_model";
  const nanoCost=(n:number|null)=>costLabel(n===null?null:n/1e9);
  return <div className="space-y-6">
      <dl className="grid min-w-0 grid-cols-2 gap-4 border-y border-border py-4 text-sm lg:grid-cols-4">
        <div className="min-w-0"><dt className="text-xs text-muted-foreground">{receipt?"Final attempt model":"Model"}</dt><dd className="mt-1 break-all"><ModelLink provider="openrouter" id={model} name={model}/></dd></div>
        <div><dt className="text-xs text-muted-foreground">Reported cost</dt><dd className="mt-1 font-medium tabular-nums">{costLabel(run.detail.usage.cost_usd)}</dd></div>
        <div><dt className="text-xs text-muted-foreground">Input / output tokens</dt><dd className="mt-1 tabular-nums">{run.detail.usage.prompt_tokens ?? "—"} / {run.detail.usage.completion_tokens ?? "—"}</dd></div>
        <div><dt className="text-xs text-muted-foreground">Request duration</dt><dd className="mt-1">{elapsed === null ? "Not established" : `${elapsed}s`}</dd></div>
      </dl>
      {receipt&&<section aria-label="Request capacity provenance" className="grid min-w-0 gap-3 rounded-md border border-border p-4 text-sm">
        <h3 className="font-medium">{automaticCapacity?"Automated capacity policy":"Recorded request capacity"}</h3>
        <p>{attempts.length?`${attempts.length} recorded provider attempt${attempts.length===1?"":"s"}`:"Attempt count unavailable"} · Final routing reason: {receipt.trigger.replaceAll("_"," ")}</p>
        <p>Final attempt reservation: {nanoCost(receipt.reserved_nanos)} · Actual recorded cost: {nanoCost(receipt.cost_nanos)}. An unavailable cost is not zero.</p>
        {!!attempts.length&&<ol className="grid gap-3">{attempts.map((attempt,index)=><li key={attempt.capacity?.attempt_id??index} className="min-w-0 border-l-2 border-border pl-3"><p className="break-words">Attempt {index+1} · {attempt.capacity?.model??"Model unavailable"} · {attempt.state}{attempt.http_status?` · HTTP ${attempt.http_status}`:""}</p><p className="text-xs text-muted-foreground">{attempt.capacity?`${attempt.capacity.trigger.replaceAll("_"," ")} · Reserved ${nanoCost(attempt.capacity.reserved_nanos)} · Actual ${nanoCost(attempt.capacity.cost_nanos)}`:"Capacity receipt unavailable"}{attempt.reason?` · ${attempt.reason.replaceAll("_"," ")}`:""}</p></li>)}</ol>}
      </section>}
      {run.detail.reason && <p role="status" className="rounded-md border border-border p-3 text-sm">{reasonText(run.detail.reason,run.detail.http_status)}</p>}
      {run.detail.provider_message&&<p className="text-sm text-muted-foreground">Provider detail: {run.detail.provider_message}</p>}
      {run.detail.provider_limit_source&&<p className="text-sm text-muted-foreground">Limit source: {run.detail.provider_limit_source.replaceAll("_"," ")}</p>}
      {run.detail.provider_remedy&&<p className="text-sm text-muted-foreground">Provider guidance: {run.detail.provider_remedy}</p>}
      {run.detail.retry_after&&<p className="text-sm text-muted-foreground">Provider retry hint: {run.detail.retry_after} (seconds or HTTP date). No retry has been scheduled.</p>}
      {label === "Outcome unknown" && <p className="text-sm text-muted-foreground">The provider may have accepted this request. No automatic retry will occur; the research lane stays paused for reconciliation.</p>}
      {run.detail.report ? <ResearchReport report={run.detail.report}/> : <p className="text-sm text-muted-foreground">{(run.state === "admitted" || run.state === "preparing" || run.state === "research_retry") || label === "Researching" ? "Waiting for the bounded research request to finish. Progress refreshes automatically." : "No completed research report is available for this run."}</p>}
      {run.detail.response_text && run.state !== "completed" && <details className="rounded-md border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Unvalidated response{run.detail.response_truncated ? " (truncated)" : ""}</summary><div className="mt-3 space-y-3"><p className="text-sm text-muted-foreground">{run.detail.validation_error ?? "This response did not produce an accepted report."}</p><pre className="whitespace-pre-wrap break-words text-xs">{run.detail.response_text}</pre></div></details>}
      <details className="rounded-md border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Ticket and provenance</summary><div className="mt-4 space-y-4 break-words text-sm text-muted-foreground">
        <p>{run.config.input.text}</p>
        <p>Original project-authored brief · {receipt?"One logical request with bounded provider attempts":"One request"} · {run.config.limits.max_output_tokens.toLocaleString()} maximum output tokens · {run.config.limits.timeout_seconds}s request timeout · {automaticCapacity?"Automated capacity policy":spendingLimitLabel(run.config.limits)}</p>
        <dl className="space-y-2">{run.detail.fallback_of&&<div><dt>Fallback for run</dt><dd className="break-all">{run.detail.fallback_of}</dd></div>}<div><dt>Run</dt><dd className="break-all">{run.run_key}</dd></div><div><dt>Ticket</dt><dd className="break-all">{run.assignment_id}</dd></div><div><dt>Generation</dt><dd className="break-all">{run.detail.generation_id ?? "Unavailable"}</dd></div><div><dt>Returned model / serving provider</dt><dd className="break-all">{run.detail.returned_model ?? "Unavailable"} / {run.detail.serving_provider ?? "Unavailable"}</dd></div><div><dt>Whitelist revision</dt><dd>{dispatch?.detail.policy_revision ?? "Not dispatched"}</dd></div><div><dt>Request SHA-256</dt><dd className="break-all">{dispatch?.detail.request_sha256 ?? "Not dispatched"}</dd></div></dl>
      </div></details>
      <section className="space-y-3"><h3 className="text-sm font-medium">Run history</h3><ol className="space-y-2">{run.events.map(e=><li key={e.sequence} className="flex flex-wrap justify-between gap-2 border-l-2 border-border pl-3 text-sm"><span>{({admitted:"Ticket queued",preparing:"Preparing model and request",dispatched:"Dispatch intent recorded",completed:"Report recorded",failed:"Run failed",indeterminate:"Outcome unknown",research_retry:"Automatic research retry"})[e.state]}</span><time className="text-xs text-muted-foreground" dateTime={e.at}>{time(e.at)}</time></li>)}</ol></section>
  </div>;
}
function ArchiveResearch({run,onSaved,compact=false}:{run:Run;onSaved:()=>void;compact?:boolean}) {
 const cache=useQueryClient();
 const mutation=useMutation({mutationFn:async(input:{request_id:string;archived:boolean;expected_version:number})=>{
  const response=await fetch(`/api/incubator/runs/${encodeURIComponent(run.run_key)}/archive`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(input)});
  if(!response.ok)throw Error("Could not save archive status. Refresh the ticket and try again.");
 },onSuccess:()=>{void cache.invalidateQueries({queryKey:incubatorQuery.queryKey});onSaved();}});
 const action=()=>mutation.mutate({request_id:crypto.randomUUID(),archived:!run.archived,expected_version:run.archive_version??0});
 const label=run.archived?"Restore research":"Archive research";
 if(compact){const Icon=mutation.isPending?LoaderCircle:run.archived?ArchiveRestore:Archive;return <><Button type="button" variant="ghost" size="icon" className="absolute right-10 top-3 z-10 text-muted-foreground hover:text-foreground disabled:pointer-events-auto" aria-label={`${label}: ${run.config.input.title}`} title={label} disabled={mutation.isPending} onClick={action}><Icon className={`size-4 ${mutation.isPending?"animate-spin":""}`} aria-hidden="true"/></Button>{mutation.isError&&<p role="alert" className="mt-2 px-2 text-xs text-destructive">{mutation.error.message}</p>}</>;}
 return <div className="mb-5 rounded-lg border border-border p-3"><div className="flex flex-wrap items-center justify-between gap-3"><p className="text-xs text-muted-foreground">{run.archived?"Archived research · Report, chat, and linked experiments are preserved.":"Archive hides this ticket from the default list. It does not stop work or archive linked experiments."}</p><Button variant="outline" disabled={mutation.isPending} onClick={action}>{mutation.isPending?"Saving…":run.archived?"Restore research":"Archive research"}</Button></div>{mutation.isError&&<p role="alert" className="mt-2 text-sm text-destructive">{mutation.error.message}</p>}</div>;
}
function RunStatus({run,evaluation}:{run:Run;evaluation?:Evaluation}) {
  const label=researchStatus(run,evaluation);
  const color=label==="Advanced"?"var(--primary)":label==="Report ready"?"var(--good)":label==="Failed"?"var(--destructive)":label==="Outcome unknown"?"var(--warning)":label==="Researching"?"var(--primary)":"var(--muted-foreground)";
  const Icon=["Advanced","Report ready"].includes(label)?CheckCircle2:label==="Failed"?XCircle:label==="Preparing"?CircleDashed:Clock3;
  return <Badge variant="outline" className="gap-1.5" style={{color,borderColor:`color-mix(in srgb, ${color} 35%, transparent)`,backgroundColor:`color-mix(in srgb, ${color} 10%, transparent)`}}><Icon className="size-3" aria-hidden="true"/>{label}</Badge>;
}
export function RunCard({run,initiallyOpen=false,initialVersion="current",evaluation,evaluationHistory=[],fallbacks=[]}:{fallbacks?:Run[];run:Run;initiallyOpen?:boolean;initialVersion?:string;evaluation?:Evaluation;evaluationHistory?:Evaluation[]}) {
  const [open,setOpen]=useState(initiallyOpen),[version,setVersion]=useState(initialVersion);
  const conversation=useQuery({queryKey:["incubator-chat",run.run_key,evaluation?.revision??0],enabled:open,queryFn:async()=>{const r=await fetch(`/api/incubator/runs/${encodeURIComponent(run.run_key)}/chat`,{cache:"no-store"});if(!r.ok)throw Error("Plan history unavailable");return await r.json() as Conversation;}});
  const revisions=conversation.data?.plan?.revisions??[],current=revisions.at(-1);
  const selected=version==="current"?current:revisions.find(r=>String(r.revision)===version);
  const viewedRun=selected?{...run,detail:{...run.detail,report:selected.report}}:run;
  return <Dialog.Root open={open} onOpenChange={setOpen}><div className="relative flex min-w-0 flex-col"><Dialog.Trigger asChild>
    <button type="button" className={ticketCardStyles.surface} aria-label={`Open ${run.config.input.title}, ${researchStatus(run,evaluation)}, ${time(run.created_at)}`}>
      <span className="flex w-full items-start justify-between gap-3"><span className="flex min-w-0 flex-wrap gap-2 pr-7"><TicketModelBadge model={run.config.model}/>{run.archived&&<Badge variant="outline">Archived</Badge>}</span><ArrowUpRight className="size-4 shrink-0 text-muted-foreground transition-colors group-hover:text-primary" aria-hidden="true"/></span>
      <span className={ticketCardStyles.title}>{run.config.input.title}</span>
      <span className={ticketCardStyles.preview}>{evaluation?.report.hypothesis??run.detail.report?.hypothesis??run.config.input.text}</span>
      <div className={ticketCardStyles.footer}><span className="block break-all">{run.config.model} · {run.config.agent_name}</span><time className="block tabular-nums" dateTime={run.created_at}>{time(run.created_at)}</time>{fallbacks.map(attempt=><span key={attempt.run_key} className="block">Fallback attempt: {stateLabel(attempt)}</span>)}
      <div className="pt-2 text-xs text-primary">{evaluation?<EvaluationSummary evaluation={evaluation}/>:<span className="text-muted-foreground">{run.state==="failed"?"Evaluation not reached":"Evaluation follows research"}</span>}</div><WorkflowTimeline run={run} evaluation={evaluation} compact/></div>
    </button>
  </Dialog.Trigger><ArchiveResearch run={run} compact onSaved={()=>setOpen(false)}/></div><Dialog.Portal><Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/><Dialog.Content className="fixed left-1/2 top-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-6xl -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border bg-background text-foreground shadow-xl focus:outline-none">
    <div className="grid shrink-0 gap-5 border-b border-border p-5 pr-16 sm:p-6 sm:pr-16 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.8fr)]"><div><div className="mb-3"><RunStatus run={run} evaluation={evaluation}/></div><Dialog.Title className="text-lg font-semibold leading-snug sm:text-xl">{run.config.input.title}</Dialog.Title><Dialog.Description className="mt-2 text-sm text-muted-foreground">{run.config.agent_name} · {time(run.created_at)}</Dialog.Description></div><WorkflowTimeline run={run} evaluation={evaluation}/><Dialog.Close asChild><button type="button" aria-label="Close run details" className="absolute right-3 top-3 grid min-h-11 min-w-11 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring"><X className="size-5" aria-hidden="true"/></button></Dialog.Close></div>
    <Tabs.Root defaultValue="report" className="flex h-[min(72dvh,50rem)] min-h-0 flex-col">
      <Tabs.List aria-label="Run view" className="flex shrink-0 gap-5 border-b border-border px-5 sm:px-6">{["Report","Chat"].map(label=><Tabs.Trigger key={label} value={label.toLowerCase()} className="min-h-11 border-b-2 border-transparent px-1 text-sm text-muted-foreground outline-none data-[state=active]:border-primary data-[state=active]:text-foreground focus-visible:ring-2 focus-visible:ring-ring">{label}</Tabs.Trigger>)}</Tabs.List>
      <Tabs.Content value="report" className="min-h-0 overflow-y-auto overscroll-contain p-5 sm:p-6"><ArchiveResearch run={run} onSaved={()=>setOpen(false)}/>{conversation.isError&&<p role="alert" className="mb-4 text-sm text-destructive">Plan revisions could not be refreshed. The displayed version may be outdated.</p>}{!!revisions.length&&<div className="mb-5 flex flex-wrap items-center justify-between gap-3"><label className="flex items-center gap-2 text-sm">Plan version<select aria-label="Plan version" value={version} onChange={e=>setVersion(e.target.value)} className="min-h-11 rounded-md border border-input bg-background px-3"><option value="current">Current · Revision {current?.revision}</option><option value="original">Original report</option>{revisions.slice(0,-1).map(r=><option value={r.revision} key={r.revision}>Revision {r.revision}</option>)}</select></label>{selected&&<span className="text-xs text-muted-foreground">Report revised · {time(selected.created_at)}</span>}</div>}<ReportEvaluation evaluations={evaluationHistory.length?evaluationHistory:evaluation?[evaluation]:[]} revision={selected?.revision??0}/><RunDetails run={viewedRun}/>{fallbacks.map(attempt=><details key={attempt.run_key} className="mt-6 rounded-lg border border-border p-4"><summary className="cursor-pointer text-sm font-medium">Fallback attempt · {attempt.config.model} · {stateLabel(attempt)}</summary><p className="my-3 text-xs text-muted-foreground">A separate attempt for this ticket after the original model failed.{attempt.archived?" This attempt was archived.":""}</p><RunDetails run={attempt}/><a className="mt-3 inline-block text-sm text-primary underline" href={`/incubator?run=${encodeURIComponent(attempt.run_key)}`}>Open attempt and chat</a></details>)}</Tabs.Content>
      <Tabs.Content value="chat" className="min-h-0 flex-1 overflow-hidden"><div className="grid h-full min-h-0 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)]"><aside className="hidden overflow-y-auto border-r border-border p-6 lg:block"><h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">{current?`Current hypothesis · Revision ${current.revision}`:"Original hypothesis"}</h3><p className="text-sm leading-relaxed">{current?.report.hypothesis??run.detail.report?.hypothesis??run.config.input.text}</p>{run.detail.report&&<div className="mt-6">{reportList("Proposed experiment",current?.report.experiment??run.detail.report.experiment,true)}</div>}</aside><RunChat run={run}/></div></Tabs.Content>
    </Tabs.Root>
  </Dialog.Content></Dialog.Portal></Dialog.Root>;
}
function reasonText(reason:string,httpStatus:number|null) {
  if(reason==="provider_http_error")return providerErrorLabel(httpStatus);
  const messages:Record<string,string>={ model_capabilities_unavailable:"OpenRouter did not provide model capabilities. Refresh the catalog and try again.", model_text_research_unsupported:"This model does not support text research.", model_output_limit_unsupported:"This model does not advertise an output token limit, so a bounded research request cannot be sent.", model_not_whitelisted:"The selected model was not on the saved whitelist. No request was sent.",zero_spend_budget_denied:"The model did not meet this run’s $0 spending limit. No request was sent.",model_policy_changed:"The whitelist changed during preparation. No request was sent.",provider_http_error:"The provider returned an error. Its status is preserved in the run record.",incomplete_response:"The response ended before a complete report was available.",invalid_report:"The response did not match the required report structure.",unexpected_model:"The provider returned a different model than requested.",unexpected_provider_charge:"The provider reported a charge despite the $0 request limit. The lane is paused for reconciliation." };
  return messages[reason] ?? `Run stopped: ${reason.replaceAll("_"," ")}.`;
}
export function IncubatorPage() {
  const connection=useIncubatorStream(),connected=connection==="live";
  const refetchInterval=connection==="polling"?STREAM_POLL_INTERVAL_MS:false;
  const query=useQuery({...incubatorQuery,refetchInterval});
  const campaign=useQuery({queryKey:researchCampaignQueryKey,queryFn:fetchResearchCampaign,refetchInterval:connection==="polling"?STREAM_POLL_INTERVAL_MS:10000});
  const workflow=useQuery({queryKey:workflowKey,queryFn:getWorkflow,refetchInterval});
  const evaluations=workflow.data??[];
  const evaluationFor=(key:string)=>evaluations.filter(e=>e.run_key===key).sort((a,b)=>b.revision-a.revision)[0];
  const [linkedRevision,setLinkedRevision]=useState("current");
  const [linkedRun,setLinkedRun]=useState<Run|null>(null),[linkError,setLinkError]=useState("");
  useEffect(()=>{
    const key=new URL(window.location.href).searchParams.get("run");
    if(!key)return;
    const revision=new URL(window.location.href).searchParams.get("revision");
    if(revision!==null&&/^\d+$/.test(revision))setLinkedRevision(revision==="0"?"original":revision);
    fetch(`/api/incubator/runs/${encodeURIComponent(key)}`,{cache:"no-store"}).then(async r=>{if(!r.ok)throw Error();return r.json();})
      .then(run=>setLinkedRun(parseRuns({environment:"local_research",artifact_kind:"research_planning",runs:[run]})[0]))
      .catch(()=>setLinkError("The linked ticket could not be loaded."));
  },[]);
  const [search,setSearch]=useState(""),[archiveView,setArchiveView]=useState<CampaignView>("current");
  const runs=query.data??[];
  const scopedRuns=researchTickets(runs).filter(run=>!researchHasAdvanced(evaluationFor(run.run_key))).filter(run=>archiveView!=="duplicates").filter(run=>Boolean(run.archived)===(archiveView==="archived"));
  const visibleRuns=scopedRuns.filter(run=>[run.config.agent_name,run.config.model,run.config.input.title,run.run_key].join(" ").toLowerCase().includes(search.toLowerCase()));
  return <div className="supervisory-overview" data-display-only="false" data-order-authority="none"><a className="skip-link" href="#incubator-main">Skip to incubator</a><AppSidebar activePage="/incubator"/>
    <main className="overview-main" id="incubator-main" tabIndex={-1}>
      <header className="page-header">
        <div><div className="flex items-center gap-3"><h1>Incubator</h1><Badge variant="outline" role="status" title="Workflow connection" className={connected?"gap-1.5 border-[var(--good)]/35 text-[var(--good)]":"gap-1.5 text-muted-foreground"}><span aria-hidden="true" className={`size-1.5 rounded-full ${connected?"bg-[var(--good)]":"bg-muted-foreground"}`}/>{connected?"Live":connection==="polling"?"Periodic refresh":"Connecting"}</Badge></div><p>Research tickets, progress, and preserved results.</p></div>
      </header>
      {linkError&&<p role="alert" className="mb-4 text-sm text-destructive">{linkError}</p>}
      {linkedRun&&<div className="hidden"><RunCard run={runs.find(r=>r.run_key===linkedRun.run_key)??linkedRun} evaluation={evaluationFor(linkedRun.run_key)} evaluationHistory={evaluations.filter(e=>e.run_key===linkedRun.run_key)} initialVersion={linkedRevision} initiallyOpen/></div>}
      {workflow.isError&&<p role="alert" className="mb-4 text-sm text-destructive">Evaluation history is unavailable. Displayed workflow may be outdated.</p>}
      <div role="region" aria-label="Research filters and actions" className="sticky top-0 z-30 mb-5 flex flex-wrap items-center gap-3 border-b border-border bg-background py-3 shadow-[0_4px_8px_-6px_rgba(0,0,0,0.35)]">
        <Input className="min-h-11 min-w-0 flex-1 basis-64 xl:max-w-md" aria-label="Search runs" placeholder="Search agents, models, or runs…" value={search} onChange={e=>setSearch(e.target.value)}/><label className="flex flex-col items-start gap-1 text-sm text-muted-foreground sm:flex-row sm:items-center sm:gap-2">View<select aria-label="Research view" value={archiveView} onChange={e=>setArchiveView(e.target.value as CampaignView)} className="min-h-11 rounded-md border border-input bg-background px-3 text-foreground"><option value="current">Current</option><option value="archived">Archived</option><option value="duplicates">Duplicates</option></select></label>
        <div className="ml-auto flex shrink-0 flex-wrap items-center justify-end gap-3"><RefreshQueries label="Refresh runs" iconOnly queryKeys={[incubatorQuery.queryKey,workflowKey,researchCampaignQueryKey]}/><CampaignDialog/><AddAssignment/></div>
      </div>
      <Experiments evaluations={evaluations} runs={runs}/>
      <div className="mb-4 mt-6 border-t border-border pt-5"><h2 className="text-xl font-semibold">Research <span className="ml-2 text-sm font-normal text-muted-foreground">{scopedRuns.length}</span></h2></div>

      {connection==="polling"&&<p role="status" className="text-sm text-muted-foreground">Live updates are unavailable. Refreshing tickets every 5 seconds while the connection retries.</p>}
      {query.isError && <p role="alert" className="workspace-panel p-4">Run history is unavailable. {query.data ? "The history below may be outdated." : "Refresh to try again."}</p>}
      {query.isPending && <p role="status" className="workspace-panel p-6">Loading research runs…</p>}
      {archiveView!=="duplicates"&&!query.isPending&&!visibleRuns.length&&<div className={ticketCardStyles.empty}>{archiveView==="archived"?"No archived research.":"No current research."}</div>}

      <div className={ticketCardStyles.grid}>{visibleRuns.map(run=><RunCard key={run.run_key} run={run} fallbacks={runs.filter(attempt=>attempt.detail.fallback_of===run.run_key)} evaluation={evaluationFor(run.run_key)} evaluationHistory={evaluations.filter(e=>e.run_key===run.run_key)}/>)}</div>
      {campaign.isError&&<p role="alert" className="text-sm text-destructive">Seed proposals could not be refreshed. Displayed proposals may be outdated.</p>}<CampaignBacklog campaign={campaign.data} view={archiveView} search={search}/>
    </main>
  </div>;
}
