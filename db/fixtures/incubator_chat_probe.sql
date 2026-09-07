BEGIN;
CREATE FUNCTION pg_temp.must_reject(command text,expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE command; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected THEN RETURN; END IF; RAISE; END; RAISE EXCEPTION 'expected rejection: %',command; END $$;
SELECT admit_incubator_agent_run('chat-probe','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('chat-probe','failed','{"reason":"fixture"}');
SELECT admit_incubator_agent_run('other-chat-probe','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('other-chat-probe','failed','{"reason":"fixture"}');
CREATE TEMP TABLE before_run AS SELECT read_incubator_agent_run('chat-probe') AS value;
SET LOCAL ROLE incubator_chat;
SELECT admit_incubator_chat('chat-probe','message-1',0,'Question','{"model":"vendor/model:free","stream":true,"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}');
DO $$ BEGIN
 IF admit_incubator_chat('chat-probe','message-1',0,'Question','{}') THEN RAISE EXCEPTION 'replayed dispatch'; END IF;
END $$;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_chat('chat-probe','message-1',0,'Changed','{}')$q$,'22023');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_chat('chat-probe','message-2',1,'Concurrent','{}')$q$,'55000');
-- An independent task is not held behind this pending turn.
SELECT admit_incubator_chat('other-chat-probe','message-1',0,'Independent','{"model":"vendor/model:free","stream":true,"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}');
SELECT finish_incubator_chat('chat-probe','message-1','completed','{"reply":"Answer","proposal":{"hypothesis":"Revised hypothesis","evidence_gaps":["Missing data"],"experiment":["Test the revised assumption"],"falsification_rule":"Reject on failure","limitations":["Unmeasured"]}}');
SELECT finish_incubator_chat('chat-probe','message-1','completed','{"reply":"Answer","proposal":{"hypothesis":"Revised hypothesis","evidence_gaps":["Missing data"],"experiment":["Test the revised assumption"],"falsification_rule":"Reject on failure","limitations":["Unmeasured"]}}');
SELECT pg_temp.must_reject($q$SELECT finish_incubator_chat('chat-probe','message-1','completed','{"reply":"Rewritten"}')$q$,'55000');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_chat('chat-probe','message-2',0,'Stale','{}')$q$,'55000');
SELECT apply_incubator_plan('chat-probe',1,0);
SELECT apply_incubator_plan('chat-probe',1,0);
SELECT pg_temp.must_reject($q$SELECT apply_incubator_plan('chat-probe',99,0)$q$,'55000');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_chat('chat-probe','message-2',1,'Paid','{"model":"vendor/paid","stream":true,"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}')$q$,'22023');
SELECT pg_temp.must_reject($q$DELETE FROM incubator_chat_turn$q$,'42501');
SELECT pg_temp.must_reject($q$SELECT record_incubator_agent_event('chat-probe','completed','{}')$q$,'42501');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_run('forged-run','vendor/model:free','momentum-brief-v1')$q$,'42501');
SELECT admit_incubator_chat('chat-probe','message-2',1,'Follow up','{"model":"vendor/model:free","stream":true,"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}');
SELECT finish_incubator_chat('chat-probe','message-2','indeterminate','{"reason":"fixture interrupted"}');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_chat('chat-probe','message-3',2,'Unsafe retry','{}')$q$,'55000');
RESET ROLE;
SELECT pg_temp.must_reject($q$UPDATE incubator_chat_turn SET user_text='tampered'$q$,'55000');
SELECT pg_temp.must_reject($q$DELETE FROM incubator_chat_result$q$,'55000');
SELECT pg_temp.must_reject($q$UPDATE incubator_plan_revision SET report='{}'$q$,'55000');
SELECT pg_temp.must_reject($q$TRUNCATE incubator_chat_turn CASCADE$q$,'55000');
DO $$ BEGIN
 IF read_incubator_agent_run('chat-probe') IS DISTINCT FROM (SELECT value FROM before_run) THEN RAISE EXCEPTION 'original report changed'; END IF;
 IF read_incubator_plan('chat-probe')->>'revision'<>'1' OR read_incubator_plan('chat-probe')->'revisions'->0->'report'->>'hypothesis'<>'Revised hypothesis' THEN RAISE EXCEPTION 'plan revision lost'; END IF;
 IF read_incubator_chat('chat-probe')->>'revision'<>'2' THEN RAISE EXCEPTION 'history lost'; END IF;
 IF NOT (SELECT valid FROM verify_audit_event_chain()) THEN RAISE EXCEPTION 'audit chain invalid'; END IF;
END $$;
SELECT jsonb_build_object('probe','incubator-chat','passed',true,'checks',jsonb_build_array('persistent_history','dispatch_idempotency','request_identity_binding','one_pending_turn_per_task','independent_tasks','stale_context_rejected','model_binding','result_immutable','restricted_role','populated_table_mutation_denied','unknown_outcome_blocks_resend','original_report_unchanged','plan_revision_applied_once','stale_plan_revision_rejected','plan_revision_append_only','audit_chain'));
ROLLBACK;
