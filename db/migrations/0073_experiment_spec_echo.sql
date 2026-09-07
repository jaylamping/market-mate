-- An execute response may repeat exactly the registered spec; it cannot change it.
CREATE FUNCTION incubator_identical_spec_echo_pending(id_value bigint) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 WITH current_job AS (SELECT read_incubator_experiment(id_value) AS e)
 SELECT market_data_research_active(id_value)
 AND EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value)
 AND EXISTS(SELECT 1 FROM current_job, incubator_experiment_event current_event
 JOIN incubator_experiment_event dispatched ON dispatched.experiment_id=current_event.experiment_id AND dispatched.sequence=current_event.sequence-1
 WHERE current_event.experiment_id=id_value
 AND current_event.sequence=(SELECT max(sequence) FROM incubator_experiment_event WHERE experiment_id=id_value)
 AND current_event.state='needs_input' AND dispatched.state='dispatching'
 AND (current_job.e->'detail')->>'decision'='execute'
 AND coalesce((current_job.e->'detail')->'question','null')='null'::jsonb
 AND (current_job.e->'detail')->'spec' IS NOT NULL AND (current_job.e->'detail')->'spec'<>'null'::jsonb
 AND (current_job.e->'detail')->'spec'=(SELECT detail->'spec' FROM incubator_experiment_event WHERE experiment_id=id_value AND state='ready' ORDER BY sequence DESC LIMIT 1))
$$;
REVOKE ALL ON FUNCTION incubator_identical_spec_echo_pending(bigint) FROM PUBLIC;
DO $$
DECLARE definition text; needle text;
BEGIN
 SELECT pg_get_functiondef('record_incubator_experiment_event_legacy(bigint,text,jsonb)'::regprocedure) INTO definition;
 needle:=' IF NOT coalesce(( (prior.state=';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'spec_echo_transition_anchor_missing'; END IF;
 definition:=replace(definition,needle,$guard$
 IF prior.state='needs_input' AND state_value='running' THEN
  PERFORM pg_advisory_xact_lock(59001,hashtext(run_value));
  IF NOT incubator_identical_spec_echo_pending(id_value) THEN RAISE EXCEPTION 'spec_echo_recovery_unavailable'; END IF;
  detail_value:=jsonb_build_object('accepted_identical_spec_echo',true);
 END IF;
 IF NOT coalesce(( (prior.state='needs_input' AND state_value='running') OR (prior.state=$guard$);
 EXECUTE definition;
END $$;
ALTER FUNCTION next_incubator_experiment() RENAME TO next_incubator_experiment_before_spec_echo;
CREATE FUNCTION next_incubator_experiment() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(next_incubator_experiment_before_spec_echo(),(SELECT evaluation_id FROM incubator_experiment_ticket
 WHERE incubator_identical_spec_echo_pending(evaluation_id) ORDER BY evaluation_id LIMIT 1))
$$;
REVOKE ALL ON FUNCTION next_incubator_experiment(),next_incubator_experiment_before_spec_echo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION next_incubator_experiment() TO incubator_runner;
