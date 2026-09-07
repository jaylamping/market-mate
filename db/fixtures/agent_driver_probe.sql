-- Isolated, rollback-only mechanism probe for the agent driver schema. Run as migration owner after 0088.
-- No outbound network calls. The agent_driver role exercises SECURITY DEFINER entrypoints.
BEGIN;
CREATE FUNCTION pg_temp.driver_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'driver assertion: %',message; END IF;
END $$;
SELECT pg_temp.driver_assert((SELECT count(*) FROM provider)=6,'six seeded providers');
SELECT pg_temp.driver_assert((SELECT kind||'/'||protocol FROM provider WHERE id='cursor')='subscription/cursor_agent','cursor routes through cloud agents');
SELECT pg_temp.driver_assert((SELECT count(*) FROM provider_window WHERE provider_id='cursor' AND source='local')=2,'cursor pacing is local request counts');
SELECT pg_temp.driver_assert((SELECT settings->>'monthly_budget_usd' FROM provider WHERE id='cheaper-inference')='10','cheaper-inference carries a persisted monthly budget');
SELECT pg_temp.driver_assert((SELECT count(*) FROM provider_window WHERE provider_id='cheaper-inference' AND window_name='monthly' AND source='api')=1,'cheaper-inference spend is a monthly api window');
SELECT pg_temp.driver_assert((SELECT count(*) FROM provider_window WHERE provider_id='openrouter-free' AND source='local')=2,'openrouter free windows are local counters');
SELECT pg_temp.driver_assert(NOT EXISTS(SELECT 1 FROM dispatch_attempt),'isolated empty ledger required');
SET LOCAL ROLE agent_driver;
-- Agent with a subscription tier on two providers, a free tier on OpenRouter, and a paid tier.
SELECT pg_temp.driver_assert(save_agent('probe_scout',0,'{"name":"Probe Scout","spec":{"system":"probe"},"routes":[
 {"tier":"subscription","ordinal":0,"provider_id":"zai","model_id":"glm-5.3-flash"},
 {"tier":"subscription","ordinal":1,"provider_id":"opencode-go","model_id":"glm-5.3-flash"},
 {"tier":"free","ordinal":0,"provider_id":"openrouter-free","model_id":"vendor/free:free"},
 {"tier":"paid","ordinal":0,"provider_id":"openrouter-paid","model_id":"vendor/paid"}]}','import')->>'status'='saved','agent saved');
SELECT pg_temp.driver_assert(save_agent('probe_scout',0,'{"priority":5}','ui')->>'status'='conflict','stale revision rejected');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'route'->>'provider_id'='zai','primary subscription route wins with unknown usage');
-- Exhausted 5h window on Z.ai moves traffic to OpenCode Go until the window resets.
SELECT record_usage_sample('zai','rolling_5h',97,'ok',clock_timestamp()+interval '2 hours');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'route'->>'provider_id'='opencode-go','second subscription route after threshold');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'skipped'->0->>'reason'='window_exhausted:rolling_5h','skip reason names the window');
SELECT pg_temp.driver_assert((current_agent_route('probe_scout',false)->'skipped'->0->>'ordinal')::int=0,'skipped routes carry their ordinal for the UI');
-- Weekly pacing: 60% used with 90% of the week left is over pace with 15% slack.
SELECT record_usage_sample('opencode-go','weekly',60,'ok',clock_timestamp()+interval '6 days 8 hours');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'route'->>'provider_id'='openrouter-free','pacing pushes to the free tier');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'skipped'->1->>'reason'='pacing:weekly','pacing reason recorded');
-- Paid tier is never chosen unless the intent allows paid spend.
RESET ROLE;
UPDATE provider SET enabled=false WHERE id='openrouter-free';
SET LOCAL ROLE agent_driver;
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->>'status'='held','no free route holds instead of spending');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',true)->'route'->>'tier'='paid','allow_paid reaches the paid tier');
-- Reset returns traffic to the primary route without any configuration change.
SELECT record_usage_sample('zai','rolling_5h',3,'ok',clock_timestamp()+interval '5 hours');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'route'->>'provider_id'='zai','primary resumes after reset');
-- A provider the driver could not open (no credentials) is skipped, not chosen and failed.
SELECT record_provider_probe('zai','not_configured','not_configured');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->>'status'='held','unconfigured provider is skipped (remaining routes are paced or disabled)');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'skipped'->0->>'reason'='provider_not_configured','skip reason names the probe state');
SELECT record_provider_probe('zai','connected',NULL);
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->'route'->>'provider_id'='zai','connected probe restores the primary route');
-- Dispatch admission records an attempt and is idempotent on the key.
SELECT pg_temp.driver_assert(admit_dispatch('probe:one','probe_scout','research','{"messages":[{"role":"user","content":"hi"}],"max_tokens":64}',false,NULL)->>'status'='admitted','first dispatch admitted');
SELECT pg_temp.driver_assert(admit_dispatch('probe:one','probe_scout','research','{"messages":[{"role":"user","content":"hi"}],"max_tokens":64}',false,NULL)->>'status'='admitted','replay returns the same admission');
DO $$ BEGIN
 BEGIN PERFORM admit_dispatch('probe:one','probe_scout','research','{"messages":[{"role":"user","content":"changed"}],"max_tokens":64}',false,NULL); RAISE EXCEPTION 'accepted changed request';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
