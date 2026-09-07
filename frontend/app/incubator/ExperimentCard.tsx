"use client";
import {useQuery} from "@tanstack/react-query";
import {parseRuns} from "./model";
import {TicketModelBadge} from "./TicketModelBadge";
import {ticketCardStyles} from "./ticket-card-styles";
import {useState} from "react";

import {Dialog,Tabs} from "radix-ui";
import {ArrowUpRight,X} from "lucide-react";
import {Badge} from "@/components/ui/badge";
import {OriginBadge} from "./OriginBadge";
import {ProgressFooter,type ProgressStep} from "./ProgressFooter";
import {ResearchReport} from "./ResearchReport";
import {EvaluationView} from "./EvaluationView";


import {experimentLabel,experimentOutcome,experimentOutcomeColor,experimentOutcomeLabel,type Evaluation,type ExperimentOutcome} from "./evaluation";
import {ExperimentDetail,experimentProgress} from "./ExperimentDetail";

function OutcomeBadge({outcome}:{outcome:ExperimentOutcome}){
 if(outcome==="active")return null;
 const color=experimentOutcomeColor[outcome];
 return <Badge variant="outline" style={{color,borderColor:`color-mix(in srgb, ${color} 35%, transparent)`,backgroundColor:`color-mix(in srgb, ${color} 10%, transparent)`}}>{experimentOutcomeLabel[outcome]}</Badge>;
}

export function ExperimentCard({evaluation:e,creatorModel}:{evaluation:Evaluation;creatorModel?:string}){
 const [open,setOpen]=useState(false);
 const source=useQuery({queryKey:["experiment-creator",e.run_key],enabled:!!e.experiment&&!creatorModel,staleTime:Infinity,queryFn:async()=>{
  const response=await fetch(`/api/incubator/runs/${encodeURIComponent(e.run_key)}`,{cache:"no-store"});
  if(!response.ok)throw Error("Creating model unavailable");
  const run=await response.json();
  return parseRuns({environment:"local_research",artifact_kind:"research_planning",runs:[run]})[0].config.model;
 }});
 if(!e.experiment)return null;
 const steps:ProgressStep[]=experimentProgress(e.experiment);
 const outcome=experimentOutcome(e.experiment);
 const sourceLink=`?run=${encodeURIComponent(e.run_key)}&revision=${e.revision}`;
 return <Dialog.Root open={open} onOpenChange={setOpen}><Dialog.Trigger asChild><button id={`experiment-${e.id}`} className={ticketCardStyles.surface}><span className="flex w-full items-start justify-between gap-3"><span className="flex min-w-0 flex-wrap gap-2"><TicketModelBadge model={creatorModel??source.data}/><OutcomeBadge outcome={outcome}/></span><ArrowUpRight className="size-4 shrink-0 text-muted-foreground transition-colors group-hover:text-primary" aria-hidden="true"/></span><span className={ticketCardStyles.title}>{e.experiment.title}</span><span className={ticketCardStyles.preview}>{e.report.hypothesis}</span><div className={ticketCardStyles.footer}><p>Research revision {e.revision}{e.status==="superseded"?" · Research has a newer revision":""}</p><time className="block tabular-nums" dateTime={e.experiment.created_at}>{new Date(e.experiment.created_at).toLocaleString()}</time><ProgressFooter label="Experiment workflow" steps={steps}/></div></button></Dialog.Trigger>
 <Dialog.Portal><Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/><Dialog.Content className="fixed left-1/2 top-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-6xl -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border bg-background text-foreground shadow-xl focus:outline-none">
 <div className="grid shrink-0 gap-5 border-b border-border p-5 pr-16 sm:p-6 sm:pr-16 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.8fr)]"><div><div className="mb-3 flex flex-wrap gap-2"><Badge variant="outline">{experimentLabel[e.experiment.status]}</Badge><OutcomeBadge outcome={outcome}/><OriginBadge origin="agent"/></div><Dialog.Title className="text-lg font-semibold leading-snug sm:text-xl">{e.experiment.title}</Dialog.Title><Dialog.Description className="mt-2 text-sm text-muted-foreground">Experiment · {new Date(e.experiment.created_at).toLocaleString()} · {experimentLabel[e.experiment.status]}</Dialog.Description></div><div className="min-w-0"><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Workflow</p><ProgressFooter steps={steps} label="Experiment workflow" compact={false}/></div><Dialog.Close asChild><button type="button" aria-label="Close experiment" className="absolute right-3 top-3 grid min-h-11 min-w-11 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring"><X className="size-5" aria-hidden="true"/></button></Dialog.Close></div>
 <Tabs.Root defaultValue="results" className="flex h-[min(72dvh,50rem)] min-h-0 flex-col"><Tabs.List aria-label="Experiment view" className="flex shrink-0 gap-5 border-b border-border px-5 sm:px-6">{["Research","Results","Chat"].map(label=><Tabs.Trigger key={label} value={label.toLowerCase()} className="min-h-11 border-b-2 border-transparent px-1 text-sm text-muted-foreground outline-none data-[state=active]:border-primary data-[state=active]:text-foreground focus-visible:ring-2 focus-visible:ring-ring">{label}</Tabs.Trigger>)}</Tabs.List>
 <Tabs.Content value="results" className="min-h-0 overflow-y-auto overscroll-contain p-5 sm:p-6"><ExperimentDetail experiment={e.experiment}/></Tabs.Content>
 <Tabs.Content value="research" className="min-h-0 overflow-y-auto overscroll-contain p-5 sm:p-6"><div className="mb-6 flex flex-wrap items-start justify-between gap-3"><div><h3 className="text-sm font-semibold">Research · Revision {e.revision}</h3><p className="mt-2 text-sm text-muted-foreground">The research plan used for this experiment.{e.status==="superseded"?" Newer research exists; this experiment retains its original revision.":""}</p></div><a href={sourceLink} className="text-sm text-primary underline underline-offset-4">Research history and chat</a></div><ResearchReport report={e.report}/><div className="mt-6 border-t border-border pt-6"><EvaluationView evaluation={e}/></div></Tabs.Content>
 <Tabs.Content value="chat" className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5 sm:p-6"><ExperimentDetail experiment={e.experiment} chat/></Tabs.Content>
 </Tabs.Root></Dialog.Content></Dialog.Portal></Dialog.Root>;
}
