"use client";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { providersQuery, windowLabel, type Provider } from "@/lib/agents";
import { useConfigSave } from "@/lib/model-workspace";
import { useWorkspaceState } from "./WorkspaceState";
import { Inspection } from "./ui/inspection";
import { Button } from "./ui/button";
import { Input } from "./ui/input";
export function ProviderInspection() {
  const overlay = useWorkspaceState((s) => s.overlay),
    open = useWorkspaceState((s) => s.open);
  const [dirty, setDirty] = useState(false);
  const query = useQuery({
    ...providersQuery,
    enabled: overlay.kind === "provider",
    staleTime: 30_000,
  });
  const p =
    overlay.kind === "provider"
      ? query.data?.find((p) => p.id === overlay.id)
      : undefined;
  return (
    <Inspection
      open={overlay.kind === "provider"}
      onClose={() => {
        if (dirty && !window.confirm("Discard unsaved provider settings?"))
          return;
        setDirty(false);
        open({ kind: "closed" });
      }}
      title={p?.display_name ?? "Provider account"}
      description="Shared account capacity across all models."
    >
      {query.isError && (
        <p role="alert">
          Provider refresh unavailable. Saved settings and unsaved drafts are retained.{" "}
          <Button onClick={() => query.refetch()}>Retry</Button>
        </p>
      )}
      {p ? (
        <ProviderSettings key={p.id} provider={p} onDirty={setDirty} />
      ) : !query.isError ? (
        <p role="status">Loading provider…</p>
      ) : null}
    </Inspection>
  );
}
function ProviderSettings({
  provider: p,
  onDirty,
}: {
  provider: Provider;
  onDirty: (value: boolean) => void;
}) {
  const [draft, setDraft] = useState(p),
    [dirty, setDirty] = useState(false);
  const save = useConfigSave();
  return (
    <form
      className="grid gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        save.mutate(
          {
            path: `/api/providers/${p.id}`,
            body: {
              expected_revision: draft.revision,
              enabled: draft.enabled,
              windows: draft.windows.map((w) => ({
                window: w.window,
                threshold_pct: w.threshold_pct,
                pacing_slack_pct: w.pacing_slack_pct,
              })),
            },
          },
          {
            onSuccess: (revision) => {
              setDraft({ ...draft, revision });
              setDirty(false);
              onDirty(false);
            },
          },
        );
      }}
    >
      <fieldset disabled={save.isPending} className="contents">
        <div className="flex flex-wrap justify-between gap-3">
          <span className="text-sm">
            Connection: {p.state.probe_state?.replaceAll("_", " ") ?? "Unknown"}
          </span>
          <label className="flex min-h-11 items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={draft.enabled}
              onChange={(e) => {
                setDraft({ ...draft, enabled: e.target.checked });
                setDirty(true);
                onDirty(true);
              }}
            />
            Provider enabled
          </label>
        </div>
        {p.state.cooldown_until && (
          <p className="text-sm">
            Cooldown until {new Date(p.state.cooldown_until).toLocaleString()} ·{" "}
            {p.state.cooldown_reason}
          </p>
        )}
        {draft.windows.map((w, i) => {
          const usage =
            p.windows.find((current) => current.window === w.window) ?? w;
          return (
            <section key={w.window} className="rounded-lg border p-4">
              <div className="flex flex-wrap justify-between gap-3">
                <h3 className="font-medium">{windowLabel(w.window)} window</h3>
                <span className="text-sm tabular-nums">
                  {usage.status === "unknown"
                    ? "Usage unknown"
                    : `${usage.percent_used}% used · ${Math.max(0, 100 - usage.percent_used)}% remaining`}
                </span>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                {usage.source === "api"
                  ? "Provider-reported account usage"
                  : "Market Mate local request accounting"}{" "}
                ·{" "}
                {usage.observed_at
                  ? `Observed ${new Date(usage.observed_at).toLocaleString()}`
                  : "Not observed"}
              </p>
              <p className="mt-1 text-xs text-muted-foreground">
                {usage.resets_at
                  ? `Resets ${new Date(usage.resets_at).toLocaleString()}`
                  : "Reset time not reported"}
                {usage.limit_count
                  ? ` · ${usage.limit_count.toLocaleString()} request limit`
                  : ""}
              </p>
              <div className="mt-4 grid gap-4 sm:grid-cols-2">
                <label className="grid gap-2 text-sm">
                  Keep in reserve (%)
                  <Input
                    type="number"
                    min={0}
                    max={99}
                    value={100 - w.threshold_pct}
                    onChange={(e) => {
                      setDraft({
                        ...draft,
                        windows: draft.windows.map((x, n) =>
                          n === i
                            ? {
                                ...x,
                                threshold_pct: 100 - Number(e.target.value),
                              }
                            : x,
                        ),
                      });
                      setDirty(true);
                      onDirty(true);
                    }}
                  />
                </label>
                <label className="grid gap-2 text-sm">
                  Pacing headroom (%)
                  <Input
                    type="number"
                    min={0}
                    max={100}
                    value={w.pacing_slack_pct}
                    onChange={(e) => {
                      setDraft({
                        ...draft,
                        windows: draft.windows.map((x, n) =>
                          n === i
                            ? { ...x, pacing_slack_pct: Number(e.target.value) }
                            : x,
                        ),
                      });
                      setDirty(true);
                      onDirty(true);
                    }}
                  />
                </label>
              </div>
              <p className="mt-2 text-xs text-muted-foreground">
                100% headroom disables pacing. Lower values conserve allowance
                relative to elapsed window time.
              </p>
            </section>
          );
        })}
        {!draft.windows.length && (
          <p className="text-sm text-muted-foreground">
            Quota windows are not reported. No allowance is inferred.
          </p>
        )}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <a href={`/integrations#${p.id}`} className="text-sm underline">
            Manage connection and credentials
          </a>
          <Button disabled={!dirty || save.isPending}>
            Save account settings
          </Button>
        </div>
        {save.error && (
          <div role="alert" className="text-sm text-destructive">
            {save.error.message}
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setDraft(p);
                setDirty(false);
                onDirty(false);
                save.reset();
              }}
            >
              Reload saved settings
            </Button>
          </div>
        )}
        {save.isSuccess && !dirty && <p role="status">Settings saved.</p>}
      </fieldset>
    </form>
  );
}
