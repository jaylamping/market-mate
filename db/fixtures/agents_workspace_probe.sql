-- Rollback-only routing mechanism checks. No provider calls or credentials.
BEGIN;
CREATE FUNCTION pg_temp.workspace_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'workspace assertion: %',message; END IF;
END $$;
SET LOCAL ROLE agent_driver;
SELECT save_model_policy('probe/model-a',0,'{"name":"Model A","offerings":[
 {"provider_id":"zai","model_id":"probe-a","enabled":true,"priority":1,"weight":100,"requests_per_day":1},
 {"provider_id":"opencode-go","model_id":"probe-a-alias","enabled":true,"priority":2,"weight":100}]}');
SELECT save_model_policy('probe/model-b',0,'{"name":"Model B","offerings":[
 {"provider_id":"openrouter-free","model_id":"probe/b:free","enabled":true,"priority":1,"weight":100,"requests_per_day":1}]}');
SELECT pg_temp.workspace_assert(save_model_policy('probe/model-a',0,'{}')->>'status'='conflict','stale model revision rejected');
DO $$ BEGIN
 BEGIN
  PERFORM save_model_policy('probe/duplicate',0,'{"name":"Duplicate","offerings":[{"provider_id":"zai","model_id":"probe-a","enabled":true,"priority":1,"weight":100}]}');
  RAISE EXCEPTION 'duplicate mapping accepted';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN
  PERFORM save_model_policy('probe/paid',0,'{"name":"Paid","offerings":[{"provider_id":"openrouter-paid","model_id":"probe/paid","enabled":true,"priority":1,"weight":100,"paid_daily_cap":1}]}');
  RAISE EXCEPTION 'unreserved paid allowance accepted';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
SELECT save_model_fallbacks(0,'["probe/model-b"]');
SELECT save_agent('workspace_probe',0,'{"name":"Workspace Probe","spec":{"model_order":["probe/model-a"],"use_global_fallbacks":true}}','ui');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false)->'route'->>'provider_id'='zai','first model and provider priority');
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:one','workspace_probe','research','{}',false,NULL)->>'status'='admitted','native model admitted');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false)->'route'->>'provider_id'='opencode-go','native allocation advances to another provider');
SELECT record_provider_cooldown('opencode-go',clock_timestamp()+interval '1 hour','probe');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false)->'route'->>'model_id'='probe/b:free','global fallback after persona models exhausted');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false,'probe-a')->>'status'='held','pinned worker cannot silently change models');
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:delegate','workspace_probe','research','{}',false,NULL)->>'status'='delegate','global model delegated');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false)->>'status'='held','queued delegation reserves its model allocation');
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:delegate','workspace_probe','research','{}',false,NULL)->>'status'='delegate','same queued intent retains reservation');
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:other','workspace_probe','research','{}',false,NULL)->>'status'='held','second intent cannot exceed reserved allocation');
SELECT pg_temp.workspace_assert(jsonb_array_length(read_model_requests('probe/model-a'))=1,'canonical history includes mapped provider attempt');
SELECT pg_temp.workspace_assert(read_model_requests('probe/model-a')->0->'cost_nanos'='null'::jsonb,'unreported cost stays null');
DO $$ BEGIN
 BEGIN
  PERFORM save_agent('workspace_probe',1,'{"spec":{"model_order":"bad"}}','ui');
  RAISE EXCEPTION 'malformed hierarchy accepted';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN
  UPDATE model_policy SET name='bypass';
  RAISE EXCEPTION 'direct policy write accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT save_model_policy('probe/model-a',1,'{"name":"Model A","offerings":[{"provider_id":"zai","model_id":"probe-a","enabled":false,"priority":1,"weight":100}]}');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false)->'skipped'->0->>'reason'='model_provider_disabled','model-specific disable controls routing');
-- Simulate a process dying after reserving a delegated route but before recording an attempt.
RESET ROLE;
UPDATE dispatch_intent SET updated_at=clock_timestamp()-interval '151 seconds'
 WHERE key='workspace:delegate';
SET LOCAL ROLE agent_driver;
DO $$ BEGIN
 BEGIN
  PERFORM record_delegated_attempt(read_dispatch_by_key('workspace:delegate')->>'intent_id','late-capacity-receipt',repeat('a',64));
  RAISE EXCEPTION 'expired reservation accepted a late attempt';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END $$;
SELECT pg_temp.workspace_assert(jsonb_array_length(read_model_requests('probe/model-b'))=0,'expired reservation created no attempt');
SELECT pg_temp.workspace_assert(expire_dispatch_attempts()>=1,'expiry sweep recovers pre-attempt reservations');
SELECT pg_temp.workspace_assert(read_dispatch_by_key('workspace:delegate')->>'state'='cancelled','abandoned delegation is terminal');
SELECT pg_temp.workspace_assert(read_dispatch_by_key('workspace:delegate')->>'reason'='delegation_reservation_expired','reservation expiry remains observable');
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:delegate','workspace_probe','research','{}',false,NULL)->>'status'='cancelled','late replay cannot reclaim released capacity');
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:replacement','workspace_probe','research','{}',false,NULL)->>'status'='delegate','recovered allocation admits a replacement request');
SELECT pg_temp.workspace_assert(current_agent_route('workspace_probe',false)->>'status'='held','replacement still reserves the one-request allocation');
-- Admission also reclaims an expired reservation without waiting for the background sweep.
RESET ROLE;
UPDATE dispatch_intent SET updated_at=clock_timestamp()-interval '151 seconds'
 WHERE key='workspace:replacement';
SET LOCAL ROLE agent_driver;
SELECT pg_temp.workspace_assert(admit_dispatch('workspace:next','workspace_probe','research','{}',false,NULL)->>'status'='delegate','admission recovers an expired reservation atomically');
SELECT pg_temp.workspace_assert(read_dispatch_by_key('workspace:replacement')->>'state'='cancelled','admission recovery terminates the old request');
DO $$ BEGIN
 BEGIN
  PERFORM record_delegated_attempt(read_dispatch_by_key('workspace:replacement')->>'intent_id','late-capacity-receipt',repeat('a',64));
  RAISE EXCEPTION 'released reservation accepted a late attempt';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END $$;
SELECT 'agents workspace probe passed';
ROLLBACK;
