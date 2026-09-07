-- Owner-authored requests, advisory similarity checks, and a durable single-worker queue.
ALTER TABLE incubator_agent_event DROP CONSTRAINT incubator_agent_event_state_check;
ALTER TABLE incubator_agent_event ADD CHECK(state IN ('admitted','preparing','dispatched','completed','failed','indeterminate'));
CREATE FUNCTION admit_incubator_brief(key_value text, model_value text, brief_value jsonb, queued boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
 existing incubator_agent_run%ROWTYPE;
 assignment incubator_assignment%ROWTYPE;
 budget jsonb := '{"max_requests":1,"max_output_tokens":2048,"timeout_seconds":120,"max_cost_usd":0}'::jsonb;
 stopping jsonb := '"Stop after one response or 120 seconds; never retry automatically."'::jsonb;
 lineage jsonb := '{"source":"incubator-agent-poc","entitlement_version":"project-authored-brief-v1"}'::jsonb;
 config_value jsonb;
BEGIN
 IF key_value IS NULL OR key_value !~ '^[a-zA-Z0-9_-]{1,96}$'
    OR model_value IS NULL OR length(model_value) > 256 OR model_value !~ '^[a-zA-Z0-9._/-]+:free$'
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
 config_value := jsonb_build_object('agent_name','Research Scout','role','quantitative_research_and_experimentation',
   'provider','openrouter','model',model_value,'input',brief_value, 'limits',budget,
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

REVOKE ALL ON FUNCTION admit_incubator_brief(text,text,jsonb,boolean) FROM PUBLIC;
CREATE OR REPLACE FUNCTION admit_incubator_agent_run(key_value text,model_value text,input_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF input_key IS DISTINCT FROM 'momentum-brief-v1' THEN RAISE EXCEPTION 'input not permitted' USING ERRCODE='42501'; END IF;
 RETURN admit_incubator_brief(key_value,model_value,incubator_poc_brief(),false);
END $$;
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
   RAISE EXCEPTION 'invalid run event' USING ERRCODE='22023';
 END IF;
 IF NOT ((prior.state='admitted' AND state_value IN ('preparing','dispatched','failed'))
      OR (prior.state='preparing' AND state_value IN ('dispatched','failed'))
      OR (prior.state='dispatched' AND state_value IN ('completed','failed','indeterminate'))) THEN
   RAISE EXCEPTION 'invalid run transition; no redispatch or terminal rewrite' USING ERRCODE='55000';
 END IF;
 IF state_value='completed' AND jsonb_typeof(detail_value->'report') IS DISTINCT FROM 'object' THEN
   RAISE EXCEPTION 'completed run requires a report' USING ERRCODE='22023';
 END IF;
 IF state_value IN ('preparing','dispatched') AND EXISTS (
   SELECT 1 FROM incubator_agent_run r JOIN LATERAL
    (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
   WHERE r.run_key<>key_value AND e.state IN ('preparing','dispatched','indeterminate')) THEN
  RAISE EXCEPTION 'research lane occupied' USING ERRCODE='55000';
 END IF;
 INSERT INTO incubator_agent_event VALUES(key_value,prior.sequence+1,state_value,detail_value,
   run_row.source_lineage,clock_timestamp(),'local_research');
 IF state_value IN ('completed','failed') THEN
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

CREATE OR REPLACE FUNCTION admit_incubator_agent_fallback(parent_value text, key_value text, model_value text, revision_value bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE
 parent_run jsonb;
 child_run jsonb;
 lineage jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(53001);
 parent_run := read_incubator_agent_run(parent_value);
 IF parent_run IS NULL OR parent_run->>'state' <> 'failed' OR revision_value IS NULL OR revision_value<0
    OR parent_value=key_value OR parent_run->'config'->>'model'=model_value
    OR EXISTS(SELECT 1 FROM incubator_agent_fallback WHERE fallback_run_key=parent_value) THEN
   RAISE EXCEPTION 'fallback requires a failed primary and a different model; no fallback chains' USING ERRCODE='22023';
 END IF;
 child_run := read_incubator_agent_fallback(parent_value);
 IF child_run IS NOT NULL THEN
   IF child_run->>'run_key' IS DISTINCT FROM key_value OR child_run->'config'->>'model' IS DISTINCT FROM model_value THEN
     RAISE EXCEPTION 'fallback already bound' USING ERRCODE='22023';
   END IF;
   RETURN child_run;
 END IF;
 IF EXISTS(SELECT 1 FROM incubator_agent_run WHERE run_key=key_value) THEN
   RAISE EXCEPTION 'fallback key already used' USING ERRCODE='22023';
 END IF;
 child_run := admit_incubator_brief(key_value,model_value,parent_run->'config'->'input',true);
 lineage := jsonb_build_object('source','incubator-agent-fallback','entitlement_version','project-authored-brief-v1','parent_run_key',parent_value,'policy_revision',revision_value);
 INSERT INTO incubator_agent_fallback VALUES(parent_value,key_value,revision_value,lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('agent-fallback:'||parent_value,'research.agent_fallback_admitted',now(),
   jsonb_build_object('parent_run_key',parent_value,'fallback_run_key',key_value,'model',model_value,'policy_revision',revision_value),lineage,now(),'local_research');
 RETURN child_run;
END;
$$;

CREATE TABLE incubator_request_check (
 request_id text PRIMARY KEY CHECK(request_id ~ '^[a-zA-Z0-9_-]{1,80}$'),
 input jsonb NOT NULL CHECK(jsonb_typeof(input)='object' AND octet_length(input::text)<=10000),
 corpus_digest text NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE TABLE incubator_request_check_result (
 request_id text PRIMARY KEY REFERENCES incubator_request_check,
 result jsonb NOT NULL CHECK(jsonb_typeof(result)='object' AND octet_length(result::text)<=1000000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE TABLE incubator_manual_request (
 request_id text PRIMARY KEY REFERENCES incubator_request_check,
 run_key text UNIQUE NOT NULL REFERENCES incubator_agent_run,
 warning_accepted boolean NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
SELECT register_evidence_table('incubator_request_check');
SELECT register_evidence_table('incubator_request_check_result');
SELECT register_evidence_table('incubator_manual_request');
CREATE TRIGGER incubator_request_check_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_request_check
 FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
CREATE TRIGGER incubator_request_check_result_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_request_check_result
 FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
CREATE TRIGGER incubator_manual_request_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_manual_request
 FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
REVOKE ALL ON incubator_request_check,incubator_request_check_result,incubator_manual_request FROM PUBLIC;

-- Entire assignment history, including substrate assignments without a POC run.
-- Only original exportable POC briefs and owner-applied plans may leave this service.
CREATE FUNCTION incubator_assignment_corpus() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',a.assignment_id::text,'run_key',r.run_key,
  'title',coalesce(r.config->'input'->>'title',a.assignment_key),
  'text',coalesce(r.config->'input'->>'text',a.spec->'profit_contribution_hypothesis'->>'claim'),
  'plan',p.report,'exportable',coalesce(r.config->'input'->>'permitted_destination'='openrouter',false),
  'state',coalesce(e.state,s.result->>'outcome',a.state)) ORDER BY a.assignment_id),'[]')
 FROM incubator_assignment a LEFT JOIN incubator_agent_run r USING(assignment_id)
 LEFT JOIN alpha_shot s USING(assignment_id)
 LEFT JOIN LATERAL (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
 LEFT JOIN LATERAL (SELECT report FROM incubator_plan_revision WHERE run_key=r.run_key ORDER BY revision DESC LIMIT 1) p ON true
$$;
CREATE FUNCTION incubator_corpus_digest(corpus jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public AS $$
 SELECT md5(coalesce(jsonb_agg(item-'state' ORDER BY item->>'id'),'[]')::text) FROM jsonb_array_elements(corpus) item
$$;
REVOKE ALL ON FUNCTION incubator_corpus_digest(jsonb) FROM PUBLIC;
CREATE FUNCTION read_incubator_request_check(id_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('request_id',c.request_id,'input',c.input,'result',r.result,
  'run_key',m.run_key,'created_at',c.receipt_time)
 FROM incubator_request_check c LEFT JOIN incubator_request_check_result r USING(request_id)
 LEFT JOIN incubator_manual_request m USING(request_id) WHERE c.request_id=id_value
$$;
CREATE FUNCTION begin_incubator_request_check(id_value text,input_value jsonb) RETURNS jsonb
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
  OR coalesce(input_value->>'model','') !~ '^[a-zA-Z0-9._/-]+:free$' THEN
  RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
 END IF;
 corpus:=incubator_assignment_corpus();
 INSERT INTO incubator_request_check VALUES(id_value,input_value,incubator_corpus_digest(corpus),lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('request-check:'||id_value,'research.similarity_check_started',now(),
  jsonb_build_object('request_id',id_value,'input',input_value,'corpus_digest',incubator_corpus_digest(corpus),'assignment_count',jsonb_array_length(corpus)),lineage,now(),'local_research');
 RETURN jsonb_build_object('corpus',corpus);
END $$;
CREATE FUNCTION finish_incubator_request_check(id_value text,result_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_request_check%ROWTYPE; prior jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(56001);
 SELECT * INTO c FROM incubator_request_check WHERE request_id=id_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown_request' USING ERRCODE='22023'; END IF;
 SELECT result INTO prior FROM incubator_request_check_result WHERE request_id=id_value;
 IF FOUND THEN
  IF prior IS DISTINCT FROM result_value THEN RAISE EXCEPTION 'check_result_immutable' USING ERRCODE='55000'; END IF;
  RETURN read_incubator_request_check(id_value);
 END IF;
 IF jsonb_typeof(result_value->'complete') IS DISTINCT FROM 'boolean' OR jsonb_typeof(result_value->'matches') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION 'invalid_check_result' USING ERRCODE='22023';
 END IF;
 INSERT INTO incubator_request_check_result VALUES(id_value,result_value,c.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('request-check:'||id_value||':result','research.similarity_check_finished',now(),result_value,c.source_lineage,now(),'local_research');
 RETURN read_incubator_request_check(id_value);
END $$;
CREATE FUNCTION submit_incubator_request(id_value text,accept_warning boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_request_check%ROWTYPE; result_value jsonb; run_value jsonb; brief jsonb; existing text;
BEGIN
 -- Admission and warning validation share the run-admission lock. No simultaneous
 -- submission can pass a check against history that predates another submission.
 PERFORM pg_advisory_xact_lock(53001);
 SELECT run_key INTO existing FROM incubator_manual_request WHERE request_id=id_value;
 IF FOUND THEN RETURN read_incubator_agent_run(existing); END IF;
 SELECT * INTO c FROM incubator_request_check WHERE request_id=id_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown_request' USING ERRCODE='22023'; END IF;
 SELECT result INTO result_value FROM incubator_request_check_result WHERE request_id=id_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'check_pending' USING ERRCODE='55000'; END IF;
 LOCK TABLE incubator_assignment,incubator_plan_revision IN SHARE ROW EXCLUSIVE MODE;
 IF c.corpus_digest IS DISTINCT FROM incubator_corpus_digest(incubator_assignment_corpus()) THEN
  RAISE EXCEPTION 'history_changed_recheck' USING ERRCODE='55000';
 END IF;
 IF (result_value->>'complete'<>'true' OR jsonb_array_length(result_value->'matches')>0) AND accept_warning IS DISTINCT FROM true THEN
  RAISE EXCEPTION 'warning_confirmation_required' USING ERRCODE='55000';
 END IF;
 brief:=jsonb_build_object('key','manual:'||id_value,'title',c.input->>'title','text',c.input->>'text',
  'classification','project_authored_research_brief','permitted_destination','openrouter',
  'entitlement_scope','Owner-authored research planning text only; no third-party evidence or account data.');
 run_value:=admit_incubator_brief('manual-'||id_value,c.input->>'model',brief,true);
 INSERT INTO incubator_manual_request VALUES(id_value,run_value->>'run_key',coalesce(accept_warning,false),c.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('manual-request:'||id_value,'research.manual_request_queued',now(),
  jsonb_build_object('request_id',id_value,'run_key',run_value->>'run_key','warning_accepted',accept_warning,'check',result_value),c.source_lineage,now(),'local_research');
 RETURN run_value;
END $$;
CREATE FUNCTION next_incubator_manual_run() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT r.run_key FROM incubator_agent_run r JOIN LATERAL
  (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
 WHERE (r.run_key IN (SELECT run_key FROM incubator_manual_request)
   OR r.run_key IN (SELECT fallback_run_key FROM incubator_agent_fallback f JOIN incubator_manual_request m ON m.run_key=f.parent_run_key))
  AND e.state IN ('admitted','preparing','dispatched')
  AND NOT EXISTS(SELECT 1 FROM incubator_agent_run x JOIN LATERAL
   (SELECT state FROM incubator_agent_event WHERE run_key=x.run_key ORDER BY sequence DESC LIMIT 1) y ON true WHERE y.state='indeterminate')
 ORDER BY (e.state IN ('preparing','dispatched')) DESC,r.receipt_time,r.run_key LIMIT 1
$$;
REVOKE ALL ON FUNCTION incubator_assignment_corpus(),read_incubator_request_check(text),begin_incubator_request_check(text,jsonb),
 finish_incubator_request_check(text,jsonb),submit_incubator_request(text,boolean),next_incubator_manual_run() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_assignment_corpus(),read_incubator_request_check(text),begin_incubator_request_check(text,jsonb),
 finish_incubator_request_check(text,jsonb),submit_incubator_request(text,boolean),next_incubator_manual_run(),read_incubator_agent_runs() TO incubator_runner;
SELECT assert_all_evidence_table_conventions();

CREATE FUNCTION record_incubator_similarity_attempt(id_value text,batch_value integer,request_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_request_check%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_request_check WHERE request_id=id_value;
 IF NOT FOUND OR batch_value NOT BETWEEN 0 AND 7 OR octet_length(request_value::text)>96000
  OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb
  OR request_value->>'max_tokens' IS DISTINCT FROM '2048' THEN
  RAISE EXCEPTION 'invalid_similarity_attempt' USING ERRCODE='22023';
 END IF;
 PERFORM append_audit_event('request-check:'||id_value||':attempt:'||batch_value,'research.similarity_dispatched',now(),
  jsonb_build_object('request_id',id_value,'request',request_value),c.source_lineage,now(),'local_research');
END $$;
REVOKE ALL ON FUNCTION record_incubator_similarity_attempt(text,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION record_incubator_similarity_attempt(text,integer,jsonb) TO incubator_runner;

-- Active assignments remain visible even when the finished history exceeds 100.
CREATE OR REPLACE FUNCTION read_incubator_agent_runs() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 WITH states AS (
  SELECT r.run_key,r.receipt_time,e.state FROM incubator_agent_run r JOIN LATERAL
   (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
 ), visible AS (
  SELECT run_key,receipt_time FROM states WHERE state IN ('admitted','preparing','dispatched','indeterminate')
  UNION ALL
  (SELECT run_key,receipt_time FROM states WHERE state IN ('completed','failed') ORDER BY receipt_time DESC,run_key LIMIT 100)
 )
 SELECT jsonb_build_object('environment','local_research','artifact_kind','research_planning',
  'runs',coalesce(jsonb_agg(read_incubator_agent_run(run_key) ORDER BY receipt_time DESC,run_key),'[]')) FROM visible
$$;
