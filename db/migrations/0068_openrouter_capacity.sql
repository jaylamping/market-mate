-- One account, database-clock admission; dispatch commitments never become reusable.
CREATE TABLE openrouter_capacity_control (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 policy jsonb NOT NULL,
 installed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 history_known boolean NOT NULL DEFAULT true,
 last_clock timestamptz NOT NULL DEFAULT clock_timestamp(),
 next_start timestamptz NOT NULL DEFAULT clock_timestamp(),
 cooldown_until timestamptz,
 free_cooldown_until timestamptz,
 daily_gate_until timestamptz
);
INSERT INTO schema_object(table_name,kind) VALUES('openrouter_capacity_control','control');
INSERT INTO openrouter_capacity_control(policy) VALUES('{"revision":0,"paused":false,"mode":"paced","daily_target":980,"start_interval_ms":3200,"burst_remaining":0,"paid_enabled":false,"prefer_free_models":true,"paid_finish_on_429":false,"paid_max_fallback_attempts":1,"paid_role_models":{"research":null,"setup":null,"experiment":null,"default":null},"paid_model":null,"paid_models":[],"paid_outage_enabled":false,"paid_model_open_weights_confirmed":false,"free_models":[],"paid_request_limit_nanos":2000000,"paid_daily_limit_nanos":100000000,"paid_monthly_limit_nanos":2000000000,"paid_attempt_limit":100}');
CREATE TABLE openrouter_capacity_queue (
 key text PRIMARY KEY CHECK(length(key) BETWEEN 1 AND 240),
 request jsonb NOT NULL CHECK(jsonb_typeof(request)='object' AND octet_length(request::text)<=160000),
 fingerprint text NOT NULL,
 purpose text NOT NULL CHECK(length(purpose) BETWEEN 1 AND 96),
 state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','dispatched','cancelled')),
 eligible_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 reason text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_object(table_name,kind) VALUES('openrouter_capacity_queue','control');
CREATE TABLE openrouter_capacity_attempt (
 attempt_id text PRIMARY KEY,
 key text NOT NULL UNIQUE,
 parent_key text REFERENCES openrouter_capacity_attempt(key),
 fallback_ordinal integer CHECK(fallback_ordinal BETWEEN 1 AND 2),
 model text NOT NULL,
 request_fingerprint text NOT NULL DEFAULT '',
 is_free boolean NOT NULL,
 reserved_nanos bigint NOT NULL CHECK(reserved_nanos>=0),
 policy_revision bigint NOT NULL,
 trigger text NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE INDEX openrouter_capacity_attempt_time ON openrouter_capacity_attempt(receipt_time);
CREATE TABLE openrouter_capacity_result (
 attempt_id text PRIMARY KEY REFERENCES openrouter_capacity_attempt,
 outcome jsonb NOT NULL CHECK(jsonb_typeof(outcome)='object' AND octet_length(outcome::text)<=16000),
 cost_nanos bigint CHECK(cost_nanos>=0),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['openrouter_capacity_attempt','openrouter_capacity_result'] LOOP
  PERFORM register_evidence_table(t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE OR TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write()',t||'_append_only',t);
 END LOOP;
END $$;
REVOKE ALL ON openrouter_capacity_control,openrouter_capacity_queue,openrouter_capacity_attempt,openrouter_capacity_result FROM PUBLIC,incubator_runner,incubator_chat;

-- Keep source-specific IDs: evaluation/refinement audit mirrors are not counted twice.
-- Unknown legacy pricing is counted as free conservatively. All six persisted
-- paths are inventoried here; deployment must stop old binaries before migration.
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
SELECT 'legacy:'||key,'legacy:'||key,coalesce(model,'unknown'),coalesce(model LIKE '%:free' OR model='openrouter/free',true),0,0,'legacy_inventory',receipt_time,'{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM (
 SELECT 'report:'||run_key||':'||sequence key,detail->'request'->>'model' model,receipt_time FROM incubator_agent_event WHERE state='dispatched'
 UNION ALL SELECT 'chat:'||run_key||':'||sequence,request->>'model',receipt_time FROM incubator_chat_turn
 UNION ALL SELECT 'similarity:'||event_id,payload->'request'->>'model',receipt_time FROM audit_event WHERE event_type='research.similarity_dispatched'
 UNION ALL SELECT 'evaluation:'||evaluation_id||':'||sequence,request->>'model',receipt_time FROM incubator_evaluation_step
 UNION ALL SELECT 'refinement:'||evaluation_id,request->>'model',receipt_time FROM incubator_refinement
 UNION ALL SELECT 'experiment:'||experiment_id||':'||sequence,detail->'request'->>'model',receipt_time FROM incubator_experiment_event WHERE state IN ('preparing','clarifying','dispatching')
) legacy WHERE receipt_time>clock_timestamp()-interval '24 hours';
-- Legacy dispatches retain consumption, but must not occupy the new transport slots.
INSERT INTO openrouter_capacity_result(attempt_id,outcome,receipt_time,source_lineage,record_environment)
SELECT attempt_id,'{"state":"legacy_unknown"}',clock_timestamp(),'{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM openrouter_capacity_attempt WHERE trigger='legacy_inventory';

CREATE TABLE openrouter_capacity_model (
 model text PRIMARY KEY, first_failure timestamptz, last_failure timestamptz,
 cooldown_until timestamptz
);
INSERT INTO schema_object(table_name,kind) VALUES('openrouter_capacity_model','control');
REVOKE ALL ON openrouter_capacity_model FROM PUBLIC,incubator_runner,incubator_chat;

CREATE FUNCTION read_openrouter_capacity() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 WITH c AS (SELECT * FROM openrouter_capacity_control), totals AS (
 SELECT count(*) FILTER(WHERE a.is_free AND a.receipt_time>clock_timestamp()-interval '24 hours') free_used,
 count(*) FILTER(WHERE a.is_free AND a.receipt_time>clock_timestamp()-interval '61 seconds') minute_used,
 count(*) FILTER(WHERE r.attempt_id IS NULL) in_flight,
 coalesce(sum(r.cost_nanos) FILTER(WHERE NOT a.is_free AND a.trigger<>'manual' AND a.receipt_time>=date_trunc('day',clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),0) paid_used_nanos,
 coalesce(sum(a.reserved_nanos) FILTER(WHERE NOT a.is_free AND a.trigger<>'manual' AND r.cost_nanos IS NULL),0) paid_reserved_nanos,
 count(*) FILTER(WHERE NOT a.is_free AND a.trigger<>'manual' AND a.receipt_time>clock_timestamp()-interval '24 hours') paid_attempts
 FROM openrouter_capacity_attempt a LEFT JOIN openrouter_capacity_result r USING(attempt_id))
 SELECT jsonb_build_object('policy',c.policy,'free_used',t.free_used,'free_remaining',greatest(0,1000-t.free_used),'minute_used',t.minute_used,'in_flight',t.in_flight,
 'queued',(SELECT count(*) FROM openrouter_capacity_queue WHERE state='queued'),
 'next_eligible_at',greatest(c.next_start,c.cooldown_until,CASE WHEN NOT c.history_known THEN c.installed_at+interval '24 hours' END),'cooldown_until',c.cooldown_until,'free_cooldown_until',c.free_cooldown_until,
 'paid_used_nanos',t.paid_used_nanos,'paid_reserved_nanos',t.paid_reserved_nanos,'paid_attempts',t.paid_attempts,
 'manual_paid_used_nanos',coalesce((SELECT sum(r.cost_nanos) FROM openrouter_capacity_attempt a JOIN openrouter_capacity_result r USING(attempt_id) WHERE a.trigger='manual'),0),
 'manual_paid_attempts',(SELECT count(*) FROM openrouter_capacity_attempt WHERE trigger='manual'),
 'daily_limited',(t.free_used>=1000 OR coalesce(c.daily_gate_until>clock_timestamp(),false)),
 'free_outage',((c.policy->>'paid_outage_enabled')::boolean AND jsonb_array_length(c.policy->'free_models')>0 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(c.policy->'free_models') x(model) LEFT JOIN openrouter_capacity_model m USING(model) WHERE m.first_failure IS NULL OR m.first_failure>clock_timestamp()-interval '10 minutes' OR m.cooldown_until IS NULL OR m.cooldown_until<=clock_timestamp())),
 'models',coalesce((SELECT jsonb_agg(to_jsonb(m)) FROM openrouter_capacity_model m),'[]'),
 'waiting',coalesce((SELECT jsonb_agg(v) FROM (SELECT jsonb_build_object('key',key,'purpose',purpose,'reason',reason,'next_eligible_at',eligible_at) v FROM openrouter_capacity_queue WHERE state='queued' ORDER BY created_at LIMIT 100) w),'[]'),
 'window_mode','rolling_24h','history_status',CASE WHEN NOT c.history_known AND clock_timestamp()<c.installed_at+interval '24 hours' THEN 'initial_history_hold' ELSE 'accounted' END)
 FROM c CROSS JOIN totals t
$$;
CREATE FUNCTION save_openrouter_capacity(expected bigint,new_policy jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE p jsonb; k text; BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 SELECT policy INTO p FROM openrouter_capacity_control;
 IF expected IS DISTINCT FROM (p->>'revision')::bigint THEN RETURN read_openrouter_capacity()||'{"status":"conflict"}'; END IF;
 IF jsonb_typeof(new_policy) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(new_policy) x WHERE NOT p ? x) THEN RAISE EXCEPTION 'invalid_capacity_policy'; END IF;
 p:=p||new_policy;
 FOREACH k IN ARRAY ARRAY['paused','paid_enabled','paid_outage_enabled','paid_model_open_weights_confirmed','prefer_free_models','paid_finish_on_429'] LOOP
  IF jsonb_typeof(p->k) IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'invalid_capacity_policy_boolean'; END IF;
 END LOOP;
 FOREACH k IN ARRAY ARRAY['paid_max_fallback_attempts','revision','daily_target','start_interval_ms','burst_remaining','paid_request_limit_nanos','paid_daily_limit_nanos','paid_monthly_limit_nanos','paid_attempt_limit'] LOOP
  IF jsonb_typeof(p->k) IS DISTINCT FROM 'number' OR p->>k !~ '^[0-9]{1,16}$' THEN RAISE EXCEPTION 'invalid_capacity_policy_integer'; END IF;
 END LOOP;
 IF jsonb_typeof(p->'mode') IS DISTINCT FROM 'string' OR p->>'mode' NOT IN ('paced','burst') OR (p->>'daily_target')::bigint NOT BETWEEN 1 AND 1000 OR (p->>'start_interval_ms')::bigint NOT BETWEEN 3100 AND 60000
 OR (p->>'burst_remaining')::bigint NOT BETWEEN 0 AND 100 OR (p->>'paid_request_limit_nanos')::bigint NOT BETWEEN 0 AND 1000000000
 OR (p->>'paid_daily_limit_nanos')::bigint NOT BETWEEN 0 AND 10000000000 OR (p->>'paid_monthly_limit_nanos')::bigint NOT BETWEEN 0 AND 100000000000
 OR (p->>'paid_attempt_limit')::bigint NOT BETWEEN 0 AND 100
 OR (p->'paid_model'<>'null'::jsonb AND (jsonb_typeof(p->'paid_model')<>'string' OR p->>'paid_model' !~ '^[a-zA-Z0-9._/-]{1,160}$'))
 OR ((p->>'paid_enabled')::boolean AND (((p->>'prefer_free_models')::boolean AND NOT (p->>'paid_model_open_weights_confirmed')::boolean) OR p->>'paid_model' IS NULL OR p->>'paid_model' LIKE '%:free')) THEN RAISE EXCEPTION 'invalid_capacity_policy_range'; END IF;
 IF (p->>'paid_max_fallback_attempts')::integer NOT BETWEEN 1 AND 2 THEN RAISE EXCEPTION 'invalid_paid_fallback_limit'; END IF;
 IF jsonb_typeof(p->'paid_models') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_paid_models'; END IF;
 IF jsonb_array_length(p->'paid_models')>16 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p->'paid_models') m WHERE jsonb_typeof(m)<>'string' OR m#>>'{}' !~ '^[a-zA-Z0-9._/-]{1,160}$') OR ((p->>'paid_enabled')::boolean AND NOT (p->'paid_models' ? (p->>'paid_model'))) THEN RAISE EXCEPTION 'invalid_paid_models'; END IF;
 IF jsonb_typeof(p->'free_models') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_free_models'; END IF;
 IF jsonb_array_length(p->'free_models')>16 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p->'free_models') m WHERE jsonb_typeof(m)<>'string' OR m#>>'{}' !~ '^[a-zA-Z0-9._/-]+:free$') THEN RAISE EXCEPTION 'invalid_free_models'; END IF;
 IF jsonb_typeof(p->'paid_role_models') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'invalid_paid_role_models'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(p->'paid_role_models') e WHERE e.key NOT IN ('research','setup','experiment','default') OR (e.value<>'null'::jsonb AND (jsonb_typeof(e.value)<>'string' OR NOT (p->'paid_models' ? (e.value#>>'{}'))))) THEN RAISE EXCEPTION 'invalid_paid_role_models'; END IF;
 p:=jsonb_set(p,'{revision}',to_jsonb(expected+1));
 UPDATE openrouter_capacity_control SET policy=p,next_start=greatest(clock_timestamp(),(SELECT max(receipt_time) FROM openrouter_capacity_attempt WHERE is_free)+(CASE WHEN p->>'mode'='burst' OR (p->>'burst_remaining')::integer>0 THEN (p->>'start_interval_ms')::bigint ELSE greatest((p->>'start_interval_ms')::bigint,86400000/(p->>'daily_target')::bigint) END)*interval '1 millisecond');
 UPDATE openrouter_capacity_queue SET eligible_at=clock_timestamp(),reason=NULL WHERE state='queued';
 RETURN read_openrouter_capacity()||'{"status":"saved"}';
END $$;
CREATE FUNCTION enqueue_openrouter_capacity(key_value text,request_value jsonb,purpose_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE q openrouter_capacity_queue%ROWTYPE; BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 SELECT * INTO q FROM openrouter_capacity_queue WHERE key=key_value;
 IF FOUND THEN
  IF q.fingerprint IS DISTINCT FROM encode(digest(request_value::text,'sha256'),'hex') OR q.purpose IS DISTINCT FROM purpose_value THEN RAISE EXCEPTION 'capacity_request_key_conflict'; END IF;
 ELSE
  IF jsonb_typeof(request_value) IS DISTINCT FROM 'object' OR octet_length(request_value::text)>160000 OR request_value->>'model' IS NULL THEN RAISE EXCEPTION 'capacity_model_required'; END IF;
  INSERT INTO openrouter_capacity_queue(key,request,purpose,fingerprint) VALUES(key_value,jsonb_strip_nulls(jsonb_build_object('model',request_value->'model','messages_sha256',encode(digest((request_value->'messages')::text,'sha256'),'hex'),'stream',request_value->'stream','max_tokens',request_value->'max_tokens','max_completion_tokens',request_value->'max_completion_tokens')),purpose_value,encode(digest(request_value::text,'sha256'),'hex')) RETURNING * INTO q;
 END IF;
 RETURN jsonb_build_object('status',q.state,'reason',q.reason,'key',q.key,'eligible_at',q.eligible_at);
END $$;
CREATE FUNCTION openrouter_capacity_ready(key_value text) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce((SELECT state='queued' AND eligible_at<=clock_timestamp() FROM openrouter_capacity_queue WHERE key=key_value),true)
$$;
CREATE FUNCTION cancel_openrouter_capacity(key_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 UPDATE openrouter_capacity_queue SET state='cancelled',reason='cancelled' WHERE key=key_value AND state='queued';
 RETURN jsonb_build_object('status',coalesce((SELECT state FROM openrouter_capacity_queue WHERE key=key_value),'absent'));
END $$;

CREATE FUNCTION try_openrouter_capacity(key_value text,model_value text,reserve_value bigint,trigger_value text,actual_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c openrouter_capacity_control%ROWTYPE; q openrouter_capacity_queue%ROWTYPE; p jsonb;
 at_time timestamptz; due timestamptz; reason_value text; free_value boolean; manual_value boolean; used bigint; n bigint;
 parent_key_value text; ordinal integer; parent_attempt openrouter_capacity_attempt%ROWTYPE; parent_result openrouter_capacity_result%ROWTYPE;
 daily_cost numeric; monthly_cost numeric; pending_cost numeric; id_value text; interval_ms bigint; model_due timestamptz;
BEGIN
 PERFORM pg_advisory_xact_lock(68001,1);
 at_time:=clock_timestamp();
 -- A dead process must not hold all concurrency slots forever. Its dispatch and
 -- unknown spending remain consumed; only its in-flight slot is retired.
 INSERT INTO openrouter_capacity_result(attempt_id,outcome,receipt_time,source_lineage,record_environment)
 SELECT a.attempt_id,'{"state":"indeterminate","reason":"dispatch_timeout","cost_nanos":null}',at_time,a.source_lineage,a.record_environment
 FROM openrouter_capacity_attempt a LEFT JOIN openrouter_capacity_result r USING(attempt_id)
 WHERE r.attempt_id IS NULL AND a.receipt_time<at_time-interval '150 seconds';
 SELECT * INTO c FROM openrouter_capacity_control;
 p:=c.policy;
 SELECT * INTO q FROM openrouter_capacity_queue WHERE key=key_value;
 IF NOT FOUND THEN RETURN '{"status":"blocked","reason":"not_queued"}'; END IF;
 IF q.state='dispatched' OR EXISTS(SELECT 1 FROM openrouter_capacity_attempt WHERE key=key_value) THEN RETURN '{"status":"already_dispatched","reason":"immutable_dispatch"}'; END IF;
 IF q.state='cancelled' THEN RETURN '{"status":"blocked","reason":"cancelled"}'; END IF;
 IF actual_request->>'model' IS DISTINCT FROM model_value OR jsonb_typeof(actual_request) IS DISTINCT FROM 'object' OR octet_length(actual_request::text)>160000
 OR actual_request ? 'models' OR NOT incubator_request_output_is_bounded(actual_request) THEN RAISE EXCEPTION 'invalid_actual_capacity_request'; END IF;
 IF encode(digest((actual_request->'messages')::text,'sha256'),'hex') IS DISTINCT FROM q.request->>'messages_sha256' OR actual_request->'stream' IS DISTINCT FROM q.request->'stream'
 OR coalesce(actual_request->'max_tokens',actual_request->'max_completion_tokens') IS DISTINCT FROM coalesce(q.request->'max_tokens',q.request->'max_completion_tokens') THEN RETURN '{"status":"blocked","reason":"capacity_payload_changed"}'; END IF;
 free_value:=model_value ~ '^[a-zA-Z0-9._/-]+:free$';
 manual_value:=NOT free_value AND trigger_value='manual';
 IF manual_value AND (q.purpose<>'manual' OR q.request->>'model' IS DISTINCT FROM model_value) THEN RETURN '{"status":"blocked","reason":"manual_authorization_required"}'; END IF;
 IF reserve_value IS NULL OR reserve_value<0 OR trigger_value IS NULL THEN RAISE EXCEPTION 'invalid_capacity_reservation'; END IF;
 IF free_value AND (reserve_value<>0 OR actual_request->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb) THEN RAISE EXCEPTION 'free_price_caps_required'; END IF;
 IF free_value AND encode(digest(actual_request::text,'sha256'),'hex') IS DISTINCT FROM q.fingerprint THEN RETURN '{"status":"blocked","reason":"free_request_changed"}'; END IF;
 -- A backward jump cannot mint capacity. A forward jump cannot release accumulated
 -- slots: last_clock and next_start advance only with database-clock admission.
 IF at_time<c.last_clock THEN
  UPDATE openrouter_capacity_control SET policy=jsonb_set(policy,'{paused}','true');
  RETURN '{"status":"blocked","reason":"clock_regressed"}';
 END IF;
 UPDATE openrouter_capacity_control SET last_clock=at_time;
 due:=at_time;
 IF (p->>'paused')::boolean THEN reason_value:='paused'; due:=at_time+interval '60 seconds'; END IF;
 IF NOT manual_value AND NOT c.history_known AND c.installed_at+interval '24 hours'>due THEN reason_value:='initial_history_hold'; due:=c.installed_at+interval '24 hours'; END IF;
 SELECT count(*) INTO used FROM openrouter_capacity_attempt WHERE is_free AND receipt_time>at_time-interval '24 hours';
 SELECT cooldown_until INTO model_due FROM openrouter_capacity_model WHERE model=model_value;
 IF model_due>due THEN due:=model_due; reason_value:='provider_cooldown'; END IF;
 IF c.cooldown_until>due THEN due:=c.cooldown_until; reason_value:='account_cooldown'; END IF;
 IF free_value THEN
  IF c.free_cooldown_until>due THEN due:=c.free_cooldown_until; reason_value:='free_minute_cooldown'; END IF;
  IF used>=1000 THEN
   SELECT min(receipt_time)+interval '24 hours' INTO model_due FROM openrouter_capacity_attempt WHERE is_free AND receipt_time>at_time-interval '24 hours';
   IF model_due>due THEN due:=model_due; reason_value:='daily_free_exhausted'; END IF;
  END IF;
  IF c.daily_gate_until>due THEN due:=c.daily_gate_until; reason_value:='daily_free_exhausted'; END IF;
  SELECT count(*) INTO n FROM openrouter_capacity_attempt WHERE is_free AND receipt_time>at_time-interval '61 seconds';
  IF n>=20 THEN
   SELECT receipt_time+interval '61 seconds' INTO model_due FROM openrouter_capacity_attempt WHERE is_free AND receipt_time>at_time-interval '61 seconds' ORDER BY receipt_time OFFSET (n-20) LIMIT 1;
   IF model_due>due THEN due:=model_due; reason_value:='minute_capacity'; END IF;
  END IF;
 ELSIF NOT manual_value THEN
  IF NOT (p->>'paid_enabled')::boolean OR ((p->>'prefer_free_models')::boolean AND NOT (p->>'paid_model_open_weights_confirmed')::boolean) OR NOT (p->'paid_models' ? model_value) THEN
   RETURN '{"status":"blocked","reason":"paid_model_not_enabled"}'; END IF;
  IF trigger_value='paid_primary' THEN
   IF (p->>'prefer_free_models')::boolean THEN RETURN '{"status":"blocked","reason":"free_preference_enabled"}'; END IF;
  ELSIF trigger_value='finish_after_429' THEN
   IF NOT (p->>'paid_finish_on_429')::boolean OR key_value !~ ':paid:[12]$' THEN RETURN '{"status":"blocked","reason":"paid_finish_not_enabled"}'; END IF;
   ordinal:=right(key_value,1)::integer;
   parent_key_value:=regexp_replace(key_value,':paid:[12]$','');
   SELECT * INTO parent_attempt FROM openrouter_capacity_attempt WHERE key=parent_key_value AND is_free;
   SELECT * INTO parent_result FROM openrouter_capacity_result WHERE attempt_id=parent_attempt.attempt_id;
   IF ordinal>(p->>'paid_max_fallback_attempts')::integer OR parent_attempt.attempt_id IS NULL OR parent_result.outcome->>'state' IS DISTINCT FROM 'failed' OR parent_result.outcome->>'http_status' IS DISTINCT FROM '429'
   OR coalesce(parent_result.outcome->>'limit_scope','unknown') NOT IN ('minute','daily','provider') OR parent_result.receipt_time<at_time-interval '5 minutes'
   OR NOT EXISTS(SELECT 1 FROM openrouter_capacity_queue parent WHERE parent.key=parent_key_value AND parent.fingerprint=q.fingerprint AND parent.purpose=q.purpose) THEN RETURN '{"status":"blocked","reason":"paid_finish_parent_required"}'; END IF;
   IF ordinal=2 AND NOT EXISTS(SELECT 1 FROM openrouter_capacity_attempt previous JOIN openrouter_capacity_result result USING(attempt_id) WHERE previous.key=parent_key_value||':paid:1' AND previous.trigger='finish_after_429' AND result.outcome->>'state'='failed' AND result.outcome->>'http_status'='429' AND result.receipt_time>=at_time-interval '5 minutes') THEN RETURN '{"status":"blocked","reason":"paid_finish_previous_required"}'; END IF;
  ELSIF trigger_value='daily_free_exhausted' THEN
   IF used<1000 AND (c.daily_gate_until IS NULL OR c.daily_gate_until<=at_time) THEN RETURN '{"status":"blocked","reason":"free_capacity_available"}'; END IF;
  ELSIF trigger_value='free_capacity_unavailable' THEN
   IF NOT (p->>'paid_outage_enabled')::boolean OR jsonb_array_length(p->'free_models')=0 OR EXISTS(
    SELECT 1 FROM jsonb_array_elements_text(p->'free_models') x(model) LEFT JOIN openrouter_capacity_model m USING(model)
    WHERE m.first_failure IS NULL OR m.first_failure>at_time-interval '10 minutes' OR m.cooldown_until IS NULL OR m.cooldown_until<=at_time
   ) THEN RETURN '{"status":"blocked","reason":"free_outage_unproven"}'; END IF;
  ELSE RETURN '{"status":"blocked","reason":"invalid_paid_trigger"}'; END IF;
  IF NOT c.history_known AND c.installed_at+interval '24 hours'>at_time THEN RETURN '{"status":"blocked","reason":"unknown_free_history"}'; END IF;
  IF reserve_value<=0 OR reserve_value>(p->>'paid_request_limit_nanos')::bigint OR jsonb_typeof(actual_request->'provider'->'max_price') IS DISTINCT FROM 'object' THEN RETURN '{"status":"blocked","reason":"paid_reservation_required"}'; END IF;
  SELECT coalesce(sum(r.cost_nanos) FILTER(WHERE a.receipt_time>=date_trunc('day',at_time AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),0),
   coalesce(sum(r.cost_nanos) FILTER(WHERE a.receipt_time>=date_trunc('month',at_time AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),0),
   coalesce(sum(a.reserved_nanos) FILTER(WHERE r.cost_nanos IS NULL),0),
   count(*) FILTER(WHERE a.receipt_time>at_time-interval '24 hours')
  INTO daily_cost,monthly_cost,pending_cost,n FROM openrouter_capacity_attempt a LEFT JOIN openrouter_capacity_result r USING(attempt_id) WHERE NOT a.is_free AND a.trigger<>'manual';
  IF daily_cost+pending_cost+reserve_value>(p->>'paid_daily_limit_nanos')::bigint OR monthly_cost+pending_cost+reserve_value>(p->>'paid_monthly_limit_nanos')::bigint OR n>=(p->>'paid_attempt_limit')::bigint THEN
   due:=greatest(due,at_time+interval '60 seconds'); reason_value:='paid_budget';
  END IF;
  SELECT max(receipt_time)+interval '12 seconds' INTO model_due FROM openrouter_capacity_attempt WHERE NOT is_free AND trigger<>'manual';
  IF model_due>due THEN due:=model_due; reason_value:='paid_pacing'; END IF;
 END IF;
 SELECT count(*) INTO n FROM openrouter_capacity_attempt a LEFT JOIN openrouter_capacity_result r USING(attempt_id) WHERE r.attempt_id IS NULL;
 IF n>=4 THEN due:=greatest(due,at_time+interval '5 seconds'); reason_value:='in_flight_capacity'; END IF;
 IF free_value AND c.next_start>due THEN due:=c.next_start; reason_value:='pacing'; END IF;
 IF due>at_time THEN
  UPDATE openrouter_capacity_queue SET eligible_at=due,reason=reason_value WHERE key=key_value;
  RETURN jsonb_build_object('status','waiting','reason',reason_value,'wait_ms',greatest(1,ceil(extract(epoch FROM due-at_time)*1000)::bigint));
 END IF;
 id_value:=gen_random_uuid()::text;
 INSERT INTO openrouter_capacity_attempt(attempt_id,key,parent_key,fallback_ordinal,model,request_fingerprint,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
 VALUES(id_value,key_value,parent_key_value,ordinal,model_value,encode(digest(actual_request::text,'sha256'),'hex'),free_value,reserve_value,(p->>'revision')::bigint,trigger_value,at_time,'{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research');
 interval_ms:=CASE WHEN NOT free_value THEN 12000 WHEN p->>'mode'='burst' OR (p->>'burst_remaining')::integer>0 THEN (p->>'start_interval_ms')::bigint ELSE greatest((p->>'start_interval_ms')::bigint,86400000/(p->>'daily_target')::bigint) END;
 IF free_value AND (p->>'burst_remaining')::integer>0 THEN p:=jsonb_set(p,'{burst_remaining}',to_jsonb((p->>'burst_remaining')::integer-1)); END IF;
 UPDATE openrouter_capacity_control SET next_start=CASE WHEN NOT free_value THEN next_start ELSE at_time+interval_ms*interval '1 millisecond' END,policy=p;
 UPDATE openrouter_capacity_queue SET state='dispatched',reason=NULL WHERE key=key_value;
 RETURN jsonb_build_object('status','admitted','attempt_id',id_value,'wait_ms',0);
END $$;

CREATE FUNCTION finish_openrouter_capacity(id_value text,outcome_value jsonb) RETURNS jsonb
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
  UPDATE openrouter_capacity_model SET first_failure=NULL,last_failure=NULL,cooldown_until=NULL WHERE model=a.model;
  IF a.is_free THEN UPDATE openrouter_capacity_control SET daily_gate_until=NULL; END IF;
 END IF;
 RETURN '{"status":"recorded"}';
END $$;
REVOKE ALL ON FUNCTION read_openrouter_capacity(),save_openrouter_capacity(bigint,jsonb),enqueue_openrouter_capacity(text,jsonb,text),openrouter_capacity_ready(text),cancel_openrouter_capacity(text),try_openrouter_capacity(text,text,bigint,text,jsonb),finish_openrouter_capacity(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_openrouter_capacity(),enqueue_openrouter_capacity(text,jsonb,text),openrouter_capacity_ready(text),cancel_openrouter_capacity(text),try_openrouter_capacity(text,text,bigint,text,jsonb),finish_openrouter_capacity(text,jsonb) TO incubator_runner,incubator_chat;
GRANT EXECUTE ON FUNCTION save_openrouter_capacity(bigint,jsonb) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();
