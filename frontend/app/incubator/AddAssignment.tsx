"use client";
import {useEffect,useRef,useState} from "react";
import {useQuery,useQueryClient} from "@tanstack/react-query";
import {Dialog} from "radix-ui";
import {Plus,X,LoaderCircle,TriangleAlert} from "lucide-react";
import {Button} from "@/components/ui/button";
import {Input} from "@/components/ui/input";
import {incubatorQuery,modelRoutingQuery} from "@/lib/api-queries";
import {assignmentRequest,needsWarning,parseCheck,requestError,type RequestCheck} from "@/lib/incubator-requests";

export function AddAssignment() {
 const [open,setOpen]=useState(false),[title,setTitle]=useState(""),[text,setText]=useState(""),[model,setModel]=useState("");
 const [phase,setPhase]=useState<"editing"|"checking"|"warning"|"submitting">("editing");
 const [check,setCheck]=useState<RequestCheck|null>(null),[error,setError]=useState(""),[notice,setNotice]=useState("");
 const id=useRef<string|null>(null),busy=useRef(false),client=useQueryClient();
 const routing=useQuery({...modelRoutingQuery,enabled:open});
 const models=routing.data?.models.map(m=>m.routes[0]).filter(r=>r.provider==="openrouter")??[];
 const locked=phase==="checking"||phase==="submitting";
 function revise(){id.current=null;setCheck(null);setPhase("editing");setError("");}
 async function submit(checked:RequestCheck,accept=false) {
   setPhase("submitting");setError("");
   try {
     await assignmentRequest("",{request_id:checked.request_id,accept_warning:accept});
     await client.invalidateQueries({queryKey:incubatorQuery.queryKey});
     setNotice("Ticket queued. Its workflow will update automatically.");
     setOpen(false);setTitle("");setText("");setModel("");revise();
   }catch(e){const code=e instanceof Error?e.message:"Submission failed";setError(requestError(code));
     if(code==="history_changed_recheck"){id.current=null;setCheck(null);setPhase("editing");}else setPhase("warning");
   }
 }
 async function receive(value:unknown) {
   const next=parseCheck(value);setCheck(next);
   if(next.run_key){setNotice("This ticket is already queued.");setOpen(false);revise();return;}
   if(!next.result){setPhase("checking");return;}
   if(needsWarning(next)){setPhase("warning");setNotice("Review the similarity warning in New research ticket before proceeding.");}else await submit(next);
 }
 async function start() {
   if(busy.current)return;busy.current=true;setError("");setNotice("");setPhase("checking");
   id.current??=crypto.randomUUID();
   try {await receive(await assignmentRequest("/check",{request_id:id.current,title:title.trim(),text:text.trim(),model}));}
   catch(e){setError(requestError(e instanceof Error?e.message:"Check failed"));setPhase("editing");}
   finally{busy.current=false;}
 }
 useEffect(()=>{
   if(phase!=="checking"||!check||check.result)return;
   let cancelled=false;
   const timer=setInterval(async()=>{
     if(busy.current)return;busy.current=true;
     try{const value=await assignmentRequest(`/check/${check.request_id}`);if(!cancelled)await receive(value);}
     catch(e){if(!cancelled)setError(requestError(e instanceof Error?e.message:"Check unavailable"));}
     finally{busy.current=false;}
   },1500);
   return()=>{cancelled=true;clearInterval(timer);};
 // Each recorded check owns one polling cycle; closing the modal does not discard it.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[phase,check?.request_id]);
 return <><Dialog.Root open={open} onOpenChange={setOpen}><Dialog.Trigger asChild><Button className="min-h-11"><Plus aria-hidden="true"/>Research</Button></Dialog.Trigger>
 <Dialog.Portal><Dialog.Overlay className="fixed inset-0 z-50 bg-black/60"/>
 <Dialog.Content className="fixed left-1/2 top-1/2 z-50 max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-2xl border border-border bg-background p-6 text-foreground shadow-xl">
  <Dialog.Title className="pr-10 text-xl font-semibold">New research ticket</Dialog.Title>
  <Dialog.Description className="mt-2 text-sm text-muted-foreground">Describe a research question. We’ll check existing tickets, then queue it with your chosen model.</Dialog.Description>
  <Dialog.Close asChild><Button variant="ghost" size="icon" className="absolute right-3 top-3 min-h-11 min-w-11" aria-label="Close new ticket"><X/></Button></Dialog.Close>
  <form className="mt-6 space-y-5" onSubmit={e=>{e.preventDefault();void start();}}>
   <label className="block space-y-2 text-sm font-medium">Title<Input required maxLength={240} value={title} disabled={locked} placeholder="What would you like to investigate?" onChange={e=>{setTitle(e.target.value);revise();}}/></label>
   <label className="block space-y-2 text-sm font-medium">Request<textarea required maxLength={6000} rows={5} value={text} disabled={locked} onChange={e=>{setText(e.target.value);revise();}} className="w-full resize-y rounded-md border border-input bg-background px-3 py-2 text-sm leading-relaxed focus-visible:outline-2 focus-visible:outline-ring" placeholder="Describe the hypothesis, question, or experiment you have in mind…"/></label>
   <label className="block space-y-2 text-sm font-medium">Ticket model<select value={model} disabled={locked||routing.isPending} onChange={e=>{setModel(e.target.value);revise();}} className="min-h-11 w-full rounded-md border border-input bg-background px-3 text-sm"><option value="">Use research runner{(routing.data?.research_model??routing.data?.default_model)?` · ${routing.data?.research_model??routing.data?.default_model}`:""}</option>{models.map(m=><option key={m.model_id} value={m.model_id}>{m.model_id}</option>)}</select></label>
   {routing.isError&&<p role="alert" className="text-sm text-destructive">Model choices are unavailable. The saved research runner or default will be checked when you submit.</p>}
   <p className="text-xs leading-relaxed text-muted-foreground">Owner-authored research text only. Manual tickets can use approved free or paid models. Paid models incur provider charges. Similarity checks use the default/fallback model when wording alone is inconclusive.</p>
   {phase==="checking"&&<p role="status" className="flex gap-2 text-sm"><LoaderCircle className="size-4 animate-spin"/>Checking current and historical tickets…</p>}
   {phase==="warning"&&check?.result&&<section aria-label="Similarity warning" className="space-y-3 rounded-lg border border-[var(--warning)]/50 bg-[var(--warning)]/5 p-4">
    <h3 className="flex items-center gap-2 text-sm font-medium"><TriangleAlert className="size-4"/>{check.result.matches.length?"Similar tickets found":check.result.complete?"Ready to create":"Similarity check incomplete"}</h3>
    {check.result.matches.map(m=><article key={m.id} className="space-y-1 border-t border-border pt-3 text-sm"><p className="font-medium">{m.title}</p><p className="text-xs text-muted-foreground">{m.state.replaceAll("_"," ")}</p><p>{m.reason}</p>{m.run_key?<a className="text-primary underline underline-offset-4" href={`/incubator?run=${encodeURIComponent(m.run_key)}`} target="_blank" rel="noreferrer">View ticket ↗</a>:<details><summary className="cursor-pointer text-primary">View preserved ticket</summary><p className="mt-2 break-words">{m.text}</p><p className="mt-2 break-all text-xs text-muted-foreground">{m.id}</p></details>}</article>)}
    {!check.result.complete&&<div className="space-y-1 text-sm"><p>We could not fully assess similarity. This does not mean no duplicates exist.</p>{check.result.issues.map(i=><p key={i} className="text-xs text-muted-foreground">{requestError(i)}</p>)}</div>}
    <p className="text-xs text-muted-foreground">You can revise the request above, cancel, or create it anyway.</p>
   </section>}
   {error&&<p role="alert" className="text-sm text-destructive">{error}</p>}
   <div className="flex flex-wrap justify-end gap-2"><Dialog.Close asChild><Button type="button" variant="outline" className="min-h-11">{locked?"Close":"Cancel"}</Button></Dialog.Close>
    {phase==="warning"&&check?.result?<Button type="button" className="min-h-11" onClick={()=>void submit(check,true)}>{needsWarning(check)?"Create ticket anyway":"Retry submission"}</Button>:<Button type="submit" className="min-h-11" disabled={locked||!title.trim()||!text.trim()}>{phase==="submitting"?"Queueing…":phase==="checking"?"Checking…":"Check & create ticket"}</Button>}
   </div>
  </form>
 </Dialog.Content></Dialog.Portal></Dialog.Root>{notice&&<span role="status" className="order-first max-w-64 text-xs text-muted-foreground">{notice}</span>}</>;
}
