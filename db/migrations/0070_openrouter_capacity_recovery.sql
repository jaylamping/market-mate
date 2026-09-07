-- Preserve deployed migration history; finalize capacity queue and recovery semantics.

CREATE OR REPLACE FUNCTION enqueue_openrouter_capacity(key_value text,request_value jsonb,purpose_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE q openrouter_capacity_queue%ROWTYPE; BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 SELECT * INTO q FROM openrouter_capacity_queue WHERE key=key_value;
 IF FOUND THEN
  IF q.purpose IS DISTINCT FROM purpose_value THEN RAISE EXCEPTION 'capacity_request_key_conflict'; END IF;
  IF q.fingerprint IS DISTINCT FROM encode(digest(request_value::text,'sha256'),'hex') THEN
   IF q.state<>'queued' OR EXISTS(SELECT 1 FROM openrouter_capacity_attempt WHERE key=key_value) THEN RAISE EXCEPTION 'capacity_request_key_conflict'; END IF;
   IF jsonb_typeof(request_value) IS DISTINCT FROM 'object' OR octet_length(request_value::text)>160000 OR request_value->>'model' IS NULL THEN RAISE EXCEPTION 'capacity_model_required'; END IF;
   UPDATE openrouter_capacity_queue SET request=jsonb_strip_nulls(jsonb_build_object('model',request_value->'model','messages_sha256',encode(digest((request_value->'messages')::text,'sha256'),'hex'),'stream',request_value->'stream','max_tokens',request_value->'max_tokens','max_completion_tokens',request_value->'max_completion_tokens')),fingerprint=encode(digest(request_value::text,'sha256'),'hex') WHERE key=key_value RETURNING * INTO q;
  END IF;
 ELSE
  IF jsonb_typeof(request_value) IS DISTINCT FROM 'object' OR octet_length(request_value::text)>160000 OR request_value->>'model' IS NULL THEN RAISE EXCEPTION 'capacity_model_required'; END IF;
  INSERT INTO openrouter_capacity_queue(key,request,purpose,fingerprint) VALUES(key_value,jsonb_strip_nulls(jsonb_build_object('model',request_value->'model','messages_sha256',encode(digest((request_value->'messages')::text,'sha256'),'hex'),'stream',request_value->'stream','max_tokens',request_value->'max_tokens','max_completion_tokens',request_value->'max_completion_tokens')),purpose_value,encode(digest(request_value::text,'sha256'),'hex')) RETURNING * INTO q;
 END IF;
 RETURN jsonb_build_object('status',q.state,'reason',q.reason,'key',q.key,'eligible_at',q.eligible_at);
END $$;


CREATE OR REPLACE FUNCTION finish_openrouter_capacity(id_value text,outcome_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a openrouter_capacity_attempt%ROWTYPE; r openrouter_capacity_result%ROWTYPE; cost_value bigint; at_time timestamptz;
 scope_value text; retry_value bigint; hits bigint; until_value timestamptz; BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 SELECT * INTO STRICT a FROM openrouter_capacity_attempt WHERE attempt_id=id_value;
 SELECT * INTO r FROM openrouter_capacity_result WHERE attempt_id=id_value;
 IF FOUND THEN
  IF r.outcome IS DISTINCT FROM outcome_value THEN RAISE EXCEPTION 'immutable_capacity_result'; END IF;
  RETURN '{"status":"recorded"}';
 END IF;
 IF jsonb_typeof(outcome_value) IS DISTINCT FROM 'object' OR outcome_value->>'state' IS NULL THEN RAISE EXCEPTION 'invalid_capacity_outcome'; END IF;
 IF outcome_value ? 'cost_nanos' AND outcome_value->'cost_nanos'<>'null'::jsonb THEN
  IF jsonb_typeof(outcome_value->'cost_nanos')<>'number' OR outcome_value->>'cost_nanos' !~ '^[0-9]{1,16}$' THEN RAISE EXCEPTION 'invalid_capacity_cost'; END IF;
  cost_value:=(outcome_value->>'cost_nanos')::bigint;
 END IF;
 INSERT INTO openrouter_capacity_result(attempt_id,outcome,cost_nanos,receipt_time,source_lineage,record_environment) VALUES(id_value,outcome_value,cost_value,clock_timestamp(),'{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research');
 at_time:=clock_timestamp();
 IF a.trigger<>'manual' AND cost_value>a.reserved_nanos THEN
  UPDATE openrouter_capacity_control SET policy=jsonb_set(policy,'{paid_enabled}','false');
 END IF;
 IF outcome_value->>'http_status'='429' THEN
  scope_value:=coalesce(outcome_value->>'limit_scope','unknown');
  retry_value:=CASE WHEN outcome_value->>'retry_ms' ~ '^[0-9]{1,9}$' THEN least(86400000,greatest(60000,(outcome_value->>'retry_ms')::bigint)) ELSE 60000 END;
  SELECT count(*) INTO hits FROM openrouter_capacity_result z JOIN openrouter_capacity_attempt b USING(attempt_id)
  WHERE z.receipt_time>at_time-interval '5 minutes' AND z.outcome->>'http_status'='429'
  AND CASE WHEN scope_value='provider' THEN b.model=a.model AND z.outcome->>'limit_scope'='provider' ELSE coalesce(z.outcome->>'limit_scope','unknown')<>'provider' END;
  retry_value:=greatest(retry_value,least(900000,60000*(2^least(hits-1,4))::bigint));
  IF hits>=3 THEN retry_value:=greatest(retry_value,300000); END IF;
  until_value:=at_time+retry_value*interval '1 millisecond';
  IF scope_value='provider' THEN
   INSERT INTO openrouter_capacity_model(model,first_failure,last_failure,cooldown_until) VALUES(a.model,at_time,at_time,until_value)
   ON CONFLICT(model) DO UPDATE SET first_failure=coalesce(openrouter_capacity_model.first_failure,at_time),last_failure=at_time,cooldown_until=greatest(openrouter_capacity_model.cooldown_until,until_value);
  ELSIF scope_value='daily' AND a.is_free THEN
   UPDATE openrouter_capacity_control SET daily_gate_until=greatest(daily_gate_until,CASE WHEN outcome_value->'retry_hint_valid'='true'::jsonb AND outcome_value->>'retry_ms' ~ '^[0-9]{1,9}$' THEN at_time+greatest(1000,least(86400000,(outcome_value->>'retry_ms')::bigint))*interval '1 millisecond' ELSE at_time+interval '24 hours' END);
  ELSIF scope_value='minute' AND a.is_free THEN
   UPDATE openrouter_capacity_control SET free_cooldown_until=greatest(free_cooldown_until,until_value),policy=jsonb_set(policy,'{start_interval_ms}',to_jsonb(greatest(4000,(policy->>'start_interval_ms')::integer)));
  ELSE
   UPDATE openrouter_capacity_control SET cooldown_until=greatest(cooldown_until,until_value),policy=jsonb_set(policy,'{start_interval_ms}',to_jsonb(greatest(4000,(policy->>'start_interval_ms')::integer)));
  END IF;
 ELSIF outcome_value->>'state'='completed' THEN
  UPDATE openrouter_capacity_model SET first_failure=NULL,last_failure=NULL,cooldown_until=NULL WHERE model=a.model AND (last_failure IS NULL OR last_failure<=a.receipt_time);

 END IF;
 RETURN '{"status":"recorded"}';
END $$;

CREATE OR REPLACE FUNCTION openrouter_work_ready(prefix_value text) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT NOT EXISTS(SELECT 1 FROM openrouter_capacity_queue q
 LEFT JOIN openrouter_capacity_attempt a USING(key) LEFT JOIN openrouter_capacity_result r USING(attempt_id)
 WHERE (q.key=prefix_value OR starts_with(q.key,prefix_value||CASE WHEN right(prefix_value,1)=':' THEN '' ELSE ':' END))
 AND ((q.state='queued' AND q.eligible_at>clock_timestamp())
 OR (q.state='dispatched' AND a.receipt_time<clock_timestamp()-interval '150 seconds' AND (r.attempt_id IS NULL OR r.outcome->>'reason'='dispatch_timeout'))))
$$;

CREATE OR REPLACE FUNCTION read_openrouter_work_wait(prefix_value text) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('reason',CASE WHEN q.state='dispatched' THEN 'dispatch_outcome_unknown' ELSE coalesce(q.reason,'queued') END,'next_eligible_at',q.eligible_at)
 FROM openrouter_capacity_queue q LEFT JOIN openrouter_capacity_attempt a USING(key) LEFT JOIN openrouter_capacity_result r USING(attempt_id)
 WHERE (q.key=prefix_value OR starts_with(q.key,prefix_value||CASE WHEN right(prefix_value,1)=':' THEN '' ELSE ':' END))
 AND (q.state='queued' OR (q.state='dispatched' AND a.receipt_time<clock_timestamp()-interval '150 seconds' AND (r.attempt_id IS NULL OR r.outcome->>'reason'='dispatch_timeout')))
 ORDER BY q.created_at LIMIT 1
$$;

CREATE OR REPLACE FUNCTION next_incubator_evaluation() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT id FROM incubator_evaluation WHERE
 (read_incubator_evaluation(id)->>'status' IN('queued','evaluating','awaiting_clarification')
 OR (read_incubator_evaluation(id)->>'status'='indeterminate' AND EXISTS(SELECT 1 FROM incubator_evaluation_step s LEFT JOIN incubator_evaluation_result r USING(evaluation_id,sequence) WHERE s.evaluation_id=id AND r.state IS NULL)))
 AND (openrouter_work_ready('evaluation:'||id||':') OR EXISTS(SELECT 1 FROM incubator_evaluation_step s LEFT JOIN incubator_evaluation_result r USING(evaluation_id,sequence) WHERE s.evaluation_id=id AND r.sequence IS NULL)) ORDER BY id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION next_incubator_refinement() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT id FROM incubator_evaluation e WHERE
 ((read_incubator_evaluation(id)->>'status'='refining' AND NOT coalesce((read_incubator_agent_run(run_key)->>'archived')::boolean,false))
 OR EXISTS(SELECT 1 FROM incubator_refinement a LEFT JOIN incubator_refinement_result r USING(evaluation_id) WHERE a.evaluation_id=e.id AND r.evaluation_id IS NULL))
 AND (openrouter_work_ready('refinement:'||id) OR EXISTS(SELECT 1 FROM incubator_refinement a LEFT JOIN incubator_refinement_result r USING(evaluation_id) WHERE a.evaluation_id=e.id AND r.evaluation_id IS NULL)) ORDER BY id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION next_incubator_experiment() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT t.evaluation_id FROM incubator_experiment_ticket t LEFT JOIN LATERAL(SELECT state FROM incubator_experiment_event WHERE experiment_id=t.evaluation_id ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE (e.state IS NULL OR e.state IN('preparing','setup_question','clarifying','clarified','answered','ready','dispatching','running')
 OR (e.state='awaiting_data' AND EXISTS(SELECT 1 FROM incubator_experiment_dataset d WHERE d.experiment_id=t.evaluation_id)))
 AND (e.state IN('preparing','clarifying','dispatching','running') OR openrouter_work_ready('experiment:'||t.evaluation_id||':')) ORDER BY t.evaluation_id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION defer_openrouter_capacity(key_value text,reason_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 UPDATE openrouter_capacity_queue SET eligible_at=clock_timestamp()+interval '60 seconds',reason=left(reason_value,160) WHERE key=key_value AND state='queued';
END $$;

REVOKE ALL ON FUNCTION defer_openrouter_capacity(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION defer_openrouter_capacity(text,text) TO incubator_runner,incubator_chat;
