"use client";
import { useIsFetching, useQueryClient } from "@tanstack/react-query";
import { RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
export function RefreshEvidence({ label = "Refresh evidence" }: { label?: string }) {
  const client = useQueryClient();
  const pending = useIsFetching({ queryKey: ["api"] }) > 0;
  return <Button variant="outline" size="sm" disabled={pending} onClick={() => void client.invalidateQueries({ queryKey: ["api"] })}><RefreshCw className={pending ? "animate-spin" : ""} aria-hidden="true"/>{pending ? "Refreshing…" : label}</Button>;
}
