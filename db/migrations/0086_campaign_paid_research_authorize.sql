-- Qualify campaign request identity. Campaign research stays on a free Research runner.
CREATE OR REPLACE FUNCTION incubator_campaign_paid_authorized(key_value text,model_value text,purpose text,actual_request jsonb,fingerprint text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; campaign_request text; generation_id bigint;
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
  campaign_request:=split_part(key_value,':',2);
  RETURN purpose='similarity' AND EXISTS(SELECT 1 FROM incubator_campaign_attempt a WHERE a.request_id=campaign_request AND a.model=model_value AND a.state IN('checking','queued'));
 END IF;
 IF key_value ~ '^research:campaign-pilot-v1-[0-9]{1,10}(:retry)?$' THEN
  campaign_request:=split_part(key_value,':',2);
  RETURN purpose='research' AND EXISTS(SELECT 1 FROM incubator_campaign_attempt a WHERE a.request_id=campaign_request AND a.state='queued');
 END IF;
 RETURN false;
END $$;
REVOKE ALL ON FUNCTION incubator_campaign_paid_authorized(text,text,text,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_campaign_paid_authorized(text,text,text,jsonb,text) TO incubator_runner;

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
BEGIN
 IF key_value IS NULL OR key_value !~ '^[a-zA-Z0-9_-]{1,96}$'
    OR model_value IS NULL OR length(model_value) > 256 OR model_value !~ '^[a-zA-Z0-9._/:~-]+$' OR (NOT coalesce(manual_spend,false) AND model_value !~ '^[a-zA-Z0-9._/-]+:free$')
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
 END IF;
 config_value := jsonb_build_object('agent_name','Research Scout','role','quantitative_research_and_experimentation',
   'manual_model_spend',coalesce(manual_spend,false),'campaign_model_spend',false,'provider','openrouter','model',model_value,'input',brief_value, 'limits',budget,
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

CREATE FUNCTION finish_incubator_campaign(ordinal_value integer, research_model text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; checked jsonb; outcome text; reason_value text; r jsonb; matches jsonb; child integer; admit_model text;
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
    admit_model:=coalesce(research_model,a.model);
    IF admit_model !~ '^[a-zA-Z0-9._/-]+:free$' THEN
     outcome:='blocked'; reason_value:='Campaign research uses the configured free Research runner. Ticket Creator may stay paid.';
    ELSE
     r:=admit_incubator_brief('campaign-pilot-v1-'||p.ordinal,admit_model,jsonb_build_object('key',a.request_id,'title',p.title,
      'text',p.premise||E'\nCampaign-approved fixed diagnostic spec: '||p.spec::text||E'\nCampaign-approved observed data request: '||a.scope::text||E'\nPreserve this exact scope in the research plan. These are exploratory diagnostics; no parameter selection, statistical significance or independent confirmation is claimed. Record missing data and limitations. Do not change symbols, dates, benchmark, costs or runner. The existing one-session decile pilot is historical context, not an untouched holdout.',
      'classification','project_authored_research_brief','permitted_destination','openrouter','entitlement_scope','Model-proposed research premise within the approved campaign scope; no observed prices or account data.'),true);
     outcome:='queued'; reason_value:='Created by Ticket Creator and admitted after a complete duplicate check.';
    END IF;
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

CREATE OR REPLACE FUNCTION finish_incubator_campaign(ordinal_value integer) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT finish_incubator_campaign(ordinal_value, NULL)
$$;

CREATE FUNCTION reroute_incubator_campaign_research(key_value text, model_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE existing incubator_agent_run%ROWTYPE; latest text;
 budget jsonb := '{"max_requests":1,"max_output_tokens":2048,"timeout_seconds":120,"max_cost_usd":0}'::jsonb;
BEGIN
 IF key_value IS NULL OR key_value !~ '^campaign-pilot-v1-[0-9]{1,10}$'
    OR model_value IS NULL OR length(model_value)>256 OR model_value !~ '^[a-zA-Z0-9._/-]+:free$' THEN
  RAISE EXCEPTION 'invalid run identity or zero-spend model' USING ERRCODE='22023';
 END IF;
 PERFORM pg_advisory_xact_lock(53001);
 SELECT * INTO existing FROM incubator_agent_run WHERE run_key=key_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown run' USING ERRCODE='22023'; END IF;
 SELECT state INTO latest FROM incubator_agent_event WHERE run_key=key_value ORDER BY sequence DESC LIMIT 1;
 IF latest IS DISTINCT FROM 'admitted' OR EXISTS(SELECT 1 FROM incubator_agent_event WHERE run_key=key_value AND state='dispatched') THEN
  RETURN read_incubator_agent_run(key_value);
 END IF;
 IF existing.config->>'campaign_model_spend' IS DISTINCT FROM 'true' AND existing.config->>'model' IS NOT DISTINCT FROM model_value THEN
  RETURN read_incubator_agent_run(key_value);
 END IF;
 PERFORM set_config('session_replication_role','replica',true);
 UPDATE incubator_agent_run SET config=existing.config||jsonb_build_object('model',model_value,'campaign_model_spend',false,'limits',budget)
  WHERE run_key=key_value;
 PERFORM set_config('session_replication_role','origin',true);
 PERFORM append_audit_event('agent-poc:'||key_value||':reroute','research.campaign_research_rerouted',now(),
  jsonb_build_object('run_key',key_value,'from',existing.config->>'model','to',model_value),existing.source_lineage,now(),'local_research');
 RETURN read_incubator_agent_run(key_value);
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('session_replication_role','origin',true);
 RAISE;
END $$;

REVOKE ALL ON FUNCTION admit_incubator_brief(text,text,jsonb,boolean),finish_incubator_campaign(integer),finish_incubator_campaign(integer,text),reroute_incubator_campaign_research(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admit_incubator_brief(text,text,jsonb,boolean),finish_incubator_campaign(integer),finish_incubator_campaign(integer,text),reroute_incubator_campaign_research(text,text) TO incubator_runner;
