import test from "node:test";
import assert from "node:assert/strict";
import { costLabel,parseRuns,stateLabel,type Run } from "../app/incubator/model";
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
