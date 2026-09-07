"use client";
import {useState} from "react";

import {Dialog,Tabs} from "radix-ui";
import {ArrowUpRight,X} from "lucide-react";
import {Badge} from "@/components/ui/badge";
import {OriginBadge} from "./OriginBadge";
import {ProgressFooter,type ProgressStep} from "./ProgressFooter";
import {ResearchReport} from "./ResearchReport";
import {EvaluationView} from "./EvaluationView";


import {experimentLabel,type Evaluation} from "./evaluation";
import {ExperimentDetail,experimentProgress} from "./ExperimentDetail";
export function ExperimentCard({evaluation:e}:{evaluation:Evaluation}){
 const [open,setOpen]=useState(false);
 if(!e.experiment)return null;
 const steps:ProgressStep[]=experimentProgress(e.experiment);
 const sourceLink=`?run=${encodeURIComponent(e.run_key)}&revision=${e.revision}`;
 return <Dialog.Root open={open} onOpenChange={setOpen}><Dialog.Trigger asChild><button id={`experiment-${e.id}`} className="group flex min-h-72 min-w-0 flex-col items-start gap-4 rounded-xl border border-border bg-card p-5 text-left hover:border-primary/60 focus-visible:outline-2 focus-visible:outline-ring"><span className="flex w-full items-center justify-between gap-2"><Badge variant="outline">{experimentLabel[e.experiment.status]}</Badge><ArrowUpRight className="size-4 text-muted-foreground" aria-hidden="true"/></span><OriginBadge origin="agent"/><span className="line-clamp-3 font-medium">{e.experiment.title}</span><span className="text-xs text-muted-foreground">Research revision {e.revision}{e.status==="superseded"?" · Research has a newer revision":""}</span><div className="mt-auto w-full"><ProgressFooter label="Experiment workflow" steps={steps}/></div></button></Dialog.Trigger>
 <Dialog.Portal><Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/><Dialog.Content className="fixed left-1/2 top-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-6xl -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border bg-background text-foreground shadow-xl focus:outline-none">
 <div className="grid shrink-0 gap-5 border-b border-border p-5 pr-16 sm:p-6 sm:pr-16 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,0.8fr)]"><div><div className="mb-3 flex flex-wrap gap-2"><Badge variant="outline">{experimentLabel[e.experiment.status]}</Badge><OriginBadge origin="agent"/></div><Dialog.Title className="text-lg font-semibold leading-snug sm:text-xl">{e.experiment.title}</Dialog.Title><Dialog.Description className="mt-2 text-sm text-muted-foreground">Experiment · {new Date(e.experiment.created_at).toLocaleString()} · {experimentLabel[e.experiment.status]}</Dialog.Description></div><div className="min-w-0"><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Workflow</p><ProgressFooter steps={steps} label="Experiment workflow" compact={false}/></div><Dialog.Close asChild><button type="button" aria-label="Close experiment" className="absolute right-3 top-3 grid min-h-11 min-w-11 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring"><X className="size-5" aria-hidden="true"/></button></Dialog.Close></div>
 <Tabs.Root defaultValue="report" className="flex h-[min(72dvh,50rem)] min-h-0 flex-col"><Tabs.List aria-label="Experiment view" className="flex shrink-0 gap-5 border-b border-border px-5 sm:px-6">{["Report","Chat"].map(label=><Tabs.Trigger key={label} value={label.toLowerCase()} className="min-h-11 border-b-2 border-transparent px-1 text-sm text-muted-foreground outline-none data-[state=active]:border-primary data-[state=active]:text-foreground focus-visible:ring-2 focus-visible:ring-ring">{label}</Tabs.Trigger>)}</Tabs.List>
 <Tabs.Content value="report" className="min-h-0 overflow-y-auto overscroll-contain p-5 sm:p-6"><div className="mb-5 flex flex-wrap items-center justify-between gap-3 text-sm"><a href={sourceLink} className="text-primary underline underline-offset-4">Open originating research · Revision {e.revision}</a><span className="text-xs text-muted-foreground">Pinned plan · {experimentLabel[e.experiment.status]}</span></div><ExperimentDetail experiment={e.experiment}/><details className="mt-6"><summary className="mb-4 cursor-pointer text-sm font-medium">Pinned research plan</summary><ResearchReport report={e.report}/></details><div className="mt-6"><EvaluationView evaluation={e}/></div></Tabs.Content>
 <Tabs.Content value="chat" className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5 sm:p-6"><ExperimentDetail experiment={e.experiment} chat/></Tabs.Content>
 </Tabs.Root></Dialog.Content></Dialog.Portal></Dialog.Root>;
}
