-- Faster backlog claims. One automatic Experiment-agent retry after an unusable reply.
CREATE OR REPLACE FUNCTION claim_incubator_campaign(model_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; scope_value jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE state='checking' ORDER BY ordinal LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(a)||jsonb_build_object('fresh',false); END IF;
 IF clock_timestamp()<c.next_at THEN RETURN NULL; END IF;
 IF (SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued' AND receipt_time>clock_timestamp()-interval '24 hours')>=c.daily_limit OR incubator_campaign_open_count()>=c.open_limit THEN RETURN NULL; END IF;
 IF model_value IS NULL OR model_value !~ '^[a-zA-Z0-9._/-]+:free$' OR model_value LIKE 'openrouter/%' THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for an approved free Research model. Configure Models to continue.'; END IF;
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
REVOKE ALL ON FUNCTION claim_incubator_campaign(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION claim_incubator_campaign(text) TO incubator_runner;

ALTER TABLE incubator_experiment_event DROP CONSTRAINT incubator_experiment_event_state_check;
ALTER TABLE incubator_experiment_event ADD CONSTRAINT incubator_experiment_event_state_check CHECK(state IN('setup_retry','experiment_retry','setup_question','clarifying','clarified','answered','awaiting_data','preparing','needs_input','ready','dispatching','running','completed','failed','indeterminate'));

CREATE FUNCTION incubator_experiment_failure_reason(id_value bigint, sequence_value integer) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(
  (SELECT md.detail->>'reason' FROM market_data_event_detail md WHERE md.experiment_id=id_value AND md.sequence=sequence_value),
  (SELECT e.detail->>'reason' FROM incubator_experiment_event e WHERE e.experiment_id=id_value AND e.sequence=sequence_value))
$$;
REVOKE ALL ON FUNCTION incubator_experiment_failure_reason(bigint,integer) FROM PUBLIC;

CREATE FUNCTION incubator_experiment_retry_available(id_value bigint) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT market_data_research_active(id_value)
 AND EXISTS(SELECT 1 FROM incubator_experiment_event last_event JOIN incubator_experiment_event intent
 ON intent.experiment_id=last_event.experiment_id AND intent.sequence=last_event.sequence-1
 WHERE last_event.experiment_id=id_value AND last_event.sequence=(SELECT max(sequence) FROM incubator_experiment_event WHERE experiment_id=id_value)
 AND last_event.state='failed' AND intent.state='dispatching'
 AND incubator_experiment_failure_reason(id_value,last_event.sequence) IN('invalid_experiment_agent_response','incomplete_agent_reply','experiment_agent_output_truncated'))
 AND NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE experiment_id=id_value AND state IN('experiment_retry','running','completed'))
 AND EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value)
 AND (SELECT count(*) FROM incubator_experiment_event WHERE experiment_id=id_value AND state='dispatching')<2
$$;
REVOKE ALL ON FUNCTION incubator_experiment_retry_available(bigint) FROM PUBLIC;

DO $$
DECLARE definition text; needle text;
BEGIN
 SELECT pg_get_functiondef('record_incubator_experiment_event_legacy(bigint,text,jsonb)'::regprocedure) INTO definition;
 needle:=' IF state_value=''setup_retry'' THEN';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'experiment_retry_setup_guard_anchor_missing'; END IF;
 definition:=replace(definition,needle,$guard$
 IF state_value='experiment_retry' THEN
  PERFORM pg_advisory_xact_lock(59001,hashtext(run_value));
  IF NOT incubator_experiment_retry_available(id_value) THEN RAISE EXCEPTION 'experiment_retry_unavailable'; END IF;
  detail_value:=jsonb_build_object('reason','Automatic Experiment-agent retry after an unusable reply.','failed_sequence',prior.sequence);
 END IF;
 IF prior.state='experiment_retry' AND state_value='dispatching' THEN
  PERFORM pg_advisory_xact_lock(59001,hashtext(run_value));
  IF NOT market_data_research_active(id_value) THEN RAISE EXCEPTION 'experiment_retry_research_inactive'; END IF;
 END IF;
 IF state_value='setup_retry' THEN$guard$);
 needle:='OR (prior.state=''failed'' AND state_value=''setup_retry'')';
 IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'experiment_retry_transition_anchor_missing'; END IF;
 definition:=replace(definition,needle,$trans$OR (prior.state='failed' AND state_value='setup_retry') OR (prior.state='failed' AND state_value='experiment_retry') OR (prior.state='experiment_retry' AND state_value IN('dispatching','failed'))$trans$);
 EXECUTE definition;
END $$;

ALTER FUNCTION read_incubator_experiment(bigint) RENAME TO read_incubator_experiment_before_experiment_retry;
CREATE FUNCTION read_incubator_experiment(id_value bigint) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT read_incubator_experiment_before_experiment_retry(id_value)||jsonb_build_object('experiment_retry_available',incubator_experiment_retry_available(id_value))
$$;
REVOKE ALL ON FUNCTION read_incubator_experiment(bigint),read_incubator_experiment_before_experiment_retry(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_experiment(bigint) TO incubator_runner,incubator_chat;

ALTER FUNCTION next_incubator_experiment() RENAME TO next_incubator_experiment_before_experiment_retry;
CREATE FUNCTION next_incubator_experiment() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(next_incubator_experiment_before_experiment_retry(),(SELECT evaluation_id FROM incubator_experiment_ticket
 WHERE market_data_research_active(evaluation_id) AND openrouter_work_ready('experiment:'||evaluation_id||':')
 AND ((read_incubator_experiment(evaluation_id)->>'status'='experiment_retry')
  OR coalesce((read_incubator_experiment(evaluation_id)->>'experiment_retry_available')::boolean,false))
 ORDER BY evaluation_id LIMIT 1))
$$;
REVOKE ALL ON FUNCTION next_incubator_experiment(),next_incubator_experiment_before_experiment_retry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION next_incubator_experiment() TO incubator_runner;
