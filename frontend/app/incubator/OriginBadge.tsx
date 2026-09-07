import {Bot,User,Terminal} from "lucide-react";
import {Badge} from "@/components/ui/badge";
export function OriginBadge({origin}:{origin:"principal"|"agent"|"local_runner"}){const Icon=origin==="principal"?User:origin==="agent"?Bot:Terminal;const label=origin==="principal"?"You":origin==="agent"?"Agent":"Local runner";return <Badge variant="outline" className="gap-1 text-xs font-normal text-muted-foreground" title={`Created by ${label}`}><Icon className="size-3" aria-hidden="true"/>{label}</Badge>;}
