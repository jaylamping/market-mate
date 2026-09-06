export type PaperAccount = { status: string; currency: string; cash: string; equity: string; buying_power: string; trading_blocked: boolean; account_blocked: boolean };
export type PaperPosition = { symbol: string; asset_class: string; side: string; qty: string; market_value: string | null; unrealized_pl: string | null };
export type PaperOrder = { id: string; symbol: string; side: string; status: string; type: string; qty: string | null; notional: string | null; filled_qty: string; submitted_at: string | null };
export type PaperActivity = { id: string; activity_type: string; transaction_time: string | null; date: string | null; symbol: string | null; qty: string | null; price: string | null; net_amount: string | null };
export type PaperSnapshot = { provider: "alpaca"; environment: "paper"; access: "read_only"; state: "connected"; fetched_at_ms: number; account: PaperAccount; positions: PaperPosition[]; orders: PaperOrder[]; activities: PaperActivity[]; recent_limit: 50 };
export type PaperState = PaperSnapshot | { state: string };

function record(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid paper response");
  return value as Record<string, unknown>;
}
function strings(row: Record<string, unknown>, required: string[], optional: string[] = []) {
  for (const key of required) if (typeof row[key] !== "string") throw new Error("Invalid paper field");
  for (const key of optional) if (row[key] !== null && typeof row[key] !== "string") throw new Error("Invalid optional paper field");
}
function decimals(row: Record<string, unknown>, keys: string[]) {
  for (const key of keys) if (row[key] !== null && (typeof row[key] !== "string" || !/^-?\d+(\.\d+)?$/.test(row[key]) || !Number.isFinite(Number(row[key])))) throw new Error("Invalid paper amount");
}
export function parsePaper(value: unknown): PaperState {
  const data = record(value);
  if (data.provider !== "alpaca" || data.environment !== "paper" || data.access !== "read_only") throw new Error("Invalid paper boundary");
  if (data.state !== "connected") {
    if (!["not_configured", "invalid_credentials", "credentials_rejected", "rate_limited", "provider_unavailable", "connection_failed", "invalid_response"].includes(String(data.state))) throw new Error("Unknown paper state");
    return { state: String(data.state) };
  }
  if (typeof data.fetched_at_ms !== "number" || !Number.isSafeInteger(data.fetched_at_ms) || data.fetched_at_ms <= 0 || data.recent_limit !== 50) throw new Error("Invalid paper snapshot");
  const account = record(data.account);
  strings(account, ["status", "currency", "cash", "equity", "buying_power"]);
  decimals(account, ["cash", "equity", "buying_power"]);
  if (typeof account.trading_blocked !== "boolean" || typeof account.account_blocked !== "boolean" || !/^[A-Z]{3}$/.test(String(account.currency))) throw new Error("Invalid account state");
  for (const key of ["positions", "orders", "activities"] as const) {
    const rows = data[key];
    if (!Array.isArray(rows)) throw new Error("Invalid paper collection");
    for (const item of rows) {
      const row = record(item);
      if (key === "positions") { strings(row, ["symbol", "asset_class", "side", "qty"], ["market_value", "unrealized_pl"]); decimals(row, ["qty", "market_value", "unrealized_pl"]); }
      if (key === "orders") { strings(row, ["id", "symbol", "side", "status", "type", "filled_qty"], ["qty", "notional", "submitted_at"]); decimals(row, ["qty", "notional", "filled_qty"]); }
      if (key === "activities") { strings(row, ["id", "activity_type"], ["transaction_time", "date", "symbol", "qty", "price", "net_amount"]); decimals(row, ["qty", "price", "net_amount"]); }
    }
  }
  return data as unknown as PaperSnapshot;
}

export function connected(state: PaperState): state is PaperSnapshot { return state.state === "connected" && "account" in state; }
