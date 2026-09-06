import type { PaperActivity, PaperOrder } from "./model";

export function money(value: string | null, currency: string) {
  return value === null ? "Not reported" : new Intl.NumberFormat("en-US", { style: "currency", currency }).format(Number(value));
}

export function timestamp(value: string | null) {
  if (!value) return "Time not reported";
  const date = new Date(value);
  return Number.isFinite(date.valueOf()) ? new Intl.DateTimeFormat("en-US", { month:"short",day:"numeric",year:"numeric",hour:"2-digit",minute:"2-digit",timeZone:"UTC",hour12:false }).format(date) + " UTC" : value;
}

export function readable(value: string) { return value.replaceAll("_", " "); }

const activityLabels: Record<string, string> = {
  FILL:"Trade fill", JNLC:"Cash journal", JNLS:"Security journal", CSD:"Cash deposit", CSW:"Cash withdrawal",
  DIV:"Dividend", INT:"Interest", FEE:"Fee", ACATC:"Account transfer", ACATS:"Security transfer",
  OPEXP:"Option expiration", OPASN:"Option assignment", OPXRC:"Option exercise", SPLIT:"Stock split",
};
export function activityLabel(activity: PaperActivity) { return activityLabels[activity.activity_type] ?? activity.activity_type; }
export function matchesSymbol(symbol: string | null, query: string) { return (symbol ?? "").toLowerCase().includes(query.trim().toLowerCase()); }
export function ordersMatching(orders: PaperOrder[], query: string, status: string) {
  return orders.filter(order => matchesSymbol(order.symbol, query) && (status === "all" || order.status === status));
}
