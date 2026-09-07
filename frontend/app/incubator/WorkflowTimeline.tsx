import {type Evaluation} from "./evaluation";
import {ProgressFooter,type ProgressStep} from "./ProgressFooter";
import {type Run,stateLabel} from "./model";
const stages=[{state:"admitted",label:"Assigned"},{state:"preparing",label:"Preparing"},{state:"dispatched",label:"Researching"},{state:"completed",label:"Report ready"}] as const;
export function WorkflowTimeline({run,compact=false,evaluation}:{run:Run;compact?:boolean;evaluation?:Evaluation}) {
 const stopped=run.state==="failed"||stateLabel(run)==="Outcome unknown";
 const current=stages.findIndex(s=>s.state===run.state);
 if(run.state==="completed"&&evaluation){
  const status=evaluation.status,finished=["advance","refine","close"].includes(status);
  return <ProgressFooter steps={[{label:"Assigned",state:"complete"},{label:"Research",state:"complete"},{label:status==="failed"?"Failed":status==="indeterminate"?"Unknown":status==="awaiting_clarification"?"Clarify":status==="needs_input"?"Your input":"Evaluate",state:status==="failed"?"failed":status==="indeterminate"||status==="needs_input"?"paused":status==="evaluating"||status==="awaiting_clarification"?"active":finished?"complete":"pending"},{label:status==="advance"?"Advanced":status==="refine"?"Refine":status==="close"?"Closed":"Decision",state:finished?"complete":"pending"}]}/>;
 }
 if(compact){
  const lastReached=Math.max(0,...run.events.map(e=>stages.findIndex(s=>s.state===e.state)));
  // Pre-dispatch failures belong to preparation, even for older runs without that event.
  const failedStage=Math.max(1,lastReached);
  const steps:ProgressStep[]=stages.map((s,i)=>({label:stopped&&i===failedStage?(run.state==="failed"?"Failed":"Unknown"):s.state==="dispatched"?"Research":s.state==="completed"?"Ready":s.label,title:stopped&&i===failedStage?`${s.label}: ${run.state==="failed"?"Failed":"Outcome unknown"}`:s.label,state:stopped&&i===failedStage?(run.state==="failed"?"failed":"paused"):i===current&&["preparing","dispatched"].includes(run.state)?"active":i<=lastReached?"complete":"pending"}));
  return <ProgressFooter steps={steps}/>;
 }

 return <div className={compact?"mt-3 w-full":"min-w-0"} aria-label="Assignment workflow">
  {!compact&&<p className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">Workflow</p>}
  <ol className={`grid ${compact?"grid-cols-4 gap-1":"grid-cols-2 gap-3 sm:grid-cols-4"}`}>
   {stages.map((stage,i)=>{
    const event=run.events.find(e=>e.state===stage.state);
    const reached=!!event;
    const active=!stopped&&i===current;
    return <li key={stage.state} aria-current={active?"step":undefined} className="min-w-0">
     <div className={`mb-2 h-1 rounded-full ${reached?(stopped?"bg-muted-foreground":"bg-primary"):"bg-border"} ${active&&run.state!=="completed"?"workflow-progress-active":""}`}/>
     <p className={`${compact?"text-[9px]":"text-xs"} ${reached?"text-foreground":"text-muted-foreground"}`}>{compact&&stage.state==="dispatched"?"Research":compact&&stage.state==="completed"?"Ready":stage.label}</p>
     {!compact&&<p className="mt-1 text-[10px] tabular-nums text-muted-foreground">{event?<time dateTime={event.at} title={new Date(event.at).toLocaleString()}>{new Date(event.at).toLocaleTimeString([],{hour:"numeric",minute:"2-digit",second:"2-digit"})}</time>:"—"}</p>}
    </li>;
   })}
  </ol>
  {stopped&&<p className={`${compact?"mt-2 text-[10px]":"mt-3 text-xs"} ${run.state==="failed"?"text-destructive":"text-[var(--warning)]"}`}>{run.state==="failed"?"Stopped · Failed":"Paused · Outcome unknown"}{!compact&&` · ${new Date(run.updated_at).toLocaleString()}`}</p>}
  {!compact&&run.state==="admitted"&&<p className="mt-3 text-xs text-muted-foreground">Queued for the next available research slot.</p>}
 </div>;
}
