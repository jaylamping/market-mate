import { loadSurfaces } from "../../surfaces/load-surfaces";
export const dynamic = "force-dynamic";
export async function GET() {
  try { return Response.json(await loadSurfaces(), { headers: { "Cache-Control": "no-store" } }); }
  catch { return Response.json({ error: "Research evidence unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } }); }
}
