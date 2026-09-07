"use client";
import { useQuery } from "@tanstack/react-query";
import { openrouterStatusQuery } from "@/lib/api-queries";
import type { OpenRouterStatus } from "@/lib/openrouter";

const credits = (value: number | undefined) => value === undefined ? "Unknown" : new Intl.NumberFormat("en-US", { maximumFractionDigits: 6 }).format(value);

export function OpenRouterLimitsSummary({ status }: { status: OpenRouterStatus }) {
  const limits = status.key_limits;
  if (status.state !== "connected" || !limits) return <p role="status" className="text-sm text-muted-foreground">OpenRouter key limits unavailable. Check the connection in System.</p>;
  const cap = (value: number | null | undefined) => value === null ? "Unlimited" : credits(value);
  return <section aria-label="OpenRouter key limits" className="grid min-w-0 gap-3 rounded-md border p-4 text-sm">
    <div className="flex flex-wrap justify-between gap-2"><h3 className="font-medium">OpenRouter key limits</h3><span className="text-xs text-muted-foreground">Checked {new Date(status.checked_at_ms!).toLocaleString()} · refreshes every minute</span></div>
    <dl className="grid grid-cols-2 gap-4 sm:grid-cols-3">
      {[
        ["Key credit cap", cap(limits.limit)], ["Key credits remaining", cap(limits.limit_remaining)],
        ["Reset policy", limits.limit_reset === null ? "Does not reset" : limits.limit_reset ?? "Unknown"],
        ["Credits used today (UTC)", credits(limits.usage_daily)], ["Credits used this week (UTC)", credits(limits.usage_weekly)],
        ["Credits used this month (UTC)", credits(limits.usage_monthly)],
      ].map(([label, value]) => <div key={label} className="min-w-0"><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-1 break-words tabular-nums">{value}</dd></div>)}
    </dl>
    {limits.limit_remaining === 0 && <p role="status">This key’s credit cap is exhausted. OpenRouter may reject requests with 402; free-model availability must be checked separately.</p>}
    <p className="text-xs text-muted-foreground">Free requests remaining: unknown. OpenRouter’s key endpoint reports credit usage, not a free-request counter. Zero spend does not mean quota remains. Request limits are shared across API keys.</p>
    <details className="text-xs text-muted-foreground"><summary className="cursor-pointer">Usage details and free-model limits</summary><div className="mt-2 grid gap-2">
      <p>Account tier: {status.is_free_tier === undefined ? "unknown" : status.is_free_tier ? "free" : "credits previously purchased"}. Tier alone does not establish the daily free-request allowance.</p>
      <p>All-time key usage: {credits(status.key_usage_credits)} credits. External BYOK usage: {credits(limits.byok_usage)} all time; {credits(limits.byok_usage_daily)} today; {credits(limits.byok_usage_weekly)} this week; {credits(limits.byok_usage_monthly)} this month. BYOK usage counts toward the cap: {limits.include_byok_in_limit === undefined ? "unknown" : limits.include_byok_in_limit ? "yes" : "no"}.</p>
      <p>Credit caps and account balance are separate. Free models can still be rate limited. A 429 response may provide a reset time or Retry-After hint.</p>
      <a className="underline underline-offset-4" href="https://openrouter.ai/docs/api_reference/limits#checking-your-limits" target="_blank" rel="noreferrer">OpenRouter’s current limits</a>
    </div></details>
  </section>;
}

export function OpenRouterLimits() {
  const query = useQuery(openrouterStatusQuery);
  if (query.isPending) return <p role="status" className="text-sm text-muted-foreground">Checking OpenRouter key limits…</p>;
  if (query.isError || !query.data) return <p role="status" className="text-sm text-muted-foreground">OpenRouter key limits unavailable. Refresh to try again.</p>;
  return <OpenRouterLimitsSummary status={query.data}/>;
}
