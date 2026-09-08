import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {QueryClient,QueryClientProvider} from "@tanstack/react-query";
import {CapacitySummary,OpenRouterCapacity,PaidRoleFallback} from "../components/OpenRouterCapacity";
import {capacityProxy,capacityQuery,parseCapacity,canSaveCapacity,dollarsToNanos,updateCapacity,type Capacity} from "../lib/openrouter-capacity";
import {modelRoutingQuery,openrouterModelsQuery} from "../lib/api-queries";
import {parseRuns} from "../app/incubator/model";
import {RunDetails} from "../app/incubator/IncubatorPage";

const capacity: Capacity = {policy:{revision:2,paused:false,mode:"paced",daily_target:980,start_interval_ms:3200,burst_remaining:0,prefer_free_models:true,paid_enabled:false,paid_model:null,paid_models:[],paid_outage_enabled:false,paid_model_open_weights_confirmed:false,paid_finish_on_429:false,paid_max_fallback_attempts:1,paid_role_models:{research:null,setup:null,experiment:null,default:null},paid_request_limit_nanos:2000000,paid_daily_limit_nanos:100000000,paid_monthly_limit_nanos:2000000000,paid_attempt_limit:100},free_used:742,free_remaining:258,minute_used:18,in_flight:3,queued:5,next_eligible_at:null,cooldown_until:null,free_cooldown_until:null,paid_used_nanos:1000000,paid_reserved_nanos:2000000,paid_attempts:1,window_mode:"rolling_24h",history_status:"complete"};

