export type Provider = "openrouter" | "cursor";
export type ModelRoute = {provider:Provider;model_id:string};
export type ModelPreference = {model_id:string;routes:ModelRoute[]};
export type RoutingPolicy = {revision:number;legacy_revisions:[number,number];models:ModelPreference[];default_model?:string|null};
export function canonicalModel(_provider:Provider,id:string):string {
  return id.split("/").at(-1)??id;
}
export function parseRouting(value:unknown):RoutingPolicy {
  if (!value || typeof value!=="object") throw new Error("Invalid model preferences");
  const p=value as RoutingPolicy;
  if (!Number.isSafeInteger(p.revision)||p.revision<0||!Array.isArray(p.legacy_revisions)||p.legacy_revisions.length!==2||p.legacy_revisions.some(n=>!Number.isSafeInteger(n)||n<0)||!Array.isArray(p.models)||p.models.length>200) throw new Error("Invalid model preferences");
  const groups=new Set<string>();const counts={openrouter:0,cursor:0};
  for(const m of p.models) {
    if(!m||typeof m.model_id!=="string"||groups.has(m.model_id)||!Array.isArray(m.routes)||m.routes.length<1||m.routes.length>2) throw new Error("Invalid model preferences");
    groups.add(m.model_id);const providers=new Set<string>();
    for(const r of m.routes) {
      if(!r||!["openrouter","cursor"].includes(r.provider)||typeof r.model_id!=="string"||canonicalModel(r.provider,r.model_id)!==m.model_id||providers.has(r.provider)) throw new Error("Invalid provider route");
      providers.add(r.provider);if(++counts[r.provider]>100) throw new Error("Too many approved models");
    }
  }
  if(p.default_model!=null&&(typeof p.default_model!=="string"||!groups.has(p.default_model)))throw new Error("Default model must be selected");
  return {...p,default_model:p.default_model??null};
}
export function setRoutes(policy:RoutingPolicy,model_id:string,routes:ModelRoute[]):RoutingPolicy {
  return {...policy,default_model:policy.default_model===model_id&&!routes.length?null:policy.default_model,models:[...policy.models.filter(m=>m.model_id!==model_id),...(routes.length?[{model_id,routes}]:[])].sort((a,b)=>a.model_id.localeCompare(b.model_id))};
}
export function moveRoute(routes:ModelRoute[],index:number,direction:-1|1):ModelRoute[] {
  const next=[...routes],target=index+direction;
  if(index<0||index>=routes.length||target<0||target>=routes.length)return next;
  [next[index],next[target]]=[next[target],next[index]];return next;
}
export function groupModels<T extends {provider:Provider;id:string}>(rows:T[]):{id:string;offers:T[]}[] {
  const groups=new Map<string,T[]>();
  for(const row of rows) {
    const id=canonicalModel(row.provider,row.id);
    groups.set(id,[...(groups.get(id)??[]),row]);
  }
  return [...groups].map(([id,offers])=>({id,offers}));
}
export function referenceMetadata<T>(primary:{pricing?:T;context?:number},openrouter:{pricing?:T;context?:number}) {
  return {pricing:primary.pricing??openrouter.pricing,context:primary.context??openrouter.context};
}
