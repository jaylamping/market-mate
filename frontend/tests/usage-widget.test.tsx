import test from "node:test";
import assert from "node:assert/strict";
import {parseUsageSummary} from "../lib/agents";
test("usage summary preserves provider windows and counters",()=>{const summary=parseUsageSummary({providers:[{id:"zai",display_name:"Z.ai",kind:"subscription",enabled:true,probe_state:"connected",cooldown_until:null,windows:[{window:"weekly",source:"api",percent_used:42,status:"ok",resets_at:null,observed_at:null,threshold_pct:95,pacing_slack_pct:5,limit_count:null,elapsed_pct:40,over_threshold:false,over_pace:false}]}],holds:2,in_flight:1,observed_at:"2026-09-07T15:00:00Z"});assert.equal(summary.holds,2);assert.equal(summary.providers[0].windows[0].status,"ok");});
test("usage summary rejects malformed provider windows",()=>{assert.throws(()=>parseUsageSummary({providers:[{id:"zai",display_name:"Z.ai",kind:"subscription",enabled:true,windows:[]}],holds:0,in_flight:0,observed_at:"now"}));});
