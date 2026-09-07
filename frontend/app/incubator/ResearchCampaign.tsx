"use client";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Dialog, Tabs } from "radix-ui";
import { ArrowUpRight, LoaderCircle, Plus, X } from "lucide-react";
import {modelRoutingQuery} from "@/lib/api-queries";
import { Button } from "@/components/ui/button";
import { TicketModelBadge } from "./TicketModelBadge";
import { ticketCardStyles } from "./ticket-card-styles";
import { ProgressFooter, type ProgressStep } from "./ProgressFooter";

type Usage = {calls:number; input_tokens:number; output_tokens:number; reasoning_tokens:number; unknown_token_calls:number; known_cost_usd:number; unknown_cost_calls:number};
export type CampaignAgenda = { retry_of?:number|null; retry_candidate?:number|null; retry_blocker?:string|null; request_id?:string|null; check_input?:unknown; creator_call?:unknown; check_requests?:unknown[]; ordinal: number; generation_id: number; creator_model?: string; check?: {attempts?:{batch:number;model:string;state:string;detail:Record<string,unknown>}[];issues?:string[];matches?:{id:string;title:string;reason:string;run_key:string}[]}; title: string; premise?: string; state: string; reason: string | null; run_key: string | null;
  spec: {runner?: string; lookback_sessions?: number; quantile_count?: number; one_way_cost_bps?: number; borrow_bps_per_session?: number};
  scope: {start: string; end: string} | null };
