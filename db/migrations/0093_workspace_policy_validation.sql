-- Disambiguate offering validation from the PL/pgSQL loop variable.
CREATE OR REPLACE FUNCTION save_model_policy(id_value text,expected bigint,patch jsonb) RETURNS jsonb
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
 IF EXISTS(SELECT FROM jsonb_array_elements(patch->'offerings') incoming(value) GROUP BY incoming.value->>'provider_id',incoming.value->>'model_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'duplicate_model_offering' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT FROM model_policy p CROSS JOIN LATERAL jsonb_array_elements(p.offerings) prior
  CROSS JOIN LATERAL jsonb_array_elements(patch->'offerings') incoming WHERE p.id<>id_value AND prior->>'provider_id'=incoming->>'provider_id' AND prior->>'model_id'=incoming->>'model_id') THEN RAISE EXCEPTION 'offering_already_mapped' USING ERRCODE='22023'; END IF;
 INSERT INTO model_policy(id,name,offerings,revision) VALUES(id_value,patch->>'name',patch->'offerings',expected+1)
 ON CONFLICT(id) DO UPDATE SET name=excluded.name,offerings=excluded.offerings,revision=excluded.revision;
 INSERT INTO config_revision(entity,entity_id,revision,source,diff) VALUES('model',id_value,expected+1,'ui',patch);
 RETURN jsonb_build_object('status','saved','revision',expected+1);
END $$;