test("dollar inputs preserve nanodollar units and reject fractional or unsafe nanodollars",()=>{
  assert.equal(dollarsToNanos("0.002"),2000000);
  assert.equal(dollarsToNanos("0.10"),100000000);
  assert.equal(dollarsToNanos("2"),2000000000);
  assert.equal(dollarsToNanos("0.000000001"),1);
  for(const value of ["-1","NaN","Infinity","1e2","0.0000000001","9007199254740991",""])assert.equal(dollarsToNanos(value),null);
});
test("paid saving requires an approved model, explicit published weights check, and positive caps",()=>{
  const policy={...capacity.policy,paid_enabled:true};
  assert.equal(canSaveCapacity(policy,["approved"]),false);
  assert.equal(canSaveCapacity({...policy,paid_model:"approved"},["approved"]),false);
  const valid={...policy,paid_model:"approved",paid_models:["approved"],paid_model_open_weights_confirmed:true};
  assert.equal(canSaveCapacity(valid,["approved"]),true);
  assert.equal(canSaveCapacity(valid,[]),false);
  assert.equal(canSaveCapacity({...valid,paid_daily_limit_nanos:0},["approved"]),false);
  assert.equal(canSaveCapacity({...valid,start_interval_ms:3000},["approved"]),false);
  assert.equal(canSaveCapacity({...valid,daily_target:1001},["approved"]),false);
  assert.equal(canSaveCapacity({...valid,paid_models:[]},["approved"]),false);
  assert.equal(canSaveCapacity({...valid,paid_model:"outside"},["approved","outside"]),false);
  assert.equal(canSaveCapacity({...valid,paid_models:["approved","second"]},["approved"]),false);
  assert.equal(canSaveCapacity({...valid,paid_models:["approved","second"]},["approved","second"]),true);
  assert.equal(canSaveCapacity({...valid,paid_enabled:false,paid_model_open_weights_confirmed:false},["approved"]),true);
  assert.equal(canSaveCapacity({...valid,paid_role_models:{...valid.paid_role_models,research:"outside"}},["approved","outside"]),false);
  assert.equal(canSaveCapacity({...valid,paid_role_models:{...valid.paid_role_models,research:"approved"},paid_max_fallback_attempts:2},["approved"]),true);
  assert.equal(canSaveCapacity({...valid,paid_max_fallback_attempts:3},["approved"]),false);
  assert.equal(canSaveCapacity({...valid,prefer_free_models:false,paid_model_open_weights_confirmed:false},["approved"]),true);
  assert.equal(canSaveCapacity({...valid,prefer_free_models:false,paid_request_limit_nanos:0},["approved"]),false);
  assert.equal(canSaveCapacity({...capacity.policy,prefer_free_models:false},[]),true);
  assert.equal(capacity.policy.prefer_free_models,true);assert.equal(capacity.policy.paid_enabled,false);
  for(const fields of [{start_interval_ms:60001},{paid_request_limit_nanos:1000000001},{paid_daily_limit_nanos:10000000001},{paid_monthly_limit_nanos:100000000001},{paid_attempt_limit:101},{paid_models:Array.from({length:17},(_,i)=>`model/${i}`)}]) {
    assert.equal(canSaveCapacity({...capacity.policy,...fields},[]),false);
    assert.throws(()=>parseCapacity({...capacity,policy:{...capacity.policy,...fields}}));
  }
});
test("capacity parser rejects missing counters and impossible policy bounds",()=>{
  assert.deepEqual(parseCapacity(capacity),capacity);
  assert.throws(()=>parseCapacity({...capacity,free_remaining:undefined}));
  assert.throws(()=>parseCapacity({...capacity,policy:{...capacity.policy,daily_target:1001}}));
  assert.throws(()=>parseCapacity({...capacity,cooldown_until:"tomorrow"}));
  assert.throws(()=>parseCapacity({...capacity,free_cooldown_until:undefined}));
  assert.throws(()=>parseCapacity({...capacity,free_cooldown_until:"tomorrow"}));
  for(const paid_models of [undefined,["duplicate","duplicate"],["model:free"],[1]])assert.throws(()=>parseCapacity({...capacity,policy:{...capacity.policy,paid_models}}));
  for(const fields of [{prefer_free_models:undefined},{paid_finish_on_429:undefined},{paid_max_fallback_attempts:0},{paid_max_fallback_attempts:3},{paid_role_models:{}},{paid_role_models:null}])assert.throws(()=>parseCapacity({...capacity,policy:{...capacity.policy,...fields}}));
});
test("counts identify local accounting and paid selector cannot save an enabled empty choice",()=>{
  const markup=renderToStaticMarkup(<CapacitySummary capacity={capacity}/>);
  assert.match(markup,/742 \/ 1,000/);assert.match(markup,/Local accounting/);assert.match(markup,/separate from credits/);
  const client=new QueryClient({defaultOptions:{queries:{retry:false}}});
  client.setQueryData(capacityQuery.queryKey,{...capacity,policy:{...capacity.policy,paid_enabled:true}});
  client.setQueryData(modelRoutingQuery.queryKey,{revision:1,legacy_revisions:[0,0],models:[]});
  client.setQueryData(openrouterModelsQuery.queryKey,[]);
  const html=renderToStaticMarkup(<QueryClientProvider client={client}><OpenRouterCapacity/></QueryClientProvider>);
  assert.match(html,/<button[^>]*disabled=""[^>]*>Save capacity settings<\/button>/);
  assert.match(html,/Automated paid models/);assert.match(html,/Manually selected paid models run as chosen/);
  assert.match(html,/Finish active work on paid after a definite 429/);assert.match(html,/With Prefer free models on, other queued work remains on free/);
  assert.match(html,/<input type="checkbox" checked=""\/>Prefer free models/);
  assert.match(html,/This preference does not authorize spending/);
  client.clear();
});
test("free-model cooldown is visible separately from account cooldown",()=>{
  const future=new Date(Date.now()+60_000).toISOString();
  const html=renderToStaticMarkup(<CapacitySummary capacity={{...capacity,free_cooldown_until:future}}/>);
  assert.match(html,/Free models cooling down until/);assert.doesNotMatch(html,/Account cooling down until/);
  assert.match(renderToStaticMarkup(<CapacitySummary capacity={{...capacity,cooldown_until:future,free_cooldown_until:future}}/>),/Account cooling down until/);
});
test("role inherited paid option follows default-role precedence before shared model",()=>{
  const client=new QueryClient({defaultOptions:{queries:{retry:false}}});
  client.setQueryData(capacityQuery.queryKey,{...capacity,policy:{...capacity.policy,paid_model:"vendor/shared",paid_models:["vendor/shared","vendor/default"],paid_role_models:{...capacity.policy.paid_role_models,default:"vendor/default"}}});
  client.setQueryData(modelRoutingQuery.queryKey,{revision:1,legacy_revisions:[0,0],models:[]});
  client.setQueryData(openrouterModelsQuery.queryKey,[]);
  const render=(role:"research"|"default")=>renderToStaticMarkup(<QueryClientProvider client={client}><PaidRoleFallback role={role}/></QueryClientProvider>);
  assert.match(render("research"),/<option value="" selected="">Use default role paid model \(vendor\/default\)<\/option>/);
  assert.match(render("default"),/<option value="">Use shared paid model \(vendor\/shared\)<\/option>/);
  client.clear();
});
test("run provenance preserves paid recovery attempts and does not promise a zero spending limit",()=>{
  const receipt={attempt_id:"paid-2",model:"vendor/paid",trigger:"finish_after_429",reserved_nanos:2000000,cost_nanos:null};
  const detail={capacity:receipt,capacity_attempts:[{state:"failed",http_status:429,reason:"provider_http_error",capacity:{...receipt,attempt_id:"free-1",model:"vendor/free:free",trigger:"free",reserved_nanos:0,cost_nanos:0}},{state:"indeterminate",http_status:null,reason:"incomplete_response",capacity:receipt}]};
  const raw={run_key:"capacity-run",assignment_id:"assignment",created_by:"agent",created_at:"2026-09-07T07:00:00Z",updated_at:"2026-09-07T07:00:05Z",state:"indeterminate",config:{provider:"openrouter",agent_name:"Research",model:"vendor/free:free",input:{classification:"project_authored_research_brief",title:"Research",text:"Original question"},limits:{max_requests:1,max_output_tokens:2048,timeout_seconds:120,max_cost_usd:0}},detail,events:[{sequence:1,state:"indeterminate",at:"2026-09-07T07:00:05Z",detail}]};
  const history=(run:unknown)=>({environment:"local_research",artifact_kind:"research_planning",runs:[run]});
  const run=parseRuns(history(raw))[0];
  assert.deepEqual(run.detail.capacity,receipt);assert.equal(run.detail.capacity_attempts?.length,2);
  const html=renderToStaticMarkup(<RunDetails run={run}/>);
  assert.match(html,/Automated capacity policy/);assert.match(html,/2 recorded provider attempts/);
  assert.match(html,/finish after 429/);assert.match(html,/vendor\/paid/);assert.match(html,/Actual recorded cost: Unavailable/);
  assert.match(html,/One logical request with bounded provider attempts/);assert.doesNotMatch(html,/\$0 spending limit/);
  assert.throws(()=>parseRuns(history({...raw,detail:{...detail,capacity:{...receipt,cost_nanos:-1}}})));
  assert.throws(()=>parseRuns(history({...raw,detail:{...detail,capacity_attempts:[{state:"failed",capacity:{...receipt,reserved_nanos:0.5}}]}})));
});
test("paid primary mode does not require published weights and does not enable spending by itself",()=>{
  const client=new QueryClient({defaultOptions:{queries:{retry:false}}});
  client.setQueryData(capacityQuery.queryKey,{...capacity,policy:{...capacity.policy,prefer_free_models:false}});
  client.setQueryData(modelRoutingQuery.queryKey,{revision:1,legacy_revisions:[0,0],models:[]});
  client.setQueryData(openrouterModelsQuery.queryKey,[]);
  const html=renderToStaticMarkup(<QueryClientProvider client={client}><OpenRouterCapacity/></QueryClientProvider>);
  assert.doesNotMatch(html,/I checked that every allowed paid fallback model has published weights/);
  assert.match(html,/Automated paid spending is disabled/);
  assert.match(html,/<option value="free" selected="">Paid spending disabled<\/option>/);
  client.clear();
});
test("role fallback selector is restricted to allowed paid models and does not enable spending",()=>{
  const client=new QueryClient({defaultOptions:{queries:{retry:false}}});
  client.setQueryData(capacityQuery.queryKey,{...capacity,policy:{...capacity.policy,paid_models:["vendor/allowed"],paid_model:"vendor/allowed"}});
  client.setQueryData(modelRoutingQuery.queryKey,{revision:1,legacy_revisions:[0,0],models:[{model_id:"allowed",routes:[{provider:"openrouter",model_id:"vendor/allowed"}]},{model_id:"other",routes:[{provider:"openrouter",model_id:"vendor/other"}]}]});
  client.setQueryData(openrouterModelsQuery.queryKey,[{id:"vendor/allowed",name:"Allowed paid",context_length:8192,pricing:{prompt:"0.0000001",completion:"0.0000002"}},{id:"vendor/other",name:"Other paid",context_length:8192,pricing:{prompt:"0.0000001",completion:"0.0000002"}}]);
  const html=renderToStaticMarkup(<QueryClientProvider client={client}><PaidRoleFallback role="research"/></QueryClientProvider>);
  assert.match(html,/Allowed paid/);assert.doesNotMatch(html,/Other paid/);assert.match(html,/Automated paid spending is off/);
  assert.match(html,/Use shared paid model/);assert.match(html,/<button[^>]*disabled=""[^>]*>Save paid model<\/button>/);
  client.clear();
});
test("unavailable refresh hides previously cached capacity numbers",async()=>{
  const client=new QueryClient({defaultOptions:{queries:{retry:false}}});
  client.setQueryData(capacityQuery.queryKey,capacity);
  await assert.rejects(client.fetchQuery({...capacityQuery,staleTime:0,queryFn:async()=>{throw Error("unavailable");}}));
  const html=renderToStaticMarkup(<QueryClientProvider client={client}><OpenRouterCapacity/></QueryClientProvider>);
  assert.match(html,/Request capacity unavailable/);assert.doesNotMatch(html,/742/);assert.doesNotMatch(html,/Save capacity settings/);
  client.clear();
});
test("save preserves revision and units, and exposes conflict instead of overwriting",async()=>{
  const original=globalThis.fetch;let body:unknown;
  globalThis.fetch=async(_input,init)=>{body=JSON.parse(String(init?.body));return Response.json({error:"conflict"},{status:409});};
  try {
    await assert.rejects(updateCapacity(capacity.policy),/Settings changed elsewhere/);
    assert.deepEqual(body,{expected_revision:2,policy:capacity.policy});
  } finally {globalThis.fetch=original;}
});
test("capacity proxy preserves method and conflict; rejects foreign origins and oversized bodies",async()=>{
  const previous=process.env.AGENT_DRIVER_URL,original=globalThis.fetch;
  process.env.AGENT_DRIVER_URL="http://internal:8086";
  const sent:{url:string;method?:string}[]=[];
  globalThis.fetch=async(input,init)=>{sent.push({url:String(input),method:init?.method});return Response.json({error:"revision"},{status:409});};
  const request=(origin="http://localhost",body="{}")=>new Request("http://localhost/api/incubator/capacity",{method:"PUT",headers:{host:"localhost",origin},body});
  try {
    assert.equal((await capacityProxy(request("https://foreign.example"),"PUT")).status,403);
    assert.equal((await capacityProxy(request("http://localhost","x".repeat(10001)),"PUT")).status,413);
    assert.equal(sent.length,0);
    const response=await capacityProxy(request(),"PUT");
    assert.equal(response.status,409);assert.deepEqual(await response.json(),{error:"revision"});
    assert.deepEqual(sent,[{url:"http://internal:8086/capacity",method:"PUT"}]);
    await capacityProxy(request(),"POST");
    assert.equal(sent[1].url,"http://internal:8086/capacity/burst");
    const normalized=(origin:string)=>new Request("http://localhost:3000/api/incubator/capacity",{method:"PUT",headers:{host:"127.0.0.1:3000",origin},body:"{}"});
    assert.equal((await capacityProxy(normalized("http://127.0.0.1:3000"),"PUT")).status,409);
    assert.equal(sent.length,3);
    assert.equal((await capacityProxy(normalized("http://localhost:3000"),"PUT")).status,403);
    assert.equal((await capacityProxy(normalized("https://127.0.0.1:3000"),"PUT")).status,403);
    assert.equal(sent.length,3);
    delete process.env.AGENT_DRIVER_URL;
    assert.equal((await capacityProxy(new Request("http://localhost/api/incubator/capacity"),"GET")).status,503);
  } finally {globalThis.fetch=original;if(previous===undefined)delete process.env.AGENT_DRIVER_URL;else process.env.AGENT_DRIVER_URL=previous;}
});
