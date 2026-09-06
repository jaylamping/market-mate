import test from "node:test";
import assert from "node:assert/strict";
import { makeQueryClient } from "../lib/query-client";
import { paperQuery } from "../lib/api-queries";

test("shared API cache deduplicates reads and invalidation marks data stale", async () => {
  const client = makeQueryClient();
  let calls = 0;
  const options = { ...paperQuery, queryFn: async () => { calls++; return { state: "not_configured" }; } };
  await Promise.all([client.fetchQuery(options), client.fetchQuery(options)]);
  assert.equal(calls, 1);
  await client.fetchQuery(options);
  assert.equal(calls, 1);
  await client.invalidateQueries({ queryKey: ["api"] });
  await client.fetchQuery(options);
  assert.equal(calls, 2);
  const otherRequest = makeQueryClient();
  assert.equal(otherRequest.getQueryData(paperQuery.queryKey), undefined);
  client.clear(); otherRequest.clear();
});

test("failed API requests are not retried or accepted as account data", async () => {
  const original = globalThis.fetch;
  const client = makeQueryClient();
  let calls = 0;
  try {
    globalThis.fetch = async () => { calls++; return new Response("unavailable", { status: 429 }); };
    await assert.rejects(client.fetchQuery(paperQuery));
    assert.equal(calls, 1);
    assert.equal(client.getQueryData(paperQuery.queryKey), undefined);
    globalThis.fetch = async () => Response.json({ provider: "alpaca", environment: "live", access: "read_only", state: "connected" });
    await assert.rejects(client.fetchQuery(paperQuery), /Invalid paper boundary/);
  } finally { globalThis.fetch = original; client.clear(); }
});
