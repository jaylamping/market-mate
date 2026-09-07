BEGIN;
CREATE FUNCTION pg_temp.must_reject(command text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN EXECUTE command;
 EXCEPTION WHEN OTHERS THEN
   IF SQLSTATE=expected THEN RETURN; END IF;
   RAISE;
 END;
 RAISE EXCEPTION 'expected rejection: %',command;
END;
$$;
SET LOCAL ROLE incubator_runner;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_run('bad-input','vendor/model:free','licensed-account-data')$q$,'42501');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_run('paid','vendor/model','momentum-brief-v1')$q$,'22023');
SELECT admit_incubator_agent_run('probe-success','vendor/model:free','momentum-brief-v1') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_run('probe-success','other/model:free','momentum-brief-v1')$q$,'22023');
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_run('concurrent','vendor/model:free','momentum-brief-v1')$q$,'55000');
SELECT pg_temp.must_reject($q$INSERT INTO incubator_agent_event SELECT * FROM incubator_agent_event$q$,'42501');
SELECT pg_temp.must_reject($q$UPDATE incubator_agent_run SET config='{}'$q$,'42501');
SELECT pg_temp.must_reject($q$TRUNCATE incubator_agent_event$q$,'42501');
SELECT record_incubator_agent_event('probe-success','dispatched','{"request_sha256":"probe"}') IS NOT NULL;
SELECT record_incubator_agent_event('probe-success','completed','{"report":{"hypothesis":"Test a premise","evidence_gaps":["No data"],"experiment":["Preregister"],"falsification_rule":"Reject after costs","limitations":["Planning only"]},"usage":{"cost_usd":null}}') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT record_incubator_agent_event('probe-success','dispatched','{}')$q$,'55000');
SELECT pg_temp.must_reject($q$SELECT record_incubator_agent_event('probe-success','failed','{}')$q$,'55000');
SELECT admit_incubator_agent_run('probe-failure','vendor/model:free','momentum-brief-v1') IS NOT NULL;
SELECT record_incubator_agent_event('probe-failure','failed','{"reason":"model_not_whitelisted"}') IS NOT NULL;
SELECT admit_incubator_agent_run('probe-unknown','vendor/model:free','momentum-brief-v1') IS NOT NULL;
SELECT record_incubator_agent_event('probe-unknown','dispatched','{}') IS NOT NULL;
SELECT record_incubator_agent_event('probe-unknown','indeterminate','{"reason":"interrupted_after_dispatch_no_retry"}') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_run('after-crash','vendor/model:free','momentum-brief-v1')$q$,'55000');
SELECT pg_temp.must_reject($q$SELECT record_incubator_agent_event('probe-unknown','dispatched','{}')$q$,'55000');
RESET ROLE;
SELECT pg_temp.must_reject($q$UPDATE incubator_agent_run SET config='{}'$q$,'55000');
SELECT pg_temp.must_reject($q$DELETE FROM incubator_agent_event$q$,'55000');
SELECT pg_temp.must_reject($q$TRUNCATE incubator_agent_event$q$,'55000');
DO $$ BEGIN
 IF (SELECT count(*) FROM alpha_shot s JOIN incubator_agent_run r USING(assignment_id)) <> 2 THEN
   RAISE EXCEPTION 'success and failure must each record an Alpha Shot';
 END IF;
 IF NOT (SELECT valid FROM verify_audit_event_chain()) THEN RAISE EXCEPTION 'audit chain invalid'; END IF;
 IF (SELECT count(*) FROM incubator_agent_event WHERE run_key='probe-success')<>3 THEN RAISE EXCEPTION 'duplicate events'; END IF;
 IF read_incubator_agent_run('probe-success')->>'state' <> 'completed' THEN RAISE EXCEPTION 'bad projection'; END IF;
END $$;
SELECT jsonb_build_object('probe','incubator-agent-poc','passed',true,'runs',3,'alpha_shots',2,
 'checks',jsonb_build_array('input_denial','zero_spend_admission','run_identity','single_lane','restricted_role_writes',
 'append_only_nonempty_records','terminal_no_redispatch','uncertain_acceptance_holds_lane','success_failure_lineage','audit_chain'));
ROLLBACK;
