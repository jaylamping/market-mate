-- All provider observations below are synthetic and confined to this disposable database.
BEGIN;
CREATE FUNCTION pg_temp.assert(ok boolean,msg text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',msg; END IF; END $$;
CREATE FUNCTION pg_temp.reject(q text,code text DEFAULT 'P0001') RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=code THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',q;
END $$;
CREATE FUNCTION pg_temp.source(label text, certification text DEFAULT 'certified') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE s uuid; v uuid; e uuid; ev uuid; lineage jsonb:='{"source":"isolated-wu61-fixture","entitlement_version":"fixture-only"}'; BEGIN
 INSERT INTO source_registry(source_key,source_name,source_kind,source_lineage,receipt_time,record_environment) VALUES(label,label,'market_data',lineage,now(),'local_research') RETURNING source_id INTO s;
 INSERT INTO source_registry_version(source_id,registry_version,lifecycle,license_terms,permitted_use,lineage_rules,observation_states,correction_semantics,effective_from,source_lineage,receipt_time,record_environment)
 VALUES(s,1,'active','{"name":"isolated test only"}','{"purposes":["local_research"]}','{"required_fields":[]}',ARRAY['current'],ARRAY['required_deletion'],now()-interval '1 day',lineage,now(),'local_research') RETURNING source_version_id INTO v;
 INSERT INTO data_entitlement(entitlement_key,account_scope,plan_name,source_lineage,receipt_time,record_environment) VALUES(label,'fixture account','fixture plan',lineage,now(),'local_research') RETURNING entitlement_id INTO e;
 INSERT INTO data_entitlement_version(entitlement_id,entitlement_version,source_registry_version_id,certification_state,authorized_purposes,effective_from,certification_basis,source_lineage,receipt_time,record_environment)
 VALUES(e,1,v,certification,ARRAY['local_research'],now()-interval '1 day','{"authority":"isolated acceptance fixture, not a real provider approval"}',lineage,now(),'local_research') RETURNING entitlement_version_id INTO ev;
 RETURN configure_market_data_source(v,ev);
END $$;
CREATE FUNCTION pg_temp.bundle() RETURNS jsonb LANGUAGE sql AS $$
 WITH dates AS (SELECT d FROM unnest(ARRAY['2026-01-05','2026-01-06','2026-01-07','2026-01-08']) d),
 bars AS (SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',12345,'close_cents',12445) ORDER BY d) b FROM dates),
 panel AS (SELECT jsonb_build_object('dataset_class','observed','symbols','["A","B","C","D"]'::jsonb,'sessions',(SELECT jsonb_agg(d ORDER BY d) FROM dates),'series',(SELECT jsonb_agg(jsonb_build_object('symbol',s,'bars',b) ORDER BY s) FROM unnest(ARRAY['A','B','C','D']) s),'benchmark',b,'cash_bps','[0,0,0,0]'::jsonb) p FROM bars)
 SELECT jsonb_build_object('schema','market_mate_daily_download_v1','panel',p,'request',jsonb_build_object('symbols',p->'symbols','sessions',p->'sessions','benchmark','SPY','cash','zero_interest','symbol_asof','2026-01-08','spec',jsonb_build_object('runner','momentum_v1','lookback_sessions',1,'quantile_count',2,'one_way_cost_bps',5,'borrow_bps_per_session',0)),
 'source_facts','{"provider":"alpaca","feed":"sip","currency":"USD","adjustment":"all","cash":"assumed_zero_interest","symbol_asof":"2026-01-08"}'::jsonb,
 'observations',(SELECT jsonb_agg(jsonb_build_object('symbol',s,'session',d,'bar',jsonb_build_object('t',d||'T05:00:00Z','o',123.451234,'h',125,'l',122,'c',124.451234,'v',1000)) ORDER BY s,d) FROM unnest(ARRAY['A','B','C','D','SPY']) s CROSS JOIN dates)) FROM panel
$$;
CREATE FUNCTION pg_temp.experiment(label text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE id bigint; seq integer; BEGIN
 PERFORM admit_incubator_agent_run(label,'vendor/model:free','momentum-brief-v1');
 PERFORM record_incubator_agent_event(label,'dispatched','{}');
 PERFORM record_incubator_agent_event(label,'completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
 PERFORM queue_incubator_evaluations(); id:=next_incubator_evaluation();
 seq:=begin_incubator_evaluation_step(id,'evaluation','{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}');
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Diagnostic","question":null}');
 RETURN id;
END $$;
SELECT pg_temp.reject($q$SELECT pg_temp.source('wu61-uncertified','uncertified')$q$);
CREATE TEMP TABLE ids(k text PRIMARY KEY,v uuid);
INSERT INTO ids VALUES('source_a',pg_temp.source('wu61-a')),('source_b',pg_temp.source('wu61-b'));
GRANT SELECT,INSERT,UPDATE ON ids TO market_data_writer,incubator_runner;
SET LOCAL ROLE market_data_writer;
INSERT INTO ids VALUES('snapshot_a',register_market_data_download((SELECT v FROM ids WHERE k='source_a'),pg_temp.bundle()));
SELECT pg_temp.assert(register_market_data_download((SELECT v FROM ids WHERE k='source_a'),pg_temp.bundle())=(SELECT v FROM ids WHERE k='snapshot_a'),'import must be idempotent');
INSERT INTO ids VALUES('snapshot_shared',register_market_data_download((SELECT v FROM ids WHERE k='source_a'),jsonb_set(pg_temp.bundle(),'{request,spec,one_way_cost_bps}','6')));
INSERT INTO ids VALUES('snapshot_b',register_market_data_download((SELECT v FROM ids WHERE k='source_b'),pg_temp.bundle()));
SELECT pg_temp.reject(format('SELECT register_market_data_download(%L,%L)',(SELECT v FROM ids WHERE k='source_a'),jsonb_set(pg_temp.bundle(),'{panel,series,0,bars,0,open_cents}','1')));
SELECT pg_temp.reject('DELETE FROM market_data_payload','42501');
SELECT pg_temp.reject('UPDATE market_data_dataset SET removed_at=now()','42501');
SELECT pg_temp.reject('DELETE FROM research_snapshot','42501');
SELECT pg_temp.reject('SELECT record_incubator_experiment_event_legacy(1,''completed'',''{}'')','42501');
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM market_data_observation WHERE source_id=(SELECT v FROM ids WHERE k='source_a'))=20,'shared observations were duplicated');
SET LOCAL ROLE market_data_writer;
INSERT INTO ids VALUES('snapshot_corrected',register_market_data_download((SELECT v FROM ids WHERE k='source_a'),jsonb_set(jsonb_set(pg_temp.bundle(),'{panel,series,0,bars,0,open_cents}','12344'),'{observations,0,bar,o}','123.441234')));
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM market_data_observation WHERE source_id=(SELECT v FROM ids WHERE k='source_a'))=21,'correction must append one observation');
SELECT pg_temp.assert((SELECT panel FROM market_data_payload p JOIN market_data_dataset d ON d.id=p.dataset_id WHERE d.snapshot_id=(SELECT v FROM ids WHERE k='snapshot_a'))=pg_temp.bundle()->'panel','correction changed pinned original');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM research_snapshot WHERE payload::text LIKE '%12345%'),'snapshot contains prices');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM audit_event WHERE payload::text LIKE '%12345%'),'audit contains prices');
CREATE TEMP TABLE experiments(k text PRIMARY KEY,id bigint);
GRANT SELECT,INSERT ON experiments TO incubator_runner;
SET LOCAL ROLE incubator_runner;
INSERT INTO experiments VALUES('a',pg_temp.experiment('wu61-a'));
INSERT INTO experiments VALUES('b',pg_temp.experiment('wu61-b'));
INSERT INTO experiments VALUES('failure',pg_temp.experiment('wu61-failure'));
SELECT bind_incubator_experiment_dataset((SELECT id FROM experiments WHERE k='failure'),(SELECT v FROM ids WHERE k='snapshot_a'));
SELECT record_incubator_experiment_event((SELECT id FROM experiments WHERE k='failure'),'failed','{"reason":"bad observation 314159265","provider_bar":{"o":314159265}}');
SELECT pg_temp.assert(read_incubator_experiment((SELECT id FROM experiments WHERE k='failure'))->'detail'->'provider_bar'->>'o'='314159265','managed failure details must resolve before removal');
SELECT bind_incubator_experiment_dataset((SELECT id FROM experiments WHERE k='a'),(SELECT v FROM ids WHERE k='snapshot_a'));
SELECT bind_incubator_experiment_dataset((SELECT id FROM experiments WHERE k='b'),(SELECT v FROM ids WHERE k='snapshot_b'));
SELECT pg_temp.assert(read_incubator_experiment_input((SELECT id FROM experiments WHERE k='a'))->'payload'=pg_temp.bundle()->'panel','snapshot payload resolution failed');
DO $$ DECLARE id_value bigint:=(SELECT id FROM experiments WHERE k='a'); request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; BEGIN
 PERFORM record_incubator_experiment_event(id_value,'preparing',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id_value,'ready',jsonb_build_object('spec',pg_temp.bundle()->'request'->'spec'));
 PERFORM record_incubator_experiment_event(id_value,'dispatching',jsonb_build_object('request',request));
 PERFORM record_incubator_experiment_event(id_value,'running','{}');
 PERFORM record_incubator_experiment_event(id_value,'completed','{"result":{"engine":"momentum_v1","outcome":"diagnostic_only","mean_next_open_net_bps":987654321}}');
 PERFORM record_incubator_experiment_event(id_value,'completed','{"result":{"engine":"momentum_v1","outcome":"diagnostic_only","mean_next_open_net_bps":987654321}}');
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''completed'',''{"result":{"engine":"momentum_v1","outcome":"diagnostic_only","mean_next_open_net_bps":42}}'')',id_value));
 PERFORM pg_temp.assert(read_incubator_experiment(id_value)->'detail'->'result'->>'mean_next_open_net_bps'='987654321','result projection failed');
