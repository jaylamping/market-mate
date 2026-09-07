-- Owner-configured, personal Local Research collection only.
CREATE ROLE market_data_service LOGIN PASSWORD 'local-data-only' NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;
GRANT market_data_acquirer TO market_data_service;
CREATE TABLE market_data_settings (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), source_id uuid NOT NULL REFERENCES market_data_source,
 enabled boolean NOT NULL DEFAULT true, refresh_enabled boolean NOT NULL DEFAULT false,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
SELECT register_evidence_table('market_data_settings');
CREATE FUNCTION setup_personal_market_data(acknowledged boolean) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE s uuid; v uuid; e uuid; ev uuid; configured uuid;
 lineage jsonb:=jsonb_build_object('source','alpaca-personal-research','entitlement_version','owner-account-review-v1');
BEGIN
 IF acknowledged IS DISTINCT FROM true THEN RAISE EXCEPTION 'account_terms_review_required'; END IF;
 PERFORM pg_advisory_xact_lock(63001);
 SELECT source_id INTO configured FROM market_data_settings;
 IF FOUND THEN
  IF NOT market_data_source_available(configured) THEN RAISE EXCEPTION 'source_unavailable'; END IF;
  RETURN configured;
 END IF;
 INSERT INTO source_registry(source_key,source_name,source_kind,source_lineage,receipt_time,record_environment)
 VALUES('alpaca-personal-research','Alpaca historical SIP','market_data',lineage,now(),'local_research') RETURNING source_id INTO s;
 INSERT INTO source_registry_version(source_id,registry_version,lifecycle,license_terms,permitted_use,lineage_rules,observation_states,correction_semantics,effective_from,source_lineage,receipt_time,record_environment)
 VALUES(s,1,'active','{"name":"Alpaca account agreement - Principal reviewed","basis":"Principal confirms account terms permit local personal research retention; no independent legal certification"}','{"purposes":["local_research"]}','{"required_fields":[]}',ARRAY['current'],ARRAY['required_deletion'],now(),lineage,now(),'local_research') RETURNING source_version_id INTO v;
 INSERT INTO data_entitlement(entitlement_key,account_scope,plan_name,source_lineage,receipt_time,record_environment)
 VALUES('alpaca-personal-research','Principal account','Historical SIP only; no paid upgrade',lineage,now(),'local_research') RETURNING entitlement_id INTO e;
 INSERT INTO data_entitlement_version(entitlement_id,entitlement_version,source_registry_version_id,certification_state,authorized_purposes,effective_from,certification_basis,source_lineage,receipt_time,record_environment)
 VALUES(e,1,v,'certified',ARRAY['local_research'],now(),'{"authority":"Principal account-terms attestation","scope":"personal local research only","provider_access":"historical bars checked by connector","not_certified":["Paper","Live","redistribution"]}',lineage,now(),'local_research') RETURNING entitlement_version_id INTO ev;
 configured:=configure_market_data_source(v,ev);
 INSERT INTO market_data_settings(source_id,source_lineage,receipt_time,record_environment) VALUES(configured,lineage,now(),'local_research');
 RETURN configured;
