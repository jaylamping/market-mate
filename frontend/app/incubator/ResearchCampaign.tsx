"use client";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import {modelRoutingQuery} from "@/lib/api-queries";
import { Button } from "@/components/ui/button";

type Campaign = {
  creator_model: string; backlog_limit: number; backlog_count: number; creator_status: string | null; target: number; created_count: number; completed_count: number; enabled: boolean; revision: number; daily_limit: number; open_limit: number;
  next_at: string; note: string; open_count: number; attempts_today: number; symbols: string[];
  agenda: { ordinal: number; title: string; state: string; reason: string | null; run_key: string | null;
    scope: {start: string; end: string} | null }[];
};
const key = ["research-campaign"];
async function response(r: Response): Promise<Campaign> {
  const body = await r.json();
  if (!r.ok) throw Error(body.error ?? "Campaign unavailable");
  return body;
}
export function ResearchCampaign() {
  const client = useQueryClient();
  const routing = useQuery(modelRoutingQuery);
  const models = routing.data?.models.map(m=>m.routes[0]).filter(r=>r.provider==="openrouter")??[];
  const [creator, setCreator] = useState<string | null>(null), [backlog,setBacklog]=useState<number | null>(null);
  const query = useQuery({ queryKey: key, queryFn: () => fetch("/api/incubator/campaign", {cache:"no-store"}).then(response), refetchInterval: 10000 });
  const [daily, setDaily] = useState<number | null>(null), [open, setOpen] = useState<number | null>(null);
  const save = useMutation({ mutationFn: (enabled: boolean) => fetch("/api/incubator/campaign", {
    method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({ enabled,
      creator_model: creator??query.data?.creator_model??"", backlog_limit: backlog??query.data?.backlog_limit, revision: query.data?.revision, daily_limit: daily ?? query.data?.daily_limit, open_limit: open ?? query.data?.open_limit })
  }).then(response), onSuccess: data => {client.setQueryData(key, data); setDaily(null); setOpen(null); setCreator(null); setBacklog(null);} });
  const c = query.data;
  return <section className="mb-6 rounded-xl border border-border bg-card p-5" aria-label="Research campaign">
    <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-lg font-semibold">Research campaign</h2><span className="text-sm text-muted-foreground">{c ? c.enabled ? "Enabled" : "Paused" : "Loading"}</span></div>
    <p className="mt-2 text-sm text-muted-foreground">One Ticket Creator model proposes a backlog of research questions. Free research workers take tickets as capacity permits, then evaluation and experiments follow.</p>
    {query.isError && <p role="alert" className="mt-3 text-sm text-destructive">Campaign could not be refreshed. <button className="underline" onClick={()=>query.refetch()}>Retry</button></p>}
    {c && <>
      <p role="status" className="mt-3 text-sm">{c.note}</p>
      <p className="mt-2 text-xs text-muted-foreground">{c.completed_count} / {c.target} experiments completed · {c.created_count} tickets created · {c.backlog_count} tickets in backlog · Creator: {c.creator_status??"idle"} · {c.attempts_today} candidates checked in the last 24 hours · {c.open_count} unfinished tickets{c.enabled ? ` · Next check no earlier than ${new Date(c.next_at).toLocaleString()}` : ""}</p>
      <details className="mt-4"><summary className="cursor-pointer text-sm font-medium text-primary">Research scope and backlog</summary>
        <div className="mt-3 space-y-3 text-sm"><p>{c.symbols.join(", ")}. Each candidate pins the latest 60 trading sessions ending before today in New York, with SPY as benchmark and zero-interest cash.</p>
          <p className="text-muted-foreground">Ticket Creator uses the selected model; paid choices require your existing automated spending policy to allow that model. Research workers stay on free routes. Duplicate or incomplete checks create no research ticket. This acceptance campaign stops new admission at ten tickets and preserves its remaining backlog. Pausing lets existing research tickets finish.</p>
          <ol className="space-y-3">{(c.agenda??[]).map(a=><li key={a.ordinal} className="border-l-2 border-border pl-3"><p>{a.title} <span className="text-muted-foreground">· {a.state}</span></p>{a.reason&&<p className="text-xs text-muted-foreground">{a.reason}</p>}{a.scope&&<p className="text-xs text-muted-foreground">Pinned dates: {a.scope.start} – {a.scope.end}</p>}{a.run_key&&<a className="text-primary underline" href={`/incubator?run=${encodeURIComponent(a.run_key)}`}>Open research ticket</a>}</li>)}</ol>
        </div>
      </details>
      <div className="mt-4 grid min-w-0 gap-3 sm:grid-cols-2">
        <label className="min-w-0 text-sm">Ticket Creator model<select className="mt-2 min-h-11 w-full min-w-0 rounded-md border border-input bg-background px-3" aria-label="Ticket Creator model" value={creator??c.creator_model} disabled={save.isPending||routing.isPending} onChange={e=>setCreator(e.target.value)}><option value="">Choose a model</option>{!!c.creator_model&&!models.some(m=>m.model_id===c.creator_model)&&<option value={c.creator_model}>{c.creator_model} (unavailable)</option>}{models.map(m=><option key={m.model_id} value={m.model_id}>{m.model_id}{m.model_id.endsWith(":free")?" · Free":" · Paid"}</option>)}</select></label>
        <label className="text-sm">Backlog target<select className="ml-2 min-h-11 rounded-md border border-input bg-background px-3" value={backlog??c.backlog_limit} onChange={e=>setBacklog(Number(e.target.value))}>{[1,3,5,10,15,20].map(n=><option key={n}>{n}</option>)}</select></label>
      </div>
      {routing.isError&&<p role="alert" className="mt-2 text-sm text-destructive">Model choices are unavailable. Refresh Models to choose a Ticket Creator.</p>}
      <div className="mt-4 flex flex-wrap items-end gap-3">
        <label className="text-sm">New tickets per day<select className="ml-2 min-h-11 rounded-md border border-input bg-background px-3" value={daily??c.daily_limit} onChange={e=>setDaily(Number(e.target.value))}>{[1,2,3,4,5,6,7,8,9,10].map(n=><option key={n}>{n}</option>)}</select></label>
        <label className="text-sm">Unfinished ticket limit<select className="ml-2 min-h-11 rounded-md border border-input bg-background px-3" value={open??c.open_limit} onChange={e=>setOpen(Number(e.target.value))}>{[1,2,3].map(n=><option key={n}>{n}</option>)}</select></label>
        <Button disabled={save.isPending||query.isError||(!c.enabled&&!(creator??c.creator_model))} onClick={()=>save.mutate(!c.enabled)}>{save.isPending?"Saving…":c.enabled?"Pause campaign":"Enable pilot campaign"}</Button>
        {(daily!==null||open!==null||creator!==null||backlog!==null)&&<Button variant="outline" disabled={save.isPending||query.isError} onClick={()=>save.mutate(c.enabled)}>Save settings</Button>}
      </div>
    </>}
    {save.isError&&<p role="alert" className="mt-3 text-sm text-destructive">{save.error.message}</p>}
  </section>;
}
