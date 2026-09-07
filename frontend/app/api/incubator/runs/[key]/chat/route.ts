import {forwardChat,postChat} from "@/lib/incubator-chat-proxy";
export const dynamic="force-dynamic";
export const runtime="nodejs";
type Context={params:Promise<{key:string}>};
export async function GET(request:Request,context:Context){return forwardChat(request,context,"GET");}
export async function POST(request:Request,context:Context){return postChat(request,context);}
