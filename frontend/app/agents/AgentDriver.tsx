"use client";
import { useMemo, useState, useRef } from "react";
import { useQueries, useQuery, useIsMutating } from "@tanstack/react-query";
import {
  createColumnHelper,
  createFilteredRowModel,
  createPaginatedRowModel,
  createSortedRowModel,
  columnVisibilityFeature,
  columnFilteringFeature,
  globalFilteringFeature,
  rowPaginationFeature,
  rowSelectionFeature,
  rowSortingFeature,
  sortFns,
  filterFns,
  tableFeatures,
  useTable,
} from "@tanstack/react-table";
import {
  ArrowDownUp,
  ChevronLeft,
  ChevronRight,
  Columns3,
  Plus,
} from "lucide-react";
import {
  agentsQuery,
  providersQuery,
  type Agent,
  type ProviderModel,
} from "@/lib/agents";
import {
  catalogQuery,
  combineCatalogs,
  workspaceQuery,
  useConfigSave,
  type CatalogModel,
  type ModelWorkspace,
} from "@/lib/model-workspace";
import { useWorkspaceState } from "@/components/WorkspaceState";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Inspection } from "@/components/ui/inspection";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { PersonaEditor, type PersonaEditorHandle } from "./PersonaEditor";
import { ModelSheet } from "./ModelSheet";

const features = tableFeatures({
  columnVisibilityFeature,
  columnFilteringFeature,
  globalFilteringFeature,
  rowPaginationFeature,
  rowSelectionFeature,
  rowSortingFeature,
  filteredRowModel: createFilteredRowModel(),
  paginatedRowModel: createPaginatedRowModel(),
  sortedRowModel: createSortedRowModel(),
  sortFns,
  filterFns,
});
const helper = createColumnHelper<typeof features, CatalogModel>();
const empty: Agent[] = [];
const combineResults = (
  results: {
    data: ProviderModel[] | undefined;
    isError: boolean;
    isPending: boolean;
  }[],
) =>
  results.map((r) => ({
    models: r.data ?? [],
    failed: r.isError,
    pending: r.isPending,
  }));

