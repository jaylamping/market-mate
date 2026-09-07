BEGIN;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('revisit-no-source','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('revisit-no-source','dispatched','{}');
SELECT record_incubator_agent_event('revisit-no-source','completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
SELECT queue_incubator_evaluations();
DO $$
DECLARE id bigint:=next_incubator_evaluation(); seq integer; request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}';
BEGIN
 seq:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Diagnostic","question":null}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'awaiting_data','{"spec":{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":0}}');
 IF next_incubator_experiment() IS NOT NULL THEN RAISE EXCEPTION 'unconfigured_connector_revisited_ticket'; END IF;
 BEGIN
  PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
  RAISE EXCEPTION 'revisit_without_source_was_accepted';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'setup_revisit_not_eligible' THEN RAISE; END IF;
 END;
 IF read_incubator_experiment(id)->>'status'<>'awaiting_data' THEN RAISE EXCEPTION 'rejected_revisit_changed_ticket'; END IF;
END $$;
ROLLBACK;
