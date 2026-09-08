import test from "node:test";
import assert from "node:assert/strict";
import {
  parseWorkspace,
  parseModelRequests,
  combineCatalogs,
  modelPolicyOfferings,
  workspaceQuery,
} from "../lib/model-workspace";
import { GET, PUT } from "../app/api/models/[[...path]]/route";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AgentDriver } from "../app/agents/AgentDriver";
import { WorkspaceStateProvider } from "../components/WorkspaceState";
import { agentsQuery, providersQuery, type Agent } from "../lib/agents";
Object.assign(globalThis, { React });

const legacyAgent: Agent = {
  id: "scout", name: "Research scout", spec: {}, priority: 100,
  hold_at_pct: 100, enabled: true, revision: 1, updated_at: "",
  routes: [{ tier: "subscription", ordinal: 2, provider_id: "zai", model_id: "model-a", share_pct: 100 }],
  current: { status: "eligible" },
};

test("catalog success preserves legacy routing just like a catalog outage", () => {
  const catalogs = [{ provider: { id: "zai", kind: "subscription" as const }, models: [{ id: "model-a", name: "A", context_length: 0, pricing: { prompt: "0", completion: "0" } }] }];
  const online = combineCatalogs(catalogs, [], [legacyAgent])[0];
  const offline = combineCatalogs([], [], [legacyAgent])[0];
  assert.deepEqual(online.offerings, offline.offerings);
  assert.equal(online.offerings[0].enabled, true);
  const disabled = { ...online, revision: 1, offerings: online.offerings.map((o) => ({ ...o, enabled: false })) };
  assert.equal(combineCatalogs(catalogs, [disabled], [legacyAgent])[0].offerings[0].enabled, false);
});

test("model saves leave legacy paid authorization alone and retain explicit paid restrictions", () => {
  const legacy = combineCatalogs([], [], [legacyAgent])[0];
  const paid = { ...legacy.offerings[0], provider_id: "paid", enabled: true };
  const draft = { ...legacy, offerings: [...legacy.offerings, paid] };
  const providers = [{ id: "zai", kind: "subscription" as const }, { id: "paid", kind: "paid" as const }];
  assert.deepEqual(modelPolicyOfferings(draft, providers, undefined), legacy.offerings);
  const saved = { ...draft, revision: 1, offerings: [{ ...paid, enabled: false }] };
  assert.deepEqual(modelPolicyOfferings(draft, providers, saved), [...legacy.offerings, saved.offerings[0]]);
});

test("failed configuration refresh retains the cached persona editor", async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, retryOnMount: false, staleTime: Infinity } } });
  client.setQueryData(agentsQuery.queryKey, [legacyAgent]);
  client.setQueryData(providersQuery.queryKey, []);
  client.setQueryData(workspaceQuery.queryKey, { models: [], fallbacks: { models: [], revision: 0 } });
  await assert.rejects(client.fetchQuery({ queryKey: agentsQuery.queryKey, staleTime: 0, queryFn: async () => { throw Error("Offline"); } }));
  assert.equal(client.getQueryState(agentsQuery.queryKey)?.status, "error");
  const html = renderToStaticMarkup(<QueryClientProvider client={client}><WorkspaceStateProvider><AgentDriver /></WorkspaceStateProvider></QueryClientProvider>);
  assert.match(html, /Configuration refresh failed/);
  assert.match(html, /value="Research scout"/);
  assert.match(html, /Save persona/);
  assert.doesNotMatch(html, /Agent workspace unavailable/);
  client.clear();
});

test("model policy parsing preserves disabled offerings and unknown limits", () => {
  const workspace = parseWorkspace({
    models: [
      {
        id: "canonical/model",
        name: "Model",
        revision: 2,
        offerings: [
          {
            provider_id: "zai",
            model_id: "alias",
            enabled: false,
            priority: 900,
            weight: 30,
          },
        ],
      },
    ],
    fallbacks: { models: ["canonical/model"], revision: 1 },
  });
  const offering = workspace.models[0].offerings[0];
  assert.equal(offering.enabled, false);
  assert.equal(offering.requests_per_day, null);
  assert.equal(offering.paid_daily_cap, null);
  assert.throws(() =>
    parseWorkspace({ models: [], fallbacks: { models: "bad", revision: 1 } }),
  );
});

