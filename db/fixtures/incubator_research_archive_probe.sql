BEGIN;
CREATE FUNCTION pg_temp.reject(q text, expected text DEFAULT 'P0001') RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',q;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('archive-probe','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('archive-probe','dispatched','{}');
SELECT record_incubator_agent_event('archive-probe','completed','{"report":{"hypothesis":"Test momentum","evidence_gaps":["Prices"],"experiment":["Compare after costs"],"falsification_rule":"Reject underperformance","limitations":["No results"]}}');
SELECT queue_incubator_evaluations();
DO $$ DECLARE original jsonb:=read_incubator_agent_run('archive-probe'); evaluation jsonb; id bigint:=next_incubator_evaluation(); BEGIN
 evaluation:=read_incubator_evaluation(id);
 PERFORM set_incubator_research_archived('archive-probe','archive-1',true,0);
 PERFORM set_incubator_research_archived('archive-probe','archive-1',true,0);
 IF read_incubator_agent_run('archive-probe')->>'archived' IS DISTINCT FROM 'true' OR read_incubator_agent_run('archive-probe')->>'archive_version' IS DISTINCT FROM '1' THEN RAISE EXCEPTION 'archive failed'; END IF;
 IF (read_incubator_agent_run('archive-probe')-'archived'-'archive_version') IS DISTINCT FROM (original-'archived'-'archive_version') THEN RAISE EXCEPTION 'research changed'; END IF;
 IF read_incubator_evaluation(id) IS DISTINCT FROM evaluation OR next_incubator_evaluation() IS DISTINCT FROM id THEN RAISE EXCEPTION 'archive changed work scheduling'; END IF;
 PERFORM pg_temp.reject($q$SELECT set_incubator_research_archived('archive-probe','archive-1',false,0)$q$);
 PERFORM pg_temp.reject($q$SELECT set_incubator_research_archived('archive-probe','stale',false,0)$q$);
 PERFORM set_incubator_research_archived('archive-probe','restore-1',false,1);
 -- Delayed replay must not re-archive a restored ticket.
 PERFORM set_incubator_research_archived('archive-probe','archive-1',true,0);
 IF read_incubator_agent_run('archive-probe')->>'archived' IS DISTINCT FROM 'false' OR read_incubator_agent_run('archive-probe')->>'archive_version' IS DISTINCT FROM '2' THEN RAISE EXCEPTION 'replay changed state'; END IF;
 PERFORM pg_temp.reject($q$SELECT set_incubator_research_archived('archive-probe','null',NULL,2)$q$,'23502');
END $$;
SELECT pg_temp.reject('UPDATE incubator_research_archive_event SET archived=false','42501');
RESET ROLE;
SELECT pg_temp.reject('UPDATE incubator_research_archive_event SET archived=false','55000');
SELECT pg_temp.reject('DELETE FROM incubator_research_archive_event','55000');
SELECT pg_temp.reject('TRUNCATE incubator_research_archive_event','55000');
DO $$ BEGIN
 IF (SELECT count(*) FROM incubator_research_archive_event)<>2 THEN RAISE EXCEPTION 'duplicate command'; END IF;
 IF NOT (SELECT valid FROM verify_audit_event_chain()) THEN RAISE EXCEPTION 'audit invalid'; END IF;
END $$;
SELECT jsonb_build_object('probe','incubator-research-archive','passed',true,'checks',jsonb_build_array('archive_restore','immutable_command_identity','stale_version_denied','delayed_replay_no_effect','research_preserved','evaluation_scheduling_unchanged','populated_append_only','restricted_role','audit_chain'));
ROLLBACK;
