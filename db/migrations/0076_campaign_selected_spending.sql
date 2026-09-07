-- Explicit campaign model selection authorizes only its exact creator request.
CREATE OR REPLACE FUNCTION try_openrouter_capacity(key_value text,model_value text,reserve_value bigint,trigger_value text,actual_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c openrouter_capacity_control%ROWTYPE; q openrouter_capacity_queue%ROWTYPE; p jsonb;
 at_time timestamptz; due timestamptz; reason_value text; free_value boolean; manual_value boolean; used bigint; n bigint;
 parent_key_value text; ordinal integer; parent_attempt openrouter_capacity_attempt%ROWTYPE; parent_result openrouter_capacity_result%ROWTYPE;
 daily_cost numeric; monthly_cost numeric; pending_cost numeric; id_value text; interval_ms bigint; model_due timestamptz; generation_id bigint;
BEGIN
 IF trigger_value='campaign_selection' THEN PERFORM 1 FROM incubator_campaign WHERE id FOR UPDATE; END IF;
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
 IF trigger_value='campaign_selection' THEN
 IF key_value !~ '^ticket-creator:[0-9]{1,19}$' OR NOT pg_input_is_valid(split_part(key_value,':',2),'bigint') THEN RETURN '{"status":"blocked","reason":"campaign_selection_required"}'; END IF;
  IF session_user IS DISTINCT FROM 'incubator_runner' AND current_setting('role',true) IS DISTINCT FROM 'incubator_runner' THEN RETURN '{"status":"blocked","reason":"campaign_selection_required"}'; END IF;
  generation_id:=split_part(key_value,':',2)::bigint;
  IF free_value OR q.purpose<>'ticket_creator' OR q.request->>'model' IS DISTINCT FROM model_value OR NOT EXISTS(
   SELECT 1 FROM incubator_ticket_generation g JOIN incubator_campaign selected_campaign ON selected_campaign.id WHERE g.id=generation_id
   AND g.state='queued' AND g.request IS NOT NULL AND g.model=model_value AND q.fingerprint=encode(digest(g.request::text,'sha256'),'hex')
   AND (actual_request #- '{provider,max_price}') IS NOT DISTINCT FROM (g.request #- '{provider,max_price}')
   AND selected_campaign.enabled AND selected_campaign.creator_model=model_value AND selected_campaign.revision=g.campaign_revision
  ) THEN RETURN '{"status":"blocked","reason":"campaign_selection_required"}'; END IF;
 END IF;
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
  IF trigger_value<>'campaign_selection' AND (NOT (p->>'paid_enabled')::boolean OR ((p->>'prefer_free_models')::boolean AND NOT (p->>'paid_model_open_weights_confirmed')::boolean) OR NOT (p->'paid_models' ? model_value)) THEN
   RETURN '{"status":"blocked","reason":"paid_model_not_enabled"}'; END IF;
  IF trigger_value='campaign_selection' THEN NULL;
  ELSIF trigger_value='paid_primary' THEN
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
CREATE INDEX incubator_ticket_generation_active_idx ON incubator_ticket_generation(id) WHERE state IN('queued','dispatching');
CREATE FUNCTION read_incubator_campaign_fence() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('enabled',enabled,'revision',revision) FROM incubator_campaign WHERE id
$$;
REVOKE ALL ON FUNCTION read_incubator_campaign_fence() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_campaign_fence() TO incubator_runner;
CREATE OR REPLACE FUNCTION read_incubator_campaign() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT to_jsonb(c)-'id'||jsonb_build_object('open_count',incubator_campaign_open_count(),'target',10,'created_count',(SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued'),
 'completed_count',(SELECT count(*) FROM incubator_campaign_attempt a WHERE a.state='queued' AND EXISTS(SELECT 1 FROM incubator_evaluation e WHERE (e.run_key=a.run_key OR e.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) AND read_incubator_experiment(e.id)->>'status'='completed')),
 'attempts_today',(SELECT count(*) FROM incubator_campaign_attempt WHERE receipt_time>clock_timestamp()-interval '24 hours'),
 'symbols','["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","AVGO","JPM","JNJ","V","UNH","PG","MA","HD","DIS","PYPL","ADBE","CRM","NFLX"]'::jsonb,
 'backlog_count',(SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt)),
 'creator_in_progress',EXISTS(SELECT 1 FROM incubator_ticket_generation WHERE state IN('queued','dispatching')),'creator_status',(SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 1),
 'creator_usage',jsonb_build_object('lifetime',read_incubator_ticket_usage('-infinity'),'last_24h',read_incubator_ticket_usage(now()-interval '24 hours')),
 'creator_calls',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT g.id,g.model,g.state,a.receipt_time AS started_at,g.detail->'usage' AS usage,r.cost_nanos::numeric/1000000000 AS cost_usd FROM incubator_ticket_generation g JOIN openrouter_capacity_attempt a ON a.key='ticket-creator:'||g.id LEFT JOIN openrouter_capacity_result r USING(attempt_id) ORDER BY g.id DESC LIMIT 20) x),'[]'::jsonb),
 'agenda_limit',100,'agenda',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',p.ordinal,'generation_id',p.generation_id,'title',p.title,'spec',p.spec,'state',coalesce(a.state,'pending'),'reason',a.reason,'run_key',a.run_key,'scope',a.scope) ORDER BY p.ordinal)
 FROM (SELECT * FROM incubator_campaign_candidate ORDER BY ordinal DESC LIMIT 100) p LEFT JOIN incubator_campaign_attempt a USING(ordinal)),'[]'::jsonb)) FROM incubator_campaign c
$$;