SELECT pg_temp.driver_assert(read_dispatch_by_key('probe:one')->'route'->>'provider_id'='zai' AND read_dispatch_by_key('probe:one')->>'attempt_id' IS NOT NULL,'one attempt recorded on the primary route');
SELECT mark_dispatched(read_dispatch_by_key('probe:one')->>'attempt_id');
SELECT pg_temp.driver_assert(read_dispatch_by_key('probe:one')->>'state'='dispatched','dispatched state visible');
-- A rate-limited outcome cools the provider down and is classified as failed; the next dispatch moves on.
SELECT record_dispatch_outcome(read_dispatch_by_key('probe:one')->>'attempt_id','failed','{"reason":"provider_http_error","http_status":429,"retry_ms":120000}',NULL);
SELECT pg_temp.driver_assert(read_dispatch_by_key('probe:one')->'outcome'->>'state'='failed','outcome recorded');
SELECT pg_temp.driver_assert((current_agent_route('probe_scout',false)->'skipped'->0->>'reason')='rate_limited','429 cools the provider');
SELECT pg_temp.driver_assert(current_agent_route('probe_scout',false)->>'status'='held' AND (current_agent_route('probe_scout',false)->'skipped'->1->>'reason')='pacing:weekly','cooldown and pacing hold every subscription route');
-- OpenRouter routes are delegated to the capacity ledger rather than admitted here.
SELECT record_usage_sample('opencode-go','rolling_5h',99,'ok',clock_timestamp()+interval '1 hour');
RESET ROLE;
UPDATE provider SET enabled=true WHERE id='openrouter-free';
SET LOCAL ROLE agent_driver;
SELECT pg_temp.driver_assert(admit_dispatch('probe:two','probe_scout','research','{"model":"vendor/free:free","messages":[{"role":"user","content":"hi"}],"max_tokens":64}',false,NULL)->>'status'='delegate','openrouter route delegates admission');
SELECT pg_temp.driver_assert(record_delegated_attempt(read_dispatch_by_key('probe:two')->>'intent_id','or-attempt-1','abc')->>'status'='admitted','delegated attempt links the capacity receipt');
SELECT pg_temp.driver_assert(read_dispatch_by_key('probe:two')->>'openrouter_attempt_id'='or-attempt-1','capacity receipt visible on the intent');
-- Usage summary and revisions are readable by the widget.
SELECT pg_temp.driver_assert(jsonb_array_length(read_usage_summary()->'providers')=6,'summary covers every routable provider');
SELECT pg_temp.driver_assert((SELECT count(*) FROM jsonb_array_elements(read_config_revisions(10)) r WHERE r->>'entity'='agent')=1,'agent revision recorded');
-- Evidence tables are append-only for every role.
RESET ROLE;
DO $$ BEGIN
 BEGIN UPDATE dispatch_attempt SET model_id='tamper'; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 BEGIN DELETE FROM provider_usage_sample; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END $$;
-- Expired in-flight attempts become indeterminate, never completed.
INSERT INTO dispatch_intent(intent_id,key,agent_id,purpose,request,fingerprint) VALUES('stale','probe:stale','probe_scout','research','{}','x');
INSERT INTO dispatch_attempt(attempt_id,intent_id,agent_id,provider_id,model_id,tier,ordinal,request_sha256,source_lineage,receipt_time,record_environment)
 VALUES('stale-attempt','stale','probe_scout','zai','glm-5.3-flash','subscription',0,'x','{"source":"agent_driver","entitlement_version":"local-research-v1"}',clock_timestamp()-interval '10 minutes','local_research');
UPDATE dispatch_intent SET state='dispatched',attempt_id='stale-attempt' WHERE intent_id='stale';
SELECT pg_temp.driver_assert(expire_dispatch_attempts()=1,'one expired attempt retired');
SELECT pg_temp.driver_assert(read_dispatch('stale')->>'state'='indeterminate','expired attempt is indeterminate');
SELECT 'agent driver probe passed' AS result;
ROLLBACK;
