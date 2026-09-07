import {forwardChat} from "@/lib/incubator-chat-proxy";
export const dynamic="force-dynamic";
export async function GET(request:Request,context:{params:Promise<{key:string}>}){return forwardChat(request,context,"GET","stream");}
