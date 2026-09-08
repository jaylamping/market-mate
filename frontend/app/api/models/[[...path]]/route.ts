export const dynamic = "force-dynamic";
const headers = { "Cache-Control": "no-store" };
async function forward(
  request: Request,
  path: string[],
  method: "GET" | "PUT",
) {
  const resource = path.join("/");
  if (
    !(method === "GET" ? ["", "requests"] : ["", "fallbacks"]).includes(
      resource,
    )
  )
    return Response.json({ error: "Not found" }, { status: 404, headers });
  if (method === "PUT") {
    try {
      const origin = new URL(request.headers.get("origin") ?? "");
      if (
        origin.host !== request.headers.get("host") ||
        !["localhost", "127.0.0.1", "[::1]"].includes(origin.hostname)
      )
        throw Error();
    } catch {
      return Response.json(
        { error: "Invalid origin" },
        { status: 403, headers },
      );
    }
  }
  const base = process.env.AGENT_DRIVER_URL;
  if (!base)
    return Response.json(
      { error: "Agent driver unavailable" },
      { status: 503, headers },
    );
  try {
    const response = await fetch(
      `${base}/models${resource ? "/" + resource : ""}${new URL(request.url).search}`,
      {
        method,
        cache: "no-store",
        signal: AbortSignal.timeout(12000),
        ...(method === "PUT"
          ? {
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(await request.json()),
            }
          : {}),
      },
    );
    return Response.json(await response.json(), {
      status: response.status,
      headers,
    });
  } catch {
    return Response.json(
      { error: "Agent driver unavailable" },
      { status: 503, headers },
    );
  }
}
export async function GET(
  request: Request,
  { params }: { params: Promise<{ path?: string[] }> },
) {
  return forward(request, (await params).path ?? [], "GET");
}
export async function PUT(
  request: Request,
  { params }: { params: Promise<{ path?: string[] }> },
) {
  return forward(request, (await params).path ?? [], "PUT");
}
