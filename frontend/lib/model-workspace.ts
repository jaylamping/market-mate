import {
  queryOptions,
  useMutation,
  useQueryClient,
} from "@tanstack/react-query";
import { getJson } from "./api-queries";
import {
  parseProviderModels,
  type Agent,
  type Provider,
  type ProviderModel,
} from "./agents";

export type Offering = {
  provider_id: string;
  model_id: string;
  enabled: boolean;
  priority: number;
  weight: number;
  requests_per_day: number | null;
  paid_daily_cap: number | null;
};
export type ModelPolicy = {
  id: string;
  name: string;
  offerings: Offering[];
  revision: number;
};
export type CatalogModel = ModelPolicy & { context: number | null };
export type ModelWorkspace = {
  models: ModelPolicy[];
  fallbacks: { models: string[]; revision: number };
};
export type ModelRequest = {
  attempt_id: string;
  intent_id: string;
  agent_id: string;
  provider_id: string;
  model_id: string;
  parent_attempt_id: string | null;
  receipt_time: string;
  state: string;
  cost_nanos: number | null;
  http_status: number | null;
  finished_at: string | null;
};
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw Error("Invalid workspace response");
  return value as Record<string, unknown>;
}
function text(value: unknown): string {
  if (typeof value !== "string") throw Error("Invalid workspace string");
  return value;
}
function number(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value))
    throw Error("Invalid workspace number");
  return value;
}
function list<T>(value: unknown, parse: (v: unknown) => T): T[] {
  if (!Array.isArray(value)) throw Error("Invalid workspace list");
  return value.map(parse);
}
export function parseWorkspace(value: unknown): ModelWorkspace {
  const data = object(value),
    fallbacks = object(data.fallbacks);
  return {
    models: list(data.models, (value) => {
      const m = object(value);
      return {
        id: text(m.id),
        name: text(m.name),
        revision: number(m.revision),
        offerings: list(m.offerings, (value) => {
          const o = object(value);
          if (typeof o.enabled !== "boolean")
            throw Error("Invalid offering state");
          return {
            provider_id: text(o.provider_id),
            model_id: text(o.model_id),
            enabled: o.enabled,
            priority: number(o.priority),
            weight: number(o.weight),
            requests_per_day:
              o.requests_per_day == null ? null : number(o.requests_per_day),
            paid_daily_cap:
              o.paid_daily_cap == null ? null : number(o.paid_daily_cap),
          };
        }),
      };
    }),
    fallbacks: {
      models: list(fallbacks.models, text),
      revision: number(fallbacks.revision),
    },
  };
}
export function parseModelRequests(value: unknown): ModelRequest[] {
  return list(value, (value) => {
    const r = object(value);
    return {
      attempt_id: text(r.attempt_id),
      intent_id: text(r.intent_id),
      agent_id: text(r.agent_id),
      provider_id: text(r.provider_id),
      model_id: text(r.model_id),
      parent_attempt_id:
        r.parent_attempt_id == null ? null : text(r.parent_attempt_id),
      receipt_time: text(r.receipt_time),
      state: text(r.state),
      cost_nanos: r.cost_nanos == null ? null : number(r.cost_nanos),
      http_status: r.http_status == null ? null : number(r.http_status),
      finished_at: r.finished_at == null ? null : text(r.finished_at),
    };
  });
}
export const workspaceQuery = queryOptions({
  queryKey: ["api", "models", "workspace"],
  staleTime: 30_000,
  queryFn: async ({ signal }) =>
    parseWorkspace(await getJson("/api/models", signal)),
});
export const catalogQuery = (provider: string) =>
  queryOptions({
    queryKey: ["api", "providers", provider, "models"],
    staleTime: 600_000,
    retry: 1,
    queryFn: async ({ signal }) =>
      parseProviderModels(
        await getJson(
          `/api/providers/${encodeURIComponent(provider)}/models`,
          signal,
        ),
      ),
  });
export const requestsQuery = (model: string) =>
  queryOptions({
    queryKey: ["api", "models", model, "requests"],
    staleTime: 30_000,
    queryFn: async ({ signal }) =>
      parseModelRequests(
        await getJson(
          `/api/models/requests?id=${encodeURIComponent(model)}`,
          signal,
        ),
      ),
  });
