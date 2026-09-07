-- One Research Scout retry after an unusable reply. Campaign workers may use the paid creator.
ALTER TABLE incubator_campaign_attempt DROP CONSTRAINT incubator_campaign_attempt_model_check;
ALTER TABLE incubator_campaign_attempt ADD CONSTRAINT incubator_campaign_attempt_model_check CHECK(model ~ '^[a-zA-Z0-9._/:~-]+$' AND model NOT LIKE 'openrouter/%' AND char_length(model)<=256);
ALTER TABLE incubator_agent_event DROP CONSTRAINT IF EXISTS incubator_agent_event_state_check;
ALTER TABLE incubator_agent_event ADD CONSTRAINT incubator_agent_event_state_check CHECK(state IN('admitted','preparing','dispatched','completed','failed','indeterminate','research_retry'));

CREATE FUNCTION incubator_research_retry_available(key_value text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT EXISTS(SELECT 1 FROM incubator_agent_event last_event
  WHERE last_event.run_key=key_value AND last_event.sequence=(SELECT max(sequence) FROM incubator_agent_event WHERE run_key=key_value)
  AND last_event.state='failed' AND last_event.detail->>'reason' IN('incomplete_response','invalid_report'))
 AND NOT EXISTS(SELECT 1 FROM incubator_agent_event WHERE run_key=key_value AND state IN('research_retry','completed'))
 AND NOT coalesce((SELECT archived FROM incubator_research_archive_event WHERE run_key=key_value ORDER BY sequence DESC LIMIT 1),false)
 AND (SELECT count(*) FROM incubator_agent_event WHERE run_key=key_value AND state='dispatched')<2
$$;
REVOKE ALL ON FUNCTION incubator_research_retry_available(text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION record_incubator_agent_event(key_value text, state_value text, detail_value jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
 run_row incubator_agent_run%ROWTYPE;
 prior incubator_agent_event%ROWTYPE;
 spec_value jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(53001);
 SELECT * INTO run_row FROM incubator_agent_run WHERE run_key=key_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown run' USING ERRCODE='22023'; END IF;
 SELECT * INTO prior FROM incubator_agent_event WHERE run_key=key_value ORDER BY sequence DESC LIMIT 1;
 IF prior.state=state_value AND prior.detail=detail_value THEN RETURN read_incubator_agent_run(key_value); END IF;
 IF detail_value IS NULL OR jsonb_typeof(detail_value) <> 'object' OR octet_length(detail_value::text)>64000
    OR incubator_json_claims_authority(detail_value) THEN
   RAISE EXCEPTION 'invalid run event' USING ERRCODE='22023'; END IF;
 IF state_value='research_retry' AND NOT incubator_research_retry_available(key_value) THEN RAISE EXCEPTION 'research_retry_unavailable' USING ERRCODE='55000'; END IF;
 IF NOT ((prior.state='admitted' AND state_value IN ('preparing','dispatched','failed'))
      OR (prior.state='preparing' AND state_value IN ('dispatched','failed'))
      OR (prior.state='dispatched' AND state_value IN ('completed','failed','indeterminate'))
      OR (prior.state='failed' AND state_value='research_retry')
      OR (prior.state='research_retry' AND state_value IN ('preparing','failed'))) THEN
   RAISE EXCEPTION 'invalid run transition; no redispatch or terminal rewrite' USING ERRCODE='55000';
 END IF;
 IF state_value='completed' AND jsonb_typeof(detail_value->'report') IS DISTINCT FROM 'object' THEN
   RAISE EXCEPTION 'completed run requires a report' USING ERRCODE='22023'; END IF;
 IF state_value IN ('preparing','dispatched') AND EXISTS (
   SELECT 1 FROM incubator_agent_run r JOIN LATERAL
    (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
   WHERE r.run_key<>key_value AND e.state IN ('preparing','dispatched','indeterminate')) THEN
  RAISE EXCEPTION 'research lane occupied' USING ERRCODE='55000';
 END IF;
 INSERT INTO incubator_agent_event VALUES(key_value,prior.sequence+1,state_value,detail_value,
   run_row.source_lineage,clock_timestamp(),'local_research');
 IF state_value IN ('completed','failed') AND NOT incubator_research_retry_available(key_value) THEN
   SELECT spec INTO spec_value FROM incubator_assignment WHERE assignment_id=run_row.assignment_id;
   PERFORM record_alpha_shot(spec_value,jsonb_build_object('outcome',state_value,
     'artifact_kind','research_planning_report','run_key',key_value,'detail',detail_value),NULL,
     CASE WHEN state_value='failed' THEN coalesce(detail_value->>'reason','run_failed') ELSE NULL END,
     run_row.source_lineage);
 END IF;
 PERFORM append_audit_event('agent-poc:'||key_value||':'||(prior.sequence+1)::text,
   'research.agent_'||state_value,now(),jsonb_build_object('run_key',key_value,'detail',detail_value),
   run_row.source_lineage,now(),'local_research');
 RETURN read_incubator_agent_run(key_value);
END;
$$;

CREATE OR REPLACE FUNCTION read_incubator_agent_run(key_value text) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_incubator_agent_run_before_campaign(key_value)||CASE WHEN EXISTS(SELECT 1 FROM incubator_campaign_attempt WHERE run_key=key_value) THEN '{"created_by":"agent"}'::jsonb ELSE '{}'::jsonb END||jsonb_build_object('research_retry_available',incubator_research_retry_available(key_value))
$$;

CREATE OR REPLACE FUNCTION next_incubator_manual_run_before_campaign() RETURNS text
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT r.run_key FROM incubator_agent_run r JOIN LATERAL
 (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE (r.run_key IN(SELECT run_key FROM incubator_manual_request)
 OR r.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback f JOIN incubator_manual_request m ON m.run_key=f.parent_run_key))
 AND NOT coalesce((SELECT archived FROM incubator_research_archive_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1),false)
 AND (e.state IN('admitted','preparing','dispatched','research_retry') OR (e.state='failed' AND incubator_research_retry_available(r.run_key)))
 AND (e.state IN('preparing','dispatched')
  OR (e.state IN('admitted','failed') AND openrouter_capacity_ready('research:'||r.run_key))
  OR (e.state='research_retry' AND openrouter_capacity_ready('research:'||r.run_key||':retry')))
 AND NOT EXISTS(SELECT 1 FROM incubator_agent_run x JOIN LATERAL(SELECT state FROM incubator_agent_event WHERE run_key=x.run_key ORDER BY sequence DESC LIMIT 1)y ON true WHERE y.state='indeterminate')
 ORDER BY (e.state IN('preparing','dispatched')) DESC,r.receipt_time,r.run_key LIMIT 1
$$;

CREATE OR REPLACE FUNCTION next_incubator_manual_run() RETURNS text
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(next_incubator_manual_run_before_campaign(),(SELECT r.run_key FROM incubator_campaign_attempt a
 JOIN incubator_agent_run r ON (r.run_key=a.run_key OR r.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) JOIN LATERAL(SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE a.state='queued' AND NOT coalesce((SELECT archived FROM incubator_research_archive_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1),false)
 AND (e.state IN('admitted','preparing','dispatched','research_retry') OR (e.state='failed' AND incubator_research_retry_available(r.run_key)))
 AND (e.state IN('preparing','dispatched')
  OR (e.state IN('admitted','failed') AND openrouter_capacity_ready('research:'||r.run_key))
  OR (e.state='research_retry' AND openrouter_capacity_ready('research:'||r.run_key||':retry')))
 AND NOT EXISTS(SELECT 1 FROM incubator_agent_run x WHERE read_incubator_agent_run(x.run_key)->>'state'='indeterminate')
 ORDER BY (e.state IN('preparing','dispatched')) DESC,r.receipt_time LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION admit_incubator_brief(key_value text, model_value text, brief_value jsonb, queued boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
 existing incubator_agent_run%ROWTYPE;
 assignment incubator_assignment%ROWTYPE;
 budget jsonb := '{"max_requests":1,"max_output_tokens":2048,"timeout_seconds":120,"max_cost_usd":0}'::jsonb;
 stopping jsonb := '"Stop after one response or one automatic retry of an unusable reply; never invent a second research identity."'::jsonb;
 lineage jsonb := '{"source":"incubator-agent-poc","entitlement_version":"project-authored-brief-v1"}'::jsonb;
 config_value jsonb;
 manual_spend boolean := queued AND key_value = 'manual-' || substring(brief_value->>'key' from 8) AND brief_value->>'key' LIKE 'manual:%';
 campaign_spend boolean := queued AND key_value ~ '^campaign-pilot-v1-[0-9]{1,10}$' AND model_value IS NOT NULL AND model_value !~ '^[a-zA-Z0-9._/-]+:free$' AND model_value=(SELECT creator_model FROM incubator_campaign);
BEGIN
 IF key_value IS NULL OR key_value !~ '^[a-zA-Z0-9_-]{1,96}$'
    OR model_value IS NULL OR length(model_value) > 256 OR model_value !~ '^[a-zA-Z0-9._/:~-]+$' OR (NOT coalesce(manual_spend,false) AND NOT campaign_spend AND model_value !~ '^[a-zA-Z0-9._/-]+:free$')
    OR model_value LIKE 'openrouter/%' THEN
   RAISE EXCEPTION 'invalid run identity or zero-spend model' USING ERRCODE='22023';
 END IF;
 IF brief_value IS NULL OR jsonb_typeof(brief_value) <> 'object'
    OR brief_value->>'classification' IS DISTINCT FROM 'project_authored_research_brief'
    OR brief_value->>'permitted_destination' IS DISTINCT FROM 'openrouter'
    OR octet_length(brief_value->>'text') NOT BETWEEN 1 AND 6000
    OR coalesce(length(btrim(brief_value->>'text')),0)=0
    OR octet_length(brief_value->>'title') NOT BETWEEN 1 AND 240
    OR coalesce(length(btrim(brief_value->>'title')),0)=0 THEN
   RAISE EXCEPTION 'invalid owner-authored research brief' USING ERRCODE='22023';
 END IF;
 PERFORM pg_advisory_xact_lock(53001);
 SELECT * INTO existing FROM incubator_agent_run WHERE run_key=key_value;
 IF FOUND THEN
   IF existing.config->>'model' IS DISTINCT FROM model_value OR existing.config->'input' IS DISTINCT FROM brief_value THEN
     RAISE EXCEPTION 'run key already binds a different model' USING ERRCODE='22023';
   END IF;
   RETURN read_incubator_agent_run(key_value);
 END IF;
 IF NOT queued AND EXISTS (SELECT 1 FROM incubator_agent_run r JOIN LATERAL
     (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
     WHERE e.state IN ('admitted','preparing','dispatched','indeterminate')) THEN
   RAISE EXCEPTION 'research lane occupied; inspect the existing run' USING ERRCODE='55000';
 END IF;
 IF manual_spend THEN
   budget := (budget - 'max_cost_usd') || '{"spend_policy":"owner_selected_model"}'::jsonb;
 ELSIF campaign_spend THEN
   budget := (budget - 'max_cost_usd') || '{"spend_policy":"campaign_selected_model"}'::jsonb;
 END IF;
 config_value := jsonb_build_object('agent_name','Research Scout','role','quantitative_research_and_experimentation',
   'manual_model_spend',coalesce(manual_spend,false),'campaign_model_spend',coalesce(campaign_spend,false),'provider','openrouter','model',model_value,'input',brief_value, 'limits',budget,
   'prompt_version','research-scout-v1','output_schema','hypothesis-report-v1');
 assignment := engine_admit_research_assignment(jsonb_build_object(
   'assignment_key','agent-poc:'||key_value,'lane','research','desk_role',config_value->>'role',
   'budget',budget,'stopping_rule',stopping,
   'profit_contribution_hypothesis',jsonb_build_object(
      'claim',brief_value->>'text',
      'metric','One testable hypothesis, evidence gaps, and a falsification experiment; no measured return claim.',
      'cost_envelope',budget,'stopping_rule',stopping)),lineage);
 INSERT INTO incubator_agent_run VALUES(key_value,assignment.assignment_id,config_value,lineage,clock_timestamp(),'local_research');
 INSERT INTO incubator_agent_event VALUES(key_value,1,'admitted','{}',lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('agent-poc:'||key_value||':1','research.agent_admitted',now(),
   jsonb_build_object('run_key',key_value,'config',config_value),lineage,now(),'local_research');
 RETURN read_incubator_agent_run(key_value);
END;
$$;

CREATE OR REPLACE FUNCTION claim_incubator_campaign(model_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; scope_value jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE state='checking' ORDER BY ordinal LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(a)||jsonb_build_object('fresh',false); END IF;
 IF clock_timestamp()<c.next_at THEN RETURN NULL; END IF;
 IF (SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued' AND receipt_time>clock_timestamp()-interval '24 hours')>=c.daily_limit OR incubator_campaign_open_count()>=c.open_limit THEN RETURN NULL; END IF;
 IF model_value IS NULL OR model_value LIKE 'openrouter/%' OR length(model_value)>256 OR model_value !~ '^[a-zA-Z0-9._/:~-]+$'
  OR (model_value !~ '^[a-zA-Z0-9._/-]+:free$' AND model_value IS DISTINCT FROM c.creator_model) THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for an approved campaign Research model. Configure Models or the Ticket Creator model to continue.'; END IF;
  RETURN NULL;
 END IF;
 SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt) ORDER BY ordinal LIMIT 1;
 IF NOT FOUND THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for Ticket Creator to stock the backlog.'; END IF;
  RETURN NULL;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM market_data_source WHERE market_data_source_available(id)) THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for an available market data connection.'; END IF;
  RETURN NULL;
 END IF;
 BEGIN
  scope_value:=incubator_campaign_scope();
 EXCEPTION WHEN raise_exception THEN
  UPDATE incubator_campaign SET enabled=false,note='The supported calendar cannot supply 60 completed sessions. Update calendar coverage before resuming.'; RETURN NULL;
 END;
 INSERT INTO incubator_campaign_attempt(ordinal,request_id,campaign_revision,scope,model,state) VALUES(p.ordinal,'campaign-pilot-v1-'||p.ordinal,c.revision,scope_value,model_value,'checking') RETURNING * INTO a;
 UPDATE incubator_campaign SET next_at=clock_timestamp()+interval '10 seconds',note=CASE WHEN c.enabled THEN 'Checking the next research question against assignment history.' ELSE note END;
 PERFORM append_audit_event(a.request_id||':claimed','research.campaign_candidate_claimed',now(),to_jsonb(a),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN to_jsonb(a)||jsonb_build_object('fresh',true,'title',p.title,'text',p.premise||E'\nExact diagnostic spec: '||p.spec::text);
END $$;

CREATE FUNCTION incubator_campaign_paid_authorized(key_value text,model_value text,purpose text,actual_request jsonb,fingerprint text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; request_id text; generation_id bigint;
BEGIN
 IF session_user IS DISTINCT FROM 'incubator_runner' AND current_setting('role',true) IS DISTINCT FROM 'incubator_runner' THEN RETURN false; END IF;
 IF model_value ~ '^[a-zA-Z0-9._/-]+:free$' OR model_value LIKE 'openrouter/%' THEN RETURN false; END IF;
 SELECT * INTO STRICT c FROM incubator_campaign;
 IF c.creator_model IS DISTINCT FROM model_value THEN RETURN false; END IF;
 IF key_value ~ '^ticket-creator:[0-9]{1,19}$' AND pg_input_is_valid(split_part(key_value,':',2),'bigint') THEN
  generation_id:=split_part(key_value,':',2)::bigint;
  RETURN purpose='ticket_creator' AND c.enabled AND EXISTS(
   SELECT 1 FROM incubator_ticket_generation g WHERE g.id=generation_id AND g.state='queued' AND g.request IS NOT NULL AND g.model=model_value
   AND fingerprint=encode(digest(g.request::text,'sha256'),'hex')
   AND (actual_request #- '{provider,max_price}') IS NOT DISTINCT FROM (g.request #- '{provider,max_price}')
   AND c.revision=g.campaign_revision);
 END IF;
 IF key_value ~ '^similarity:campaign-pilot-v1-[0-9]{1,10}$' THEN
  request_id:=split_part(key_value,':',2);
  RETURN purpose='similarity' AND EXISTS(SELECT 1 FROM incubator_campaign_attempt a WHERE a.request_id=request_id AND a.model=model_value AND a.state IN('checking','queued'));
 END IF;
 IF key_value ~ '^research:campaign-pilot-v1-[0-9]{1,10}(:retry)?$' THEN
  request_id:=split_part(key_value,':',2);
  RETURN purpose='research' AND EXISTS(SELECT 1 FROM incubator_campaign_attempt a WHERE a.request_id=request_id AND a.state='queued');
 END IF;
 RETURN false;
END $$;
REVOKE ALL ON FUNCTION incubator_campaign_paid_authorized(text,text,text,jsonb,text) FROM PUBLIC;

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
  IF NOT incubator_campaign_paid_authorized(key_value,model_value,q.purpose,actual_request,q.fingerprint) THEN RETURN '{"status":"blocked","reason":"campaign_selection_required"}'; END IF;
 END IF;
 IF manual_value AND (q.purpose<>'manual' OR q.request->>'model' IS DISTINCT FROM model_value) THEN RETURN '{"status":"blocked","reason":"manual_authorization_required"}'; END IF;
 IF reserve_value IS NULL OR reserve_value<0 OR trigger_value IS NULL THEN RAISE EXCEPTION 'invalid_capacity_reservation'; END IF;
 IF free_value AND (reserve_value<>0 OR actual_request->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb) THEN RAISE EXCEPTION 'free_price_caps_required'; END IF;
 IF free_value AND encode(digest(actual_request::text,'sha256'),'hex') IS DISTINCT FROM q.fingerprint THEN RETURN '{"status":"blocked","reason":"free_request_changed"}'; END IF;
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

REVOKE ALL ON FUNCTION incubator_research_retry_available(text),record_incubator_agent_event(text,text,jsonb),read_incubator_agent_run(text),next_incubator_manual_run(),admit_incubator_brief(text,text,jsonb,boolean),claim_incubator_campaign(text),try_openrouter_capacity(text,text,bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_research_retry_available(text),record_incubator_agent_event(text,text,jsonb),read_incubator_agent_run(text),next_incubator_manual_run(),admit_incubator_brief(text,text,jsonb,boolean),claim_incubator_campaign(text),try_openrouter_capacity(text,text,bigint,text,jsonb) TO incubator_runner;
GRANT EXECUTE ON FUNCTION read_incubator_agent_run(text) TO incubator_chat;
