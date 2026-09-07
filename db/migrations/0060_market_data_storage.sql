-- Governed Local Research payloads. Permanent records contain references, not prices.
CREATE ROLE market_data_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT USAGE ON SCHEMA public TO market_data_writer;
CREATE TABLE market_data_source (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 source_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
 entitlement_version_id uuid NOT NULL,
 removed_at timestamptz,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 UNIQUE(source_version_id,entitlement_version_id),
 FOREIGN KEY(entitlement_version_id,source_version_id) REFERENCES data_entitlement_version(entitlement_version_id,source_registry_version_id)
);
CREATE TABLE market_data_dataset (
 id uuid PRIMARY KEY,
 source_id uuid NOT NULL REFERENCES market_data_source,
 snapshot_id uuid NOT NULL UNIQUE REFERENCES research_snapshot,
 last_used_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 removed_at timestamptz,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 UNIQUE(id,source_id)
);
CREATE TABLE market_data_payload (
 dataset_id uuid PRIMARY KEY,
 source_id uuid NOT NULL,
 content_digest text NOT NULL,
 panel jsonb NOT NULL,
 request jsonb NOT NULL,
 source_facts jsonb NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 FOREIGN KEY(dataset_id,source_id) REFERENCES market_data_dataset(id,source_id),
 UNIQUE(source_id,content_digest)
);
CREATE TABLE market_data_observation (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 source_id uuid NOT NULL REFERENCES market_data_source,
 symbol text NOT NULL,
 session date NOT NULL,
 symbol_asof date NOT NULL,
 open_price numeric NOT NULL CHECK(open_price>0),
 high_price numeric NOT NULL CHECK(high_price>0),
 low_price numeric NOT NULL CHECK(low_price>0),
 close_price numeric NOT NULL CHECK(close_price>0),
 volume bigint NOT NULL CHECK(volume>=0),
 bar jsonb NOT NULL,
 content_digest text NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 CHECK(high_price>=greatest(open_price,close_price) AND low_price<=least(open_price,close_price)),
 UNIQUE(source_id,symbol,session,symbol_asof,content_digest), UNIQUE(id,source_id)
);
CREATE TABLE market_data_dataset_observation (
 dataset_id uuid NOT NULL, observation_id uuid NOT NULL, source_id uuid NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 PRIMARY KEY(dataset_id,observation_id),
 FOREIGN KEY(dataset_id,source_id) REFERENCES market_data_dataset(id,source_id),
 FOREIGN KEY(observation_id,source_id) REFERENCES market_data_observation(id,source_id)
);
CREATE TABLE market_data_result (
 experiment_id bigint PRIMARY KEY REFERENCES incubator_experiment_ticket(evaluation_id),
 dataset_id uuid NOT NULL REFERENCES market_data_dataset,
 result jsonb NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
-- These payload/control tables deliberately support scoped deletion; only the API role
-- may invoke lifecycle functions. There are no table grants to either runtime role.
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['market_data_source','market_data_dataset','market_data_payload','market_data_observation','market_data_dataset_observation','market_data_result'] LOOP
  PERFORM register_evidence_table(t);
 END LOOP;
END $$;

CREATE FUNCTION market_data_source_available(id_value uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM market_data_source s
 JOIN source_registry_version v ON v.source_version_id=s.source_version_id
 JOIN data_entitlement_version e ON e.entitlement_version_id=s.entitlement_version_id
 WHERE s.id=id_value AND s.removed_at IS NULL AND v.lifecycle='active' AND e.certification_state='certified'
 AND v.record_environment='local_research' AND e.record_environment='local_research'
 AND 'local_research'=ANY(e.authorized_purposes)
 AND statement_timestamp()>=greatest(v.effective_from,e.effective_from)
 AND (v.effective_to IS NULL OR statement_timestamp()<v.effective_to)
 AND (e.expires_at IS NULL OR statement_timestamp()<e.expires_at))
$$;
CREATE FUNCTION configure_market_data_source(source_value uuid,entitlement_value uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE id_value uuid; lineage jsonb; BEGIN
 IF NOT EXISTS(SELECT 1 FROM source_registry_version v JOIN source_registry r USING(source_id)
  JOIN data_entitlement_version e ON e.source_registry_version_id=v.source_version_id
  WHERE v.source_version_id=source_value AND e.entitlement_version_id=entitlement_value AND r.source_kind='market_data') THEN
  RAISE EXCEPTION 'registered_market_data_entitlement_required';
 END IF;
 lineage:=jsonb_build_object('source',source_value::text,'entitlement_version',entitlement_value::text);
 INSERT INTO market_data_source(source_version_id,entitlement_version_id,source_lineage,receipt_time,record_environment)
 VALUES(source_value,entitlement_value,lineage,clock_timestamp(),'local_research') ON CONFLICT(source_version_id,entitlement_version_id) DO NOTHING;
 SELECT id INTO STRICT id_value FROM market_data_source WHERE source_version_id=source_value AND entitlement_version_id=entitlement_value FOR UPDATE;
 IF NOT market_data_source_available(id_value) THEN RAISE EXCEPTION 'source_unavailable'; END IF;
 PERFORM append_audit_event('market-data-source:'||id_value,'research.market_data_source_configured',now(),jsonb_build_object('source_id',id_value),lineage,now(),'local_research');
 RETURN id_value;
END $$;

CREATE FUNCTION validate_market_data_panel(p jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE n integer; s text; d text; previous text; item jsonb; b jsonb; names text[]; seen text[]:='{}'; i integer;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(p))<>6
 OR p->>'dataset_class' IS DISTINCT FROM 'observed'
 OR jsonb_typeof(p->'symbols') IS DISTINCT FROM 'array' OR jsonb_typeof(p->'sessions') IS DISTINCT FROM 'array'
 OR jsonb_typeof(p->'series') IS DISTINCT FROM 'array' OR jsonb_typeof(p->'benchmark') IS DISTINCT FROM 'array'
 OR jsonb_typeof(p->'cash_bps') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_panel'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p->'symbols') x WHERE jsonb_typeof(x)<>'string') OR EXISTS(SELECT 1 FROM jsonb_array_elements(p->'sessions') x WHERE jsonb_typeof(x)<>'string') THEN RAISE EXCEPTION 'invalid_panel'; END IF;
 SELECT array_agg(value) INTO names FROM jsonb_array_elements_text(p->'symbols');
 n:=jsonb_array_length(p->'sessions');
 IF cardinality(names) NOT BETWEEN 4 AND 32 OR n NOT BETWEEN 3 AND 60
 OR jsonb_array_length(p->'series')<>cardinality(names) OR jsonb_array_length(p->'benchmark')<>n
 OR jsonb_array_length(p->'cash_bps')<>n OR (SELECT count(DISTINCT x) FROM unnest(names) x)<>cardinality(names)
 THEN RAISE EXCEPTION 'invalid_panel'; END IF;
 FOREACH s IN ARRAY names LOOP IF s !~ '^[A-Z0-9.-]{1,16}$' THEN RAISE EXCEPTION 'invalid_panel'; END IF; END LOOP;
 FOR d IN SELECT value FROM jsonb_array_elements_text(p->'sessions') LOOP
  IF d !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' OR to_char(d::date,'YYYY-MM-DD')<>d OR (previous IS NOT NULL AND d<=previous) THEN RAISE EXCEPTION 'invalid_panel'; END IF;
  previous:=d;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p->'cash_bps') x WHERE x IS DISTINCT FROM '0'::jsonb) THEN RAISE EXCEPTION 'zero_interest_assumption_required'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p->'series') LOOP
  s:=item->>'symbol';
  IF jsonb_typeof(item->'symbol') IS DISTINCT FROM 'string' OR s IS NULL OR NOT s=ANY(names) OR s=ANY(seen) OR (SELECT count(*) FROM jsonb_object_keys(item))<>2
    OR jsonb_typeof(item->'bars') IS DISTINCT FROM 'array' OR jsonb_array_length(item->'bars')<>n THEN RAISE EXCEPTION 'invalid_panel'; END IF;
  seen:=array_append(seen,s);
 END LOOP;
 FOR item IN SELECT value->'bars' FROM jsonb_array_elements(p->'series') UNION ALL SELECT p->'benchmark' LOOP
  i:=0;
  FOR b IN SELECT value FROM jsonb_array_elements(item) LOOP
   IF jsonb_typeof(b) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(b))<>3
    OR b->>'session' IS DISTINCT FROM p->'sessions'->>i
    OR jsonb_typeof(b->'open_cents') IS DISTINCT FROM 'number' OR jsonb_typeof(b->'close_cents') IS DISTINCT FROM 'number'
    OR coalesce(b->>'open_cents','') !~ '^[0-9]+$' OR coalesce(b->>'close_cents','') !~ '^[0-9]+$'
    OR (b->>'open_cents')::numeric NOT BETWEEN 1 AND 1000000000 OR (b->>'close_cents')::numeric NOT BETWEEN 1 AND 1000000000 THEN RAISE EXCEPTION 'invalid_panel'; END IF;
   i:=i+1;
  END LOOP;
 END LOOP;
