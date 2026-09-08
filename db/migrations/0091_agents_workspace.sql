-- Explicit model identities and shared routing policy. Catalog discovery grants no authority.
CREATE TABLE model_policy (
 id text PRIMARY KEY CHECK(id ~ '^[a-zA-Z0-9._/:~-]+$' AND length(id)<=256),
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 120),
 offerings jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(offerings)='array'),
 revision bigint NOT NULL DEFAULT 0
);
CREATE TABLE model_fallback_policy (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 models jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(models)='array'),
 revision bigint NOT NULL DEFAULT 0
);
INSERT INTO model_fallback_policy DEFAULT VALUES;
INSERT INTO schema_object(table_name,kind) VALUES('model_policy','control'),('model_fallback_policy','control');
ALTER TABLE config_revision DROP CONSTRAINT config_revision_entity_check;
ALTER TABLE config_revision ADD CHECK(entity IN('provider','agent','model','fallback'));
REVOKE ALL ON model_policy,model_fallback_policy FROM PUBLIC,agent_driver,incubator_runner,incubator_chat;

CREATE FUNCTION read_model_workspace() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('models',(SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY name),'[]') FROM model_policy m),
 'fallbacks',(SELECT jsonb_build_object('models',models,'revision',revision) FROM model_fallback_policy))
$$;
CREATE FUNCTION save_model_policy(id_value text,expected bigint,patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE m model_policy%ROWTYPE; o jsonb; BEGIN
 PERFORM pg_advisory_xact_lock(88001,3);
 SELECT * INTO m FROM model_policy WHERE id=id_value;
 IF expected IS DISTINCT FROM coalesce(m.revision,0) THEN RETURN jsonb_build_object('status','conflict'); END IF;
 IF jsonb_typeof(patch) IS DISTINCT FROM 'object' OR EXISTS(SELECT FROM jsonb_object_keys(patch) k WHERE k NOT IN('name','offerings'))
 OR jsonb_typeof(patch->'offerings') IS DISTINCT FROM 'array' OR jsonb_array_length(patch->'offerings')>48 THEN RAISE EXCEPTION 'invalid_model_policy' USING ERRCODE='22023'; END IF;
 FOR o IN SELECT * FROM jsonb_array_elements(patch->'offerings') LOOP
  IF jsonb_typeof(o) IS DISTINCT FROM 'object' OR EXISTS(SELECT FROM jsonb_object_keys(o) k WHERE k NOT IN('provider_id','model_id','enabled','priority','weight','requests_per_day','paid_daily_cap'))
   OR NOT EXISTS(SELECT FROM provider WHERE id=o->>'provider_id' AND kind<>'catalog_only')
   OR (o->>'model_id') IS NULL OR (o->>'model_id') !~ '^[a-zA-Z0-9._/:~-]+$' OR length(o->>'model_id')>256
   OR jsonb_typeof(o->'enabled') IS DISTINCT FROM 'boolean'
   OR coalesce((o->>'priority')::integer,0) NOT BETWEEN 1 AND 1000
   OR coalesce((o->>'weight')::integer,0) NOT BETWEEN 1 AND 100
   OR (o->>'requests_per_day')::integer<1
   OR coalesce((o->>'paid_daily_cap')::numeric,0)<>0
   OR ((o->>'enabled')::boolean AND EXISTS(SELECT FROM provider WHERE id=o->>'provider_id' AND kind='paid')) THEN RAISE EXCEPTION 'invalid_model_offering' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM jsonb_array_elements(patch->'offerings') o GROUP BY o->>'provider_id',o->>'model_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'duplicate_model_offering' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT FROM model_policy p CROSS JOIN LATERAL jsonb_array_elements(p.offerings) prior
  CROSS JOIN LATERAL jsonb_array_elements(patch->'offerings') incoming WHERE p.id<>id_value AND prior->>'provider_id'=incoming->>'provider_id' AND prior->>'model_id'=incoming->>'model_id') THEN RAISE EXCEPTION 'offering_already_mapped' USING ERRCODE='22023'; END IF;
 INSERT INTO model_policy(id,name,offerings,revision) VALUES(id_value,patch->>'name',patch->'offerings',expected+1)
 ON CONFLICT(id) DO UPDATE SET name=excluded.name,offerings=excluded.offerings,revision=excluded.revision;
 INSERT INTO config_revision(entity,entity_id,revision,source,diff) VALUES('model',id_value,expected+1,'ui',patch);
 RETURN jsonb_build_object('status','saved','revision',expected+1);
