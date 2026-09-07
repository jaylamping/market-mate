SELECT append_research_snapshot('incubator_momentum_daily_v1',jsonb_build_object(
 'dataset_class','fixture','symbols',jsonb_build_array('A','B','C','D'),
 'sessions',jsonb_build_array('2026-01-05','2026-01-06','2026-01-07','2026-01-08'),
 'series',(SELECT jsonb_agg(jsonb_build_object('symbol',symbol,'bars',(SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',10000+i*t*100,'close_cents',10000+i*t*200) ORDER BY t) FROM (VALUES(0,'2026-01-05'),(1,'2026-01-06'),(2,'2026-01-07'),(3,'2026-01-08')) day(t,d)))) FROM (VALUES(-1,'A'),(0,'B'),(1,'C'),(2,'D')) stock(i,symbol)),
 'benchmark',(SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',10000,'close_cents',10010) ORDER BY d) FROM (VALUES('2026-01-05'),('2026-01-06'),('2026-01-07'),('2026-01-08')) day(d)),
 'cash_bps',jsonb_build_array(0,0,0,0)), '{"source":"isolated-experiment-fixture","entitlement_version":"fixture-v1"}',NULL,NULL);
BEGIN;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('experiment-dispatch-retry','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('experiment-dispatch-retry','dispatched','{}');
SELECT record_incubator_agent_event('experiment-dispatch-retry','completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
SELECT queue_incubator_evaluations();
DO $$
DECLARE id bigint:=next_incubator_evaluation(); seq integer; snapshot uuid;
 request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}';
 spec jsonb:='{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":0}';
BEGIN
 seq:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Diagnostic","question":null}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'awaiting_data',jsonb_build_object('spec',spec));
 snapshot:=(read_incubator_momentum_datasets()->0->>'id')::uuid;
 PERFORM bind_incubator_experiment_dataset(id,snapshot);
 PERFORM record_incubator_experiment_event(id,'ready',jsonb_build_object('spec',spec));
 PERFORM record_incubator_experiment_event(id,'dispatching',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'failed','{"reason":"invalid_experiment_agent_response"}');
 IF NOT coalesce((read_incubator_experiment(id)->>'experiment_retry_available')::boolean,false) THEN RAISE EXCEPTION 'dispatch_retry_unavailable'; END IF;
 IF next_incubator_experiment() IS DISTINCT FROM id THEN RAISE EXCEPTION 'failed_dispatch_not_selected'; END IF;
 PERFORM record_incubator_experiment_event(id,'experiment_retry','{}');
 IF next_incubator_experiment() IS DISTINCT FROM id THEN RAISE EXCEPTION 'queued_dispatch_retry_not_selected'; END IF;
 PERFORM record_incubator_experiment_event(id,'dispatching',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'failed','{"reason":"invalid_experiment_agent_response"}');
 IF coalesce((read_incubator_experiment(id)->>'experiment_retry_available')::boolean,false) THEN RAISE EXCEPTION 'second_dispatch_retry_available'; END IF;
 BEGIN
  PERFORM record_incubator_experiment_event(id,'experiment_retry','{}');
  RAISE EXCEPTION 'second_dispatch_retry_accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'experiment_retry_unavailable' THEN RAISE; END IF; END;
 IF next_incubator_experiment() IS NOT NULL THEN RAISE EXCEPTION 'exhausted_dispatch_retry_selected'; END IF;
END $$;
SELECT jsonb_build_object('probe','experiment-dispatch-retry','passed',true);
ROLLBACK;
