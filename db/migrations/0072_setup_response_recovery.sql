-- Explicit, once-only recovery of a confirmed invalid Setup response.
ALTER TABLE incubator_experiment_event DROP CONSTRAINT incubator_experiment_event_state_check;
ALTER TABLE incubator_experiment_event ADD CONSTRAINT incubator_experiment_event_state_check CHECK(state IN('setup_retry','setup_question','clarifying','clarified','answered','awaiting_data','preparing','needs_input','ready','dispatching','running','completed','failed','indeterminate'));
CREATE FUNCTION incubator_setup_retry_available(id_value bigint) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT market_data_research_active(id_value)
 AND EXISTS(SELECT 1 FROM incubator_experiment_event last_event JOIN incubator_experiment_event intent
 ON intent.experiment_id=last_event.experiment_id AND intent.sequence=last_event.sequence-1
 WHERE last_event.experiment_id=id_value AND last_event.sequence=(SELECT max(sequence) FROM incubator_experiment_event WHERE experiment_id=id_value)
 AND last_event.state='failed' AND intent.state='preparing'
 AND last_event.detail->>'reason' IN('invalid_experiment_agent_response','incomplete_agent_reply','experiment_agent_output_truncated'))
 AND NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state IN('setup_retry','ready','dispatching','running','completed'))
 AND NOT EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value)
 AND NOT EXISTS(SELECT 1 FROM market_data_acquisition WHERE experiment_id=id_value)
 AND (SELECT count(*) FROM incubator_experiment_event WHERE experiment_id=id_value AND state='preparing')<5
$$;
REVOKE ALL ON FUNCTION incubator_setup_retry_available(bigint) FROM PUBLIC;
DO $$
DECLARE definition text; needle text;
BEGIN
 SELECT pg_get_functiondef('record_incubator_experiment_event_legacy(bigint,text,jsonb)'::regprocedure) INTO definition;
 needle:=' IF NOT coalesce(( (prior.state IS NULL';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'setup_retry_transition_anchor_missing'; END IF;
 definition:=replace(definition,needle,$guard$
 IF state_value='setup_retry' THEN
  PERFORM pg_advisory_xact_lock(59001,hashtext(run_value));
  IF NOT incubator_setup_retry_available(id_value) THEN RAISE EXCEPTION 'setup_retry_unavailable'; END IF;
  detail_value:=jsonb_build_object('reason','Owner requested one Setup retry after an invalid response.','failed_sequence',prior.sequence);
 END IF;
 IF prior.state='setup_retry' AND state_value='preparing' THEN
  PERFORM pg_advisory_xact_lock(59001,hashtext(run_value));
  IF NOT market_data_research_active(id_value) THEN RAISE EXCEPTION 'setup_retry_research_inactive'; END IF;
 END IF;
 IF NOT coalesce(( (prior.state='failed' AND state_value='setup_retry')
 OR (prior.state='setup_retry' AND state_value IN('preparing','failed')) OR (prior.state IS NULL$guard$);
 needle:='THEN 1 ELSE 0 END) THEN RAISE EXCEPTION ''setup_budget_exhausted''';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'setup_retry_budget_anchor_missing'; END IF;
 definition:=replace(definition,needle,'THEN 1 ELSE 0 END+CASE WHEN EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state=''setup_retry'') THEN 1 ELSE 0 END) THEN RAISE EXCEPTION ''setup_budget_exhausted''');
 needle:='''max_model_calls'',6';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'setup_retry_registration_anchor_missing'; END IF;
 definition:=replace(definition,needle,'''max_model_calls'',6+CASE WHEN EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state=''setup_retry'') THEN 1 ELSE 0 END');
 EXECUTE definition;
END $$;
CREATE FUNCTION retry_incubator_setup(id_value bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(58001,id_value::integer);
 IF EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='setup_retry') THEN RETURN false; END IF;
 PERFORM record_incubator_experiment_event(id_value,'setup_retry','{}');
 PERFORM pg_notify('incubator_experiment',id_value::text);
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION retry_incubator_setup(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION retry_incubator_setup(bigint) TO incubator_runner;
ALTER FUNCTION read_incubator_experiment(bigint) RENAME TO read_incubator_experiment_before_setup_retry;
CREATE FUNCTION read_incubator_experiment(id_value bigint) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT read_incubator_experiment_before_setup_retry(id_value)||jsonb_build_object('setup_retry_available',incubator_setup_retry_available(id_value))
$$;
REVOKE ALL ON FUNCTION read_incubator_experiment(bigint),read_incubator_experiment_before_setup_retry(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_experiment(bigint) TO incubator_runner,incubator_chat;
ALTER FUNCTION next_incubator_experiment() RENAME TO next_incubator_experiment_before_setup_retry;
CREATE FUNCTION next_incubator_experiment() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(next_incubator_experiment_before_setup_retry(),(SELECT evaluation_id FROM incubator_experiment_ticket
 WHERE read_incubator_experiment(evaluation_id)->>'status'='setup_retry' AND market_data_research_active(evaluation_id)
 AND openrouter_work_ready('experiment:'||evaluation_id||':') ORDER BY evaluation_id LIMIT 1))
$$;
REVOKE ALL ON FUNCTION next_incubator_experiment(),next_incubator_experiment_before_setup_retry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION next_incubator_experiment() TO incubator_runner;
