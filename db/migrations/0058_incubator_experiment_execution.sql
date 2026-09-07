-- Bounded Local Research diagnostic execution; no strategy qualification or order authority.
CREATE TABLE incubator_experiment_dataset (
 experiment_id bigint PRIMARY KEY REFERENCES incubator_experiment_ticket(evaluation_id),
 snapshot_id uuid NOT NULL REFERENCES research_snapshot,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE TABLE incubator_experiment_event (
 experiment_id bigint NOT NULL REFERENCES incubator_experiment_ticket(evaluation_id),
 sequence integer NOT NULL CHECK(sequence BETWEEN 1 AND 24),
 state text NOT NULL CHECK(state IN ('clarifying','clarified','answered','awaiting_data','preparing','needs_input','ready','dispatching','running','completed','failed','indeterminate')),
 detail jsonb NOT NULL CHECK(jsonb_typeof(detail)='object' AND octet_length(detail::text)<=256000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(experiment_id,sequence)
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['incubator_experiment_dataset','incubator_experiment_event'] LOOP
  PERFORM register_evidence_table(t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE OR TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write()',t||'_append_only',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
 END LOOP;
END $$;
CREATE FUNCTION read_incubator_experiment(id_value bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('id',t.evaluation_id::text,'title',t.title,'created_at',t.receipt_time,
 'status',coalesce(e.state,'awaiting_setup'),'detail',coalesce(e.detail,'{}'),
 'snapshot_id',d.snapshot_id,'dataset_class',s.payload->>'dataset_class',
 'events',coalesce((SELECT jsonb_agg(jsonb_build_object('sequence',x.sequence,'state',x.state,'detail',x.detail,'at',x.receipt_time) ORDER BY x.sequence) FROM incubator_experiment_event x WHERE x.experiment_id=t.evaluation_id),'[]'))
 FROM incubator_experiment_ticket t
 LEFT JOIN LATERAL(SELECT * FROM incubator_experiment_event WHERE experiment_id=t.evaluation_id ORDER BY sequence DESC LIMIT 1)e ON true
 LEFT JOIN incubator_experiment_dataset d ON d.experiment_id=t.evaluation_id
 LEFT JOIN research_snapshot s USING(snapshot_id) WHERE t.evaluation_id=id_value
$$;
CREATE FUNCTION read_incubator_momentum_datasets() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.snapshot_id,'kind',s.snapshot_kind,'dataset_class',s.payload->>'dataset_class','created_at',s.receipt_time) ORDER BY s.receipt_time DESC),'[]')
 FROM research_snapshot s WHERE s.snapshot_kind='incubator_momentum_daily_v1' AND s.record_environment='local_research'
 AND NOT EXISTS(SELECT 1 FROM research_snapshot_revision r WHERE r.predecessor_snapshot_id=s.snapshot_id)
$$;
CREATE FUNCTION bind_incubator_experiment_dataset(id_value bigint,snapshot_value uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior uuid; s research_snapshot%ROWTYPE; BEGIN
 PERFORM pg_advisory_xact_lock(58001,id_value::integer);
 SELECT snapshot_id INTO prior FROM incubator_experiment_dataset WHERE experiment_id=id_value;
 IF FOUND THEN IF prior IS DISTINCT FROM snapshot_value THEN RAISE EXCEPTION 'dataset_already_pinned'; END IF; RETURN; END IF;
 IF read_incubator_experiment(id_value)->>'status' IS NULL OR read_incubator_experiment(id_value)->>'status' NOT IN ('awaiting_setup','awaiting_data','needs_input') THEN RAISE EXCEPTION 'experiment_not_waiting_for_data'; END IF;
 SELECT * INTO STRICT s FROM research_snapshot WHERE snapshot_id=snapshot_value;
 IF s.snapshot_kind<>'incubator_momentum_daily_v1' OR s.record_environment<>'local_research' OR EXISTS(SELECT 1 FROM research_snapshot_revision WHERE predecessor_snapshot_id=snapshot_value) THEN RAISE EXCEPTION 'incompatible_dataset'; END IF;
 INSERT INTO incubator_experiment_dataset VALUES(id_value,snapshot_value,s.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('experiment:'||id_value||':dataset','research.experiment_dataset_pinned',now(),jsonb_build_object('experiment_id',id_value,'snapshot_id',snapshot_value),s.source_lineage,now(),'local_research');
END $$;
CREATE FUNCTION read_incubator_experiment_input(id_value bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('experiment',read_incubator_experiment(id_value),'evaluation',read_incubator_evaluation(id_value),'payload',s.payload,'snapshot_superseded',EXISTS(SELECT 1 FROM research_snapshot_revision r WHERE r.predecessor_snapshot_id=s.snapshot_id))
 FROM incubator_experiment_ticket t LEFT JOIN incubator_experiment_dataset d ON d.experiment_id=t.evaluation_id LEFT JOIN research_snapshot s USING(snapshot_id) WHERE t.evaluation_id=id_value
$$;
CREATE FUNCTION next_incubator_experiment() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT t.evaluation_id FROM incubator_experiment_ticket t LEFT JOIN LATERAL(SELECT state FROM incubator_experiment_event WHERE experiment_id=t.evaluation_id ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE e.state IS NULL OR e.state IN ('preparing','clarifying','clarified','answered','ready','dispatching','running') OR (e.state='awaiting_data' AND EXISTS(SELECT 1 FROM incubator_experiment_dataset d WHERE d.experiment_id=t.evaluation_id)) ORDER BY t.evaluation_id LIMIT 1
$$;
CREATE FUNCTION record_incubator_experiment_event(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior incubator_experiment_event%ROWTYPE; lineage jsonb; registration experiment_preregistration%ROWTYPE; spec jsonb; d jsonb; run_value text; BEGIN
 PERFORM pg_advisory_xact_lock(58001,id_value::integer);
 SELECT source_lineage INTO STRICT lineage FROM incubator_experiment_ticket WHERE evaluation_id=id_value;
 SELECT run_key INTO STRICT run_value FROM incubator_evaluation WHERE id=id_value;
 PERFORM pg_advisory_xact_lock(55001,hashtext(run_value));
 IF state_value='answered' AND EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='answered') THEN
  IF NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='answered' AND detail=detail_value) THEN RAISE EXCEPTION 'immutable_answer'; END IF;
  RETURN;
 END IF;
 SELECT * INTO prior FROM incubator_experiment_event WHERE experiment_id=id_value ORDER BY sequence DESC LIMIT 1;
 IF FOUND AND prior.state=state_value AND (prior.detail=detail_value OR (state_value='ready' AND NOT detail_value ?| ARRAY['registration_id','registration_digest'] AND prior.detail - 'registration_id' - 'registration_digest'=detail_value)) THEN RETURN; END IF;
 IF NOT coalesce(( (prior.state IS NULL AND state_value IN ('preparing','failed'))
 OR (prior.state='preparing' AND state_value IN ('awaiting_data','ready','needs_input','clarifying','failed','indeterminate'))
 OR (prior.state='clarifying' AND state_value IN ('clarified','failed','indeterminate'))
 OR (prior.state='clarified' AND state_value IN ('preparing','failed'))
 OR (prior.state='answered' AND state_value IN ('preparing','dispatching','failed'))
 OR (prior.state='needs_input' AND state_value='answered')
 OR (prior.state='awaiting_data' AND state_value IN ('ready','needs_input','failed'))
 OR (prior.state='ready' AND state_value IN ('dispatching','failed'))
 OR (prior.state='dispatching' AND state_value IN ('running','needs_input','failed','indeterminate'))
 OR (prior.state='running' AND state_value IN ('completed','failed')) ),false) THEN RAISE EXCEPTION 'invalid_experiment_transition'; END IF;
 IF state_value='preparing' AND (SELECT count(*) FROM incubator_experiment_event WHERE experiment_id=id_value AND state='preparing')>=3 THEN RAISE EXCEPTION 'setup_budget_exhausted'; END IF;
 IF state_value='preparing' AND EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='ready') THEN RAISE EXCEPTION 'package_already_registered'; END IF;
 IF state_value='dispatching' AND (NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='ready') OR (SELECT count(*) FROM incubator_experiment_event WHERE experiment_id=id_value AND state='dispatching')>=2) THEN RAISE EXCEPTION 'experiment_budget_exhausted'; END IF;
 IF state_value='clarifying' AND EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='clarifying') THEN RAISE EXCEPTION 'clarification_budget_exhausted'; END IF;
 IF state_value='answered' AND (EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state='answered')) THEN RAISE EXCEPTION 'input_budget_exhausted'; END IF;
 IF state_value IN ('answered','clarified') AND (jsonb_typeof(detail_value->'answer') IS DISTINCT FROM 'string' OR length(btrim(detail_value->>'answer'))=0 OR octet_length(detail_value->>'answer')>6000) THEN RAISE EXCEPTION 'invalid_answer'; END IF;
 IF state_value IN ('preparing','clarifying','ready','dispatching','running','completed') AND read_incubator_evaluation(id_value)->>'status'='superseded' THEN RAISE EXCEPTION 'research_superseded'; END IF;
 IF state_value IN ('ready','dispatching','running','completed') AND EXISTS(SELECT 1 FROM incubator_experiment_dataset x JOIN research_snapshot_revision r ON r.predecessor_snapshot_id=x.snapshot_id WHERE x.experiment_id=id_value) THEN RAISE EXCEPTION 'dataset_superseded'; END IF;
 IF state_value IN ('ready','dispatching','running','completed') AND NOT EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value) THEN RAISE EXCEPTION 'dataset_required'; END IF;
 IF state_value IN ('preparing','clarifying','dispatching') AND (detail_value->'request'->>'max_tokens' IS DISTINCT FROM '2048' OR detail_value->'request'->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb OR coalesce(detail_value->'request'->>'model','') !~ '^[a-zA-Z0-9._/-]+:free$') THEN RAISE EXCEPTION 'bounded_model_request_required'; END IF;
 IF state_value='clarifying' AND detail_value->'request'->>'model' IS DISTINCT FROM (SELECT config->>'model' FROM incubator_agent_run WHERE run_key=run_value) THEN RAISE EXCEPTION 'original_research_model_required'; END IF;
 IF state_value='ready' THEN
  spec:=detail_value->'spec';
  IF spec->>'runner' IS DISTINCT FROM 'momentum_v1' OR (SELECT count(*) FROM jsonb_object_keys(spec))<>5
   OR strategy_sandbox_integer(spec->'lookback_sessions') IS NULL OR strategy_sandbox_integer(spec->'lookback_sessions') NOT BETWEEN 1 AND 5
   OR strategy_sandbox_integer(spec->'quantile_count') IS NULL OR strategy_sandbox_integer(spec->'quantile_count') NOT BETWEEN 2 AND 10
   OR strategy_sandbox_integer(spec->'one_way_cost_bps') IS NULL OR strategy_sandbox_integer(spec->'one_way_cost_bps') NOT BETWEEN 0 AND 100
   OR strategy_sandbox_integer(spec->'borrow_bps_per_session') IS NULL OR strategy_sandbox_integer(spec->'borrow_bps_per_session') NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'invalid_momentum_spec'; END IF;
  d:=read_incubator_experiment_input(id_value);
  registration:=register_experiment_preregistration('incubator-experiment:'||id_value,jsonb_build_object('hypothesis',d->'evaluation'->'report'->'hypothesis','windows',jsonb_build_object('snapshot_id',d->'experiment'->'snapshot_id','sessions',d->'payload'->'sessions'),'estimators','Equal-weight daily mean return, gross and net, diagnostic comparison only','budget',jsonb_build_object('max_symbols',32,'max_sessions',60,'max_model_calls',6,'max_cost_usd',0),'stopping_rule','One deterministic pass over the pinned snapshot; no parameter search','multiplicity_plan','One fixed diagnostic specification; no significance or qualification claim','runner_spec',spec),NULL,lineage);
  detail_value:=detail_value||jsonb_build_object('registration_id',registration.registration_id,'registration_digest',registration.spec_digest);
 END IF;
 IF state_value='completed' AND (detail_value->'result'->>'engine' IS DISTINCT FROM 'momentum_v1' OR detail_value->'result'->>'outcome' IS DISTINCT FROM 'diagnostic_only') THEN RAISE EXCEPTION 'diagnostic_result_required'; END IF;
 INSERT INTO incubator_experiment_event VALUES(id_value,coalesce(prior.sequence,0)+1,state_value,detail_value,lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('experiment:'||id_value||':'||coalesce(prior.sequence+1,1),'research.experiment_'||state_value,now(),jsonb_build_object('experiment_id',id_value,'detail',detail_value),lineage,now(),'local_research');
END $$;
CREATE OR REPLACE FUNCTION read_incubator_workflow() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('evaluations',coalesce(jsonb_agg(read_incubator_evaluation(id)||jsonb_build_object('experiment',read_incubator_experiment(id)) ORDER BY id DESC),'[]')) FROM incubator_evaluation
$$;
REVOKE ALL ON FUNCTION read_incubator_experiment(bigint),read_incubator_momentum_datasets(),bind_incubator_experiment_dataset(bigint,uuid),read_incubator_experiment_input(bigint),next_incubator_experiment(),record_incubator_experiment_event(bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_experiment(bigint),read_incubator_momentum_datasets(),bind_incubator_experiment_dataset(bigint,uuid),read_incubator_experiment_input(bigint),next_incubator_experiment(),record_incubator_experiment_event(bigint,text,jsonb) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();

CREATE FUNCTION notify_incubator_experiment() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN PERFORM pg_notify('incubator_experiment','changed'); RETURN NEW; END $$;
CREATE TRIGGER experiment_ticket_wakeup AFTER INSERT ON incubator_experiment_ticket FOR EACH ROW EXECUTE FUNCTION notify_incubator_experiment();
CREATE TRIGGER experiment_data_wakeup AFTER INSERT ON incubator_experiment_dataset FOR EACH ROW EXECUTE FUNCTION notify_incubator_experiment();
CREATE TRIGGER experiment_event_wakeup AFTER INSERT ON incubator_experiment_event FOR EACH ROW EXECUTE FUNCTION notify_incubator_experiment();
REVOKE ALL ON FUNCTION notify_incubator_experiment() FROM PUBLIC;
