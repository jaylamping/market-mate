import { Stage1Surfaces } from "../Stage1Surfaces";
import { parseStage1Surfaces } from "./stage1-surfaces-model";

export const dynamic = "force-dynamic";

async function loadSurfaces() {
  const base = process.env.BACKEND_URL ?? "http://127.0.0.1:8080";
  const response = await fetch(`${base}/stage1-surfaces`, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`stage-1 surfaces are unavailable (${response.status})`);
  }
  return parseStage1Surfaces(await response.json());
}

export default async function SurfacesPage() {
  return <Stage1Surfaces surfaces={await loadSurfaces()} />;
}