END $$;

CREATE FUNCTION register_market_data_download(source_value uuid,bundle jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE src market_data_source%ROWTYPE; dataset_value uuid; snapshot_value research_snapshot%ROWTYPE;
 p jsonb; obs jsonb; bar_value jsonb; expected jsonb; symbol_value text; session_value date; obs_value uuid;
 fingerprint text; names text[]; seen text[]:='{}'; obs_key text; request_value jsonb;
BEGIN
 SELECT * INTO STRICT src FROM market_data_source WHERE id=source_value FOR UPDATE;
 IF NOT market_data_source_available(source_value) THEN RAISE EXCEPTION 'source_unavailable'; END IF;
 IF bundle IS NULL OR octet_length(bundle::text)>2000000 OR bundle->>'schema' IS DISTINCT FROM 'market_mate_daily_download_v1'
 OR bundle->'source_facts'->>'provider' IS DISTINCT FROM 'alpaca' OR bundle->'source_facts'->>'feed' IS DISTINCT FROM 'sip'
 OR bundle->'source_facts'->>'currency' IS DISTINCT FROM 'USD' OR bundle->'source_facts'->>'adjustment' IS DISTINCT FROM 'all'
 OR bundle->'source_facts'->>'cash' IS DISTINCT FROM 'assumed_zero_interest' THEN RAISE EXCEPTION 'invalid_download'; END IF;
 p:=bundle->'panel'; request_value:=bundle->'request'; PERFORM validate_market_data_panel(p);
 IF request_value->'symbols' IS DISTINCT FROM p->'symbols' OR request_value->'sessions' IS DISTINCT FROM p->'sessions'
 OR request_value->>'cash' IS DISTINCT FROM 'zero_interest' OR coalesce(request_value->>'benchmark','') !~ '^[A-Z0-9.-]{1,16}$'
 OR coalesce(request_value->>'symbol_asof','') !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
 OR request_value->>'symbol_asof' IS DISTINCT FROM bundle->'source_facts'->>'symbol_asof'
 OR jsonb_typeof(bundle->'observations') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_download'; END IF;
 SELECT array_agg(DISTINCT name) INTO names FROM (SELECT value name FROM jsonb_array_elements_text(p->'symbols') UNION SELECT request_value->>'benchmark') x;
 IF jsonb_array_length(bundle->'observations')<>cardinality(names)*jsonb_array_length(p->'sessions') THEN RAISE EXCEPTION 'incomplete_observations'; END IF;
 fingerprint:=encode(digest(jsonb_build_object('panel',p,'request',request_value,'observations',bundle->'observations')::text,'sha256'),'hex');
 SELECT dataset_id INTO dataset_value FROM market_data_payload WHERE source_id=source_value AND content_digest=fingerprint;
 IF FOUND THEN UPDATE market_data_dataset SET last_used_at=clock_timestamp() WHERE id=dataset_value; RETURN (SELECT snapshot_id FROM market_data_dataset WHERE id=dataset_value); END IF;
 dataset_value:=gen_random_uuid();
 snapshot_value:=append_research_snapshot('incubator_momentum_daily_v1',jsonb_build_object('storage','market_data_v1','dataset_id',dataset_value,'dataset_class','observed'),src.source_lineage,NULL,NULL);
 INSERT INTO market_data_dataset(id,source_id,snapshot_id,source_lineage,receipt_time,record_environment) VALUES(dataset_value,source_value,snapshot_value.snapshot_id,src.source_lineage,clock_timestamp(),'local_research');
 INSERT INTO market_data_payload VALUES(dataset_value,source_value,fingerprint,p,request_value,bundle->'source_facts',src.source_lineage,clock_timestamp(),'local_research');
 FOR obs IN SELECT value FROM jsonb_array_elements(bundle->'observations') LOOP
  symbol_value:=obs->>'symbol'; session_value:=(obs->>'session')::date; bar_value:=obs->'bar'; obs_key:=symbol_value||':'||session_value::text;
  IF jsonb_typeof(obs->'symbol') IS DISTINCT FROM 'string' OR jsonb_typeof(obs->'session') IS DISTINCT FROM 'string' OR symbol_value IS NULL OR session_value IS NULL OR NOT symbol_value=ANY(names) OR NOT p->'sessions' ? session_value::text OR obs_key=ANY(seen)
   THEN RAISE EXCEPTION 'invalid_observation_identity'; END IF;
  seen:=array_append(seen,obs_key);
  IF symbol_value=request_value->>'benchmark' THEN SELECT value INTO expected FROM jsonb_array_elements(p->'benchmark') WHERE value->>'session'=session_value::text;
  ELSE SELECT b INTO expected FROM jsonb_array_elements(p->'series') s CROSS JOIN LATERAL jsonb_array_elements(s->'bars') b WHERE s->>'symbol'=symbol_value AND b->>'session'=session_value::text; END IF;
  IF jsonb_typeof(bar_value) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(bar_value))<>6
   OR (bar_value->>'t')::timestamptz AT TIME ZONE 'America/New_York' IS DISTINCT FROM session_value::timestamp
   OR EXISTS(SELECT 1 FROM unnest(ARRAY['o','h','l','c']) k WHERE jsonb_typeof(bar_value->k) IS DISTINCT FROM 'number'
      OR coalesce(bar_value->>k,'') !~ '^[0-9]+(\.[0-9]{1,6})?$' OR (bar_value->>k)::numeric<=0 OR (bar_value->>k)::numeric>10000000)
   OR jsonb_typeof(bar_value->'v') IS DISTINCT FROM 'number' OR coalesce(bar_value->>'v','') !~ '^[0-9]+$'
   OR floor((bar_value->>'o')::numeric*100+0.5) IS DISTINCT FROM (expected->>'open_cents')::numeric
   OR floor((bar_value->>'c')::numeric*100+0.5) IS DISTINCT FROM (expected->>'close_cents')::numeric
   THEN RAISE EXCEPTION 'inconsistent_observation'; END IF;
  -- If the benchmark is also in the universe, its two panel representations must agree.
  IF symbol_value=request_value->>'benchmark' AND EXISTS(SELECT 1 FROM jsonb_array_elements(p->'series') s CROSS JOIN LATERAL jsonb_array_elements(s->'bars') b WHERE s->>'symbol'=symbol_value AND b->>'session'=session_value::text AND b IS DISTINCT FROM expected) THEN RAISE EXCEPTION 'inconsistent_benchmark'; END IF;
  INSERT INTO market_data_observation(source_id,symbol,session,symbol_asof,open_price,high_price,low_price,close_price,volume,bar,content_digest,source_lineage,receipt_time,record_environment)
  VALUES(source_value,symbol_value,session_value,(request_value->>'symbol_asof')::date,(bar_value->>'o')::numeric,(bar_value->>'h')::numeric,(bar_value->>'l')::numeric,(bar_value->>'c')::numeric,(bar_value->>'v')::bigint,bar_value,encode(digest(bar_value::text,'sha256'),'hex'),src.source_lineage,clock_timestamp(),'local_research') ON CONFLICT DO NOTHING;
  SELECT id INTO STRICT obs_value FROM market_data_observation WHERE source_id=source_value AND symbol=symbol_value AND session=session_value AND symbol_asof=(request_value->>'symbol_asof')::date AND content_digest=encode(digest(bar_value::text,'sha256'),'hex');
  INSERT INTO market_data_dataset_observation VALUES(dataset_value,obs_value,source_value,src.source_lineage,clock_timestamp(),'local_research');
 END LOOP;
 PERFORM append_audit_event('market-data-import:'||dataset_value,'research.market_data_registered',now(),jsonb_build_object('dataset_id',dataset_value,'snapshot_id',snapshot_value.snapshot_id,'source_id',source_value),src.source_lineage,now(),'local_research');
 RETURN snapshot_value.snapshot_id;