END $$;
CREATE FUNCTION read_market_data_settings() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('source_id',source_id,'enabled',enabled,'refresh_enabled',refresh_enabled,'available',market_data_source_available(source_id),'provider','Alpaca','feed','SIP','adjustment','all','currency','USD','calendar','XNYS_2025_2026_v1') FROM market_data_settings
$$;
CREATE FUNCTION change_market_data_settings(enabled_value boolean,refresh_value boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE src uuid; BEGIN
 SELECT source_id INTO STRICT src FROM market_data_settings;
 PERFORM 1 FROM market_data_source WHERE id=src FOR UPDATE;
 UPDATE market_data_settings SET enabled=enabled_value,refresh_enabled=refresh_value;
 PERFORM append_audit_event('market-data-settings:'||gen_random_uuid(),'research.market_data_settings',now(),jsonb_build_object('enabled',enabled_value,'refresh_enabled',refresh_value),(SELECT source_lineage FROM market_data_settings),now(),'local_research');
END $$;
CREATE FUNCTION market_data_collection_enabled(src uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT coalesce((SELECT enabled FROM market_data_settings WHERE source_id=src),true)
$$;
ALTER FUNCTION queue_market_data_acquisitions(uuid) RENAME TO queue_market_data_acquisitions_wu62;
CREATE FUNCTION queue_market_data_acquisitions(src uuid) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN PERFORM 1 FROM market_data_source WHERE id=src FOR UPDATE;
 IF NOT market_data_collection_enabled(src) THEN RETURN 0; END IF;
 RETURN queue_market_data_acquisitions_wu62(src); END $$;
ALTER FUNCTION claim_market_data_acquisition(uuid) RENAME TO claim_market_data_acquisition_wu62;
CREATE FUNCTION claim_market_data_acquisition(src uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN PERFORM 1 FROM market_data_source WHERE id=src FOR UPDATE;
 IF NOT market_data_collection_enabled(src) THEN RETURN NULL; END IF;
 RETURN claim_market_data_acquisition_wu62(src); END $$;
ALTER FUNCTION finish_market_data_acquisition(bigint,uuid,jsonb) RENAME TO finish_market_data_acquisition_wu62;
CREATE FUNCTION finish_market_data_acquisition(id_value bigint,token uuid,bundle jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE src uuid; BEGIN SELECT source_id INTO STRICT src FROM market_data_acquisition WHERE experiment_id=id_value;
 PERFORM 1 FROM market_data_source WHERE id=src FOR UPDATE;
 IF NOT market_data_collection_enabled(src) THEN RAISE EXCEPTION 'collection_paused'; END IF;
 RETURN finish_market_data_acquisition_wu62(id_value,token,bundle); END $$;
REVOKE ALL ON FUNCTION queue_market_data_acquisitions_wu62(uuid),claim_market_data_acquisition_wu62(uuid),finish_market_data_acquisition_wu62(bigint,uuid,jsonb) FROM market_data_acquirer,PUBLIC;
GRANT EXECUTE ON FUNCTION queue_market_data_acquisitions(uuid),claim_market_data_acquisition(uuid),finish_market_data_acquisition(bigint,uuid,jsonb) TO market_data_acquirer;
CREATE FUNCTION market_data_calendar_sessions_v1(start_value date,end_value date) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE sessions jsonb; BEGIN
 IF start_value<'2025-01-01' OR end_value>'2026-12-31' OR start_value>end_value THEN RAISE EXCEPTION 'calendar_unsupported'; END IF;
 SELECT jsonb_agg(day::date::text ORDER BY day) INTO sessions FROM generate_series(start_value::timestamp,end_value::timestamp,interval '1 day') day
 WHERE extract(isodow FROM day)<=5 AND day::date<>ALL(ARRAY['2025-01-01','2025-01-09','2025-01-20','2025-02-17','2025-04-18','2025-05-26','2025-06-19','2025-07-04','2025-09-01','2025-11-27','2025-12-25','2026-01-01','2026-01-19','2026-02-16','2026-04-03','2026-05-25','2026-06-19','2026-07-03','2026-09-07','2026-11-26','2026-12-25']::date[]);
 RETURN sessions; END $$;
CREATE OR REPLACE FUNCTION expand_market_data_request(d jsonb,spec jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE start_value date; end_value date; sessions jsonb; result jsonb; n integer; k text;
BEGIN
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(d))<>7
  OR d->>'calendar' IS DISTINCT FROM 'XNYS_2025_2026_v1' OR d->>'cash' IS DISTINCT FROM 'zero_interest'
  OR jsonb_typeof(d->'symbols') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_setup_request'; END IF;
 FOREACH k IN ARRAY ARRAY['start','end','symbol_asof'] LOOP
  IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' OR d->>k !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RAISE EXCEPTION 'invalid_setup_request'; END IF;
 END LOOP;
 start_value:=(d->>'start')::date; end_value:=(d->>'end')::date;
 IF start_value<'2025-01-01' OR end_value>'2026-12-31' OR start_value>end_value OR end_value-start_value>120
  OR end_value>=(statement_timestamp() AT TIME ZONE 'America/New_York')::date
  OR (d->>'symbol_asof')::date<'2016-01-01' OR (d->>'symbol_asof')::date>(statement_timestamp() AT TIME ZONE 'America/New_York')::date THEN RAISE EXCEPTION 'unsupported_date_range'; END IF;
 n:=jsonb_array_length(d->'symbols');
 IF n NOT BETWEEN 4 AND 32 OR (SELECT count(DISTINCT value) FROM jsonb_array_elements(d->'symbols'))<>n
  OR EXISTS(SELECT 1 FROM jsonb_array_elements(d->'symbols') x WHERE jsonb_typeof(x) IS DISTINCT FROM 'string' OR x#>>'{}' !~ '^[A-Z0-9.-]{1,16}$')
  OR jsonb_typeof(d->'benchmark') IS DISTINCT FROM 'string' OR d->>'benchmark' !~ '^[A-Z0-9.-]{1,16}$' THEN RAISE EXCEPTION 'invalid_symbols'; END IF;
 sessions:=market_data_calendar_sessions_v1(start_value,end_value);
 IF jsonb_typeof(spec) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(spec))<>5 OR spec->>'runner' IS DISTINCT FROM 'momentum_v1' THEN RAISE EXCEPTION 'invalid_spec'; END IF;
 FOREACH k IN ARRAY ARRAY['lookback_sessions','quantile_count','one_way_cost_bps','borrow_bps_per_session'] LOOP
  IF strategy_sandbox_integer(spec->k) IS NULL THEN RAISE EXCEPTION 'invalid_spec'; END IF;
 END LOOP;
 IF (spec->>'lookback_sessions')::int NOT BETWEEN 1 AND 5 OR (spec->>'quantile_count')::int NOT BETWEEN 2 AND 10 OR (spec->>'one_way_cost_bps')::int NOT BETWEEN 0 AND 100 OR (spec->>'borrow_bps_per_session')::int NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'invalid_spec'; END IF;
 IF coalesce(jsonb_array_length(sessions),0) NOT BETWEEN 3 AND 60 OR jsonb_array_length(sessions)<=(spec->>'lookback_sessions')::int+1 OR n%(spec->>'quantile_count')::int<>0 THEN RAISE EXCEPTION 'incompatible_panel_request'; END IF;
 RETURN jsonb_build_object('schema_version',1,'symbols',d->'symbols','sessions',sessions,'benchmark',d->'benchmark','symbol_asof',d->'symbol_asof','cash',d->'cash','spec',spec);
END $$;


CREATE TABLE market_data_refresh (
 experiment_id bigint NOT NULL REFERENCES market_data_acquisition(experiment_id), session_end date NOT NULL,
 request jsonb NOT NULL, state text NOT NULL CHECK(state IN ('queued','leased','completed','failed')),
 token uuid, lease_until timestamptz, attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
 snapshot_id uuid REFERENCES research_snapshot, error_code text,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)), receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'), PRIMARY KEY(experiment_id,session_end)
);
SELECT register_evidence_table('market_data_refresh');
CREATE FUNCTION market_data_research_active(id_value bigint) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM incubator_evaluation e WHERE e.id=id_value AND read_incubator_evaluation(id_value)->>'status'<>'superseded' AND NOT coalesce((SELECT archived FROM incubator_research_archive_event WHERE run_key=e.run_key ORDER BY sequence DESC LIMIT 1),false))
$$;
CREATE FUNCTION queue_market_data_refreshes_at(now_value timestamptz) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE local_now timestamp:=now_value AT TIME ZONE 'America/New_York'; dates jsonb; latest date; j record; window_value jsonb; n integer:=0;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM market_data_settings WHERE enabled AND refresh_enabled AND market_data_source_available(source_id)) OR local_now::time<'06:00' OR local_now::date NOT BETWEEN '2025-01-01' AND '2026-12-31' THEN RETURN 0; END IF;
 IF coalesce(jsonb_array_length(market_data_calendar_sessions_v1(local_now::date,local_now::date)),0)=0 THEN RETURN 0; END IF;
 dates:=market_data_calendar_sessions_v1(greatest('2025-01-01'::date,local_now::date-120),local_now::date-1); latest:=(dates->>-1)::date;
 IF latest IS NULL THEN RETURN 0; END IF;
 FOR j IN SELECT a.* FROM market_data_acquisition a JOIN market_data_settings s USING(source_id) WHERE a.state='completed' AND s.enabled AND s.refresh_enabled AND market_data_research_active(a.experiment_id) AND NOT EXISTS(SELECT 1 FROM market_data_refresh WHERE experiment_id=a.experiment_id AND session_end=latest) ORDER BY a.experiment_id LIMIT 32 LOOP
  SELECT jsonb_agg(value ORDER BY ord) INTO window_value FROM jsonb_array_elements(dates) WITH ORDINALITY x(value,ord) WHERE ord>jsonb_array_length(dates)-jsonb_array_length(j.request->'sessions');
  IF jsonb_array_length(window_value)<>jsonb_array_length(j.request->'sessions') THEN CONTINUE; END IF;
  INSERT INTO market_data_refresh(experiment_id,session_end,request,state,source_lineage,receipt_time,record_environment)
  VALUES(j.experiment_id,latest,j.request||jsonb_build_object('sessions',window_value),'queued',j.source_lineage,now(),'local_research') ON CONFLICT DO NOTHING;
  n:=n+1;
 END LOOP; RETURN n;
