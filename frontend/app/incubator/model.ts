export type RunState = "admitted" | "preparing" | "dispatched" | "completed" | "failed" | "indeterminate";
export type Report = { hypothesis: string; evidence_gaps: string[]; experiment: string[]; falsification_rule: string; limitations: string[] };
type Detail = { fallback_of: string | null; response_text: string | null; validation_error: string | null; response_truncated: boolean; reason: string | null; generation_id: string | null; returned_model: string | null; serving_provider: string | null; report: Report | null; usage: { prompt_tokens: number | null; completion_tokens: number | null; cost_usd: number | null }; request_sha256: string | null; policy_revision: number | null };
export type Run = { created_by?: "principal"|"agent"|"local_runner"; run_key: string; assignment_id: string; created_at: string; updated_at: string; state: RunState; config: { agent_name: string; model: string; input: { title: string; text: string }; limits: { max_requests: number; max_output_tokens: number; timeout_seconds: number; max_cost_usd: number } }; detail: Detail; events: { sequence: number; state: RunState; at: string; detail: Detail }[] };
function object(v: unknown): Record<string, unknown> { if (!v || typeof v !== "object" || Array.isArray(v)) throw Error("Invalid run history"); return v as Record<string, unknown>; }
function string(v: unknown): string { if (typeof v !== "string" || !v.trim()) throw Error("Invalid run text"); return v; }
function number(v: unknown): number { if (typeof v !== "number" || !Number.isFinite(v) || v < 0) throw Error("Invalid run number"); return v; }
function array(v: unknown): unknown[] { if (!Array.isArray(v)) throw Error("Invalid run list"); return v; }
function date(v: unknown): string { const s=string(v); if (!Number.isFinite(Date.parse(s))) throw Error("Invalid run date"); return s; }
function state(v: unknown): RunState { if (!["admitted","preparing","dispatched","completed","failed","indeterminate"].includes(string(v))) throw Error("Invalid run state"); return v as RunState; }
function nullable<T>(v: unknown, parse: (v: unknown) => T): T | null { return v === null || v === undefined ? null : parse(v); }
export function parseReport(v: unknown): Report {
 const r=object(v),fields=["hypothesis","evidence_gaps","experiment","falsification_rule","limitations"];
 if(Object.keys(r).length!==fields.length||fields.some(k=>!(k in r)))throw Error("Invalid report fields");
 const text=(v:unknown)=>{const s=string(v);if(new TextEncoder().encode(s).length>6000||/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(s))throw Error("Invalid report text");return s;};
 const list=(v:unknown)=>{const rows=array(v);if(rows.length<1||rows.length>12)throw Error("Invalid report list");return rows.map(text);};
 if(new TextEncoder().encode(JSON.stringify(r)).length>24000)throw Error("Report too long");
 return {hypothesis:text(r.hypothesis),evidence_gaps:list(r.evidence_gaps),experiment:list(r.experiment),falsification_rule:text(r.falsification_rule),limitations:list(r.limitations)};
}
function detail(v: unknown): Detail {
  const d=object(v), u=d.usage == null ? {} : object(d.usage);
  return { fallback_of:nullable(d.fallback_of,string),response_text:nullable(d.response_text,v=>{if(typeof v!=="string") throw Error("Invalid response text");return v;}),validation_error:nullable(d.validation_error,string),response_truncated:d.response_truncated === true,reason:nullable(d.reason,string), generation_id:nullable(d.generation_id,string), returned_model:nullable(d.returned_model,string), serving_provider:nullable(d.serving_provider,string), report:nullable(d.report,parseReport), usage:{ prompt_tokens:nullable(u.prompt_tokens,number), completion_tokens:nullable(u.completion_tokens,number), cost_usd:nullable(u.cost_usd,number) }, request_sha256:nullable(d.request_sha256,string), policy_revision:nullable(d.policy_revision,number) };
}
export function parseRuns(v: unknown): Run[] {
  const body=object(v); if (body.environment !== "local_research" || body.artifact_kind !== "research_planning") throw Error("Invalid history scope");
  return array(body.runs).map(v => {
    const r=object(v), c=object(r.config), input=object(c.input), limits=object(c.limits);
    if (c.provider !== "openrouter" || input.classification !== "project_authored_research_brief") throw Error("Invalid run scope");
    const result: Run={ created_by:r.created_by==="principal"||r.created_by==="agent"?r.created_by:"local_runner", run_key:string(r.run_key), assignment_id:string(r.assignment_id), created_at:date(r.created_at), updated_at:date(r.updated_at), state:state(r.state),
      config:{agent_name:string(c.agent_name),model:string(c.model),input:{title:string(input.title),text:string(input.text)},limits:{max_requests:number(limits.max_requests),max_output_tokens:number(limits.max_output_tokens),timeout_seconds:number(limits.timeout_seconds),max_cost_usd:number(limits.max_cost_usd)}}, detail:detail(r.detail),
      events:array(r.events).map(v => { const e=object(v); return {sequence:number(e.sequence),state:state(e.state),at:date(e.at),detail:detail(e.detail)}; }) };
    if (!result.events.length || result.events.at(-1)?.state !== result.state || (result.state === "completed" && !result.detail.report)) throw Error("Incomplete run history");
    return result;
  });
}
export function stateLabel(run: Run, now = Date.now()): string {
  if (run.state === "dispatched" && now - Date.parse(run.updated_at) > (run.config.limits.timeout_seconds + 15) * 1000) return "Outcome unknown";
  return { admitted:"Assigned", preparing:"Preparing", dispatched:"Researching", completed:"Report ready", failed:"Failed", indeterminate:"Outcome unknown" }[run.state];
}
export function costLabel(value: number | null): string { return value === null ? "Unavailable" : value === 0 ? "$0.00" : `$${value.toFixed(6)}`; }
