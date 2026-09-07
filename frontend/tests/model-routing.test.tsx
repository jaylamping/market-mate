import test from "node:test";
import assert from "node:assert/strict";
import {referenceMetadata,canonicalModel,groupModels,moveRoute,parseRouting,setRoutes,type RoutingPolicy} from "../lib/model-routing";
const routes=[{provider:"openrouter" as const,model_id:"openai/gpt-5.6-luna"},{provider:"cursor" as const,model_id:"gpt-5.6-luna"}];
test("slug grouping ignores provider prefixes but preserves variants and full dispatch IDs",()=>{
 const rows=[...routes.map(r=>({provider:r.provider,id:r.model_id})),{provider:"openrouter" as const,id:"openai/gpt-5.6-luna-pro"},{provider:"openrouter" as const,id:"openai/gpt-5.6-luna:batch"}];
 const groups=groupModels(rows);assert.equal(groups.length,3);assert.equal(groups[0].offers.length,2);assert.equal(groups[0].offers[0].id,"openai/gpt-5.6-luna");assert.equal(canonicalModel("cursor","gpt-5.6-luna"),groups[0].id);
});
test("provider priority persists through parse and reorder without changing approvals",()=>{
 const initial:RoutingPolicy={revision:4,legacy_revisions:[3,0],models:[]};
 const selected=setRoutes(initial,"gpt-5.6-luna",routes);
 const ordered=setRoutes(selected,"gpt-5.6-luna",moveRoute(routes,1,-1));
 assert.equal(parseRouting(JSON.parse(JSON.stringify(ordered))).models[0].routes[0].provider,"cursor");
 assert.equal(selected.models[0].routes[0].provider,"openrouter");
 assert.deepEqual(moveRoute(routes,0,-1),routes);
 assert.equal(setRoutes(ordered,"gpt-5.6-luna",[]).models.length,0);
 assert.throws(()=>parseRouting({...ordered,models:[{model_id:"different",routes}]}));
 assert.throws(()=>parseRouting({...ordered,models:[{model_id:"gpt-5.6-luna",routes:[routes[0],routes[0]]}]}));
});

test("missing Cursor fields use OpenRouter reference values without replacing supplied values",()=>{
 const reference={pricing:{prompt:"0.2",completion:"1.2"},context:1050000};
 assert.deepEqual(referenceMetadata({},reference),reference);
 assert.deepEqual(referenceMetadata({context:128000},reference),{...reference,context:128000});
 assert.equal(referenceMetadata({pricing:{prompt:"0",completion:"0"}},reference).pricing?.prompt,"0");
});

test("default fallback must be approved and clears when its last provider is removed",()=>{
 const policy:RoutingPolicy={revision:1,legacy_revisions:[0,0],default_model:"gpt-5.6-luna",models:[{model_id:"gpt-5.6-luna",routes}]};
 assert.equal(parseRouting(policy).default_model,"gpt-5.6-luna");
 assert.equal(setRoutes(policy,"gpt-5.6-luna",[]).default_model,null);
 assert.equal(setRoutes(policy,"gpt-5.6-luna",[routes[0]]).default_model,"gpt-5.6-luna");
 assert.throws(()=>parseRouting({...policy,default_model:"unapproved"}));
 assert.equal(parseRouting({revision:0,legacy_revisions:[0,0],models:[]}).default_model,null);
});

test("role runners persist independently and clear when their final route is removed",()=>{
 const model={model_id:"advanced:free",routes:[{provider:"openrouter" as const,model_id:"vendor/advanced:free"}]};
 const p=parseRouting({revision:1,legacy_revisions:[0,0],models:[model],default_model:null,research_model:model.model_id,setup_model:model.model_id,experiment_model:model.model_id});
 const cleared=setRoutes(p,model.model_id,[]);assert.equal(cleared.research_model,null);assert.equal(cleared.setup_model,null);assert.equal(cleared.experiment_model,null);
 assert.throws(()=>parseRouting({...p,setup_model:"not-selected"}));assert.throws(()=>parseRouting({...p,research_model:"not-selected"}));assert.throws(()=>parseRouting({...p,experiment_model:"not-selected"}));
});
