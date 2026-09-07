const headers = { "Cache-Control": "no-store", "X-Accel-Buffering": "no" };
type Context = { params: Promise<{ key: string }> };
export async function forwardChat(request: Request, context: Context, method: "GET" | "POST", suffix:""|"plan"|"stream"="") {
  const { key } = await context.params;
  if (!/^[a-zA-Z0-9_-]{1,96}$/.test(key)) return Response.json({ error: "Invalid run" }, { status: 400 });
  const base = process.env.INCUBATOR_CHAT_URL;
  if (!base) return Response.json({ error: "Conversation service unavailable" }, { status: 503 });
  try {
    let body: string | undefined;
    if (method === "POST") {
      const reader=request.body?.getReader();
      if (!reader) return Response.json({error:"Message required"},{status:400});
      const chunks:Uint8Array[]=[];let size=0;
      while (true) { const chunk=await reader.read();if(chunk.done)break;size+=chunk.value.length;if(size>10000){await reader.cancel();return Response.json({error:"Message too long"},{status:413});}chunks.push(chunk.value); }
      body=new TextDecoder().decode(Buffer.concat(chunks));
    }
    const response = await fetch(`${base}/runs/${key}/chat${suffix?`/${suffix}`:""}`, {
      method, cache: "no-store", signal: AbortSignal.timeout(suffix==="stream"?300_000:method === "POST" ? 180_000 : 10_000),
      ...(body ? { headers: { "Content-Type": "application/json" }, body } : {}),
    });
    return new Response(response.body, { status: response.status, headers: { ...headers, "Content-Type": response.headers.get("Content-Type") ?? "application/json" } });
  } catch { return Response.json({ error: "Connection interrupted. Reload the conversation to check delivery." }, { status: 503, headers }); }
}
export async function postChat(request:Request, context:Context, suffix:""|"plan"|"stream"="") {
  const origin = request.headers.get("origin"), host = request.headers.get("host");
  try {
    const url = new URL(origin ?? "");
    if (url.host !== host || !["http:","https:"].includes(url.protocol) || !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) throw Error();
  } catch { return Response.json({ error: "Local same-origin request required" }, { status: 403 }); }
  return forwardChat(request,context,"POST",suffix);
}
