import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {parseCheck,needsWarning} from "../lib/incubator-requests";
import {requestProxy} from "../lib/incubator-request-proxy";
import {WorkflowTimeline} from "../app/incubator/WorkflowTimeline";
import {type Run,stateLabel} from "../app/incubator/model";
test("matches and incomplete checks require an explicit decision; malformed checks are not clean",()=>{
 assert.equal(needsWarning(parseCheck({request_id:"x",result:null})),false);
 assert.equal(needsWarning(parseCheck({request_id:"x",result:{complete:true,matches:[],issues:[]}})),false);
 assert.equal(needsWarning(parseCheck({request_id:"x",result:{complete:false,matches:[],issues:["unavailable"]}})),true);
 assert.equal(needsWarning(parseCheck({request_id:"x",result:{complete:true,matches:[{id:"a",run_key:"a",title:"old",text:"premise",state:"completed",reason:"Same experiment"}],issues:[]}})),true);
 for(const result of [{matches:[],issues:[]},{complete:true,matches:[{}],issues:[]},{}])assert.throws(()=>parseCheck({request_id:"x",result}));
});
test("card timeline and detailed timestamps reflect persisted stages and never call failure completed",()=>{
 const run={state:"preparing",events:[{state:"admitted",at:"2026-09-07T01:00:00Z"},{state:"preparing",at:"2026-09-07T01:00:01Z"}],updated_at:"2026-09-07T01:00:01Z",config:{limits:{timeout_seconds:120}}} as Run;
 const compact=renderToStaticMarkup(<WorkflowTimeline run={run} compact/>);
 assert.match(compact,/aria-current="step"/);assert.match(compact,/Preparing/);assert.doesNotMatch(compact,/<time/);
 assert.match(renderToStaticMarkup(<WorkflowTimeline run={run}/>),/dateTime="2026-09-07T01:00:01Z"/);
 assert.match(renderToStaticMarkup(<WorkflowTimeline run={{...run,state:"failed"}}/>),/Stopped · Failed/);
 assert.doesNotMatch(renderToStaticMarkup(<WorkflowTimeline run={{...run,state:"failed"}}/>),/aria-current/);
 assert.equal(stateLabel({...run,state:"admitted"}),"Assigned");
});
test("assignment mutations reject foreign origins and oversized requests before forwarding",async()=>{
 const old=process.env.INCUBATOR_REQUESTS_URL;process.env.INCUBATOR_REQUESTS_URL="http://internal:8086";
 const original=globalThis.fetch;let sent=0;
 globalThis.fetch=async()=>{sent++;return Response.json({});};
 try{
  assert.equal((await requestProxy(new Request("http://localhost/api",{method:"POST",headers:{host:"localhost",origin:"https://foreign.example"},body:"{}"}),"/assignments","POST")).status,403);
  assert.equal((await requestProxy(new Request("http://localhost/api",{method:"POST",headers:{host:"localhost",origin:"http://localhost"},body:"x".repeat(10001)}),"/assignments","POST")).status,413);
  assert.equal(sent,0);
  assert.equal((await requestProxy(new Request("http://localhost/api",{method:"POST",headers:{host:"localhost",origin:"http://localhost"},body:"{}"}),"/assignments","POST")).status,200);
  assert.equal(sent,1);
 }finally{globalThis.fetch=original;if(old===undefined)delete process.env.INCUBATOR_REQUESTS_URL;else process.env.INCUBATOR_REQUESTS_URL=old;}
});
