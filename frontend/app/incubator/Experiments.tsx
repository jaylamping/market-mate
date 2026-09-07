import type {Run} from "./model";
import {ticketCardStyles} from "./ticket-card-styles";
import {FlaskConical} from "lucide-react";
import {ExperimentCard} from "./ExperimentCard";
import type {Evaluation} from "./evaluation";
export function Experiments({evaluations,runs=[]}:{evaluations:Evaluation[];runs?:Run[]}){
 const tickets=evaluations.filter(e=>e.experiment);
 return <section aria-labelledby="experiments-heading" className="mt-5"><div className="mb-4"><h2 id="experiments-heading" className="text-xl font-semibold">Experiments <span className="ml-2 text-sm font-normal text-muted-foreground">{tickets.length}</span></h2><p className="mt-2 text-sm text-muted-foreground">Automatic setup, dataset readiness, and bounded local diagnostic results.</p></div>
 {!tickets.length?<div className="rounded-xl border border-dashed border-border p-8 text-sm text-muted-foreground"><FlaskConical className="mb-3 size-5" aria-hidden="true"/>Research that advances through evaluation will appear here.</div>:<div className={ticketCardStyles.grid}>{tickets.map(e=><ExperimentCard key={e.id} evaluation={e} creatorModel={runs.find(run=>run.run_key===e.run_key)?.config.model}/>)}</div>}
 </section>
}
