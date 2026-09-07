import type {Report} from "@/app/incubator/model";
export type ChatTurn = {
  sequence:number; request_id:string; user_text:string; author:"principal"; model:string; created_at:string;
  state:"streaming"|"completed"|"failed"|"indeterminate";
  detail:{proposal?:Report|null;reply?:string;reason?:string;response_text?:string;usage?:{cost?:number;prompt_tokens?:number;completion_tokens?:number}};
};
export type Conversation = {run_key:string;revision:number;turns:ChatTurn[];plan?:{revision:number;revisions:{revision:number;chat_sequence:number;report:Report;created_at:string}[]}};
export type ChatEvent = {type:"saved";conversation:Conversation}|{type:"preview";text:string;request_id?:string}|{type:"error";error:string};
export async function readChatStream(body:ReadableStream<Uint8Array>,onEvent:(event:ChatEvent)=>void) {
  const reader=body.getReader(),decoder=new TextDecoder();let buffer="",saved=false;
  function consume(final=false) {
    const lines=buffer.split("\n");buffer=final?"":lines.pop()??"";
    for(const raw of lines){const line=raw.replace(/\r$/,"");if(!line.startsWith("data: "))continue;
      const event=JSON.parse(line.slice(6)) as ChatEvent;
      if(event.type==="saved")saved=true;
      else if(event.type!=="preview"&&event.type!=="error")throw Error("Invalid conversation event");
      onEvent(event);
    }
  }
  try {while(true){const chunk=await reader.read();if(chunk.done)break;buffer+=decoder.decode(chunk.value,{stream:true});if(buffer.length>1_000_000)throw Error("Conversation event too large");consume();}buffer+=decoder.decode();consume(true);if(!saved)throw Error("No delivery receipt received");}
  finally {reader.releaseLock();}
}
export function chatError(reason:string) {
  const labels:Record<string,string>={
    model_not_whitelisted:"Approve this run’s model in Models before chatting.",
    preferred_provider_execution_unavailable:"This model’s preferred provider cannot execute yet. Choose OpenRouter first in Models.",
    zero_spend_budget_denied:"Chat currently requires an approved free model.",
    provider_rejected_request:"The provider rejected this message. Your question is saved.",
    invalid_or_incomplete_reply:"The reply did not match the response contract. Your question is saved.",
    provider_stream_error:"The provider stopped with an error. Your question is saved.",
  };
  return labels[reason]??reason.replaceAll("_"," ");
}
