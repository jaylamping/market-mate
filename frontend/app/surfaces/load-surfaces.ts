import { parseStage1Surfaces } from "./stage1-surfaces-model";

export async function loadSurfaces() {
  const base = process.env.BACKEND_URL ?? "http://127.0.0.1:8080";
  const response = await fetch(`${base}/stage1-surfaces`, {
    cache: "no-store",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`Stage-1 evidence unavailable (${response.status})`);
  return parseStage1Surfaces(await response.json());
}
