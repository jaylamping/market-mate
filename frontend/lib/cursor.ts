export type CursorStatus = { provider: "cursor"; state: string; model_policy: "whitelist"; inference_enabled: false; checked_at_ms?: number };
export type Model = { id: string; name: string;  };
export type ModelPolicy = { revision: number; allowed_models: string[] };
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid Cursor response");
  return value as Record<string, unknown>;
}
export function parseStatus(value: unknown): CursorStatus {
  const row = object(value);
  if (row.provider !== "cursor" || row.model_policy !== "whitelist" || row.inference_enabled !== false || !["connected","not_configured","invalid_credentials","credentials_rejected","rate_limited","provider_unavailable","connection_failed","invalid_response"].includes(String(row.state))) throw new Error("Invalid Cursor status");
  if (row.state === "connected" && (typeof row.checked_at_ms !== "number" || !Number.isSafeInteger(row.checked_at_ms))) throw new Error("Invalid check time");
  return { provider: "cursor", state: String(row.state), model_policy: "whitelist", inference_enabled: false, checked_at_ms: row.checked_at_ms as number | undefined };
}
export function parseModels(value: unknown): Model[] {
  const rows = object(value).models;
  if (!Array.isArray(rows)) throw new Error("Invalid Cursor catalog");
  return rows.map(value => { const row = object(value); if (typeof row.id !== "string" || !row.id || typeof row.name !== "string" || !row.name) throw new Error("Invalid Cursor model"); return {id:row.id,name:row.name}; });
}
export function parsePolicy(value: unknown): ModelPolicy {
  const row = object(value);
  if (typeof row.revision !== "number" || !Number.isSafeInteger(row.revision) || row.revision < 0 || !Array.isArray(row.allowed_models) || row.allowed_models.length > 100 || row.allowed_models.some(v => typeof v !== "string")) throw new Error("Invalid model whitelist");
  return { revision: row.revision, allowed_models: row.allowed_models as string[] };
}
