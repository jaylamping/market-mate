import test from "node:test";
import assert from "node:assert/strict";
import {GET,POST} from "../app/api/market-data/[[...path]]/route";
import {acquisitionLabels,canRetryAcquisition,dataError} from "../lib/market-data";
test("market data proxy rejects foreign origins, oversized secrets and arbitrary paths",async()=>{
 const old=process.env.MARKET_DATA_URL,original=globalThis.fetch;process.env.MARKET_DATA_URL="http://connector:8087";let sent=0;
 globalThis.fetch=async(input,init)=>{sent++;assert.equal(String(input),"http://connector:8087/setup");assert.equal(init?.cache,"no-store");return Response.json({saved:true});};
 const context=(path:string[])=>({params:Promise.resolve({path})});
 const request=(origin="http://localhost",body="{}")=>new Request("http://localhost/api/market-data/setup",{method:"POST",headers:{host:"localhost",origin},body});
 try{
  assert.equal((await POST(request("https://foreign.example"),context(["setup"]))).status,403);
  assert.equal((await POST(request("http://localhost","x".repeat(8193)),context(["setup"]))).status,413);
  assert.equal((await POST(request(),context(["credentials"]))).status,404);
  assert.equal((await GET(new Request("http://localhost/api"),context(["setup"]))).status,404);
  assert.equal(sent,0);
  const response=await POST(request(),context(["setup"]));assert.equal(response.status,200);assert.equal(response.headers.get("cache-control"),"no-store");assert.deepEqual(await response.json(),{saved:true});assert.equal(sent,1);
 }finally{globalThis.fetch=original;if(old===undefined)delete process.env.MARKET_DATA_URL;else process.env.MARKET_DATA_URL=old;}
});
test("failed collection and incomplete coverage never imply usable experiment data",()=>{
 assert.equal(acquisitionLabels.failed,"Download needs attention");
 assert.match(dataError("IncompleteCoverage"),/No dataset was attached/);
 assert.match(dataError("refresh_failed"),/Saved experiment inputs are unchanged/);
 assert.match(dataError("commit_rejected"),/Retry uses the same request/);
 const request={symbols:["AAPL"],sessions:["2026-01-05"],benchmark:"SPY",cash:"zero_interest",symbol_asof:"2026-01-05"};
 assert.equal(canRetryAcquisition({state:"failed",attempts:2,error_code:"IncompleteCoverage",request}),true);
 assert.equal(canRetryAcquisition({state:"failed",attempts:3,error_code:"IncompleteCoverage",request}),false);
 assert.equal(canRetryAcquisition({state:"failed",attempts:3,error_code:"commit_rejected",request}),true);
 assert.equal(canRetryAcquisition({state:"failed",attempts:3,error_code:"commit_rejected",request:null}),false);
});

test("reuse forwards only the acknowledgement and keeps foreign requests out",async()=>{
 const old=process.env.MARKET_DATA_URL,original=globalThis.fetch;process.env.MARKET_DATA_URL="http://connector:8087";let sent=0;
 globalThis.fetch=async(input,init)=>{sent++;assert.equal(String(input),"http://connector:8087/reuse");assert.deepEqual(JSON.parse(String(init?.body)),{rights_confirmed:true});return Response.json({connected:true});};
 const context={params:Promise.resolve({path:["reuse"]})};
 try{
  const request=(origin:string)=>new Request("http://localhost/api/market-data/reuse",{method:"POST",headers:{host:"localhost",origin},body:JSON.stringify({rights_confirmed:true})});
  assert.equal((await POST(request("https://foreign.example"),context)).status,403);assert.equal(sent,0);
  assert.equal((await POST(request("http://localhost"),context)).status,200);assert.equal(sent,1);
 }finally{globalThis.fetch=original;if(old===undefined)delete process.env.MARKET_DATA_URL;else process.env.MARKET_DATA_URL=old;}
});
