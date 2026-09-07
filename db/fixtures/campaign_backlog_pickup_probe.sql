BEGIN;
CREATE FUNCTION pg_temp.ensure(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'pickup assertion: %',label; END IF;
END $$;
SELECT pg_temp.ensure(incubator_momentum_case_spec('Exact diagnostic spec: {"lookback_sessions":3,"quantile_count":5,"one_way_cost_bps":8,"borrow_bps_per_session":4} and more')
 = '{"lookback_sessions":3,"quantile_count":5,"one_way_cost_bps":8,"borrow_bps_per_session":4}'::jsonb,'flat spec extracted');
SELECT pg_temp.ensure(jsonb_array_length(incubator_campaign_material_matches(
 '{"lookback_sessions":3,"quantile_count":5,"one_way_cost_bps":8,"borrow_bps_per_session":4}'::jsonb,
 '[{"id":"same","text":"Earlier wording\nExact diagnostic spec: {\"lookback_sessions\":3,\"quantile_count\":5,\"one_way_cost_bps\":8,\"borrow_bps_per_session\":4}"},{"id":"sensitivity","text":"Same topic\nExact diagnostic spec: {\"lookback_sessions\":1,\"quantile_count\":5,\"one_way_cost_bps\":8,\"borrow_bps_per_session\":4}"},{"id":"generic","text":"Investigate whether a simple daily stock momentum signal could produce durable after-cost excess returns."}]'::jsonb
))=1,'only exact-case matches remain');
UPDATE incubator_campaign SET enabled=false,revision=0,backlog_limit=100,next_at=now()-interval '1 minute',note='Paused. Existing tickets continue; no new tickets will be admitted.';
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.ensure(claim_incubator_ticket_generation() IS NULL,'paused creator stays idle');
CREATE TEMP TABLE pickup AS SELECT claim_incubator_campaign('vendor/model:free') j;
SELECT pg_temp.ensure((SELECT j->>'fresh' FROM pickup)='true','paused campaign still claims existing backlog');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM pickup;
SELECT finish_incubator_request_check(j->>'request_id','{"complete":true,"matches":[{"id":"prior","reason":"same core research question","text":"Investigate whether a simple daily stock momentum signal could produce durable after-cost excess returns."}]}') FROM pickup;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM pickup;
SELECT pg_temp.ensure((SELECT x->>'state' FROM jsonb_array_elements(read_incubator_campaign()->'agenda') x WHERE x->>'ordinal'=(SELECT j->>'ordinal' FROM pickup))='queued','topic overlap is not a duplicate');
SELECT pg_temp.ensure(read_incubator_campaign()->>'enabled'='false','admission does not enable a paused campaign');
SELECT pg_temp.ensure(read_incubator_campaign()->>'note' LIKE 'Paused.%','admission keeps the owner pause note');
RESET ROLE;
UPDATE incubator_campaign SET next_at=now()-interval '1 minute';
SET LOCAL ROLE incubator_runner;
TRUNCATE pickup;
INSERT INTO pickup SELECT claim_incubator_campaign('vendor/model:free');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM pickup;
SELECT finish_incubator_request_check(j->>'request_id',jsonb_build_object('complete',true,'matches',jsonb_build_array(jsonb_build_object('id','same-case','reason','rewritten exact case','text',j->>'text')))) FROM pickup;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM pickup;
SELECT pg_temp.ensure((SELECT x->>'state' FROM jsonb_array_elements(read_incubator_campaign()->'agenda') x WHERE x->>'ordinal'=(SELECT j->>'ordinal' FROM pickup))='duplicate','exact case moves to the duplicate queue');
RESET ROLE;
UPDATE incubator_campaign SET enabled=true,next_at=now()-interval '1 minute',note='Enabled. Waiting for the next eligible agenda item.';
SET LOCAL ROLE incubator_runner;
TRUNCATE pickup;
INSERT INTO pickup SELECT claim_incubator_campaign('vendor/model:free');
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM pickup;
SELECT pg_temp.ensure((SELECT x->>'state' FROM jsonb_array_elements(read_incubator_campaign()->'agenda') x WHERE x->>'ordinal'=(SELECT j->>'ordinal' FROM pickup))='blocked','incomplete check stays recorded');
SELECT pg_temp.ensure(read_incubator_campaign()->>'enabled'='true','incomplete check leaves campaign enabled');
SELECT pg_temp.ensure((SELECT count(*) FROM jsonb_array_elements(read_incubator_campaign()->'agenda') x WHERE x->>'retry_of'=(SELECT j->>'ordinal' FROM pickup))=1,'incomplete check queues a linked retry');
SELECT pg_temp.ensure(retry_incubator_campaign((SELECT (j->>'ordinal')::int FROM pickup), (read_incubator_campaign()->>'revision')::int)->>'enabled'='true','manual retry stays idempotent');
RESET ROLE;
ROLLBACK;
SELECT '{"probe":"campaign-backlog-pickup","passed":true}';
