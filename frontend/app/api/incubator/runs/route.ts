export const dynamic = "force-dynamic";
export async function GET() {
  try {
    const response = await fetch(`${process.env.BACKEND_URL ?? "http://127.0.0.1:8080"}/incubator/runs`, {cache:"no-store", signal:AbortSignal.timeout(10_000)});
    if (!response.ok) throw Error("History unavailable");
    return Response.json(await response.json(), {headers:{"Cache-Control":"no-store"}});
  } catch { return Response.json({error:"Incubator history unavailable"}, {status:503,headers:{"Cache-Control":"no-store"}}); }
}
