BEGIN;
CREATE FUNCTION pg_temp.must_reject(command text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN EXECUTE command;
 EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',command;
END $$;
CREATE FUNCTION pg_temp.check_request(id text,body text,result jsonb) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 PERFORM begin_incubator_request_check(id,jsonb_build_object('title',body,'text',body,'model','vendor/model:free','selected_model',''));
 PERFORM finish_incubator_request_check(id,result);
END $$;
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.check_request('first','Investigate costs of a weekly momentum experiment','{"complete":true,"matches":[],"issues":[]}');
SELECT pg_temp.check_request('stale','Investigate costs of a weekly momentum experiment','{"complete":true,"matches":[],"issues":[]}');
SELECT submit_incubator_request('first',false);
SELECT pg_temp.must_reject($q$SELECT submit_incubator_request('stale',true)$q$,'55000');
SELECT submit_incubator_request('first',false);
SELECT pg_temp.must_reject($q$SELECT begin_incubator_request_check('first','{"title":"changed","text":"changed","model":"vendor/model:free"}')$q$,'22023');
SELECT pg_temp.check_request('warn','Investigate costs of a weekly momentum experiment','{"complete":true,"matches":[{"id":"first","reason":"Same premise"}],"issues":[]}');
SELECT pg_temp.must_reject($q$SELECT submit_incubator_request('warn',false)$q$,'55000');
SELECT submit_incubator_request('warn',true);
SELECT pg_temp.check_request('partial','Research diversification with uncertainty','{"complete":false,"matches":[],"issues":["Model unavailable"]}');
SELECT pg_temp.must_reject($q$SELECT submit_incubator_request('partial',false)$q$,'55000');
SELECT submit_incubator_request('partial',true);
SELECT pg_temp.must_reject($q$SELECT finish_incubator_request_check('partial','{"complete":true,"matches":[]}')$q$,'55000');
SELECT pg_temp.must_reject($q$UPDATE incubator_request_check SET input='{}'$q$,'42501');
SELECT pg_temp.must_reject($q$INSERT INTO incubator_manual_request SELECT * FROM incubator_manual_request$q$,'42501');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_brief('bypass','vendor/model:free','{}',true)$q$,'42501');
DO $$ BEGIN
 IF next_incubator_manual_run() IS DISTINCT FROM 'manual-first' THEN RAISE EXCEPTION 'queue order'; END IF;
END $$;
SELECT record_incubator_agent_event('manual-first','preparing','{}');
SELECT pg_temp.must_reject($q$SELECT record_incubator_agent_event('manual-warn','preparing','{}')$q$,'55000');
SELECT record_incubator_agent_event('manual-first','dispatched','{}');
SELECT record_incubator_agent_event('manual-first','failed','{"reason":"provider_rejected"}');
SELECT admit_incubator_agent_fallback('manual-first','fallback-manual','vendor/backup:free',1);
DO $$ BEGIN
 IF read_incubator_agent_run('fallback-manual')->'config'->'input' IS DISTINCT FROM read_incubator_agent_run('manual-first')->'config'->'input' THEN
  RAISE EXCEPTION 'fallback changed custom brief';
 END IF;
END $$;
SELECT record_incubator_agent_event('fallback-manual','failed','{"reason":"provider_rejected"}');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_fallback('fallback-manual','fallback-chain','vendor/third:free',1)$q$,'22023');
SELECT record_incubator_agent_event('manual-warn','preparing','{}');
SELECT record_incubator_agent_event('manual-warn','dispatched','{}');
SELECT record_incubator_agent_event('manual-warn','indeterminate','{"reason":"interrupted"}');
DO $$ BEGIN
 IF next_incubator_manual_run() IS NOT NULL THEN RAISE EXCEPTION 'uncertain request did not pause queue'; END IF;
END $$;
SELECT pg_temp.must_reject($q$SELECT record_incubator_agent_event('manual-warn','dispatched','{}')$q$,'55000');
RESET ROLE;
SELECT pg_temp.must_reject($q$UPDATE incubator_request_check SET input='{}'$q$,'55000');
SELECT pg_temp.must_reject($q$DELETE FROM incubator_request_check_result$q$,'55000');
SELECT pg_temp.must_reject($q$TRUNCATE incubator_manual_request$q$,'55000');
DO $$
DECLARE i integer; spec jsonb;
BEGIN
 SELECT a.spec INTO spec FROM incubator_assignment a LIMIT 1;
 FOR i IN 1..105 LOOP
  PERFORM engine_admit_research_assignment(spec||jsonb_build_object('assignment_key','historical-'||i),'{"source":"manual-probe","entitlement_version":"test-v1"}');
 END LOOP;
 IF jsonb_array_length(incubator_assignment_corpus())<>109 THEN RAISE EXCEPTION 'history omitted assignments'; END IF;
 IF (SELECT count(*) FROM incubator_manual_request WHERE request_id='first')<>1 THEN RAISE EXCEPTION 'duplicate submission'; END IF;
 IF (SELECT count(*) FROM incubator_agent_event WHERE run_key='manual-first')<>4 THEN RAISE EXCEPTION 'workflow events missing'; END IF;
 IF NOT (SELECT valid FROM verify_audit_event_chain()) THEN RAISE EXCEPTION 'invalid audit'; END IF;
END $$;
SELECT jsonb_build_object('probe','incubator-manual-requests','passed',true,'checks',jsonb_build_array(
 'all_history_over_100','request_identity','idempotent_submission','stale_check_rejected','warning_requires_confirmation',
 'incomplete_check_requires_confirmation','queued_while_busy','single_dispatch','custom_brief_fallback','no_fallback_chain',
 'uncertain_outcome_pauses_queue','append_only_nonempty','least_privilege','workflow_events','audit_chain'));
ROLLBACK;
