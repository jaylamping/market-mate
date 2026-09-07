BEGIN;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('setup-retry-budget','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('setup-retry-budget','dispatched','{}');
SELECT record_incubator_agent_event('setup-retry-budget','completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
SELECT queue_incubator_evaluations();
DO $$
DECLARE id bigint:=next_incubator_evaluation(); seq integer; before_count integer; request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}';
BEGIN
 seq:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Diagnostic","question":null}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'setup_question','{"question":"Confirm scope"}');
 PERFORM record_incubator_experiment_event(id,'clarifying',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'clarified','{"answer":"Diagnostic only"}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'needs_input','{"question":"Which dates?"}');
 PERFORM record_incubator_experiment_event(id,'answered','{"answer":"Use the pinned dates"}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'failed','{"reason":"invalid_experiment_agent_response"}');
 PERFORM set_incubator_research_archived('setup-retry-budget','archive',true,0);
 IF (read_incubator_experiment(id)->>'setup_retry_available')::boolean THEN RAISE EXCEPTION 'archived_retry_available'; END IF;
 BEGIN
  PERFORM retry_incubator_setup(id);
  RAISE EXCEPTION 'archived_retry_accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'setup_retry_unavailable' THEN RAISE; END IF; END;
 PERFORM set_incubator_research_archived('setup-retry-budget','unarchive',false,1);
 IF NOT retry_incubator_setup(id) THEN RAISE EXCEPTION 'retry_not_queued'; END IF;
 IF retry_incubator_setup(id) THEN RAISE EXCEPTION 'duplicate_retry_queued'; END IF;
 IF next_incubator_experiment() IS DISTINCT FROM id THEN RAISE EXCEPTION 'retry_not_selected'; END IF;
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'failed','{"reason":"invalid_experiment_agent_response"}');
 IF (read_incubator_experiment(id)->>'setup_retry_available')::boolean THEN RAISE EXCEPTION 'second_retry_available'; END IF;
 BEGIN
  PERFORM record_incubator_experiment_event(id,'setup_retry','{}');
  RAISE EXCEPTION 'second_retry_accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'setup_retry_unavailable' THEN RAISE; END IF; END;
 IF next_incubator_experiment() IS NOT NULL THEN RAISE EXCEPTION 'failed_ticket_auto_retried'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(read_incubator_experiment(id)->'events') e WHERE e->>'state'='preparing')<>4 THEN RAISE EXCEPTION 'retry_budget_mismatch'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(read_incubator_experiment(id)->'events') e WHERE e->>'state'='failed')<>2 THEN RAISE EXCEPTION 'failure_history_lost'; END IF;
END $$;
SELECT admit_incubator_agent_run('setup-retry-unknown','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('setup-retry-unknown','dispatched','{}');
SELECT record_incubator_agent_event('setup-retry-unknown','completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
SELECT queue_incubator_evaluations();
DO $$
DECLARE id bigint:=next_incubator_evaluation(); seq integer; request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}';
BEGIN
 seq:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Diagnostic","question":null}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'indeterminate','{"reason":"invalid_experiment_agent_response"}');
 IF (read_incubator_experiment(id)->>'setup_retry_available')::boolean THEN RAISE EXCEPTION 'unknown_outcome_retry_available'; END IF;
 BEGIN
  PERFORM retry_incubator_setup(id);
  RAISE EXCEPTION 'unknown_outcome_retry_accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'setup_retry_unavailable' THEN RAISE; END IF; END;
END $$;
ROLLBACK;
