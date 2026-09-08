import { queryOptions } from "@tanstack/react-query";
import { getJson } from "./api-queries";

export type Tier = "subscription" | "free" | "paid";
export type ProviderKind = "subscription" | "free" | "paid" | "catalog_only";
export type Protocol = "openai_chat" | "openai_responses" | "cursor_agent" | "none";
export type ProviderWindowName = "rolling_5h" | "weekly" | "monthly" | "daily" | "minute";
export type ProviderWindow = {
  window: ProviderWindowName; source: "api" | "local"; percent_used: number;
  status: "ok" | "rate_limited" | "unknown"; resets_at: string | null; observed_at: string | null;
  threshold_pct: number; pacing_slack_pct: number; limit_count: number | null;
  elapsed_pct: number; over_threshold: boolean; over_pace: boolean;
};
export type Provider = {
  id: string; display_name: string; kind: ProviderKind; protocol: Protocol; base_url: string;
  credential_path: string; catalog_source: "live" | "static" | "none"; catalog_url: string | null;
  static_models: unknown[]; usage_url: string | null; status_url: string | null;
  settings: Record<string, unknown>; enabled: boolean; revision: number;
  credential_state: "configured" | "not_configured"; windows: ProviderWindow[];
  state: {cooldown_until: string | null; cooldown_reason: string | null; probe_state: string | null; probe_at: string | null; last_error: string | null};
};
export type AgentRoute = {tier: Tier; ordinal: number; provider_id: string; model_id: string; share_pct: number};
export type Agent = {
  id: string; name: string; spec: Record<string, unknown>; priority: number; hold_at_pct: number;
  enabled: boolean; revision: number; updated_at: string; routes: AgentRoute[];
  current: {status: "eligible" | "held" | "blocked"; route?: {provider_id: string; model_id: string; tier: Tier; ordinal: number}; held_until?: string; reason?: string; skipped?: {provider_id:string;model_id:string;tier:Tier;ordinal:number;reason:string;next_eligible_at?:string}[]};
};
export type UsageSummary = {providers: (Pick<Provider, "id"|"display_name"|"kind"|"enabled"> & {probe_state:string|null;cooldown_until:string|null;windows:ProviderWindow[]})[]; holds:number; in_flight:number; observed_at:string};
export type Revision = {revision_id:number; entity:"provider"|"agent"|"model"|"fallback"; entity_id:string; revision:number; source:"import"|"ui"|"api"|"seed"; actor:string; diff:Record<string, unknown>; created_at:string};
export type ProviderModel = {id:string;name:string;context_length:number;pricing:{prompt:string;completion:string};protocol?:string};
export type ProviderStatus = {provider:string;state:"connected"|"not_configured"|"invalid_credentials"|"credentials_rejected"|"no_plan"|"rate_limited"|"provider_unavailable"|"connection_failed"|"invalid_response"|"catalog_only";checked_at_ms?:number;detail?:Record<string,unknown>};

