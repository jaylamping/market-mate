import { capacityProxy } from "@/lib/openrouter-capacity";
export const dynamic = "force-dynamic";
export function POST(request:Request){return capacityProxy(request,"POST")}
