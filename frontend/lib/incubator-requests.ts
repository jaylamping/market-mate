export type SimilarAssignment={id:string;run_key:string|null;title:string;text:string;state:string;reason:string};
export type RequestCheck={request_id:string;result:null|{complete:boolean;matches:SimilarAssignment[];issues:string[];assignments_checked?:number};run_key?:string|null};
export function parseCheck(value:unknown):RequestCheck {
 if(!value||typeof value!=="object")throw Error("Invalid similarity result");
 const v=value as RequestCheck;
 if(typeof v.request_id!=="string")throw Error("Invalid request identity");
 if(v.result===null)return v;
 const r=v.result;
 if(!r||typeof r.complete!=="boolean"||!Array.isArray(r.matches)||!Array.isArray(r.issues)||r.issues.some(i=>typeof i!=="string"))throw Error("Invalid similarity result");
 for(const m of r.matches)if(!m||[m.id,m.title,m.text,m.state,m.reason].some(s=>typeof s!=="string")||(m.run_key!==null&&typeof m.run_key!=="string"))throw Error("Invalid similar ticket");
 return v;
}
export function needsWarning(check:RequestCheck){return !!check.result&&(!check.result.complete||check.result.matches.length>0);}
export function requestError(code:string):string {
 const messages:Record<string,string>={
  default_model_not_configured:"Choose a default model in Models, or select an approved model for this ticket.",
  model_not_whitelisted:"This model is no longer approved. Refresh the model choices.",
  zero_spend_budget_denied:"This operation requires an approved free model.",
  history_changed_recheck:"Tickets changed while you reviewed this request. Check again to review the latest matches.",
  warning_confirmation_required:"Review the similarity warning before creating the ticket.",
  provider_http_error:"The default model provider could not complete the similarity check.",
  similarity_check_busy:"Other similarity checks are running. Try again shortly.",
  check_pending:"The similarity check is still running. Check its status again shortly.",
  invalid_request:"Enter a title (up to 240 bytes) and request (up to 6,000 bytes).",
 };
 return messages[code]??code.replaceAll("_"," ");
}
export async function assignmentRequest(path:string,body?:unknown):Promise<unknown> {
 const response=await fetch(`/api/incubator/assignments${path}`,{method:body?"POST":"GET",headers:body?{"Content-Type":"application/json"}:undefined,body:body?JSON.stringify(body):undefined,cache:"no-store"});
 const value=await response.json();if(!response.ok)throw Error(value.error??"Ticket request failed");return value;
}
