BEGIN;
CREATE FUNCTION pg_temp.reject(q text, expected text DEFAULT 'P0001') RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=expected THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'expected rejection: %',q;
END $$;
SET LOCAL ROLE incubator_runner;
SELECT admit_incubator_agent_run('refinement-probe','vendor/model:free','momentum-brief-v1');
SELECT record_incubator_agent_event('refinement-probe','dispatched','{}');
SELECT record_incubator_agent_event('refinement-probe','completed','{"report":{"hypothesis":"H","evidence_gaps":["Prices"],"experiment":["Compare"],"falsification_rule":"Reject underperformance","limitations":["No data"]}}');
SELECT queue_incubator_evaluations();
DO $$ DECLARE id bigint; request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; s integer; v jsonb; plan jsonb; r integer; BEGIN
 FOR round IN 1..3 LOOP
  id:=next_incubator_evaluation();
  s:=begin_incubator_evaluation_step(id,'evaluation',request);
  PERFORM finish_incubator_evaluation_step(id,s,'completed',jsonb_build_object('decision','refine','reason','Gap '||round));
  IF round=3 THEN
   IF read_incubator_evaluation(id)->>'status'<>'needs_input' THEN RAISE EXCEPTION 'ticket limit reset'; END IF;
   PERFORM pg_temp.reject(format('SELECT begin_incubator_refinement(%s,%L)',id,request));
   EXIT;
  END IF;
  IF read_incubator_evaluation(id)->>'status'<>'refining' OR next_incubator_refinement()<>id THEN RAISE EXCEPTION 'not queued for refinement'; END IF;
  PERFORM pg_temp.reject(format('SELECT begin_incubator_refinement(%s,%L)',id,jsonb_set(request,'{model}','"vendor/paid"')));
  IF round=1 THEN
   PERFORM set_incubator_research_archived('refinement-probe','archive-refinement',true,0);
   IF read_incubator_evaluation(id)->>'status'<>'refine' OR next_incubator_refinement() IS NOT NULL THEN RAISE EXCEPTION 'archived refinement queued'; END IF;
   PERFORM set_incubator_research_archived('refinement-probe','restore-refinement',false,1);
  END IF;
  r:=begin_incubator_refinement(id,request);
  IF r<>round THEN RAISE EXCEPTION 'incorrect durable round'; END IF;
  PERFORM pg_temp.reject(format('SELECT begin_incubator_refinement(%s,%L)',id,request));
  plan:=read_incubator_evaluation(id)->'report'||jsonb_build_object('hypothesis','Revised '||round);
  PERFORM finish_incubator_refinement(id,'completed',jsonb_build_object('reason','Changed hypothesis','report',plan));
  PERFORM finish_incubator_refinement(id,'completed',jsonb_build_object('reason','Changed hypothesis','report',plan));
  IF read_incubator_evaluation(id)->>'status'<>'superseded' THEN RAISE EXCEPTION 'old evaluation current'; END IF;
  PERFORM queue_incubator_evaluations();
  PERFORM queue_incubator_evaluations();
 END LOOP;
END $$;
SELECT pg_temp.reject('UPDATE incubator_refinement SET round=1','42501');
SELECT pg_temp.reject('DELETE FROM incubator_refinement_result','42501');
RESET ROLE;
DO $$ BEGIN
 IF (read_incubator_plan('refinement-probe')->>'revision')::int<>2 OR jsonb_array_length(read_incubator_plan('refinement-probe')->'revisions')<>2 THEN RAISE EXCEPTION 'revision history lost'; END IF;
 IF (SELECT count(*) FROM incubator_evaluation WHERE run_key='refinement-probe')<>3 THEN RAISE EXCEPTION 'duplicate evaluation'; END IF;
END $$;
SET LOCAL ROLE incubator_chat;
SELECT admit_incubator_chat('refinement-probe','owner-edit',0,'Revise the scope','{"model":"vendor/model:free","stream":true,"max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}');
SELECT finish_incubator_chat('refinement-probe','owner-edit','completed','{"reply":"Revised scope","proposal":{"hypothesis":"Owner revision","evidence_gaps":["Data"],"experiment":["Compare peers"],"falsification_rule":"Reject failure","limitations":["Assumption"]}}');
SELECT apply_incubator_plan('refinement-probe',1,2);
RESET ROLE;
DO $$ BEGIN IF read_incubator_plan('refinement-probe')->>'revision'<>'3' THEN RAISE EXCEPTION 'manual revision did not follow automatic revisions'; END IF; END $$;
SET LOCAL ROLE incubator_runner;
SELECT queue_incubator_evaluations();
DO $$ DECLARE id bigint; s integer; request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; BEGIN
 id:=next_incubator_evaluation(); s:=begin_incubator_evaluation_step(id,'evaluation',request);
 PERFORM finish_incubator_evaluation_step(id,s,'completed','{"decision":"refine","reason":"New issue"}');
 IF read_incubator_evaluation(id)->>'status'<>'needs_input' THEN RAISE EXCEPTION 'manual edit reset automatic budget'; END IF;
