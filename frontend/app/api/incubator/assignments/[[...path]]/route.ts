import { requestProxy } from "@/lib/incubator-request-proxy";
export const dynamic="force-dynamic";
type Context={params:Promise<{path?:string[]}>};
async function forward(request:Request,context:Context,method:"GET"|"POST") {
  const path=(await context.params).path??[];
  const valid=method==="POST"?(path.length===0||path.join("/")==="check"):
    (path.join("/")==="stream"||(path.length===2&&path[0]==="check"&&/^[a-zA-Z0-9_-]{1,80}$/.test(path[1])));
  if(!valid)return Response.json({error:"Not found"},{status:404});
  return requestProxy(request,`/assignments${path.length?`/${path.join("/")}`:""}`,method);
}
export function GET(request:Request,context:Context){return forward(request,context,"GET");}
export function POST(request:Request,context:Context){return forward(request,context,"POST");}
