-- Synthetic data exists only in this isolated acceptance project.
SELECT append_research_snapshot('incubator_momentum_daily_v1',jsonb_build_object(
 'dataset_class','fixture','symbols',jsonb_build_array('A','B','C','D'),
 'sessions',jsonb_build_array('2026-01-05','2026-01-06','2026-01-07','2026-01-08'),
 'series',(SELECT jsonb_agg(jsonb_build_object('symbol',symbol,'bars',(SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',10000+i*t*100,'close_cents',10000+i*t*200) ORDER BY t) FROM (VALUES(0,'2026-01-05'),(1,'2026-01-06'),(2,'2026-01-07'),(3,'2026-01-08')) day(t,d)))) FROM (VALUES(-1,'A'),(0,'B'),(1,'C'),(2,'D')) stock(i,symbol)),
 'benchmark',(SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',10000,'close_cents',10010) ORDER BY d) FROM (VALUES('2026-01-05'),('2026-01-06'),('2026-01-07'),('2026-01-08')) day(d)),
 'cash_bps',jsonb_build_array(0,0,0,0)), '{"source":"isolated-experiment-fixture","entitlement_version":"fixture-v1"}',NULL,NULL);
BEGIN;
CREATE FUNCTION pg_temp.reject(q text, expected text DEFAULT 'P0001', message text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected AND (message IS NULL OR SQLERRM=message) THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',q;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('experiment-probe','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('experiment-probe','dispatched','{}');
SELECT record_incubator_agent_event('experiment-probe','completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
SELECT queue_incubator_evaluations();
DO $$ DECLARE id bigint:=next_incubator_evaluation(); request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; seq integer; snapshot uuid; spec jsonb:='{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":0}'; BEGIN
 seq:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"A diagnostic","question":null}');
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''completed'',''{}'')',id));
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,NULL,''{}'')',id));
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''preparing'',''{}'')',id));
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'needs_input','{"question":"Which method?"}');
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''answered'',''{"answer":""}'')',id));
 PERFORM record_incubator_experiment_event(id,'answered','{"answer":"Fixed diagnostic"}');
 PERFORM record_incubator_experiment_event(id,'answered','{"answer":"Fixed diagnostic"}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''ready'',%L)',id,jsonb_build_object('spec',spec)));
 PERFORM record_incubator_experiment_event(id,'awaiting_data',jsonb_build_object('spec',spec));
 snapshot:=(read_incubator_momentum_datasets()->0->>'id')::uuid;
 PERFORM bind_incubator_experiment_dataset(id,snapshot);PERFORM bind_incubator_experiment_dataset(id,snapshot);
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''ready'',''{"spec":null}'')',id));
 PERFORM record_incubator_experiment_event(id,'ready',jsonb_build_object('spec',spec));
 PERFORM record_incubator_experiment_event(id,'ready',jsonb_build_object('spec',spec));
 IF length(read_incubator_experiment(id)->'detail'->>'registration_digest') IS DISTINCT FROM 64 THEN RAISE EXCEPTION 'missing registration'; END IF;
 PERFORM record_incubator_experiment_event(id,'dispatching',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'running','{}');
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''completed'',''{}'')',id));
 PERFORM record_incubator_experiment_event(id,'completed','{"result":{"engine":"momentum_v1","outcome":"diagnostic_only"}}');
 IF next_incubator_experiment() IS NOT NULL THEN RAISE EXCEPTION 'completed job selected'; END IF;
END $$;
SELECT pg_temp.reject('UPDATE incubator_experiment_event SET detail=''{}''','42501');
SELECT pg_temp.reject('DELETE FROM incubator_experiment_dataset','42501');
RESET ROLE;
SELECT pg_temp.reject('UPDATE incubator_experiment_event SET detail=detail||''{"changed":true}''','55000');
SELECT pg_temp.reject('DELETE FROM incubator_experiment_dataset','55000');
SELECT pg_temp.reject('TRUNCATE incubator_experiment_event','55000');
DO $$ BEGIN
 IF (SELECT count(*) FROM incubator_experiment_dataset)<>1 THEN RAISE EXCEPTION 'duplicate dataset'; END IF;
 IF NOT (SELECT valid FROM verify_audit_event_chain()) THEN RAISE EXCEPTION 'audit invalid'; END IF;
END $$;

DO $$ DECLARE id bigint; seq integer; snapshot uuid; successor research_snapshot%ROWTYPE; report jsonb;
 request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}';
 spec jsonb:='{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":0}'; BEGIN
 report:=read_incubator_agent_run('experiment-probe')->'detail'->'report';
 PERFORM admit_incubator_agent_run('superseded-experiment','vendor/model:free','momentum-brief-v1');
 PERFORM record_incubator_agent_event('superseded-experiment','dispatched','{}');
 PERFORM record_incubator_agent_event('superseded-experiment','completed',jsonb_build_object('report',report));
 PERFORM queue_incubator_evaluations();id:=next_incubator_evaluation();
 seq:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"A diagnostic","question":null}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id,'awaiting_data',jsonb_build_object('spec',spec));
 snapshot:=(read_incubator_momentum_datasets()->0->>'id')::uuid;
 PERFORM bind_incubator_experiment_dataset(id,snapshot);
 PERFORM record_incubator_experiment_event(id,'ready',jsonb_build_object('spec',spec));
 successor:=append_research_snapshot('incubator_momentum_daily_v1',(SELECT payload FROM research_snapshot WHERE snapshot_id=snapshot),'{"source":"isolated-experiment-fixture","entitlement_version":"fixture-v1"}',snapshot,'Correction fixture');
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''dispatching'',%L)',id,jsonb_build_object('request',request)),'P0001','dataset_superseded');
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(read_incubator_momentum_datasets()) d WHERE d->>'id'=snapshot::text) THEN RAISE EXCEPTION 'superseded dataset listed'; END IF;
 PERFORM admit_incubator_chat('superseded-experiment','new-plan',0,'Refine',request||'{"stream":true}');
 PERFORM finish_incubator_chat('superseded-experiment','new-plan','completed',jsonb_build_object('reply','Refined','proposal',report||'{"hypothesis":"New hypothesis"}'));
 PERFORM apply_incubator_plan('superseded-experiment',1,0);
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''dispatching'',%L)',id,jsonb_build_object('request',request)),'P0001','research_superseded');
 IF read_incubator_experiment_input(id)->'evaluation'->'report' IS DISTINCT FROM report THEN RAISE EXCEPTION 'pinned report changed'; END IF;
END $$;
SELECT jsonb_build_object('probe','incubator-experiment','passed',true,'checks',jsonb_build_array('null_transition_denied','bounded_request_required','owner_input_idempotency','dataset_required','ready_idempotency_after_digest_enrichment','completion_shape','restricted_role','populated_append_only_tables','audit_chain','superseded_dataset_denied','superseded_research_denied','pinned_report_preserved'));
ROLLBACK;
