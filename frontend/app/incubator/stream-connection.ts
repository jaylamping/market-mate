export type StreamStatus = "connecting" | "live" | "polling";
export const STREAM_CONNECT_TIMEOUT_MS = 10_000;
export const STREAM_POLL_INTERVAL_MS = 5_000;
type Source = Pick<EventSource,"onmessage"|"onerror"|"close">;
export function connectWorkflowStream(create:()=>Source, apply:(data:string)=>Promise<void>, status:(value:StreamStatus)=>void) {
 let active=true;
 const update=(value:StreamStatus)=>{if(active)status(value);};
 update("connecting");
 const timeout=setTimeout(()=>update("polling"),STREAM_CONNECT_TIMEOUT_MS);
 let source:Source;
 try {source=create();} catch {clearTimeout(timeout);update("polling");return()=>{active=false;};}
 source.onmessage=async event=>{
  try {await apply(event.data);if(active){clearTimeout(timeout);update("live");}}
  catch {clearTimeout(timeout);update("polling");}
 };
 source.onerror=()=>{clearTimeout(timeout);update("polling");};
 return()=>{active=false;clearTimeout(timeout);source.onmessage=null;source.onerror=null;source.close();};
}
