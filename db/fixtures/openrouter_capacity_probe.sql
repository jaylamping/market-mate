-- Isolated, rollback-only mechanism probe. Run as migration owner after 0068.
-- No outbound network calls. Restricted roles exercise SECURITY DEFINER entrypoints.
BEGIN;
CREATE FUNCTION pg_temp.capacity_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'capacity assertion: %',message; END IF;
END $$;
SELECT pg_temp.capacity_assert(to_regprocedure('try_openrouter_capacity(text,text,bigint,text,jsonb)') IS NOT NULL,'shared admission exists');
-- Dedicated acceptance database must contain no earlier capacity dispatches.
SELECT pg_temp.capacity_assert(NOT EXISTS(SELECT 1 FROM openrouter_capacity_attempt),'isolated empty ledger required');
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.capacity_assert(read_openrouter_capacity()->'policy'->>'paid_enabled'='false','spending initially off');
SELECT pg_temp.capacity_assert(save_openrouter_capacity(0,'{"mode":"burst","burst_remaining":100}')->>'status'='saved','revision save');
SELECT pg_temp.capacity_assert(save_openrouter_capacity(0,'{}')->>'status'='conflict','stale revision rejected');
SELECT enqueue_openrouter_capacity('probe:first','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:first','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'status'='admitted','first dispatch admitted');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:first','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'status'='already_dispatched','no duplicate replay');
DO $$ BEGIN
 BEGIN
  PERFORM enqueue_openrouter_capacity('probe:first','{"model":"different/model:free"}','research');
  RAISE EXCEPTION 'accepted changed request';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM='accepted changed request' THEN RAISE; END IF; END;
END $$;
SELECT enqueue_openrouter_capacity('probe:second','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:second','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'status'='waiting','starts cannot catch up');
SELECT pg_temp.capacity_assert(NOT openrouter_capacity_ready('probe:second'),'waiting survives poll');
SELECT pg_temp.capacity_assert(cancel_openrouter_capacity('probe:second')->>'status'='cancelled','pending cancellation');
RESET ROLE;
SELECT finish_openrouter_capacity(attempt_id,'{"state":"failed","http_status":429,"limit_scope":"minute","retry_ms":60000}') FROM openrouter_capacity_attempt WHERE key='probe:first';
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'free_used')::integer=1,'429 consumes allocation');
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'in_flight')::integer=0,'terminal failure releases concurrency');
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'free_cooldown_until')::timestamptz>clock_timestamp(),'minute cooldown shared by free routes');
-- Grant mutation only inside rollback fixture, proving trigger mechanism beyond ACL.
GRANT SELECT,UPDATE,DELETE,TRUNCATE ON openrouter_capacity_attempt,openrouter_capacity_result TO incubator_runner,incubator_chat;
SET LOCAL ROLE incubator_runner;
DO $$ BEGIN
 BEGIN UPDATE openrouter_capacity_attempt SET model='tamper' WHERE key='probe:first'; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 BEGIN DELETE FROM openrouter_capacity_result; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 BEGIN TRUNCATE openrouter_capacity_result; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END $$;
SET LOCAL ROLE incubator_chat;
DO $$ BEGIN
 BEGIN DELETE FROM openrouter_capacity_attempt WHERE key='probe:first'; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 BEGIN UPDATE openrouter_capacity_result SET outcome='{}'; RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
