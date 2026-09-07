-- Synthetic data exists only in this isolated acceptance project.
SELECT append_research_snapshot('incubator_momentum_daily_v1',jsonb_build_object(
 'dataset_class','fixture','symbols',jsonb_build_array('A','B','C','D'),
 'sessions',jsonb_build_array('2026-01-05','2026-01-06','2026-01-07','2026-01-08'),
 'series',(SELECT jsonb_agg(jsonb_build_object('symbol',symbol,'bars',(SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',10000+i*t*100,'close_cents',10000+i*t*200) ORDER BY t) FROM (VALUES(0,'2026-01-05'),(1,'2026-01-06'),(2,'2026-01-07'),(3,'2026-01-08')) day(t,d)))) FROM (VALUES(-1,'A'),(0,'B'),(1,'C'),(2,'D')) stock(i,symbol)),
 'benchmark',(SELECT jsonb_agg(jsonb_build_object('session',d,'open_cents',10000,'close_cents',10010) ORDER BY d) FROM (VALUES('2026-01-05'),('2026-01-06'),('2026-01-07'),('2026-01-08')) day(d)),
 'cash_bps',jsonb_build_array(0,0,0,0)), '{"source":"isolated-experiment-fixture","entitlement_version":"fixture-v1"}',NULL,NULL);
DO $$ BEGIN
 IF read_incubator_campaign()->'agenda' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'empty backlog must be an array'; END IF;
END $$;
-- Disposable model double: all backlog candidates enter through the generator result API.
UPDATE incubator_campaign SET enabled=true,daily_limit=10,open_limit=3,creator_model='vendor/creator:free',backlog_limit=100;
DO $$ DECLARE g jsonb; req jsonb; i integer; BEGIN
 FOR i IN 1..100 LOOP
  g:=claim_incubator_ticket_generation();
  req:=jsonb_build_object('model','vendor/creator:free','max_tokens',2048,'provider',jsonb_build_object('max_price',jsonb_build_object('prompt',0,'completion',0)));
  PERFORM prepare_incubator_ticket_generation((g->>'id')::bigint,req);
  PERFORM dispatch_incubator_ticket_generation((g->>'id')::bigint);
  PERFORM finish_incubator_ticket_generation((g->>'id')::bigint,'completed',jsonb_build_object('proposal',jsonb_build_object('title','Generated test case '||i,'premise','Falsify this isolated hypothesis against SPY and cash after costs.',
   'spec',jsonb_build_object('runner','momentum_v1','lookback_sessions',3,'quantile_count',10,'one_way_cost_bps',(9+i)%101,'borrow_bps_per_session',2))));
 END LOOP;
 IF claim_incubator_ticket_generation() IS NOT NULL THEN RAISE EXCEPTION 'backlog cap not enforced'; END IF;
END $$;
UPDATE incubator_campaign SET enabled=false,revision=0,backlog_limit=10;
BEGIN;
CREATE FUNCTION pg_temp.assert(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'assertion failed: %',label; END IF;
END $$;
CREATE FUNCTION pg_temp.reject(q text, expected text DEFAULT 'P0001', message text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected AND (message IS NULL OR SQLERRM=message) THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',q;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.assert(claim_incubator_ticket_generation() IS NULL,'paused campaign does not generate tickets');
SELECT pg_temp.reject('SELECT set_incubator_campaign(true,101,3,0,''vendor/creator:free'',10)');
SELECT set_incubator_campaign(true,10,1,0,'vendor/creator:free',10);
SELECT pg_temp.reject('SELECT set_incubator_campaign(false,2,3,0,''vendor/creator:free'',10)');
CREATE TEMP TABLE candidate AS SELECT claim_incubator_campaign('vendor/model:free') j;
SELECT pg_temp.assert((SELECT j->>'fresh'='true' FROM candidate),'fresh claim');
SELECT pg_temp.assert(claim_incubator_campaign('vendor/model:free')->>'fresh'='false','restart gets same claim');
SELECT pg_temp.assert((SELECT j->'scope'->>'benchmark'='SPY' AND j->'scope'->>'cash'='zero_interest' FROM candidate),'pinned scope');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM candidate;
SELECT finish_incubator_request_check(j->>'request_id','{"complete":true,"matches":[]}') FROM candidate;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM candidate;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM candidate;
SELECT pg_temp.assert(read_incubator_campaign()->>'created_count'='1','idempotent admission');
SELECT pg_temp.assert(next_incubator_manual_run()='campaign-pilot-v1-1','existing worker selects automatic ticket');
SELECT pg_temp.assert(read_incubator_agent_run('campaign-pilot-v1-1')->'config'->>'manual_model_spend'='false','no manual spending authority');
SELECT pg_temp.assert(read_incubator_agent_run('campaign-pilot-v1-1')->>'created_by'='agent','automatic provenance');
SELECT pg_temp.assert(claim_incubator_campaign('vendor/model:free') IS NULL,'open limit after first admission');
RESET ROLE;
UPDATE incubator_campaign SET next_at=now()-interval '1 minute';
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.assert(claim_incubator_campaign('vendor/model:free') IS NULL,'open limit enforced');
SELECT pg_temp.reject('UPDATE incubator_campaign SET enabled=true','42501');
SELECT record_incubator_agent_event('campaign-pilot-v1-1','dispatched','{}');
SELECT record_incubator_agent_event('campaign-pilot-v1-1','completed','{"report":{"hypothesis":"Test the exact case","evidence_gaps":["Observed prices"],"experiment":["Exact momentum case"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
SELECT queue_incubator_evaluations();
DO $$ DECLARE id bigint:=next_incubator_evaluation(); seq integer; j jsonb:=(SELECT candidate.j FROM candidate); req jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; spec jsonb:='{"runner":"momentum_v1","lookback_sessions":3,"quantile_count":10,"one_way_cost_bps":10,"borrow_bps_per_session":2}'; BEGIN
 seq:=begin_incubator_evaluation_step(id,'evaluation',req);
 PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Bounded diagnostic","question":null}');
 PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',req));
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''awaiting_data'',%L)',id,jsonb_build_object('spec',spec||'{"lookback_sessions":1}','data_request',j->'scope')));
 PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''awaiting_data'',%L)',id,jsonb_build_object('spec',spec,'data_request',(j->'scope')||'{"benchmark":"QQQ"}')));
 PERFORM record_incubator_experiment_event(id,'awaiting_data',jsonb_build_object('spec',spec,'data_request',j->'scope'));
 PERFORM pg_temp.reject(format('SELECT supply_market_data_request(%s,%L)',id,(j->'scope')||'{"benchmark":"QQQ"}'));
 PERFORM pg_temp.reject(format('SELECT bind_incubator_experiment_dataset(%s,%L)',id,read_incubator_momentum_datasets()->0->>'id'),'P0001','campaign_dataset_mismatch');
 PERFORM record_incubator_experiment_event(id,'failed','{"reason":"isolated boundary probe"}');
END $$;
SELECT set_incubator_campaign(true,10,3,1,'vendor/creator:free',10);
RESET ROLE;
UPDATE incubator_campaign SET next_at=now()+interval '1 hour';
SET LOCAL ROLE incubator_runner;
TRUNCATE candidate;
INSERT INTO candidate SELECT claim_incubator_campaign('vendor/model:free');
SELECT pg_temp.assert((SELECT j IS NOT NULL FROM candidate),'claim ignores next_at');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM candidate;
SELECT finish_incubator_request_check(j->>'request_id',jsonb_build_object('complete',true,'matches',jsonb_build_array(jsonb_build_object('id','prior','reason','rewritten exact case','text',j->>'text')))) FROM candidate;
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM candidate;
SELECT pg_temp.assert(read_incubator_campaign()->>'created_count'='1','duplicate creates no ticket');
RESET ROLE;
UPDATE incubator_campaign SET next_at=now()-interval '1 minute';
SET LOCAL ROLE incubator_runner;
TRUNCATE candidate;
INSERT INTO candidate SELECT claim_incubator_campaign('vendor/model:free');
SELECT begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model')) FROM candidate;
SELECT finish_incubator_request_check(j->>'request_id','{"complete":true,"matches":[]}') FROM candidate;
SELECT set_incubator_campaign(false,10,3,2,'vendor/creator:free',10);
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM candidate;
SELECT pg_temp.assert(read_incubator_campaign()->>'created_count'='1','settings change during check fences admission');
SELECT pg_temp.assert(read_incubator_campaign()->'agenda'->2->>'state'='cancelled','settings change during check cancelled');
SELECT pg_temp.assert(read_incubator_campaign()->>'note' LIKE 'Paused.%','cancelled check preserves owner pause explanation');
SELECT pg_temp.assert(read_incubator_campaign()->'agenda'->2->>'creator_model'='vendor/creator:free','proposal preserves creator model');
SELECT pg_temp.assert(read_incubator_campaign()->'agenda'->2->'check'->>'complete'='true','stopped proposal preserves check evidence');
SELECT set_incubator_campaign(true,10,3,3,'vendor/creator:free',100);
RESET ROLE;
UPDATE incubator_campaign SET next_at=now()-interval '1 minute';
SET LOCAL ROLE incubator_runner;
TRUNCATE candidate;
INSERT INTO candidate SELECT claim_incubator_campaign('vendor/model:free');
SELECT finish_incubator_campaign((j->>'ordinal')::int) FROM candidate;
SELECT pg_temp.assert(read_incubator_campaign()->>'enabled'='true','interrupted check does not pause campaign');
SELECT pg_temp.assert((SELECT count(*) FROM jsonb_array_elements(read_incubator_campaign()->'agenda') x WHERE x->>'retry_of'=(SELECT j->>'ordinal' FROM candidate))=1,'interrupted check queues a linked retry');
RESET ROLE;
SELECT pg_temp.assert((SELECT valid FROM verify_audit_event_chain()),'audit chain');
ROLLBACK;
BEGIN;
CREATE FUNCTION pg_temp.reject(q text, expected text DEFAULT 'P0001', message text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected AND (message IS NULL OR SQLERRM=message) THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',q;
END $$;
DO $$ DECLARE j jsonb; i integer; scope_value jsonb; id bigint; seq integer; req jsonb:='{"model":"vendor/backup:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; BEGIN
 PERFORM set_incubator_campaign(true,25,3,0,'vendor/creator:free',10);
 FOR i IN 1..25 LOOP
  UPDATE incubator_campaign SET next_at=now()-interval '1 minute';
  j:=claim_incubator_campaign('vendor/model:free');
  IF j IS NULL THEN RAISE EXCEPTION 'candidate missing at %',i; END IF;
  PERFORM begin_incubator_request_check(j->>'request_id',jsonb_build_object('title',j->>'title','text',j->>'text','model',j->>'model'));
  PERFORM finish_incubator_request_check(j->>'request_id','{"complete":true,"matches":[]}');
  PERFORM finish_incubator_campaign((j->>'ordinal')::int);
  -- Terminal failure frees the queue only in this admission-limit probe; live completion is verified separately.
  PERFORM record_incubator_agent_event(j->>'request_id','failed','{"reason":"isolated admission-limit probe"}');
  IF i=1 THEN
   PERFORM admit_incubator_agent_fallback(j->>'request_id','campaign-fallback-probe','vendor/backup:free',0);
   PERFORM record_incubator_agent_event('campaign-fallback-probe','dispatched','{}');
   PERFORM record_incubator_agent_event('campaign-fallback-probe','completed','{"report":{"hypothesis":"Fallback case","evidence_gaps":["Prices"],"experiment":["Exact case"],"falsification_rule":"Reject net underperformance","limitations":["Diagnostic only"]}}');
   PERFORM queue_incubator_evaluations(); id:=next_incubator_evaluation();
   seq:=begin_incubator_evaluation_step(id,'evaluation',req);
   PERFORM finish_incubator_evaluation_step(id,seq,'completed','{"decision":"advance","reason":"Exact diagnostic","question":null}');
   PERFORM record_incubator_experiment_event(id,'preparing',jsonb_build_object('request',req));
   PERFORM pg_temp.reject(format('SELECT record_incubator_experiment_event(%s,''awaiting_data'',%L)',id,jsonb_build_object('spec','{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":0,"borrow_bps_per_session":0}'::jsonb,'data_request',j->'scope')),'P0001','campaign_spec_mismatch');
   PERFORM record_incubator_experiment_event(id,'failed','{"reason":"isolated fallback boundary probe"}');
  END IF;
 END LOOP;
 IF read_incubator_campaign()->>'created_count'<>'25' THEN RAISE EXCEPTION 'daily admission limit not reached'; END IF;
 UPDATE incubator_campaign SET next_at=clock_timestamp()-interval '1 second';
 IF claim_incubator_campaign('vendor/model:free') IS NOT NULL THEN RAISE EXCEPTION 'daily limit exceeded'; END IF;
 IF read_incubator_campaign()->>'enabled'<>'true' THEN RAISE EXCEPTION 'milestone stopped campaign'; END IF;
 PERFORM set_incubator_campaign(true,50,10,1,'vendor/creator:free',100);
 IF claim_incubator_campaign('vendor/model:free') IS NULL THEN RAISE EXCEPTION 'continuous intake did not resume above 25'; END IF;
END $$;
ROLLBACK;
BEGIN;
DO $$ DECLARE g jsonb; next_job jsonb; req jsonb; candidate jsonb; BEGIN
 PERFORM set_incubator_campaign(true,10,3,0,'vendor/creator:free',100);
 candidate:=claim_incubator_campaign('vendor/model:free');
 g:=claim_incubator_ticket_generation();
 IF g IS NULL OR g->>'model'<>'vendor/creator:free' THEN RAISE EXCEPTION 'creator choice lost'; END IF;
 req:='{"model":"vendor/creator:free","max_tokens":2048}';
 PERFORM prepare_incubator_ticket_generation((g->>'id')::bigint,req);
 PERFORM prepare_incubator_ticket_generation((g->>'id')::bigint,req);
 PERFORM dispatch_incubator_ticket_generation((g->>'id')::bigint);
 PERFORM set_incubator_campaign(true,10,3,1,'vendor/new-creator:free',100);
 PERFORM finish_incubator_ticket_generation((g->>'id')::bigint,'completed','{"proposal":{"title":"Stale output","premise":"Stale creator premise","spec":{"runner":"momentum_v1","lookback_sessions":5,"quantile_count":2,"one_way_cost_bps":99,"borrow_bps_per_session":0}}}');
 IF (SELECT state FROM incubator_ticket_generation WHERE id=(g->>'id')::bigint)<>'cancelled' OR (SELECT count(*) FROM incubator_campaign_candidate)<>100 THEN RAISE EXCEPTION 'stale creator admitted output'; END IF;
 next_job:=claim_incubator_ticket_generation();
 IF next_job->>'model'<>'vendor/new-creator:free' THEN RAISE EXCEPTION 'creator picker did not affect next job'; END IF;
 PERFORM prepare_incubator_ticket_generation((next_job->>'id')::bigint,'{"model":"vendor/new-creator:free","max_tokens":2048}');
 PERFORM set_incubator_campaign(false,10,3,2,'vendor/new-creator:free',100);
 IF dispatch_incubator_ticket_generation((next_job->>'id')::bigint) IS DISTINCT FROM false THEN RAISE EXCEPTION 'paused creator dispatched'; END IF;
 PERFORM set_incubator_campaign(true,10,3,3,'vendor/new-creator:free',100);
 next_job:=claim_incubator_ticket_generation();
 INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
 VALUES('creator-crash-probe','ticket-creator:'||(next_job->>'id'),'vendor/new-creator:free',true,0,0,'free',clock_timestamp(),'{"source":"isolated-campaign-test","entitlement_version":"fixture-v1"}','local_research');
 g:=claim_incubator_ticket_generation();
 IF g->>'uncertain' IS DISTINCT FROM 'true' OR g->>'id' IS DISTINCT FROM next_job->>'id' THEN RAISE EXCEPTION 'capacity intent gap not recovered'; END IF;
 PERFORM finish_incubator_ticket_generation((next_job->>'id')::bigint,'indeterminate','{"reason":"interrupted_after_dispatch_no_replay"}');
 IF read_incubator_campaign()->>'enabled'<>'false' THEN RAISE EXCEPTION 'uncertain creator not paused'; END IF;
 IF NOT incubator_campaign_free_work('research:campaign-pilot-v1-1') OR NOT incubator_campaign_free_work('similarity:campaign-pilot-v1-1:0') OR incubator_campaign_free_work('ticket-creator:1') THEN RAISE EXCEPTION 'free worker purpose mapping'; END IF;
END $$;
ROLLBACK;
BEGIN;
UPDATE incubator_ticket_generation SET state='failed',detail='{"usage":{"prompt_tokens":100,"completion_tokens":40,"completion_tokens_details":{"reasoning_tokens":10}}}' WHERE id=1;
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
SELECT 'creator-usage-'||n,'ticket-creator:'||n,'vendor/paid',false,125000000,0,'paid_primary',now()-CASE WHEN n=1 THEN interval '0 hours' ELSE interval '2 days' END,'{"source":"usage-probe","entitlement_version":"test"}','local_research' FROM generate_series(1,2)n;
INSERT INTO openrouter_capacity_result VALUES('creator-usage-1','{"state":"failed"}',125000000,'{"source":"usage-probe","entitlement_version":"test"}',now(),'local_research');
DO $$ DECLARE u jsonb:=read_incubator_campaign()->'creator_usage'; BEGIN
 IF u->'lifetime'->>'calls' IS DISTINCT FROM '2' OR u->'lifetime'->>'unknown_cost_calls' IS DISTINCT FROM '1' OR (u->'lifetime'->>'known_cost_usd')::numeric IS DISTINCT FROM 0.125 OR u->'last_24h'->>'calls' IS DISTINCT FROM '1' OR u->'last_24h'->>'input_tokens' IS DISTINCT FROM '100' OR u->'last_24h'->>'output_tokens' IS DISTINCT FROM '40' OR u->'last_24h'->>'reasoning_tokens' IS DISTINCT FROM '10' THEN RAISE EXCEPTION 'creator usage accounting incorrect'; END IF;
END $$;
ROLLBACK;
BEGIN;
UPDATE openrouter_capacity_control SET history_known=true,installed_at=now()-interval '2 days',next_start=now(),policy=policy||'{"paid_enabled":false,"paid_models":[],"paid_model":null,"paid_request_limit_nanos":2000000}';
SET LOCAL ROLE incubator_runner;
DO $$ DECLARE g jsonb; req jsonb; actual jsonb; admitted jsonb; k text; c jsonb; fence jsonb; BEGIN
 PERFORM set_incubator_campaign(true,50,10,0,'vendor/selected',100);
 PERFORM claim_incubator_campaign('vendor/research:free');
 g:=claim_incubator_ticket_generation(); k:='ticket-creator:'||(g->>'id');
 req:='{"model":"vendor/selected","max_tokens":2048,"stream":false,"messages":[{"role":"user","content":"propose"}],"provider":{"max_price":{"prompt":0,"completion":0}}}';
 PERFORM prepare_incubator_ticket_generation((g->>'id')::bigint,req);
 PERFORM enqueue_openrouter_capacity(k,req,'ticket_creator');
 actual:=jsonb_set(req,'{provider,max_price}','{"prompt":1,"completion":1}');
 IF try_openrouter_capacity(k,'vendor/selected',1000000,'campaign_selection',actual||'{"response_format":{"type":"json_object"}}')->>'reason' IS DISTINCT FROM 'campaign_selection_required' THEN RAISE EXCEPTION 'changed campaign request authorized paid creator'; END IF;
 SET LOCAL ROLE incubator_chat;
 IF try_openrouter_capacity(k,'vendor/selected',1000000,'campaign_selection',actual)->>'reason' IS DISTINCT FROM 'campaign_selection_required' THEN RAISE EXCEPTION 'chat role authorized paid creator'; END IF;
 SET LOCAL ROLE incubator_runner;
 IF try_openrouter_capacity(k,'vendor/selected',2000001,'campaign_selection',actual)->>'reason' IS DISTINCT FROM 'paid_reservation_required' THEN RAISE EXCEPTION 'campaign reservation cap bypassed'; END IF;
 PERFORM enqueue_openrouter_capacity('unselected-agent',req,'research');
 IF try_openrouter_capacity('unselected-agent','vendor/selected',1000000,'campaign_selection',actual)->>'reason' IS DISTINCT FROM 'campaign_selection_required' THEN RAISE EXCEPTION 'agent impersonated campaign selection'; END IF;
 IF try_openrouter_capacity('unselected-agent','vendor/selected',1000000,'paid_primary',actual)->>'reason' IS DISTINCT FROM 'paid_model_not_enabled' THEN RAISE EXCEPTION 'automated paid execution enabled'; END IF;
 SET LOCAL ROLE mm;
 UPDATE incubator_campaign SET enabled=false;
 SET LOCAL ROLE incubator_runner;
 IF try_openrouter_capacity(k,'vendor/selected',1000000,'campaign_selection',actual)->>'reason' IS DISTINCT FROM 'campaign_selection_required' THEN RAISE EXCEPTION 'paused campaign authorized paid creator'; END IF;
 SET LOCAL ROLE mm;
 UPDATE incubator_campaign SET enabled=true,creator_model='vendor/other';
 SET LOCAL ROLE incubator_runner;
 IF try_openrouter_capacity(k,'vendor/selected',1000000,'campaign_selection',actual)->>'reason' IS DISTINCT FROM 'campaign_selection_required' THEN RAISE EXCEPTION 'wrong selected model authorized paid creator'; END IF;
 SET LOCAL ROLE mm;
 UPDATE incubator_campaign SET creator_model='vendor/selected',revision=revision+1;
 SET LOCAL ROLE incubator_runner;
 IF try_openrouter_capacity(k,'vendor/selected',1000000,'campaign_selection',actual)->>'reason' IS DISTINCT FROM 'campaign_selection_required' THEN RAISE EXCEPTION 'stale campaign revision authorized paid creator'; END IF;
 SET LOCAL ROLE mm;
 UPDATE incubator_campaign SET revision=revision-1;
 SET LOCAL ROLE incubator_runner;
 admitted:=try_openrouter_capacity(k,'vendor/selected',1000000,'campaign_selection',actual);
 IF admitted->>'status' IS DISTINCT FROM 'admitted' THEN RAISE EXCEPTION 'selected creator denied: %',admitted; END IF;
 PERFORM dispatch_incubator_ticket_generation((g->>'id')::bigint);
 fence:=read_incubator_campaign_fence();
 IF fence->>'enabled' IS DISTINCT FROM 'true' OR fence->>'revision' IS DISTINCT FROM g->>'campaign_revision' THEN RAISE EXCEPTION 'campaign cancellation fence incorrect'; END IF;
 PERFORM set_incubator_campaign(false,50,10,1,'vendor/selected',100);
 IF read_incubator_campaign_fence()->>'enabled' IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 'campaign cancellation fence missed pause'; END IF;
 PERFORM finish_openrouter_capacity(admitted->>'attempt_id','{"state":"indeterminate","cost_nanos":null}');
 PERFORM finish_incubator_ticket_generation((g->>'id')::bigint,'indeterminate','{"reason":"cancelled_by_owner"}');
 c:=read_incubator_campaign();
 IF c->>'creator_in_progress' IS DISTINCT FROM 'false' OR c->'creator_usage'->'last_24h'->>'unknown_cost_calls' IS DISTINCT FROM '1' OR read_openrouter_capacity()->'policy'->>'paid_enabled' IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 'cancellation accounting or permission changed'; END IF;
END $$;
ROLLBACK;
SELECT jsonb_build_object('probe','research-campaign','passed',true,'checks',jsonb_build_array('paused_default','bounded_limits','settings_revision','restart_identity','pinned_scope','idempotent_admission','worker_pickup','no_manual_spend','automatic_origin','pacing','backpressure','role_restrictions','duplicates','pause_fence','no_check_replay','audit_chain','continuous_intake_and_daily_cap','campaign_spec_fence','campaign_scope_fence','owner_request_fence','dataset_binding_fence','fallback_contract_fence','generated_backlog_ingestion','backlog_cap','creator_model_change_fence','creator_model_next_job','creator_intent_gap_no_replay','free_worker_routing','empty_backlog_array','creator_final_dispatch_pause_fence'));
