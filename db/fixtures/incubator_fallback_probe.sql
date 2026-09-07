BEGIN;
CREATE FUNCTION pg_temp.must_reject(command text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN EXECUTE command;
 EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',command;
END;
$$;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('fallback-parent','vendor/primary:free','momentum-brief-v1') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_fallback('fallback-parent','fallback-child','vendor/backup:free',1)$q$,'22023');
SELECT record_incubator_agent_event('fallback-parent','failed','{"reason":"invalid_report"}') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_fallback('fallback-parent','fallback-child','vendor/primary:free',1)$q$,'22023');
SELECT admit_incubator_agent_fallback('fallback-parent','fallback-child','vendor/backup:free',1) IS NOT NULL;
SELECT admit_incubator_agent_fallback('fallback-parent','fallback-child','vendor/backup:free',1) IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_fallback('fallback-parent','another-child','vendor/other:free',1)$q$,'22023');
SELECT pg_temp.must_reject($q$DELETE FROM incubator_agent_fallback$q$,'42501');
SELECT record_incubator_agent_event('fallback-child','failed','{"reason":"invalid_report","fallback_of":"fallback-parent"}') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_fallback('fallback-child','grandchild','vendor/another:free',1)$q$,'22023');
SELECT admit_incubator_agent_run('fallback-uncertain','vendor/primary:free','momentum-brief-v1') IS NOT NULL;
SELECT record_incubator_agent_event('fallback-uncertain','dispatched','{}') IS NOT NULL;
SELECT record_incubator_agent_event('fallback-uncertain','indeterminate','{}') IS NOT NULL;
SELECT pg_temp.must_reject($q$SELECT admit_incubator_agent_fallback('fallback-uncertain','unsafe-child','vendor/backup:free',1)$q$,'22023');
RESET ROLE;
SELECT pg_temp.must_reject($q$UPDATE incubator_agent_fallback SET policy_revision=2$q$,'55000');
SELECT pg_temp.must_reject($q$DELETE FROM incubator_agent_fallback$q$,'55000');
SELECT pg_temp.must_reject($q$TRUNCATE incubator_agent_fallback$q$,'55000');
DO $$ BEGIN
 IF (SELECT count(*) FROM incubator_agent_fallback)<>1 THEN RAISE EXCEPTION 'multiple fallback assignments'; END IF;
 IF read_incubator_agent_fallback('fallback-parent')->>'run_key'<>'fallback-child' THEN RAISE EXCEPTION 'lost child'; END IF;
 IF NOT (SELECT valid FROM verify_audit_event_chain()) THEN RAISE EXCEPTION 'invalid audit chain'; END IF;
END $$;
SELECT jsonb_build_object('probe','incubator-fallback','passed',true,'checks',jsonb_build_array('confirmed_failure_only','different_model','one_fallback_per_parent','no_fallback_chains','idempotent_admission','uncertain_outcome_denied','restricted_role','immutable_populated_link','audit_chain'));
ROLLBACK;
