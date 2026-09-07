import test from "node:test";
import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { OpenRouterLimitsSummary } from "../components/OpenRouterLimits";
import { parseStatus } from "../lib/openrouter";

const status = {provider:"openrouter",state:"connected",model_policy:"whitelist",inference_enabled:false,checked_at_ms:1};
test("limits display never turns zero spend into remaining free requests", () => {
  const html = renderToStaticMarkup(<OpenRouterLimitsSummary status={parseStatus({...status, key_limits:{limit:null,limit_remaining:0,usage_daily:0}})}/>);
  assert.match(html, /Unlimited/);
  assert.match(html, /credit cap is exhausted/);
  assert.match(html, /Free requests remaining: unknown/);
  assert.match(html, /Unknown/);
});
test("unavailable limits hide cached amounts and missing caps are not unlimited", () => {
  const missing = renderToStaticMarkup(<OpenRouterLimitsSummary status={parseStatus({...status,key_limits:{}})}/>);
  assert.doesNotMatch(missing, /Unlimited|credit cap is exhausted/);
  const failed = renderToStaticMarkup(<OpenRouterLimitsSummary status={parseStatus({...status,state:"connection_failed",key_limits:{limit:12345}})}/>);
  assert.match(failed, /limits unavailable/);
  assert.doesNotMatch(failed, /12345/);
});
