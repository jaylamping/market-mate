"use client";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { modelRoutingQuery, openrouterModelsQuery } from "@/lib/api-queries";
import { isFree, tokenPrice, type Model } from "@/lib/openrouter";
import { capacityQuery, updateCapacity, canSaveCapacity, dollarsToNanos, type Capacity, type CapacityPolicy } from "@/lib/openrouter-capacity";

const usdFormatter = new Intl.NumberFormat("en-US",{style:"currency",currency:"USD",maximumFractionDigits:6});
const usd = (n: number) => usdFormatter.format(n / 1_000_000_000);
const date = (value: string | null) => value ? new Date(value).toLocaleString() : "No wait reported";
const inputClass = "mt-1 w-full min-w-0 rounded-md border bg-background px-3 py-2 text-sm";

export function CapacitySummary({capacity:c}: {capacity: Capacity}) {
  return <div className="grid gap-3">
    <dl className="grid grid-cols-2 gap-4 sm:grid-cols-3">
      {[["Free attempts accounted",`${c.free_used} / 1,000`],["Free requests remaining (local)",String(c.free_remaining)],
        ["Starts in last minute",`${c.minute_used} / 20`],["In flight",String(c.in_flight)],["Waiting for capacity",String(c.queued)],
        ["Automated paid attempts (24h)",String(c.paid_attempts)]].map(([label,value]) => <div key={label} className="min-w-0"><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-1 break-words tabular-nums">{value}</dd></div>)}
    </dl>
    <p className="text-xs text-muted-foreground">{c.policy.mode === "paced" ? "Paced" : "Bounded burst"} · daily free target {c.policy.daily_target} · minimum start interval {c.policy.start_interval_ms/1000}s. {c.policy.paid_enabled ? `Automated paid ${c.policy.prefer_free_models?"fallback":"primary routing"} enabled for ${c.policy.paid_models.length} model(s); preferred: ${c.policy.paid_model}.` : "Automated paid spending is disabled."}</p>
    <p className="text-xs text-muted-foreground">Local accounting · rolling 24-hour window · history: {c.history_status}. These are request counts, separate from credits. Remaining allowance does not guarantee provider availability.</p>
    <p className="text-xs">{c.policy.paused ? "Dispatch paused. Already running requests may complete." : `Next eligible start: ${date(c.next_eligible_at)}.`}</p>
    {c.cooldown_until&&Date.parse(c.cooldown_until)>Date.now()&&<p role="status" className="text-xs">Account cooling down until {date(c.cooldown_until)}.</p>}
    {c.free_cooldown_until&&Date.parse(c.free_cooldown_until)>Date.now()&&<p role="status" className="text-xs">Free models cooling down until {date(c.free_cooldown_until)}.</p>}
    <p className="text-xs text-muted-foreground">Automated paid cost accounted: {usd(c.paid_used_nanos)} · unresolved automated reservations: {usd(c.paid_reserved_nanos)}. {c.policy.paid_enabled&&c.policy.paid_finish_on_429 ? `Active work may use up to ${c.policy.paid_max_fallback_attempts} paid fallback attempt(s) after a definite 429. ${c.policy.prefer_free_models?"Other queued work waits for free capacity.":"Configured paid primary routing can apply to queued work."}` : "Finishing active work on paid after a 429 is disabled."}</p>
  </div>;
}

function CapacityEditor({capacity,paidModels,catalogAvailable,onSaved}: {capacity:Capacity;paidModels:Model[];catalogAvailable:boolean;onSaved:()=>Promise<Capacity>}) {
  const [draft,setDraft] = useState(capacity.policy);
  const [amounts,setAmounts] = useState({paid_request_limit_nanos:String(draft.paid_request_limit_nanos/1e9),paid_daily_limit_nanos:String(draft.paid_daily_limit_nanos/1e9),paid_monthly_limit_nanos:String(draft.paid_monthly_limit_nanos/1e9)});
  const [busy,setBusy] = useState(false), [message,setMessage] = useState("");
  const conflict = draft.revision !== capacity.policy.revision;
  const policy = {...draft};
  for (const key of Object.keys(amounts) as (keyof typeof amounts)[]) policy[key] = dollarsToNanos(amounts[key]) ?? -1;
  const valid = canSaveCapacity(policy,paidModels.map(m=>m.id)) && (!draft.paid_enabled || catalogAvailable);
  const selected = paidModels.find(m=>m.id === draft.paid_model);
  function change<K extends keyof CapacityPolicy>(key:K,value:CapacityPolicy[K]) {setDraft({...draft,[key]:value});setMessage("");}
  function selectPaidModel(id:string,enabled:boolean) {
    const paid_models=enabled?[...draft.paid_models,id]:draft.paid_models.filter(model=>model!==id);
    const paid_role_models={...draft.paid_role_models};
    for(const role of Object.keys(paid_role_models) as (keyof typeof paid_role_models)[])if(!paid_models.includes(paid_role_models[role]??""))paid_role_models[role]=null;
    setDraft({...draft,paid_models,paid_role_models,paid_model:paid_models.includes(draft.paid_model??"")?draft.paid_model:paid_models[0]??null,paid_model_open_weights_confirmed:false});
    setMessage("");
  }
  async function save() {
    setBusy(true);setMessage("");
    try {await updateCapacity(policy);await onSaved();setMessage("Settings saved. Reload current settings to make another change.");}
    catch(error) {setMessage(error instanceof Error ? error.message : "Save failed. Reload before retrying.");}
    finally {setBusy(false);}
  }
  async function reload() {
    setBusy(true);
    try {const fresh=await onSaved();setDraft(fresh.policy);setAmounts({paid_request_limit_nanos:String(fresh.policy.paid_request_limit_nanos/1e9),paid_daily_limit_nanos:String(fresh.policy.paid_daily_limit_nanos/1e9),paid_monthly_limit_nanos:String(fresh.policy.paid_monthly_limit_nanos/1e9)});setMessage("");}
    catch {setMessage("Current settings unavailable. Try refreshing again.");} finally {setBusy(false);}
  }
  async function burst() {
    setBusy(true);setMessage("");
    try {
      const response=await fetch("/api/providers/capacity/burst",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({requests:100}),signal:AbortSignal.timeout(15_000)});
      if(!response.ok)throw Error("Burst could not be confirmed. Reload capacity before retrying.");
      await onSaved();setMessage("Burst allowance set. It advances existing queued work within daily and minute limits.");
    } catch(error) {setMessage(error instanceof Error ? error.message : "Burst failed.");} finally {setBusy(false);}
  }
  return <div className="grid gap-4 border-t pt-4">
    <div className="grid gap-3 sm:grid-cols-3">
      <label>Dispatch mode<select className={inputClass} value={draft.mode} onChange={e=>change("mode",e.target.value as CapacityPolicy["mode"])}><option value="paced">Paced across the day</option><option value="burst">Bounded burst</option></select></label>
      <label>Daily free target<input className={inputClass} type="number" min={1} max={1000} value={draft.daily_target} onChange={e=>change("daily_target",Number(e.target.value))}/></label>
      <label>Minimum start interval (seconds)<input className={inputClass} type="number" min={3.1} max={60} step={0.1} value={draft.start_interval_ms/1000} onChange={e=>change("start_interval_ms",Math.round(Number(e.target.value)*1000))}/></label>
    </div>
    <label className="flex items-start gap-2"><input type="checkbox" checked={draft.paused} onChange={e=>change("paused",e.target.checked)}/>Pause new dispatches</label>
    <p className="text-xs text-muted-foreground">Burst blocks temporarily accelerate paced work. Burst mode continuously dispatches available work within limits. Daily target controls pacing, not a hard ceiling. Burst allowance remaining: {capacity.policy.burst_remaining}. A 100-attempt block can use at most {Math.min(100,capacity.free_remaining)} locally available attempts. It creates no new research tasks.</p>
    <button className="rounded-md border px-3 py-2 text-sm justify-self-start disabled:opacity-50" disabled={busy||conflict||capacity.policy.paused} onClick={burst}>Allow 100 queued attempts</button>
    <label className="flex items-start gap-2"><input type="checkbox" checked={draft.prefer_free_models} onChange={e=>change("prefer_free_models",e.target.checked)}/>Prefer free models</label>
    <p className="text-xs text-muted-foreground">On by default: automated work uses free models first, with paid models only under enabled fallback conditions. Turn off to use configured paid models as primary routes. This preference does not authorize spending; automated paid models must also be enabled and stay within all paid caps. Manual model choices are independent.</p>
    <label>Automated spending authorization<select className={inputClass} value={draft.paid_enabled ? "paid" : "free"} onChange={e=>change("paid_enabled",e.target.value==="paid")}><option value="free">Paid spending disabled</option><option value="paid">Enable configured paid models</option></select></label>
    <p className="text-xs text-muted-foreground">Applies to automated agents and workflows. Manually selected paid models run as chosen; usage is recorded separately. These automated caps do not limit explicitly selected manual paid requests.</p>
    <fieldset className="grid min-w-0 gap-3 rounded-md border p-3"><legend className="px-1 font-medium">Automated paid models</legend>
      <p className="text-xs text-muted-foreground">Select up to 16 approved paid models to allow for automated work. The default is none. Selecting models does not enable automated paid spending.</p>
      {paidModels.map(model=><label key={model.id} className="flex min-w-0 items-start gap-2"><input type="checkbox" checked={draft.paid_models.includes(model.id)} disabled={!draft.paid_models.includes(model.id)&&draft.paid_models.length>=16} onChange={e=>selectPaidModel(model.id,e.target.checked)}/><span className="min-w-0 break-words">{model.name} · {model.id}<span className="block text-xs text-muted-foreground">Per million tokens: {tokenPrice(model.pricing.prompt)} input / {tokenPrice(model.pricing.completion)} output</span></span></label>)}
      {draft.paid_models.filter(id=>!paidModels.some(model=>model.id===id)).map(id=><label key={id} className="flex min-w-0 items-start gap-2"><input type="checkbox" checked onChange={()=>selectPaidModel(id,false)}/><span className="min-w-0 break-words">{id} (approval or current pricing unavailable; remove before enabling)</span></label>)}
      {catalogAvailable&&paidModels.length===0&&<p className="text-xs text-muted-foreground">No approved paid models. Configure available models first.</p>}
    </fieldset>
    <div className="grid gap-3 sm:grid-cols-2">
      <label>Shared paid model<select className={inputClass} value={draft.paid_model??""} onChange={e=>change("paid_model",e.target.value||null)}><option value="">Select an allowed paid model</option>{draft.paid_model&&!selected&&<option value={draft.paid_model} disabled>{draft.paid_model} (unavailable)</option>}{paidModels.filter(m=>draft.paid_models.includes(m.id)).map(m=><option key={m.id} value={m.id}>{m.name} · {m.id}</option>)}</select></label>
      <label>Automated paid attempts per rolling 24h<input className={inputClass} type="number" min={1} max={100} step={1} value={draft.paid_attempt_limit} onChange={e=>change("paid_attempt_limit",Number(e.target.value))}/></label>
    </div>
    {!catalogAvailable&&<p role="status">Current approved models and prices unavailable. Paid fallback cannot be enabled or saved.</p>}
    {selected&&<p className="text-xs text-muted-foreground">Catalog prices per million tokens: {tokenPrice(selected.pricing.prompt)} input / {tokenPrice(selected.pricing.completion)} output. Example: 1,000 input + 2,048 output tokens costs {usd(Math.ceil((Number(selected.pricing.prompt)*1000+Number(selected.pricing.completion)*2048)*1e9))} before any other billable dimensions. Dispatch requires a bounded reservation within all caps.</p>}
    {draft.prefer_free_models&&<label className="flex items-start gap-2"><input type="checkbox" checked={draft.paid_model_open_weights_confirmed} disabled={draft.paid_models.length===0} onChange={e=>change("paid_model_open_weights_confirmed",e.target.checked)}/>I checked that every allowed paid fallback model has published weights and an appropriate license. Catalog approval alone does not verify this. Changing the allowed list clears this confirmation.</label>}
    <div className="grid gap-3 sm:grid-cols-3">{([['paid_request_limit_nanos','USD per request'],['paid_daily_limit_nanos','USD per UTC day'],['paid_monthly_limit_nanos','USD per UTC month']] as const).map(([key,label])=><label key={key}>{label}<input className={inputClass} inputMode="decimal" value={amounts[key]} onChange={e=>setAmounts({...amounts,[key]:e.target.value})}/></label>)}</div>
    <p className="text-xs text-muted-foreground">When Prefer free models is on, the default paid trigger is confirmed daily free allowance exhausted. A lower daily target or unknown accounting never qualifies. New work returns to free when capacity recovers. No automatic purchases or cap increases.</p>
    <label className="flex items-start gap-2"><input type="checkbox" checked={draft.paid_finish_on_429} onChange={e=>change("paid_finish_on_429",e.target.checked)}/>Finish active work on paid after a definite 429</label>
    <label>Maximum paid fallback attempts per active request<select className={inputClass} value={draft.paid_max_fallback_attempts} onChange={e=>change("paid_max_fallback_attempts",Number(e.target.value))}><option value={1}>One attempt</option><option value={2}>Two attempts</option></select></label>
    <p className="text-xs text-muted-foreground">Off by default. When automated paid fallback is enabled, this option permits the selected role’s paid fallback only after a definite 429 for already active work, within its existing limits and paid caps. With Prefer free models on, other queued work remains on free; with it off, configured paid primary routing can apply. An uncertain response is never replayed. Choose role-specific paid models in Agent configuration on the Agents page.</p>
    <label className="flex items-start gap-2"><input type="checkbox" checked={draft.paid_outage_enabled} onChange={e=>change("paid_outage_enabled",e.target.checked)}/>Also allow paid during prolonged free outages</label>
    <p className="text-xs text-muted-foreground">Optional outage fallback requires at least 10 minutes of observed unavailability across suitable approved free routes. Account and authentication blocks do not qualify.</p>
    {conflict&&<p role="alert">Settings changed since this draft. Reload current settings before saving.</p>}
    {message&&<p role="status">{message}</p>}
    <div className="flex flex-wrap gap-2"><button className="rounded-md border px-3 py-2 disabled:opacity-50" disabled={busy||conflict||!valid} onClick={save}>{busy?"Saving…":"Save capacity settings"}</button><button className="rounded-md border px-3 py-2 disabled:opacity-50" disabled={busy} onClick={reload}>Reload current settings</button></div>
  </div>;
}

export function OpenRouterCapacity() {
  const query=useQuery(capacityQuery), routing=useQuery(modelRoutingQuery), models=useQuery(openrouterModelsQuery);
  if(query.isPending)return <p role="status">Checking request capacity…</p>;
  if(query.isError||!query.data)return <div role="status"><p>Request capacity unavailable. Counts and controls are hidden until refreshed.</p><button className="text-link" onClick={()=>void query.refetch()}>Refresh capacity</button></div>;
  const approved=new Set(routing.data?.models.flatMap(m=>m.routes.filter(r=>r.provider==="openrouter").map(r=>r.model_id))??[]);
  const available=!routing.isError&&!models.isError&&!!routing.data&&!!models.data;
  const paidModels=available?models.data!.filter(m=>approved.has(m.id)&&!isFree(m)&&!m.id.endsWith(":free")):[];
  return <section aria-label="OpenRouter request capacity" className="grid min-w-0 gap-4 rounded-md border p-4 text-sm"><h3 className="font-medium">OpenRouter request capacity</h3><CapacitySummary capacity={query.data}/><details><summary className="cursor-pointer">Configure capacity and automated paid models</summary><div className="mt-4"><CapacityEditor capacity={query.data} paidModels={paidModels} catalogAvailable={available} onSaved={async()=>{const result=await query.refetch();if(result.isError||!result.data)throw Error("Current capacity unavailable");return result.data;}}/></div></details></section>;
}

export function PaidRoleFallback({role}: {role: keyof CapacityPolicy["paid_role_models"]}) {
  const query=useQuery(capacityQuery), models=useQuery(openrouterModelsQuery), routing=useQuery(modelRoutingQuery);
  const [draft,setDraft]=useState<CapacityPolicy|null>(null), [busy,setBusy]=useState(false), [message,setMessage]=useState("");
  if(query.isError||!query.data)return <p className="text-xs text-muted-foreground">Paid fallback settings {query.isPending ? "loading…" : "unavailable. Refresh capacity to retry."}</p>;
  const current=query.data.policy, policy=draft??current, selected=policy.paid_role_models[role];
  const inherited=role==="default"?policy.paid_model:policy.paid_role_models.default??policy.paid_model;
  const conflict=!!draft&&draft.revision!==current.revision;
  const approved=new Set(routing.data?.models.flatMap(m=>m.routes.filter(r=>r.provider==="openrouter").map(r=>r.model_id))??[]);
  const available=!models.isError&&!routing.isError&&!!models.data&&!!routing.data;
  const eligible=available ? models.data!.filter(m=>approved.has(m.id)&&!isFree(m)&&!m.id.endsWith(":free")) : [];
  const choices=eligible.filter(m=>policy.paid_models.includes(m.id));
  async function reload() {
    setBusy(true);setMessage("");
    try {const result=await query.refetch();if(result.isError||!result.data)throw Error("Paid settings unavailable");setDraft(null);}
    catch {setMessage("Could not reload paid fallback settings.");} finally {setBusy(false);}
  }
  async function save() {
    if(!draft)return;
    setBusy(true);setMessage("");
    try {await updateCapacity(draft);const result=await query.refetch();if(result.isError)throw Error("Saved; refresh capacity to confirm current settings.");setDraft(null);setMessage("Paid role model saved.");}
    catch(error){setMessage(error instanceof Error?error.message:"Paid fallback could not be saved. Reload before retrying.");}
    finally{setBusy(false);}
  }
  return <div className="grid min-w-0 gap-2 border-t pt-3">
    <label htmlFor={`paid-role-${role}`} className="text-xs font-medium">Paid model</label>
    <select id={`paid-role-${role}`} className={inputClass} value={selected??""} disabled={busy||conflict||!available} onChange={e=>{setDraft({...policy,paid_role_models:{...policy.paid_role_models,[role]:e.target.value||null}});setMessage("");}}>
      <option value="">Use {role!=="default"&&policy.paid_role_models.default?"default role":"shared"} paid model{inherited?` (${inherited})`:" (none selected)"}</option>
      {selected&&!choices.some(m=>m.id===selected)&&<option value={selected} disabled>{selected} (unavailable)</option>}
      {choices.map(model=><option key={model.id} value={model.id}>{model.name} · {model.id}</option>)}
    </select>
    <p className="text-xs text-muted-foreground">{current.paid_enabled?(current.prefer_free_models?"Used as fallback when an enabled automated paid fallback condition applies.":"Used as a primary automated route within paid caps."):"Automated paid spending is off. You can prepare this choice without enabling spending."} With Prefer free models on, this is a fallback; with it off, this is a primary model. Enable allowed paid models in Settings. Explicit manual model selections are unchanged.</p>
    {conflict&&<p role="alert" className="text-xs">Capacity settings changed. Reload before saving this role.</p>}
    {message&&<p role="status" className="text-xs">{message}</p>}
    <div className="flex flex-wrap gap-2"><button className="rounded-md border px-2 py-1 text-xs disabled:opacity-50" disabled={!draft||busy||conflict||!available||!canSaveCapacity(policy,eligible.map(m=>m.id))} onClick={save}>Save paid model</button>{(draft||message)&&<button className="rounded-md border px-2 py-1 text-xs disabled:opacity-50" disabled={busy} onClick={reload}>Reload</button>}</div>
  </div>;
}
