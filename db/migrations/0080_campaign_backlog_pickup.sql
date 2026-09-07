-- Existing backlog keeps moving to free research. Exact-case duplicates leave the live queue.
CREATE FUNCTION incubator_momentum_case_fields(spec jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public AS $$
 SELECT CASE WHEN spec ? 'lookback_sessions' AND spec ? 'quantile_count' AND spec ? 'one_way_cost_bps' AND spec ? 'borrow_bps_per_session'
 THEN jsonb_build_object('lookback_sessions',spec->'lookback_sessions','quantile_count',spec->'quantile_count',
  'one_way_cost_bps',spec->'one_way_cost_bps','borrow_bps_per_session',spec->'borrow_bps_per_session') END
$$;
CREATE FUNCTION incubator_momentum_case_spec(text_value text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,public AS $$
DECLARE rest text; payload text;
BEGIN
 IF text_value IS NULL THEN RETURN NULL; END IF;
 rest:=substring(text_value from 'Exact diagnostic spec:[[:space:]]*(\{.*)$');
 IF rest IS NULL THEN rest:=substring(text_value from 'Campaign-approved fixed diagnostic spec:[[:space:]]*(\{.*)$'); END IF;
 IF rest IS NULL THEN RETURN NULL; END IF;
 payload:=substring(btrim(rest) from '^(\{[^}]*\})');
 IF payload IS NULL THEN RETURN NULL; END IF;
 BEGIN
  RETURN incubator_momentum_case_fields(payload::jsonb);
 EXCEPTION WHEN invalid_text_representation THEN RETURN NULL;
 END;
END $$;
CREATE FUNCTION incubator_campaign_material_matches(spec jsonb,matches jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(m),'[]'::jsonb) FROM jsonb_array_elements(coalesce(matches,'[]'::jsonb)) m
 WHERE incubator_momentum_case_fields(spec) IS NOT NULL AND incubator_momentum_case_fields(spec)=coalesce(incubator_momentum_case_fields(m->'spec'),incubator_momentum_case_spec(m->>'text'))
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
 UPDATE incubator_campaign SET next_at=clock_timestamp()+interval '60 seconds',note=CASE WHEN c.enabled THEN 'Checking the next research question against assignment history.' ELSE note END;
 PERFORM append_audit_event(a.request_id||':claimed','research.campaign_candidate_claimed',now(),to_jsonb(a),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN to_jsonb(a)||jsonb_build_object('fresh',true,'title',p.title,'text',p.premise||E'\nExact diagnostic spec: '||p.spec::text);
END $$;
CREATE OR REPLACE FUNCTION finish_incubator_campaign(ordinal_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; checked jsonb; outcome text; reason_value text; r jsonb; matches jsonb; child integer;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE ordinal=ordinal_value FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown_campaign_candidate'; END IF;
 IF a.state<>'checking' THEN RETURN read_incubator_campaign(); END IF;
 checked:=read_incubator_request_check(a.request_id);
 SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal=a.ordinal;
 IF c.revision<>a.campaign_revision THEN outcome:='cancelled'; reason_value:='Campaign settings changed during checking.';
 ELSIF checked->'input'->>'title' IS DISTINCT FROM p.title
 OR checked->'input'->>'text' IS DISTINCT FROM (p.premise||E'\nExact diagnostic spec: '||p.spec::text)
 OR checked->'input'->>'model' IS DISTINCT FROM a.model
 OR checked->'result'->>'complete' IS DISTINCT FROM 'true' THEN outcome:='blocked'; reason_value:='Similarity check stopped: '||coalesce((SELECT string_agg(issue,'; ') FROM jsonb_array_elements_text(checked->'result'->'issues') issue),'Check input changed or its result was not recorded. Review request history before retrying.');
 ELSE
  matches:=incubator_campaign_material_matches(p.spec,checked->'result'->'matches');
  IF jsonb_array_length(matches)>0 THEN outcome:='duplicate'; reason_value:='Exact diagnostic case already exists; moved to the duplicate queue.';
  ELSE
   PERFORM pg_advisory_xact_lock(53001);
   LOCK TABLE incubator_assignment,incubator_plan_revision IN SHARE ROW EXCLUSIVE MODE;
   IF (SELECT corpus_digest FROM incubator_request_check WHERE request_id=a.request_id) IS DISTINCT FROM incubator_corpus_digest(incubator_assignment_corpus()) THEN
    outcome:='blocked'; reason_value:='Assignment history changed during checking. No ticket was created.';
   ELSIF incubator_campaign_open_count()>c.open_limit THEN outcome:='blocked'; reason_value:='Unfinished ticket limit reached.';
   ELSE
    SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal=a.ordinal;
    r:=admit_incubator_brief('campaign-pilot-v1-'||p.ordinal,a.model,jsonb_build_object('key',a.request_id,'title',p.title,
     'text',p.premise||E'\nCampaign-approved fixed diagnostic spec: '||p.spec::text||E'\nCampaign-approved observed data request: '||a.scope::text||E'\nPreserve this exact scope in the research plan. These are exploratory diagnostics; no parameter selection, statistical significance or independent confirmation is claimed. Record missing data and limitations. Do not change symbols, dates, benchmark, costs or runner. The existing one-session decile pilot is historical context, not an untouched holdout.',
     'classification','project_authored_research_brief','permitted_destination','openrouter','entitlement_scope','Model-proposed research premise within the approved campaign scope; no observed prices or account data.'),true);
    outcome:='queued'; reason_value:='Created by Ticket Creator and admitted after a complete duplicate check.';
   END IF;
  END IF;
 END IF;
 UPDATE incubator_campaign_attempt SET state=outcome,run_key=r->>'run_key',reason=reason_value WHERE ordinal=a.ordinal;
 IF outcome='blocked' AND reason_value NOT LIKE 'Unfinished ticket limit%' AND incubator_campaign_retry_blocker(a.ordinal) IS NULL
  AND (SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt))<c.backlog_limit THEN
  INSERT INTO incubator_campaign_candidate(title,premise,spec,generation_id,retry_of) VALUES(p.title,p.premise,p.spec,p.generation_id,p.ordinal) RETURNING ordinal INTO child;
  PERFORM append_audit_event('campaign-retry:'||p.ordinal,'research.campaign_retry_requested',now(),
   jsonb_build_object('original_candidate',p.ordinal,'candidate',child,'original_request_id',a.request_id,'campaign_revision',c.revision,'automatic',true),
   '{"source":"research-campaign","entitlement_version":"campaign-recovery-v1"}',now(),'local_research');
 END IF;
 UPDATE incubator_campaign SET note=CASE
  WHEN NOT c.enabled THEN note
  WHEN outcome='cancelled' THEN note
  WHEN child IS NOT NULL THEN 'Similarity check incomplete. Retry queued as proposal #'||child||'. Existing backlog continues.'
  ELSE reason_value END;
 PERFORM append_audit_event(a.request_id||':finished','research.campaign_candidate_finished',now(),
  jsonb_build_object('request_id',a.request_id,'candidate',a.ordinal,'state',outcome,'run_key',r->>'run_key','reason',reason_value,'retry_candidate',child,'material_matches',matches,'check',checked->'result'),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;
REVOKE ALL ON FUNCTION incubator_momentum_case_fields(jsonb),incubator_momentum_case_spec(text),incubator_campaign_material_matches(jsonb,jsonb),claim_incubator_campaign(text),finish_incubator_campaign(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_momentum_case_fields(jsonb),incubator_momentum_case_spec(text),incubator_campaign_material_matches(jsonb,jsonb),claim_incubator_campaign(text),finish_incubator_campaign(integer) TO incubator_runner;