END $$;
CREATE FUNCTION queue_market_data_refreshes() RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$ SELECT queue_market_data_refreshes_at(clock_timestamp()) $$;
REVOKE ALL ON FUNCTION queue_market_data_refreshes_at(timestamptz) FROM PUBLIC;
CREATE FUNCTION claim_market_data_refresh() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_refresh%ROWTYPE; src uuid;
BEGIN
 SELECT source_id INTO src FROM market_data_settings WHERE enabled AND refresh_enabled;
 IF src IS NULL THEN RETURN NULL; END IF;
 PERFORM 1 FROM market_data_source WHERE id=src FOR UPDATE;
 IF NOT market_data_source_available(src) OR NOT EXISTS(SELECT 1 FROM market_data_settings WHERE source_id=src AND enabled AND refresh_enabled) THEN RETURN NULL; END IF;
 UPDATE market_data_refresh SET state='failed',error_code='lease_expired',token=NULL WHERE state='leased' AND lease_until<clock_timestamp() AND attempts>=3;
 SELECT r.* INTO j FROM market_data_refresh r JOIN market_data_acquisition a USING(experiment_id) WHERE a.source_id=src AND r.attempts<3 AND (r.state='queued' OR (r.state='leased' AND r.lease_until<clock_timestamp())) AND market_data_research_active(r.experiment_id) ORDER BY session_end DESC,experiment_id FOR UPDATE OF r SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 UPDATE market_data_refresh SET state='leased',token=gen_random_uuid(),lease_until=clock_timestamp()+interval '5 minutes',attempts=attempts+1 WHERE experiment_id=j.experiment_id AND session_end=j.session_end RETURNING * INTO j;
 RETURN jsonb_build_object('experiment_id',j.experiment_id,'session_end',j.session_end,'token',j.token,'request',j.request);
