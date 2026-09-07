"use client";
import { ArrowDown, ArrowUp, ArrowUpDown } from "lucide-react";
import { catalogDate, type Sort, type SortKey } from "./model-sort";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ModelLink } from "@/components/ModelLink";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { cursorModelsQuery, cursorStatusQuery, openrouterModelsQuery, modelRoutingQuery } from "@/lib/api-queries";
import { isFree, tokenPrice, type ModelPricing } from "@/lib/openrouter";
import { referenceMetadata, groupModels, moveRoute, parseRouting, setRoutes, type Provider, type RoutingPolicy, type ModelRoute } from "@/lib/model-routing";

const names = {openrouter:"OpenRouter",cursor:"Cursor"};
type Offer = {provider:Provider;id:string;name:string;pricing?:ModelPricing;context?:number;created?:number;free:boolean;retired?:boolean};
export function ModelsTable() {
  const client=useQueryClient(),query=useQuery(modelRoutingQuery);
  const orModels=useQuery(openrouterModelsQuery),status=useQuery(cursorStatusQuery);
  const cursorModels=useQuery({...cursorModelsQuery,enabled:status.data?.state==="connected"});
  const [draft,setDraft]=useState<RoutingPolicy|null>(null);
  const policy=draft??query.data;
  const [search,setSearch]=useState(""),[provider,setProvider]=useState("all"),[filter,setFilter]=useState("all");
  const [sort,setSort]=useState<Sort>({key:"selected",direction:"desc"});
  const epoch=`${query.dataUpdatedAt}:${orModels.dataUpdatedAt}:${cursorModels.dataUpdatedAt}`;
  const [pageState,setPageState]=useState({index:0,epoch:""});
  const page=pageState.epoch===epoch?pageState.index:0;
  const setPage=(index:number)=>setPageState({index,epoch});
  const save=useMutation({mutationFn:async()=>{
    if(!draft)throw new Error("No changes to save.");
    const response=await fetch("/api/openrouter/routing",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(draft),signal:AbortSignal.timeout(20_000)});
    if(!response.ok)throw new Error(response.status===409?"Preferences changed elsewhere. Reload saved preferences before editing again.":"Could not save. Your changes are still here; check the provider connections and try again.");
    return parseRouting(await response.json());
  },onSuccess:value=>{client.setQueryData(modelRoutingQuery.queryKey,value);setDraft(null);void client.invalidateQueries({queryKey:["api","openrouter","policy"]});void client.invalidateQueries({queryKey:["api","cursor","policy"]});}});
  const dirty=!!draft&&(JSON.stringify(draft.models)!==JSON.stringify(query.data?.models)||draft.default_model!==query.data?.default_model);
  const update=(id:string,routes:ModelRoute[])=>{if(policy)setDraft(setRoutes(policy,id,routes));save.reset();};
  const reload=async()=>{const result=await query.refetch();if(result.isSuccess){setDraft(null);save.reset();}};
  const ready={openrouter:!!orModels.data&&!orModels.isError,cursor:status.data?.state==="connected"&&!!cursorModels.data&&!cursorModels.isError};
  const offers:Offer[]=[
    ...(ready.openrouter?orModels.data??[]:[]).map(m=>({provider:"openrouter" as const,id:m.id,name:m.name,pricing:m.pricing,context:m.context_length,created:m.created,free:isFree(m)})),
    ...(ready.cursor?cursorModels.data??[]:[]).map(m=>({provider:"cursor" as const,id:m.id,name:m.name,free:false})),
  ];
  for(const m of policy?.models??[])for(const r of m.routes)if(!offers.some(o=>o.provider===r.provider&&o.id===r.model_id))offers.push({provider:r.provider,id:r.model_id,name:m.model_id,free:false,retired:true});
  const groups=groupModels(offers).map(group=>{
    const routes=policy?.models.find(m=>m.model_id===group.id)?.routes??[];
    const saved=query.data?.models.find(m=>m.model_id===group.id)?.routes??[];
    const primary=group.offers.find(o=>o.provider===saved[0]?.provider&&o.id===saved[0]?.model_id)??group.offers.find(o=>o.provider==="openrouter")??group.offers[0];
    const metadata=group.offers.find(o=>o.provider==="openrouter")??primary;
    const {pricing,context}=referenceMetadata(primary,metadata);
    return {...group,routes,saved,primary,metadata,pricing,context,name:metadata.name.replace(/^(OpenAI|Anthropic|Google|MoonshotAI|Z-AI): /,"")};
  });
  const sortValue=(m:typeof groups[number]):string|number|undefined=>{
    switch(sort.key){
      case "selected":return Number(m.saved.length>0);
      case "name":return m.name;
      case "date":return m.metadata.created;
      case "context":return m.context;
      case "input":return m.pricing?Number(m.pricing.prompt):undefined;
      case "output":return m.pricing?Number(m.pricing.completion):undefined;
    }
  };
  const ordered=groups.sort((a,b)=>{
    const av=sortValue(a),bv=sortValue(b);
    if(av===undefined&&bv!==undefined)return 1;if(bv===undefined&&av!==undefined)return -1;
    const delta=typeof av==="string"&&typeof bv==="string"?av.localeCompare(bv):typeof av==="number"&&typeof bv==="number"?av-bv:0;
    return delta*(sort.direction==="asc"?1:-1)||a.name.localeCompare(b.name)||a.id.localeCompare(b.id);
  });
  const filtered=ordered.filter(m=>m.offers.some(o=>(provider==="all"||o.provider===provider)&&`${m.name} ${o.id} ${names[o.provider]}`.toLowerCase().includes(search.toLowerCase())&&(filter==="all"||(filter==="free"?o.free:m.routes.some(r=>r.provider===o.provider&&r.model_id===o.id)))));
  const pages=Math.max(1,Math.ceil(filtered.length/20)),currentPage=Math.min(page,pages-1);
  const counts={openrouter:policy?.models.flatMap(m=>m.routes).filter(r=>r.provider==="openrouter").length??0,cursor:policy?.models.flatMap(m=>m.routes).filter(r=>r.provider==="cursor").length??0};
  const sortHeader=(key:SortKey,label:string,title?:string)=><TableHead aria-sort={sort.key===key?(sort.direction==="asc"?"ascending":"descending"):"none"}><button type="button" title={title} className="inline-flex min-h-11 items-center gap-1 rounded-sm text-left focus-visible:outline-2 focus-visible:outline-ring" onClick={()=>{setSort({key,direction:sort.key===key&&sort.direction==="asc"?"desc":"asc"});setPage(0);}}>{label}{sort.key!==key?<ArrowUpDown className="size-3" aria-hidden="true"/>:sort.direction==="asc"?<ArrowUp className="size-3" aria-hidden="true"/>:<ArrowDown className="size-3" aria-hidden="true"/>}</button></TableHead>;
  return <div className="grid min-w-0 gap-4">
    <div className="flex flex-wrap items-end justify-between gap-3"><div><h3 className="font-medium">Model preferences</h3><p className="text-sm text-muted-foreground">{policy?.models.length??0} models selected · {counts.openrouter+counts.cursor} provider selections</p></div><div className="flex flex-wrap gap-2"><Button disabled={!query.data||query.isError||!dirty||save.isPending} onClick={()=>save.mutate()}>{save.isPending?"Saving…":"Save model preferences"}</Button></div></div>
    <p className="text-sm text-muted-foreground">Select providers for each model. Move selected providers up or down to set priority; number 1 is first. Saving does not start agent tasks.</p>
    <p className="text-xs text-muted-foreground">OpenRouter execution is available for approved free models. Cursor is catalog-only until its execution adapter is connected. An unavailable first choice blocks the POC; it does not silently switch providers.</p>
    {query.isError&&<p role="alert" className="text-sm text-destructive">Model preferences unavailable. <Button variant="link" onClick={()=>void query.refetch()}>Reload preferences</Button></p>}
    {save.isError&&<div role="alert" className="text-sm text-destructive"><p>{save.error.message}</p>{save.error.message.startsWith("Preferences changed elsewhere")&&<><p>Loading the latest preferences discards your unsaved edits.</p><Button variant="link" onClick={()=>void reload()}>Load latest preferences</Button></>}</div>}
    {save.isSuccess&&!dirty&&<p role="status" className="text-sm text-muted-foreground">Model preferences saved.</p>}
    {(["openrouter","cursor"] as const).map(key=>!ready[key]&&<p key={key} role="status" className="text-sm text-muted-foreground">{names[key]}: {key==="cursor"&&status.data?.state==="not_configured"?"connect in System to load models.":(key==="openrouter"?orModels.isPending:status.isPending||cursorModels.isFetching)?"loading models…":"catalog unavailable; refresh or check the connection in System."}</p>)}
    <div className="flex flex-wrap items-center gap-3"><Input className="min-w-0 flex-1 basis-60" aria-label="Search models" placeholder="Search models or providers…" value={search} onChange={e=>{setSearch(e.target.value);setPage(0);}}/>{[{label:"Provider",value:provider,set:setProvider,options:[["all","All providers"],["openrouter","OpenRouter"],["cursor","Cursor"]]},{label:"Show",value:filter,set:setFilter,options:[["all","All models"],["free","Free models"],["selected","Selected models"]]}].map(control=><label key={control.label} className="flex items-center gap-2 text-sm">{control.label}<select className="rounded-md border border-input bg-background px-3 py-2 text-foreground" value={control.value} onChange={e=>{control.set(e.target.value);setPage(0);}}>{control.options.map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label>)}</div>
    <div className="overflow-hidden rounded-md border"><Table className="min-w-[960px]"><TableHeader><TableRow>{sortHeader("name","Model")}{sortHeader("selected","Providers / Priority")}{sortHeader("date","Release Date","OpenRouter catalog-added date, not a verified original release date.")}{sortHeader("input","Input / 1M","Primary provider base price; OpenRouter reference when missing")}{sortHeader("output","Output / 1M","Primary provider base price; OpenRouter reference when missing")}{sortHeader("context","Context","Primary provider context; OpenRouter reference when missing")}</TableRow></TableHeader><TableBody>{filtered.slice(currentPage*20,currentPage*20+20).map(m=>{
      const selectedOffers=m.routes.map(r=>m.offers.find(o=>o.provider===r.provider&&o.id===r.model_id)!).filter(Boolean);
      const orderedOffers=[...selectedOffers,...m.offers.filter(o=>!selectedOffers.includes(o))];
      return <TableRow key={m.id}><TableCell className="min-w-56 align-top"><div className="pt-3 font-medium"><ModelLink provider={m.metadata.provider} id={m.metadata.id} name={m.name}/></div><span className="mt-1 block text-xs text-muted-foreground">{m.id}</span></TableCell><TableCell className="min-w-72"><div className="grid gap-1">{orderedOffers.map(o=>{
        const index=m.routes.findIndex(r=>r.provider===o.provider&&r.model_id===o.id),selected=index>=0;
        const disabled=save.isPending||!query.data||query.isError;
        return <div key={`${o.provider}:${o.id}`} className="flex items-center gap-1"><label className="flex min-h-11 flex-1 items-center gap-2 text-sm"><input className="size-4 accent-primary" type="checkbox" aria-label={`Allow ${o.id} via ${names[o.provider]}`} checked={selected} disabled={disabled||(!selected&&(!ready[o.provider]||o.retired||counts[o.provider]>=100))} onChange={()=>update(m.id,selected?m.routes.filter((_,i)=>i!==index):[...m.routes,{provider:o.provider,model_id:o.id}])}/><span className="w-4 tabular-nums text-muted-foreground">{selected?`${index+1}.`:""}</span><span title={o.id}>{names[o.provider]}</span>{o.free&&<Badge variant="outline">Free</Badge>}{o.retired&&<Badge variant="outline">Unavailable</Badge>}</label>{selected&&<div className="flex"><Button variant="ghost" size="icon" aria-label={`Move ${names[o.provider]} up for ${m.name}`} disabled={disabled||index===0} onClick={()=>update(m.id,moveRoute(m.routes,index,-1))}><ArrowUp className="size-4" aria-hidden="true"/></Button><Button variant="ghost" size="icon" aria-label={`Move ${names[o.provider]} down for ${m.name}`} disabled={disabled||index===m.routes.length-1} onClick={()=>update(m.id,moveRoute(m.routes,index,1))}><ArrowDown className="size-4" aria-hidden="true"/></Button></div>}</div>;
      })}</div></TableCell><TableCell className="whitespace-nowrap tabular-nums">{catalogDate(m.metadata.created)}</TableCell><TableCell className="tabular-nums">{m.pricing?tokenPrice(m.pricing.prompt):"—"}</TableCell><TableCell className="tabular-nums">{m.pricing?tokenPrice(m.pricing.completion):"—"}</TableCell><TableCell className="tabular-nums">{m.context?.toLocaleString("en-US")??"—"}</TableCell></TableRow>;
    })}</TableBody></Table>{!filtered.length&&<p className="p-6 text-sm text-muted-foreground">{query.isPending?"Loading preferences…":"No models match these filters."}</p>}</div>
    <div className="flex flex-wrap items-center justify-between gap-3 text-sm"><span className="text-muted-foreground">{filtered.length} matching models · Page {currentPage+1} of {pages}</span><div className="flex gap-2"><Button variant="outline" disabled={currentPage===0} onClick={()=>setPage(currentPage-1)}>Previous</Button><Button variant="outline" disabled={currentPage+1>=pages} onClick={()=>setPage(currentPage+1)}>Next</Button></div></div>
    <div className="grid gap-2 border-t pt-4">
      <label htmlFor="default-fallback-model" className="text-sm font-medium">Default / Fallback Model</label>
      <select id="default-fallback-model" className="min-h-11 w-full max-w-md rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground" value={policy?.default_model??""} disabled={!policy||query.isError||save.isPending} onChange={e=>{if(policy)setDraft({...policy,default_model:e.target.value||null});save.reset();}}>
        <option value="">None — no automatic fallback</option>
        {[...(policy?.models??[])].sort((a,b)=>a.model_id.localeCompare(b.model_id)).map(m=><option key={m.model_id} value={m.model_id}>{groups.find(g=>g.id===m.model_id)?.name??m.model_id}</option>)}
      </select>
      <p className="max-w-prose text-xs text-muted-foreground">Uses this model when no model is specified, or once after a confirmed failure. Its provider order and the run’s budget still apply. Uncertain outcomes never trigger fallback. Removing its last provider clears this setting.</p>
    </div>
    <p className="text-xs text-muted-foreground">Up to 100 selections per provider. Missing pricing and context use OpenRouter reference values; Cursor billing follows your Cursor plan. Prices are base USD rates; tiers and extra capabilities can cost more. A dash means information was not supplied. Free, Pro, preview, and batch variants remain separate.</p>
  </div>;
}
