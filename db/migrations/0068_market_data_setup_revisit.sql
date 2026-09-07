-- One bounded Setup revisit for pre-acquisition tickets when collection is available.
CREATE FUNCTION market_data_setup_revisit_eligible(id_value bigint) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM market_data_settings WHERE enabled AND market_data_source_available(source_id))
 AND market_data_research_active(id_value)
 AND read_incubator_experiment(id_value)->>'status'='awaiting_data'
 AND coalesce(read_incubator_experiment(id_value)->'detail'->'data_request','null')='null'::jsonb
 AND NOT EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value)
 AND NOT EXISTS(SELECT 1 FROM market_data_acquisition WHERE experiment_id=id_value)
 AND NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND detail->>'resume_reason'='market_data_available')
 AND (SELECT count(*) FROM incubator_experiment_event WHERE experiment_id=id_value AND state='preparing')<3
$$;
REVOKE ALL ON FUNCTION market_data_setup_revisit_eligible(bigint) FROM PUBLIC;

-- Preserve the original selector and its ordinary execution/recovery cases.
ALTER FUNCTION next_incubator_experiment() RENAME TO next_incubator_experiment_before_data_revisit;
CREATE FUNCTION next_incubator_experiment() RETURNS bigint LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(next_incubator_experiment_before_data_revisit(),(SELECT evaluation_id FROM incubator_experiment_ticket WHERE market_data_setup_revisit_eligible(evaluation_id) ORDER BY evaluation_id LIMIT 1))
$$;
REVOKE ALL ON FUNCTION next_incubator_experiment_before_data_revisit() FROM PUBLIC,incubator_runner;
REVOKE ALL ON FUNCTION next_incubator_experiment() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION next_incubator_experiment() TO incubator_runner;

-- Extend only the legacy transition engine; retain all model, budget and payload guards.
DO $$
DECLARE definition text; needle text := 'OR (prior.state=''awaiting_data'' AND state_value IN (''ready'',''needs_input'',''failed''))';
BEGIN
 SELECT pg_get_functiondef('record_incubator_experiment_event_legacy(bigint,text,jsonb)'::regprocedure) INTO definition;
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'setup_revisit_transition_anchor_missing'; END IF;
 definition:=replace(definition,needle,'OR (prior.state=''awaiting_data'' AND state_value IN (''preparing'',''ready'',''needs_input'',''failed''))');
 needle:=' IF NOT coalesce(( (prior.state IS NULL';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'setup_revisit_guard_anchor_missing'; END IF;
 definition:=replace(definition,needle,$guard$
 IF prior.state='awaiting_data' AND state_value='preparing' THEN
  PERFORM pg_advisory_xact_lock(59001,hashtext(run_value));
  IF NOT market_data_setup_revisit_eligible(id_value) THEN RAISE EXCEPTION 'setup_revisit_not_eligible'; END IF;
  detail_value:=detail_value||jsonb_build_object('resume_reason','market_data_available');
 END IF;
 IF NOT coalesce(( (prior.state IS NULL$guard$);
 needle:=' PERFORM pg_advisory_xact_lock(58001,id_value::integer);';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'setup_revisit_lock_anchor_missing'; END IF;
 definition:=replace(definition,needle,$lock$
 IF state_value='preparing' THEN
  PERFORM 1 FROM market_data_source WHERE id=(SELECT source_id FROM market_data_settings) FOR UPDATE;
 END IF;
 PERFORM pg_advisory_xact_lock(58001,id_value::integer);$lock$);
 EXECUTE definition;
END $$;
