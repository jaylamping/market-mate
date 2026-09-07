import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {QueryClient,QueryClientProvider} from "@tanstack/react-query";
import {ResearchCampaign} from "../app/incubator/ResearchCampaign";
import {modelRoutingQuery} from "../lib/api-queries";
Object.assign(globalThis,{React});
test("fresh empty backlog renders the independent Ticket Creator picker",()=>{
 const client=new QueryClient({defaultOptions:{queries:{retry:false,staleTime:Infinity}}});
 client.setQueryData(["research-campaign"],{enabled:false,revision:0,daily_limit:2,open_limit:3,next_at:"2026-09-07T00:00:00Z",note:"Paused",open_count:0,attempts_today:0,symbols:[],agenda:[],target:10,created_count:0,completed_count:0,creator_model:"",backlog_limit:10,backlog_count:0,creator_status:null});
 client.setQueryData(modelRoutingQuery.queryKey,{revision:0,legacy_revisions:[0,0],models:[{model_id:"creator:free",routes:[{provider:"openrouter",model_id:"vendor/creator:free"}]},{model_id:"creator-paid",routes:[{provider:"openrouter",model_id:"vendor/creator-paid"}]}]});
 const html=renderToStaticMarkup(<QueryClientProvider client={client}><ResearchCampaign/></QueryClientProvider>);
 assert.match(html,/Ticket Creator model/);assert.match(html,/vendor\/creator:free/);assert.match(html,/vendor\/creator-paid/);assert.match(html,/Enable pilot campaign/);
 client.clear();
});
