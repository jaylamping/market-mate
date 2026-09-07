-- Durable ticket-wide refinement allowance; revisions remain append-only.
CREATE TABLE incubator_refinement (
 evaluation_id bigint PRIMARY KEY REFERENCES incubator_evaluation,
 run_key text NOT NULL REFERENCES incubator_agent_run,
 round integer NOT NULL CHECK(round BETWEEN 1 AND 2),
 request jsonb NOT NULL CHECK(octet_length(request::text)<=96000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 UNIQUE(run_key,round)
);
CREATE TABLE incubator_refinement_result (
 evaluation_id bigint PRIMARY KEY REFERENCES incubator_refinement,
 revision integer CHECK(revision>0),
 state text NOT NULL CHECK(state IN ('completed','blocked','failed','indeterminate','superseded')),
 detail jsonb NOT NULL CHECK(octet_length(detail::text)<=64000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 CHECK((state='completed')=(revision IS NOT NULL))
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['incubator_refinement','incubator_refinement_result'] LOOP
  PERFORM register_evidence_table(t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE OR TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write()',t||'_append_only',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION read_incubator_plan(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('revision',coalesce(max(revision),0),'revisions',coalesce(jsonb_agg(v ORDER BY revision),'[]')) FROM (
 SELECT revision,jsonb_build_object('revision',revision,'chat_sequence',chat_sequence,'report',report,'created_at',receipt_time,'origin','principal') v FROM incubator_plan_revision WHERE run_key=key_value
 UNION ALL
 SELECT r.revision,jsonb_build_object('revision',r.revision,'chat_sequence',NULL,'report',r.detail->'report','created_at',r.receipt_time,'origin','agent','refinement_round',a.round,'changes',r.detail->>'reason') FROM incubator_refinement_result r JOIN incubator_refinement a USING(evaluation_id) WHERE a.run_key=key_value AND r.state='completed'
 ) x
$$;
ALTER FUNCTION read_incubator_evaluation(bigint) RENAME TO read_incubator_evaluation_base;
CREATE FUNCTION read_incubator_evaluation(id_value bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v jsonb; a incubator_refinement%ROWTYPE; r incubator_refinement_result%ROWTYPE; used integer; reason text; BEGIN
 v:=read_incubator_evaluation_base(id_value);
 IF v IS NULL THEN RETURN NULL; END IF;
 SELECT count(*) INTO used FROM incubator_refinement WHERE run_key=v->>'run_key';
 SELECT * INTO a FROM incubator_refinement WHERE evaluation_id=id_value;
 SELECT * INTO r FROM incubator_refinement_result WHERE evaluation_id=id_value;
 v:=v||jsonb_build_object('refinement_rounds_used',used,'refinement',CASE WHEN a.evaluation_id IS NOT NULL THEN jsonb_build_object('round',a.round,'state',coalesce(r.state,'pending'),'reason',r.detail->>'reason','created_at',a.receipt_time,'finished_at',r.receipt_time) END);
 IF v->>'status'='refine' THEN
  reason:=CASE WHEN r.evaluation_id IS NOT NULL THEN coalesce(r.detail->>'reason','Automatic refinement stopped.') WHEN used>=2 AND a.evaluation_id IS NULL THEN 'The two automatic refinement rounds have been used. Revise the plan in Chat.' END;
  IF reason IS NULL AND a.evaluation_id IS NULL AND EXISTS(
   SELECT 1 FROM incubator_refinement old JOIN incubator_evaluation_result result ON result.evaluation_id=old.evaluation_id
   WHERE old.run_key=v->>'run_key' AND old.evaluation_id<>id_value AND result.detail->>'decision'='refine'
   AND lower(regexp_replace(result.detail->>'reason','\s+',' ','g'))=lower(regexp_replace(v->'steps'->-1->'detail'->>'reason','\s+',' ','g'))
  ) THEN reason:='The evaluator repeated the same feedback after refinement. Please resolve it in Chat.'; END IF;
  IF reason IS NOT NULL THEN RETURN v||jsonb_build_object('status','needs_input','refinement_stop_reason',reason); END IF;
  RETURN v||jsonb_build_object('status','refining');
 END IF;
 RETURN v;
END $$;
CREATE FUNCTION next_incubator_refinement() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT id FROM incubator_evaluation e WHERE
 (read_incubator_evaluation(id)->>'status'='refining' AND NOT coalesce((read_incubator_agent_run(run_key)->>'archived')::boolean,false))
 OR EXISTS(SELECT 1 FROM incubator_refinement a LEFT JOIN incubator_refinement_result r USING(evaluation_id) WHERE a.evaluation_id=e.id AND r.evaluation_id IS NULL)
 ORDER BY id LIMIT 1
$$;
CREATE FUNCTION begin_incubator_refinement(id_value bigint,request_value jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE j incubator_evaluation%ROWTYPE; n integer; BEGIN
 SELECT * INTO STRICT j FROM incubator_evaluation WHERE id=id_value;
 PERFORM pg_advisory_xact_lock(55001,hashtext(j.run_key));
 IF read_incubator_evaluation(id_value)->>'status' IS DISTINCT FROM 'refining'
 OR EXISTS(SELECT 1 FROM incubator_refinement WHERE evaluation_id=id_value)
 OR coalesce((read_incubator_agent_run(j.run_key)->>'archived')::boolean,false) THEN RAISE EXCEPTION 'refinement_not_ready'; END IF;
 SELECT count(*) INTO n FROM incubator_refinement WHERE run_key=j.run_key;
 IF n>=2 THEN RAISE EXCEPTION 'refinement_budget_exhausted'; END IF;
 IF NOT incubator_request_output_is_bounded(request_value) OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb OR coalesce(request_value->>'model','') !~ '^[a-zA-Z0-9._/-]+:free$' THEN RAISE EXCEPTION 'invalid_bounded_request'; END IF;
 INSERT INTO incubator_refinement VALUES(id_value,j.run_key,n+1,request_value,j.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('refinement:'||id_value,'research.refinement_dispatched',now(),jsonb_build_object('evaluation_id',id_value,'round',n+1,'request',request_value),j.source_lineage,now(),'local_research');
 RETURN n+1;
END $$;
CREATE FUNCTION finish_incubator_refinement(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a incubator_refinement%ROWTYPE; j incubator_evaluation%ROWTYPE; prior incubator_refinement_result%ROWTYPE; candidate jsonb; field text; n integer; BEGIN
 SELECT * INTO STRICT a FROM incubator_refinement WHERE evaluation_id=id_value;
 PERFORM pg_advisory_xact_lock(55001,hashtext(a.run_key));
 SELECT * INTO prior FROM incubator_refinement_result WHERE evaluation_id=id_value;
 IF FOUND THEN
  IF prior.detail IS DISTINCT FROM detail_value THEN RAISE EXCEPTION 'immutable_refinement_result'; END IF;
  RETURN;
 END IF;
 SELECT * INTO STRICT j FROM incubator_evaluation WHERE id=id_value;
 IF state_value NOT IN ('completed','blocked','failed','indeterminate') OR jsonb_typeof(detail_value->'reason') IS DISTINCT FROM 'string' OR length(btrim(detail_value->>'reason'))=0 THEN RAISE EXCEPTION 'invalid_refinement_result'; END IF;
 IF j.revision<>(read_incubator_plan(a.run_key)->>'revision')::integer THEN state_value:='superseded'; END IF;
 IF state_value='completed' THEN
  candidate:=detail_value->'report';
  IF jsonb_typeof(candidate) IS DISTINCT FROM 'object' OR octet_length(candidate::text)>24000 OR (SELECT count(*) FROM jsonb_object_keys(candidate))<>5 THEN RAISE EXCEPTION 'invalid_refined_report'; END IF;
  FOREACH field IN ARRAY ARRAY['hypothesis','falsification_rule'] LOOP
   IF jsonb_typeof(candidate->field) IS DISTINCT FROM 'string' OR octet_length(candidate->>field) NOT BETWEEN 1 AND 6000 OR length(btrim(candidate->>field))=0 THEN RAISE EXCEPTION 'invalid_refined_report'; END IF;
  END LOOP;
  FOREACH field IN ARRAY ARRAY['evidence_gaps','experiment','limitations'] LOOP
   IF jsonb_typeof(candidate->field) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_refined_report'; END IF;
   IF jsonb_array_length(candidate->field) NOT BETWEEN 1 AND 12 OR EXISTS(SELECT 1 FROM jsonb_array_elements(candidate->field) v WHERE jsonb_typeof(v)<>'string' OR octet_length(v#>>'{}') NOT BETWEEN 1 AND 6000 OR length(btrim(v#>>'{}'))=0) THEN RAISE EXCEPTION 'invalid_refined_report'; END IF;
  END LOOP;
  IF candidate=j.report THEN state_value:='blocked'; detail_value:=detail_value||'{"reason":"The revision did not change the plan. Please resolve the evaluator feedback in Chat."}'::jsonb;
  ELSE n:=j.revision+1; END IF;
 END IF;
 INSERT INTO incubator_refinement_result VALUES(id_value,n,state_value,detail_value,a.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('refinement:'||id_value||':result','research.refinement_'||state_value,now(),jsonb_build_object('evaluation_id',id_value,'revision',n,'detail',detail_value),a.source_lineage,now(),'local_research');
END $$;
REVOKE ALL ON FUNCTION read_incubator_evaluation_base(bigint),next_incubator_refinement(),begin_incubator_refinement(bigint,jsonb),finish_incubator_refinement(bigint,text,jsonb),read_incubator_evaluation(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION next_incubator_refinement(),begin_incubator_refinement(bigint,jsonb),finish_incubator_refinement(bigint,text,jsonb),read_incubator_evaluation(bigint) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();

CREATE OR REPLACE FUNCTION apply_incubator_plan(key_value text,sequence_value integer,revision_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE result_value incubator_chat_result%ROWTYPE; n integer; candidate jsonb; field text;
BEGIN
 PERFORM pg_advisory_xact_lock(55001,hashtext(key_value));
 IF EXISTS(SELECT 1 FROM incubator_plan_revision WHERE run_key=key_value AND chat_sequence=sequence_value) THEN
  RETURN read_incubator_plan(key_value);
 END IF;
 SELECT (read_incubator_plan(key_value)->>'revision')::integer INTO n;
 IF revision_value IS DISTINCT FROM n OR EXISTS(SELECT 1 FROM incubator_chat_turn t LEFT JOIN incubator_chat_result r USING(run_key,sequence)
  WHERE t.run_key=key_value AND (r.state IS NULL OR r.state='indeterminate')) THEN
  RAISE EXCEPTION 'plan changed or conversation unresolved' USING ERRCODE='55000';
 END IF;
 IF (SELECT plan_revision FROM incubator_chat_turn WHERE run_key=key_value AND sequence=sequence_value) IS DISTINCT FROM n THEN
  RAISE EXCEPTION 'proposal was based on an older plan; request a fresh proposal' USING ERRCODE='55000';
 END IF;
 SELECT * INTO result_value FROM incubator_chat_result WHERE run_key=key_value AND sequence=sequence_value;
 candidate:=result_value.detail->'proposal';
 IF result_value.state IS DISTINCT FROM 'completed' OR jsonb_typeof(candidate) IS DISTINCT FROM 'object'
  OR octet_length(candidate::text)>24000
  OR (SELECT count(*) FROM jsonb_object_keys(candidate))<>5 THEN
  RAISE EXCEPTION 'validated plan proposal required' USING ERRCODE='22023';
 END IF;
 FOREACH field IN ARRAY ARRAY['hypothesis','falsification_rule'] LOOP
  IF jsonb_typeof(candidate->field) IS DISTINCT FROM 'string' OR octet_length(candidate->>field) NOT BETWEEN 1 AND 6000 OR length(btrim(candidate->>field))=0 THEN
   RAISE EXCEPTION 'invalid plan text' USING ERRCODE='22023';
  END IF;
 END LOOP;
 FOREACH field IN ARRAY ARRAY['evidence_gaps','experiment','limitations'] LOOP
  IF jsonb_typeof(candidate->field) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid plan list' USING ERRCODE='22023'; END IF;
  IF jsonb_array_length(candidate->field) NOT BETWEEN 1 AND 12 OR EXISTS(
   SELECT 1 FROM jsonb_array_elements(candidate->field) v WHERE jsonb_typeof(v)<>'string' OR octet_length(v#>>'{}') NOT BETWEEN 1 AND 6000 OR length(btrim(v#>>'{}'))=0) THEN
   RAISE EXCEPTION 'invalid plan list' USING ERRCODE='22023';
  END IF;
 END LOOP;
 INSERT INTO incubator_plan_revision VALUES(key_value,n+1,sequence_value,candidate,result_value.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('plan:'||key_value||':'||(n+1),'research.plan_revised',now(),
  jsonb_build_object('run_key',key_value,'revision',n+1,'chat_sequence',sequence_value,'report',candidate,'applied_by','principal'),result_value.source_lineage,now(),'local_research');
 RETURN read_incubator_plan(key_value);
END $$;
CREATE FUNCTION read_incubator_refinement_history(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('round',a.round,'feedback',j.report,'evaluation',read_incubator_evaluation_base(j.id)->'steps','state',r.state,'reason',r.detail->>'reason','revised_report',r.detail->'report') ORDER BY a.round),'[]') FROM incubator_refinement a JOIN incubator_evaluation j ON j.id=a.evaluation_id LEFT JOIN incubator_refinement_result r USING(evaluation_id) WHERE a.run_key=key_value
$$;
REVOKE ALL ON FUNCTION read_incubator_refinement_history(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_refinement_history(text) TO incubator_runner;
