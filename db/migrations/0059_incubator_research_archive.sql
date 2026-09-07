-- Presentation-only archive state; never changes research or experiment execution.
CREATE TABLE incubator_research_archive_event (
 run_key text NOT NULL REFERENCES incubator_agent_run,
 sequence integer NOT NULL CHECK(sequence>0),
 request_id text NOT NULL CHECK(request_id ~ '^[a-zA-Z0-9_-]{1,80}$'),
 archived boolean NOT NULL,
 expected_version integer NOT NULL CHECK(expected_version>=0),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(run_key,sequence), UNIQUE(run_key,request_id)
);
SELECT register_evidence_table('incubator_research_archive_event');
CREATE TRIGGER incubator_research_archive_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_research_archive_event FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
REVOKE ALL ON incubator_research_archive_event FROM PUBLIC;
CREATE FUNCTION set_incubator_research_archived(key_value text,request_value text,archived_value boolean,version_value integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior incubator_research_archive_event%ROWTYPE; n integer; lineage jsonb; BEGIN
 PERFORM pg_advisory_xact_lock(59001,hashtext(key_value));
 SELECT source_lineage INTO STRICT lineage FROM incubator_agent_run WHERE run_key=key_value;
 SELECT * INTO prior FROM incubator_research_archive_event WHERE run_key=key_value AND request_id=request_value;
 IF FOUND THEN
  IF prior.archived IS DISTINCT FROM archived_value OR prior.expected_version IS DISTINCT FROM version_value THEN RAISE EXCEPTION 'archive_request_mismatch'; END IF;
  RETURN;
 END IF;
 SELECT coalesce(max(sequence),0) INTO n FROM incubator_research_archive_event WHERE run_key=key_value;
 IF version_value IS DISTINCT FROM n THEN RAISE EXCEPTION 'archive_version_conflict'; END IF;
 INSERT INTO incubator_research_archive_event VALUES(key_value,n+1,request_value,archived_value,version_value,lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('research:'||key_value||':archive:'||(n+1),'research.archive_changed',now(),jsonb_build_object('run_key',key_value,'archived',archived_value,'version',n+1),lineage,now(),'local_research');
END $$;
REVOKE ALL ON FUNCTION set_incubator_research_archived(text,text,boolean,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_incubator_research_archived(text,text,boolean,integer) TO incubator_runner;
CREATE OR REPLACE FUNCTION read_incubator_agent_run(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
 SELECT jsonb_build_object('run_key', r.run_key, 'assignment_id', r.assignment_id,
   'archived',coalesce(a.archived,false),'archive_version',coalesce(a.sequence,0),
   'created_by', CASE WHEN EXISTS(SELECT 1 FROM incubator_manual_request m WHERE m.run_key=r.run_key) THEN 'principal' WHEN EXISTS(SELECT 1 FROM incubator_agent_fallback f WHERE f.fallback_run_key=r.run_key) THEN 'agent' ELSE 'local_runner' END,
   'config', r.config, 'created_at', r.receipt_time,
   'state', e.state, 'updated_at', e.receipt_time, 'detail', e.detail,
   'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('sequence', v.sequence,
       'state', v.state, 'at', v.receipt_time, 'detail', v.detail) ORDER BY v.sequence), '[]')
     FROM incubator_agent_event v WHERE v.run_key = r.run_key))
 FROM incubator_agent_run r
 LEFT JOIN LATERAL(SELECT archived,sequence FROM incubator_research_archive_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) a ON true
 JOIN LATERAL (SELECT * FROM incubator_agent_event WHERE run_key = r.run_key
   ORDER BY sequence DESC LIMIT 1) e ON true WHERE r.run_key = key_value;
$$;

CREATE OR REPLACE FUNCTION read_incubator_agent_runs() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 WITH states AS (
  SELECT r.run_key,greatest(r.receipt_time,a.receipt_time) receipt_time,e.state,coalesce(a.archived,false) archived FROM incubator_agent_run r
  JOIN LATERAL(SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1)e ON true
  LEFT JOIN LATERAL(SELECT archived,receipt_time FROM incubator_research_archive_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1)a ON true
 ), visible AS (
  SELECT run_key,receipt_time FROM states WHERE NOT archived AND state IN ('admitted','preparing','dispatched','indeterminate')
  UNION ALL
  (SELECT run_key,receipt_time FROM states WHERE NOT archived AND state IN ('completed','failed') ORDER BY receipt_time DESC,run_key LIMIT 100)
  UNION ALL
  (SELECT run_key,receipt_time FROM states WHERE archived ORDER BY receipt_time DESC,run_key LIMIT 100)
 )
 SELECT jsonb_build_object('environment','local_research','artifact_kind','research_planning',
 'runs',coalesce(jsonb_agg(read_incubator_agent_run(run_key) ORDER BY receipt_time DESC,run_key),'[]')) FROM visible
$$;
SELECT assert_all_evidence_table_conventions();
