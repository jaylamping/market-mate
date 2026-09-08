import test from "node:test";
import assert from "node:assert/strict";
import {formatReset,moveRoute,nextOrdinal,parseAgents,parseProviderModels,routesByTier,windowLabel} from "../lib/agents";
const route=(tier:"free"|"paid"|"subscription",ordinal:number)=>({tier,ordinal,provider_id:"p",model_id:"m",share_pct:100});
test("driver parsers reject malformed envelopes",()=>{assert.throws(()=>parseAgents({agents:[null]}));assert.throws(()=>parseProviderModels({models:[{id:"m"}]}));});
test("routes move, group, and assign ordinals",()=>{const routes=[route("free",0),route("paid",0),route("free",1)];assert.equal(moveRoute(routes,0,1)[1].ordinal,1);assert.equal(routesByTier(routes).free.length,2);assert.equal(nextOrdinal(routes,"free"),2);});
test("window labels and countdown stay compact",()=>{assert.equal(windowLabel("rolling_5h"),"5h");assert.equal(formatReset("2026-09-07T17:10:00Z",Date.parse("2026-09-07T15:00:00Z")),"resets in 2h 10m");});