END $$;
RESET ROLE;
SELECT pg_temp.capacity_assert((SELECT model='probe/model:free' FROM openrouter_capacity_attempt WHERE key='probe:first'),'attempt unchanged');
UPDATE openrouter_capacity_control SET next_start=clock_timestamp(),cooldown_until=NULL,free_cooldown_until=NULL;
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
SELECT 'minute:'||n,'minute:'||n,'probe/model:free',true,0,1,'fixture',clock_timestamp()-interval '10 seconds','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM generate_series(1,19) n;
INSERT INTO openrouter_capacity_result(attempt_id,outcome,receipt_time,source_lineage,record_environment) SELECT attempt_id,'{"state":"completed"}',clock_timestamp(),'{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM openrouter_capacity_attempt WHERE trigger='fixture';
SET LOCAL ROLE incubator_runner;
SELECT enqueue_openrouter_capacity('probe:minute','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:minute','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'reason'='minute_capacity','21st minute blocked');
SELECT save_openrouter_capacity(1,'{"paid_enabled":true,"paid_model":"probe/paid","paid_models":["probe/paid"],"paid_model_open_weights_confirmed":true,"paid_daily_limit_nanos":2000000}');
SELECT enqueue_openrouter_capacity('probe:paid','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:paid','probe/paid',2000000,'daily_free_exhausted','{"model":"probe/paid","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'reason'='free_capacity_available','minute pressure cannot buy fallback');
RESET ROLE;
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
SELECT 'daily:'||n,'daily:'||n,'probe/model:free',true,0,2,'fixture_daily',clock_timestamp()-interval '1 hour','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM generate_series(1,980) n;
INSERT INTO openrouter_capacity_result(attempt_id,outcome,receipt_time,source_lineage,record_environment) SELECT attempt_id,'{"state":"completed"}',clock_timestamp(),'{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM openrouter_capacity_attempt WHERE trigger='fixture_daily';
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:minute','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'reason'='daily_free_exhausted','1001st daily blocked');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:paid','probe/paid',2000000,'daily_free_exhausted','{"model":"probe/paid","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'status'='admitted','daily exhaustion permits selected budgeted model');
RESET ROLE;
SELECT finish_openrouter_capacity(attempt_id,'{"state":"indeterminate","cost_nanos":null}') FROM openrouter_capacity_attempt WHERE key='probe:paid';
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'paid_reserved_nanos')::bigint=2000000,'unknown cost stays reserved');
UPDATE openrouter_capacity_control SET next_start=clock_timestamp();
SET LOCAL ROLE incubator_runner;
SELECT enqueue_openrouter_capacity('probe:paid2','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:paid2','probe/paid',2000000,'daily_free_exhausted','{"model":"probe/paid","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'reason'='paid_budget','unresolved reservation cannot be spent twice');
RESET ROLE;
SELECT pg_temp.capacity_assert((SELECT count(*) FROM openrouter_capacity_attempt WHERE NOT is_free)=1,'exact paid outbound commitments');
-- Explicit owner-selected paid work is not automated fallback spending.
SET LOCAL ROLE incubator_runner;
SELECT save_openrouter_capacity(2,'{"paid_enabled":false}');
SELECT enqueue_openrouter_capacity('probe:manual','{"model":"owner/unlisted","max_tokens":2048}','manual');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:manual','owner/unlisted',0,'manual','{"model":"owner/unlisted","max_tokens":2048}')->>'status'='admitted','manual paid bypasses disabled automatic lane, list, pacing, and budget');
SELECT enqueue_openrouter_capacity('probe:spoof','{"model":"owner/unlisted","max_tokens":2048}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('probe:spoof','owner/unlisted',0,'manual','{"model":"owner/unlisted","max_tokens":2048}')->>'reason'='manual_authorization_required','automated purpose cannot claim manual bypass');
RESET ROLE;
SELECT finish_openrouter_capacity(attempt_id,'{"state":"completed","cost_nanos":9000000}') FROM openrouter_capacity_attempt WHERE key='probe:manual';
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'manual_paid_used_nanos')::bigint=9000000,'manual actual cost visible');
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'paid_used_nanos')::bigint=0,'manual spend excluded from automated dollars');
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'paid_attempts')::bigint=1,'manual attempt excluded from automated cap');
SELECT assert_all_evidence_table_conventions();
ROLLBACK;