END $$;
RESET ROLE;
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM audit_event WHERE payload::text LIKE '%987654321%'),'audit has derived result copy');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE detail::text LIKE '%987654321%'),'event has derived result copy');
UPDATE market_data_dataset SET last_used_at=now()-interval '91 days';
SET LOCAL ROLE market_data_writer;
SELECT pg_temp.assert(cleanup_market_data_cache()=2,'cleanup must retain both referenced datasets and expire unused shared panel');
RESET ROLE;
SELECT pg_temp.assert((SELECT count(*) FROM market_data_observation WHERE source_id=(SELECT v FROM ids WHERE k='source_a'))=20,'cleanup removed shared observations');
SET LOCAL ROLE market_data_writer;
SELECT remove_market_data_source((SELECT v FROM ids WHERE k='source_a'));
SELECT pg_temp.reject(format('SELECT register_market_data_download(%L,%L)',(SELECT v FROM ids WHERE k='source_a'),pg_temp.bundle()));
RESET ROLE;
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM market_data_payload WHERE source_id=(SELECT v FROM ids WHERE k='source_a')),'payload remains after purge');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM market_data_observation WHERE source_id=(SELECT v FROM ids WHERE k='source_a')),'observations remain after purge');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM market_data_result),'derived results remain after purge');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM market_data_event_detail),'event detail remains after purge');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM audit_event WHERE payload::text LIKE '%314159265%'),'audit retains failure source copy');
SELECT pg_temp.assert(NOT EXISTS(SELECT 1 FROM incubator_experiment_event WHERE detail::text LIKE '%314159265%'),'event retains failure source copy');
SELECT pg_temp.assert(read_incubator_experiment((SELECT id FROM experiments WHERE k='failure'))::text NOT LIKE '%314159265%','removed failure source copy exposed');
SELECT pg_temp.assert((SELECT count(*) FROM market_data_payload WHERE source_id=(SELECT v FROM ids WHERE k='source_b'))=1,'unrelated panel deleted');
SELECT pg_temp.assert((SELECT count(*) FROM market_data_observation WHERE source_id=(SELECT v FROM ids WHERE k='source_b'))=20,'unrelated observations deleted');
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.assert(read_incubator_experiment((SELECT id FROM experiments WHERE k='a'))->'replay_available'='false','removed data still replayable');
SELECT pg_temp.assert(read_incubator_experiment((SELECT id FROM experiments WHERE k='a'))->'detail'->'result' IS NULL,'removed result still exposed');
SELECT pg_temp.assert(read_incubator_experiment_input((SELECT id FROM experiments WHERE k='a'))->'payload'='null','removed prices still exposed');
SELECT pg_temp.assert(read_incubator_experiment_input((SELECT id FROM experiments WHERE k='b'))->'payload'=pg_temp.bundle()->'panel','unrelated experiment no longer works');
SELECT pg_temp.assert(jsonb_array_length(read_incubator_momentum_datasets())=1,'unavailable panels still selectable');
SELECT pg_temp.reject(format('SELECT bind_incubator_experiment_dataset(%s,%L)',(SELECT id FROM experiments WHERE k='a'),(SELECT v FROM ids WHERE k='snapshot_a')));
RESET ROLE;
SELECT pg_temp.assert((SELECT valid FROM verify_audit_event_chain()),'audit chain invalid');
SELECT jsonb_build_object('work_unit','WU-61','passed',true,'checks',jsonb_build_array('registered_entitlement_required','idempotent_import','shared_observation_identity','correction_preserves_original','panel_raw_consistency','restricted_runtime_role','pointer_only_snapshot','result_reference_only_audit','failure_detail_scoped_purge','resolved_experiment_payload','immutable_result_retry','referenced_retention','shared_cache_cleanup','actual_source_and_derivative_purge','source_tombstone','unrelated_experiment_preserved','replay_unavailable','audit_chain'));
ROLLBACK;
