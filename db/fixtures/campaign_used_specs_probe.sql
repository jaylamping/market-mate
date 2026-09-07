BEGIN;
CREATE FUNCTION pg_temp.ensure(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'used-spec assertion: %',label; END IF;
END $$;
SELECT admit_incubator_brief('used-spec-manual','vendor/model:free',jsonb_build_object(
 'key','used-spec-manual','title','Manual occupied momentum case',
 'text',E'Manual brief\nExact diagnostic spec: {"runner":"momentum_v1","lookback_sessions":2,"quantile_count":4,"one_way_cost_bps":17,"borrow_bps_per_session":3}',
 'classification','project_authored_research_brief','permitted_destination','openrouter'),true);
UPDATE incubator_campaign SET enabled=true,creator_model='vendor/creator:free',backlog_limit=100,next_at=now()-interval '1 minute';
WITH g AS (
 INSERT INTO incubator_ticket_generation(campaign_revision,model,state)
 SELECT revision,'vendor/creator:free','queued' FROM incubator_campaign RETURNING id
)
SELECT set_config('mm.used_gen', id::text, true) FROM g;
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.ensure(incubator_assignment_momentum_case_occupied('{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":4,"one_way_cost_bps":17,"borrow_bps_per_session":3}'::jsonb),'assignment case is occupied');
SELECT pg_temp.ensure(jsonb_array_length(incubator_used_momentum_cases())>0,'used list is nonempty');
SELECT pg_temp.ensure(current_setting('mm.used_gen')<>'','generation row available');
SELECT prepare_incubator_ticket_generation(current_setting('mm.used_gen')::bigint,'{"model":"vendor/creator:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'::jsonb);
SELECT dispatch_incubator_ticket_generation(current_setting('mm.used_gen')::bigint);
SELECT finish_incubator_ticket_generation(current_setting('mm.used_gen')::bigint,'completed',jsonb_build_object('proposal',jsonb_build_object(
 'title','Repeated assignment case','premise','Falsify this isolated hypothesis against SPY and cash after costs.',
 'spec',jsonb_build_object('runner','momentum_v1','lookback_sessions',2,'quantile_count',4,'one_way_cost_bps',17,'borrow_bps_per_session',3))));
RESET ROLE;
SELECT pg_temp.ensure(NOT EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE title='Repeated assignment case'),'assignment repeat inserts no candidate');
SELECT pg_temp.ensure((SELECT detail ? 'deduplicated' FROM incubator_ticket_generation WHERE id=current_setting('mm.used_gen')::bigint),'assignment repeat is marked deduplicated');
ROLLBACK;
SELECT '{"probe":"campaign-used-specs","passed":true}';
