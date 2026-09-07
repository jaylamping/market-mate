BEGIN;
CREATE FUNCTION pg_temp.ensure(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'near-duplicate assertion: %',label; END IF;
END $$;
CREATE FUNCTION pg_temp.generation() RETURNS bigint LANGUAGE sql AS $$
 INSERT INTO incubator_ticket_generation(campaign_revision,model,state)
 SELECT revision,'vendor/creator:free','queued' FROM incubator_campaign RETURNING id
$$;
CREATE FUNCTION pg_temp.finish(id_value bigint, title_value text, spec_value jsonb) RETURNS void LANGUAGE sql AS $$
 SELECT prepare_incubator_ticket_generation(id_value,'{"model":"vendor/creator:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'::jsonb);
 SELECT dispatch_incubator_ticket_generation(id_value);
 SELECT finish_incubator_ticket_generation(id_value,'completed',jsonb_build_object('proposal',jsonb_build_object(
  'title',title_value,'premise','Compared with the used cases, this ticket changes one field. Falsify against SPY and cash after costs.','spec',spec_value)));
$$;
SELECT admit_incubator_brief('near-dup-manual','vendor/model:free',jsonb_build_object(
 'key','near-dup-manual','title','Manual occupied momentum case',
 'text',E'Manual brief\nExact diagnostic spec: {"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":33,"borrow_bps_per_session":41}',
 'classification','project_authored_research_brief','permitted_destination','openrouter'),true);
UPDATE incubator_campaign SET enabled=true,creator_model='vendor/creator:free',backlog_limit=100,next_at=now()-interval '1 minute';
SELECT set_config('mm.near_gen', pg_temp.generation()::text, true);
SELECT set_config('mm.far_gen', pg_temp.generation()::text, true);
SELECT set_config('mm.exact_gen', pg_temp.generation()::text, true);
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.ensure(incubator_momentum_case_bucket('{"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":38,"borrow_bps_per_session":47}'::jsonb)
 ='{"lookback_sessions":4,"quantile_count":4,"one_way_cost_bin":3,"borrow_bin":4}'::jsonb,'bucket bins cost and borrow by 10 bps');
SELECT pg_temp.ensure(incubator_momentum_case_bucket('{"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":"38","borrow_bps_per_session":47}'::jsonb) IS NULL,'non-numeric cost yields no bucket');
SELECT pg_temp.ensure(incubator_used_momentum_buckets() @> '[{"lookback_sessions":4,"quantile_count":4,"one_way_cost_bin":3,"borrow_bin":4}]'::jsonb,'assignment bucket is listed as used');
SELECT pg_temp.ensure(NOT incubator_assignment_momentum_case_occupied('{"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":38,"borrow_bps_per_session":47}'::jsonb),'near case is not an exact occupant');
SELECT pg_temp.finish(current_setting('mm.near_gen')::bigint,'Near duplicate case',
 '{"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":38,"borrow_bps_per_session":47}'::jsonb);
SELECT pg_temp.finish(current_setting('mm.far_gen')::bigint,'Distinct bin case',
 '{"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":55,"borrow_bps_per_session":41}'::jsonb);
SELECT pg_temp.finish(current_setting('mm.exact_gen')::bigint,'Exact repeat case',
 '{"runner":"momentum_v1","lookback_sessions":4,"quantile_count":4,"one_way_cost_bps":33,"borrow_bps_per_session":41}'::jsonb);
RESET ROLE;
SELECT pg_temp.ensure(NOT EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE title='Near duplicate case'),'near duplicate inserts no candidate');
SELECT pg_temp.ensure((SELECT detail ? 'near_duplicate' AND detail ? 'deduplicated' AND state='completed' FROM incubator_ticket_generation WHERE id=current_setting('mm.near_gen')::bigint),'near duplicate is marked, not failed');
SELECT pg_temp.ensure((SELECT detail->'nearest_case'->>'one_way_cost_bps' FROM incubator_ticket_generation WHERE id=current_setting('mm.near_gen')::bigint)='33','near duplicate names the occupying case');
SELECT pg_temp.ensure(EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE title='Distinct bin case'),'distinct bin inserts a candidate');
SELECT pg_temp.ensure((SELECT NOT detail ? 'deduplicated' FROM incubator_ticket_generation WHERE id=current_setting('mm.far_gen')::bigint),'distinct bin is not marked deduplicated');
SELECT pg_temp.ensure((SELECT detail ? 'deduplicated' AND NOT detail ? 'near_duplicate' FROM incubator_ticket_generation WHERE id=current_setting('mm.exact_gen')::bigint),'exact repeat keeps the exact-case marker only');
SELECT pg_temp.ensure((SELECT enabled FROM incubator_campaign),'campaign stays enabled after near-duplicate intake');
ROLLBACK;
SELECT '{"probe":"campaign-near-duplicate","passed":true}';
