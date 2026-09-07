import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {QueryClient,QueryClientProvider} from "@tanstack/react-query";
import {CampaignBacklog,campaignCandidates,candidateProgress,ResearchCampaign,CampaignDialog} from "../app/incubator/ResearchCampaign";
import {modelRoutingQuery} from "../lib/api-queries";
Object.assign(globalThis,{React});
test("fresh empty backlog renders the independent Ticket Creator picker",()=>{
 const client=new QueryClient({defaultOptions:{queries:{retry:false,staleTime:Infinity}}});
 const campaign={enabled:false,revision:0,daily_limit:2,open_limit:3,next_at:"2026-09-07T00:00:00Z",note:"Paused",open_count:0,attempts_today:0,symbols:[],agenda:[],target:10,created_count:0,completed_count:0,creator_model:"",backlog_limit:10,backlog_count:0,creator_status:null,creator_usage:{last_24h:{calls:1,input_tokens:100,output_tokens:40,reasoning_tokens:10,unknown_token_calls:0,known_cost_usd:0.125,unknown_cost_calls:0},lifetime:{calls:2,input_tokens:100,output_tokens:40,reasoning_tokens:10,unknown_token_calls:1,known_cost_usd:0.125,unknown_cost_calls:1}},creator_calls:[{id:1,model:"vendor/paid",state:"failed",reason:"invalid_ticket_proposal",cost_usd:0.125,usage:{prompt_tokens:100,completion_tokens:40}},{id:2,model:"vendor/paid",state:"indeterminate",cost_usd:null,usage:null}]};
 client.setQueryData(["research-campaign"],campaign);
 client.setQueryData(modelRoutingQuery.queryKey,{revision:0,legacy_revisions:[0,0],models:[{model_id:"creator:free",routes:[{provider:"openrouter",model_id:"vendor/creator:free"}]},{model_id:"creator-paid",routes:[{provider:"openrouter",model_id:"vendor/creator-paid"}]}]});
 const html=renderToStaticMarkup(<QueryClientProvider client={client}><ResearchCampaign/></QueryClientProvider>);
 assert.match(html,/Ticket Creator model/);assert.match(html,/vendor\/creator:free/);assert.match(html,/vendor\/creator-paid/);assert.match(html,/Enable campaign/);
 assert.match(html,/Detailed validation evidence was not recorded/); assert.match(html,/Cost pending/); assert.match(html,/0.125000/); assert.match(html,/Includes failed calls/); assert.match(html,/>100<\/option>/);
 const backlog={...campaign,creator_model:"vendor/creator:free",backlog_count:1,agenda:[{ordinal:1,generation_id:3,title:"A fresh momentum question",premise:"Test whether short-horizon continuation survives costs.",spec:{runner:"momentum_v1",lookback_sessions:3,quantile_count:5,one_way_cost_bps:8,borrow_bps_per_session:4},state:"pending",reason:null,run_key:null,scope:null}]};
 const backlogHtml=renderToStaticMarkup(<CampaignBacklog campaign={backlog}/>);
 assert.match(backlogHtml,/Campaign backlog/); assert.match(backlogHtml,/A fresh momentum question/); assert.match(backlogHtml,/short-horizon continuation/); assert.match(backlogHtml,/Backlog workflow/);
 assert.match(backlogHtml,/Open campaign ticket A fresh momentum question, Created/); assert.match(backlogHtml,/aria-haspopup="dialog"/);
 const outcomes={...backlog,agenda:["pending","checking","blocked","cancelled","duplicate"].map((state,index)=>({...backlog.agenda[0],ordinal:index+1,state,reason:state==="pending"?null:`Reason for ${state}`}))};
 assert.deepEqual(campaignCandidates(outcomes,"current").map(c=>c.state),["pending","checking","blocked","cancelled"]);
 assert.deepEqual(campaignCandidates(outcomes,"duplicates").map(c=>c.state),["duplicate"]);
 assert.equal(campaignCandidates(outcomes,"archived").length,0);
 assert.deepEqual(campaignCandidates(outcomes,"current","","Failed").map(c=>c.state),["blocked"]);
 assert.deepEqual(campaignCandidates(outcomes,"current","","Cancelled").map(c=>c.state),["cancelled"]);
 assert.equal(campaignCandidates(outcomes,"duplicates","no match").length,0);
 const duplicates=renderToStaticMarkup(<CampaignBacklog campaign={outcomes} view="duplicates"/>);
 assert.match(duplicates,/Reason for duplicate/); assert.doesNotMatch(duplicates,/Reason for blocked/);
 const failed=renderToStaticMarkup(<CampaignBacklog campaign={outcomes} status="Failed"/>);
 assert.match(failed,/Reason for blocked/); assert.doesNotMatch(failed,/Reason for duplicate/);
 client.setQueryData(["research-campaign"],{...campaign,enabled:true,creator_in_progress:true,creator_model:"vendor/creator-paid",creator_status:"dispatching"});
 const active=renderToStaticMarkup(<QueryClientProvider client={client}><ResearchCampaign/></QueryClientProvider>);
 assert.match(active,/Stop generation/); assert.match(active,/request already accepted by the provider may still incur a charge/);
 client.setQueryData(["research-campaign"],{...campaign,creator_in_progress:true,creator_model:"vendor/creator-paid",creator_status:"dispatching"});
 const stopping=renderToStaticMarkup(<QueryClientProvider client={client}><ResearchCampaign/></QueryClientProvider>);
 assert.match(stopping,/Stopping generation…/); assert.match(stopping,/disabled/);
 client.clear();
});
test("campaign controls stay inside the dialog until opened",()=>{
 const client=new QueryClient({defaultOptions:{queries:{retry:false,staleTime:Infinity}}});
 const html=renderToStaticMarkup(<QueryClientProvider client={client}><CampaignDialog/></QueryClientProvider>);
 assert.match(html,/Campaign/); assert.doesNotMatch(html,/Ticket Creator model/);
 client.setQueryData(["research-campaign"],{enabled:true});
 const active=renderToStaticMarkup(<QueryClientProvider client={client}><CampaignDialog/></QueryClientProvider>);
 assert.match(active,/Campaign generating/); assert.match(active,/animate-spin/);
});

test("backlog timelines stop at the check and never imply research has started",()=>{
 for(const [state,expected] of [["pending","pending"],["checking","active"],["blocked","failed"],["duplicate","paused"],["cancelled","paused"]]){
  const steps=candidateProgress(state);
  assert.equal(steps[1].state,expected);
  assert.deepEqual(steps.slice(2).map(s=>s.state),["pending","pending"]);
 }
});
