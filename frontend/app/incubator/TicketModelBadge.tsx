import {Badge} from "@/components/ui/badge";
export function TicketModelBadge({model}:{model?:string|null}) {
 const label=model||"Model unavailable";
 return <Badge variant="outline" title={model?`Created with ${model}`:"Creating model was not recorded"} className="min-w-0 max-w-full border-primary/35 bg-primary/10 font-normal text-primary"><span className="truncate">{label}</span></Badge>;
}
