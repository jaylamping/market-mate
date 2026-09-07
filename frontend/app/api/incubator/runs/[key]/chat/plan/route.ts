import {postChat} from "@/lib/incubator-chat-proxy";
export const dynamic="force-dynamic";
export async function POST(request:Request,context:{params:Promise<{key:string}>}){return postChat(request,context,"plan");}
