import { queryOptions } from "@tanstack/react-query";
import { parsePaper } from "../app/paper/model";
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
export const surfacesQuery = queryOptions({
  queryKey: ["api", "research", "surfaces"] as const,
  queryFn: async ({ signal }) => parseStage1Surfaces(await getJson("/api/surfaces", signal)),
});
