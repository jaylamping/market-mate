"use client";
import {useQuery} from "@tanstack/react-query";
import {openrouterModelsQuery,cursorModelsQuery,cursorStatusQuery} from "@/lib/api-queries";
import {Button} from "@/components/ui/button";
import {useRoutingEditor} from "./RoutingEditor";
export function AgentConfiguration(){
 const models=useQuery(openrouterModelsQuery),status=useQuery(cursorStatusQuery);
 const cursor=useQuery({...cursorModelsQuery,enabled:status.data?.state==="connected"});
 const {query,policy,save,draft,persist,conflict,reload}=useRoutingEditor();
 return <div className="grid gap-4 p-6">
 {query.isError&&<p role="alert">Agent configuration unavailable. <Button variant="link" onClick={()=>void query.refetch()}>Reload</Button></p>}
 {save.isError&&<div role="alert"><p>{save.error.message}</p>{conflict?<Button variant="link" onClick={()=>void reload()}>Discard unsaved edits and load latest</Button>:draft&&<Button variant="link" onClick={()=>persist(draft)}>Retry saving</Button>}</div>}
 {save.isPending&&<p role="status" className="text-sm text-muted-foreground">Saving configuration…</p>}
    <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-4">{([
      ["research_model","Research runner","Used for research assignments without an explicit model and for research evaluation."],
      ["setup_model","Setup runner","Checks the pinned research plan and dataset readiness before handing a validated package to Experiment."],
      ["experiment_model","Experiment runner","Checks the Setup package before automatic bounded local diagnostic execution."],
      ["default_model","Default / Fallback Model","Used when a runner is unset, for similarity checks, or once after a confirmed research failure."]
    ] as const).map(([key,label,help])=><div key={key} className="grid content-start gap-2"><label htmlFor={key} className="text-sm font-medium">{label}</label><select id={key} className="min-h-11 w-full min-w-0 rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground" value={policy?.[key]??""} disabled={!policy||query.isError||save.isPending||conflict} onChange={e=>{if(policy)persist({...policy,[key]:e.target.value||null});}}><option value="">{key==="default_model"?"None — no default fallback":"Use default / fallback model"}</option>{[...(policy?.models??[])].sort((a,b)=>a.model_id.localeCompare(b.model_id)).map(m=><option key={m.model_id} value={m.model_id}>{m.routes.map(r=>(r.provider==="openrouter"?models.data:cursor.data)?.find(x=>x.id===r.model_id)?.name).find(Boolean)??m.model_id}</option>)}</select><p className="text-xs text-muted-foreground">{help} Provider order and execution budget still apply. Removing its last provider clears the setting.</p></div>)}</div>
 </div>;
}
