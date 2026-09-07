BEGIN;
DO $$ DECLARE request_value jsonb; BEGIN
 FOREACH request_value IN ARRAY ARRAY['{"max_completion_tokens":1024}'::jsonb,'{"max_tokens":2048}'::jsonb] LOOP
  IF NOT incubator_request_output_is_bounded(request_value) THEN RAISE EXCEPTION 'valid bound rejected'; END IF;
 END LOOP;
 FOREACH request_value IN ARRAY ARRAY['{}'::jsonb,'{"max_tokens":0}'::jsonb,'{"max_tokens":2049}'::jsonb,'{"max_tokens":"2048"}'::jsonb,'{"max_tokens":2048,"max_completion_tokens":9000}'::jsonb,'{"max_completion_tokens":null}'::jsonb] LOOP
  IF incubator_request_output_is_bounded(request_value) THEN RAISE EXCEPTION 'unsafe bound accepted'; END IF;
 END LOOP;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT begin_incubator_request_check('paid-model-probe','{"title":"Paid manual research","text":"Test a bounded research premise","model":"~vendor/paid","selected_model":"~vendor/paid"}');
SELECT record_incubator_similarity_attempt('paid-model-probe',0,'{"model":"vendor/model:free","max_completion_tokens":1024,"provider":{"max_price":{"prompt":0,"completion":0}}}');
SELECT finish_incubator_request_check('paid-model-probe','{"complete":true,"matches":[],"issues":[]}');
DO $$
DECLARE run jsonb;
BEGIN
 run := submit_incubator_request('paid-model-probe',false);
 IF run->'config'->>'model' <> '~vendor/paid'
    OR run->'config'->'manual_model_spend' IS DISTINCT FROM 'true'::jsonb
    OR run->'config'->'limits' ? 'max_cost_usd'
    OR run->'config'->'limits'->>'max_requests' <> '1' THEN
  RAISE EXCEPTION 'manual paid model admission failed';
 END IF;
 IF submit_incubator_request('paid-model-probe',false)->>'run_key' IS DISTINCT FROM run->>'run_key' THEN
  RAISE EXCEPTION 'manual admission is not idempotent';
 END IF;
 BEGIN
  PERFORM admit_incubator_agent_run('automatic-paid-probe','vendor/paid','momentum-brief-v1');
  RAISE EXCEPTION 'automatic paid admission was allowed';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
END $$;
ROLLBACK;