END $$;

CREATE FUNCTION market_data_snapshot_available(snapshot_value uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT CASE WHEN EXISTS(SELECT 1 FROM market_data_dataset WHERE snapshot_id=snapshot_value)
 THEN EXISTS(SELECT 1 FROM market_data_dataset d JOIN market_data_payload p ON p.dataset_id=d.id WHERE d.snapshot_id=snapshot_value AND d.removed_at IS NULL AND market_data_source_available(d.source_id)) ELSE true END
$$;
CREATE OR REPLACE FUNCTION read_incubator_experiment_input(id_value bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('experiment',read_incubator_experiment(id_value),'evaluation',read_incubator_evaluation(id_value),
 'payload',CASE WHEN m.id IS NULL THEN s.payload WHEN market_data_snapshot_available(s.snapshot_id) THEN p.panel ELSE NULL END,
 'snapshot_superseded',EXISTS(SELECT 1 FROM research_snapshot_revision r WHERE r.predecessor_snapshot_id=s.snapshot_id))
 FROM incubator_experiment_ticket t LEFT JOIN incubator_experiment_dataset d ON d.experiment_id=t.evaluation_id LEFT JOIN research_snapshot s USING(snapshot_id)
 LEFT JOIN market_data_dataset m ON m.snapshot_id=s.snapshot_id LEFT JOIN market_data_payload p ON p.dataset_id=m.id WHERE t.evaluation_id=id_value
$$;
ALTER FUNCTION read_incubator_momentum_datasets() RENAME TO read_incubator_momentum_datasets_legacy;
CREATE FUNCTION read_incubator_momentum_datasets() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(x),'[]') FROM jsonb_array_elements(read_incubator_momentum_datasets_legacy()) x WHERE market_data_snapshot_available((x->>'id')::uuid)
$$;
ALTER FUNCTION bind_incubator_experiment_dataset(bigint,uuid) RENAME TO bind_incubator_experiment_dataset_legacy;
CREATE FUNCTION bind_incubator_experiment_dataset(id_value bigint,snapshot_value uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE source_value uuid; BEGIN
 SELECT source_id INTO source_value FROM market_data_dataset WHERE snapshot_id=snapshot_value;
 IF FOUND THEN
  PERFORM 1 FROM market_data_source WHERE id=source_value FOR UPDATE;
  IF NOT market_data_snapshot_available(snapshot_value) THEN RAISE EXCEPTION 'dataset_unavailable'; END IF;
  UPDATE market_data_dataset SET last_used_at=clock_timestamp() WHERE snapshot_id=snapshot_value;
 END IF;
 PERFORM bind_incubator_experiment_dataset_legacy(id_value,snapshot_value);
END $$;
ALTER FUNCTION record_incubator_experiment_event(bigint,text,jsonb) RENAME TO record_incubator_experiment_event_legacy;
CREATE FUNCTION record_incubator_experiment_event(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE d market_data_dataset%ROWTYPE; prior jsonb; safe_detail jsonb;
BEGIN
 SELECT m.* INTO d FROM market_data_dataset m JOIN incubator_experiment_dataset e ON e.snapshot_id=m.snapshot_id WHERE e.experiment_id=id_value;
 IF NOT FOUND THEN PERFORM record_incubator_experiment_event_legacy(id_value,state_value,detail_value); RETURN; END IF;
 PERFORM 1 FROM market_data_source WHERE id=d.source_id FOR UPDATE;
 IF state_value<>'failed' AND NOT market_data_snapshot_available(d.snapshot_id) THEN RAISE EXCEPTION 'dataset_unavailable'; END IF;
 IF state_value='completed' THEN
  IF jsonb_typeof(detail_value->'result') IS DISTINCT FROM 'object' OR detail_value->'result'->>'engine' IS DISTINCT FROM 'momentum_v1' OR detail_value->'result'->>'outcome' IS DISTINCT FROM 'diagnostic_only'
   OR (detail_value - 'result' - 'registration_id')<>'{}'::jsonb THEN RAISE EXCEPTION 'invalid_managed_result'; END IF;
  SELECT result INTO prior FROM market_data_result WHERE experiment_id=id_value;
  IF FOUND AND prior IS DISTINCT FROM detail_value->'result' THEN RAISE EXCEPTION 'immutable_result'; END IF;
  safe_detail:=jsonb_build_object('result',jsonb_build_object('engine','momentum_v1','outcome','diagnostic_only','storage','market_data_v1'),'registration_id',(SELECT detail->'registration_id' FROM incubator_experiment_event WHERE experiment_id=id_value AND state='ready' ORDER BY sequence DESC LIMIT 1));
  PERFORM record_incubator_experiment_event_legacy(id_value,state_value,safe_detail);
  INSERT INTO market_data_result VALUES(id_value,d.id,detail_value->'result',d.source_lineage,clock_timestamp(),'local_research') ON CONFLICT DO NOTHING;
 ELSE PERFORM record_incubator_experiment_event_legacy(id_value,state_value,detail_value); END IF;
END $$;
ALTER FUNCTION read_incubator_experiment(bigint) RENAME TO read_incubator_experiment_legacy;
CREATE FUNCTION read_incubator_experiment(id_value bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE r jsonb; d market_data_dataset%ROWTYPE; result_value jsonb; events_value jsonb; available boolean;
BEGIN
 r:=read_incubator_experiment_legacy(id_value);
 SELECT m.* INTO d FROM market_data_dataset m JOIN incubator_experiment_dataset e ON e.snapshot_id=m.snapshot_id WHERE e.experiment_id=id_value;
 IF NOT FOUND THEN RETURN r; END IF;
 available:=market_data_snapshot_available(d.snapshot_id);
 SELECT result INTO result_value FROM market_data_result WHERE experiment_id=id_value AND available;
 SELECT coalesce(jsonb_agg(CASE WHEN x->>'state'='completed' THEN jsonb_set(x,'{detail}',((x->'detail')-'result')||CASE WHEN result_value IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('result',result_value) END) ELSE x END ORDER BY (x->>'sequence')::integer),'[]') INTO events_value FROM jsonb_array_elements(r->'events') x;
 r:=r||jsonb_build_object('events',events_value,'replay_available',available);
 IF r->>'status'='completed' THEN r:=jsonb_set(r,'{detail}',((r->'detail')-'result')||CASE WHEN result_value IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('result',result_value) END); END IF;
 IF NOT available THEN r:=jsonb_set(r,'{detail}',(r->'detail')||jsonb_build_object('reason','Source data is unavailable; this experiment cannot be replayed.')); END IF;
 RETURN r;
END $$;

CREATE FUNCTION remove_market_data_source(source_value uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE src market_data_source%ROWTYPE; n integer; BEGIN
 SELECT * INTO STRICT src FROM market_data_source WHERE id=source_value FOR UPDATE;
 UPDATE market_data_source SET removed_at=coalesce(removed_at,clock_timestamp()) WHERE id=source_value;
 DELETE FROM market_data_result WHERE dataset_id IN(SELECT id FROM market_data_dataset WHERE source_id=source_value);
 DELETE FROM market_data_dataset_observation WHERE source_id=source_value;
 DELETE FROM market_data_payload WHERE source_id=source_value;
 DELETE FROM market_data_observation WHERE source_id=source_value;
 GET DIAGNOSTICS n=ROW_COUNT;
 UPDATE market_data_dataset SET removed_at=coalesce(removed_at,clock_timestamp()) WHERE source_id=source_value;
 PERFORM append_audit_event('market-data-remove:'||source_value,'research.market_data_source_removed',now(),jsonb_build_object('source_id',source_value,'active_stores_purged',true),src.source_lineage,now(),'local_research');
 PERFORM pg_notify('incubator_experiment','changed');
 RETURN jsonb_build_object('source_id',source_value,'state','active_stores_purged','observations_removed',n,'external_copies','not_verified');
END $$;
CREATE FUNCTION cleanup_market_data_cache() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE src market_data_source%ROWTYPE; d market_data_dataset%ROWTYPE; n integer:=0; BEGIN
 FOR src IN SELECT * FROM market_data_source ORDER BY id FOR UPDATE LOOP
  FOR d IN SELECT * FROM market_data_dataset m WHERE m.source_id=src.id AND m.removed_at IS NULL AND m.last_used_at<clock_timestamp()-interval '90 days'
   AND NOT EXISTS(SELECT 1 FROM incubator_experiment_dataset e WHERE e.snapshot_id=m.snapshot_id) LOOP
   DELETE FROM market_data_dataset_observation WHERE dataset_id=d.id;
   DELETE FROM market_data_payload WHERE dataset_id=d.id;
   UPDATE market_data_dataset SET removed_at=clock_timestamp() WHERE id=d.id;
   PERFORM append_audit_event('market-data-expire:'||d.id,'research.market_data_cache_expired',now(),jsonb_build_object('dataset_id',d.id),src.source_lineage,now(),'local_research');
   n:=n+1;
  END LOOP;
  DELETE FROM market_data_observation o WHERE o.source_id=src.id AND NOT EXISTS(SELECT 1 FROM market_data_dataset_observation x WHERE x.observation_id=o.id);
 END LOOP;
 RETURN n;
END $$;
CREATE FUNCTION read_market_data_catalog() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('snapshot_id',d.snapshot_id,'source_id',d.source_id,'created_at',d.receipt_time,'last_used_at',d.last_used_at,'replay_available',market_data_snapshot_available(d.snapshot_id),'referenced',EXISTS(SELECT 1 FROM incubator_experiment_dataset e WHERE e.snapshot_id=d.snapshot_id)) ORDER BY d.receipt_time DESC),'[]') FROM market_data_dataset d
$$;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM market_data_writer;
REVOKE ALL ON FUNCTION configure_market_data_source(uuid,uuid),market_data_source_available(uuid),validate_market_data_panel(jsonb),register_market_data_download(uuid,jsonb),market_data_snapshot_available(uuid),remove_market_data_source(uuid),cleanup_market_data_cache(),read_market_data_catalog() FROM PUBLIC;
REVOKE ALL ON FUNCTION read_incubator_momentum_datasets_legacy(),bind_incubator_experiment_dataset_legacy(bigint,uuid),record_incubator_experiment_event_legacy(bigint,text,jsonb),read_incubator_experiment_legacy(bigint) FROM PUBLIC,incubator_runner;
REVOKE ALL ON FUNCTION read_incubator_momentum_datasets(),bind_incubator_experiment_dataset(bigint,uuid),record_incubator_experiment_event(bigint,text,jsonb),read_incubator_experiment(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION configure_market_data_source(uuid,uuid),register_market_data_download(uuid,jsonb),remove_market_data_source(uuid),cleanup_market_data_cache(),read_market_data_catalog() TO market_data_writer;
GRANT EXECUTE ON FUNCTION read_incubator_momentum_datasets(),bind_incubator_experiment_dataset(bigint,uuid),record_incubator_experiment_event(bigint,text,jsonb),read_incubator_experiment(bigint) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();