export type Campaign = {
  creator_in_progress?: boolean;
  creator_usage?:{lifetime:Usage;last_24h:Usage}; creator_calls?:{diagnostics?:unknown;request_id?:string;request?:unknown;finish_reason?:string|null;id:number;model:string;state:string;reason?:string|null;response_text?:string|null;validation_error?:string|null;response_truncated?:boolean;cost_usd:number|null;usage:{prompt_tokens?:number;completion_tokens?:number}|null}[];
  creator_model: string; backlog_limit: number; backlog_count: number; creator_status: string | null; target: number; created_count: number; completed_count: number; enabled: boolean; revision: number; daily_limit: number; open_limit: number;
  next_at: string; note: string; open_count: number; attempts_today: number; symbols: string[];
  agenda: CampaignAgenda[];
};
export const researchCampaignQueryKey = ["research-campaign"] as const;
async function response(r: Response): Promise<Campaign> {
  const body = await r.json();
  if (!r.ok) throw Error(body.error ?? "Campaign unavailable");
  return body;
}
export async function fetchResearchCampaign(): Promise<Campaign> {
  return response(await fetch("/api/incubator/campaign", {cache:"no-store"}));
}
const stateLabel: Record<string,string> = {pending:"Created",checking:"Checking exact case",queued:"Queued",duplicate:"Duplicate",blocked:"Failed",cancelled:"Cancelled"};
export function candidateProgress(state:string):ProgressStep[] {
  const check:ProgressStep["state"]=state==="checking"?"active":state==="blocked"?"failed":["duplicate","cancelled"].includes(state)?"paused":state==="queued"?"complete":"pending";
  return [{label:"Created",state:"complete"},{label:state==="duplicate"?"Duplicate":state==="cancelled"?"Cancelled":state==="blocked"?"Failed":"Check",state:check},{label:"Research",state:"pending"},{label:"Experiment",state:"pending"}];
}
function RequestEvidence({label, value}:{label:string;value:unknown}) {
  return <details className="mt-3 text-sm"><summary className="cursor-pointer text-primary">{label}</summary><pre className="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md border border-border p-3 text-xs">{JSON.stringify(value,null,2)}</pre></details>;
}
function RetryCandidate({candidate}:{candidate:CampaignAgenda}) {
  const client=useQueryClient();
  const campaign=useQuery({queryKey:researchCampaignQueryKey,queryFn:fetchResearchCampaign});
  const retry=useMutation({mutationFn:async()=>response(await fetch("/api/incubator/campaign/retry",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({ordinal:candidate.ordinal,revision:campaign.data?.revision})})),onSuccess:data=>client.setQueryData(researchCampaignQueryKey,data)});
  if(!["blocked","cancelled"].includes(candidate.state))return null;
  return <div className="mb-5 space-y-2 text-sm">
    {candidate.retry_candidate?<p>Retry queued as proposal #{candidate.retry_candidate}. The original check remains recorded.</p>:<>
      <Button variant="outline" disabled={retry.isPending||!campaign.data||!!candidate.retry_blocker} onClick={()=>retry.mutate()}>{retry.isPending?"Queuing retry…":"Queue fresh check"}</Button>
      <p className="text-muted-foreground">{candidate.retry_blocker??"Creates a linked proposal with a new similarity check under the current campaign limits. A paused campaign stays paused until enabled."}</p>
    </>}
    {retry.isError&&<p role="alert" className="text-destructive">{retry.error.message}</p>}
  </div>;
}
function CandidateCard({candidate,model}:{candidate:CampaignAgenda;model:string}) {
  const spec = candidate.spec;
  model = candidate.creator_model ?? model;
  const waiting = ["pending", "checking"].includes(candidate.state);
  const explanation = candidate.reason ?? (candidate.state === "checking" ? "Exact-case checking is in progress. Research has not started." : "This proposal is waiting for a research worker. Research begins after the exact-case check.");
  const state = stateLabel[candidate.state]??candidate.state;
  return <Dialog.Root>
    <article className="flex min-w-0">
      <Dialog.Trigger asChild>
        <button type="button" className={ticketCardStyles.surface} aria-label={`Open campaign ticket ${candidate.title}, ${state}`}>
          <span className="flex w-full items-start justify-between gap-3"><span className="flex min-w-0 flex-wrap gap-2"><TicketModelBadge model={candidate.creator_model??model}/></span><span className="flex items-center gap-2 text-xs tabular-nums text-muted-foreground">#{candidate.ordinal}<ArrowUpRight className="size-4 transition-colors group-hover:text-primary" aria-hidden="true"/></span></span>
          <span className={ticketCardStyles.title}>{candidate.title}</span>
          {candidate.reason&&<span className="mt-2 text-xs text-muted-foreground">{candidate.reason}</span>}
          {candidate.premise&&<span className={ticketCardStyles.preview}>{candidate.premise}</span>}
          <div className={ticketCardStyles.footer}><ProgressFooter label="Backlog workflow" steps={candidateProgress(candidate.state)}/></div>
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/>
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-6xl -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border bg-background text-foreground shadow-xl focus:outline-none">
          <div className="grid shrink-0 gap-5 border-b border-border p-5 pr-16 sm:p-6 sm:pr-16 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.8fr)]"><div><div className="mb-3 flex flex-wrap gap-2"><span className="rounded-full border border-primary/35 bg-primary/10 px-2.5 py-1 text-xs font-medium text-primary">Campaign ticket</span><span className="rounded-full border border-border px-2.5 py-1 text-xs text-muted-foreground">{state}</span></div><Dialog.Title className="text-lg font-semibold leading-snug sm:text-xl">{candidate.title}</Dialog.Title><Dialog.Description className="mt-2 text-sm text-muted-foreground">Ticket Creator · Generation #{candidate.generation_id} · {state}</Dialog.Description></div><div className="min-w-0"><p className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">Workflow</p><ProgressFooter compact={false} steps={candidateProgress(candidate.state)}/></div><Dialog.Close asChild><button type="button" aria-label="Close campaign ticket" className="absolute right-3 top-3 grid min-h-11 min-w-11 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring"><X className="size-5" aria-hidden="true"/></button></Dialog.Close></div>
          <Tabs.Root defaultValue="report" className="flex h-[min(72dvh,50rem)] min-h-0 flex-col">
            <Tabs.List aria-label="Campaign ticket view" className="flex shrink-0 gap-5 border-b border-border px-5 sm:px-6"><Tabs.Trigger value="report" className="min-h-11 border-b-2 border-transparent px-1 text-sm text-muted-foreground outline-none data-[state=active]:border-primary data-[state=active]:text-foreground focus-visible:ring-2 focus-visible:ring-ring">Report</Tabs.Trigger><Tabs.Trigger value="chat" className="min-h-11 border-b-2 border-transparent px-1 text-sm text-muted-foreground outline-none data-[state=active]:border-primary data-[state=active]:text-foreground focus-visible:ring-2 focus-visible:ring-ring">Chat</Tabs.Trigger></Tabs.List>
            <Tabs.Content value="report" className="min-h-0 overflow-y-auto overscroll-contain p-5 sm:p-6"><p role="status" className="mb-5 rounded-lg border border-border bg-card p-4 text-sm text-muted-foreground">{explanation}</p><RetryCandidate candidate={candidate}/>{candidate.retry_of&&<p className="mb-3 text-sm">Retry of proposal #{candidate.retry_of}</p>}{candidate.request_id&&<p className="mb-3 break-all text-xs text-muted-foreground">Check request: {candidate.request_id}</p>}{candidate.check?.issues?.map(issue=><p key={issue} className="mb-3 text-sm text-muted-foreground">{issue.replaceAll("_"," ")}</p>)}{candidate.check?.attempts?.map((attempt,index)=><div key={`${attempt.batch}-${index}`} className="mb-4 text-sm"><p>Batch {attempt.batch+1} · {attempt.model} · {attempt.state}</p>{typeof attempt.detail.validation_error==="string"&&<p className="mt-1 text-destructive">{attempt.detail.validation_error}</p>}<RequestEvidence label="Recorded check response and diagnostics" value={attempt.detail}/></div>)}{!!candidate.check_input&&<RequestEvidence label="Original check input" value={candidate.check_input}/>} {!!candidate.creator_call&&<RequestEvidence label={`Creator request ticket-creator:${candidate.generation_id}`} value={candidate.creator_call}/>} {!!candidate.check_requests?.length&&<RequestEvidence label="Exact check requests" value={candidate.check_requests}/>} {!!candidate.check?.matches?.length&&<section className="mb-5 space-y-3"><h3 className="text-sm font-medium">Similar research</h3>{candidate.check.matches.map(match=><div key={match.id} className="border-l-2 border-border pl-3 text-sm"><a className="text-primary underline" href={`/incubator?run=${encodeURIComponent(match.run_key)}`}>{match.title}</a><p className="mt-1 text-muted-foreground">{match.reason}</p></div>)}</section>}<dl className="grid min-w-0 grid-cols-2 gap-4 border-y border-border py-4 text-sm lg:grid-cols-4"><div className="min-w-0"><dt className="text-xs text-muted-foreground">Ticket Creator model</dt><dd className="mt-1 break-all">{model}</dd></div><div><dt className="text-xs text-muted-foreground">Research cost</dt><dd className="mt-1 font-medium">Not established</dd></div><div><dt className="text-xs text-muted-foreground">Research tokens</dt><dd className="mt-1">— / —</dd></div><div><dt className="text-xs text-muted-foreground">Request duration</dt><dd className="mt-1">Not established</dd></div></dl><section className="mt-6 space-y-3"><h3 className="text-sm font-medium">Research premise</h3><p className="whitespace-pre-wrap text-sm leading-relaxed">{candidate.premise??"No premise was recorded."}</p></section><section className="mt-6 space-y-3"><h3 className="text-sm font-medium">Diagnostic specification</h3><dl className="grid gap-3 border-y border-border py-4 text-sm sm:grid-cols-2"><div><dt className="text-xs text-muted-foreground">Runner</dt><dd className="mt-1">{spec.runner??"—"}</dd></div><div><dt className="text-xs text-muted-foreground">Lookback</dt><dd className="mt-1">{spec.lookback_sessions??"—"} sessions</dd></div><div><dt className="text-xs text-muted-foreground">Quantiles</dt><dd className="mt-1">{spec.quantile_count??"—"}</dd></div><div><dt className="text-xs text-muted-foreground">One-way cost</dt><dd className="mt-1">{spec.one_way_cost_bps??"—"} bps</dd></div><div><dt className="text-xs text-muted-foreground">Borrow cost</dt><dd className="mt-1">{spec.borrow_bps_per_session??"—"} bps / session</dd></div><div><dt className="text-xs text-muted-foreground">Creator model</dt><dd className="mt-1 break-all">{model}</dd></div></dl></section>{candidate.scope&&<section className="mt-6 space-y-2"><h3 className="text-sm font-medium">Pinned data scope</h3><p className="text-sm text-muted-foreground">{candidate.scope.start} – {candidate.scope.end} · SPY benchmark · approved campaign symbols</p></section>}<section className="mt-6 space-y-3"><h3 className="text-sm font-medium">Run history</h3><ol className="space-y-2"><li className="flex flex-wrap justify-between gap-2 border-l-2 border-border pl-3 text-sm"><span>Ticket created</span><span className="text-xs text-muted-foreground">Generation #{candidate.generation_id}</span></li></ol></section></Tabs.Content>
            <Tabs.Content value="chat" className="min-h-0 flex-1 overflow-y-auto p-5 sm:p-6"><div className="grid min-h-full place-items-center rounded-lg border border-dashed border-border p-6 text-center"><div><h3 className="text-sm font-medium">Research chat is not available yet</h3><p className="mt-2 max-w-md text-sm text-muted-foreground">{waiting ? "A research worker will open the conversation after this proposal passes the exact-case check." : "This proposal did not start research. Its recorded outcome is available in Report."}</p></div></div></Tabs.Content>
          </Tabs.Root>
        </Dialog.Content>
      </Dialog.Portal>
    </article>
  </Dialog.Root>;
}
export type CampaignView = "current" | "archived" | "duplicates";
export function campaignCandidateStatus(state:string) { return stateLabel[state]??state; }
export function campaignCandidates(campaign:Campaign|null|undefined, view:CampaignView, search="", status="all") {
  return (campaign?.agenda??[]).filter(candidate=>!candidate.run_key && (view==="duplicates" ? candidate.state==="duplicate" : view==="archived" ? !!candidate.retry_candidate && ["blocked","cancelled"].includes(candidate.state) : view==="current" && candidate.state!=="duplicate" && !candidate.retry_candidate) && (status==="all"||campaignCandidateStatus(candidate.state)===status) && [candidate.title,candidate.premise,candidate.creator_model??campaign?.creator_model,String(candidate.ordinal)].join(" ").toLowerCase().includes(search.toLowerCase()));
}
function campaignBacklogEmpty(view:CampaignView):string {
  switch (view) {
    case "duplicates": return "No duplicate proposals.";
    case "archived": return "No archived campaign checks.";
    case "current": return "No current campaign backlog.";
    default: {
      const _exhaustive: never = view;
      return _exhaustive;
    }
  }
}
export function CampaignBacklog({campaign,view="current",search="",status="all"}:{campaign:Campaign|null|undefined;view?:CampaignView;search?:string;status?:string}) {
  const candidates = campaignCandidates(campaign,view,search,status);
  const heading = view==="duplicates" ? "Duplicate proposals" : view==="archived" ? "Archived campaign checks" : "Campaign backlog";
  const blurb = view==="duplicates" ? "Preserved proposals that matched an exact diagnostic case. Open a card to inspect the match." : view==="archived" ? "Failed or cancelled checks that already have a retry. Open a card to inspect the original result." : "Waiting and stopped proposals. A failed check stays on file; its retry card is the one workers pick up.";
  return <section aria-labelledby="campaign-backlog-heading" className="mt-6 mb-8 border-t border-border pt-5">
    <div className="mb-3 flex flex-wrap items-end justify-between gap-3"><div><h2 id="campaign-backlog-heading" className="text-xl font-semibold">{heading}</h2><p className="mt-1 text-sm text-muted-foreground">{blurb}</p></div><span className="text-sm tabular-nums text-muted-foreground">{candidates.length} shown · latest 100 proposals</span></div>
    {!candidates.length
      ? <div className={ticketCardStyles.empty}>{campaignBacklogEmpty(view)}</div>
      : <div className={ticketCardStyles.grid}>{candidates.map(candidate=><CandidateCard key={candidate.ordinal} candidate={candidate} model={campaign!.creator_model}/>)}</div>}
  </section>;
}
export function ResearchCampaign() {
  const client = useQueryClient();
  const routing = useQuery(modelRoutingQuery);
  const models = routing.data?.models.map(m=>m.routes[0]).filter(r=>r.provider==="openrouter")??[];
  const [creator, setCreator] = useState<string | null>(null), [backlog,setBacklog]=useState<number | null>(null);
  const query = useQuery({ queryKey: researchCampaignQueryKey, queryFn: fetchResearchCampaign, refetchInterval: 10000 });
  const [daily, setDaily] = useState<number | null>(null), [open, setOpen] = useState<number | null>(null);
  const save = useMutation({ mutationFn: (enabled: boolean) => fetch("/api/incubator/campaign", {
    method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({ enabled,
      creator_model: creator??query.data?.creator_model??"", backlog_limit: backlog??query.data?.backlog_limit, revision: query.data?.revision, daily_limit: daily ?? query.data?.daily_limit, open_limit: open ?? query.data?.open_limit })
  }).then(response), onSuccess: data => {client.setQueryData(researchCampaignQueryKey, data); setDaily(null); setOpen(null); setCreator(null); setBacklog(null);} });
  const c = query.data;
  const stopping = !c?.enabled && !!c?.creator_in_progress;
  const pendingSettings = daily!==null||open!==null||creator!==null||backlog!==null;
  const campaignActionLabel = save.isPending ? "Saving…" : stopping ? "Stopping generation…" : !c?.enabled ? "Enable campaign" : c.creator_in_progress ? "Stop generation" : "Pause campaign";
  return <section className="mb-6 rounded-xl border border-border bg-card p-5" aria-label="Research campaign">
    <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-lg font-semibold">Research campaign</h2><span className="text-sm text-muted-foreground">{c ? c.enabled ? "Enabled" : "Paused" : "Loading"}</span></div>
    <p className="mt-2 text-sm text-muted-foreground">One Ticket Creator model proposes a backlog of research questions. Free research workers take tickets as capacity permits, then evaluation and experiments follow.</p>
    {query.isError && <p role="alert" className="mt-3 text-sm text-destructive">Campaign could not be refreshed. <button className="underline" onClick={()=>query.refetch()}>Retry</button></p>}
    {c && <>
      <p role="status" className="mt-3 text-sm">{c.note}</p>
      <div className="mt-4 grid grid-cols-2 gap-2 text-xs sm:grid-cols-4"><div className="rounded-lg border border-border/70 bg-background/40 p-3"><p className="text-muted-foreground">Experiments</p><p className="mt-1 text-sm font-medium tabular-nums">{c.completed_count} / {c.target}</p></div><div className="rounded-lg border border-border/70 bg-background/40 p-3"><p className="text-muted-foreground">Backlog</p><p className="mt-1 text-sm font-medium tabular-nums">{c.backlog_count}</p></div><div className="rounded-lg border border-border/70 bg-background/40 p-3"><p className="text-muted-foreground">Creator</p><p className="mt-1 text-sm font-medium capitalize">{c.creator_status??"idle"}</p></div><div className="rounded-lg border border-border/70 bg-background/40 p-3"><p className="text-muted-foreground">Unfinished</p><p className="mt-1 text-sm font-medium tabular-nums">{c.open_count}</p></div></div>
      <p className="mt-3 text-xs text-muted-foreground">{c.created_count} tickets created · {c.attempts_today} candidates checked in the last 24 hours</p>
      {c.creator_usage&&<details className="mt-4"><summary className="cursor-pointer text-sm font-medium text-primary">Ticket Creator usage · ${Number(c.creator_usage.last_24h.known_cost_usd).toFixed(4)} reported in 24h{c.creator_usage.last_24h.unknown_cost_calls>0?` · ${c.creator_usage.last_24h.unknown_cost_calls} costs pending`:""}</summary>
        <div className="mt-3 space-y-2 text-sm">{(["last_24h","lifetime"] as const).map(period=>{const u=c.creator_usage![period];return <p key={period}>{period==="last_24h"?"Last 24 hours":"Lifetime"}: {u.calls} calls · {u.input_tokens.toLocaleString()} input / {u.output_tokens.toLocaleString()} output tokens · {u.reasoning_tokens.toLocaleString()} reported reasoning tokens (included in output) · ${Number(u.known_cost_usd).toFixed(4)} reported · {u.unknown_cost_calls} costs pending · {u.unknown_token_calls} token reports pending</p>;})}
          <p className="text-muted-foreground">Includes failed calls. Costs come from recorded provider receipts; missing costs remain pending. This tracks Ticket Creator separately from research workers.</p>
          <details className="rounded-md border border-border/70 p-3"><summary className="cursor-pointer text-sm font-medium">Recent creator calls</summary><ol className="mt-3 space-y-2">{c.creator_calls?.slice(0,5).map(call=><li key={call.id}>#{call.id} · {call.state} · {call.usage?.prompt_tokens??"—"} input / {call.usage?.completion_tokens??"—"} output tokens · {call.cost_usd===null?"Cost pending":`$${Number(call.cost_usd).toFixed(6)}`}{call.reason&&<p className="mt-1 text-xs text-muted-foreground">{call.reason==="invalid_ticket_proposal"?(call.response_text?"The response did not match the required proposal format.":"The response did not match the required proposal format. Detailed validation evidence was not recorded for this older call."):call.reason.replaceAll("_"," ")}</p>}{call.validation_error&&<p className="mt-1 text-xs text-destructive">{call.validation_error}</p>}<p className="mt-1 text-xs text-muted-foreground">Request: {call.request_id??`ticket-creator:${call.id}`}{call.finish_reason?` · Finish: ${call.finish_reason}`:""}</p>{!!call.diagnostics&&<RequestEvidence label="Recorded creator diagnostics" value={call.diagnostics}/>} {!!call.request&&<RequestEvidence label="Exact creator request" value={call.request}/>} {call.response_text&&<details className="mt-2"><summary className="cursor-pointer text-xs">Unvalidated response{call.response_truncated?" (truncated)":""}</summary>{call.validation_error&&<p className="mt-2 text-xs">{call.validation_error}</p>}<pre className="mt-2 whitespace-pre-wrap break-words text-xs">{call.response_text}</pre></details>}</li>)}</ol>{(c.creator_calls?.length??0)>5&&<p className="mt-3 text-xs text-muted-foreground">Showing the latest 5 of {c.creator_calls?.length} recorded calls.</p>}</details>
        </div>
      </details>}
      <details className="mt-4"><summary className="cursor-pointer text-sm font-medium text-primary">Current diagnostic scope and recent backlog</summary>
        <div className="mt-3 space-y-3 text-sm"><p>{c.symbols.join(", ")}. Each candidate pins the latest 60 trading sessions ending before today in New York, with SPY as benchmark and zero-interest cash.</p>
          <p className="text-muted-foreground">Ticket Creator uses the selected model. A paid choice authorizes that creator for Ticket Creator only, within the recorded spending limits. Campaign Check is a local exact-case comparison and does not call that model. Research Scout uses the Research runner on the Agents page and stays free while automated paid spending is off. Later evaluation and experiment workers stay on free routes. Exact-case duplicates move to the duplicate queue. Incomplete checks retry automatically and do not pause the backlog. One automatic Research Scout retry follows an unusable reply. Ten completed experiments is an acceptance milestone; intake continues afterward. The latest 100 backlog entries are shown. Pausing stops Ticket Creator; existing backlog cards still go to the free Research runner.</p>
          <ol className="space-y-3">{(c.agenda??[]).map(a=><li key={a.ordinal} className="border-l-2 border-border pl-3"><p>{a.title} <span className="text-muted-foreground">· {a.state}</span></p>{a.reason&&<p className="text-xs text-muted-foreground">{a.reason}</p>}{a.scope&&<p className="text-xs text-muted-foreground">Pinned dates: {a.scope.start} – {a.scope.end}</p>}{a.run_key&&<a className="text-primary underline" href={`/incubator?run=${encodeURIComponent(a.run_key)}`}>Open research ticket</a>}</li>)}</ol>
        </div>
      </details>
      <div className="mt-4 grid min-w-0 gap-3 sm:grid-cols-2">
        <label className="min-w-0 text-sm">Ticket Creator model<select className="mt-2 min-h-11 w-full min-w-0 rounded-md border border-input bg-background px-3" aria-label="Ticket Creator model" value={creator??c.creator_model} disabled={save.isPending||routing.isPending} onChange={e=>setCreator(e.target.value)}><option value="">Choose a model</option>{!!c.creator_model&&!models.some(m=>m.model_id===c.creator_model)&&<option value={c.creator_model}>{c.creator_model} (unavailable)</option>}{models.map(m=><option key={m.model_id} value={m.model_id}>{m.model_id}{m.model_id.endsWith(":free")?" · Free":" · Paid"}</option>)}</select></label>
        <label className="text-sm">Backlog target<select className="ml-2 min-h-11 rounded-md border border-input bg-background px-3" value={backlog??c.backlog_limit} onChange={e=>setBacklog(Number(e.target.value))}>{[1,3,5,10,15,20,50,75,100].map(n=><option key={n}>{n}</option>)}</select></label>
      </div>
      {c.creator_in_progress&&<p className="mt-3 text-xs text-muted-foreground">Stop generation cancels the local request and pauses new intake. A request already accepted by the provider may still incur a charge; unknown costs remain pending.{pendingSettings&&" Saving settings also stops this in-flight request and may pause the campaign for attention if its provider outcome is uncertain."}</p>}
      {routing.isError&&<p role="alert" className="mt-2 text-sm text-destructive">Model choices are unavailable. Refresh Models to choose a Ticket Creator.</p>}
      <div className="mt-4 flex flex-wrap items-end gap-3">
        <label className="text-sm">New tickets per day<select className="ml-2 min-h-11 rounded-md border border-input bg-background px-3" value={daily??c.daily_limit} onChange={e=>setDaily(Number(e.target.value))}>{[1,2,3,4,5,6,7,8,9,10,25,50,75,100].map(n=><option key={n}>{n}</option>)}</select></label>
        <label className="text-sm">Unfinished ticket limit<select className="ml-2 min-h-11 rounded-md border border-input bg-background px-3" value={open??c.open_limit} onChange={e=>setOpen(Number(e.target.value))}>{[1,2,3,5,10,20].map(n=><option key={n}>{n}</option>)}</select></label>
        <Button disabled={save.isPending||query.isError||stopping||(!c.enabled&&!(creator??c.creator_model))} onClick={()=>save.mutate(!c.enabled)}>{campaignActionLabel}</Button>
        {pendingSettings&&<Button variant="outline" disabled={save.isPending||query.isError} onClick={()=>save.mutate(c.enabled)}>{c.creator_in_progress?"Save settings and stop generation":"Save settings"}</Button>}
      </div>
    </>}
    {save.isError&&<p role="alert" className="mt-3 text-sm text-destructive">{save.error.message}</p>}
  </section>;
}

export function CampaignDialog() {
 const campaign = useQuery({queryKey: researchCampaignQueryKey, queryFn: fetchResearchCampaign, refetchInterval: 10000});
 const active = campaign.data?.enabled === true;
 return <Dialog.Root><Dialog.Trigger asChild><Button className="min-h-11" variant="outline" aria-label={active ? "Campaign generating" : "Campaign"}>{active?<LoaderCircle className="animate-spin" aria-hidden="true"/>:<Plus aria-hidden="true"/>}{active?"Campaign generating":"Campaign"}</Button></Dialog.Trigger>
  <Dialog.Portal><Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/>
   <Dialog.Content className="fixed left-1/2 top-1/2 z-50 max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-3xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-2xl border border-border bg-background p-6 text-foreground shadow-xl">
    <Dialog.Title className="pr-10 text-xl font-semibold">Campaign controls</Dialog.Title>
    <Dialog.Description className="mb-5 mt-2 text-sm text-muted-foreground">Configure automatic ticket creation, review the backlog, and track creator usage.</Dialog.Description>
    <Dialog.Close asChild><Button variant="ghost" size="icon" className="absolute right-3 top-3 min-h-11 min-w-11" aria-label="Close campaign"><X/></Button></Dialog.Close>
    <ResearchCampaign/>
   </Dialog.Content>
  </Dialog.Portal>
 </Dialog.Root>;
}
