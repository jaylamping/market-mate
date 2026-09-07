"use client";
import {useState} from "react";
import {useMutation,useQuery,useQueryClient} from "@tanstack/react-query";
import {Button} from "@/components/ui/button";
import {Input} from "@/components/ui/input";
import {IntegrationDisclosure} from "@/components/IntegrationSection";
import {IntegrationLogo} from "@/components/IntegrationLogo";
import {marketDataKey,marketRequest,type MarketConnection,dataError} from "@/lib/market-data";
export function MarketDataIntegration(){
 const cache=useQueryClient(),[key,setKey]=useState(""),[secret,setSecret]=useState(""),[rights,setRights]=useState(false);
 const q=useQuery({queryKey:marketDataKey,queryFn:()=>marketRequest<MarketConnection>(),refetchInterval:15000});
 const save=useMutation({mutationFn:()=>marketRequest("/setup",{key_id:key,secret_key:secret,rights_confirmed:rights}),onSuccess:()=>{setKey("");setSecret("");void cache.invalidateQueries({queryKey:marketDataKey});}});
 const change=useMutation({mutationFn:(v:{enabled:boolean;refresh_enabled:boolean})=>marketRequest("/settings",v),onSuccess:()=>void cache.invalidateQueries({queryKey:marketDataKey})});
 const cfg=q.data?.settings,state=q.data?.state;
 return <section id="market-data" aria-labelledby="market-data-title" className="grid min-w-0 gap-4 border-b p-6">
 <div className="flex flex-wrap items-center justify-between gap-3"><h3 id="market-data-title" className="inline-flex items-center gap-2.5 text-base font-semibold"><IntegrationLogo provider="alpaca"/>Market data</h3><span className="text-sm text-muted-foreground" role="status">{q.isPending?"Checking connection…":q.isError?"Service unavailable":state==="connected"?"Connection verified":state==="configured"?"Credentials configured":state==="paused"?"Collection paused":"Setup needed"}</span></div>
 <p className="max-w-prose text-sm text-muted-foreground">Alpaca historical SIP prices for local research. Adjusted daily prices, stored locally. This connection does not place trades or upgrade your plan.</p>
 {q.isError&&<p role="alert" className="text-sm text-destructive">{q.error.message}</p>}
 {state&&!['connected','configured','paused','not_configured'].includes(state)&&<p role="alert" className="text-sm text-destructive">{dataError(state)}</p>}
 {cfg&&<div className="grid gap-3 text-sm"><label className="flex min-h-11 items-center gap-3"><input type="checkbox" checked={cfg.enabled} disabled={change.isPending} onChange={e=>change.mutate({enabled:e.target.checked,refresh_enabled:cfg.refresh_enabled})}/>Collect prices for experiments</label><label className="flex min-h-11 items-center gap-3"><input type="checkbox" checked={cfg.refresh_enabled} disabled={change.isPending} onChange={e=>change.mutate({enabled:cfg.enabled,refresh_enabled:e.target.checked})}/>Refresh active research each trading morning</label><p className="text-muted-foreground">After 6 a.m. New York time. Catches up the needed window after downtime; archived research stops refreshing. Saved experiments keep their pinned inputs.</p><p className="text-muted-foreground">{q.data?.refresh.active_windows??0} active research windows{q.data?.refresh.latest&&` · Latest refresh: ${q.data.refresh.latest.session_end} (${q.data.refresh.latest.state})`}</p>{q.data?.refresh.latest?.error_code&&<p role="alert">{dataError(q.data.refresh.latest.error_code)}</p>}</div>}
 <IntegrationDisclosure title={cfg?"Replace market data credentials":"Connect Alpaca market data"}>
 <form className="grid max-w-xl gap-4" onSubmit={e=>{e.preventDefault();save.mutate();}}>
 <label className="grid gap-2 text-sm">API key ID<Input type="password" autoComplete="off" required value={key} onChange={e=>setKey(e.target.value)}/></label>
 <label className="grid gap-2 text-sm">Secret key<Input type="password" autoComplete="new-password" required value={secret} onChange={e=>setSecret(e.target.value)}/></label>
 <label className="flex items-start gap-3 text-sm"><input type="checkbox" required checked={rights} onChange={e=>setRights(e.target.checked)} className="mt-1 size-4 shrink-0"/>I have reviewed my Alpaca account terms and can retain historical data locally for personal research.</label>
 <p className="text-sm text-muted-foreground">Keys go only to your local connector and its private storage. Connecting checks a small historical panel; it does not accept provider terms for you.</p>
 <Button className="justify-self-start" disabled={save.isPending||!rights||!key||!secret}>{save.isPending?"Checking historical access…":"Verify and save connection"}</Button>
 {save.isError&&<p role="alert" className="text-sm text-destructive">{save.error.message}</p>}{save.isSuccess&&<p role="status" className="text-sm">Connection verified and saved.</p>}
 </form></IntegrationDisclosure>
 {change.isError&&<p role="alert" className="text-sm text-destructive">{change.error.message}</p>}
 </section>;
}
