-- Correct the in-flight join in workspace admission; retain existing receipts and queued reservations.
CREATE OR REPLACE FUNCTION admit_dispatch(key_value text,agent_value text,purpose_value text,request_value jsonb,allow_paid_value boolean,parent_value text,model_value text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE i dispatch_intent%ROWTYPE; pick jsonb; fp text; id_value text; p provider%ROWTYPE; at_time timestamptz:=clock_timestamp();
BEGIN
 PERFORM pg_advisory_xact_lock(88001,3);
 IF jsonb_typeof(request_value) IS DISTINCT FROM 'object' OR octet_length(request_value::text)>160000 THEN RAISE EXCEPTION 'invalid_dispatch_request' USING ERRCODE='22023'; END IF;
 fp:=encode(digest(request_value::text,'sha256'),'hex');
 SELECT * INTO i FROM dispatch_intent WHERE key=key_value;
 IF FOUND THEN
  IF i.fingerprint<>fp OR i.agent_id<>agent_value THEN RAISE EXCEPTION 'dispatch_key_conflict' USING ERRCODE='22023'; END IF;
  IF i.state='queued' AND i.route IS NOT NULL THEN
   RETURN jsonb_build_object('status','delegate','intent_id',i.intent_id,'route',i.route);
  END IF;
  IF i.state IN('admitted','dispatched','completed','failed','indeterminate','cancelled') THEN
   RETURN jsonb_build_object('status',i.state,'intent_id',i.intent_id,'attempt_id',i.attempt_id,'route',i.route,'reason',i.reason,'held_until',i.held_until);
  END IF;
  IF i.state='held' AND i.held_until>at_time THEN
   RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',i.held_until,'reason',i.reason);
  END IF;
 ELSE
  INSERT INTO dispatch_intent(intent_id,key,agent_id,purpose,request,fingerprint,allow_paid,parent_attempt_id)
  VALUES(gen_random_uuid()::text,key_value,agent_value,purpose_value,request_value,fp,allow_paid_value,parent_value) RETURNING * INTO i;
 END IF;
 pick:=current_agent_route(agent_value,i.allow_paid,model_value);
 IF pick->>'status'='blocked' THEN
  UPDATE dispatch_intent SET state='blocked',reason=pick->>'reason',updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','blocked','intent_id',i.intent_id,'reason',pick->>'reason','skipped',pick->'skipped');
 END IF;
 IF pick->>'status'='held' THEN
  UPDATE dispatch_intent SET state='held',held_until=(pick->>'held_until')::timestamptz,reason=coalesce(pick->'skipped'->0->>'reason','held'),updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',pick->'held_until','reason',pick->'skipped'->0->>'reason','skipped',pick->'skipped');
 END IF;
 SELECT * INTO p FROM provider WHERE id=pick->'route'->>'provider_id';
 IF p.settings->>'admission'='openrouter_capacity' THEN
  UPDATE dispatch_intent SET state='queued',route=pick->'route',reason=NULL,updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','delegate','intent_id',i.intent_id,'route',pick->'route','skipped',pick->'skipped');
 END IF;
 IF EXISTS(SELECT 1 FROM dispatch_attempt a LEFT JOIN dispatch_outcome o ON o.attempt_id=a.attempt_id WHERE a.provider_id=p.id AND o.attempt_id IS NULL AND a.receipt_time>at_time-interval '150 seconds' HAVING count(*)>=4) THEN
  UPDATE dispatch_intent SET state='held',held_until=at_time+interval '5 seconds',reason='in_flight_capacity',updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',at_time+interval '5 seconds','reason','in_flight_capacity');
 END IF;
 id_value:=gen_random_uuid()::text;
 INSERT INTO dispatch_attempt(attempt_id,intent_id,agent_id,provider_id,model_id,tier,ordinal,parent_attempt_id,request_sha256,source_lineage,receipt_time,record_environment)
 VALUES(id_value,i.intent_id,agent_value,p.id,pick->'route'->>'model_id',pick->'route'->>'tier',(pick->'route'->>'ordinal')::integer,i.parent_attempt_id,fp,'{"source":"agent_driver","entitlement_version":"local-research-v1"}',at_time,'local_research');
 UPDATE dispatch_intent SET state='admitted',route=pick->'route',attempt_id=id_value,reason=NULL,held_until=NULL,updated_at=at_time WHERE intent_id=i.intent_id;
 RETURN jsonb_build_object('status','admitted','intent_id',i.intent_id,'attempt_id',id_value,'route',pick->'route','skipped',pick->'skipped');
END $$;
