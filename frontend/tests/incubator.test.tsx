import test from "node:test";
import assert from "node:assert/strict";
import { costLabel,parseRuns,providerErrorLabel,researchTickets,spendingLimitLabel,stateLabel,type Run } from "../app/incubator/model";
import { sortModels,catalogDate } from "../app/agents/model-sort";
test("missing usage is not zero and incomplete history fails",()=>{
 assert.equal(costLabel(null),"Unavailable"); assert.equal(costLabel(0),"$0.00");
 assert.throws(()=>parseRuns({environment:"paper",artifact_kind:"research_planning",runs:[]}));
 assert.deepEqual(parseRuns({environment:"local_research",artifact_kind:"research_planning",runs:[]}),[]);
 assert.equal(stateLabel({state:"dispatched",updated_at:"2020-01-01T00:00:00Z",config:{limits:{timeout_seconds:120}}} as Run),"Outcome unknown");
});
test("saved selections sort first across providers; numeric dates and prices sort with missing values last",()=>{
 const rows=[{provider:"openrouter" as const,id:"a",name:"Alpha",created:20,pricing:{prompt:"0.2",completion:"0.3"}},
 {provider:"cursor" as const,id:"b",name:"Bravo"},{provider:"openrouter" as const,id:"z",name:"Zulu",created:10,pricing:{prompt:"0.01",completion:"0.02"}}];
 const saved={openrouter:["z"],cursor:["b"]};
 assert.deepEqual(sortModels(rows,{key:"selected",direction:"desc"},saved).map(r=>r.id),["b","z","a"]);
 assert.deepEqual(sortModels(rows,{key:"input",direction:"asc"},saved).map(r=>r.id),["z","a","b"]);
 assert.deepEqual(sortModels(rows,{key:"date",direction:"desc"},saved).map(r=>r.id),["a","z","b"]);
 assert.equal(catalogDate(undefined),"—");
});

test("mixed free and owner-selected paid history remains readable without inventing a zero cap",()=>{
 const base={run_key:"free",assignment_id:"assignment",created_at:"2026-09-07T07:00:00Z",updated_at:"2026-09-07T07:00:00Z",state:"failed",
  config:{agent_name:"Research Scout",provider:"openrouter",model:"vendor/free:free",input:{classification:"project_authored_research_brief",title:"Research",text:"Question"},limits:{max_requests:1,max_output_tokens:2048,timeout_seconds:120,max_cost_usd:0}},
  detail:{},events:[{sequence:1,state:"failed",at:"2026-09-07T07:00:00Z",detail:{}}]};
 const paid={...base,run_key:"paid",config:{...base.config,model:"vendor/paid",manual_model_spend:true,limits:{max_requests:1,max_output_tokens:2048,timeout_seconds:120,spend_policy:"owner_selected_model"}},detail:{usage:{cost_usd:0.02}}};
 const history=(runs:unknown[])=>({environment:"local_research",artifact_kind:"research_planning",runs});
 const runs=parseRuns(history([base,paid]));
 assert.equal(runs.length,2);
 assert.equal(spendingLimitLabel(runs[0].config.limits),"$0 spending limit");
 assert.equal(runs[1].config.limits.max_cost_usd,null);
 assert.match(spendingLimitLabel(runs[1].config.limits),/Owner-selected model pricing.*No dollar cap/);
 assert.equal(runs[1].detail.usage.cost_usd,0.02);
 assert.equal(parseRuns(history([paid]))[0].run_key,"paid");
 for(const config of [
  {...paid.config,manual_model_spend:false},
  {...paid.config,limits:{...paid.config.limits,spend_policy:"unknown"}},
  {...base.config,limits:{...base.config.limits,max_cost_usd:undefined}},
  {...paid.config,limits:{...paid.config.limits,max_cost_usd:-1}},
 ])assert.throws(()=>parseRuns(history([{...paid,config}])));
});

test("fallback attempts stay with their ticket and do not restore archived parents",()=>{
 const run=(key:string,archived=false,parent:string|null=null)=>({run_key:key,archived,config:{input:{title:"Same question"}},detail:{fallback_of:parent}} as Run);
 const old=run("old",true),oldFallback=run("old-fallback",false,"old"),fresh=run("fresh"),fallback=run("new-fallback",false,"fresh");
 const all=[fallback,fresh,oldFallback,old];
 assert.deepEqual(researchTickets(all).filter(r=>!r.archived).map(r=>r.run_key),["fresh"]);
 assert.deepEqual(researchTickets(all).filter(r=>r.archived).map(r=>r.run_key),["old"]);
 assert.equal(old.archived,true);assert.equal(oldFallback.archived,false);
 assert.deepEqual(researchTickets([fallback]).map(r=>r.run_key),["new-fallback"]);
 assert.match(providerErrorLabel(429),/rate-limited.*HTTP 429/);
 assert.match(providerErrorLabel(402),/credits/);
});
