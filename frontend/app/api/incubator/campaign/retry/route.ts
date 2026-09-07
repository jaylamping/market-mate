import { requestProxy } from "@/lib/incubator-request-proxy";
export function POST(request: Request) { return requestProxy(request, "/campaign/retry", "POST"); }
