"use client";
import {useState} from "react";
import {useMutation,useQuery,useQueryClient} from "@tanstack/react-query";
import {Button} from "@/components/ui/button";
import {Input} from "@/components/ui/input";
import {acquisitionKey,acquisitionLabels,dataError,marketDataKey,marketRequest,type Acquisition,type MarketConnection} from "@/lib/market-data";
import {workflowKey,type Experiment} from "./evaluation";
export function AcquisitionSummary({job}:{job:Acquisition}){
 const r=job.request;
 return <div className="grid gap-3 text-sm"><p className="font-medium" role="status">{acquisitionLabels[job.state]??job.state}</p>{r&&<dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2">{[["Symbols",r.symbols.join(", ")],["Sessions",`${r.sessions[0]} – ${r.sessions.at(-1)} (${r.sessions.length})`],["Source","Alpaca · SIP · USD"],["Adjustment","Splits and distributions adjusted"],["Benchmark",r.benchmark],["Cash assumption","Zero interest"]].map(([k,v])=><div key={k} className="min-w-0"><dt className="text-muted-foreground">{k}</dt><dd className="mt-1 break-words">{v}</dd></div>)}</dl>}{job.error_code&&<p role="alert" className="text-destructive">{dataError(job.error_code)}</p>}</div>;
}
export function AcquisitionPanel({experiment:e}:{experiment:Experiment}){
 const cache=useQueryClient(),[symbols,setSymbols]=useState(""),[start,setStart]=useState(""),[end,setEnd]=useState(""),[benchmark,setBenchmark]=useState(""),[cash,setCash]=useState(false);
 const job=useQuery({queryKey:acquisitionKey(e.id),queryFn:async()=>{const r=await fetch(`/api/incubator/workflow/${e.id}/acquisition`,{cache:"no-store"});if(!r.ok)throw Error("Download status is unavailable. Try again shortly.");return await r.json() as Acquisition|null;},refetchInterval:5000});
 const connection=useQuery({queryKey:marketDataKey,queryFn:()=>marketRequest<MarketConnection>(),refetchInterval:15000});
 const save=useMutation({mutationFn:async({path,body}:{path:string;body:object})=>{const r=await fetch(`/api/incubator/workflow/${e.id}/${path}`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});if(!r.ok)throw Error(path==="data-request"?"The request was not saved. Use 4–32 distinct symbols and a compatible 3–60-session date range in 2025–2026, or check whether the ticket has changed.":"The download state changed. Refresh its status before trying again.");},onSuccess:()=>{void cache.invalidateQueries({queryKey:acquisitionKey(e.id)});void cache.invalidateQueries({queryKey:workflowKey});}});
 const waiting=e.status==="awaiting_data"&&!e.snapshot_id;
 const provided=!!e.detail?.data_request;
 return <section aria-label="Experiment market data" className="grid min-w-0 gap-4 border-t pt-4">
 <h3 className="font-medium">Prices for this experiment</h3>
 {job.isError&&<p role="alert" className="text-sm text-destructive">{job.error.message}</p>}
 {job.data?<AcquisitionSummary job={job.data}/>:<p className="text-sm text-muted-foreground">{provided?"The requested symbols and dates are ready for collection.":waiting?"Specify the prices this diagnostic needs. A daily panel is one price history per stock over the same trading sessions.":"Setup will identify the price history needed for this diagnostic."}</p>}
 {waiting&&(!connection.data?.settings?.enabled||connection.isError)&&<p className="text-sm text-muted-foreground">{connection.data?.settings?"Price collection is paused.":"Connect a historical data source to collect prices automatically."} <a className="text-primary underline underline-offset-4" href="/system#market-data">Open market data settings</a></p>}
 {job.data&&<div className="flex flex-wrap gap-3">{job.data.state==="failed"&&job.data.attempts<3&&job.data.request&&<Button disabled={save.isPending} onClick={()=>save.mutate({path:"acquisition",body:{action:"retry"}})}>Retry download</Button>}{["queued","leased","retry_wait","failed"].includes(job.data.state)&&<Button variant="outline" disabled={save.isPending} onClick={()=>save.mutate({path:"acquisition",body:{action:"cancel"}})}>Cancel download</Button>}</div>}
 {waiting&&!provided&&!job.data&&!job.isPending&&<details><summary className="cursor-pointer text-sm font-medium text-primary">Specify symbols and dates</summary><form className="mt-4 grid max-w-xl gap-4" onSubmit={ev=>{ev.preventDefault();save.mutate({path:"data-request",body:{calendar:"XNYS_2025_2026_v1",symbols:symbols.split(/[\s,]+/).filter(Boolean),start,end,benchmark,symbol_asof:end,cash:"zero_interest"}});}}>
 <label className="grid gap-2 text-sm">Stock symbols, separated by commas<Input required placeholder="For example: AAPL, XOM, JPM, NEE" value={symbols} onChange={ev=>setSymbols(ev.target.value.toUpperCase())}/></label>
 <div className="grid gap-4 sm:grid-cols-2"><label className="grid gap-2 text-sm">Start date<Input type="date" min="2025-01-01" max="2026-12-31" required value={start} onChange={ev=>setStart(ev.target.value)}/></label><label className="grid gap-2 text-sm">End date<Input type="date" min={start||"2025-01-01"} max="2026-12-31" required value={end} onChange={ev=>setEnd(ev.target.value)}/></label></div>
 <label className="grid gap-2 text-sm">Benchmark symbol<Input required placeholder="Use the benchmark from your research plan" value={benchmark} onChange={ev=>setBenchmark(ev.target.value.toUpperCase())}/></label>
 <p className="text-sm text-muted-foreground">Include the lookback period in the date range. Symbols use the provider’s mapping as of the end date. The request is fixed once submitted.</p>
 <label className="flex items-start gap-3 text-sm"><input type="checkbox" required checked={cash} onChange={ev=>setCash(ev.target.checked)} className="mt-1 size-4 shrink-0"/>Use a zero-interest cash comparison for this diagnostic.</label>
 <Button className="justify-self-start" disabled={save.isPending||!cash}>{save.isPending?"Saving request…":"Request these prices"}</Button>
 </form></details>}
 {e.snapshot_id&&<p className="text-sm text-muted-foreground">{(e as Experiment&{replay_available?:boolean}).replay_available===false?"The source inputs are unavailable. This experiment cannot be replayed.":"The attached inputs are pinned. Later price refreshes do not rewrite this experiment."}</p>}
 {save.isError&&<p role="alert" className="text-sm text-destructive">{save.error.message}</p>}
 </section>;
}
