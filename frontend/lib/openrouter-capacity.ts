import { queryOptions } from "@tanstack/react-query";
import { getJson } from "./api-queries";

export type CapacityPolicy = {
  revision: number; paused: boolean; mode: "paced" | "burst"; daily_target: number;
  start_interval_ms: number; burst_remaining: number; prefer_free_models: boolean; paid_enabled: boolean; paid_model: string | null; paid_models: string[];
  paid_outage_enabled: boolean; paid_request_limit_nanos: number; paid_daily_limit_nanos: number;
  paid_monthly_limit_nanos: number; paid_attempt_limit: number; paid_model_open_weights_confirmed: boolean;
  paid_finish_on_429: boolean; paid_max_fallback_attempts: number;
  paid_role_models: Record<"research" | "setup" | "experiment" | "default", string | null>;
};
export type Capacity = {
  policy: CapacityPolicy; free_used: number; free_remaining: number; minute_used: number;
  in_flight: number; queued: number; next_eligible_at: string | null; cooldown_until: string | null; free_cooldown_until: string | null;
  paid_used_nanos: number; paid_reserved_nanos: number; paid_attempts: number;
  window_mode: "rolling_24h"; history_status: string;
};
const whole = (n: unknown): n is number => typeof n === "number" && Number.isSafeInteger(n) && n >= 0;
const withinPolicyCaps = (p: CapacityPolicy) => p.start_interval_ms <= 60_000 && p.paid_request_limit_nanos <= 1_000_000_000 &&
  p.paid_daily_limit_nanos <= 10_000_000_000 && p.paid_monthly_limit_nanos <= 100_000_000_000 && p.paid_attempt_limit <= 100;
export function parseCapacity(value: unknown): Capacity {
  if (!value || typeof value !== "object") throw Error("Capacity unavailable");
  const c = value as Capacity, p = c.policy;
  if (!p || !whole(p.revision) || !["paced", "burst"].includes(p.mode) ||
    [p.paused,p.prefer_free_models,p.paid_enabled,p.paid_outage_enabled,p.paid_model_open_weights_confirmed,p.paid_finish_on_429].some(v => typeof v !== "boolean") ||
    ![1,2].includes(p.paid_max_fallback_attempts) || !p.paid_role_models ||
    ["research","setup","experiment","default"].some(role => {const id=p.paid_role_models[role as keyof CapacityPolicy["paid_role_models"]];return id !== null && typeof id !== "string";}) ||
    !whole(p.daily_target) || p.daily_target < 1 || p.daily_target > 1000 ||
    !whole(p.start_interval_ms) || p.start_interval_ms < 3100 ||
    [p.burst_remaining,p.paid_request_limit_nanos,p.paid_daily_limit_nanos,p.paid_monthly_limit_nanos,p.paid_attempt_limit,
      c.free_used,c.free_remaining,c.minute_used,c.in_flight,c.queued,c.paid_used_nanos,c.paid_reserved_nanos,c.paid_attempts].some(v => !whole(v)) ||
    !withinPolicyCaps(p) || (p.paid_model !== null && typeof p.paid_model !== "string") || !Array.isArray(p.paid_models) || p.paid_models.length > 16 ||
    p.paid_models.some(id => typeof id !== "string" || !id || id.endsWith(":free")) || new Set(p.paid_models).size !== p.paid_models.length ||
    c.window_mode !== "rolling_24h" || typeof c.history_status !== "string" ||
    [c.next_eligible_at,c.cooldown_until,c.free_cooldown_until].some(v => v !== null && (typeof v !== "string" || !Number.isFinite(Date.parse(v))))) throw Error("Invalid capacity response");
  return c;
}
export function dollarsToNanos(value: string): number | null {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,9})?$/.test(value)) return null;
  const [whole, fraction = ""] = value.split(".");
  const n = Number(whole) * 1_000_000_000 + Number(fraction.padEnd(9,"0"));
  return Number.isSafeInteger(n) ? n : null;
}
export function canSaveCapacity(p: CapacityPolicy, approvedPaidModels: string[]): boolean {
  return whole(p.daily_target) && p.daily_target >= 1 && p.daily_target <= 1000 && whole(p.start_interval_ms) && p.start_interval_ms >= 3100 && withinPolicyCaps(p) && p.paid_models.length <= 16 &&
    [1,2].includes(p.paid_max_fallback_attempts) && Object.values(p.paid_role_models).every(id => id === null || p.paid_models.includes(id)) &&
    [p.paid_request_limit_nanos,p.paid_daily_limit_nanos,p.paid_monthly_limit_nanos,p.paid_attempt_limit].every(whole) &&
    (!p.paid_enabled || ((!p.prefer_free_models || p.paid_model_open_weights_confirmed) && p.paid_models.length > 0 &&
      p.paid_models.includes(p.paid_model ?? "") && p.paid_models.every(id => approvedPaidModels.includes(id)) &&
      [p.paid_request_limit_nanos,p.paid_daily_limit_nanos,p.paid_monthly_limit_nanos,p.paid_attempt_limit].every(n => n > 0)));
}
export const capacityQuery = queryOptions({ queryKey: ["api", "providers", "capacity"] as const,
  refetchInterval: 10_000, queryFn: async ({signal}) => parseCapacity(await getJson("/api/providers/capacity",signal)) });
export async function updateCapacity(policy: CapacityPolicy): Promise<void> {
  const response = await fetch("/api/providers/capacity", {method:"PUT",headers:{"Content-Type":"application/json"},
    signal:AbortSignal.timeout(15_000),body:JSON.stringify({expected_revision:policy.revision,policy})});
  if (response.status === 409) throw Error("Settings changed elsewhere. Reload current settings before saving.");
  if (!response.ok) throw Error("Capacity settings could not be saved. Reload to check current settings before retrying.");
}

export async function capacityProxy(request: Request, method: "GET" | "PUT" | "POST") {
  const headers = {"Cache-Control":"no-store"};
  if (method !== "GET") {
    try {
      const origin = new URL(request.headers.get("origin") ?? "");
      if (origin.protocol !== new URL(request.url).protocol || origin.host !== request.headers.get("host") ||
        !["http:","https:"].includes(origin.protocol) || !["localhost","127.0.0.1","[::1]"].includes(origin.hostname)) throw Error();
    } catch {return Response.json({error:"Local same-origin request required"},{status:403,headers});}
  }
  const base = process.env.AGENT_DRIVER_URL;
  if (!base) return Response.json({error:"Capacity service unavailable"},{status:503,headers});
  try {
    let body: Uint8Array | undefined;
    if (method !== "GET") {
      const reader = request.body?.getReader();
      if (!reader) return Response.json({error:"Request required"},{status:400,headers});
      const chunks: Uint8Array[] = []; let size = 0;
      while (true) {
        const chunk = await reader.read(); if (chunk.done) break;
        size += chunk.value.length;
        if (size > 10_000) {await reader.cancel();return Response.json({error:"Request too long"},{status:413,headers});}
        chunks.push(chunk.value);
      }
      body = Buffer.concat(chunks);
    }
    const response = await fetch(`${base}/capacity${method === "POST" ? "/burst" : ""}`, {method,cache:"no-store",
      signal:AbortSignal.any([request.signal,AbortSignal.timeout(15_000)]),...(body ? {body:body as BodyInit,headers:{"Content-Type":"application/json"}} : {})});
    return new Response(response.body,{status:response.status,headers:{...headers,"Content-Type":"application/json"}});
  } catch {return Response.json({error:"Capacity service unavailable. Reload before retrying a change."},{status:503,headers});}
}
