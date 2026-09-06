import { loadPaper } from "../../paper/load-paper";
export const dynamic = "force-dynamic";
export async function GET() {
  const state = await loadPaper();
  return Response.json({ provider: "alpaca", environment: "paper", access: "read_only", ...state }, {
    status: state.state === "connector_unavailable" ? 503 : 200,
    headers: { "Cache-Control": "no-store" },
  });
}
