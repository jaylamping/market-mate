import test from "node:test";
import assert from "node:assert/strict";
import { parseModels, parsePolicy, parseStatus, isFree, tokenPrice } from "../lib/openrouter";

const connected = {provider:"openrouter",state:"connected",model_policy:"whitelist",inference_enabled:false,checked_at_ms:1,is_free_tier:false,key_usage_credits:0};
test("key limits distinguish missing metadata, unlimited caps and zero remaining", () => {
  assert.equal(parseStatus(connected).key_limits, undefined);
  const key_limits={limit:null,limit_remaining:0,limit_reset:null,usage_daily:0,usage_weekly:1,usage_monthly:2,byok_usage:3,byok_usage_daily:0,byok_usage_weekly:1,byok_usage_monthly:2,include_byok_in_limit:false};
  assert.deepEqual(parseStatus({...connected,key_limits}).key_limits,key_limits);
  assert.deepEqual(parseStatus({...connected,key_limits:{label:"private",rate_limit:{requests:999}}}).key_limits,{});
  for (const key_limits of [{limit:-1},{limit_remaining:"0"},{usage_daily:null},{usage_weekly:Infinity},{byok_usage:-1},{limit_reset:{}},{include_byok_in_limit:0}]) {
    assert.throws(()=>parseStatus({...connected,key_limits}));
  }
  assert.equal(parseStatus({...connected,state:"connection_failed",key_limits}).key_limits,undefined);
});

test("tiered model pricing survives parsing without being labeled free", () => {
  const pricing = {prompt:"0",completion:"0",overrides:[{min_prompt_tokens:272000,prompt:"0.0000004"}]};
  const [model] = parseModels({models:[{id:"openai/gpt-5.6-luna",name:"GPT-5.6 Luna",context_length:1050000,pricing}]});
  assert.deepEqual(model.pricing, pricing);
  assert.equal(isFree(model),false);
});

test("model pricing distinguishes free, token costs and extra charges", () => {
  const [free,paid,extra] = parseModels({models:[
    {id:"a/free:free",name:"Free",context_length:1000,pricing:{prompt:"0",completion:"0"}},
    {id:"a/paid",name:"Paid",context_length:1000,pricing:{prompt:"0.000001",completion:"0.000002"}},
    {id:"a/extra",name:"Extra",context_length:1000,pricing:{prompt:"0",completion:"0",request:"0.01"}},
  ]});
  assert.ok(isFree(free));assert.equal(isFree(paid),false);assert.equal(isFree(extra),false);
  assert.equal(tokenPrice(paid.pricing.prompt),"$1.00");
  assert.throws(()=>parseModels({models:[{...paid,pricing:{prompt:"NaN",completion:"0"}}]}));
});
test("whitelist and connection metadata fail closed", () => {
  assert.deepEqual(parsePolicy({revision:0,allowed_models:[]}),{revision:0,allowed_models:[]});
  assert.throws(()=>parsePolicy({revision:-1,allowed_models:[]}));
  assert.throws(()=>parsePolicy({revision:0,allowed_models:[null]}));
  assert.throws(()=>parseStatus({provider:"openrouter",state:"connected",model_policy:"whitelist",inference_enabled:true}));
});

import { PUT } from "../app/api/openrouter/[resource]/route";
test("model whitelist proxy rejects cross-origin and missing-origin writes", async () => {
  for (const origin of [undefined,"https://other.example","http://evil.example:3000"]) {
    const headers: Record<string,string> = {host:"localhost:3000","Content-Type":"application/json"};
    if (origin) headers.origin=origin;
    const response=await PUT(new Request("http://localhost:3000/api/openrouter/policy",{method:"PUT",headers,body:"{}"}),{params:Promise.resolve({resource:"policy"})});
    assert.equal(response.status,403);
  }
});

test("account balance distinguishes unavailable, zero and negative balances", async () => {
  const {parseBalance}=await import("../lib/openrouter");
  assert.deepEqual(parseBalance({state:"available",balance_usd:0,checked_at_ms:1}),{state:"available",balance_usd:0,checked_at_ms:1});
  assert.deepEqual(parseBalance({state:"available",balance_usd:-1,checked_at_ms:1}),{state:"available",balance_usd:-1,checked_at_ms:1});
  assert.deepEqual(parseBalance({state:"management_key_required"}),{state:"management_key_required"});
  assert.throws(()=>parseBalance({state:"available",balance_usd:null,checked_at_ms:1}));
});
