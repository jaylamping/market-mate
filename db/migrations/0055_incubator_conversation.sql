-- Local, owner-initiated research discussion. No mutation of the original report.
CREATE TABLE incubator_chat_turn (
 run_key text NOT NULL REFERENCES incubator_agent_run,
 sequence integer NOT NULL CHECK(sequence BETWEEN 1 AND 50),
 request_id text NOT NULL CHECK(request_id ~ '^[a-zA-Z0-9_-]{1,96}$'),
 plan_revision integer NOT NULL CHECK(plan_revision>=0),
 user_text text NOT NULL CHECK(octet_length(user_text) BETWEEN 1 AND 6000 AND length(btrim(user_text))>0),
 request jsonb NOT NULL CHECK(jsonb_typeof(request)='object' AND octet_length(request::text)<=120000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(run_key,sequence), UNIQUE(run_key,request_id)
);
CREATE TABLE incubator_chat_result (
 run_key text NOT NULL,
 sequence integer NOT NULL,
 state text NOT NULL CHECK(state IN ('completed','failed','indeterminate')),
 detail jsonb NOT NULL CHECK(jsonb_typeof(detail)='object' AND octet_length(detail::text)<=64000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(run_key,sequence), FOREIGN KEY(run_key,sequence) REFERENCES incubator_chat_turn
);
SELECT register_evidence_table('incubator_chat_turn');
SELECT register_evidence_table('incubator_chat_result');
CREATE TRIGGER incubator_chat_turn_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_chat_turn
 FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
CREATE TRIGGER incubator_chat_result_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_chat_result
 FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
REVOKE ALL ON incubator_chat_turn,incubator_chat_result FROM PUBLIC;

CREATE FUNCTION read_incubator_chat(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('run_key',key_value,'revision',count(*),'turns',coalesce(jsonb_agg(
  jsonb_build_object('sequence',t.sequence,'request_id',t.request_id,'user_text',t.user_text,
   'author','principal','model',t.request->>'model','created_at',t.receipt_time,
   'state',coalesce(r.state,CASE WHEN t.receipt_time<now()-interval '150 seconds' THEN 'indeterminate' ELSE 'streaming' END),
   'detail',coalesce(r.detail,'{}'::jsonb)) ORDER BY t.sequence),'[]'::jsonb))
 FROM incubator_chat_turn t LEFT JOIN incubator_chat_result r USING(run_key,sequence) WHERE t.run_key=key_value
$$;

CREATE FUNCTION admit_incubator_chat(key_value text,id_value text,revision_value integer,text_value text,request_value jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior incubator_chat_turn%ROWTYPE; run_value jsonb; lineage jsonb; n integer;
BEGIN
 PERFORM pg_advisory_xact_lock(55001,hashtext(key_value));
 SELECT * INTO prior FROM incubator_chat_turn WHERE run_key=key_value AND request_id=id_value;
 IF FOUND THEN
  IF prior.user_text IS DISTINCT FROM text_value THEN RAISE EXCEPTION 'request identity mismatch' USING ERRCODE='22023'; END IF;
  RETURN false;
 END IF;
 run_value:=read_incubator_agent_run(key_value);
 IF run_value IS NULL OR run_value->>'state' NOT IN ('completed','failed') THEN
  RAISE EXCEPTION 'run must be terminal' USING ERRCODE='22023';
 END IF;
 SELECT count(*) INTO n FROM incubator_chat_turn WHERE run_key=key_value;
 IF revision_value IS DISTINCT FROM n OR n>=50 OR EXISTS(
  SELECT 1 FROM incubator_chat_turn t LEFT JOIN incubator_chat_result r USING(run_key,sequence)
   WHERE t.run_key=key_value AND (r.state IS NULL OR r.state='indeterminate')) THEN
  RAISE EXCEPTION 'conversation changed, full, or unresolved' USING ERRCODE='55000';
 END IF;
 IF request_value->>'model' IS DISTINCT FROM run_value->'config'->>'model'
  OR request_value->>'stream' IS DISTINCT FROM 'true'
  OR request_value->>'max_tokens' IS DISTINCT FROM '2048'
  OR request_value->'provider'->'max_price' IS DISTINCT FROM '{"prompt":0,"completion":0}'::jsonb THEN
  RAISE EXCEPTION 'invalid bounded request' USING ERRCODE='22023';
 END IF;
 lineage:=jsonb_build_object('source','incubator-conversation','entitlement_version','owner-authored-discussion-v1','run_key',key_value);
 INSERT INTO incubator_chat_turn VALUES(key_value,n+1,id_value,coalesce((read_incubator_plan(key_value)->>'revision')::integer,0),text_value,request_value,lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('chat:'||key_value||':'||(n+1),'research.chat_dispatched',now(),
  jsonb_build_object('run_key',key_value,'sequence',n+1,'author','principal','request',request_value),lineage,now(),'local_research');
 RETURN true;
END $$;

CREATE FUNCTION finish_incubator_chat(key_value text,id_value text,state_value text,detail_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE turn_value incubator_chat_turn%ROWTYPE; prior incubator_chat_result%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(55001,hashtext(key_value));
 SELECT * INTO turn_value FROM incubator_chat_turn WHERE run_key=key_value AND request_id=id_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown turn' USING ERRCODE='22023'; END IF;
 SELECT * INTO prior FROM incubator_chat_result WHERE run_key=key_value AND sequence=turn_value.sequence;
 IF FOUND THEN
  IF prior.state IS DISTINCT FROM state_value OR prior.detail IS DISTINCT FROM detail_value THEN
   RAISE EXCEPTION 'terminal result is immutable' USING ERRCODE='55000';
  END IF;
  RETURN read_incubator_chat(key_value);
 END IF;
 IF state_value='completed' AND (jsonb_typeof(detail_value->'reply') IS DISTINCT FROM 'string'
  OR octet_length(detail_value->>'reply') NOT BETWEEN 1 AND 12000) THEN
  RAISE EXCEPTION 'completed reply required' USING ERRCODE='22023';
 END IF;
 INSERT INTO incubator_chat_result VALUES(key_value,turn_value.sequence,state_value,detail_value,turn_value.source_lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('chat:'||key_value||':'||turn_value.sequence||':result','research.chat_'||state_value,now(),
  jsonb_build_object('run_key',key_value,'sequence',turn_value.sequence,'author','assistant','detail',detail_value),turn_value.source_lineage,now(),'local_research');
 RETURN read_incubator_chat(key_value);
END $$;
CREATE ROLE incubator_chat LOGIN PASSWORD 'local-chat-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT USAGE ON SCHEMA public TO incubator_chat;
REVOKE ALL ON FUNCTION read_incubator_chat(text),admit_incubator_chat(text,text,integer,text,jsonb),finish_incubator_chat(text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_agent_run(text),read_incubator_chat(text),admit_incubator_chat(text,text,integer,text,jsonb),finish_incubator_chat(text,text,text,jsonb) TO incubator_chat;
SELECT assert_all_evidence_table_conventions();

-- Owner-applied planning revisions retain the report and the discussion that produced them.
CREATE TABLE incubator_plan_revision (
 run_key text NOT NULL,
 revision integer NOT NULL CHECK(revision>0),
 chat_sequence integer NOT NULL,
 report jsonb NOT NULL CHECK(jsonb_typeof(report)='object'),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(run_key,revision), UNIQUE(run_key,chat_sequence),
 FOREIGN KEY(run_key,chat_sequence) REFERENCES incubator_chat_result(run_key,sequence)
);
SELECT register_evidence_table('incubator_plan_revision');
CREATE TRIGGER incubator_plan_revision_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_plan_revision
 FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
REVOKE ALL ON incubator_plan_revision FROM PUBLIC;
CREATE FUNCTION read_incubator_plan(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('revision',coalesce(max(revision),0),'revisions',coalesce(jsonb_agg(
  jsonb_build_object('revision',revision,'chat_sequence',chat_sequence,'report',report,'created_at',receipt_time) ORDER BY revision),'[]'))
 FROM incubator_plan_revision WHERE run_key=key_value
$$;
CREATE FUNCTION apply_incubator_plan(key_value text,sequence_value integer,revision_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE result_value incubator_chat_result%ROWTYPE; n integer; candidate jsonb; field text;
BEGIN
 PERFORM pg_advisory_xact_lock(55001,hashtext(key_value));
 IF EXISTS(SELECT 1 FROM incubator_plan_revision WHERE run_key=key_value AND chat_sequence=sequence_value) THEN
  RETURN read_incubator_plan(key_value);
 END IF;
 SELECT coalesce(max(revision),0) INTO n FROM incubator_plan_revision WHERE run_key=key_value;
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
REVOKE ALL ON FUNCTION read_incubator_plan(text),apply_incubator_plan(text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_plan(text),apply_incubator_plan(text,integer,integer) TO incubator_chat;
SELECT assert_all_evidence_table_conventions();
