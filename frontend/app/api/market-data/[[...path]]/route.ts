export const dynamic="force-dynamic";
type Context={params:Promise<{path?:string[]}>};
async function proxy(request:Request,path:string,method:"GET"|"POST") {
 const headers={"Cache-Control":"no-store"};
 if(method==="POST") {try {const origin=new URL(request.headers.get("origin")??"");if(origin.host!==request.headers.get("host")||!["localhost","127.0.0.1","[::1]"].includes(origin.hostname)||!["http:","https:"].includes(origin.protocol))throw Error();}catch{return Response.json({error:"Local same-origin request required"},{status:403,headers});}}
 const base=process.env.MARKET_DATA_URL;if(!base)return Response.json({error:"Market data service unavailable"},{status:503,headers});
 try {
  let body:Buffer|undefined;
  if(method==="POST") {const reader=request.body?.getReader();if(!reader)return new Response(null,{status:400});const chunks:Uint8Array[]=[];let size=0;while(true){const c=await reader.read();if(c.done)break;size+=c.value.length;if(size>8192){await reader.cancel();return new Response(null,{status:413});}chunks.push(c.value);}body=Buffer.concat(chunks);}
  const r=await fetch(`${base}/${path}`,{method,cache:"no-store",signal:AbortSignal.timeout(25000),...(body?{body:body as BodyInit,headers:{"Content-Type":"application/json"}}:{})});
  return new Response(r.body,{status:r.status,headers:{...headers,"Content-Type":"application/json"}});
 }catch{return Response.json({error:"Market data service unavailable. Check its status before retrying."},{status:503,headers});}
}
export async function GET(request:Request,{params}:Context){const {path=[]}=await params;return path.length===0?proxy(request,"status","GET"):new Response(null,{status:404});}
export async function POST(request:Request,{params}:Context){const {path=[]}=await params;return path.length===1&&["setup","reuse","settings"].includes(path[0])?proxy(request,path[0],"POST"):new Response(null,{status:404});}
