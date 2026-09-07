import {requestProxy} from "@/lib/incubator-request-proxy";
export async function POST(request:Request,context:{params:Promise<{key:string}>}) {
 const {key}=await context.params;
 if(!/^[a-zA-Z0-9_-]{1,96}$/.test(key))return Response.json({error:"Invalid run"},{status:400});
 return requestProxy(request,`/runs/${key}/archive`,"POST");
}
