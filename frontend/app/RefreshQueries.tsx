"use client";
import { matchQuery, useIsFetching, useQueryClient, type Query, type QueryKey } from "@tanstack/react-query";
import { RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";

export function RefreshQueries({ label, queryKeys, iconOnly = false }: { label: string; queryKeys: readonly QueryKey[]; iconOnly?: boolean }) {
  const client = useQueryClient();
  const predicate = (query: Query) => queryKeys.some(queryKey => matchQuery({ queryKey, exact: true }, query));
  const pending = useIsFetching({ predicate }) > 0;
  return <Button variant="outline" size={iconOnly ? "icon" : "sm"} className={iconOnly ? "min-h-11 min-w-11" : undefined} aria-label={pending ? "Refreshing…" : label} title={label} disabled={pending} onClick={() => void client.invalidateQueries({ predicate })}><RefreshCw className={pending ? "animate-spin" : ""} aria-hidden="true"/>{!iconOnly && (pending ? "Refreshing…" : label)}</Button>;
}
