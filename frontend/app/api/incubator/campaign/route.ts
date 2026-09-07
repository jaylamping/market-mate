import { requestProxy } from "@/lib/incubator-request-proxy";
export const dynamic = "force-dynamic";
export function GET(request: Request) { return requestProxy(request, "/campaign", "GET"); }
export function POST(request: Request) { return requestProxy(request, "/campaign", "POST"); }
