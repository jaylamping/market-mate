import { capacityProxy } from "@/lib/openrouter-capacity";
export const dynamic = "force-dynamic";
export function GET(request:Request){return capacityProxy(request,"GET")}
export function PUT(request:Request){return capacityProxy(request,"PUT")}
