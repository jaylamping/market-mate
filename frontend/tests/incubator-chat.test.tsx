import test from "node:test";
import assert from "node:assert/strict";
import {readChatStream} from "../lib/incubator-chat";
import {POST} from "../app/api/incubator/runs/[key]/chat/route";
test("chat events survive every UTF-8 chunk boundary and keepalive frames",async()=>{
 const wire=new TextEncoder().encode(': keepalive\n\ndata: {"type":"preview","text":"café 😀"}\n\ndata: {"type":"saved","conversation":{"revision":1,"turns":[]}}\n\n');
 const received:unknown[]=[];
 await readChatStream(new ReadableStream({start(c){for(const byte of wire)c.enqueue(new Uint8Array([byte]));c.close();}}),e=>received.push(e));
 assert.deepEqual(received,[{type:"preview",text:"café 😀"},{type:"saved",conversation:{revision:1,turns:[]}}]);
});
test("a preview without a persistence receipt is not treated as delivered",async()=>{
 await assert.rejects(readChatStream(new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('data: {"type":"preview","text":"partial"}\n\n'));c.close();}}),()=>{}),/receipt/);
});
test("chat rejects missing, remote, and cross-origin submissions before forwarding",async()=>{
 for(const origin of [undefined,"https://evil.example","http://localhost:4000"]){const headers:Record<string,string>={host:"localhost:3000"};if(origin)headers.origin=origin;
 const r=await POST(new Request("http://localhost:3000/api/incubator/runs/probe/chat",{method:"POST",headers,body:"{}"}),{params:Promise.resolve({key:"probe"})});assert.equal(r.status,403);}
});
