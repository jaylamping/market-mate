"use client";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { type Provider } from "@/lib/agents";
import {
  requestsQuery,
  workspaceQuery,
  modelPolicyOfferings,
  useConfigSave,
  type CatalogModel,
} from "@/lib/model-workspace";
import { useWorkspaceState } from "@/components/WorkspaceState";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export function ModelSheet({
  model,
  providers,
  catalog,
  onDirty,
}: {
  model: CatalogModel;
  providers: Provider[];
  catalog: CatalogModel[];
  onDirty: (dirty: boolean) => void;
}) {
  const [draft, setDraft] = useState(model),
    [dirty, setDirty] = useState(false),
    [alias, setAlias] = useState("");
  const tab = useWorkspaceState((s) => s.modelTab),
    setTab = useWorkspaceState((s) => s.setModelTab);
  const requests = useQuery({
    ...requestsQuery(model.id),
    enabled: tab === "requests" || tab === "usage",
  });
  const save = useConfigSave();
  const workspace = useQuery(workspaceQuery);
  const update = (patch: Partial<CatalogModel>) => {
    setDraft({ ...draft, ...patch });
    setDirty(true);
    onDirty(true);
    save.reset();
  };
  return (
    <Tabs value={tab} onValueChange={setTab}>
      <TabsList variant="line" className="sticky top-0 z-10 bg-background">
        <TabsTrigger value="providers">Providers</TabsTrigger>
        <TabsTrigger value="usage">Usage</TabsTrigger>
        <TabsTrigger value="requests">Requests</TabsTrigger>
        <TabsTrigger value="details">Details</TabsTrigger>
      </TabsList>
      <TabsContent value="providers" className="mt-4">
        <form
          className="grid gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            save.mutate(
              {
                path: `/api/models?id=${encodeURIComponent(model.id)}`,
                body: {
                  expected_revision: draft.revision,
                  name: draft.name,
                  offerings: modelPolicyOfferings(draft, providers, workspace.data?.models.find((m) => m.id === model.id)),
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
            <p className="text-sm text-muted-foreground">
              Enable providers for this model. Lower priority numbers run first;
              equal priorities balance by weight using recent request counts.
            </p>
            {draft.offerings.map((o, i) => {
              const p = providers.find((p) => p.id === o.provider_id);
              const patch = (value: Partial<typeof o>) =>
                update({
                  offerings: draft.offerings.map((old, n) =>
                    n === i ? { ...old, ...value } : old,
                  ),
                });
              return (
                <fieldset
                  disabled={p?.kind === "paid"}
                  key={`${o.provider_id}:${o.model_id}`}
                  className="rounded-lg border p-4"
                >
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div>
                      <h3 className="font-medium">
                        {p?.display_name ?? o.provider_id}
                      </h3>
                      <p className="mt-1 break-all text-xs text-muted-foreground">
                        {o.model_id}
                      </p>
                    </div>
                    <label className="flex min-h-11 items-center gap-2 text-sm">
                      <input
                        type="checkbox"
                        disabled={p?.kind === "paid"}
                        checked={o.enabled}
                        onChange={(e) => patch({ enabled: e.target.checked })}
                      />
                      Use provider
                    </label>
                  </div>
                  <p className="mt-2 text-xs text-muted-foreground">
                    {!p?.enabled
                      ? "Provider disabled account-wide"
                      : p.state.cooldown_until &&
                          Date.parse(p.state.cooldown_until) > Date.now()
                        ? `Cooldown until ${new Date(p.state.cooldown_until).toLocaleString()}`
                        : (p.state.probe_state?.replaceAll("_", " ") ??
                          "Connection unknown")}
                  </p>
                  <div className="mt-4 grid gap-3 sm:grid-cols-3">
                    <label className="grid gap-2 text-xs">
                      Priority
                      <Input
                        required
                        type="number"
                        min={1}
                        max={1000}
                        value={o.priority}
                        onChange={(e) =>
                          patch({ priority: Number(e.target.value) })
                        }
                      />
                    </label>
                    <label className="grid gap-2 text-xs">
                      Balancing weight
                      <Input
                        required
                        type="number"
                        min={1}
                        max={100}
                        value={o.weight}
                        onChange={(e) =>
                          patch({ weight: Number(e.target.value) })
                        }
                      />
                    </label>
                    <label className="grid gap-2 text-xs">
                      Requests / rolling 24h
                      <Input
                        type="number"
                        min={1}
                        value={o.requests_per_day ?? ""}
                        placeholder="No extra cap"
                        onChange={(e) =>
                          patch({
                            requests_per_day: e.target.value
                              ? Number(e.target.value)
                              : null,
                          })
                        }
                      />
                    </label>
                  </div>
                  {p?.kind === "paid" && (
                    <p className="mt-3 text-xs text-muted-foreground">
                      Paid routing is read-only in this POC. Existing paid
                      workflows keep their authorization; this save does not
                      import or modify their paid routes. New paid overage
                      requires bounded cost reservation support.
                    </p>
                  )}
                </fieldset>
              );
            })}
            <details className="rounded-lg border p-3">
              <summary className="cursor-pointer text-sm">
                Map another provider’s model ID
              </summary>
              <p className="my-3 text-xs text-muted-foreground">
                Only link an offering if it is the same underlying model and
                version. Names alone are not sufficient.
              </p>
              <select
                aria-label="Additional model offering"
                className="workspace-select w-full"
                value={alias}
                onChange={(e) => setAlias(e.target.value)}
              >
                <option value="">Choose an unmapped offering</option>
                {catalog
                  .filter((m) => m.revision === 0)
                  .flatMap((m) => m.offerings)
                  .filter(
                    (o) =>
                      !draft.offerings.some(
                        (x) =>
                          x.provider_id === o.provider_id &&
                          x.model_id === o.model_id,
                      ),
                  )
                  .map((o) => (
                    <option
                      key={`${o.provider_id}|${o.model_id}`}
                      value={`${o.provider_id}|${o.model_id}`}
                    >
                      {o.provider_id} · {o.model_id}
                    </option>
                  ))}
              </select>
              <Button
                type="button"
                className="mt-3"
                variant="outline"
                disabled={!alias}
                onClick={() => {
                  const match = catalog
                    .flatMap((m) => m.offerings)
                    .find((o) => `${o.provider_id}|${o.model_id}` === alias);
                  if (match)
                    update({
                      offerings: [
                        ...draft.offerings,
                        { ...match, enabled: false },
                      ],
                    });
                  setAlias("");
                }}
              >
                Link offering
              </Button>
            </details>
            <div className="flex flex-wrap gap-3">
              <Button disabled={save.isPending || !dirty}>
                Save model routing
              </Button>
              <Button
                variant="outline"
                type="button"
                onClick={() => {
                  setDraft(model);
                  setDirty(false);
                  onDirty(false);
                  save.reset();
                }}
              >
                Reload saved version
              </Button>
            </div>
            {save.error && (
              <p role="alert" className="text-sm text-destructive">
                {save.error.message}
              </p>
            )}
            {save.isSuccess && <p role="status">Model routing saved.</p>}
          </fieldset>
        </form>
      </TabsContent>
      <TabsContent value="usage" className="mt-4">
        <h3 className="font-medium">Market Mate recorded usage</h3>
        <p className="mt-2 text-sm text-muted-foreground">
          Computed from the latest 200 recorded attempts, not your entire
          provider account.
        </p>
        {requests.isPending ? (
          <p role="status">Loading usage…</p>
        ) : requests.isError ? (
          <p role="alert">Usage history unavailable.</p>
        ) : (
          <dl className="mt-5 grid grid-cols-2 gap-5">
            <div>
              <dt className="text-xs text-muted-foreground">
                Recorded attempts
              </dt>
              <dd className="text-xl tabular-nums">{requests.data.length}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">Completed</dt>
              <dd className="text-xl tabular-nums">
                {requests.data.filter((r) => r.state === "completed").length}
              </dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">Known cost</dt>
              <dd>
                $
                {(
                  requests.data.reduce(
                    (sum, r) => sum + (r.cost_nanos ?? 0),
                    0,
                  ) / 1e9
                ).toFixed(4)}
              </dd>
              <p className="text-xs text-muted-foreground">
                {requests.data.filter((r) => r.cost_nanos === null).length}{" "}
                attempts without reported cost
              </p>
            </div>
          </dl>
        )}
      </TabsContent>
      <TabsContent value="requests" className="mt-4">
        <p className="mb-4 text-sm text-muted-foreground">
          Latest 200 driver attempts. Older worker history is not inferred.
        </p>
        {requests.isPending ? (
          <p role="status">Loading requests…</p>
        ) : requests.isError ? (
          <p role="alert">Request history unavailable.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Time</TableHead>
                <TableHead>Persona / provider</TableHead>
                <TableHead>Outcome</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {requests.data.map((r) => (
                <TableRow key={r.attempt_id}>
                  <TableCell className="whitespace-nowrap">
                    {new Date(r.receipt_time).toLocaleString()}
                  </TableCell>
                  <TableCell>
                    {r.agent_id}
                    <span className="block text-xs text-muted-foreground">
                      {r.provider_id}
                    </span>
                  </TableCell>
                  <TableCell>
                    <details>
                      <summary>{r.state}</summary>
                      <dl className="max-w-72 break-all text-xs">
                        <dt>Attempt</dt>
                        <dd>{r.attempt_id}</dd>
                        <dt>Intent</dt>
                        <dd>{r.intent_id}</dd>
                        <dt>HTTP status</dt>
                        <dd>{r.http_status ?? "Not reported"}</dd>
                        <dt>Reported cost</dt>
                        <dd>
                          {r.cost_nanos === null
                            ? "Not reported"
                            : `$${(r.cost_nanos / 1e9).toFixed(6)}`}
                        </dd>
                        <dt>Finished</dt>
                        <dd>
                          {r.finished_at
                            ? new Date(r.finished_at).toLocaleString()
                            : "Not recorded"}
                        </dd>
                        <dt>Previous attempt</dt>
                        <dd>{r.parent_attempt_id ?? "None"}</dd>
                      </dl>
                    </details>
                  </TableCell>
                </TableRow>
              ))}
              {!requests.data.length && (
                <TableRow>
                  <TableCell colSpan={3}>
                    No recorded requests for this model.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        )}
      </TabsContent>
      <TabsContent value="details" className="mt-4">
        <dl className="grid gap-3 text-sm">
          <dt className="text-muted-foreground">Canonical identity</dt>
          <dd className="break-all">{model.id}</dd>
          <dt className="text-muted-foreground">Context reported by catalog</dt>
          <dd>{model.context?.toLocaleString() ?? "Not reported"}</dd>
          <dt className="text-muted-foreground">Configuration revision</dt>
          <dd>{model.revision || "Not configured"}</dd>
        </dl>
      </TabsContent>
    </Tabs>
  );
}
