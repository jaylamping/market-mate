import { parseRouting } from "./model-routing";
import { parseStatus as parseCursorStatus, parseModels as parseCursorModels, parsePolicy as parseCursorPolicy } from "./cursor";
import { parseStatus, parseModels, parsePolicy, parseBalance } from "./openrouter";
import { queryOptions } from "@tanstack/react-query";
import { parsePaper } from "../app/paper/model";
import { parseRuns } from "../app/incubator/model";
import { parseStage1Surfaces } from "../app/surfaces/stage1-surfaces-model";

export async function getJson(path: string, signal: AbortSignal): Promise<unknown> {
  const response = await fetch(path, { signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]), cache: "no-store" });
  if (!response.ok) throw new Error("API data unavailable. Refresh to try again.");
  return response.json();
}

export const paperQuery = queryOptions({
  queryKey: ["api", "paper", "account"] as const,
  queryFn: async ({ signal }) => parsePaper(await getJson("/api/paper", signal)),
});
export const incubatorQuery = queryOptions({ queryKey:["api","incubator","runs"] as const, queryFn:async ({signal}) => parseRuns(await getJson("/api/incubator/runs",signal)), refetchInterval:5_000 });
export const surfacesQuery = queryOptions({
  queryKey: ["api", "research", "surfaces"] as const,
  queryFn: async ({ signal }) => parseStage1Surfaces(await getJson("/api/surfaces", signal)),
});

export const openrouterStatusQuery = queryOptions({ queryKey: ["api","openrouter","status"] as const, queryFn: async ({signal}) => parseStatus(await getJson("/api/openrouter/status",signal)) });
export const openrouterModelsQuery = queryOptions({ queryKey: ["api","openrouter","models"] as const, staleTime:300_000, queryFn: async ({signal}) => parseModels(await getJson("/api/openrouter/models",signal)) });
export const openrouterPolicyQuery = queryOptions({ queryKey: ["api","openrouter","policy"] as const, queryFn: async ({signal}) => parsePolicy(await getJson("/api/openrouter/policy",signal)) });

export const cursorStatusQuery = queryOptions({ queryKey: ["api","cursor","status"] as const, queryFn: async ({signal}) => parseCursorStatus(await getJson("/api/cursor/status",signal)) });
export const cursorModelsQuery = queryOptions({ queryKey: ["api","cursor","models"] as const, staleTime:300_000, queryFn: async ({signal}) => parseCursorModels(await getJson("/api/cursor/models",signal)) });
export const cursorPolicyQuery = queryOptions({ queryKey: ["api","cursor","policy"] as const, queryFn: async ({signal}) => parseCursorPolicy(await getJson("/api/cursor/policy",signal)) });

export const openrouterBalanceQuery = queryOptions({queryKey:["api","openrouter","balance"] as const,staleTime:60_000,queryFn:async ({signal})=>parseBalance(await getJson("/api/openrouter/balance",signal))});

export const modelRoutingQuery = queryOptions({queryKey:["api","models","routing"] as const,queryFn:async({signal})=>parseRouting(await getJson("/api/openrouter/routing",signal))});
