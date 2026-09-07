"use client";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { ArrowUp, LoaderCircle, Info } from "lucide-react";
import { Tooltip } from "radix-ui";
import { Button } from "@/components/ui/button";
import { MessageScrollerProvider, MessageScroller, MessageScrollerViewport, MessageScrollerContent, MessageScrollerItem, MessageScrollerButton } from "@/components/ui/message-scroller";
import { readChatStream, chatError, type Conversation, type ChatEvent } from "@/lib/incubator-chat";
import type { Run, Report } from "./model";

export function RunChat({run}:{run:Run}) {
  const url=`/api/incubator/runs/${encodeURIComponent(run.run_key)}/chat`,key=["incubator-chat",run.run_key];
  const client=useQueryClient();
  const query=useQuery({queryKey:key,queryFn:async()=>{const r=await fetch(url,{cache:"no-store"});if(!r.ok)throw Error("Conversation unavailable");return await r.json() as Conversation;},refetchInterval:2000});
  const [applying,setApplying]=useState<number|null>(null);
  const [draft,setDraft]=useState(""),[sending,setSending]=useState(false),[preview,setPreview]=useState(""),[error,setError]=useState<string|null>(null),[deliveryUnknown,setDeliveryUnknown]=useState(false);
  const gate=useRef(false),pendingId=useRef<string|null>(null);
  const turns=query.data?.turns??[],unresolved=turns.some(t=>t.state==="streaming"||t.state==="indeterminate");
  const blocked=applying!==null||sending||unresolved||query.isError||!query.data||query.data.revision>=50||!["completed","failed"].includes(run.state)||deliveryUnknown;
  useEffect(()=>{
    const stream=new EventSource(`${url}/stream`);
    stream.onmessage=message=>{
      try {const event=JSON.parse(message.data) as ChatEvent;
        if(event.type==="preview"){
          setPreview(event.text);
          const cached=client.getQueryData<Conversation>(["incubator-chat",run.run_key]);
          if(event.request_id&&!cached?.turns.some(t=>t.request_id===event.request_id))void client.invalidateQueries({queryKey:["incubator-chat",run.run_key]});
        } else if(event.type==="saved"){
          client.setQueryData(["incubator-chat",run.run_key],event.conversation);
          if(event.conversation.turns.at(-1)?.state!=="streaming")setPreview("");
        }
      } catch {void client.invalidateQueries({queryKey:["incubator-chat",run.run_key]});}
    };
    return ()=>stream.close();
  },[url,run.run_key,client]);
  async function reload() {
    const result=await query.refetch();
    if(result.isSuccess){if(result.data.turns.some(t=>t.request_id===pendingId.current)){setDraft("");pendingId.current=null;}setDeliveryUnknown(false);setError(null);}
  }
  async function applyPlan(sequence:number) {
    if(gate.current||blocked)return;
    gate.current=true;setApplying(sequence);setError(null);
    try {const r=await fetch(`${url}/plan`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({sequence,revision:query.data?.plan?.revision??0})});const data=await r.json();if(!r.ok)throw Error(data.error);client.setQueryData(key,data);}
    catch(e){setError(e instanceof Error?e.message:"Could not apply the plan update");}
    finally{gate.current=false;setApplying(null);}
  }
  async function send() {
    if(gate.current||blocked||!draft.trim())return;
    gate.current=true;setSending(true);setError(null);setPreview("");
    const id=pendingId.current??crypto.randomUUID();pendingId.current=id;
    try {
      const r=await fetch(url,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({request_id:id,revision:query.data!.revision,text:draft})});
      if(!r.ok){const value=await r.json();if(r.status<500)pendingId.current=null;else setDeliveryUnknown(true);throw Error(chatError(value.error??"Conversation unavailable"));}
      if(!r.body)throw Error("No reply stream received");
      await readChatStream(r.body,event=>{
        if(event.type==="saved"){client.setQueryData(key,event.conversation);if(event.conversation.turns.some(t=>t.request_id===id)){setDraft("");pendingId.current=null;}if(event.conversation.turns.at(-1)?.state!=="streaming")setPreview("");}
        else if(event.type==="preview")setPreview(event.text);
        else {setDeliveryUnknown(true);setError(event.error);}
      });
    } catch(e){setError(e instanceof Error?e.message:"Connection interrupted; reload to check delivery");setDeliveryUnknown(true);}
    finally {gate.current=false;setSending(false);void query.refetch();}
  }
  return <section className="flex h-full min-h-0 min-w-0 flex-col" aria-label="Task conversation">
    <div className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-5 py-3"><div className="min-w-0"><h3 className="text-sm font-medium">Chat with {run.config.agent_name}</h3><p className="truncate text-xs text-muted-foreground">{run.config.model}</p></div><Tooltip.Provider><Tooltip.Root><Tooltip.Trigger asChild><button type="button" aria-label="About task chat" className="grid size-11 shrink-0 place-items-center rounded-md text-muted-foreground focus-visible:outline-2 focus-visible:outline-ring"><Info className="size-4"/></button></Tooltip.Trigger><Tooltip.Portal><Tooltip.Content side="bottom" className="z-[60] max-w-xs rounded-md border border-border bg-popover p-3 text-xs text-popover-foreground shadow-md">Uses this assignment, its original report, and completed conversation turns. Suggested plan revisions take effect when you apply them. Explicitly selected manual models run as chosen, including paid models; one bounded logical request per message. Closing the window lets the reply finish and save.<Tooltip.Arrow className="fill-popover"/></Tooltip.Content></Tooltip.Portal></Tooltip.Root></Tooltip.Provider></div>
    <MessageScrollerProvider defaultScrollPosition="end"><MessageScroller>
      <MessageScrollerViewport aria-label="Conversation messages"><MessageScrollerContent className="gap-5 p-5">
        {query.isPending&&<p className="text-sm text-muted-foreground" role="status">Loading conversation…</p>}
        {query.isError&&<p className="text-sm text-destructive" role="alert">Conversation unavailable. <button className="underline" onClick={reload}>Reload</button></p>}
        {query.isSuccess&&!turns.length&&<div className="my-auto space-y-4 py-10"><h4 className="text-base font-medium">Explore this hypothesis</h4><p className="text-sm leading-relaxed text-muted-foreground">Ask about the methodology or suggest a different direction.</p><div className="flex flex-wrap gap-2">{["What would falsify this hypothesis?","Which assumption should we test first?"].map(s=><Button key={s} variant="outline" className="h-auto whitespace-normal py-2 text-left" onClick={()=>setDraft(s)}>{s}</Button>)}</div></div>}
        {turns.map((turn,i)=><MessageScrollerItem key={turn.request_id} messageId={turn.request_id} scrollAnchor><div className="space-y-4">
          <div className="ml-6 rounded-xl bg-muted px-4 py-3"><p className="mb-1 text-xs font-medium text-muted-foreground">You</p><p className="whitespace-pre-wrap break-words text-sm leading-relaxed">{turn.user_text}</p></div>
          <div className="mr-2"><p className="mb-2 text-xs font-medium text-primary">{run.config.agent_name}</p>
            {turn.state==="completed"?<><p className="whitespace-pre-wrap break-words text-sm leading-relaxed">{turn.detail.reply}</p>{turn.detail.proposal&&<PlanProposal report={turn.detail.proposal} appliedRevision={query.data?.plan?.revisions.find(r=>r.chat_sequence===turn.sequence)?.revision} busy={applying===turn.sequence} disabled={blocked} onApply={()=>applyPlan(turn.sequence)}/>}{turn.detail.usage&&<p className="mt-2 text-xs text-muted-foreground">{typeof turn.detail.usage.cost==="number"?`$${turn.detail.usage.cost.toFixed(2)}`:"Cost unavailable"}{typeof turn.detail.usage.completion_tokens==="number"?` · ${turn.detail.usage.completion_tokens} output tokens`:""}</p>}</>:
            turn.state==="streaming"?<div aria-busy="true">{i===turns.length-1&&preview?<p className="whitespace-pre-wrap break-words text-sm leading-relaxed">{preview}</p>:<p className="flex items-center gap-2 text-sm text-muted-foreground"><LoaderCircle className="size-4 animate-spin motion-reduce:animate-none"/>Thinking…</p>}</div>:
            <div className="space-y-2 text-sm"><p className={turn.state==="failed"?"text-destructive":"text-[var(--warning)]"}>{turn.state==="indeterminate"?"Delivery outcome unknown. This conversation is paused; no automatic resend will occur.":chatError(turn.detail.reason??"Reply failed")}</p>{turn.detail.response_text&&<details><summary className="cursor-pointer text-xs text-muted-foreground">Incomplete response</summary><p className="mt-2 whitespace-pre-wrap break-all text-xs">{turn.detail.response_text}</p></details>}</div>}
          </div>
        </div></MessageScrollerItem>)}
      </MessageScrollerContent></MessageScrollerViewport><MessageScrollerButton/></MessageScroller></MessageScrollerProvider>
    <form onSubmit={e=>{e.preventDefault();void send();}} className="shrink-0 space-y-3 border-t border-border p-4">
      {error&&<p role="alert" className="text-xs text-destructive">{error} <button type="button" className="underline" onClick={reload}>Reload conversation</button></p>}
      {query.data&&query.data.revision>=50&&<p className="text-xs text-muted-foreground">This conversation has reached its 50-message limit.</p>}
      <div className="incubator-chat-composer flex items-end gap-2 rounded-xl border border-input bg-background p-2 focus-within:ring-2 focus-within:ring-ring"><textarea aria-label="Message about this task" placeholder="Ask a question or steer the hypothesis…" value={draft} disabled={blocked} maxLength={6000} onChange={e=>setDraft(e.target.value)} onKeyDown={e=>{if(e.key==="Enter"&&!e.shiftKey&&!e.nativeEvent.isComposing){e.preventDefault();void send();}}} rows={2} className="max-h-36 min-h-14 min-w-0 flex-1 resize-y bg-transparent px-2 py-1 text-sm outline-none disabled:opacity-50"/><Button type="submit" size="icon" aria-label="Send message" disabled={blocked||!draft.trim()} className="size-11 rounded-lg">{sending?<LoaderCircle className="size-4 animate-spin motion-reduce:animate-none"/>:<ArrowUp className="size-4"/>}</Button></div>
    </form>
  </section>;
}

