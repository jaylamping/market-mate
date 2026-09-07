-- One separately admitted fallback assignment after a confirmed failure.
CREATE TABLE incubator_agent_fallback (
 parent_run_key text PRIMARY KEY REFERENCES incubator_agent_run,
 fallback_run_key text UNIQUE NOT NULL REFERENCES incubator_agent_run,
 policy_revision bigint NOT NULL CHECK (policy_revision >= 0),
 source_lineage jsonb NOT NULL CHECK (source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK (record_environment='local_research'),
 CHECK (parent_run_key <> fallback_run_key)
);
SELECT register_evidence_table('incubator_agent_fallback');
CREATE TRIGGER incubator_agent_fallback_append_only BEFORE UPDATE OR DELETE OR TRUNCATE
 ON incubator_agent_fallback FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
REVOKE ALL ON incubator_agent_fallback FROM PUBLIC;

CREATE FUNCTION read_incubator_agent_fallback(parent_value text) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_incubator_agent_run(fallback_run_key) FROM incubator_agent_fallback WHERE parent_run_key=parent_value
$$;

CREATE FUNCTION admit_incubator_agent_fallback(parent_value text, key_value text, model_value text, revision_value bigint)
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
 child_run := admit_incubator_agent_run(key_value,model_value,'momentum-brief-v1');
 lineage := jsonb_build_object('source','incubator-agent-fallback','entitlement_version','project-authored-brief-v1','parent_run_key',parent_value,'policy_revision',revision_value);
 INSERT INTO incubator_agent_fallback VALUES(parent_value,key_value,revision_value,lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('agent-fallback:'||parent_value,'research.agent_fallback_admitted',now(),
   jsonb_build_object('parent_run_key',parent_value,'fallback_run_key',key_value,'model',model_value,'policy_revision',revision_value),lineage,now(),'local_research');
 RETURN child_run;
END;
$$;
REVOKE ALL ON FUNCTION read_incubator_agent_fallback(text),admit_incubator_agent_fallback(text,text,text,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_agent_fallback(text),admit_incubator_agent_fallback(text,text,text,bigint) TO incubator_runner;
