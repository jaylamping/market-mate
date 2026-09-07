"use client";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient, type UseQueryResult } from "@tanstack/react-query";
import { ModelLink } from "@/components/ModelLink";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { cursorModelsQuery, cursorPolicyQuery, cursorStatusQuery, openrouterModelsQuery, openrouterPolicyQuery } from "@/lib/api-queries";
import { isFree, parsePolicy, tokenPrice, type ModelPolicy } from "@/lib/openrouter";

type Provider = "openrouter" | "cursor";
const names = {openrouter:"OpenRouter",cursor:"Cursor"};
type Row = {provider:Provider;id:string;name:string;pricing?:Record<string,string>;context?:number;free:boolean;retired?:boolean};
function useWhitelist(provider:Provider, query:UseQueryResult<ModelPolicy>) {
  const client = useQueryClient();
  const [draft,setDraft] = useState<ModelPolicy|null>(null);
  const selected = draft?.allowed_models ?? query.data?.allowed_models ?? [];
  const save = useMutation({mutationFn:async () => {
    if (!draft) throw new Error("No changes to save.");
    const response=await fetch(`/api/${provider}/policy`,{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(draft),signal:AbortSignal.timeout(15_000)});
    if (!response.ok) throw new Error(response.status === 409 ? "The saved whitelist changed. Reload it before editing again." : "Could not save. Your selections are still here; try again.");
    return parsePolicy(await response.json());
  },onSuccess:value=>{client.setQueryData(["api",provider,"policy"],value);setDraft(null);}});
  const toggle=(id:string)=>{
    if (!query.data) return;
    const next=selected.includes(id)?selected.filter(v=>v!==id):[...selected,id];
    setDraft({revision:draft?.revision??query.data.revision,allowed_models:next});
  };
  const dirty=JSON.stringify([...selected].sort())!==JSON.stringify([...(query.data?.allowed_models??[])].sort());
  const reload=async()=>{await query.refetch();setDraft(null);save.reset();};
  return {query,selected,save,toggle,dirty,reload};
}
export function ModelsTable() {
  const openrouter=useWhitelist("openrouter",useQuery(openrouterPolicyQuery)), cursor=useWhitelist("cursor",useQuery(cursorPolicyQuery));
  const policies={openrouter,cursor};
  const orModels=useQuery(openrouterModelsQuery), status=useQuery(cursorStatusQuery);
  const cursorModels=useQuery({...cursorModelsQuery,enabled:status.data?.state==="connected"});
  const [search,setSearch]=useState(""),[provider,setProvider]=useState("all"),[filter,setFilter]=useState("all"),[page,setPage]=useState(0);
  const ready={openrouter:!!orModels.data&&!orModels.isError&&!openrouter.query.isError&&!!openrouter.query.data,cursor:status.data?.state==="connected"&&!!cursorModels.data&&!cursorModels.isError&&!cursor.query.isError&&!!cursor.query.data};
  const rows:Row[]=[
    ...(ready.openrouter?orModels.data??[]:[]).map(m=>({provider:"openrouter" as const,id:m.id,name:m.name,pricing:m.pricing,context:m.context_length,free:isFree(m)})),
    ...(ready.cursor?cursorModels.data??[]:[]).map(m=>({provider:"cursor" as const,id:m.id,name:m.name,free:false})),
  ];
  for (const key of ["openrouter","cursor"] as const) {
    if (ready[key]) for (const id of policies[key].selected) if (!rows.some(r=>r.provider===key&&r.id===id)) rows.push({provider:key,id,name:id,free:false,retired:true});
  }
  rows.sort((a,b)=>a.name.localeCompare(b.name)||a.provider.localeCompare(b.provider));
  const filtered=rows.filter(m=>(provider==="all"||m.provider===provider)&&`${m.name} ${m.id} ${names[m.provider]}`.toLowerCase().includes(search.toLowerCase())&&(filter==="all"||(filter==="free"?m.free:policies[m.provider].selected.includes(m.id))));
  const pages=Math.max(1,Math.ceil(filtered.length/20)), currentPage=Math.min(page,pages-1);
  return <div className="grid min-w-0 gap-4">
    <div className="flex flex-wrap items-end justify-between gap-3"><div><h3 className="font-medium">Model whitelist</h3><p className="text-sm text-muted-foreground">{openrouter.selected.length+cursor.selected.length} selected across providers</p></div><div className="flex flex-wrap gap-2">{(["openrouter","cursor"] as const).map(key=><Button key={key} disabled={!ready[key]||!policies[key].dirty||policies[key].save.isPending} onClick={()=>policies[key].save.mutate()}>{policies[key].save.isPending?"Saving…":`Save ${names[key]}`}</Button>)}</div></div>
    <p className="text-sm text-muted-foreground">Approve a model separately for each serving provider. Saving selections does not start agent tasks.</p>
    {(["openrouter","cursor"] as const).map(key=><div key={key} className="contents">{!ready[key]&&<p role="status" className="text-sm text-muted-foreground">{names[key]}: {key==="cursor"&&status.data?.state==="not_configured"?"connect in System to load models.":(key==="openrouter"?orModels.isPending:status.isPending||cursorModels.isFetching)?"loading models…":"model settings unavailable; refresh or check the connection in System."}</p>}{policies[key].save.isError&&<p role="alert" className="text-sm text-destructive">{names[key]}: {policies[key].save.error.message}<Button variant="link" onClick={()=>void policies[key].reload()}>Reload {names[key]} selection</Button></p>}</div>)}
    <div className="flex flex-wrap items-center gap-3"><Input className="min-w-0 flex-1 basis-60" aria-label="Search models" placeholder="Search models or providers…" value={search} onChange={e=>{setSearch(e.target.value);setPage(0);}}/>{[{label:"Provider",value:provider,set:setProvider,options:[["all","All providers"],["openrouter","OpenRouter"],["cursor","Cursor"]]},{label:"Show",value:filter,set:setFilter,options:[["all","All models"],["free","Free models"],["selected","Selected models"]]}].map(control=><label key={control.label} className="flex items-center gap-2 text-sm">{control.label}<select className="rounded-md border border-input bg-background px-3 py-2 text-foreground" value={control.value} onChange={e=>{control.set(e.target.value);setPage(0);}}>{control.options.map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label>)}</div>
    <div className="overflow-hidden rounded-md border"><Table className="min-w-[620px]"><TableHeader><TableRow><TableHead>Allow</TableHead><TableHead>Model / Provider</TableHead><TableHead>Input / 1M</TableHead><TableHead>Output / 1M</TableHead><TableHead>Context</TableHead></TableRow></TableHeader><TableBody>{filtered.slice(currentPage*20,currentPage*20+20).map(m=><TableRow key={`${m.provider}:${m.id}`}><TableCell><label className="grid min-h-11 min-w-11 place-items-center"><input className="size-4 accent-primary" type="checkbox" aria-label={`Allow ${m.id} via ${names[m.provider]}`} checked={policies[m.provider].selected.includes(m.id)} disabled={policies[m.provider].save.isPending||(!policies[m.provider].selected.includes(m.id)&&policies[m.provider].selected.length>=100)} onChange={()=>policies[m.provider].toggle(m.id)}/></label></TableCell><TableCell><div className="flex flex-wrap items-center gap-2"><ModelLink provider={m.provider} id={m.id} name={m.name}/><Badge variant="outline">{names[m.provider]}</Badge>{m.free&&<Badge variant="outline">Free</Badge>}{m.retired&&<Badge variant="outline">Unavailable</Badge>}</div><span className="block text-xs text-muted-foreground">{m.id}</span></TableCell><TableCell className="tabular-nums">{m.pricing?tokenPrice(m.pricing.prompt):"—"}</TableCell><TableCell className="tabular-nums">{m.pricing?tokenPrice(m.pricing.completion):"—"}</TableCell><TableCell className="tabular-nums">{m.context?.toLocaleString("en-US")??"—"}</TableCell></TableRow>)}</TableBody></Table>{!filtered.length&&<p className="p-6 text-sm text-muted-foreground">No models match these filters.</p>}</div>
    <div className="flex flex-wrap items-center justify-between gap-3 text-sm"><span className="text-muted-foreground">{filtered.length} matching models · Page {currentPage+1} of {pages}</span><div className="flex gap-2"><Button variant="outline" disabled={currentPage===0} onClick={()=>setPage(currentPage-1)}>Previous</Button><Button variant="outline" disabled={currentPage+1>=pages} onClick={()=>setPage(currentPage+1)}>Next</Button></div></div>
    <p className="text-xs text-muted-foreground">Up to 100 approved models per provider. Prices are base USD rates; extra capabilities can cost more. A dash means the provider did not supply that information. Cursor runs use your Cursor plan allowance.</p>
  </div>;
}
