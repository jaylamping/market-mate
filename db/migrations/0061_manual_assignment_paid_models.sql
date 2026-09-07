-- Manual owner requests may use paid models; automated runs retain zero-spend admission.
CREATE OR REPLACE FUNCTION admit_incubator_brief(key_value text, model_value text, brief_value jsonb, queued boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
 existing incubator_agent_run%ROWTYPE;
 assignment incubator_assignment%ROWTYPE;
 budget jsonb := '{"max_requests":1,"max_output_tokens":2048,"timeout_seconds":120,"max_cost_usd":0}'::jsonb;
 stopping jsonb := '"Stop after one response or 120 seconds; never retry automatically."'::jsonb;
 lineage jsonb := '{"source":"incubator-agent-poc","entitlement_version":"project-authored-brief-v1"}'::jsonb;
 config_value jsonb;
 manual_spend boolean := queued AND key_value = 'manual-' || substring(brief_value->>'key' from 8) AND brief_value->>'key' LIKE 'manual:%';
BEGIN
 IF key_value IS NULL OR key_value !~ '^[a-zA-Z0-9_-]{1,96}$'
    OR model_value IS NULL OR length(model_value) > 256 OR model_value !~ '^[a-zA-Z0-9._/:-]+$' OR (NOT coalesce(manual_spend,false) AND model_value !~ '^[a-zA-Z0-9._/-]+:free$')
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
 -- Uncertain provider acceptance holds this lane even after the process dies.
 IF NOT queued AND EXISTS (SELECT 1 FROM incubator_agent_run r JOIN LATERAL
     (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
     WHERE e.state IN ('admitted','preparing','dispatched','indeterminate')) THEN
   RAISE EXCEPTION 'research lane occupied; inspect the existing run' USING ERRCODE='55000';
 END IF;
 IF manual_spend THEN
   budget := (budget - 'max_cost_usd') || '{"spend_policy":"owner_selected_model"}'::jsonb;
 END IF;
 config_value := jsonb_build_object('agent_name','Research Scout','role','quantitative_research_and_experimentation',
   'manual_model_spend',coalesce(manual_spend,false),'provider','openrouter','model',model_value,'input',brief_value, 'limits',budget,
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

CREATE OR REPLACE FUNCTION begin_incubator_request_check(id_value text,input_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior jsonb; corpus jsonb; lineage jsonb := '{"source":"incubator-manual-request","entitlement_version":"owner-authored-brief-v1"}';
BEGIN
 PERFORM pg_advisory_xact_lock(56001);
 prior:=read_incubator_request_check(id_value);
 IF prior IS NOT NULL THEN
  IF prior->'input' IS DISTINCT FROM input_value THEN RAISE EXCEPTION 'request_identity_mismatch' USING ERRCODE='22023'; END IF;
  RETURN jsonb_build_object('existing',prior);
 END IF;
 IF coalesce(length(btrim(input_value->>'text')),0)=0 OR octet_length(input_value->>'text')>6000
  OR coalesce(length(btrim(input_value->>'title')),0)=0 OR octet_length(input_value->>'title')>240
  OR length(input_value->>'model') > 256 OR coalesce(input_value->>'model','') !~ '^[a-zA-Z0-9._/:-]+$' THEN
  RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
 END IF;
 corpus:=incubator_assignment_corpus();
 INSERT INTO incubator_request_check VALUES(id_value,input_value,incubator_corpus_digest(corpus),lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('request-check:'||id_value,'research.similarity_check_started',now(),
  jsonb_build_object('request_id',id_value,'input',input_value,'corpus_digest',incubator_corpus_digest(corpus),'assignment_count',jsonb_array_length(corpus)),lineage,now(),'local_research');
 RETURN jsonb_build_object('corpus',corpus);
END $$;
