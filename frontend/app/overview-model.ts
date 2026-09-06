import type { Stage1SurfacesModel, Qualification } from "./Stage1Surfaces";

export type Tone = "danger" | "good" | "neutral" | "warning";
export type AttentionItem = { label: string; detail: string; tone: Tone; href: string };

export function custodyTrusted(s: Stage1SurfacesModel) {
  return s.checkpoints_verified && s.checkpoint_pack.state === "CHECKPOINT VERIFIED";
}

export function attentionItems(s: Stage1SurfacesModel): AttentionItem[] {
  const items: AttentionItem[] = [];
  if (!s.checkpoints_verified || s.checkpoint_pack.state === "CHECKPOINT UNVERIFIED") {
    items.push({ label: "Custody is unverified", detail: "Evidence trust cannot be confirmed. Inspect checkpoint coverage before relying on these records.", tone: "danger", href: "/surfaces#checkpoint-pack" });
  } else if (s.checkpoint_pack.state === "CHECKPOINT PENDING") {
    const pending = s.checkpoint_pack.pending_events;
    items.push({ label: "Checkpoint coverage pending", detail: pending === null ? "The number of events awaiting coverage is unavailable." : `${pending} ${pending === 1 ? "event awaits" : "events await"} the next signed checkpoint.`, tone: "warning", href: "/surfaces#checkpoint-pack" });
  }
  if (s.cost_model.recorded && !s.cost_model.within_caps) items.push({ label: "Projected costs exceed cap", detail: s.cost_model.required_decision ?? "Projected operating costs exceed the approved envelope.", tone: "danger", href: "/surfaces#cost-vs-caps" });
  if (s.cost.recorded && (s.cost.register.monthly_state === "exceeded" || s.cost.register.year_one_state === "exceeded")) items.push({ label: "Recorded spend exceeds cap", detail: "The cost register exceeds a hard ceiling. Inspect the monthly and year-one totals.", tone: "danger", href: "/surfaces#cost-vs-caps" });
  if (s.qualification.recorded && s.qualification.status === "failed") items.push({ label: "Qualification failed", detail: s.qualification.failure_reasons.join(" ") || "The latest frozen qualification report failed.", tone: "danger", href: "/surfaces#qualification-progress" });
  const degraded = s.snapshots.latest_manifests.filter(m => m.evidence_state !== "complete");
  if (degraded.length) items.push({ label: "Research evidence needs inspection", detail: `${degraded.length} of the displayed cycles ${degraded.length === 1 ? "has" : "have"} incomplete or degraded evidence.`, tone: "warning", href: `/surfaces#${encodeURIComponent(`cycle-${degraded[0].cycle_key}`)}` });
  return items.sort((a, b) => Number(b.tone === "danger") - Number(a.tone === "danger"));
}

export function comparatorFloors(q: Qualification) {
  if (!q.recorded) return "Not recorded";
  const count = Number(q.meets_cash_floor) + (q.sp500_comparator_required ? Number(q.meets_sp500_floor === true) : 0);
  return `${count} / ${q.sp500_comparator_required ? 2 : 1} pass`;
}

export function qualificationMeasures(q: Extract<Qualification, { recorded: true }>) {
  return [
    { label: "Net mean", value: q.net_mean_return_bps, unavailable: "Unavailable" },
    { label: "LCB vs cash", value: q.lcb_vs_cash_bps, unavailable: "Unavailable" },
    { label: "LCB vs S&P 500", value: q.sp500_comparator_required ? q.lcb_vs_sp500_bps : null, unavailable: q.sp500_comparator_required ? "Unavailable" : "Not required" },
  ];
}

export function money(cents: number | string) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(cents) / 100);
}

export function displayTime(value: string) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Time unavailable";
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: false, timeZone: "UTC" }).format(date) + " UTC";
}
