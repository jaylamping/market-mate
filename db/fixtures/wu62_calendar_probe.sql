BEGIN;
CREATE FUNCTION pg_temp.check_calendar() RETURNS void LANGUAGE plpgsql AS $$
DECLARE d jsonb := '{"calendar":"XNYS_2025_2026_v1","symbols":["A","B","C","D"],"start":"2025-01-06","end":"2025-01-10","benchmark":"SPY","symbol_asof":"2025-01-10","cash":"zero_interest"}';
spec jsonb := '{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":2,"one_way_cost_bps":5,"borrow_bps_per_session":0}'; r jsonb;
BEGIN
 r:=expand_market_data_request(d,spec);
 IF r->'sessions' IS DISTINCT FROM '["2025-01-06","2025-01-07","2025-01-08","2025-01-10"]'::jsonb THEN RAISE EXCEPTION 'mourning closure not honored'; END IF;
 d:=d||'{"start":"2026-01-16","end":"2026-01-21"}';
 IF expand_market_data_request(d,spec)->'sessions' IS DISTINCT FROM '["2026-01-16","2026-01-20","2026-01-21"]'::jsonb THEN RAISE EXCEPTION 'holiday or weekend included'; END IF;
 d:=d||'{"start":"2025-11-26","end":"2025-12-01"}';
 IF expand_market_data_request(d,spec)->'sessions' IS DISTINCT FROM '["2025-11-26","2025-11-28","2025-12-01"]'::jsonb THEN RAISE EXCEPTION 'early close omitted'; END IF;
 BEGIN PERFORM expand_market_data_request(d||'{"start":"2024-12-27"}',spec); RAISE EXCEPTION 'accepted unsupported range' USING ERRCODE='XX001'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
 BEGIN PERFORM expand_market_data_request(d||'{"symbols":["A","A","C","D"]}',spec); RAISE EXCEPTION 'accepted duplicate symbol' USING ERRCODE='XX001'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
 BEGIN PERFORM expand_market_data_request(d,spec||'{"quantile_count":3}'); RAISE EXCEPTION 'accepted incompatible quantiles' USING ERRCODE='XX001'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END;
END $$;
SELECT pg_temp.check_calendar();
ROLLBACK;
