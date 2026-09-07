export type OpenRouterStatus = { provider: "openrouter"; state: string; model_policy: "whitelist"; inference_enabled: false; checked_at_ms?: number };
export type ModelPricing = { prompt: string; completion: string; [key: string]: unknown };
export type Model = { id: string; name: string; context_length: number; created?: number; pricing: ModelPricing };
export type ModelPolicy = { revision: number; allowed_models: string[] };
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid OpenRouter response");
  return value as Record<string, unknown>;
}
export function parseStatus(value: unknown): OpenRouterStatus {
  const row = object(value);
  if (row.provider !== "openrouter" || row.model_policy !== "whitelist" || row.inference_enabled !== false || !["connected","not_configured","invalid_credentials","credentials_rejected","rate_limited","provider_unavailable","connection_failed","invalid_response"].includes(String(row.state))) throw new Error("Invalid OpenRouter status");
  if (row.state === "connected" && (typeof row.checked_at_ms !== "number" || !Number.isSafeInteger(row.checked_at_ms))) throw new Error("Invalid check time");
  return { provider: "openrouter", state: String(row.state), model_policy: "whitelist", inference_enabled: false, checked_at_ms: row.checked_at_ms as number | undefined };
}
export function parseModels(value: unknown): Model[] {
  const rows = object(value).models;
  if (!Array.isArray(rows)) throw new Error("Invalid model catalog");
  return rows.map(value => {
    const row = object(value), pricing = object(row.pricing);
    if (typeof row.id !== "string" || typeof row.name !== "string" || typeof row.context_length !== "number" || !Number.isSafeInteger(row.context_length) || row.context_length <= 0 || ["prompt","completion"].some(key => typeof pricing[key] !== "string" || !Number.isFinite(Number(pricing[key])) || Number(pricing[key]) < 0)) throw new Error("Invalid model");
    if (row.created != null && (typeof row.created !== "number" || !Number.isSafeInteger(row.created) || row.created < 0 || row.created > 8640000000000)) throw new Error("Invalid catalog date");
    return { created: row.created == null ? undefined : row.created as number, id: row.id, name: row.name, context_length: row.context_length, pricing: pricing as ModelPricing };
  });
}
export function parsePolicy(value: unknown): ModelPolicy {
  const row = object(value);
  if (typeof row.revision !== "number" || !Number.isSafeInteger(row.revision) || row.revision < 0 || !Array.isArray(row.allowed_models) || row.allowed_models.length > 100 || row.allowed_models.some(v => typeof v !== "string")) throw new Error("Invalid model whitelist");
  return { revision: row.revision, allowed_models: row.allowed_models as string[] };
}
export function isFree(model: Model) { return Object.values(model.pricing).every(price => typeof price === "string" && /^(?=.*0)[0.]+$/.test(price) && Number(price) === 0); }
export function tokenPrice(value: string) { return new Intl.NumberFormat("en-US", {style:"currency",currency:"USD",maximumFractionDigits:4}).format(Number(value)*1_000_000); }

export type AccountBalance = {state:"available";balance_usd:number;checked_at_ms:number} | {state:"not_configured"|"invalid_credentials"|"management_key_required"|"rate_limited"|"unavailable"|"invalid_response"};
export function parseBalance(value:unknown):AccountBalance {
  const row=object(value);
  if (row.state === "available") {
    if (typeof row.balance_usd !== "number" || !Number.isFinite(row.balance_usd) || typeof row.checked_at_ms !== "number" || !Number.isSafeInteger(row.checked_at_ms)) throw new Error("Invalid account balance");
    return {state:"available",balance_usd:row.balance_usd,checked_at_ms:row.checked_at_ms};
  }
  if (!["not_configured","invalid_credentials","management_key_required","rate_limited","unavailable","invalid_response"].includes(String(row.state))) throw new Error("Invalid balance state");
  return {state:row.state} as AccountBalance;
}
