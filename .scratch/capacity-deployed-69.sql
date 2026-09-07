-- Waiting is pre-dispatch state. Keep the original recovery transitions for sent work.
CREATE FUNCTION openrouter_work_ready(prefix_value text) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT NOT EXISTS(SELECT 1 FROM openrouter_capacity_queue WHERE (key=prefix_value OR starts_with(key,prefix_value||CASE WHEN right(prefix_value,1)=':' THEN '' ELSE ':' END)) AND state='queued' AND eligible_at>clock_timestamp())
$$;
REVOKE ALL ON FUNCTION openrouter_work_ready(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION openrouter_work_ready(text) TO incubator_runner,incubator_chat;

CREATE OR REPLACE FUNCTION next_incubator_manual_run() RETURNS text
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT r.run_key FROM incubator_agent_run r JOIN LATERAL
 (SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE (r.run_key IN(SELECT run_key FROM incubator_manual_request)
 OR r.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback f JOIN incubator_manual_request m ON m.run_key=f.parent_run_key))
 AND e.state IN('admitted','preparing','dispatched')
 AND (e.state<>'admitted' OR openrouter_capacity_ready('research:'||r.run_key))
 AND NOT EXISTS(SELECT 1 FROM incubator_agent_run x JOIN LATERAL(SELECT state FROM incubator_agent_event WHERE run_key=x.run_key ORDER BY sequence DESC LIMIT 1)y ON true WHERE y.state='indeterminate')
 ORDER BY (e.state IN('preparing','dispatched')) DESC,r.receipt_time,r.run_key LIMIT 1
$$;
CREATE OR REPLACE FUNCTION next_incubator_evaluation() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT id FROM incubator_evaluation WHERE
 (read_incubator_evaluation(id)->>'status' IN('queued','evaluating','awaiting_clarification')
 OR (read_incubator_evaluation(id)->>'status'='indeterminate' AND EXISTS(SELECT 1 FROM incubator_evaluation_step s LEFT JOIN incubator_evaluation_result r USING(evaluation_id,sequence) WHERE s.evaluation_id=id AND r.state IS NULL)))
 AND openrouter_work_ready('evaluation:'||id||':') ORDER BY id LIMIT 1
$$;
CREATE OR REPLACE FUNCTION next_incubator_refinement() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT id FROM incubator_evaluation e WHERE
 ((read_incubator_evaluation(id)->>'status'='refining' AND NOT coalesce((read_incubator_agent_run(run_key)->>'archived')::boolean,false))
 OR EXISTS(SELECT 1 FROM incubator_refinement a LEFT JOIN incubator_refinement_result r USING(evaluation_id) WHERE a.evaluation_id=e.id AND r.evaluation_id IS NULL))
 AND openrouter_work_ready('refinement:'||id) ORDER BY id LIMIT 1
$$;
CREATE OR REPLACE FUNCTION next_incubator_experiment() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT t.evaluation_id FROM incubator_experiment_ticket t LEFT JOIN LATERAL(SELECT state FROM incubator_experiment_event WHERE experiment_id=t.evaluation_id ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE (e.state IS NULL OR e.state IN('preparing','setup_question','clarifying','clarified','answered','ready','dispatching','running')
 OR (e.state='awaiting_data' AND EXISTS(SELECT 1 FROM incubator_experiment_dataset d WHERE d.experiment_id=t.evaluation_id)))
 AND openrouter_work_ready('experiment:'||t.evaluation_id||':') ORDER BY t.evaluation_id LIMIT 1
$$;

ALTER TABLE incubator_experiment_event DROP CONSTRAINT incubator_experiment_event_state_check;
ALTER TABLE incubator_experiment_event ADD CONSTRAINT incubator_experiment_event_state_check CHECK(state IN('setup_question','clarifying','clarified','answered','awaiting_data','preparing','needs_input','ready','dispatching','running','completed','failed','indeterminate'));
DO $$ DECLARE body text; original text; BEGIN
 original:=pg_get_functiondef('record_incubator_experiment_event_legacy(bigint,text,jsonb)'::regprocedure);
 body:=replace(original,'prior.state=''preparing'' AND state_value IN (''awaiting_data''','prior.state=''preparing'' AND state_value IN (''setup_question'',''awaiting_data''');
 body:=replace(body,'OR (prior.state=''clarifying'' AND','OR (prior.state=''setup_question'' AND state_value IN (''clarifying'',''failed'')) OR (prior.state=''clarifying'' AND');
 IF body=original OR position('prior.state=''setup_question''' IN body)=0 THEN RAISE EXCEPTION 'experiment_transition_definition_changed'; END IF;
 EXECUTE body;
END $$;

CREATE FUNCTION read_openrouter_work_wait(prefix_value text) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('reason',coalesce(reason,'queued'),'next_eligible_at',eligible_at)
 FROM openrouter_capacity_queue WHERE (key=prefix_value OR starts_with(key,prefix_value||CASE WHEN right(prefix_value,1)=':' THEN '' ELSE ':' END)) AND state='queued' ORDER BY created_at LIMIT 1
$$;
REVOKE ALL ON FUNCTION read_openrouter_work_wait(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_openrouter_work_wait(text) TO incubator_runner,incubator_chat;
ALTER FUNCTION read_incubator_agent_run(text) RENAME TO read_incubator_agent_run_before_capacity;
CREATE FUNCTION read_incubator_agent_run(key_value text) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_incubator_agent_run_before_capacity(key_value)||jsonb_build_object('capacity_wait',read_openrouter_work_wait('research:'||key_value))
$$;
ALTER FUNCTION read_incubator_evaluation(bigint) RENAME TO read_incubator_evaluation_before_capacity;
CREATE FUNCTION read_incubator_evaluation(id_value bigint) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_incubator_evaluation_before_capacity(id_value)||jsonb_build_object('capacity_wait',coalesce(read_openrouter_work_wait('evaluation:'||id_value||':'),read_openrouter_work_wait('refinement:'||id_value)))
$$;
ALTER FUNCTION read_incubator_experiment(bigint) RENAME TO read_incubator_experiment_before_capacity;
CREATE FUNCTION read_incubator_experiment(id_value bigint) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_incubator_experiment_before_capacity(id_value)||jsonb_build_object('capacity_wait',read_openrouter_work_wait('experiment:'||id_value||':'))
$$;
REVOKE ALL ON FUNCTION read_incubator_agent_run(text),read_incubator_evaluation(bigint),read_incubator_experiment(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_agent_run(text),read_incubator_evaluation(bigint),read_incubator_experiment(bigint) TO incubator_runner,incubator_chat;

SELECT assert_all_evidence_table_conventions();

-- A manually chosen paid conversation keeps that model. The capacity receipt
-- proves this was admitted as manual work, independently of automated settings.
DO $$ DECLARE body text; original text; old_clause text; new_clause text; BEGIN
 original:=pg_get_functiondef('admit_incubator_chat(text,text,integer,text,jsonb)'::regprocedure);
 old_clause:='request_value->''provider''->''max_price'' IS DISTINCT FROM ''{"prompt":0,"completion":0}''::jsonb';
 new_clause:='(request_value->''provider''->''max_price'' IS DISTINCT FROM ''{"prompt":0,"completion":0}''::jsonb AND NOT EXISTS(SELECT 1 FROM openrouter_capacity_attempt a WHERE a.key=''chat:''||key_value||'':''||id_value AND a.trigger=''manual'' AND a.request_fingerprint=encode(digest(request_value::text,''sha256''),''hex'')))';
 body:=replace(original,old_clause,new_clause);
 IF body=original THEN RAISE EXCEPTION 'chat_admission_definition_changed'; END IF;
 EXECUTE body;
END $$;
