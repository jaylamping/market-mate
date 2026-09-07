-- Archived tickets do not imply that automatic refinement is queued.
CREATE OR REPLACE FUNCTION read_incubator_evaluation(id_value bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v jsonb; a incubator_refinement%ROWTYPE; r incubator_refinement_result%ROWTYPE; used integer; reason text; BEGIN
 v:=read_incubator_evaluation_base(id_value);
 IF v IS NULL THEN RETURN NULL; END IF;
 SELECT count(*) INTO used FROM incubator_refinement WHERE run_key=v->>'run_key';
 SELECT * INTO a FROM incubator_refinement WHERE evaluation_id=id_value;
 SELECT * INTO r FROM incubator_refinement_result WHERE evaluation_id=id_value;
 v:=v||jsonb_build_object('refinement_rounds_used',used,'refinement',CASE WHEN a.evaluation_id IS NOT NULL THEN jsonb_build_object('round',a.round,'state',coalesce(r.state,'pending'),'reason',r.detail->>'reason','created_at',a.receipt_time,'finished_at',r.receipt_time) END);
 IF v->>'status'='refine' AND a.evaluation_id IS NULL AND coalesce((read_incubator_agent_run(v->>'run_key')->>'archived')::boolean,false) THEN RETURN v; END IF;
 IF v->>'status'='refine' THEN
  reason:=CASE WHEN r.evaluation_id IS NOT NULL THEN coalesce(r.detail->>'reason','Automatic refinement stopped.') WHEN used>=2 AND a.evaluation_id IS NULL THEN 'The two automatic refinement rounds have been used. Revise the plan in Chat.' END;
  IF reason IS NULL AND a.evaluation_id IS NULL AND EXISTS(
   SELECT 1 FROM incubator_refinement old JOIN incubator_evaluation_result result ON result.evaluation_id=old.evaluation_id
   WHERE old.run_key=v->>'run_key' AND old.evaluation_id<>id_value AND result.detail->>'decision'='refine'
   AND lower(regexp_replace(result.detail->>'reason','\s+',' ','g'))=lower(regexp_replace(v->'steps'->-1->'detail'->>'reason','\s+',' ','g'))
  ) THEN reason:='The evaluator repeated the same feedback after refinement. Please resolve it in Chat.'; END IF;
  IF reason IS NOT NULL THEN RETURN v||jsonb_build_object('status','needs_input','refinement_stop_reason',reason); END IF;
  RETURN v||jsonb_build_object('status','refining');
 END IF;
 RETURN v;
END $$;
