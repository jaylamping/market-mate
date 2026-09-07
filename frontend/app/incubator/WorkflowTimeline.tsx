import {type Run,stateLabel} from "./model";
const stages=[{state:"admitted",label:"Assigned"},{state:"preparing",label:"Preparing"},{state:"dispatched",label:"Researching"},{state:"completed",label:"Report ready"}] as const;
export function WorkflowTimeline({run,compact=false}:{run:Run;compact?:boolean}) {
 const stopped=run.state==="failed"||stateLabel(run)==="Outcome unknown";
 const current=stages.findIndex(s=>s.state===run.state);
 return <div className={compact?"mt-3 w-full":"min-w-0"} aria-label="Assignment workflow">
  {!compact&&<p className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">Workflow</p>}
  <ol className={`grid ${compact?"grid-cols-4 gap-1":"grid-cols-2 gap-3 sm:grid-cols-4"}`}>
   {stages.map((stage,i)=>{
    const event=run.events.find(e=>e.state===stage.state);
    const reached=!!event;
    const active=!stopped&&i===current;
    return <li key={stage.state} aria-current={active?"step":undefined} className="min-w-0">
     <div className={`mb-2 h-1 rounded-full ${reached?(stopped?"bg-muted-foreground":"bg-primary"):"bg-border"} ${active&&run.state!=="completed"?"motion-safe:animate-pulse":""}`}/>
     <p className={`${compact?"text-[9px]":"text-xs"} ${reached?"text-foreground":"text-muted-foreground"}`}>{compact&&stage.state==="dispatched"?"Research":compact&&stage.state==="completed"?"Ready":stage.label}</p>
     {!compact&&<p className="mt-1 text-[10px] tabular-nums text-muted-foreground">{event?<time dateTime={event.at} title={new Date(event.at).toLocaleString()}>{new Date(event.at).toLocaleTimeString([],{hour:"numeric",minute:"2-digit",second:"2-digit"})}</time>:"—"}</p>}
    </li>;
   })}
  </ol>
  {stopped&&<p className={`${compact?"mt-2 text-[10px]":"mt-3 text-xs"} ${run.state==="failed"?"text-destructive":"text-[var(--warning)]"}`}>{run.state==="failed"?"Stopped · Failed":"Paused · Outcome unknown"}{!compact&&` · ${new Date(run.updated_at).toLocaleString()}`}</p>}
  {!compact&&run.state==="admitted"&&<p className="mt-3 text-xs text-muted-foreground">Queued for the next available research slot.</p>}
 </div>;
}