END $$;
RESET ROLE;
DO $$ DECLARE key text; id bigint; s integer; request jsonb:='{"model":"vendor/model:free","max_tokens":2048,"provider":{"max_price":{"prompt":0,"completion":0}}}'; report jsonb:='{"hypothesis":"H","evidence_gaps":["Unknown"],"experiment":["Compare"],"falsification_rule":"Reject failure","limitations":["Assumption"]}'; BEGIN
 FOREACH key IN ARRAY ARRAY['no-progress','blocked','interrupted','repeated','concurrent'] LOOP
  PERFORM admit_incubator_agent_run(key,'vendor/model:free','momentum-brief-v1');
  PERFORM record_incubator_agent_event(key,'dispatched','{}');
  PERFORM record_incubator_agent_event(key,'completed',jsonb_build_object('report',report));
  PERFORM queue_incubator_evaluations();
  SELECT e.id INTO id FROM incubator_evaluation e WHERE e.run_key=key;
  s:=begin_incubator_evaluation_step(id,'evaluation',request);
  PERFORM finish_incubator_evaluation_step(id,s,'completed','{"decision":"refine","reason":"Missing method"}');
  PERFORM begin_incubator_refinement(id,request);
  IF key='no-progress' THEN PERFORM finish_incubator_refinement(id,'completed',jsonb_build_object('reason','Same report','report',report));
  ELSIF key='blocked' THEN PERFORM finish_incubator_refinement(id,'blocked','{"reason":"Need external evidence"}');
  ELSIF key='interrupted' THEN PERFORM finish_incubator_refinement(id,'indeterminate','{"reason":"Interrupted; no retry"}');
  ELSIF key='concurrent' THEN
   PERFORM admit_incubator_chat(key,'edit-during-refinement',0,'Owner revision',request||'{"stream":true}'::jsonb);
   PERFORM finish_incubator_chat(key,'edit-during-refinement','completed',jsonb_build_object('reply','Owner change','proposal',report||'{"hypothesis":"Owner wins"}'::jsonb));
   PERFORM apply_incubator_plan(key,1,0);
   PERFORM finish_incubator_refinement(id,'completed',jsonb_build_object('reason','Late result','report',report||'{"hypothesis":"Late model"}'::jsonb));
   IF read_incubator_plan(key)->'revisions'->-1->'report'->>'hypothesis'<>'Owner wins' OR (SELECT state FROM incubator_refinement_result WHERE evaluation_id=id)<>'superseded' THEN RAISE EXCEPTION 'late result overwrote owner revision'; END IF;
   CONTINUE;
  ELSE
   PERFORM finish_incubator_refinement(id,'completed',jsonb_build_object('reason','Changed','report',report||'{"hypothesis":"Revised"}'::jsonb));
   PERFORM queue_incubator_evaluations();
   SELECT e.id INTO id FROM incubator_evaluation e WHERE e.run_key=key AND revision=1;
   s:=begin_incubator_evaluation_step(id,'evaluation',request);
   PERFORM finish_incubator_evaluation_step(id,s,'completed','{"decision":"refine","reason":"Missing method"}');
  END IF;
  IF read_incubator_evaluation(id)->>'status'<>'needs_input' THEN RAISE EXCEPTION 'stop condition failed: %',key; END IF;
  PERFORM pg_temp.reject(format('SELECT begin_incubator_refinement(%s,%L)',id,request));
 END LOOP;
END $$;
SELECT '{"probe":"incubator-refinement","passed":true,"checks":["two_round_ticket_limit","automatic_revision_and_reevaluation","duplicate_dispatch_denied","idempotent_result","paid_model_denied","append_only_nonempty","preserved_revision_history","manual_revision_preserves_budget","unchanged_report_stops","external_data_blocker_stops","interrupted_attempt_not_retried","repeated_feedback_stops","owner_revision_wins_dispatch_race","archived_ticket_not_queued"]}';
ROLLBACK;
