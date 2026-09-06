import test from "node:test";
import assert from "node:assert/strict";
import { connected, parsePaper } from "../app/paper/model";
import { activityLabel, money, ordersMatching, timestamp } from "../app/paper/presentation";
import type { PaperActivity, PaperOrder } from "../app/paper/model";

const envelope = {provider:"alpaca",environment:"paper",access:"read_only"};
const snapshot = () => ({...envelope,state:"connected",fetched_at_ms:1788732000000,recent_limit:50,
  account:{status:"ACTIVE",currency:"USD",cash:"0",equity:"-1.1234",buying_power:"0",trading_blocked:false,account_blocked:false},
  positions:[],orders:[],activities:[]});

test("Paper connection keeps genuine zero, negative and missing values distinct", () => {
  const state = parsePaper(snapshot());
  assert.ok(connected(state));
  assert.equal(state.account.equity, "-1.1234");
  assert.equal(state.account.cash, "0");
  const missing = parsePaper({...envelope,state:"not_configured"});
  assert.equal(connected(missing), false);
  assert.equal("account" in missing, false);
});

test("Paper boundary refuses Live, write access and malformed data", () => {
  for (const change of [{environment:"live"},{access:"trade"},{positions:null},{fetched_at_ms:NaN}]) {
    assert.throws(() => parsePaper({...snapshot(),...change}));
  }
  const value = snapshot();
  value.account.cash = "Infinity";
  assert.throws(() => parsePaper(value));
  assert.throws(() => parsePaper({...snapshot(),account:{...snapshot().account,trading_blocked:null}}));
});

test("Paper presentation preserves source meanings and filters records", () => {
  assert.equal(activityLabel({activity_type:"JNLC"} as PaperActivity), "Cash journal");
  assert.equal(activityLabel({activity_type:"NEW_PROVIDER_CODE"} as PaperActivity), "NEW_PROVIDER_CODE");
  assert.equal(money(null,"USD"), "Not reported");
  assert.equal(money("0","USD"), "$0.00");
  assert.equal(timestamp(null), "Time not reported");
  const orders = [{symbol:"AAPL",status:"new"},{symbol:"AAPL",status:"rejected"},{symbol:"MSFT",status:"new"}] as PaperOrder[];
  assert.deepEqual(ordersMatching(orders," aapl ","rejected"), [orders[1]]);
});
