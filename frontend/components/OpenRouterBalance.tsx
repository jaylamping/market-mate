"use client";
import { useQuery } from "@tanstack/react-query";
import { openrouterBalanceQuery } from "@/lib/api-queries";

export function OpenRouterBalance() {
  const query=useQuery(openrouterBalanceQuery);
  const balance=query.data;
  if (balance?.state === "available" && !query.isError) return <span className="inline-flex items-center gap-2 rounded-md border px-3 py-1 text-sm" title={`Account credit balance · checked ${new Date(balance.checked_at_ms).toLocaleString()}`}><span className="text-muted-foreground">OpenRouter balance</span><span className="font-medium tabular-nums">{new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(balance.balance_usd)}</span></span>;
  return <a href="/system#openrouter-balance" className="text-sm text-muted-foreground underline underline-offset-4">{query.isPending?"Checking balance…":balance?.state==="management_key_required"?"Balance · needs management key":"Balance unavailable"}</a>;
}
