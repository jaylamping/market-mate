-- Preserve bounded dispatch while accepting the token-limit parameter advertised by each model.
CREATE FUNCTION incubator_request_output_is_bounded(request_value jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public AS $$
 SELECT coalesce(CASE WHEN jsonb_typeof(request_value)='object'
 AND ((request_value ? 'max_tokens') <> (request_value ? 'max_completion_tokens'))
 AND jsonb_typeof(coalesce(request_value->'max_tokens',request_value->'max_completion_tokens'))='number'
 AND coalesce(request_value->>'max_tokens',request_value->>'max_completion_tokens') ~ '^[0-9]{1,4}$'
 THEN coalesce(request_value->>'max_tokens',request_value->>'max_completion_tokens')::integer BETWEEN 1 AND 2048
 ELSE false END,false)
$$;
CREATE OR REPLACE FUNCTION admit_incubator_chat(key_value text,id_value text,revision_value integer,text_value text,request_value jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior incubator_chat_turn%ROWTYPE; run_value jsonb; lineage jsonb; n integer;
BEGIN
 PERFORM pg_advisory_xact_lock(55001,hashtext(key_value));
 SELECT * INTO prior FROM incubator_chat_turn WHERE run_key=key_value AND request_id=id_value;
 IF FOUND THEN
  IF prior.user_text IS DISTINCT FROM text_value THEN RAISE EXCEPTION 'request identity mismatch' USING ERRCODE='22023'; END IF;
  RETURN false;
 END IF;
 run_value:=read_incubator_agent_run(key_value);
 IF run_value IS NULL OR run_value->>'state' NOT IN ('completed','failed') THEN
  RAISE EXCEPTION 'run must be terminal' USING ERRCODE='22023';
 END IF;
 SELECT count(*) INTO n FROM incubator_chat_turn WHERE run_key=key_value;
 IF revision_value IS DISTINCT FROM n OR n>=50 OR EXISTS(
  SELECT 1 FROM incubator_chat_turn t LEFT JOIN incubator_chat_result r USING(run_key,sequence)
   WHERE t.run_key=key_value AND (r.state IS NULL OR r.state='indeterminate')) THEN
  RAISE EXCEPTION 'conversation changed, full, or unresolved' USING ERRCODE='55000';
 END IF;
 IF request_value->>'model' IS DISTINCT FROM run_value->'config'->>'model'
  OR request_value->>'stream' IS DISTINCT FROM 'true'
  OR NOT incubator_request_output_is_bounded(request_value)
  OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb THEN
  RAISE EXCEPTION 'invalid bounded request' USING ERRCODE='22023';
 END IF;
 lineage:=jsonb_build_object('source','incubator-conversation','entitlement_version','owner-authored-discussion-v1','run_key',key_value);
 INSERT INTO incubator_chat_turn VALUES(key_value,n+1,id_value,coalesce((read_incubator_plan(key_value)->>'revision')::integer,0),text_value,request_value,lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('chat:'||key_value||':'||(n+1),'research.chat_dispatched',now(),
  jsonb_build_object('run_key',key_value,'sequence',n+1,'author','principal','request',request_value),lineage,now(),'local_research');
 RETURN true;
END $$;
CREATE OR REPLACE FUNCTION record_incubator_similarity_attempt(id_value text,batch_value integer,request_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_request_check%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_request_check WHERE request_id=id_value;
 IF NOT FOUND OR batch_value NOT BETWEEN 0 AND 7 OR octet_length(request_value::text)>96000
  OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb
  OR NOT incubator_request_output_is_bounded(request_value) THEN
  RAISE EXCEPTION 'invalid_similarity_attempt' USING ERRCODE='22023';
 END IF;
 PERFORM append_audit_event('request-check:'||id_value||':attempt:'||batch_value,'research.similarity_dispatched',now(),
  jsonb_build_object('request_id',id_value,'request',request_value),c.source_lineage,now(),'local_research');
END $$;
CREATE OR REPLACE FUNCTION begin_incubator_evaluation_step(id_value bigint,kind_value text,request_value jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE j incubator_evaluation%ROWTYPE; v jsonb; n integer; expected text; BEGIN
 PERFORM pg_advisory_xact_lock(57001,id_value::integer);
 SELECT * INTO STRICT j FROM incubator_evaluation WHERE id=id_value;
 PERFORM pg_advisory_xact_lock(55001,hashtext(j.run_key));
 v:=read_incubator_evaluation(id_value);
 n:=jsonb_array_length(v->'steps');
 expected:=CASE WHEN v->>'status'='awaiting_clarification' THEN 'clarification' ELSE 'evaluation' END;
 IF v->>'status' NOT IN ('queued','awaiting_clarification') OR EXISTS(SELECT 1 FROM incubator_evaluation_step s LEFT JOIN incubator_evaluation_result r USING(evaluation_id,sequence) WHERE s.evaluation_id=id_value AND r.state IS NULL)
 OR kind_value IS DISTINCT FROM expected OR n>=6 THEN RAISE EXCEPTION 'evaluation_not_ready'; END IF;
 IF NOT incubator_request_output_is_bounded(request_value) OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb
 OR coalesce(request_value->>'model','') !~ '^[a-zA-Z0-9._/-]+:free$'
 OR (kind_value='clarification' AND request_value->>'model' IS DISTINCT FROM (SELECT config->>'model' FROM incubator_agent_run WHERE run_key=j.run_key)) THEN RAISE EXCEPTION 'invalid_bounded_request'; END IF;
 INSERT INTO incubator_evaluation_step(evaluation_id,sequence,kind,request,source_lineage,receipt_time,record_environment) VALUES(id_value,n+1,kind_value,request_value,j.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('evaluation:'||id_value||':'||(n+1),'research.evaluation_dispatched',now(),jsonb_build_object('evaluation_id',id_value,'kind',kind_value,'request',request_value),j.source_lineage,now(),'local_research');
 RETURN n+1;
END $$;
CREATE OR REPLACE FUNCTION record_incubator_experiment_event_legacy(id_value bigint,state_value text,detail_value jsonb) RETURNS void
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
 IF state_value IN ('preparing','clarifying','dispatching') AND (NOT incubator_request_output_is_bounded(detail_value->'request') OR detail_value->'request'->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb OR coalesce(detail_value->'request'->>'model','') !~ '^[a-zA-Z0-9._/-]+:free$') THEN RAISE EXCEPTION 'bounded_model_request_required'; END IF;
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
CREATE OR REPLACE FUNCTION record_incubator_experiment_event(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE d market_data_dataset%ROWTYPE; prior jsonb; safe_detail jsonb; event_value incubator_experiment_event%ROWTYPE;
BEGIN
 IF state_value IN ('preparing','clarifying','dispatching') AND NOT incubator_request_output_is_bounded(detail_value->'request') THEN RAISE EXCEPTION 'bounded_model_request_required'; END IF;
 SELECT m.* INTO d FROM market_data_dataset m JOIN incubator_experiment_dataset e ON e.snapshot_id=m.snapshot_id WHERE e.experiment_id=id_value;
 IF NOT FOUND THEN PERFORM record_incubator_experiment_event_legacy(id_value,state_value,detail_value); RETURN; END IF;
 PERFORM 1 FROM market_data_source WHERE id=d.source_id FOR UPDATE;
 IF state_value<>'failed' AND NOT market_data_snapshot_available(d.snapshot_id) THEN RAISE EXCEPTION 'dataset_unavailable'; END IF;
 IF state_value='completed' THEN
  IF jsonb_typeof(detail_value->'result') IS DISTINCT FROM 'object' OR detail_value->'result'->>'engine' IS DISTINCT FROM 'momentum_v1' OR detail_value->'result'->>'outcome' IS DISTINCT FROM 'diagnostic_only'
   OR (detail_value - 'result' - 'registration_id')<>'{}'::jsonb THEN RAISE EXCEPTION 'invalid_managed_result'; END IF;
  SELECT result INTO prior FROM market_data_result WHERE experiment_id=id_value;
  IF FOUND AND prior IS DISTINCT FROM detail_value->'result' THEN RAISE EXCEPTION 'immutable_result'; END IF;
  safe_detail:=jsonb_build_object('result',jsonb_build_object('engine','momentum_v1','outcome','diagnostic_only','storage','market_data_v1'),'registration_id',(SELECT detail->'registration_id' FROM incubator_experiment_event WHERE experiment_id=id_value AND state='ready' ORDER BY sequence DESC LIMIT 1));
  PERFORM record_incubator_experiment_event_legacy(id_value,state_value,safe_detail);
  INSERT INTO market_data_result VALUES(id_value,d.id,detail_value->'result',d.source_lineage,clock_timestamp(),'local_research') ON CONFLICT DO NOTHING;
 ELSE
  SELECT * INTO event_value FROM incubator_experiment_event WHERE experiment_id=id_value AND (state_value<>'answered' OR state='answered') ORDER BY sequence DESC LIMIT 1;
  SELECT detail INTO prior FROM market_data_event_detail WHERE experiment_id=id_value AND sequence=event_value.sequence;
  IF event_value.state=state_value AND prior=detail_value THEN RETURN; END IF;
  IF event_value.state=state_value AND prior IS NOT NULL THEN RAISE EXCEPTION 'immutable_event_detail'; END IF;
  -- Keep free text, model messages and provider diagnostics in deletable storage.
  -- The legacy state machine receives only the bounded control fields it validates.
  safe_detail:='{}';
  IF state_value IN ('preparing','clarifying','dispatching') THEN
   safe_detail:=jsonb_build_object('request',jsonb_build_object('model',detail_value->'request'->'model','max_tokens',coalesce(detail_value->'request'->'max_tokens',detail_value->'request'->'max_completion_tokens'),'provider',jsonb_build_object('max_price',detail_value->'request'->'provider'->'max_price')));
  ELSIF state_value='ready' THEN safe_detail:=jsonb_build_object('spec',detail_value->'spec');
  ELSIF state_value IN ('answered','clarified') THEN
   IF jsonb_typeof(detail_value->'answer') IS DISTINCT FROM 'string' OR length(btrim(detail_value->>'answer'))=0 OR octet_length(detail_value->>'answer')>6000 THEN RAISE EXCEPTION 'invalid_answer'; END IF;
   safe_detail:=jsonb_build_object('answer','Stored with managed dataset');
  ELSIF state_value='failed' THEN safe_detail:=jsonb_build_object('reason','Managed experiment failed; details are retained with its dataset.');
  END IF;
  PERFORM record_incubator_experiment_event_legacy(id_value,state_value,safe_detail);
  IF market_data_snapshot_available(d.snapshot_id) THEN
   INSERT INTO market_data_event_detail
   SELECT id_value,max(sequence),d.id,detail_value,d.source_lineage,clock_timestamp(),'local_research' FROM incubator_experiment_event WHERE experiment_id=id_value;
  END IF;
 END IF;
END $$;
