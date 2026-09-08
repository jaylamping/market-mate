"use client";
import { useEffect, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  usageSummaryQuery,
  windowLabel,
  type ProviderWindow,
} from "@/lib/agents";
import { useWorkspaceState } from "./WorkspaceState";
import { ProviderInspection } from "./ProviderInspection";
export function remainingLabel(w: ProviderWindow, now = Date.now()) {
  if (w.status === "unknown" || !w.observed_at) return "Unknown";
  if (w.source === "api" && now - Date.parse(w.observed_at) > 1800000)
    return "Stale";
  return `${Math.max(0, Math.min(100, 100 - w.percent_used)).toLocaleString(undefined, { maximumFractionDigits: 1 })}%`;
}
export function UsageWidget({ preview = false }: { preview?: boolean }) {
  const query = useQuery({ ...usageSummaryQuery, staleTime: 30_000 });
  const open = useWorkspaceState((s) => s.open),
    ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const observer = new ResizeObserver(() =>
      document.documentElement.style.setProperty(
        "--provider-rail-height",
        `${element.getBoundingClientRect().height}px`,
      ),
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return (
    <>
      <aside
        ref={ref}
        className="provider-capacity-rail"
        aria-label="Provider capacity"
      >
        <div className="flex justify-between gap-3 px-4 pt-2 text-xs text-muted-foreground">
          <span>
            {preview
              ? "Isolated POC · demo catalog · remaining allowance"
              : "Remaining allowance"}
          </span>
          <a href="/integrations">Integrations</a>
        </div>
        {query.isError ? (
          <p role="alert" className="p-3 text-sm">
            Usage unavailable.{" "}
            <button onClick={() => query.refetch()} className="underline">
              Retry
            </button>
          </p>
        ) : !query.data ? (
          <p role="status" className="p-3 text-sm">
            Loading capacity…
          </p>
        ) : (
          <div className="grid grid-cols-3 xl:grid-cols-6">
            {query.data.providers.map((p) => (
              <button
                key={p.id}
                onClick={() => open({ kind: "provider", id: p.id })}
                className="min-w-0 border-r px-4 py-3 text-left hover:bg-muted"
              >
                <span className="block truncate text-xs font-medium">
                  {p.display_name}
                </span>
                <span className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs tabular-nums">
                  {p.windows.length ? (
                    p.windows.map((w) => (
                      <span
                        key={w.window}
                        className={
                          w.over_threshold
                            ? "text-destructive"
                            : "text-muted-foreground"
                        }
                      >
                        {windowLabel(w.window)}
                        {w.source === "local" ? " local" : ""}{" "}
                        <strong className="font-medium">
                          {remainingLabel(w)}
                        </strong>
                      </span>
                    ))
                  ) : (
                    <span className="text-muted-foreground">
                      Usage not reported
                    </span>
                  )}
                </span>
                {!p.enabled && <span className="text-xs">Disabled</span>}
              </button>
            ))}
          </div>
        )}
      </aside>
      <ProviderInspection />
    </>
  );
}
