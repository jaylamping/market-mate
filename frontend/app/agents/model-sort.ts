export type SortKey = "selected" | "name" | "input" | "output" | "context" | "date";
export type Sort = { key: SortKey; direction: "asc" | "desc" };
export type SortableModel = { provider: "openrouter" | "cursor"; id: string; name: string; pricing?: Record<string,unknown>; context?: number; created?: number };
export function sortModels<T extends SortableModel>(rows: T[], sort: Sort, saved: Record<"openrouter"|"cursor", readonly string[]>): T[] {
  const value = (r:T): string | number | undefined => {
    switch(sort.key) {
      case "selected": return Number(saved[r.provider].includes(r.id));
      case "name": return r.name;
      case "input": return r.pricing ? Number(r.pricing.prompt) : undefined;
      case "output": return r.pricing ? Number(r.pricing.completion) : undefined;
      case "context": return r.context;
      case "date": return r.created;
    }
  };
  return [...rows].sort((a,b)=>{
    const av=value(a),bv=value(b);
    if (av === undefined && bv !== undefined) return 1;
    if (bv === undefined && av !== undefined) return -1;
    const delta=typeof av==="string"&&typeof bv==="string"?av.localeCompare(bv):typeof av==="number"&&typeof bv==="number"?av-bv:0;
    return delta*(sort.direction==="asc"?1:-1)||a.name.localeCompare(b.name)||a.provider.localeCompare(b.provider)||a.id.localeCompare(b.id);
  });
}
export function catalogDate(created?: number) { return created === undefined ? "—" : new Date(created*1000).toLocaleDateString("en-US",{year:"numeric",month:"short",day:"numeric",timeZone:"UTC"}); }
