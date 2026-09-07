BEGIN;
CREATE FUNCTION pg_temp.ensure(value boolean, label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'recovery assertion: %',label; END IF;
END $$;
UPDATE incubator_campaign SET enabled=true,backlog_limit=100,next_at=now()-interval '1 minute';
SET LOCAL ROLE incubator_runner;
DO $$ DECLARE a jsonb; original jsonb; state jsonb; child integer; BEGIN
 a:=claim_incubator_campaign('vendor/model:free');
 PERFORM begin_incubator_request_check(a->>'request_id',jsonb_build_object('title',a->'title','text',a->'text','model',a->'model'));
 PERFORM finish_incubator_request_check(a->>'request_id','{"complete":false,"matches":[],"issues":["invalid_similarity_response"],"attempts":[]}');
 PERFORM finish_incubator_campaign((a->>'ordinal')::integer);
 original:=read_incubator_request_check(a->>'request_id');
 state:=retry_incubator_campaign((a->>'ordinal')::integer,0);
 SELECT (x->>'ordinal')::integer INTO child FROM jsonb_array_elements(state->'agenda') x WHERE x->>'retry_of'=a->>'ordinal';
 PERFORM pg_temp.ensure(child IS NOT NULL,'retry links original candidate');
 PERFORM pg_temp.ensure(state->>'enabled'='true','retry does not change campaign enabled state');
 PERFORM pg_temp.ensure(read_incubator_request_check(a->>'request_id')=original,'original check unchanged');
 PERFORM pg_temp.ensure(retry_incubator_campaign((a->>'ordinal')::integer,-999)=state,'network replay returns same child');
 BEGIN PERFORM retry_incubator_campaign(child,0); RAISE EXCEPTION 'pending candidate retry accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Only failed or cancelled checks can be retried.' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
-- A recorded dispatch with no receipt must block another provider request.
INSERT INTO incubator_campaign_attempt(ordinal,request_id,campaign_revision,scope,model,state) VALUES(2,'recovery-unknown',0,'{}','vendor/model:free','blocked');
INSERT INTO openrouter_capacity_attempt(attempt_id,key,model,is_free,reserved_nanos,policy_revision,trigger,source_lineage,receipt_time,record_environment)
 VALUES('recovery-unknown-attempt','similarity:recovery-unknown:0','vendor/model:free',true,0,0,'free','{"source":"isolated-recovery-probe","entitlement_version":"fixture-v1"}',now(),'local_research');
SET LOCAL ROLE incubator_runner;
DO $$ BEGIN
 BEGIN PERFORM retry_incubator_campaign(2,0); RAISE EXCEPTION 'unknown dispatch retried';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Reconcile the uncertain provider request before retrying.' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
INSERT INTO openrouter_capacity_result VALUES('recovery-unknown-attempt','{"state":"indeterminate"}',NULL,'{"source":"isolated-recovery-probe","entitlement_version":"fixture-v1"}',now(),'local_research');
SET LOCAL ROLE incubator_runner;
DO $$ BEGIN
 BEGIN PERFORM retry_incubator_campaign(2,0); RAISE EXCEPTION 'indeterminate dispatch retried';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Reconcile the uncertain provider request before retrying.' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
-- Pre-dispatch failures must appear even without a capacity receipt.
INSERT INTO incubator_ticket_generation(campaign_revision,model,state,detail) VALUES(0,'vendor/model:free','failed','{"reason":"model_not_whitelisted","stage":"preparation"}');
UPDATE incubator_campaign SET enabled=false,note='Ticket Creator needs attention. Its recorded attempts are preserved; uncertain requests are not replayed.';
SELECT pg_temp.ensure(read_incubator_campaign()->'creator_calls'->0->>'reason'='model_not_whitelisted','pre-dispatch failure visible');
SELECT pg_temp.ensure(read_incubator_campaign()->>'note' LIKE '%model_not_whitelisted%','pause retains root cause');
SELECT pg_temp.ensure(read_incubator_campaign()->'creator_calls'->0->>'request_id' LIKE 'ticket-creator:%','creator failure linked');
SELECT pg_temp.ensure(EXISTS(SELECT 1 FROM audit_event WHERE event_type='research.campaign_retry_requested' AND payload->>'original_request_id' IS NOT NULL),'retry audit links original request');
ROLLBACK;
SELECT '{"probe":"campaign-recovery","passed":true}';
