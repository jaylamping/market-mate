"use client";
import { useState, useImperativeHandle, type Ref } from "react";
import { ArrowUp, X } from "lucide-react";
import { type Agent } from "@/lib/agents";
import {
  modelOrder,
  useConfigSave,
  type CatalogModel,
} from "@/lib/model-workspace";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export type PersonaEditorHandle = { assignModels: (ids: string[]) => void };

export function PersonaEditor({
  agent,
  models,
  onSaved,
  onDirty,
  ref,
}: {
  agent: Agent;
  models: CatalogModel[];
  onSaved: () => void;
  onDirty: (dirty: boolean) => void;
  ref: Ref<PersonaEditorHandle>;
}) {
  const [draft, setDraft] = useState(agent),
    [dirty, setDirty] = useState(false);
  const save = useConfigSave(onSaved);
  const update = (patch: Partial<Agent>) => {
    setDraft({ ...draft, ...patch });
    setDirty(true);
    onDirty(true);
    save.reset();
  };
  const order = modelOrder(draft);
  const setOrder = (order: string[]) =>
    update({
      spec: {
        ...draft.spec,
        model_order: order,
        use_global_fallbacks: draft.spec.use_global_fallbacks === true,
      },
    });
  useImperativeHandle(ref, () => ({
    assignModels: (ids) => {
      if (!save.isPending) setOrder([...new Set([...order, ...ids])]);
    },
  }));
  const textSpec = (key: string) =>
    typeof draft.spec[key] === "string" ? String(draft.spec[key]) : "";
  return (
    <form
      className="grid gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        save.mutate(
          {
            path: `/api/agents/${draft.id}`,
            body: {
              expected_revision: draft.revision,
              name: draft.name,
              enabled: draft.enabled,
              priority: draft.priority,
              hold_at_pct: draft.hold_at_pct,
              spec: draft.spec,
              routes: draft.routes,
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
        <div className="grid gap-6 md:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
          <div className="grid content-start gap-4">
            <label className="grid gap-2 text-sm">
              Persona name
              <Input
                required
                maxLength={80}
                value={draft.name}
                onChange={(e) => update({ name: e.target.value })}
              />
            </label>
            <details>
              <summary className="cursor-pointer text-sm font-medium">
                Instructions & allocation
              </summary>
              <div className="mt-3 grid gap-4">
                <label className="grid gap-2 text-sm">
                  Specialty
                  <Input
                    value={textSpec("specialty")}
                    onChange={(e) =>
                      update({
                        spec: { ...draft.spec, specialty: e.target.value },
                      })
                    }
                    placeholder="Expertise this persona brings"
                  />
                </label>

                <label className="grid gap-2 text-sm">
                  Persona instructions
                  <textarea
                    className="min-h-28 rounded-md border bg-background p-3"
                    value={textSpec("system")}
                    onChange={(e) =>
                      update({
                        spec: { ...draft.spec, system: e.target.value },
                      })
                    }
                  />
                </label>
                <p className="text-xs text-muted-foreground">
                  Instructions are saved with the persona. Existing workflow
                  workers retain their built-in prompts and response contracts
                  until persona selection is integrated.
                </p>
                <label className="grid gap-2 text-sm">
                  Priority (display order)
                  <Input
                    type="number"
                    min={1}
                    max={1000}
                    value={draft.priority}
                    onChange={(e) =>
                      update({ priority: Number(e.target.value) })
                    }
                  />
                </label>
                <label className="grid gap-2 text-sm">
                  Hold when provider usage reaches (%)
                  <Input
                    type="number"
                    min={1}
                    max={100}
                    value={draft.hold_at_pct}
                    onChange={(e) =>
                      update({ hold_at_pct: Number(e.target.value) })
                    }
                  />
                </label>
              </div>
            </details>
            <label className="flex min-h-11 items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={draft.enabled}
                onChange={(e) => update({ enabled: e.target.checked })}
              />
              Enabled for routing
            </label>
          </div>
          <div>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h3 className="font-medium">Model hierarchy</h3>
              <span className="text-xs text-muted-foreground">
                Provider independent
              </span>
            </div>
            {!("model_order" in draft.spec) && (
              <p className="mt-3 rounded-md border p-3 text-xs text-muted-foreground">
                This persona uses {draft.routes.length} existing provider
                routes. Assigning a model switches it to the new model hierarchy
                when saved. Pinned workflow requests continue to require their
                exact model.
              </p>
            )}
            <ol className="my-3 divide-y">
              {order.map((id, i) => (
                <li key={id} className="flex items-center gap-3 py-2">
                  <span className="text-sm text-muted-foreground">{i + 1}</span>
                  <span className="min-w-0 flex-1 break-all text-sm">
                    {models.find((m) => m.id === id)?.name ?? id}
                  </span>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    aria-label={`Move ${id} earlier`}
                    disabled={i === 0}
                    onClick={() => {
                      const next = [...order];
                      [next[i - 1], next[i]] = [next[i], next[i - 1]];
                      setOrder(next);
                    }}
                  >
                    <ArrowUp />
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    aria-label={`Remove ${id}`}
                    onClick={() => setOrder(order.filter((x) => x !== id))}
                  >
                    <X />
                  </Button>
                </li>
              ))}
            </ol>
            {!order.length && (
              <p className="my-4 text-sm text-muted-foreground">
                Select configured models in the catalog below to build this
                persona’s order.
              </p>
            )}
            <label className="mt-4 flex min-h-11 items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={draft.spec.use_global_fallbacks === true}
                onChange={(e) =>
                  update({
                    spec: {
                      ...draft.spec,
                      model_order: order,
                      use_global_fallbacks: e.target.checked,
                    },
                  })
                }
              />
              Use global fallbacks after this list
            </label>
            <p className="mt-2 text-xs text-muted-foreground">
              Saving enables these models for this persona within existing
              provider and spending limits.
            </p>
          </div>
        </div>
        <footer className="flex flex-wrap items-center gap-3 border-t pt-4">
          <Button disabled={save.isPending || !dirty}>Save persona</Button>
          <Button
            type="button"
            variant="outline"
            disabled={save.isPending}
            onClick={() => {
              setDraft(agent);
              setDirty(false);
              onDirty(false);
              save.reset();
            }}
          >
            Reload saved version
          </Button>
          <span className="text-xs text-muted-foreground">
            {dirty ? "Unsaved changes" : `Revision ${draft.revision}`} ·{" "}
            {agent.current.reason?.replaceAll("_", " ") ?? agent.current.status}
          </span>
        </footer>
        {save.error && (
          <p role="alert" className="text-sm text-destructive">
            {save.error.message}
          </p>
        )}
        {save.isSuccess && (
          <p role="status" className="text-sm">
            Persona saved.
          </p>
        )}
      </fieldset>
    </form>
  );
}