test("request metadata preserves unknown costs and retry lineage", () => {
  const request = {
    attempt_id: "attempt",
    intent_id: "intent",
    agent_id: "research",
    provider_id: "zai",
    model_id: "alias",
    parent_attempt_id: "previous",
    receipt_time: "2026-09-08T00:00:00Z",
    state: "indeterminate",
    cost_nanos: null,
    finished_at: null,
    http_status: null,
  };
  assert.deepEqual(parseModelRequests([request]), [request]);
  assert.throws(() => parseModelRequests([{ ...request, cost_nanos: "0" }]));
});

test("catalog identity uses explicit aliases and never enables discovered offerings", () => {
  const model = (id: string) => ({
    id,
    name: "Same display name",
    context_length: 0,
    pricing: { prompt: "0", completion: "0" },
  });
  const catalogs = [
    {
      provider: { id: "zai", kind: "subscription" as const },
      models: [model("version-a")],
    },
    {
      provider: { id: "opencode-go", kind: "subscription" as const },
      models: [model("different-version")],
    },
  ];
  const unconfigured = combineCatalogs(catalogs, [], []);
  assert.equal(unconfigured.length, 2);
  assert.ok(
    unconfigured.every((row) =>
      row.offerings.every((offering) => !offering.enabled),
    ),
  );
  assert.equal(unconfigured[0].context, null);
  const policy = {
    id: "canonical-a",
    name: "Model A",
    revision: 1,
    offerings: [
      {
        provider_id: "zai",
        model_id: "version-a",
        enabled: false,
        priority: 1,
        weight: 100,
        requests_per_day: null,
        paid_daily_cap: null,
      },
      {
        provider_id: "opencode-go",
        model_id: "different-version",
        enabled: false,
        priority: 2,
        weight: 100,
        requests_per_day: null,
        paid_daily_cap: null,
      },
    ],
  };
  const mapped = combineCatalogs(catalogs, [policy], []);
  assert.equal(mapped.length, 1);
  assert.equal(mapped[0].id, "canonical-a");
  assert.equal(mapped[0].offerings.length, 2);
  assert.equal(combineCatalogs([], [policy], [])[0].offerings.length, 2);
});

test("model proxy preserves identity and conflicts and rejects foreign origins", async () => {
  const original = globalThis.fetch,
    prior = process.env.AGENT_DRIVER_URL;
  process.env.AGENT_DRIVER_URL = "http://127.0.0.1:8083";
  const params = { params: Promise.resolve({ path: [] }) };
  let called = 0;
  try {
    globalThis.fetch = async (url, options) => {
      called++;
      assert.equal(
        String(url),
        "http://127.0.0.1:8083/models?id=vendor%2Fmodel",
      );
      assert.equal(options?.method, "PUT");
      assert.deepEqual(JSON.parse(String(options?.body)), {
        expected_revision: 2,
      });
      return Response.json({ status: "conflict" }, { status: 409 });
    };
    const make = (origin: string) =>
      new Request("http://localhost:3100/api/models?id=vendor%2Fmodel", {
        method: "PUT",
        headers: {
          origin,
          host: "localhost:3100",
          "content-type": "application/json",
        },
        body: JSON.stringify({ expected_revision: 2 }),
      });
    assert.equal(
      (await PUT(make("https://foreign.example"), params)).status,
      403,
    );
    assert.equal(called, 0);
    assert.equal(
      (await PUT(make("http://localhost:3100"), params)).status,
      409,
    );
    assert.equal(called, 1);
    assert.equal(
      (
        await GET(new Request("http://localhost/api/models/nope"), {
          params: Promise.resolve({ path: ["nope"] }),
        })
      ).status,
      404,
    );
  } finally {
    globalThis.fetch = original;
    if (prior === undefined) delete process.env.AGENT_DRIVER_URL;
    else process.env.AGENT_DRIVER_URL = prior;
  }
});
