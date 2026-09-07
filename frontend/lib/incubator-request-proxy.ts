export async function requestProxy(request:Request,path:string,method:"GET"|"POST") {
  const base=process.env.INCUBATOR_REQUESTS_URL;
  const headers={"Cache-Control":"no-store","X-Accel-Buffering":"no"};
  if(method==="POST") {
    try {
      const origin=new URL(request.headers.get("origin")??"");
      if(origin.host!==request.headers.get("host")||!["http:","https:"].includes(origin.protocol)||!["localhost","127.0.0.1","[::1]"].includes(origin.hostname))throw Error();
    } catch {return Response.json({error:"Local same-origin request required"},{status:403,headers});}
  }
  if(!base)return Response.json({error:"Assignment service unavailable"},{status:503,headers});
  try {
    let body:Uint8Array|undefined;
    if(method==="POST") {
      const reader=request.body?.getReader();if(!reader)return Response.json({error:"Request required"},{status:400,headers});
      const chunks:Uint8Array[]=[];let size=0;
      while(true){const chunk=await reader.read();if(chunk.done)break;size+=chunk.value.length;if(size>10000){await reader.cancel();return Response.json({error:"Request too long"},{status:413,headers});}chunks.push(chunk.value);}
      body=Buffer.concat(chunks);
    }
    const response=await fetch(`${base}${path}`,{method,cache:"no-store",signal:AbortSignal.any([request.signal,AbortSignal.timeout(path.endsWith("/stream")?300000:15000)]),...(body?{body:body as BodyInit,headers:{"Content-Type":"application/json"}}:{})});
    return new Response(response.body,{status:response.status,headers:{...headers,"Content-Type":response.headers.get("Content-Type")??"application/json"}});
  } catch {return Response.json({error:"Connection interrupted. Your request may be saved; retry to check its status."},{status:503,headers});}
}