export function useConfigSave(onSaved?: () => void) {
  const client = useQueryClient();
  const refreshConfiguration = async () => {
    await Promise.all(
      [
        ["api", "agents"],
        ["api", "providers"],
        ["api", "models", "workspace"],
        ["api", "usage", "summary"],
        ["api", "config", "revisions"],
      ].map((queryKey) => client.invalidateQueries({ queryKey, exact: true })),
    );
  };
  return useMutation({
    mutationKey: ["configuration"],
    retry: false,
    mutationFn: async ({ path, body }: { path: string; body: unknown }) => {
      const response = await fetch(path, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15_000),
      });
      if (response.status === 409)
        throw Error(
          "Configuration changed elsewhere or was rejected. Your draft is preserved. Reload the saved version to reconcile.",
        );
      if (!response.ok)
        throw Error(
          "Save was not confirmed. Your draft is preserved; refresh the saved version before retrying.",
        );
      const result = object(await response.json());
      if (result.status !== "saved") throw Error("Save was not confirmed.");
      return number(result.revision);
    },
    onSuccess: async () => {
      await refreshConfiguration();
      onSaved?.();
    },
    onError: refreshConfiguration,
  });
}
// Only exact provider IDs or explicitly saved mappings are deduplicated. Names are not identity.
export function combineCatalogs(
  catalogs: {
    provider: Pick<Provider, "id" | "kind">;
    models: ProviderModel[];
  }[],
  policies: ModelPolicy[],
  agents: Agent[],
): CatalogModel[] {
  const rows = new Map<string, CatalogModel>(
    policies.map((p) => [
      p.id,
      { ...p, offerings: p.offerings.map((o) => ({ ...o })), context: null },
    ]),
  );
  for (const { provider, models } of catalogs)
    for (const model of models) {
      const mapped = policies.find((p) =>
        p.offerings.some(
          (o) => o.provider_id === provider.id && o.model_id === model.id,
        ),
      );
      const id = mapped?.id ?? model.id;
      let row = rows.get(id);
      if (!row) {
        row = {
          id,
          name: model.name,
          offerings: [],
          revision: 0,
          context: model.context_length || null,
        };
        rows.set(id, row);
      }
      if (
        !row.offerings.some(
          (o) => o.provider_id === provider.id && o.model_id === model.id,
        )
      ) {
        const legacyRoute = agents.flatMap((agent) => agent.routes).find(
          (route) => route.provider_id === provider.id && route.model_id === model.id,
        );
        row.offerings.push({
          provider_id: provider.id,
          model_id: model.id,
          enabled: legacyRoute !== undefined,
          priority:
            legacyRoute?.ordinal !== undefined
              ? legacyRoute.ordinal + 1
              : provider.id === "cursor"
              ? 900
              : provider.kind === "paid"
                ? 1000
                : 100,
          weight: 100,
          requests_per_day: null,
          paid_daily_cap: null,
        });
      }
      if (!row.context && model.context_length)
        row.context = model.context_length;
    }
  for (const agent of agents)
    for (const route of agent.routes) {
      if (
        [...rows.values()].some((row) =>
          row.offerings.some(
            (o) =>
              o.provider_id === route.provider_id &&
              o.model_id === route.model_id,
          ),
        )
      )
        continue;
      const row = rows.get(route.model_id) ?? {
        id: route.model_id,
        name: route.model_id,
        offerings: [],
        revision: 0,
        context: null,
      };
      row.offerings.push({
        provider_id: route.provider_id,
        model_id: route.model_id,
        enabled: true,
        priority: route.ordinal + 1,
        weight: 100,
        requests_per_day: null,
        paid_daily_cap: null,
      });
      rows.set(row.id, row);
    }
  return [...rows.values()].sort((a, b) => a.name.localeCompare(b.name));
}
export function modelOrder(agent: Agent): string[] {
  return Array.isArray(agent.spec.model_order)
    ? agent.spec.model_order.filter((v): v is string => typeof v === "string")
    : [];
}

export function modelPolicyOfferings(
  draft: ModelPolicy,
  providers: Pick<Provider, "id" | "kind">[],
  saved: ModelPolicy | undefined,
): Offering[] {
  return draft.offerings.flatMap((offering) => {
    if (providers.find((p) => p.id === offering.provider_id)?.kind !== "paid")
      return [offering];
    const existing = saved?.offerings.find(
      (o) => o.provider_id === offering.provider_id && o.model_id === offering.model_id,
    );
    return existing ? [existing] : [];
  });
}
