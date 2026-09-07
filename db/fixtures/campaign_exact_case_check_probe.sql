BEGIN;
CREATE FUNCTION pg_temp.ensure(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'exact-case assertion: %',label; END IF;
END $$;
UPDATE incubator_campaign SET enabled=true,revision=0,daily_limit=10,open_limit=3,backlog_limit=100,next_at=now()+interval '1 hour',note='Enabled.';
SET LOCAL ROLE incubator_runner;
CREATE TEMP TABLE exact_case AS SELECT claim_incubator_campaign('vendor/model:free') j;
SELECT pg_temp.ensure((SELECT j->>'fresh' FROM exact_case)='true','future next_at does not block a new check');
SELECT pg_temp.ensure(claim_incubator_campaign('vendor/model:free')->>'fresh'='false','restart still returns the in-flight check');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM exact_case;
SELECT finish_incubator_request_check(j->>'request_id',jsonb_build_object('complete',true,'matches','[]'::jsonb,'issues','[]'::jsonb,'attempts','[]'::jsonb,'method','exact_case')) FROM exact_case;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM exact_case;
CREATE TEMP TABLE exact_next AS SELECT claim_incubator_campaign('vendor/model:free') j;
SELECT pg_temp.ensure((SELECT j->>'fresh' FROM exact_next)='true','next check is claimed without a delay');
SELECT pg_temp.ensure((SELECT j->>'ordinal' FROM exact_next) IS DISTINCT FROM (SELECT j->>'ordinal' FROM exact_case),'next check is a different card');
RESET ROLE;
ROLLBACK;
SELECT '{"probe":"campaign-exact-case-check","passed":true}';
