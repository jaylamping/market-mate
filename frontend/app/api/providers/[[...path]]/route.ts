export const dynamic = "force-dynamic";
const headers = {"Cache-Control":"no-store"};
async function forward(request: Request, path: string[], method: "GET"|"PUT") {
  if (path[0] === "capacity") return Response.json({error:"Not found"},{status:404,headers});
  if (method === "PUT" && path.length !== 1) return Response.json({error:"Not found"},{status:404,headers});
  const base=process.env.AGENT_DRIVER_URL;
  if(!base)return Response.json({error:"Agent driver unavailable"},{status:503,headers});
  try { const response=await fetch(`${base}/providers${path.length?"/"+path.map(encodeURIComponent).join("/"):""}`,{method,cache:"no-store",signal:AbortSignal.timeout(12_000),...(method==="PUT"?{headers:{"Content-Type":"application/json"},body:JSON.stringify(await request.json())}:{})}); return Response.json(await response.json(),{status:response.status,headers}); }
  catch{return Response.json({error:"Agent driver unavailable"},{status:503,headers});}
}
function allowed(request: Request) { const origin=request.headers.get("origin"),host=request.headers.get("host"); if(!origin||!host)return false; try {const url=new URL(origin);return url.host===host&&["localhost","127.0.0.1","[::1]"].includes(url.hostname)}catch{return false} }
export async function GET(request:Request,{params}:{params:Promise<{path?:string[]}>}){return forward(request,(await params).path??[],"GET")}
export async function PUT(request:Request,{params}:{params:Promise<{path?:string[]}>}){if(!allowed(request))return Response.json({error:"Invalid origin"},{status:403,headers});return forward(request,(await params).path??[],"PUT")}
