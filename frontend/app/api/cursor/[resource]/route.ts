const resources = ["status", "models", "policy"];
export const dynamic = "force-dynamic";
async function forward(request: Request, resource: string, method: "GET" | "PUT") {
  if (!resources.includes(resource) || (method === "PUT" && resource !== "policy")) return Response.json({error:"Not found"},{status:404});
  const base = process.env.CURSOR_CONNECTOR_URL;
  if (!base) return Response.json({error:"Cursor connector unavailable"},{status:503});
  try {
    const response = await fetch(`${base}/cursor/${resource}`, {method, cache:"no-store",signal:AbortSignal.timeout(12_000), ...(method === "PUT" ? {headers:{"Content-Type":"application/json"},body:JSON.stringify(await request.json())} : {})});
    return Response.json(await response.json(),{status:response.status,headers:{"Cache-Control":"no-store"}});
  } catch { return Response.json({error:"Cursor connector unavailable"},{status:503,headers:{"Cache-Control":"no-store"}}); }
}
export async function GET(request: Request, {params}: {params:Promise<{resource:string}>}) { return forward(request,(await params).resource,"GET"); }
export async function PUT(request: Request, {params}: {params:Promise<{resource:string}>}) {
  // This local configuration write accepts only the browser's same-origin request.
  const origin = request.headers.get("origin"), host = request.headers.get("host");
  if (!origin || !host) return Response.json({error:"Origin required"},{status:403});
  try {
    const url = new URL(origin);
    if (url.host !== host || !["localhost","127.0.0.1","[::1]"].includes(url.hostname)) return Response.json({error:"Invalid origin"},{status:403});
  } catch { return Response.json({error:"Invalid origin"},{status:403}); }
  return forward(request,(await params).resource,"PUT");
}
