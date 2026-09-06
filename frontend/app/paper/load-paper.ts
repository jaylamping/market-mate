import { connected, parsePaper, type PaperState } from "./model";

export async function loadPaper(): Promise<PaperState> {
  const base = process.env.PAPER_CONNECTOR_URL;
  if (!base) return { state: "connector_unavailable" };
  try {
    const response = await fetch(`${base}/paper/account`, { cache: "no-store", signal: AbortSignal.timeout(12_000) });
    const parsed = parsePaper(await response.json());
    if (!response.ok && connected(parsed)) return { state: "invalid_response" };
    return parsed;
  } catch { return { state: "connector_unavailable" }; }
}
