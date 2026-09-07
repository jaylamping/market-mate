"use client";
import { matchQuery, useIsFetching, useQueryClient, type Query, type QueryKey } from "@tanstack/react-query";
import { RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";

export function RefreshQueries({ label, queryKeys }: { label: string; queryKeys: readonly QueryKey[] }) {
  const client = useQueryClient();
  const predicate = (query: Query) => queryKeys.some(queryKey => matchQuery({ queryKey, exact: true }, query));
  const pending = useIsFetching({ predicate }) > 0;
  return <Button variant="outline" size="sm" disabled={pending} onClick={() => void client.invalidateQueries({ predicate })}><RefreshCw className={pending ? "animate-spin" : ""} aria-hidden="true"/>{pending ? "Refreshing…" : label}</Button>;
}