const record = (v: unknown, message = "Invalid driver response"): Record<string, unknown> => {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw Error(message);
  return v as Record<string, unknown>;
};
const string = (v: unknown) => { if (typeof v !== "string") throw Error("Invalid driver string"); return v; };
const nullableString = (v: unknown) => v === null ? null : string(v);
const number = (v: unknown) => { if (typeof v !== "number" || !Number.isFinite(v)) throw Error("Invalid driver number"); return v; };
const integer = (v: unknown) => { const n = number(v); if (!Number.isSafeInteger(n)) throw Error("Invalid driver integer"); return n; };
const bool = (v: unknown) => { if (typeof v !== "boolean") throw Error("Invalid driver boolean"); return v; };
const oneOf = <T extends string>(v: unknown, values: readonly T[]): T => { if (!values.includes(v as T)) throw Error("Invalid driver enum"); return v as T; };
const windowParser = (v: unknown): ProviderWindow => { const r=record(v); return {
  window:oneOf(r.window,["rolling_5h","weekly","monthly","daily","minute"]), source:oneOf(r.source,["api","local"]),
  percent_used:number(r.percent_used), status:oneOf(r.status,["ok","rate_limited","unknown"]), resets_at:nullableString(r.resets_at), observed_at:nullableString(r.observed_at),
  threshold_pct:number(r.threshold_pct), pacing_slack_pct:number(r.pacing_slack_pct), limit_count:r.limit_count===null?null:integer(r.limit_count),
  elapsed_pct:number(r.elapsed_pct), over_threshold:bool(r.over_threshold), over_pace:bool(r.over_pace),
}; };
const providerParser = (v: unknown): Provider => { const r=record(v); const state=record(r.state); if (!Array.isArray(r.windows)) throw Error("Invalid provider windows"); return {
  id:string(r.id), display_name:string(r.display_name), kind:oneOf(r.kind,["subscription","free","paid","catalog_only"]), protocol:oneOf(r.protocol,["openai_chat","openai_responses","cursor_agent","none"]),
  base_url:string(r.base_url), credential_path:string(r.credential_path), catalog_source:oneOf(r.catalog_source,["live","static","none"]), catalog_url:nullableString(r.catalog_url),
  static_models:Array.isArray(r.static_models)?r.static_models: (()=>{throw Error("Invalid static models")})(), usage_url:nullableString(r.usage_url), status_url:nullableString(r.status_url),
  settings:record(r.settings), enabled:bool(r.enabled), revision:integer(r.revision), credential_state:oneOf(r.credential_state,["configured","not_configured"]), windows:r.windows.map(windowParser),
  state:{cooldown_until:nullableString(state.cooldown_until),cooldown_reason:nullableString(state.cooldown_reason),probe_state:nullableString(state.probe_state),probe_at:nullableString(state.probe_at),last_error:nullableString(state.last_error)},
}; };
const routeParser = (v: unknown): AgentRoute => { const r=record(v); return {tier:oneOf(r.tier,["subscription","free","paid"]),ordinal:integer(r.ordinal),provider_id:string(r.provider_id),model_id:string(r.model_id),share_pct:number(r.share_pct)}; };
const currentRoute = (v: unknown) => { const x=record(v); return {provider_id:string(x.provider_id),model_id:string(x.model_id),tier:oneOf(x.tier,["subscription","free","paid"]),ordinal:integer(x.ordinal)}; };
const agentParser = (v: unknown): Agent => { const r=record(v), current=record(r.current); if (!Array.isArray(r.routes)) throw Error("Invalid agent routes"); return {
  id:string(r.id),name:string(r.name),spec:record(r.spec),priority:integer(r.priority),hold_at_pct:number(r.hold_at_pct),enabled:bool(r.enabled),revision:integer(r.revision),updated_at:string(r.updated_at),routes:r.routes.map(routeParser),
  current:{status:oneOf(current.status,["eligible","held","blocked"]),...(current.route?{route:currentRoute(current.route)}:{}),...(current.held_until?{held_until:string(current.held_until)}:{}),...(current.reason?{reason:string(current.reason)}:{}),...(current.skipped?{skipped:Array.isArray(current.skipped)?current.skipped.map(v=>{const x=record(v);return {...currentRoute(x),reason:string(x.reason),...(x.next_eligible_at==null?{}:{next_eligible_at:string(x.next_eligible_at)})}}):(()=>{throw Error("Invalid skipped routes")})()}: {})},
}; };
export function parseProviders(value: unknown): Provider[] { const r=record(value); if(!Array.isArray(r.providers))throw Error("Invalid providers"); return r.providers.map(providerParser); }
export function parseProvider(value: unknown): Provider { return providerParser(value); }
export function parseAgents(value: unknown): Agent[] { const r=record(value); if(!Array.isArray(r.agents))throw Error("Invalid agents"); return r.agents.map(agentParser); }
export function parseUsageSummary(value: unknown): UsageSummary { const r=record(value); if(!Array.isArray(r.providers))throw Error("Invalid usage summary"); return {providers:r.providers.map(v=>{const p=record(v);if(!Array.isArray(p.windows))throw Error("Invalid usage windows");return {id:string(p.id),display_name:string(p.display_name),kind:string(p.kind) as ProviderKind,enabled:bool(p.enabled),probe_state:nullableString(p.probe_state),cooldown_until:nullableString(p.cooldown_until),windows:p.windows.map(windowParser)}}),holds:integer(r.holds),in_flight:integer(r.in_flight),observed_at:string(r.observed_at)}; }
export function parseRevisions(value: unknown): Revision[] { const r=record(value); if(!Array.isArray(r.revisions))throw Error("Invalid revisions"); return r.revisions.map(v=>{const x=record(v);return {revision_id:integer(x.revision_id),entity:oneOf(x.entity,["provider","agent","model","fallback"]),entity_id:string(x.entity_id),revision:integer(x.revision),source:oneOf(x.source,["import","ui","api","seed"]),actor:string(x.actor),diff:record(x.diff),created_at:string(x.created_at)}}); }
export function parseProviderModels(value: unknown): ProviderModel[] { const r=record(value);if(!Array.isArray(r.models))throw Error("Invalid provider models");return r.models.map(v=>{const x=record(v),p=record(x.pricing);return {id:string(x.id),name:string(x.name),context_length:integer(x.context_length),pricing:{prompt:string(p.prompt),completion:string(p.completion)},...(x.protocol===undefined?{}:{protocol:string(x.protocol)})}}); }
export function parseProviderStatus(value: unknown): ProviderStatus { const r=record(value);return {provider:string(r.provider),state:oneOf(r.state,["connected","not_configured","invalid_credentials","credentials_rejected","no_plan","rate_limited","provider_unavailable","connection_failed","invalid_response","catalog_only"]),...(r.checked_at_ms===undefined?{}:{checked_at_ms:integer(r.checked_at_ms)}),...(r.detail===undefined?{}:{detail:record(r.detail)})}; }
export function moveRoute(routes: AgentRoute[], index: number, dir: -1|1) { const next=[...routes], target=index+dir; if(index>=0&&target>=0&&target<next.length)[next[index],next[target]]=[next[target],next[index]]; return next.map((r,i)=>({...r,ordinal:i})); }
export function routesByTier(routes: AgentRoute[]) { return {subscription:routes.filter(r=>r.tier==="subscription").sort((a,b)=>a.ordinal-b.ordinal),free:routes.filter(r=>r.tier==="free").sort((a,b)=>a.ordinal-b.ordinal),paid:routes.filter(r=>r.tier==="paid").sort((a,b)=>a.ordinal-b.ordinal)}; }
export function nextOrdinal(routes: AgentRoute[], tier: Tier) { return Math.max(-1,...routes.filter(r=>r.tier===tier).map(r=>r.ordinal))+1; }
export function windowLabel(window: ProviderWindowName) { return {rolling_5h:"5h",weekly:"Week",monthly:"Month",daily:"Day",minute:"Minute"}[window]; }
export function formatReset(resets_at: string|null, now = Date.now()) { if(!resets_at)return "reset unknown"; const minutes=Math.max(0,Math.round((Date.parse(resets_at)-now)/60000)); return `resets in ${Math.floor(minutes/60)}h ${minutes%60}m`; }
export const agentsQuery=queryOptions({queryKey:["api","agents"] as const,queryFn:async({signal})=>parseAgents(await getJson("/api/agents",signal))});
export const providersQuery=queryOptions({queryKey:["api","providers"] as const,queryFn:async({signal})=>parseProviders(await getJson("/api/providers",signal))});
export const usageSummaryQuery=queryOptions({queryKey:["api","usage","summary"] as const,refetchInterval:60_000,queryFn:async({signal})=>parseUsageSummary(await getJson("/api/usage/summary",signal))});
export const revisionsQuery=queryOptions({queryKey:["api","config","revisions"] as const,queryFn:async({signal})=>parseRevisions(await getJson("/api/config/revisions",signal))});