function PlanProposal({report,appliedRevision,busy,disabled,onApply}:{report:Report;appliedRevision?:number;busy:boolean;disabled:boolean;onApply:()=>void}) {
 return <div className="mt-4 space-y-3 rounded-xl border border-primary/30 bg-primary/5 p-4"><div className="flex flex-wrap items-center justify-between gap-2"><h4 className="text-sm font-medium">Proposed plan update</h4>{appliedRevision&&<span className="text-xs text-[var(--good)]">Applied · Revision {appliedRevision}</span>}</div><p className="text-sm leading-relaxed">{report.hypothesis}</p><details><summary className="cursor-pointer text-xs font-medium text-primary">Review full plan</summary><div className="mt-3 space-y-3 text-sm text-muted-foreground">{([['Evidence needed',report.evidence_gaps],['Experiment',report.experiment],['Limitations',report.limitations]] as const).map(([label,items])=><div key={label}><h5 className="mb-1 font-medium text-foreground">{label}</h5><ul className="list-disc space-y-1 pl-4">{items.map((item,i)=><li key={i}>{item}</li>)}</ul></div>)}<div><h5 className="font-medium text-foreground">Falsification rule</h5><p>{report.falsification_rule}</p></div></div></details>{!appliedRevision&&<Button type="button" variant="outline" disabled={disabled} onClick={onApply}>{busy?"Applying…":"Apply update"}</Button>}</div>;
}