-- Independent transaction keeps timing probes deterministic without sleeping.
BEGIN;
CREATE FUNCTION pg_temp.capacity_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'capacity assertion: %',message; END IF;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT save_openrouter_capacity(0,'{"paid_enabled":true,"paid_model":"probe/paid","paid_models":["probe/paid","probe/paid2"],"paid_model_open_weights_confirmed":true,"paid_daily_limit_nanos":10000000,"paid_finish_on_429":true,"paid_max_fallback_attempts":2,"paid_role_models":{"research":"probe/paid","setup":null,"experiment":"probe/paid2","default":null}}');
SELECT enqueue_openrouter_capacity('finish-parent','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('finish-parent','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'status'='admitted','free parent admitted');
RESET ROLE;
SELECT finish_openrouter_capacity(attempt_id,'{"state":"failed","http_status":429,"limit_scope":"minute","retry_ms":60000}') FROM openrouter_capacity_attempt WHERE key='finish-parent';
SET LOCAL ROLE incubator_runner;
SELECT enqueue_openrouter_capacity('finish-parent:paid:1','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT enqueue_openrouter_capacity('finish-parent:paid:2','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('finish-parent:paid:2','probe/paid2',2000000,'finish_after_429','{"model":"probe/paid2","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'reason'='paid_finish_previous_required','second child requires preceding definite failure');
SAVEPOINT before_child;
SELECT pg_temp.capacity_assert(try_openrouter_capacity('finish-parent:paid:1','probe/paid',2000000,'finish_after_429','{"model":"probe/paid","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'status'='admitted','opt-in paid child can finish free minute 429');
RESET ROLE;
SELECT pg_temp.capacity_assert((SELECT parent_key='finish-parent' AND fallback_ordinal=1 FROM openrouter_capacity_attempt WHERE key='finish-parent:paid:1'),'parent lineage persisted');
SELECT finish_openrouter_capacity(attempt_id,'{"state":"indeterminate","cost_nanos":null}') FROM openrouter_capacity_attempt WHERE key='finish-parent:paid:1';
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.capacity_assert(try_openrouter_capacity('finish-parent:paid:2','probe/paid2',2000000,'finish_after_429','{"model":"probe/paid2","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'reason'='paid_finish_previous_required','ambiguous first child cannot create second');
ROLLBACK TO before_child;
RESET ROLE;
-- Fixture-only old first-child commitment permits testing second admission without a sleep.
INSERT INTO openrouter_capacity_attempt(attempt_id,key,parent_key,fallback_ordinal,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
VALUES('prior-child','finish-parent:paid:1','finish-parent',1,'probe/paid',false,2000000,1,'finish_after_429',clock_timestamp()-interval '13 seconds','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research');
SELECT finish_openrouter_capacity('prior-child','{"state":"failed","http_status":429,"limit_scope":"provider","cost_nanos":0}');
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.capacity_assert(try_openrouter_capacity('finish-parent:paid:2','probe/paid2',2000000,'finish_after_429','{"model":"probe/paid2","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'status'='admitted','second configured child follows definite rejected first');
SELECT enqueue_openrouter_capacity('primary','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('primary','probe/paid2',2000000,'paid_primary','{"model":"probe/paid2","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'reason'='free_preference_enabled','paid primary blocked by free preference');
SELECT save_openrouter_capacity(1,'{"prefer_free_models":false,"paid_model_open_weights_confirmed":false}');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('primary','probe/paid2',2000000,'paid_primary','{"model":"probe/paid2","max_tokens":2048,"provider":{"max_price":{"prompt":1,"completion":1}}}')->>'reason'='paid_pacing','paid primary enabled while still rate limited');
RESET ROLE;
ROLLBACK;

BEGIN;
CREATE FUNCTION pg_temp.capacity_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'capacity assertion: %',message; END IF;
END $$;
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment)
SELECT 'expired:'||n,'expired:'||n,'probe/paid',false,2000000,0,'paid_primary',clock_timestamp()-interval '151 seconds','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research' FROM generate_series(1,4) n;
SET LOCAL ROLE incubator_runner;
SELECT enqueue_openrouter_capacity('after-expired','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('after-expired','probe/model:free',0,'free','{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'status'='admitted','dead transports release concurrency after 150 seconds');
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'paid_reserved_nanos')::bigint=8000000,'expired transports retain every spending reservation');
RESET ROLE;
SELECT pg_temp.capacity_assert((SELECT count(*) FROM openrouter_capacity_result WHERE outcome->>'state'='indeterminate')=4,'expired transports recorded indeterminate');
SET LOCAL ROLE incubator_runner;
SELECT enqueue_openrouter_capacity('content-fingerprint','{"model":"probe/model:free","messages":[{"role":"user","content":"fixture prompt"}],"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','research');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('content-fingerprint','probe/model:free',0,'free','{"model":"probe/model:free","messages":[{"role":"user","content":"substituted prompt"}],"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'reason'='capacity_payload_changed','message substitution blocked');
RESET ROLE;
SELECT pg_temp.capacity_assert((SELECT NOT request ? 'messages' AND request ? 'messages_sha256' AND request::text NOT LIKE '%fixture prompt%' FROM openrouter_capacity_queue WHERE key='content-fingerprint'),'queue stores content fingerprints only');

ROLLBACK;

BEGIN;
CREATE FUNCTION pg_temp.capacity_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'capacity assertion: %',message; END IF;
END $$;
INSERT INTO openrouter_capacity_queue(key,request,fingerprint,purpose,eligible_at) VALUES('refinement:1234','{}','fixture','refinement',clock_timestamp()+interval '60 seconds');
SELECT pg_temp.capacity_assert(openrouter_work_ready('refinement:123'),'numeric prefix does not block a different job');
SELECT pg_temp.capacity_assert(NOT openrouter_work_ready('refinement:1234'),'deferred job excluded from worker polling');
INSERT INTO openrouter_capacity_queue(key,request,fingerprint,purpose,state) VALUES('evaluation:77:1','{}','fixture','evaluation','dispatched');
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment) VALUES('orphan-ui','evaluation:77:1','probe/model:free',true,0,0,'free',clock_timestamp()-interval '151 seconds','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research');
SELECT pg_temp.capacity_assert(read_openrouter_work_wait('evaluation:77:')->>'reason'='dispatch_outcome_unknown','orphan commitment visible as unknown without replay');
SELECT pg_temp.capacity_assert(NOT openrouter_work_ready('evaluation:77:'),'orphan job cannot monopolize polling');
ROLLBACK;

BEGIN;
CREATE FUNCTION pg_temp.capacity_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'capacity assertion: %',message; END IF;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT enqueue_openrouter_capacity('queued-refresh','{"model":"old/free:free","messages":[{"role":"user","content":"yesterday"}],"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','experiment');
SELECT enqueue_openrouter_capacity('queued-refresh','{"model":"new/free:free","messages":[{"role":"user","content":"today"}],"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}','experiment');
SELECT pg_temp.capacity_assert(try_openrouter_capacity('queued-refresh','new/free:free',0,'free','{"model":"new/free:free","messages":[{"role":"user","content":"today"}],"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')->>'status'='admitted','unsent queued work refreshes model and date before admission');
RESET ROLE;
SELECT pg_temp.capacity_assert((SELECT count(*) FROM openrouter_capacity_attempt)=1,'refresh never mints a second commitment');
ROLLBACK;

BEGIN;
CREATE FUNCTION pg_temp.capacity_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'capacity assertion: %',message; END IF;
END $$;
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment) VALUES('older-success','older-success','probe/model:free',true,0,0,'free',clock_timestamp()-interval '10 seconds','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research');
UPDATE openrouter_capacity_control SET daily_gate_until=clock_timestamp()+interval '30 minutes';
INSERT INTO openrouter_capacity_model(model,first_failure,last_failure,cooldown_until) VALUES('probe/model:free',clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '60 seconds');
SELECT finish_openrouter_capacity('older-success','{"state":"completed","cost_nanos":0}');
SELECT pg_temp.capacity_assert((read_openrouter_capacity()->>'daily_limited')::boolean,'older success cannot clear later daily rejection');
SELECT pg_temp.capacity_assert((SELECT cooldown_until>clock_timestamp() FROM openrouter_capacity_model WHERE model='probe/model:free'),'older success cannot clear later provider rejection');
ROLLBACK;

BEGIN;
DO $$ DECLARE kind text; run text; id_value bigint; sequence_value integer; key_value text;
 request_value jsonb:='{"model":"probe/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}';
BEGIN
 FOREACH kind IN ARRAY ARRAY['evaluation','refinement','experiment'] LOOP
  run:='capacity-recovery-'||kind;
  PERFORM admit_incubator_agent_run(run,'probe/model:free','momentum-brief-v1');
  PERFORM record_incubator_agent_event(run,'dispatched','{}');
  PERFORM record_incubator_agent_event(run,'completed','{"report":{"hypothesis":"Test recovery","evidence_gaps":["Data"],"experiment":["Compare costs"],"falsification_rule":"Reject failure","limitations":["Fixture"]}}');
  PERFORM queue_incubator_evaluations();
  SELECT id INTO STRICT id_value FROM incubator_evaluation WHERE run_key=run;
  sequence_value:=begin_incubator_evaluation_step(id_value,'evaluation',request_value);
  IF kind='evaluation' THEN key_value:='evaluation:'||id_value||':'||sequence_value;
  ELSIF kind='refinement' THEN
   PERFORM finish_incubator_evaluation_step(id_value,sequence_value,'completed','{"decision":"refine","reason":"Refine method"}');
   PERFORM begin_incubator_refinement(id_value,request_value);
   key_value:='refinement:'||id_value;
  ELSE
   PERFORM finish_incubator_evaluation_step(id_value,sequence_value,'completed','{"decision":"advance","reason":"Ready","question":null}');
   PERFORM record_incubator_experiment_event(id_value,'preparing',jsonb_build_object('request',request_value));
   key_value:='experiment:'||id_value||':1:setup';
  END IF;
  INSERT INTO openrouter_capacity_queue(key,request,fingerprint,purpose,state) VALUES(key_value,'{}','fixture',kind,'dispatched');
  INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,receipt_time,source_lineage,record_environment) VALUES(key_value,key_value,'probe/model:free',true,0,0,'free',clock_timestamp()-interval '151 seconds','{"source":"openrouter_capacity","entitlement_version":"local-research-v1"}','local_research');
  IF kind='evaluation' THEN
   IF next_incubator_evaluation() IS DISTINCT FROM id_value THEN RAISE EXCEPTION 'evaluation recovery blocked'; END IF;
   PERFORM finish_incubator_evaluation_step(id_value,sequence_value,'indeterminate','{"reason":"restart_no_retry"}');
  ELSIF kind='refinement' THEN
   IF next_incubator_refinement() IS DISTINCT FROM id_value THEN RAISE EXCEPTION 'refinement recovery blocked'; END IF;
   PERFORM finish_incubator_refinement(id_value,'indeterminate','{"reason":"restart_no_retry"}');
  ELSE
   IF next_incubator_experiment() IS DISTINCT FROM id_value THEN RAISE EXCEPTION 'experiment recovery blocked'; END IF;
   PERFORM record_incubator_experiment_event(id_value,'indeterminate','{"reason":"restart_no_retry"}');
  END IF;
 END LOOP;
END $$;
ROLLBACK;