END $$;
CREATE FUNCTION finish_market_data_refresh(id_value bigint,end_value date,token_value uuid,bundle jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_refresh%ROWTYPE; src uuid; snapshot_value uuid;
BEGIN
 SELECT source_id INTO STRICT src FROM market_data_acquisition WHERE experiment_id=id_value;
 PERFORM 1 FROM market_data_source WHERE id=src FOR UPDATE;
 PERFORM pg_advisory_xact_lock(55001,hashtext((SELECT run_key FROM incubator_evaluation WHERE id=id_value)));
 PERFORM pg_advisory_xact_lock(59001,hashtext((SELECT run_key FROM incubator_evaluation WHERE id=id_value)));
 SELECT * INTO STRICT j FROM market_data_refresh WHERE experiment_id=id_value AND session_end=end_value FOR UPDATE;
 IF j.state<>'leased' OR j.token IS DISTINCT FROM token_value OR j.lease_until<=clock_timestamp() OR NOT market_data_research_active(id_value) OR NOT EXISTS(SELECT 1 FROM market_data_settings WHERE source_id=src AND enabled AND refresh_enabled) THEN RAISE EXCEPTION 'refresh_no_longer_active'; END IF;
 IF bundle->'request' IS DISTINCT FROM j.request THEN RAISE EXCEPTION 'request_changed'; END IF;
 snapshot_value:=register_market_data_download(src,bundle);
 UPDATE market_data_refresh SET state='completed',snapshot_id=snapshot_value,token=NULL WHERE experiment_id=id_value AND session_end=end_value;
END $$;
CREATE FUNCTION fail_market_data_refresh(id_value bigint,end_value date,token_value uuid) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 UPDATE market_data_refresh SET state='failed',error_code='refresh_failed',token=NULL WHERE experiment_id=id_value AND session_end=end_value AND state='leased' AND token=token_value
$$;
CREATE FUNCTION read_market_data_refresh_status() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('active_windows',(SELECT count(*) FROM market_data_acquisition WHERE state='completed' AND market_data_research_active(experiment_id)),'latest',(SELECT jsonb_build_object('session_end',session_end,'state',state,'error_code',error_code) FROM market_data_refresh ORDER BY session_end DESC,receipt_time DESC LIMIT 1))
$$;
REVOKE ALL ON FUNCTION setup_personal_market_data(boolean),read_market_data_settings(),change_market_data_settings(boolean,boolean),market_data_collection_enabled(uuid),market_data_calendar_sessions_v1(date,date),market_data_research_active(bigint),queue_market_data_refreshes(),claim_market_data_refresh(),finish_market_data_refresh(bigint,date,uuid,jsonb),fail_market_data_refresh(bigint,date,uuid),read_market_data_refresh_status(),queue_market_data_acquisitions(uuid),claim_market_data_acquisition(uuid),finish_market_data_acquisition(bigint,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION setup_personal_market_data(boolean),read_market_data_settings(),change_market_data_settings(boolean,boolean),queue_market_data_refreshes(),claim_market_data_refresh(),finish_market_data_refresh(bigint,date,uuid,jsonb),fail_market_data_refresh(bigint,date,uuid),read_market_data_refresh_status() TO market_data_service;
SELECT assert_all_evidence_table_conventions();

CREATE TABLE market_data_owner_request (
 experiment_id bigint PRIMARY KEY REFERENCES incubator_experiment_ticket(evaluation_id),request jsonb NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
SELECT register_evidence_table('market_data_owner_request');
CREATE TRIGGER market_data_owner_request_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON market_data_owner_request FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();
CREATE FUNCTION supply_market_data_request(id_value bigint,request_value jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE existing jsonb; e jsonb; lineage jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(58001,id_value::integer);
 SELECT request INTO existing FROM market_data_owner_request WHERE experiment_id=id_value;
 IF FOUND THEN IF existing IS DISTINCT FROM request_value THEN RAISE EXCEPTION 'request_already_pinned'; END IF;RETURN; END IF;
 e:=read_incubator_experiment(id_value);
 IF e->>'status' IS DISTINCT FROM 'awaiting_data' OR EXISTS(SELECT 1 FROM market_data_acquisition WHERE experiment_id=id_value) OR EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value) THEN RAISE EXCEPTION 'experiment_changed'; END IF;
 PERFORM expand_market_data_request(request_value,e->'detail'->'spec');
 SELECT source_lineage INTO STRICT lineage FROM incubator_experiment_ticket WHERE evaluation_id=id_value;
 INSERT INTO market_data_owner_request VALUES(id_value,request_value,lineage,now(),'local_research');
 PERFORM append_audit_event('market-data-owner-request:'||id_value,'research.market_data_requested',now(),jsonb_build_object('experiment_id',id_value),lineage,now(),'local_research');
 PERFORM pg_notify('incubator_experiment','changed');
END $$;
ALTER FUNCTION read_incubator_experiment(bigint) RENAME TO read_incubator_experiment_wu61;
CREATE FUNCTION read_incubator_experiment(id_value bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE e jsonb; request_value jsonb; BEGIN
 e:=read_incubator_experiment_wu61(id_value);
 SELECT request INTO request_value FROM market_data_owner_request WHERE experiment_id=id_value;
 IF request_value IS NOT NULL AND e->>'status'='awaiting_data' THEN e:=jsonb_set(e,'{detail,data_request}',request_value); END IF;
 RETURN e; END $$;
REVOKE ALL ON FUNCTION read_incubator_experiment_wu61(bigint) FROM PUBLIC,incubator_runner;
REVOKE ALL ON FUNCTION read_incubator_experiment(bigint),supply_market_data_request(bigint,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_experiment(bigint),supply_market_data_request(bigint,jsonb) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();

-- Cleanup runs once per UTC day even when collection is paused or unconfigured.
CREATE TABLE market_data_housekeeping (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), completed_day date NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL, record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
SELECT register_evidence_table('market_data_housekeeping');
REVOKE ALL ON market_data_housekeeping FROM PUBLIC;
CREATE FUNCTION run_market_data_housekeeping() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE day_value date := (clock_timestamp() AT TIME ZONE 'UTC')::date; n integer;
BEGIN
 PERFORM pg_advisory_xact_lock(63002,0);
 IF EXISTS(SELECT 1 FROM market_data_housekeeping WHERE completed_day>=day_value) THEN RETURN 0; END IF;
 n:=cleanup_market_data_cache();
 INSERT INTO market_data_housekeeping VALUES(true,day_value,'{"source":"market-data-housekeeping","entitlement_version":"local-maintenance-v1"}',clock_timestamp(),'local_research')
 ON CONFLICT(singleton) DO UPDATE SET completed_day=excluded.completed_day,receipt_time=excluded.receipt_time;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION run_market_data_housekeeping() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION run_market_data_housekeeping() TO market_data_service;
SELECT assert_all_evidence_table_conventions();
