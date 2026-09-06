import assert from "node:assert/strict";
import test from "node:test";
import { renderToStaticMarkup } from "react-dom/server";
import fixture from "./fixtures/stage1.json";
import { Stage1Surfaces } from "../app/Stage1Surfaces";
import { parseStage1Surfaces } from "../app/surfaces/stage1-surfaces-model";
import { attentionItems, comparatorFloors, custodyTrusted, qualificationMeasures } from "../app/overview-model";

const fresh = () => parseStage1Surfaces(structuredClone(fixture));

test("unverified custody is actionable even without known pending counts", () => {
  const s = fresh();
  s.checkpoints_verified = false;
  s.checkpoint_pack.state = "CHECKPOINT UNVERIFIED";
  s.checkpoint_pack.pending_events = null;
  s.checkpoint_pack.verified_position = null;
  assert.equal(custodyTrusted(s), false);
  const item = attentionItems(s).find(i => i.label === "Custody is unverified");
  assert.equal(item?.tone, "danger");
  assert.equal(item?.href, "/surfaces#checkpoint-pack");
});

test("optional and unavailable comparator values never turn into zero", () => {
  const s = fresh();
  assert.ok(s.qualification.recorded);
  const q = s.qualification;
  q.net_mean_return_bps = -74;
  q.lcb_vs_cash_bps = 0;
  q.lcb_vs_sp500_bps = null;
  q.meets_sp500_floor = null;
  q.sp500_comparator_required = false;
  assert.equal(comparatorFloors(q), "1 / 1 pass");
  assert.deepEqual(qualificationMeasures(q).map(m => m.value), [-74, 0, null]);
  assert.equal(qualificationMeasures(q)[2].unavailable, "Not required");
  q.sp500_comparator_required = true;
  assert.equal(comparatorFloors(q), "1 / 2 pass");
  assert.equal(qualificationMeasures(q)[2].unavailable, "Unavailable");
});

test("cost model remains visible when the register is not recorded", () => {
  const s = fresh();
  s.cost = { recorded: false, state: "not_recorded", detail: "No cost register" };
  const html = renderToStaticMarkup(<Stage1Surfaces surfaces={s} />);
  assert.match(html, /Projected month/);
  assert.match(html, /\$264\.00/);
  assert.doesNotMatch(html, /Registered month/);
});

test("attention drill-downs resolve to real evidence targets", () => {
  const s = fresh();
  const html = renderToStaticMarkup(<Stage1Surfaces surfaces={s} />);
  for (const item of attentionItems(s)) {
    const fragment = decodeURIComponent(item.href.split("#")[1]);
    assert.ok(html.includes(`id="${fragment}"`), `${item.href} must resolve`);
  }
  for (const m of s.snapshots.latest_manifests) assert.ok(html.includes(`id="cycle-${m.cycle_key}"`));
  for (const record of s.snapshots.latest_snapshots) assert.ok(html.includes(`id="snapshot-${record.snapshot_id}"`));
  assert.doesNotMatch(html, /<(button|form)\b/);
  for (const id of ["stage-badge", "qualification-progress", "cost-vs-caps", "snapshot-browser", "checkpoint-pack"]) assert.ok(html.includes(`id="${id}"`));
  assert.match(html, /data-order-authority="none"/);
});

test("empty projection retains explicit missing evidence states", () => {
  const s = fresh();
  s.qualification = s.cost = s.cost_model = { recorded: false, state: "not_recorded", detail: "Not recorded yet" };
  s.snapshots = { recorded: false, snapshot_count: 0, manifest_count: 0, latest_manifests: [], latest_snapshots: [] };
  s.checkpoints_verified = false;
  s.checkpoint_pack = { recorded: false, checkpoint_count: 0, head_position: null, verified_position: null, pending_events: null, state: "CHECKPOINT UNVERIFIED" };
  const html = renderToStaticMarkup(<Stage1Surfaces surfaces={s} />);
  assert.match(html, /No research cycle manifests/);
  assert.match(html, /No snapshots have been recorded/);
  assert.match(html, /unverified/);
});

test("parser rejects authority drift and ambiguous recorded flags", () => {
  for (const mutate of [
    (s: any) => { s.order_authority = true; },
    (s: any) => { s.environment = "live"; },
    (s: any) => { delete s.qualification.recorded; },
    (s: any) => { s.cost.recorded = "yes"; },
    (s: any) => { s.snapshots.latest_snapshots = {}; },
    (s: any) => { s.qualification.net_mean_return_bps = Infinity; },
  ]) {
    const s = structuredClone(fixture);
    mutate(s);
    assert.throws(() => parseStage1Surfaces(s));
  }
});
