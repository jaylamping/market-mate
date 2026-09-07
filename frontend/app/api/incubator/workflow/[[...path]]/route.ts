import {requestProxy} from "@/lib/incubator-request-proxy";
export const dynamic="force-dynamic";
type Context={params:Promise<{path?:string[]}>};
export async function GET(request:Request,{params}:Context){const {path=[]}=await params;if(path.length===1&&path[0]==="datasets")return requestProxy(request,"/workflow/datasets","GET");if(path.length===2&&/^\d+$/.test(path[0])&&path[1]==="acquisition")return requestProxy(request,`/workflow/${path[0]}/acquisition`,"GET");if(path.length)return new Response(null,{status:404});return requestProxy(request,"/workflow","GET");}
export async function POST(request:Request,{params}:Context){const {path=[]}=await params;if(path.length!==2||!/^\d+$/.test(path[0])||!["answer","dataset","experiment-answer","retry-setup","acquisition","data-request"].includes(path[1]))return new Response(null,{status:404});return requestProxy(request,`/workflow/${path[0]}/${path[1]}`,"POST");}
