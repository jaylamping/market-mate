import {FlaskConical} from "lucide-react";
import {ExperimentCard} from "./ExperimentCard";
import type {Evaluation} from "./evaluation";
export function Experiments({evaluations}:{evaluations:Evaluation[]}){
 const tickets=evaluations.filter(e=>e.experiment);
 return <section aria-labelledby="experiments-heading" className="mt-8 border-t border-border pt-7"><div className="mb-5"><h2 id="experiments-heading" className="text-xl font-semibold">Experiments <span className="ml-2 text-sm font-normal text-muted-foreground">{tickets.length}</span></h2><p className="mt-2 text-sm text-muted-foreground">Automatic setup, dataset readiness, and bounded local diagnostic results.</p></div>
 {!tickets.length?<div className="rounded-xl border border-dashed border-border p-8 text-sm text-muted-foreground"><FlaskConical className="mb-3 size-5" aria-hidden="true"/>Research that advances through evaluation will appear here.</div>:<div className="grid grid-cols-[repeat(auto-fill,minmax(min(100%,14rem),15rem))] gap-4">{tickets.map(e=><ExperimentCard key={e.id} evaluation={e}/>)}</div>}
 </section>
}
