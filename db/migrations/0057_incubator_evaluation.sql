-- Advisory phases within a research assignment. Experiment tickets grant no execution authority.
CREATE TABLE incubator_evaluation (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 run_key text NOT NULL REFERENCES incubator_agent_run,
 revision integer NOT NULL CHECK(revision>=0),
 report jsonb NOT NULL CHECK(jsonb_typeof(report)='object'),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 UNIQUE(run_key,revision)
);
CREATE TABLE incubator_evaluation_step (
 evaluation_id bigint NOT NULL REFERENCES incubator_evaluation,
 sequence integer NOT NULL CHECK(sequence BETWEEN 1 AND 6),
 kind text NOT NULL CHECK(kind IN ('evaluation','clarification')),
 request jsonb NOT NULL CHECK(jsonb_typeof(request)='object' AND octet_length(request::text)<=96000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(evaluation_id,sequence)
);
CREATE TABLE incubator_evaluation_result (
 evaluation_id bigint NOT NULL,
 sequence integer NOT NULL,
 state text NOT NULL CHECK(state IN ('completed','failed','indeterminate')),
 detail jsonb NOT NULL CHECK(jsonb_typeof(detail)='object' AND octet_length(detail::text)<=64000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(evaluation_id,sequence), FOREIGN KEY(evaluation_id,sequence) REFERENCES incubator_evaluation_step
);
CREATE TABLE incubator_evaluation_input (
 evaluation_id bigint PRIMARY KEY REFERENCES incubator_evaluation,
 answer text NOT NULL CHECK(octet_length(answer) BETWEEN 1 AND 6000 AND length(btrim(answer))>0),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE TABLE incubator_experiment_ticket (
 evaluation_id bigint PRIMARY KEY REFERENCES incubator_evaluation,
 title text NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['incubator_evaluation','incubator_evaluation_step','incubator_evaluation_result','incubator_evaluation_input','incubator_experiment_ticket'] LOOP
  PERFORM register_evidence_table(t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE OR TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write()',t||'_append_only',t);
  EXECUTE format('REVOKE ALL ON %I FROM PUBLIC',t);
 END LOOP;
END $$;

CREATE FUNCTION read_incubator_evaluation(id_value bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('id',j.id::text,'run_key',j.run_key,'revision',j.revision,'report',j.report,'created_at',j.receipt_time,
 'status',CASE
  WHEN j.revision<>(read_incubator_plan(j.run_key)->>'revision')::integer THEN 'superseded'
  WHEN s.sequence IS NULL THEN 'queued'
  WHEN r.state IS NULL THEN CASE WHEN s.receipt_time<now()-interval '150 seconds' THEN 'indeterminate' WHEN s.kind='evaluation' THEN 'evaluating' ELSE 'awaiting_clarification' END
  WHEN r.state<>'completed' THEN r.state
  WHEN s.kind='clarification' THEN 'queued'
  WHEN r.detail->>'decision'='needs_input' THEN CASE WHEN i.receipt_time>r.receipt_time AND s.sequence<6 THEN 'queued' ELSE 'needs_input' END
  WHEN r.detail->>'decision'='clarify' THEN CASE WHEN s.sequence<5 THEN 'awaiting_clarification' WHEN i.evaluation_id IS NOT NULL AND s.sequence=5 THEN 'queued' ELSE 'needs_input' END
  ELSE r.detail->>'decision' END,
 'owner_answer',i.answer,
 'steps',coalesce((SELECT jsonb_agg(jsonb_build_object('sequence',x.sequence,'kind',x.kind,'model',x.request->>'model','created_at',x.receipt_time,'state',coalesce(y.state,'pending'),'detail',coalesce(y.detail,'{}'),'finished_at',y.receipt_time) ORDER BY x.sequence)
 FROM incubator_evaluation_step x LEFT JOIN incubator_evaluation_result y USING(evaluation_id,sequence) WHERE x.evaluation_id=j.id),'[]'),
 'experiment',CASE WHEN e.evaluation_id IS NOT NULL THEN jsonb_build_object('id',e.evaluation_id::text,'title',e.title,'status','awaiting_setup','created_at',e.receipt_time) END)
 FROM incubator_evaluation j
 LEFT JOIN LATERAL(SELECT * FROM incubator_evaluation_step WHERE evaluation_id=j.id ORDER BY sequence DESC LIMIT 1) s ON true
 LEFT JOIN incubator_evaluation_result r ON r.evaluation_id=j.id AND r.sequence=s.sequence
 LEFT JOIN incubator_evaluation_input i ON i.evaluation_id=j.id
 LEFT JOIN incubator_experiment_ticket e ON e.evaluation_id=j.id WHERE j.id=id_value
$$;
CREATE FUNCTION queue_incubator_evaluations() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r record; p jsonb; BEGIN
 FOR r IN SELECT a.* FROM incubator_agent_run a JOIN LATERAL(SELECT state FROM incubator_agent_event WHERE run_key=a.run_key ORDER BY sequence DESC LIMIT 1) e ON e.state='completed' LOOP
  p:=read_incubator_plan(r.run_key);
  INSERT INTO incubator_evaluation(run_key,revision,report,source_lineage,receipt_time,record_environment)
  VALUES(r.run_key,(p->>'revision')::integer,coalesce(p->'revisions'->-1->'report',read_incubator_agent_run(r.run_key)->'detail'->'report'),r.source_lineage,clock_timestamp(),'local_research')
  ON CONFLICT(run_key,revision) DO NOTHING;
 END LOOP;
END $$;
CREATE FUNCTION next_incubator_evaluation() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT id FROM incubator_evaluation WHERE read_incubator_evaluation(id)->>'status' IN ('queued','evaluating','awaiting_clarification')
 OR (read_incubator_evaluation(id)->>'status'='indeterminate' AND EXISTS(SELECT 1 FROM incubator_evaluation_step s LEFT JOIN incubator_evaluation_result r USING(evaluation_id,sequence) WHERE s.evaluation_id=id AND r.state IS NULL)) ORDER BY id LIMIT 1
$$;
CREATE FUNCTION begin_incubator_evaluation_step(id_value bigint,kind_value text,request_value jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE j incubator_evaluation%ROWTYPE; v jsonb; n integer; expected text; BEGIN
 PERFORM pg_advisory_xact_lock(57001,id_value::integer);
 SELECT * INTO STRICT j FROM incubator_evaluation WHERE id=id_value;
 PERFORM pg_advisory_xact_lock(55001,hashtext(j.run_key));
 v:=read_incubator_evaluation(id_value);
 n:=jsonb_array_length(v->'steps');
 expected:=CASE WHEN v->>'status'='awaiting_clarification' THEN 'clarification' ELSE 'evaluation' END;
 IF v->>'status' NOT IN ('queued','awaiting_clarification') OR EXISTS(SELECT 1 FROM incubator_evaluation_step s LEFT JOIN incubator_evaluation_result r USING(evaluation_id,sequence) WHERE s.evaluation_id=id_value AND r.state IS NULL)
 OR kind_value IS DISTINCT FROM expected OR n>=6 THEN RAISE EXCEPTION 'evaluation_not_ready'; END IF;
 IF request_value->>'max_tokens' IS DISTINCT FROM '2048' OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb
 OR coalesce(request_value->>'model','') !~ '^[a-zA-Z0-9._/-]+:free$'
 OR (kind_value='clarification' AND request_value->>'model' IS DISTINCT FROM (SELECT config->>'model' FROM incubator_agent_run WHERE run_key=j.run_key)) THEN RAISE EXCEPTION 'invalid_bounded_request'; END IF;
 INSERT INTO incubator_evaluation_step(evaluation_id,sequence,kind,request,source_lineage,receipt_time,record_environment) VALUES(id_value,n+1,kind_value,request_value,j.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('evaluation:'||id_value||':'||(n+1),'research.evaluation_dispatched',now(),jsonb_build_object('evaluation_id',id_value,'kind',kind_value,'request',request_value),j.source_lineage,now(),'local_research');
 RETURN n+1;
END $$;
CREATE FUNCTION finish_incubator_evaluation_step(id_value bigint,sequence_value integer,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE s incubator_evaluation_step%ROWTYPE; prior incubator_evaluation_result%ROWTYPE; decision text; BEGIN
 PERFORM pg_advisory_xact_lock(57001,id_value::integer);
 SELECT * INTO STRICT s FROM incubator_evaluation_step WHERE evaluation_id=id_value AND sequence=sequence_value;
 PERFORM pg_advisory_xact_lock(55001,hashtext((SELECT run_key FROM incubator_evaluation WHERE id=id_value)));
 SELECT * INTO prior FROM incubator_evaluation_result WHERE evaluation_id=id_value AND sequence=sequence_value;
 IF FOUND THEN
  IF prior.state IS DISTINCT FROM state_value OR prior.detail IS DISTINCT FROM detail_value THEN RAISE EXCEPTION 'immutable_result'; END IF;
  RETURN;
 END IF;
 IF state_value='completed' THEN
  IF s.kind='evaluation' THEN
   decision:=detail_value->>'decision';
   IF decision IS NULL OR decision NOT IN ('advance','refine','close','clarify','needs_input') OR jsonb_typeof(detail_value->'reason') IS DISTINCT FROM 'string' OR length(btrim(detail_value->>'reason'))=0 OR octet_length(detail_value->>'reason')>6000
   OR (decision IN ('clarify','needs_input') AND (jsonb_typeof(detail_value->'question') IS DISTINCT FROM 'string' OR length(btrim(detail_value->>'question'))=0 OR octet_length(detail_value->>'question')>6000)) THEN RAISE EXCEPTION 'invalid_evaluation'; END IF;
  ELSE
   IF jsonb_typeof(detail_value->'answer') IS DISTINCT FROM 'string' OR length(btrim(detail_value->>'answer'))=0 OR octet_length(detail_value->>'answer')>6000 THEN RAISE EXCEPTION 'invalid_clarification'; END IF;
  END IF;
 END IF;
 INSERT INTO incubator_evaluation_result(evaluation_id,sequence,state,detail,source_lineage,receipt_time,record_environment) VALUES(id_value,sequence_value,state_value,detail_value,s.source_lineage,clock_timestamp(),'local_research');
 IF state_value='completed' AND decision='advance' AND (SELECT revision FROM incubator_evaluation WHERE id=id_value)=(SELECT (read_incubator_plan(run_key)->>'revision')::integer FROM incubator_evaluation WHERE id=id_value) THEN
  INSERT INTO incubator_experiment_ticket(evaluation_id,title,source_lineage,receipt_time,record_environment)
  SELECT j.id,a.config->'input'->>'title',j.source_lineage,clock_timestamp(),'local_research' FROM incubator_evaluation j JOIN incubator_agent_run a USING(run_key) WHERE j.id=id_value ON CONFLICT DO NOTHING;
 END IF;
 PERFORM append_audit_event('evaluation:'||id_value||':'||sequence_value||':result','research.evaluation_'||state_value,now(),jsonb_build_object('evaluation_id',id_value,'detail',detail_value),s.source_lineage,now(),'local_research');
END $$;
CREATE FUNCTION answer_incubator_evaluation(id_value bigint,answer_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior text; BEGIN
 PERFORM pg_advisory_xact_lock(57001,id_value::integer);
 SELECT answer INTO prior FROM incubator_evaluation_input WHERE evaluation_id=id_value;
 IF FOUND THEN IF prior IS DISTINCT FROM answer_value THEN RAISE EXCEPTION 'answer_already_recorded'; END IF; RETURN; END IF;
 IF read_incubator_evaluation(id_value)->>'status' IS DISTINCT FROM 'needs_input' OR jsonb_array_length(read_incubator_evaluation(id_value)->'steps')>=6 THEN RAISE EXCEPTION 'input_not_requested'; END IF;
 INSERT INTO incubator_evaluation_input(evaluation_id,answer,source_lineage,receipt_time,record_environment) SELECT id,answer_value,source_lineage,clock_timestamp(),'local_research' FROM incubator_evaluation WHERE id=id_value;
 PERFORM append_audit_event('evaluation:'||id_value||':input','research.evaluation_owner_input',now(),jsonb_build_object('evaluation_id',id_value,'answer',answer_value),(SELECT source_lineage FROM incubator_evaluation WHERE id=id_value),now(),'local_research');
END $$;
CREATE FUNCTION read_incubator_workflow() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('evaluations',coalesce(jsonb_agg(read_incubator_evaluation(id) ORDER BY id DESC),'[]')) FROM incubator_evaluation
$$;
REVOKE ALL ON FUNCTION read_incubator_evaluation(bigint),queue_incubator_evaluations(),next_incubator_evaluation(),begin_incubator_evaluation_step(bigint,text,jsonb),finish_incubator_evaluation_step(bigint,integer,text,jsonb),answer_incubator_evaluation(bigint,text),read_incubator_workflow() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_evaluation(bigint),queue_incubator_evaluations(),next_incubator_evaluation(),begin_incubator_evaluation_step(bigint,text,jsonb),finish_incubator_evaluation_step(bigint,integer,text,jsonb),answer_incubator_evaluation(bigint,text),read_incubator_workflow() TO incubator_runner;
SELECT assert_all_evidence_table_conventions();

CREATE OR REPLACE FUNCTION read_incubator_agent_run(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
 SELECT jsonb_build_object('run_key', r.run_key, 'assignment_id', r.assignment_id,
   'created_by', CASE WHEN EXISTS(SELECT 1 FROM incubator_manual_request m WHERE m.run_key=r.run_key) THEN 'principal' WHEN EXISTS(SELECT 1 FROM incubator_agent_fallback f WHERE f.fallback_run_key=r.run_key) THEN 'agent' ELSE 'local_runner' END,
   'config', r.config, 'created_at', r.receipt_time,
   'state', e.state, 'updated_at', e.receipt_time, 'detail', e.detail,
   'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('sequence', v.sequence,
       'state', v.state, 'at', v.receipt_time, 'detail', v.detail) ORDER BY v.sequence), '[]')
     FROM incubator_agent_event v WHERE v.run_key = r.run_key))
 FROM incubator_agent_run r
 JOIN LATERAL (SELECT * FROM incubator_agent_event WHERE run_key = r.run_key
   ORDER BY sequence DESC LIMIT 1) e ON true WHERE r.run_key = key_value;
$$;
