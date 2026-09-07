-- One-shot, zero-spend Local Research POC. The only exportable input is
-- original project-authored planning text; this grants no vendor-data rights.
CREATE FUNCTION incubator_poc_brief() RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
 SELECT jsonb_build_object(
   'key', 'momentum-brief-v1',
   'title', 'Can a simple momentum premise survive trading costs?',
   'classification', 'project_authored_research_brief',
   'text', 'Investigate whether a simple daily stock momentum signal could produce durable after-cost excess returns. No observations, prices, backtest results, or performance estimates are supplied. Formulate one falsifiable hypothesis, identify the data and controls required to test it, and propose the smallest experiment that could reject it. Consider turnover, spread, slippage, survivorship, leakage, and a cash and broad-market total-return baseline. Do not invent measurements or claim that the premise works. This is research planning, not empirical validation.',
   'permitted_destination', 'openrouter',
   'entitlement_scope', 'Original project-authored text only; no third-party evidence or account data.'
 );
$$;

CREATE TABLE incubator_agent_run (
 run_key text PRIMARY KEY CHECK (run_key ~ '^[a-zA-Z0-9_-]{1,96}$'),
 assignment_id uuid NOT NULL UNIQUE REFERENCES incubator_assignment,
 config jsonb NOT NULL,
 source_lineage jsonb NOT NULL CHECK (source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK (record_environment = 'local_research')
);
SELECT register_evidence_table('incubator_agent_run');
CREATE TABLE incubator_agent_event (
 run_key text NOT NULL REFERENCES incubator_agent_run,
 sequence integer NOT NULL CHECK (sequence > 0),
 state text NOT NULL CHECK (state IN ('admitted','dispatched','completed','failed','indeterminate')),
 detail jsonb NOT NULL CHECK (jsonb_typeof(detail) = 'object'),
 source_lineage jsonb NOT NULL CHECK (source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK (record_environment = 'local_research'),
 PRIMARY KEY (run_key, sequence)
);
SELECT register_evidence_table('incubator_agent_event');
CREATE TRIGGER incubator_agent_run_append_only BEFORE UPDATE OR DELETE OR TRUNCATE
 ON incubator_agent_run FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
CREATE TRIGGER incubator_agent_event_append_only BEFORE UPDATE OR DELETE OR TRUNCATE
 ON incubator_agent_event FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
REVOKE ALL ON incubator_agent_run, incubator_agent_event FROM PUBLIC;

CREATE FUNCTION read_incubator_agent_run(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
 SELECT jsonb_build_object('run_key', r.run_key, 'assignment_id', r.assignment_id,
   'config', r.config, 'created_at', r.receipt_time,
   'state', e.state, 'updated_at', e.receipt_time, 'detail', e.detail,
   'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('sequence', v.sequence,
       'state', v.state, 'at', v.receipt_time, 'detail', v.detail) ORDER BY v.sequence), '[]')
     FROM incubator_agent_event v WHERE v.run_key = r.run_key))
 FROM incubator_agent_run r
 JOIN LATERAL (SELECT * FROM incubator_agent_event WHERE run_key = r.run_key
   ORDER BY sequence DESC LIMIT 1) e ON true WHERE r.run_key = key_value;
$$;

CREATE FUNCTION admit_incubator_agent_run(key_value text, model_value text, input_key text)
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
 IF input_key IS DISTINCT FROM 'momentum-brief-v1' THEN
   RAISE EXCEPTION 'input is not permitted for external POC research' USING ERRCODE='42501';
 END IF;
 PERFORM pg_advisory_xact_lock(53001);
 SELECT * INTO existing FROM incubator_agent_run WHERE run_key=key_value;
 IF FOUND THEN
   IF existing.config->>'model' IS DISTINCT FROM model_value THEN
     RAISE EXCEPTION 'run key already binds a different model' USING ERRCODE='22023';
   END IF;
   RETURN read_incubator_agent_run(key_value);
 END IF;
 -- Uncertain provider acceptance holds this lane even after the process dies.
 IF EXISTS (SELECT 1 FROM incubator_agent_run r JOIN LATERAL
     (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1) e ON true
     WHERE e.state IN ('admitted','dispatched','indeterminate')) THEN
   RAISE EXCEPTION 'research lane occupied; inspect the existing run' USING ERRCODE='55000';
 END IF;
 config_value := jsonb_build_object('agent_name','Research Scout','role','quantitative_research_and_experimentation',
   'provider','openrouter','model',model_value,'input',incubator_poc_brief(), 'limits',budget,
   'prompt_version','research-scout-v1','output_schema','hypothesis-report-v1');
 assignment := engine_admit_research_assignment(jsonb_build_object(
   'assignment_key','agent-poc:'||key_value,'lane','research','desk_role',config_value->>'role',
   'budget',budget,'stopping_rule',stopping,
   'profit_contribution_hypothesis',jsonb_build_object(
      'claim','Rapidly falsify an uneconomic stock momentum premise before spending on experiments.',
      'metric','One testable hypothesis, evidence gaps, and a falsification experiment; no measured return claim.',
      'cost_envelope',budget,'stopping_rule',stopping)),lineage);
 INSERT INTO incubator_agent_run VALUES(key_value,assignment.assignment_id,config_value,lineage,clock_timestamp(),'local_research');
 INSERT INTO incubator_agent_event VALUES(key_value,1,'admitted','{}',lineage,clock_timestamp(),'local_research');
 PERFORM append_audit_event('agent-poc:'||key_value||':1','research.agent_admitted',now(),
   jsonb_build_object('run_key',key_value,'config',config_value),lineage,now(),'local_research');
 RETURN read_incubator_agent_run(key_value);
END;
$$;

CREATE FUNCTION record_incubator_agent_event(key_value text, state_value text, detail_value jsonb)
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
 IF NOT ((prior.state='admitted' AND state_value IN ('dispatched','failed'))
      OR (prior.state='dispatched' AND state_value IN ('completed','failed','indeterminate'))) THEN
   RAISE EXCEPTION 'invalid run transition; no redispatch or terminal rewrite' USING ERRCODE='55000';
 END IF;
 IF state_value='completed' AND jsonb_typeof(detail_value->'report') IS DISTINCT FROM 'object' THEN
   RAISE EXCEPTION 'completed run requires a report' USING ERRCODE='22023';
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

CREATE FUNCTION read_incubator_agent_runs() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
 SELECT jsonb_build_object('environment','local_research','artifact_kind','research_planning',
   'runs',coalesce(jsonb_agg(read_incubator_agent_run(r.run_key) ORDER BY r.receipt_time DESC,r.run_key), '[]'))
 FROM (SELECT run_key,receipt_time FROM incubator_agent_run ORDER BY receipt_time DESC,run_key LIMIT 100) r;
$$;

REVOKE ALL ON FUNCTION admit_incubator_agent_run(text,text,text), record_incubator_agent_event(text,text,jsonb),
 read_incubator_agent_run(text), read_incubator_agent_runs() FROM PUBLIC;
-- Local-only orchestration identity. The model receives text and has no tools,
-- credentials, network access, or database session in this process.
CREATE ROLE incubator_runner LOGIN PASSWORD 'local-poc-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT USAGE ON SCHEMA public TO incubator_runner;
GRANT EXECUTE ON FUNCTION admit_incubator_agent_run(text,text,text),
 record_incubator_agent_event(text,text,jsonb),read_incubator_agent_run(text) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();
