import test from "node:test";
import assert from "node:assert/strict";
import {connectWorkflowStream,STREAM_CONNECT_TIMEOUT_MS,type StreamStatus} from "../app/incubator/stream-connection";
function source(){return {onmessage:null,onerror:null,close(){this.closed=true;},closed:false} as Pick<EventSource,"onmessage"|"onerror"|"close">&{closed:boolean};}
async function message(stream:ReturnType<typeof source>,data="snapshot"){await stream.onmessage?.call(stream as unknown as EventSource,{data} as MessageEvent);}
test("a stream with no usable snapshot times out, then recovers on valid data",async t=>{
 t.mock.timers.enable({apis:["setTimeout"]});
 const stream=source(),states:StreamStatus[]=[];
 const stop=connectWorkflowStream(()=>stream,async()=>{},s=>states.push(s));
 t.mock.timers.tick(STREAM_CONNECT_TIMEOUT_MS-1);assert.deepEqual(states,["connecting"]);
 t.mock.timers.tick(1);assert.equal(states.at(-1),"polling");
 await message(stream);assert.equal(states.at(-1),"live");
 // The server sends only changed snapshots; quiet healthy connections remain live.
 t.mock.timers.tick(60_000);assert.equal(states.at(-1),"live");
 stop();assert.equal(stream.closed,true);
});
test("invalid snapshots and connection errors trigger fallback, and a reconnect restores live updates",async t=>{
 t.mock.timers.enable({apis:["setTimeout"]});
 const stream=source(),states:StreamStatus[]=[];
 const stop=connectWorkflowStream(()=>stream,async data=>{if(data==="invalid")throw Error("Invalid history");},s=>states.push(s));
 await message(stream,"invalid");assert.equal(states.at(-1),"polling");
 await message(stream);assert.equal(states.at(-1),"live");
 stream.onerror?.call(stream as unknown as EventSource,{} as Event);assert.equal(states.at(-1),"polling");
 await message(stream);assert.equal(states.at(-1),"live");
 stop();
});
test("cleanup cancels timeout and ignores a pending snapshot",async t=>{
 t.mock.timers.enable({apis:["setTimeout"]});
 const stream=source(),states:StreamStatus[]=[];
 let resolve!:()=>void;const pending=new Promise<void>(r=>{resolve=r;});
 const stop=connectWorkflowStream(()=>stream,()=>pending,s=>states.push(s));
 const delivered=message(stream);stop();resolve();await delivered;
 t.mock.timers.tick(60_000);assert.deepEqual(states,["connecting"]);
 assert.equal(stream.onmessage,null);assert.equal(stream.onerror,null);assert.equal(stream.closed,true);
});
test("failure to create the stream immediately enables polling",()=>{
 const states:StreamStatus[]=[];
 const stop=connectWorkflowStream(()=>{throw Error("Unavailable");},async()=>{},s=>states.push(s));
 assert.deepEqual(states,["connecting","polling"]);stop();
});