export function AgentDriver() {
  const configSaving = useIsMutating({ mutationKey: ["configuration"] }) > 0;
  const agents = useQuery(agentsQuery),
    providers = useQuery(providersQuery),
    workspace = useQuery(workspaceQuery);
  const catalogs = useQueries({
    queries: (providers.data ?? []).map((p) => catalogQuery(p.id)),
    combine: combineResults,
  });
  const models = useMemo(
    () =>
      combineCatalogs(
        (providers.data ?? []).map((provider, i) => ({
          provider,
          models: catalogs[i]?.models ?? [],
        })),
        workspace.data?.models ?? [],
        agents.data ?? empty,
      ),
    [providers.data, catalogs, workspace.data, agents.data],
  );
  const selected = useWorkspaceState((s) => s.persona),
    select = useWorkspaceState((s) => s.setPersona),
    overlay = useWorkspaceState((s) => s.overlay),
    open = useWorkspaceState((s) => s.open);
  const [newAgent, setNewAgent] = useState<Agent | null>(null),
    [personaDirty, setPersonaDirty] = useState(false),
    [modelDirty, setModelDirty] = useState(false);
  const personaEditor = useRef<PersonaEditorHandle>(null);
  const agent =
    newAgent ?? agents.data?.find((a) => a.id === selected) ?? agents.data?.[0];
  const model =
    overlay.kind === "model"
      ? models.find((m) => m.id === overlay.id)
      : undefined;
  function changePersona(id: string) {
    if (personaDirty && !window.confirm("Discard unsaved persona changes?"))
      return;
    setPersonaDirty(false);
    setNewAgent(null);
    select(id);
  }
  function createPersona() {
    if (personaDirty && !window.confirm("Discard unsaved persona changes?"))
      return;
    const id = `persona_${crypto.randomUUID().replaceAll("-", "").slice(0, 24)}`;
    setNewAgent({
      id,
      name: "New specialist",
      spec: { model_order: [], use_global_fallbacks: false },
      priority: 100,
      hold_at_pct: 100,
      enabled: false,
      revision: 0,
      updated_at: "",
      routes: [],
      current: { status: "blocked", reason: "not_saved" },
    });
    select(id);
    setPersonaDirty(false);
  }
  if (agents.isPending || providers.isPending || workspace.isPending)
    return <p role="status">Loading the agent workspace…</p>;
  if (!agents.data || !providers.data || !workspace.data)
    return (
      <div role="alert" className="workspace-panel p-6">
        <h2 className="font-medium">Agent workspace unavailable</h2>
        <p className="my-3 text-sm">
          The workspace needs the updated agent-driver API. Saved configuration
          has not been changed.
        </p>
        <Button
          variant="outline"
          onClick={() => {
            agents.refetch();
            providers.refetch();
            workspace.refetch();
          }}
        >
          Retry
        </Button>
      </div>
    );
  return (
    <div className="agents-workspace">
      {(agents.isError || providers.isError || workspace.isError) && (
        <p role="alert" className="text-sm text-destructive">
          Configuration refresh failed. Showing the last saved configuration;
          unsaved drafts are retained. Retry the refresh before reconciling a failed save.
          <Button variant="outline" onClick={() => {
            agents.refetch();
            providers.refetch();
            workspace.refetch();
          }}>Retry refresh</Button>
        </p>
      )}
      <section className="workspace-panel p-5">
        <div className="mb-5 flex flex-wrap items-center justify-between gap-4">
          <div className="flex flex-wrap items-center gap-3">
            <h2 className="text-base font-semibold">Personas</h2>
            <select
              disabled={configSaving}
              aria-label="Selected persona"
              value={agent?.id ?? ""}
              onChange={(e) => changePersona(e.target.value)}
            >
              {agents.data.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name}
                  {a.enabled ? "" : " · disabled"}
                </option>
              ))}
              {newAgent && <option value={newAgent.id}>New specialist</option>}
            </select>
          </div>
          <Button
            variant="outline"
            disabled={configSaving}
            onClick={createPersona}
          >
            <Plus />
            New persona
          </Button>
        </div>
        {agent ? (
          <PersonaEditor
            key={agent.id}
            agent={agent}
            models={models}
            ref={personaEditor}
            onDirty={setPersonaDirty}
            onSaved={() => {
              if (newAgent) {
                setNewAgent(null);
              }
            }}
          />
        ) : (
          <p>Create a persona to get started.</p>
        )}
      </section>
      <section>
        <div className="mb-3 flex flex-wrap justify-between gap-3">
          <h2 className="text-base font-semibold">
            Models{" "}
            <span className="ml-2 text-sm font-normal text-muted-foreground">
              {models.length}
            </span>
          </h2>
          <span className="text-xs text-muted-foreground">
            One row per identity · providers inside
          </span>
        </div>
        {catalogs.some((c) => c.pending) && (
          <p role="status" className="mb-3 text-sm text-muted-foreground">
            Loading provider catalogs…
          </p>
        )}
        {catalogs.some((c) => c.failed) && (
          <p role="alert" className="mb-3 text-sm text-[var(--warning)]">
            Some catalogs are unavailable. Saved models and policies are
            retained.
          </p>
        )}
        <ModelTable
          models={models}
          disabled={configSaving}
          onSelected={(ids) => {
            personaEditor.current?.assignModels(ids);
          }}
          onOpen={(id) => open({ kind: "model", id })}
        />
      </section>
      <FallbackEditor workspace={workspace.data} models={models} />
      <Inspection
        open={overlay.kind === "model"}
        side
        title={model?.name ?? "Model"}
        description="Model-specific routing, usage, and request history."
        onClose={() => {
          if (
            modelDirty &&
            !window.confirm("Discard unsaved model routing changes?")
          )
            return;
          setModelDirty(false);
          open({ kind: "closed" });
        }}
      >
        {model && (
          <ModelSheet
            key={model.id}
            model={model}
            providers={providers.data}
            catalog={models}
            onDirty={setModelDirty}
          />
        )}
      </Inspection>
    </div>
  );
}
function ModelTable({
  models,
  onSelected,
  onOpen,
  disabled,
}: {
  models: CatalogModel[];
  disabled: boolean;
  onSelected: (ids: string[]) => void;
  onOpen: (id: string) => void;
}) {
  const search = useWorkspaceState((s) => s.search),
    setSearch = useWorkspaceState((s) => s.setSearch);
  const columns = useMemo(
    () =>
      helper.columns([
        helper.display({
          id: "select",
          header: ({ table }) => (
            <label className="flex size-11 items-center justify-center">
              <input
                aria-label="Select page"
                type="checkbox"
                checked={table.getIsAllPageRowsSelected()}
                onChange={table.getToggleAllPageRowsSelectedHandler()}
              />
            </label>
          ),
          cell: ({ row }) => (
            <label className="flex size-11 items-center justify-center">
              <input
                aria-label={`Select ${row.original.name}`}
                type="checkbox"
                disabled={row.original.revision === 0}
                checked={row.getIsSelected()}
                onChange={row.getToggleSelectedHandler()}
              />
            </label>
          ),
          enableHiding: false,
        }),
        helper.accessor("name", {
          header: "Model",
          cell: ({ row }) => (
            <button
              className="py-2 text-left font-medium hover:underline"
              onClick={() => onOpen(row.original.id)}
            >
              {row.original.name}
            </button>
          ),
          enableHiding: false,
        }),
        helper.accessor(
          (row) => row.offerings.map((o) => o.provider_id).join(" · "),
          { id: "providers", header: "Providers" },
        ),
        helper.accessor(
          (row) =>
            row.revision
              ? row.offerings.some((o) => o.enabled)
                ? "Configured"
                : "Disabled"
              : "Not configured",
          {
            id: "routing",
            header: "Routing",
            cell: ({ getValue }) => (
              <Badge variant="outline">{getValue()}</Badge>
            ),
          },
        ),
        helper.accessor("context", {
          header: "Context",
          cell: ({ getValue }) => getValue()?.toLocaleString() ?? "—",
        }),
      ]),
    [onOpen],
  );
  const table = useTable({
    features,
    columns,
    data: models,
    getRowId: (row) => row.id,
    enableRowSelection: (row) => row.original.revision > 0,
    state: { globalFilter: search },
    onGlobalFilterChange: (value) =>
      setSearch(typeof value === "function" ? value(search) : value),
    initialState: { pagination: { pageIndex: 0, pageSize: 10 } },
  });
  const selected = table.getSelectedRowModel().rows;
  return (
    <div className="overflow-hidden rounded-xl border bg-card">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b p-4">
        <Input
          className="w-full sm:max-w-72"
          aria-label="Search models"
          placeholder="Search models or providers…"
          value={search}
          onChange={(e) => {
            setSearch(e.target.value);
            table.setPageIndex(0);
          }}
        />
        <div className="flex items-center gap-2">
          <details className="relative">
            <summary className="flex cursor-pointer items-center gap-2 rounded-md border px-3 py-2 text-sm">
              <Columns3 className="size-4" />
              Columns
            </summary>
            <div className="absolute right-0 z-20 mt-2 min-w-44 rounded-lg border bg-popover p-3 shadow-md">
              {table
                .getAllLeafColumns()
                .filter((c) => c.getCanHide())
                .map((c) => (
                  <label
                    key={c.id}
                    className="flex min-h-11 items-center gap-2 text-sm capitalize"
                  >
                    <input
                      type="checkbox"
                      checked={c.getIsVisible()}
                      onChange={c.getToggleVisibilityHandler()}
                    />
                    {c.id}
                  </label>
                ))}
            </div>
          </details>
          <Button
            variant="outline"
            disabled={disabled || !selected.length}
            onClick={() => onSelected(selected.map((r) => r.id))}
          >
            Add to persona ({selected.length})
          </Button>
        </div>
      </div>
      <Table className="min-w-[720px]">
        <TableHeader>
          {table.getHeaderGroups().map((group) => (
            <TableRow key={group.id}>
              {group.headers.map((h) => (
                <TableHead key={h.id}>
                  {h.column.getCanSort() ? (
                    <button
                      className="flex items-center gap-2"
                      onClick={h.column.getToggleSortingHandler()}
                    >
                      <table.FlexRender header={h} />
                      <ArrowDownUp className="size-3" />
                    </button>
                  ) : (
                    <table.FlexRender header={h} />
                  )}
                </TableHead>
              ))}
            </TableRow>
          ))}
        </TableHeader>
        <TableBody>
          {table.getRowModel().rows.map((row) => (
            <TableRow
              key={row.id}
              data-state={row.getIsSelected() ? "selected" : undefined}
            >
              {row.getVisibleCells().map((cell) => (
                <TableCell key={cell.id}>
                  <table.FlexRender cell={cell} />
                </TableCell>
              ))}
            </TableRow>
          ))}
          {!table.getRowModel().rows.length && (
            <TableRow>
              <TableCell colSpan={columns.length} className="p-8 text-center">
                No matching models.
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
      <footer className="flex flex-wrap items-center justify-between gap-3 border-t p-4 text-xs text-muted-foreground">
        <span>
          {selected.length} selected · {table.getFilteredRowModel().rows.length}{" "}
          models
        </span>
        <div className="flex items-center gap-3">
          <label className="flex items-center gap-2">
            Rows
            <select
              aria-label="Rows per page"
              value={table.state.pagination.pageSize}
              onChange={(e) => table.setPageSize(Number(e.target.value))}
            >
              {[10, 20, 50].map((n) => (
                <option key={n}>{n}</option>
              ))}
            </select>
          </label>
          <Button
            variant="outline"
            size="icon"
            aria-label="Previous page"
            disabled={!table.getCanPreviousPage()}
            onClick={() => table.previousPage()}
          >
            <ChevronLeft />
          </Button>
          <span>
            {table.state.pagination.pageIndex + 1} /{" "}
            {Math.max(1, table.getPageCount())}
          </span>
          <Button
            variant="outline"
            size="icon"
            aria-label="Next page"
            disabled={!table.getCanNextPage()}
            onClick={() => table.nextPage()}
          >
            <ChevronRight />
          </Button>
        </div>
      </footer>
      <p className="border-t px-4 py-3 text-xs text-muted-foreground">
        Open a model and save its provider configuration before assigning it.
        Catalog availability does not enable routing.
      </p>
    </div>
  );
}
function FallbackEditor({
  workspace,
  models,
}: {
  workspace: ModelWorkspace;
  models: CatalogModel[];
}) {
  const [order, setOrder] = useState(workspace.fallbacks.models),
    [choice, setChoice] = useState(""),
    [revision, setRevision] = useState(workspace.fallbacks.revision);
  const save = useConfigSave();
  return (
    <details className="workspace-panel p-5">
      <summary className="cursor-pointer font-medium">
        Global fallback models{" "}
        <span className="text-xs text-muted-foreground">
          · {order.length} configured
        </span>
      </summary>
      <div className="mt-4 grid gap-3">
        <p className="text-sm text-muted-foreground">
          Used in this order only by personas that opt in, after their own
          hierarchy. Existing spending limits apply.
        </p>
        {order.map((id, i) => (
          <div
            className="flex items-center justify-between gap-3 text-sm"
            key={id}
          >
            <span>
              {i + 1}. {models.find((m) => m.id === id)?.name ?? id}
            </span>
            <Button
              variant="ghost"
              onClick={() => setOrder(order.filter((x) => x !== id))}
            >
              Remove
            </Button>
          </div>
        ))}
        <div className="flex flex-wrap gap-3">
          <select
            aria-label="Global fallback model"
            value={choice}
            onChange={(e) => setChoice(e.target.value)}
          >
            <option value="">Choose a configured model</option>
            {models
              .filter((m) => m.revision > 0 && !order.includes(m.id))
              .map((m) => (
                <option key={m.id} value={m.id}>
                  {m.name}
                </option>
              ))}
          </select>
          <Button
            variant="outline"
            disabled={!choice}
            onClick={() => {
              setOrder([...order, choice]);
              setChoice("");
            }}
          >
            Append fallback
          </Button>
          <Button
            disabled={save.isPending}
            onClick={() =>
              save.mutate(
                {
                  path: "/api/models/fallbacks",
                  body: { expected_revision: revision, models: order },
                },
                { onSuccess: setRevision },
              )
            }
          >
            Save fallbacks
          </Button>
          <Button
            variant="outline"
            onClick={() => {
              setOrder(workspace.fallbacks.models);
              setRevision(workspace.fallbacks.revision);
              save.reset();
            }}
          >
            Reload saved version
          </Button>
        </div>
        {save.error && <p role="alert">{save.error.message}</p>}
        {save.isSuccess &&
          order.length === workspace.fallbacks.models.length &&
          order.every((id, i) => id === workspace.fallbacks.models[i]) && (
            <p role="status">Global fallbacks saved.</p>
          )}
      </div>
    </details>
  );
}