END $$;
CREATE FUNCTION save_model_fallbacks(expected bigint,models_value jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(88001,3);
 IF expected IS DISTINCT FROM (SELECT revision FROM model_fallback_policy) THEN RETURN jsonb_build_object('status','conflict'); END IF;
 IF jsonb_typeof(models_value) IS DISTINCT FROM 'array' OR jsonb_array_length(models_value)>16
 OR EXISTS(SELECT FROM jsonb_array_elements_text(models_value) id WHERE NOT EXISTS(SELECT FROM model_policy WHERE model_policy.id=id)) THEN RAISE EXCEPTION 'invalid_fallback_models' USING ERRCODE='22023'; END IF;
 UPDATE model_fallback_policy SET models=models_value,revision=revision+1;
 INSERT INTO config_revision(entity,entity_id,revision,source,diff) VALUES('fallback','global',expected+1,'ui',jsonb_build_object('models',models_value));
 RETURN jsonb_build_object('status','saved','revision',expected+1);
END $$;

CREATE FUNCTION workspace_model_routes(agent_value text) RETURNS TABLE(tier text,ordinal integer,provider_id text,model_id text,share_pct integer,enabled boolean,priority integer,weight integer,requests_per_day integer,paid_daily_cap numeric,model_rank bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 WITH selected AS (
 SELECT value AS id,min(position) AS rank FROM agent a CROSS JOIN LATERAL jsonb_array_elements_text(
  coalesce(a.spec->'model_order','[]') || CASE WHEN a.spec->>'use_global_fallbacks'='true' THEN (SELECT models FROM model_fallback_policy) ELSE '[]'::jsonb END
 ) WITH ORDINALITY x(value,position) WHERE a.id=agent_value AND a.spec ? 'model_order' GROUP BY value
 ), configured AS (
 SELECT p.kind AS tier,(o.position-1)::integer AS ordinal,o.value->>'provider_id' AS provider_id,o.value->>'model_id' AS model_id,100 AS share_pct,
 (o.value->>'enabled')::boolean AS enabled,(o.value->>'priority')::integer AS priority,(o.value->>'weight')::integer AS weight,
 (o.value->>'requests_per_day')::integer AS requests_per_day,(o.value->>'paid_daily_cap')::numeric AS paid_daily_cap,s.rank AS model_rank
 FROM selected s JOIN model_policy m ON m.id=s.id CROSS JOIN LATERAL jsonb_array_elements(m.offerings) WITH ORDINALITY o(value,position) JOIN provider p ON p.id=o.value->>'provider_id'
 ) SELECT * FROM configured UNION ALL
 SELECT r.tier,r.ordinal,r.provider_id,r.model_id,r.share_pct,coalesce((o.value->>'enabled')::boolean,true),coalesce((o.value->>'priority')::integer,r.ordinal+1),coalesce((o.value->>'weight')::integer,100),
 (o.value->>'requests_per_day')::integer,(o.value->>'paid_daily_cap')::numeric,array_position(ARRAY['subscription','free','paid'],r.tier)::bigint
 FROM agent_route r JOIN agent a ON a.id=r.agent_id LEFT JOIN model_policy m ON EXISTS(SELECT FROM jsonb_array_elements(m.offerings) x WHERE x->>'provider_id'=r.provider_id AND x->>'model_id'=r.model_id)
 LEFT JOIN LATERAL jsonb_array_elements(m.offerings) o(value) ON o.value->>'provider_id'=r.provider_id AND o.value->>'model_id'=r.model_id
 WHERE r.agent_id=agent_value AND NOT a.spec ? 'model_order'
$$;
CREATE OR REPLACE FUNCTION current_agent_route(agent_value text,allow_paid_value boolean,model_filter text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a agent%ROWTYPE; r record; e jsonb; skipped jsonb:='[]'; next_at timestamptz; reason_value text; daily_count bigint;
BEGIN
 SELECT * INTO a FROM agent WHERE id=agent_value;
 IF NOT FOUND THEN RETURN jsonb_build_object('status','blocked','reason','unknown_agent'); END IF;
 IF NOT a.enabled THEN RETURN jsonb_build_object('status','blocked','reason','agent_disabled'); END IF;
 FOR r IN SELECT x.* FROM workspace_model_routes(agent_value) x WHERE model_filter IS NULL OR x.model_id=model_filter
 ORDER BY x.model_rank,x.priority,
  (SELECT count(*)::numeric/x.weight FROM dispatch_attempt d WHERE d.provider_id=x.provider_id AND d.model_id=x.model_id AND d.receipt_time>clock_timestamp()-interval '5 hours'),x.ordinal LOOP
  reason_value:=NULL;
  IF NOT r.enabled THEN reason_value:='model_provider_disabled';
  ELSIF r.tier='paid' AND NOT allow_paid_value THEN reason_value:='paid_not_allowed';
  ELSE
   SELECT (SELECT count(*) FROM dispatch_attempt d
    WHERE d.provider_id=r.provider_id AND d.model_id=r.model_id AND d.receipt_time>clock_timestamp()-interval '24 hours')
    + (SELECT count(*) FROM dispatch_intent i WHERE i.state='queued' AND i.attempt_id IS NULL
       AND i.route->>'provider_id'=r.provider_id AND i.route->>'model_id'=r.model_id)
    INTO daily_count;
   IF r.requests_per_day IS NOT NULL AND daily_count>=r.requests_per_day THEN reason_value:='model_daily_allocation'; END IF;
   -- New model policies cannot authorize paid calls until admission can reserve their maximum cost.
   IF r.tier='paid' AND a.spec ? 'model_order' THEN reason_value:='model_paid_limit'; END IF;
  END IF;
  IF reason_value IS NULL THEN
   e:=provider_route_eligibility(r.provider_id,agent_value,r.share_pct,a.hold_at_pct);
   IF (e->>'eligible')::boolean THEN RETURN jsonb_build_object('status','eligible','route',jsonb_build_object('provider_id',r.provider_id,'model_id',r.model_id,'tier',r.tier,'ordinal',r.ordinal),'skipped',skipped); END IF;
   reason_value:=e->>'reason'; next_at:=least(next_at,(e->>'next_eligible_at')::timestamptz);
  END IF;
  skipped:=skipped||jsonb_build_object('provider_id',r.provider_id,'model_id',r.model_id,'tier',r.tier,'ordinal',r.ordinal,'reason',reason_value);
 END LOOP;
 IF jsonb_array_length(skipped)=0 THEN RETURN jsonb_build_object('status','blocked','reason','no_routes','skipped',skipped); END IF;
 RETURN jsonb_build_object('status','held','held_until',coalesce(next_at,clock_timestamp()+interval '5 minutes'),'skipped',skipped);
END $$;
CREATE FUNCTION read_model_requests(model_value text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.receipt_time DESC),'[]') FROM (
 SELECT d.attempt_id,d.intent_id,d.agent_id,d.provider_id,d.model_id,d.parent_attempt_id,d.receipt_time,coalesce(o.state,i.state) AS state,o.cost_nanos,o.http_status,o.receipt_time AS finished_at
 FROM dispatch_attempt d JOIN dispatch_intent i USING(intent_id) LEFT JOIN dispatch_outcome o ON o.attempt_id=d.attempt_id
 WHERE d.model_id=model_value OR EXISTS(SELECT FROM model_policy m CROSS JOIN LATERAL jsonb_array_elements(m.offerings) x WHERE m.id=model_value AND x->>'model_id'=d.model_id AND x->>'provider_id'=d.provider_id)
 ORDER BY d.receipt_time DESC LIMIT 200) t
$$;
REVOKE ALL ON FUNCTION read_model_workspace(),save_model_policy(text,bigint,jsonb),save_model_fallbacks(bigint,jsonb),workspace_model_routes(text),read_model_requests(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_model_workspace(),save_model_policy(text,bigint,jsonb),save_model_fallbacks(bigint,jsonb),read_model_requests(text) TO agent_driver;

CREATE FUNCTION validate_agent_model_order() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public AS $$
BEGIN
 IF NEW.spec ? 'model_order' THEN
  IF jsonb_typeof(NEW.spec->'model_order') IS DISTINCT FROM 'array' THEN
   RAISE EXCEPTION 'invalid_model_order' USING ERRCODE='22023';
  END IF;
  IF jsonb_array_length(NEW.spec->'model_order')>16
   OR EXISTS(SELECT FROM jsonb_array_elements(NEW.spec->'model_order') v WHERE jsonb_typeof(v)<>'string')
   OR EXISTS(SELECT FROM jsonb_array_elements_text(NEW.spec->'model_order') v WHERE NOT EXISTS(SELECT FROM model_policy m WHERE m.id=v))
   OR (SELECT count(*)<>count(DISTINCT v) FROM jsonb_array_elements_text(NEW.spec->'model_order') v) THEN
   RAISE EXCEPTION 'invalid_model_order' USING ERRCODE='22023';
  END IF;
 END IF;
 IF NEW.spec ? 'use_global_fallbacks' AND jsonb_typeof(NEW.spec->'use_global_fallbacks') IS DISTINCT FROM 'boolean' THEN
  RAISE EXCEPTION 'invalid_global_fallback_opt_in' USING ERRCODE='22023';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER agent_model_order_valid BEFORE INSERT OR UPDATE OF spec ON agent
FOR EACH ROW EXECUTE FUNCTION validate_agent_model_order();
REVOKE ALL ON FUNCTION validate_agent_model_order() FROM PUBLIC;

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
 IF EXISTS(SELECT 1 FROM dispatch_attempt a LEFT JOIN dispatch_outcome o ON o.attempt_id=d.attempt_id WHERE a.provider_id=p.id AND o.attempt_id IS NULL AND a.receipt_time>at_time-interval '150 seconds' HAVING count(*)>=4) THEN
  UPDATE dispatch_intent SET state='held',held_until=at_time+interval '5 seconds',reason='in_flight_capacity',updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',at_time+interval '5 seconds','reason','in_flight_capacity');
 END IF;
 id_value:=gen_random_uuid()::text;
 INSERT INTO dispatch_attempt(attempt_id,intent_id,agent_id,provider_id,model_id,tier,ordinal,parent_attempt_id,request_sha256,source_lineage,receipt_time,record_environment)
 VALUES(id_value,i.intent_id,agent_value,p.id,pick->'route'->>'model_id',pick->'route'->>'tier',(pick->'route'->>'ordinal')::integer,i.parent_attempt_id,fp,'{"source":"agent_driver","entitlement_version":"local-research-v1"}',at_time,'local_research');
 UPDATE dispatch_intent SET state='admitted',route=pick->'route',attempt_id=id_value,reason=NULL,held_until=NULL,updated_at=at_time WHERE intent_id=i.intent_id;
 RETURN jsonb_build_object('status','admitted','intent_id',i.intent_id,'attempt_id',id_value,'route',pick->'route','skipped',pick->'skipped');
END $$;
