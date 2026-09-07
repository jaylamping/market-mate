"use client";
import {useState} from "react";
import type {Run} from "./model";
import {ticketCardStyles} from "./ticket-card-styles";
import {ExperimentCard} from "./ExperimentCard";
import {experimentOutcome,experimentOutcomeLabel,experimentOutcomeOrder,visibleExperiments,type Evaluation,type Experiment} from "./evaluation";
import {Tabs,TabsList,TabsTrigger} from "@/components/ui/tabs";

const filters=["all",...experimentOutcomeOrder] as const;
type ExperimentFilter=(typeof filters)[number];

function emptyFilterCopy(filter:ExperimentFilter):string {
 if(filter==="all")return "No matching experiments.";
 return `No ${experimentOutcomeLabel[filter].toLowerCase()} experiments.`;
}

export function Experiments({evaluations,runs=[]}:{evaluations:Evaluation[];runs?:Run[]}){
 const tickets=evaluations.filter((evaluation):evaluation is Evaluation&{experiment:Experiment}=>!!evaluation.experiment);
 const [filter,setFilter]=useState<ExperimentFilter>("active");
 const counts:Record<ExperimentFilter,number>={all:tickets.length,active:0,positive:0,negative:0,terrible:0,stopped:0};
 for(const evaluation of tickets)counts[experimentOutcome(evaluation.experiment)]+=1;
 const visible=visibleExperiments(tickets,filter);
 return <section aria-labelledby="experiments-heading" className="mt-5">
  <div className="mb-4">
   <div className="flex flex-wrap items-center justify-between gap-3">
    <h2 id="experiments-heading" className="text-xl font-semibold">Experiments <span className="ml-2 text-sm font-normal text-muted-foreground">{tickets.length}</span></h2>
    {!!tickets.length&&<Tabs value={filter} onValueChange={value=>setFilter(value as ExperimentFilter)}>
     <TabsList aria-label="Filter experiments by diagnostic outcome" className="h-auto flex-wrap [&_[role=tab]]:gap-2 [&_[role=tab]_span]:text-xs [&_[role=tab]_span]:text-muted-foreground">{filters.map(value=><TabsTrigger key={value} value={value}>{value==="all"?"All":experimentOutcomeLabel[value]} <span>{counts[value]}</span></TabsTrigger>)}</TabsList>
    </Tabs>}
   </div>
   <p className="mt-2 text-sm text-muted-foreground">Research tickets with promise.</p>
  </div>
  {!tickets.length?<div className={ticketCardStyles.empty}>No experiments.</div>
  :!visible.length?<div className={ticketCardStyles.empty}>{emptyFilterCopy(filter)}</div>
  :<div className={ticketCardStyles.grid}>{visible.map(evaluation=><ExperimentCard key={evaluation.id} evaluation={evaluation} creatorModel={runs.find(run=>run.run_key===evaluation.run_key)?.config.model}/>)}</div>}
 </section>;
}
