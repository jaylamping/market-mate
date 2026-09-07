-- On-demand Local Research acquisition. No trading or source certification authority.
CREATE ROLE market_data_acquirer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT USAGE ON SCHEMA public TO market_data_acquirer;
CREATE TABLE market_data_acquisition (
 experiment_id bigint PRIMARY KEY REFERENCES incubator_experiment_ticket(evaluation_id),
 source_id uuid NOT NULL REFERENCES market_data_source,
 request jsonb,
 calendar_version text NOT NULL DEFAULT 'XNYS_2025_2026_v1',
 state text NOT NULL CHECK(state IN ('queued','leased','retry_wait','failed','cancelled','completed')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
 lease_token uuid,
 lease_until timestamptz,
 next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 error_code text,
 snapshot_id uuid REFERENCES research_snapshot,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
SELECT register_evidence_table('market_data_acquisition');

-- Published NYSE 2025/2026 closures plus the January 9, 2025 mourning closure.
-- Early closes remain trading sessions. Version is frozen; unsupported years fail.
CREATE FUNCTION expand_market_data_request(d jsonb,spec jsonb) RETURNS jsonb
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
 SELECT jsonb_agg(day::date::text ORDER BY day) INTO sessions FROM generate_series(start_value::timestamp,end_value::timestamp,interval '1 day') day
 WHERE extract(isodow FROM day)<=5 AND day::date<>ALL(ARRAY['2025-01-01','2025-01-09','2025-01-20','2025-02-17','2025-04-18','2025-05-26','2025-06-19','2025-07-04','2025-09-01','2025-11-27','2025-12-25','2026-01-01','2026-01-19','2026-02-16','2026-04-03','2026-05-25','2026-06-19','2026-07-03','2026-09-07','2026-11-26','2026-12-25']::date[]);
 IF jsonb_typeof(spec) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(spec))<>5 OR spec->>'runner' IS DISTINCT FROM 'momentum_v1' THEN RAISE EXCEPTION 'invalid_spec'; END IF;
 FOREACH k IN ARRAY ARRAY['lookback_sessions','quantile_count','one_way_cost_bps','borrow_bps_per_session'] LOOP
  IF strategy_sandbox_integer(spec->k) IS NULL THEN RAISE EXCEPTION 'invalid_spec'; END IF;
 END LOOP;
 IF (spec->>'lookback_sessions')::int NOT BETWEEN 1 AND 5 OR (spec->>'quantile_count')::int NOT BETWEEN 2 AND 10 OR (spec->>'one_way_cost_bps')::int NOT BETWEEN 0 AND 100 OR (spec->>'borrow_bps_per_session')::int NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'invalid_spec'; END IF;
 IF coalesce(jsonb_array_length(sessions),0) NOT BETWEEN 3 AND 60 OR jsonb_array_length(sessions)<=(spec->>'lookback_sessions')::int+1 OR n%(spec->>'quantile_count')::int<>0 THEN RAISE EXCEPTION 'incompatible_panel_request'; END IF;
 RETURN jsonb_build_object('schema_version',1,'symbols',d->'symbols','sessions',sessions,'benchmark',d->'benchmark','symbol_asof',d->'symbol_asof','cash',d->'cash','spec',spec);
END $$;

CREATE FUNCTION queue_market_data_acquisitions(source_value uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE src market_data_source%ROWTYPE; t record; detail_value jsonb; request_value jsonb; failure text; n integer:=0;
BEGIN
 SELECT * INTO STRICT src FROM market_data_source WHERE id=source_value FOR UPDATE;
 IF NOT market_data_source_available(source_value) THEN RETURN 0; END IF;
 FOR t IN SELECT evaluation_id FROM incubator_experiment_ticket x WHERE NOT EXISTS(SELECT 1 FROM market_data_acquisition WHERE experiment_id=x.evaluation_id) AND NOT EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=x.evaluation_id) AND read_incubator_experiment(x.evaluation_id)->>'status'='awaiting_data' AND coalesce(read_incubator_experiment(x.evaluation_id)->'detail'->'data_request','null')<>'null'::jsonb ORDER BY evaluation_id LIMIT 32 LOOP
  PERFORM pg_advisory_xact_lock(58001,t.evaluation_id::integer);
  IF read_incubator_experiment(t.evaluation_id)->>'status' IS DISTINCT FROM 'awaiting_data' OR read_incubator_evaluation(t.evaluation_id)->>'status'='superseded' THEN CONTINUE; END IF;
  detail_value:=read_incubator_experiment(t.evaluation_id)->'detail';
  IF detail_value->'data_request' IS NULL OR detail_value->'data_request'='null' THEN CONTINUE; END IF;
  request_value:=NULL; failure:=NULL;
  BEGIN request_value:=expand_market_data_request(detail_value->'data_request',detail_value->'spec'); EXCEPTION WHEN OTHERS THEN failure:='invalid_setup_request'; END;
  INSERT INTO market_data_acquisition(experiment_id,source_id,request,state,error_code,source_lineage,receipt_time,record_environment)
   VALUES(t.evaluation_id,source_value,request_value,CASE WHEN failure IS NULL THEN 'queued' ELSE 'failed' END,failure,src.source_lineage,clock_timestamp(),'local_research') ON CONFLICT DO NOTHING;
  n:=n+1;
 END LOOP;
 RETURN n;
END $$;

CREATE FUNCTION claim_market_data_acquisition(source_value uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_acquisition%ROWTYPE;
BEGIN
 PERFORM 1 FROM market_data_source WHERE id=source_value FOR UPDATE;
 IF NOT market_data_source_available(source_value) THEN
  UPDATE market_data_acquisition SET state='failed',error_code='source_unavailable',lease_token=NULL,lease_until=NULL WHERE source_id=source_value AND state IN ('queued','leased','retry_wait'); RETURN NULL;
 END IF;
 UPDATE market_data_acquisition SET state='failed',error_code='attempt_budget_exhausted',lease_token=NULL WHERE source_id=source_value AND state='leased' AND lease_until<=clock_timestamp() AND attempts>=3;
 SELECT * INTO j FROM market_data_acquisition WHERE source_id=source_value AND attempts<3 AND ((state IN ('queued','retry_wait') AND next_attempt_at<=clock_timestamp()) OR (state='leased' AND lease_until<=clock_timestamp())) ORDER BY experiment_id FOR UPDATE SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF read_incubator_experiment(j.experiment_id)->>'status' IS DISTINCT FROM 'awaiting_data' OR read_incubator_evaluation(j.experiment_id)->>'status'='superseded' OR EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=j.experiment_id) THEN
  UPDATE market_data_acquisition SET state='cancelled',error_code='experiment_changed',lease_token=NULL WHERE experiment_id=j.experiment_id; RETURN NULL;
 END IF;
 UPDATE market_data_acquisition SET state='leased',attempts=attempts+1,lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '5 minutes',error_code=NULL WHERE experiment_id=j.experiment_id RETURNING * INTO j;
 RETURN jsonb_build_object('experiment_id',j.experiment_id,'lease_token',j.lease_token,'request',j.request);
END $$;

-- Reuse a complete symbol window from one same-day adjusted download, never splice
-- a symbol across adjustment vintages. Missing/partial symbols are fetched in full.
CREATE FUNCTION read_market_data_acquisition_cache(id_value bigint,token uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_acquisition%ROWTYPE; result jsonb;
BEGIN
 SELECT * INTO STRICT j FROM market_data_acquisition WHERE experiment_id=id_value AND state='leased' AND lease_token=token AND lease_until>statement_timestamp();
 IF NOT market_data_source_available(j.source_id) THEN RAISE EXCEPTION 'source_unavailable'; END IF;
 WITH names AS (SELECT DISTINCT value#>>'{}' symbol FROM jsonb_array_elements(j.request->'symbols'||jsonb_build_array(j.request->'benchmark'))),
 chosen AS (SELECT n.symbol,p.dataset_id FROM names n CROSS JOIN LATERAL (
 SELECT p.dataset_id FROM market_data_payload p JOIN market_data_dataset d ON d.id=p.dataset_id
 WHERE p.source_id=j.source_id AND d.removed_at IS NULL AND p.request->'symbol_asof'=j.request->'symbol_asof'
 AND (p.source_facts->>'received_at')::timestamptz AT TIME ZONE 'America/New_York'>=date_trunc('day',statement_timestamp() AT TIME ZONE 'America/New_York')
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(j.request->'sessions') s WHERE NOT EXISTS(SELECT 1 FROM market_data_dataset_observation x JOIN market_data_observation o ON o.id=x.observation_id WHERE x.dataset_id=p.dataset_id AND o.symbol=n.symbol AND o.session=s::date))
 ORDER BY d.receipt_time DESC,d.id LIMIT 1) p)
 SELECT coalesce(jsonb_agg(jsonb_build_object('symbol',o.symbol,'session',o.session,'bar',o.bar) ORDER BY o.symbol,o.session),'[]') INTO result
 FROM chosen c JOIN market_data_dataset_observation x ON x.dataset_id=c.dataset_id JOIN market_data_observation o ON o.id=x.observation_id AND o.symbol=c.symbol WHERE j.request->'sessions' ? o.session::text;
 RETURN result;
END $$;

CREATE FUNCTION finish_market_data_acquisition(id_value bigint,token uuid,bundle jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_acquisition%ROWTYPE; source_value uuid; snapshot_value uuid;
BEGIN
 SELECT source_id INTO STRICT source_value FROM market_data_acquisition WHERE experiment_id=id_value;
 PERFORM 1 FROM market_data_source WHERE id=source_value FOR UPDATE;
 SELECT * INTO STRICT j FROM market_data_acquisition WHERE experiment_id=id_value FOR UPDATE;
 IF j.state<>'leased' OR j.lease_token IS DISTINCT FROM token OR j.lease_until<=clock_timestamp() THEN RAISE EXCEPTION 'stale_acquisition_lease'; END IF;
 IF NOT market_data_source_available(source_value) THEN RAISE EXCEPTION 'source_unavailable'; END IF;
 PERFORM pg_advisory_xact_lock(58001,id_value::integer);
 PERFORM pg_advisory_xact_lock(55001,hashtext((SELECT run_key FROM incubator_evaluation WHERE id=id_value)));
 IF read_incubator_experiment(id_value)->>'status' IS DISTINCT FROM 'awaiting_data' OR read_incubator_evaluation(id_value)->>'status'='superseded' OR EXISTS(SELECT 1 FROM incubator_experiment_dataset WHERE experiment_id=id_value) THEN RAISE EXCEPTION 'experiment_changed'; END IF;
 IF bundle->'request' IS DISTINCT FROM j.request THEN RAISE EXCEPTION 'request_changed'; END IF;
 snapshot_value:=register_market_data_download(source_value,bundle);
 PERFORM bind_incubator_experiment_dataset(id_value,snapshot_value);
 UPDATE market_data_acquisition SET state='completed',snapshot_id=snapshot_value,lease_token=NULL,lease_until=NULL WHERE experiment_id=id_value;
 RETURN snapshot_value;
END $$;

CREATE FUNCTION fail_market_data_acquisition(id_value bigint,token uuid,code text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF code NOT IN ('Transport','RateLimited','ProviderUnavailable','AccessDenied','InvalidRequest','InvalidResponse','ResourceLimit','InvalidPrice','IncompleteCoverage','DuplicateObservation','UnexpectedObservation','IncompatiblePanel','ProviderRejected','commit_rejected','download_timeout') THEN RAISE EXCEPTION 'invalid_error_code'; END IF;
 UPDATE market_data_acquisition SET state=CASE WHEN code IN ('Transport','RateLimited','ProviderUnavailable','download_timeout') AND attempts<3 THEN 'retry_wait' ELSE 'failed' END,error_code=code,lease_token=NULL,lease_until=NULL,next_attempt_at=clock_timestamp()+interval '60 seconds' WHERE experiment_id=id_value AND state='leased' AND lease_token=token AND lease_until>clock_timestamp();
END $$;
CREATE FUNCTION control_market_data_acquisition(id_value bigint,action text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_acquisition%ROWTYPE; source_value uuid;
BEGIN
 SELECT source_id INTO STRICT source_value FROM market_data_acquisition WHERE experiment_id=id_value;
 PERFORM 1 FROM market_data_source WHERE id=source_value FOR UPDATE;
 SELECT * INTO STRICT j FROM market_data_acquisition WHERE experiment_id=id_value FOR UPDATE;
 IF action='cancel' AND j.state IN ('queued','leased','retry_wait','failed') THEN
  UPDATE market_data_acquisition SET state='cancelled',lease_token=NULL,lease_until=NULL WHERE experiment_id=id_value;
 ELSIF action='retry' AND j.state='failed' AND j.request IS NOT NULL AND j.attempts<3 AND market_data_source_available(source_value) THEN
  UPDATE market_data_acquisition SET state='queued',error_code=NULL,next_attempt_at=clock_timestamp() WHERE experiment_id=id_value;
 ELSE RAISE EXCEPTION 'acquisition_control_rejected'; END IF;
 PERFORM pg_notify('incubator_experiment','changed');
END $$;
CREATE FUNCTION read_market_data_acquisition(id_value bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT jsonb_build_object('state',CASE WHEN NOT market_data_source_available(source_id) THEN 'source_unavailable' ELSE state END,'attempts',attempts,'error_code',error_code,'request',request,'calendar_version',calendar_version,'source_id',source_id,'snapshot_id',snapshot_id) FROM market_data_acquisition WHERE experiment_id=id_value
$$;
CREATE FUNCTION audit_market_data_acquisition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 PERFORM append_audit_event('market-data-acquisition:'||NEW.experiment_id||':'||gen_random_uuid(),'research.market_data_acquisition',now(),jsonb_build_object('experiment_id',NEW.experiment_id,'source_id',NEW.source_id,'state',NEW.state,'attempts',NEW.attempts),NEW.source_lineage,now(),'local_research');
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION audit_market_data_acquisition() FROM PUBLIC;
CREATE TRIGGER market_data_acquisition_audit AFTER INSERT OR UPDATE ON market_data_acquisition FOR EACH ROW EXECUTE FUNCTION audit_market_data_acquisition();
CREATE TRIGGER market_data_acquisition_wakeup AFTER INSERT OR UPDATE ON market_data_acquisition FOR EACH ROW EXECUTE FUNCTION notify_incubator_experiment();
REVOKE ALL ON FUNCTION expand_market_data_request(jsonb,jsonb),queue_market_data_acquisitions(uuid),claim_market_data_acquisition(uuid),read_market_data_acquisition_cache(bigint,uuid),finish_market_data_acquisition(bigint,uuid,jsonb),fail_market_data_acquisition(bigint,uuid,text),control_market_data_acquisition(bigint,text),read_market_data_acquisition(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION queue_market_data_acquisitions(uuid),claim_market_data_acquisition(uuid),read_market_data_acquisition_cache(bigint,uuid),finish_market_data_acquisition(bigint,uuid,jsonb),fail_market_data_acquisition(bigint,uuid,text) TO market_data_acquirer;
GRANT EXECUTE ON FUNCTION read_market_data_acquisition(bigint),control_market_data_acquisition(bigint,text) TO incubator_runner;
SELECT assert_all_evidence_table_conventions();
