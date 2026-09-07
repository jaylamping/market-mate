BEGIN;
CREATE FUNCTION pg_temp.ensure(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'research retry assertion: %',label; END IF;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('research-retry-probe','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('research-retry-probe','failed','{"reason":"incomplete_response"}');
SELECT pg_temp.ensure(incubator_research_retry_available('research-retry-probe'),'retry after incomplete_response');
SELECT record_incubator_agent_event('research-retry-probe','research_retry','{"reason":"Automatic Research Scout retry after an unusable reply."}');
SELECT pg_temp.ensure(NOT incubator_research_retry_available('research-retry-probe'),'retry consumed');
SELECT record_incubator_agent_event('research-retry-probe','failed','{"reason":"invalid_report"}');
DO $$
BEGIN
  PERFORM record_incubator_agent_event('research-retry-probe','research_retry','{"reason":"second"}');
  RAISE EXCEPTION 'second research retry accepted';
EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'research_retry_unavailable' THEN RAISE; END IF;
END $$;
SELECT admit_incubator_agent_run('research-retry-archived','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('research-retry-archived','failed','{"reason":"invalid_report"}');
SELECT pg_temp.ensure(incubator_research_retry_available('research-retry-archived'),'archive candidate retryable');
SELECT set_incubator_research_archived('research-retry-archived','archive-research-retry-probe',true,0);
SELECT pg_temp.ensure(NOT incubator_research_retry_available('research-retry-archived'),'archived run is not retryable');
DO $$
BEGIN
  PERFORM record_incubator_agent_event('research-retry-archived','research_retry','{"reason":"archived"}');
  RAISE EXCEPTION 'archived research retry accepted';
EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'research_retry_unavailable' THEN RAISE; END IF;
END $$;
RESET ROLE;
UPDATE incubator_campaign SET enabled=false,revision=0,backlog_limit=100,next_at=now()-interval '1 minute',creator_model='vendor/selected',
 note='Paused. Existing tickets continue; no new tickets will be admitted.';
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.ensure(claim_incubator_campaign('vendor/other') IS NULL,'wrong paid model is rejected');
CREATE TEMP TABLE paid_claim AS SELECT claim_incubator_campaign('vendor/selected') j;
SELECT pg_temp.ensure((SELECT j->>'fresh' FROM paid_claim)='true','paid creator may claim');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM paid_claim;
SELECT finish_incubator_request_check(j->>'request_id','{"complete":true,"matches":[]}') FROM paid_claim;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM paid_claim;
SELECT pg_temp.ensure((SELECT x->>'state' FROM jsonb_array_elements(read_incubator_campaign()->'agenda') x WHERE x->>'ordinal'=(SELECT j->>'ordinal' FROM paid_claim))='queued','paid claim admits research');
SELECT pg_temp.ensure((read_incubator_agent_run('campaign-pilot-v1-'||(SELECT j->>'ordinal' FROM paid_claim))->>'research_retry_available')='false','fresh admission is not a retry');
SELECT pg_temp.ensure((read_incubator_agent_run('campaign-pilot-v1-'||(SELECT j->>'ordinal' FROM paid_claim))->'config'->>'campaign_model_spend')='true','paid creator marks campaign spend');
SELECT record_incubator_agent_event('campaign-pilot-v1-'||(SELECT j->>'ordinal' FROM paid_claim),'failed','{"reason":"incomplete_response"}');
SELECT pg_temp.ensure(next_incubator_manual_run()='campaign-pilot-v1-'||(SELECT j->>'ordinal' FROM paid_claim),'failed research is picked for retry');
SELECT set_incubator_research_archived('campaign-pilot-v1-'||(SELECT j->>'ordinal' FROM paid_claim),'archive-paid-research-retry',true,0);
SELECT pg_temp.ensure(next_incubator_manual_run() IS NULL,'archived research is not picked');
RESET ROLE;
ROLLBACK;
SELECT '{"probe":"research-scout-retry","passed":true}';
