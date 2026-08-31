-- WU-34 Walk-forward engine: preregistered, disjoint chronological test
-- windows each >=250 trading days, with a purge gap and frozen placement
-- after results exist. Evaluation slices use a bounded sandbox path so the
-- WU-33 60-session / 64KiB cap remains fail-closed for ordinary snapshots.

CREATE FUNCTION strategy_sandbox_evaluate_program_bounded(
    spec_value jsonb,
    payload_value jsonb,
    max_sessions integer,
    max_payload_bytes integer
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    needs_sp500 boolean := false;
    allowed_payload text[];
    symbols text[];
    sessions text[];
    symbol text;
    session_text text;
    prev_session text;
    i integer;
    n integer;
    horizon integer;
    units integer;
    side_text text;
    signed integer;
    op_text text;
    threshold bigint;
    surprise bigint;
    entry_cents bigint;
    exit_cents bigint;
    return_bps bigint;
    trade_sum bigint := 0;
    trade_count integer := 0;
    sp_sum bigint := 0;
    mean_bps bigint;
    sp_mean bigint;
    cash_bps bigint := 0;
    trades jsonb := '[]'::jsonb;
    block jsonb;
    bar jsonb;
    earn jsonb;
BEGIN
    IF max_sessions IS NULL OR max_sessions < 2 OR max_sessions > 10000
       OR max_payload_bytes IS NULL OR max_payload_bytes < 1
       OR max_payload_bytes > 16777216 THEN
        RAISE EXCEPTION 'strategy sandbox resource bound is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT strategy_sandbox_program_is_executable(spec_value) THEN
        RAISE EXCEPTION
            'strategy dsl rules are not executable in the deterministic sandbox'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(payload_value) IS DISTINCT FROM 'object'
       OR strategy_sandbox_payload_is_forbidden(payload_value) THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot is credential-shaped or out of scope'
            USING ERRCODE = '22023';
    END IF;
    IF octet_length(payload_value::text) > max_payload_bytes THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot exceeds the resource bound'
            USING ERRCODE = '22023';
    END IF;

    SELECT bool_or(c IN ('sp500', 's&p_500', 'spx'))
    INTO needs_sp500
    FROM jsonb_array_elements_text(spec_value->'comparators') c;
    allowed_payload := ARRAY['symbols', 'sessions', 'eod', 'earnings'];
    IF needs_sp500 THEN
        allowed_payload := allowed_payload || ARRAY['sp500'];
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_object_keys(payload_value) k
        WHERE k <> ALL (allowed_payload)
    ) THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot contains out-of-scope keys'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(payload_value->'symbols') IS DISTINCT FROM 'array'
       OR jsonb_typeof(payload_value->'sessions') IS DISTINCT FROM 'array'
       OR jsonb_typeof(payload_value->'eod') IS DISTINCT FROM 'array'
       OR jsonb_typeof(payload_value->'earnings') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot is not admissible'
            USING ERRCODE = '22023';
    END IF;

    SELECT coalesce(array_agg(s ORDER BY ord), '{}')
    INTO symbols
    FROM jsonb_array_elements_text(payload_value->'symbols') WITH ORDINALITY AS t(s, ord);
    SELECT coalesce(array_agg(s ORDER BY ord), '{}')
    INTO sessions
    FROM jsonb_array_elements_text(payload_value->'sessions') WITH ORDINALITY AS t(s, ord);

    n := coalesce(cardinality(symbols), 0);
    IF n < 1 OR n > 32 OR n <> (
            SELECT count(DISTINCT s) FROM unnest(symbols) s
            WHERE coalesce(btrim(s), '') <> ''
        ) THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot exceeds the resource bound'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(symbols) s WHERE coalesce(btrim(s), '') = '') THEN
        RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
            USING ERRCODE = '22023';
    END IF;

    n := coalesce(cardinality(sessions), 0);
    IF n < 2 OR n > max_sessions THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot exceeds the resource bound'
            USING ERRCODE = '22023';
    END IF;
    prev_session := NULL;
    FOREACH session_text IN ARRAY sessions LOOP
        IF session_text IS NULL OR session_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
            RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
                USING ERRCODE = '22023';
        END IF;
        IF prev_session IS NOT NULL AND session_text <= prev_session THEN
            RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
                USING ERRCODE = '22023';
        END IF;
        prev_session := session_text;
    END LOOP;

    IF jsonb_array_length(payload_value->'eod') IS DISTINCT FROM cardinality(symbols) THEN
        RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
            USING ERRCODE = '22023';
    END IF;
    FOREACH symbol IN ARRAY symbols LOOP
        SELECT count(*) INTO i
        FROM jsonb_array_elements(payload_value->'eod') AS e(block)
        WHERE e.block->>'symbol' = symbol;
        IF i <> 1 THEN
            RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
                USING ERRCODE = '22023';
        END IF;
        FOREACH session_text IN ARRAY sessions LOOP
            PERFORM strategy_sandbox_close_cents(payload_value, symbol, session_text);
        END LOOP;
    END LOOP;
    FOR block IN SELECT jsonb_array_elements(payload_value->'eod') LOOP
        IF jsonb_typeof(block) IS DISTINCT FROM 'object'
           OR jsonb_typeof(block->'bars') IS DISTINCT FROM 'array'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(block) k
                WHERE k NOT IN ('symbol', 'bars')
           ) THEN
            RAISE EXCEPTION
                'strategy sandbox snapshot contains out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
        FOR bar IN SELECT jsonb_array_elements(block->'bars') LOOP
            IF jsonb_typeof(bar) IS DISTINCT FROM 'object'
               OR EXISTS (
                    SELECT 1 FROM jsonb_object_keys(bar) k
                    WHERE k NOT IN ('session', 'close_cents')
               ) THEN
                RAISE EXCEPTION
                    'strategy sandbox snapshot contains out-of-scope keys'
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;
    END LOOP;
    FOR earn IN SELECT jsonb_array_elements(payload_value->'earnings') LOOP
        IF jsonb_typeof(earn) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(earn) k
                WHERE k NOT IN ('symbol', 'as_of_session', 'earnings_surprise_bps')
           ) THEN
            RAISE EXCEPTION
                'strategy sandbox snapshot contains out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
        IF earn->>'symbol' IS NULL
           OR earn->>'symbol' <> ALL (symbols) THEN
            RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF needs_sp500 THEN
        IF jsonb_typeof(payload_value->'sp500') IS DISTINCT FROM 'object'
           OR jsonb_typeof(payload_value->'sp500'->'bars') IS DISTINCT FROM 'array'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(payload_value->'sp500') k
                WHERE k NOT IN ('bars')
           ) THEN
            RAISE EXCEPTION
                'strategy sandbox snapshot is not admissible'
                USING ERRCODE = '22023';
        END IF;
        FOR bar IN SELECT jsonb_array_elements(payload_value->'sp500'->'bars') LOOP
            IF jsonb_typeof(bar) IS DISTINCT FROM 'object'
               OR EXISTS (
                    SELECT 1 FROM jsonb_object_keys(bar) k
                    WHERE k NOT IN ('session', 'close_cents')
               ) THEN
                RAISE EXCEPTION
                    'strategy sandbox snapshot contains out-of-scope keys'
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;
        FOREACH session_text IN ARRAY sessions LOOP
            PERFORM strategy_sandbox_close_cents(
                jsonb_build_object(
                    'eod', jsonb_build_array(
                        jsonb_build_object(
                            'symbol', 'sp500',
                            'bars', payload_value->'sp500'->'bars'
                        )
                    )
                ),
                'sp500',
                session_text
            );
        END LOOP;
    END IF;

    horizon := strategy_sandbox_integer(spec_value->'rules'->'exit'->'horizon_sessions');
    units := strategy_sandbox_integer(spec_value->'rules'->'sizing'->'units');
    side_text := btrim(spec_value->'rules'->'entry'->>'side');
    signed := CASE side_text WHEN 'long' THEN 1 ELSE -1 END;
    op_text := btrim(spec_value->'rules'->'entry'->>'op');
    threshold := strategy_sandbox_integer(spec_value->'rules'->'entry'->'threshold');
    IF cardinality(sessions) <= horizon THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot exceeds the resource bound'
            USING ERRCODE = '22023';
    END IF;

    FOR i IN 1 .. (cardinality(sessions) - horizon) LOOP
        FOREACH symbol IN ARRAY symbols LOOP
            surprise := strategy_sandbox_surprise_bps(
                payload_value, symbol, sessions[i]);
            IF surprise IS NULL THEN
                CONTINUE;
            END IF;
            IF strategy_sandbox_predicate(surprise, op_text, threshold)
                  IS DISTINCT FROM true THEN
                CONTINUE;
            END IF;
            entry_cents := strategy_sandbox_close_cents(
                payload_value, symbol, sessions[i]);
            exit_cents := strategy_sandbox_close_cents(
                payload_value, symbol, sessions[i + horizon]);
            return_bps := signed * units
                * (exit_cents - entry_cents) * 10000 / entry_cents;
            trades := trades || jsonb_build_array(
                jsonb_build_object(
                    'symbol', symbol,
                    'entry_session', sessions[i],
                    'exit_session', sessions[i + horizon],
                    'side', side_text,
                    'units', units,
                    'return_bps', return_bps
                )
            );
            trade_sum := trade_sum + return_bps;
            trade_count := trade_count + 1;
            IF needs_sp500 THEN
                sp_sum := sp_sum + (
                    units * (
                        strategy_sandbox_close_cents(
                            jsonb_build_object(
                                'eod', jsonb_build_array(
                                    jsonb_build_object(
                                        'symbol', 'sp500',
                                        'bars', payload_value->'sp500'->'bars'
                                    )
                                )
                            ),
                            'sp500',
                            sessions[i + horizon]
                        )
                        - strategy_sandbox_close_cents(
                            jsonb_build_object(
                                'eod', jsonb_build_array(
                                    jsonb_build_object(
                                        'symbol', 'sp500',
                                        'bars', payload_value->'sp500'->'bars'
                                    )
                                )
                            ),
                            'sp500',
                            sessions[i]
                        )
                    ) * 10000
                    / strategy_sandbox_close_cents(
                        jsonb_build_object(
                            'eod', jsonb_build_array(
                                jsonb_build_object(
                                    'symbol', 'sp500',
                                    'bars', payload_value->'sp500'->'bars'
                                )
                            )
                        ),
                        'sp500',
                        sessions[i]
                    )
                );
            END IF;
        END LOOP;
    END LOOP;

    IF trade_count = 0 THEN
        mean_bps := 0;
        sp_mean := 0;
    ELSE
        mean_bps := trade_sum / trade_count;
        sp_mean := CASE WHEN needs_sp500 THEN sp_sum / trade_count ELSE 0 END;
    END IF;

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'engine_kind', 'deterministic_dsl',
            'target', 'earnings_direction',
            'trade_count', trade_count,
            'mean_return_bps', mean_bps,
            'cash_return_bps', cash_bps,
            'excess_vs_cash_bps', mean_bps - cash_bps,
            'sp500_return_bps', CASE WHEN needs_sp500 THEN sp_mean ELSE NULL END,
            'excess_vs_sp500_bps',
                CASE WHEN needs_sp500 THEN mean_bps - sp_mean ELSE NULL END,
            'trades', trades
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION strategy_sandbox_evaluate_program(
    spec_value jsonb,
    payload_value jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    RETURN strategy_sandbox_evaluate_program_bounded(
        spec_value, payload_value, 60, 65536);
END;
$$;

CREATE FUNCTION walk_forward_parse_session_date(node jsonb)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    text_value text;
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'string' THEN
        RETURN NULL;
    END IF;
    text_value := btrim(node #>> '{}');
    IF text_value IS NULL OR text_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RETURN NULL;
    END IF;
    RETURN text_value::date;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE FUNCTION walk_forward_positive_int(node jsonb, min_value integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n numeric;
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'number' THEN
        RETURN NULL;
    END IF;
    n := node::numeric;
    IF n IS NULL OR n <> floor(n) OR n < min_value OR n > 2147483647 THEN
        RETURN NULL;
    END IF;
    RETURN n::integer;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE FUNCTION walk_forward_calendar_dates_are_valid(session_dates_value date[])
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    i integer;
BEGIN
    n := coalesce(cardinality(session_dates_value), 0);
    IF n < 1 THEN
        RETURN false;
    END IF;
    IF array_position(session_dates_value, NULL) IS NOT NULL THEN
        RETURN false;
    END IF;
    FOR i IN 1 .. n - 1 LOOP
        IF session_dates_value[i] >= session_dates_value[i + 1] THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION walk_forward_sessions_in_range(
    session_dates_value date[],
    start_date date,
    end_date date
) RETURNS date[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN start_date IS NULL OR end_date IS NULL OR start_date > end_date THEN NULL
        ELSE (
            SELECT coalesce(array_agg(d ORDER BY d), '{}')
            FROM unnest(session_dates_value) AS d
            WHERE d >= start_date AND d <= end_date
        )
    END;
$$;

CREATE FUNCTION walk_forward_calendar_digest(session_dates_value date[])
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-walk-forward-calendar-v1|' || coalesce((
                SELECT jsonb_agg(to_char(d, 'YYYY-MM-DD') ORDER BY d)::text
                FROM unnest(session_dates_value) AS d
            ), '[]'),
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION walk_forward_plan_digest(plan_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-walk-forward-plan-v1|' || plan_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION walk_forward_manifest_digest(manifest_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-walk-forward-manifest-v1|' || manifest_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION walk_forward_assert_payload_scope(payload_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    block jsonb;
    bar jsonb;
    earn jsonb;
    allowed_payload text[] := ARRAY['symbols', 'sessions', 'eod', 'earnings', 'sp500'];
BEGIN
    IF jsonb_typeof(payload_value) IS DISTINCT FROM 'object'
       OR strategy_sandbox_payload_is_forbidden(payload_value) THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot is credential-shaped or out of scope'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_object_keys(payload_value) k
        WHERE k <> ALL (allowed_payload)
    ) THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot contains out-of-scope keys'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(payload_value->'symbols') IS DISTINCT FROM 'array'
       OR jsonb_typeof(payload_value->'sessions') IS DISTINCT FROM 'array'
       OR jsonb_typeof(payload_value->'eod') IS DISTINCT FROM 'array'
       OR jsonb_typeof(payload_value->'earnings') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(payload_value->'sessions') AS sess
        WHERE jsonb_typeof(sess) IS DISTINCT FROM 'string'
           OR coalesce(sess #>> '{}', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    ) THEN
        RAISE EXCEPTION 'strategy sandbox snapshot is not admissible'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(payload_value->'eod') = 'array' THEN
        FOR block IN SELECT jsonb_array_elements(payload_value->'eod') LOOP
            IF jsonb_typeof(block) IS DISTINCT FROM 'object'
               OR EXISTS (
                    SELECT 1 FROM jsonb_object_keys(block) k
                    WHERE k NOT IN ('symbol', 'bars')
               ) THEN
                RAISE EXCEPTION
                    'strategy sandbox snapshot contains out-of-scope keys'
                    USING ERRCODE = '22023';
            END IF;
            IF jsonb_typeof(block->'bars') = 'array' THEN
                FOR bar IN SELECT jsonb_array_elements(block->'bars') LOOP
                    IF jsonb_typeof(bar) IS DISTINCT FROM 'object'
                       OR EXISTS (
                            SELECT 1 FROM jsonb_object_keys(bar) k
                            WHERE k NOT IN ('session', 'close_cents')
                       ) THEN
                        RAISE EXCEPTION
                            'strategy sandbox snapshot contains out-of-scope keys'
                            USING ERRCODE = '22023';
                    END IF;
                END LOOP;
            END IF;
        END LOOP;
    END IF;
    IF jsonb_typeof(payload_value->'earnings') = 'array' THEN
        FOR earn IN SELECT jsonb_array_elements(payload_value->'earnings') LOOP
            IF jsonb_typeof(earn) IS DISTINCT FROM 'object'
               OR EXISTS (
                    SELECT 1 FROM jsonb_object_keys(earn) k
                    WHERE k NOT IN (
                        'symbol', 'as_of_session', 'earnings_surprise_bps'
                    )
               ) THEN
                RAISE EXCEPTION
                    'strategy sandbox snapshot contains out-of-scope keys'
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;
    END IF;
    IF payload_value ? 'sp500' THEN
        IF jsonb_typeof(payload_value->'sp500') IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(payload_value->'sp500') k
                WHERE k NOT IN ('bars')
           ) THEN
            RAISE EXCEPTION
                'strategy sandbox snapshot contains out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
        IF jsonb_typeof(payload_value->'sp500'->'bars') = 'array' THEN
            FOR bar IN SELECT jsonb_array_elements(payload_value->'sp500'->'bars') LOOP
                IF jsonb_typeof(bar) IS DISTINCT FROM 'object'
                   OR EXISTS (
                        SELECT 1 FROM jsonb_object_keys(bar) k
                        WHERE k NOT IN ('session', 'close_cents')
                   ) THEN
                    RAISE EXCEPTION
                        'strategy sandbox snapshot contains out-of-scope keys'
                        USING ERRCODE = '22023';
                END IF;
            END LOOP;
        END IF;
    END IF;
END;
$$;

CREATE FUNCTION walk_forward_slice_payload(
    payload_value jsonb,
    session_dates_value date[]
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    sessions_json jsonb;
    eod_json jsonb;
    earnings_json jsonb;
    sp500_json jsonb;
    session_texts text[];
BEGIN
    IF jsonb_typeof(payload_value) IS DISTINCT FROM 'object'
       OR NOT walk_forward_calendar_dates_are_valid(session_dates_value) THEN
        RAISE EXCEPTION 'walk-forward snapshot slice is not admissible'
            USING ERRCODE = '22023';
    END IF;
    PERFORM walk_forward_assert_payload_scope(payload_value);

    SELECT coalesce(array_agg(to_char(d, 'YYYY-MM-DD') ORDER BY d), '{}')
    INTO session_texts
    FROM unnest(session_dates_value) AS d;

    SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY ord), '[]'::jsonb)
    INTO sessions_json
    FROM unnest(session_texts) WITH ORDINALITY AS t(s, ord);

    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'symbol', block->>'symbol',
            'bars', coalesce((
                SELECT jsonb_agg(bar ORDER BY bar->>'session')
                FROM jsonb_array_elements(block->'bars') AS bar
                WHERE bar->>'session' = ANY (session_texts)
            ), '[]'::jsonb)
        )
        ORDER BY ord
    ), '[]'::jsonb)
    INTO eod_json
    FROM jsonb_array_elements(payload_value->'eod') WITH ORDINALITY AS t(block, ord);

    SELECT coalesce(jsonb_agg(earn ORDER BY ord), '[]'::jsonb)
    INTO earnings_json
    FROM jsonb_array_elements(payload_value->'earnings') WITH ORDINALITY AS t(earn, ord)
    WHERE earn->>'as_of_session' = ANY (session_texts);

    IF payload_value ? 'sp500' THEN
        sp500_json := jsonb_build_object(
            'bars', coalesce((
                SELECT jsonb_agg(bar ORDER BY bar->>'session')
                FROM jsonb_array_elements(payload_value->'sp500'->'bars') AS bar
                WHERE bar->>'session' = ANY (session_texts)
            ), '[]'::jsonb)
        );
        RETURN jsonb_build_object(
            'symbols', payload_value->'symbols',
            'sessions', sessions_json,
            'eod', eod_json,
            'earnings', earnings_json,
            'sp500', sp500_json
        );
    END IF;

    RETURN jsonb_build_object(
        'symbols', payload_value->'symbols',
        'sessions', sessions_json,
        'eod', eod_json,
        'earnings', earnings_json
    );
END;
$$;

CREATE FUNCTION walk_forward_compile_plan(
    spec_value jsonb,
    session_dates_value date[]
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    windows_node jsonb;
    folds_node jsonb;
    fold jsonb;
    walk_count integer;
    holdout_count integer;
    purge_gap integer;
    n_calendar integer;
    holdout_dates date[];
    holdout_start date;
    holdout_end date;
    train_start date;
    train_end date;
    purge_start date;
    purge_end date;
    test_start date;
    test_end date;
    train_dates date[];
    purge_dates date[];
    test_dates date[];
    prev_test_end date;
    compiled_folds jsonb := '[]'::jsonb;
    i integer;
    window_index integer;
BEGIN
    IF NOT walk_forward_calendar_dates_are_valid(session_dates_value) THEN
        RAISE EXCEPTION 'walk-forward calendar is not admissible'
            USING ERRCODE = '22023';
    END IF;

    windows_node := experiment_preregistration_spec_node(
        spec_value, 'windows', 'window');
    IF jsonb_typeof(windows_node) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(windows_node) k
            WHERE k NOT IN (
                'walk_forward', 'holdout_sessions', 'purge_gap_sessions', 'folds'
            )
       ) THEN
        RAISE EXCEPTION 'walk-forward windows are not preregistered'
            USING ERRCODE = '22023';
    END IF;

    walk_count := walk_forward_positive_int(windows_node->'walk_forward', 3);
    holdout_count := walk_forward_positive_int(windows_node->'holdout_sessions', 60);
    purge_gap := walk_forward_positive_int(windows_node->'purge_gap_sessions', 1);
    folds_node := windows_node->'folds';
    IF walk_count IS NULL OR holdout_count IS NULL OR purge_gap IS NULL
       OR jsonb_typeof(folds_node) IS DISTINCT FROM 'array'
       OR jsonb_array_length(folds_node) IS DISTINCT FROM walk_count THEN
        RAISE EXCEPTION 'walk-forward windows are not preregistered'
            USING ERRCODE = '22023';
    END IF;

    n_calendar := cardinality(session_dates_value);
    IF n_calendar < holdout_count THEN
        RAISE EXCEPTION 'walk-forward windows overlap the release holdout'
            USING ERRCODE = '22023';
    END IF;
    holdout_dates := session_dates_value[
        (n_calendar - holdout_count + 1):n_calendar];
    holdout_start := holdout_dates[1];
    holdout_end := holdout_dates[holdout_count];

    prev_test_end := NULL;
    FOR i IN 0 .. walk_count - 1 LOOP
        fold := folds_node->i;
        window_index := i + 1;
        IF jsonb_typeof(fold) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(fold) k
                WHERE k NOT IN (
                    'train_start', 'train_end', 'purge_start', 'purge_end',
                    'test_start', 'test_end'
                )
           ) THEN
            RAISE EXCEPTION 'walk-forward windows are not preregistered'
                USING ERRCODE = '22023';
        END IF;

        train_start := walk_forward_parse_session_date(fold->'train_start');
        train_end := walk_forward_parse_session_date(fold->'train_end');
        purge_start := walk_forward_parse_session_date(fold->'purge_start');
        purge_end := walk_forward_parse_session_date(fold->'purge_end');
        test_start := walk_forward_parse_session_date(fold->'test_start');
        test_end := walk_forward_parse_session_date(fold->'test_end');
        IF train_start IS NULL OR train_end IS NULL
           OR purge_start IS NULL OR purge_end IS NULL
           OR test_start IS NULL OR test_end IS NULL THEN
            RAISE EXCEPTION 'walk-forward windows are not preregistered'
                USING ERRCODE = '22023';
        END IF;

        train_dates := walk_forward_sessions_in_range(
            session_dates_value, train_start, train_end);
        purge_dates := walk_forward_sessions_in_range(
            session_dates_value, purge_start, purge_end);
        test_dates := walk_forward_sessions_in_range(
            session_dates_value, test_start, test_end);

        IF cardinality(train_dates) < 1
           OR train_dates[1] IS DISTINCT FROM train_start
           OR train_dates[cardinality(train_dates)] IS DISTINCT FROM train_end THEN
            RAISE EXCEPTION 'walk-forward windows are not preregistered'
                USING ERRCODE = '22023';
        END IF;
        IF cardinality(purge_dates) < purge_gap
           OR purge_dates[1] IS DISTINCT FROM purge_start
           OR purge_dates[cardinality(purge_dates)] IS DISTINCT FROM purge_end THEN
            RAISE EXCEPTION 'walk-forward purge gap is missing or leaked'
                USING ERRCODE = '22023';
        END IF;
        IF cardinality(test_dates) < 250
           OR test_dates[1] IS DISTINCT FROM test_start
           OR test_dates[cardinality(test_dates)] IS DISTINCT FROM test_end THEN
            RAISE EXCEPTION
                'walk-forward test window is shorter than 250 trading days'
                USING ERRCODE = '22023';
        END IF;
        IF cardinality(test_dates) > 2000 THEN
            RAISE EXCEPTION
                'strategy sandbox snapshot exceeds the resource bound'
                USING ERRCODE = '22023';
        END IF;

        IF train_dates[cardinality(train_dates)] >= purge_dates[1]
           OR purge_dates[cardinality(purge_dates)] >= test_dates[1] THEN
            RAISE EXCEPTION 'walk-forward purge gap is missing or leaked'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
                SELECT 1 FROM unnest(train_dates) d WHERE d = ANY (test_dates)
            )
           OR EXISTS (
                SELECT 1 FROM unnest(train_dates) d WHERE d = ANY (purge_dates)
            )
           OR EXISTS (
                SELECT 1 FROM unnest(test_dates) d WHERE d = ANY (purge_dates)
            ) THEN
            RAISE EXCEPTION 'walk-forward train and test overlap'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
                SELECT 1 FROM unnest(train_dates || purge_dates || test_dates) d
                WHERE d >= holdout_start
            ) THEN
            RAISE EXCEPTION 'walk-forward windows overlap the release holdout'
                USING ERRCODE = '22023';
        END IF;
        IF prev_test_end IS NOT NULL AND test_dates[1] <= prev_test_end THEN
            RAISE EXCEPTION 'walk-forward windows are not disjoint'
                USING ERRCODE = '22023';
        END IF;

        compiled_folds := compiled_folds || jsonb_build_array(
            jsonb_build_object(
                'window_index', window_index,
                'train_start', to_char(train_start, 'YYYY-MM-DD'),
                'train_end', to_char(train_end, 'YYYY-MM-DD'),
                'train_sessions', cardinality(train_dates),
                'purge_start', to_char(purge_start, 'YYYY-MM-DD'),
                'purge_end', to_char(purge_end, 'YYYY-MM-DD'),
                'purge_sessions', cardinality(purge_dates),
                'test_start', to_char(test_start, 'YYYY-MM-DD'),
                'test_end', to_char(test_end, 'YYYY-MM-DD'),
                'test_sessions', cardinality(test_dates)
            )
        );
        prev_test_end := test_dates[cardinality(test_dates)];
    END LOOP;

    RETURN jsonb_build_object(
        'walk_forward', walk_count,
        'holdout_sessions', holdout_count,
        'purge_gap_sessions', purge_gap,
        'holdout_start', to_char(holdout_start, 'YYYY-MM-DD'),
        'holdout_end', to_char(holdout_end, 'YYYY-MM-DD'),
        'folds', compiled_folds
    );
END;
$$;

CREATE TABLE walk_forward_calendar (
    calendar_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_dates date[] NOT NULL,
    session_count integer NOT NULL CHECK (session_count >= 1),
    first_trading_date date NOT NULL,
    last_trading_date date NOT NULL,
    calendar_digest text NOT NULL CHECK (calendar_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (session_count = cardinality(session_dates)),
    CHECK (session_dates[1] = first_trading_date),
    CHECK (session_dates[session_count] = last_trading_date),
    CHECK (walk_forward_calendar_dates_are_valid(session_dates)),
    CHECK (calendar_digest = walk_forward_calendar_digest(session_dates)),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('walk_forward_calendar');

CREATE UNIQUE INDEX walk_forward_calendar_digest_uq
    ON walk_forward_calendar (calendar_digest);

CREATE TABLE walk_forward_run (
    run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_version_id uuid NOT NULL
        REFERENCES strategy_version(strategy_version_id),
    registration_id uuid NOT NULL
        REFERENCES experiment_preregistration(registration_id),
    calendar_id uuid NOT NULL
        REFERENCES walk_forward_calendar(calendar_id),
    snapshot_id uuid NOT NULL
        REFERENCES research_snapshot(snapshot_id),
    window_plan jsonb NOT NULL CHECK (jsonb_typeof(window_plan) = 'object'),
    window_plan_digest text NOT NULL CHECK (window_plan_digest ~ '^[0-9a-f]{64}$'),
    manifest jsonb NOT NULL CHECK (jsonb_typeof(manifest) = 'object'),
    manifest_digest text NOT NULL CHECK (manifest_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (window_plan_digest = walk_forward_plan_digest(window_plan)),
    CHECK (manifest_digest = walk_forward_manifest_digest(manifest)),
    CHECK (record_environment = 'local_research'),
    UNIQUE (strategy_version_id)
);

SELECT register_evidence_table('walk_forward_run');

CREATE INDEX walk_forward_run_registration_idx
    ON walk_forward_run (registration_id, receipt_time);

CREATE FUNCTION guard_walk_forward_calendar_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'walk_forward_calendar is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER walk_forward_calendar_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON walk_forward_calendar
    FOR EACH STATEMENT EXECUTE FUNCTION guard_walk_forward_calendar_write();

CREATE FUNCTION guard_walk_forward_calendar_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.walk_forward_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            'walk_forward_calendar writes must go through register_walk_forward_calendar'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER walk_forward_calendar_insert_guard
    BEFORE INSERT ON walk_forward_calendar
    FOR EACH ROW EXECUTE FUNCTION guard_walk_forward_calendar_insert();

CREATE FUNCTION guard_walk_forward_run_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'walk_forward_run is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER walk_forward_run_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON walk_forward_run
    FOR EACH STATEMENT EXECUTE FUNCTION guard_walk_forward_run_write();

CREATE FUNCTION guard_walk_forward_run_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.walk_forward_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            'walk_forward_run writes must go through record_walk_forward_run'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER walk_forward_run_insert_guard
    BEFORE INSERT ON walk_forward_run
    FOR EACH ROW EXECUTE FUNCTION guard_walk_forward_run_insert();

CREATE FUNCTION register_walk_forward_calendar(
    session_dates_value date[],
    source_lineage_value jsonb
) RETURNS walk_forward_calendar
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    digest_value text;
    existing walk_forward_calendar%ROWTYPE;
    created walk_forward_calendar%ROWTYPE;
    n integer;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value)
       OR NOT walk_forward_calendar_dates_are_valid(session_dates_value) THEN
        RAISE EXCEPTION 'walk-forward calendar arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    n := cardinality(session_dates_value);
    digest_value := walk_forward_calendar_digest(session_dates_value);
    PERFORM pg_advisory_xact_lock(hashtextextended(digest_value, 36023));

    SELECT * INTO existing
    FROM walk_forward_calendar
    WHERE calendar_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.walk_forward_write', 'on', true);
    BEGIN
        INSERT INTO walk_forward_calendar (
            session_dates, session_count, first_trading_date, last_trading_date,
            calendar_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            session_dates_value, n, session_dates_value[1], session_dates_value[n],
            digest_value, source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.walk_forward_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.walk_forward_write', 'off', true);

    RETURN created;
END;
$$;

CREATE FUNCTION record_walk_forward_run(
    strategy_version_id_value uuid,
    calendar_id_value uuid,
    snapshot_id_value uuid,
    source_lineage_value jsonb
) RETURNS walk_forward_run
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row strategy_version%ROWTYPE;
    registration_row experiment_preregistration%ROWTYPE;
    calendar_row walk_forward_calendar%ROWTYPE;
    snapshot_row research_snapshot%ROWTYPE;
    plan_value jsonb;
    plan_digest_value text;
    fold jsonb;
    test_dates date[];
    sliced jsonb;
    eval_result jsonb;
    eval_digest text;
    fold_results jsonb := '[]'::jsonb;
    trade jsonb;
    train_dates date[];
    purge_dates date[];
    payload_sessions text[];
    test_session_texts text[];
    session_text text;
    manifest_value jsonb;
    manifest_digest_value text;
    existing walk_forward_run%ROWTYPE;
    created walk_forward_run%ROWTYPE;
BEGIN
    IF strategy_version_id_value IS NULL
       OR calendar_id_value IS NULL
       OR snapshot_id_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'walk-forward run arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO version_row
    FROM strategy_version
    WHERE strategy_version_id = strategy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'strategy version % is not registered',
            strategy_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF version_row.lifecycle_state IS DISTINCT FROM 'frozen'
       OR version_row.record_environment IS DISTINCT FROM 'local_research'
       OR lower(btrim(version_row.engine_binding->>'engine_kind'))
            IS DISTINCT FROM 'deterministic_dsl' THEN
        RAISE EXCEPTION
            'walk-forward can evaluate only a frozen deterministic DSL Strategy Version'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO registration_row
    FROM experiment_preregistration
    WHERE registration_id = version_row.registration_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'experiment preregistration % is not registered',
            version_row.registration_id
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO calendar_row
    FROM walk_forward_calendar
    WHERE calendar_id = calendar_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'walk-forward calendar % is not registered',
            calendar_id_value
            USING ERRCODE = '22023';
    END IF;
    IF calendar_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'walk-forward can use only a Local Research calendar'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO snapshot_row
    FROM research_snapshot
    WHERE snapshot_id = snapshot_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research snapshot % is not registered', snapshot_id_value
            USING ERRCODE = '22023';
    END IF;
    IF snapshot_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'walk-forward can evaluate only a Local Research snapshot'
            USING ERRCODE = '22023';
    END IF;

    plan_value := walk_forward_compile_plan(
        registration_row.spec, calendar_row.session_dates);
    plan_digest_value := walk_forward_plan_digest(plan_value);

    SELECT coalesce(array_agg(s ORDER BY ord), '{}')
    INTO payload_sessions
    FROM jsonb_array_elements_text(snapshot_row.payload->'sessions')
        WITH ORDINALITY AS t(s, ord);

    FOR fold IN SELECT jsonb_array_elements(plan_value->'folds') LOOP
        test_dates := walk_forward_sessions_in_range(
            calendar_row.session_dates,
            (fold->>'test_start')::date,
            (fold->>'test_end')::date);
        train_dates := walk_forward_sessions_in_range(
            calendar_row.session_dates,
            (fold->>'train_start')::date,
            (fold->>'train_end')::date);
        purge_dates := walk_forward_sessions_in_range(
            calendar_row.session_dates,
            (fold->>'purge_start')::date,
            (fold->>'purge_end')::date);

        SELECT coalesce(array_agg(to_char(d, 'YYYY-MM-DD') ORDER BY d), '{}')
        INTO test_session_texts
        FROM unnest(test_dates) AS d;
        FOREACH session_text IN ARRAY test_session_texts LOOP
            IF session_text <> ALL (payload_sessions) THEN
                RAISE EXCEPTION
                    'walk-forward snapshot is missing test session %',
                    session_text
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;

        sliced := walk_forward_slice_payload(snapshot_row.payload, test_dates);

        IF EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(sliced->'sessions') s
                WHERE s::date = ANY (train_dates) OR s::date = ANY (purge_dates)
            )
           OR EXISTS (
                SELECT 1
                FROM jsonb_array_elements(sliced->'earnings') e
                WHERE (e->>'as_of_session')::date = ANY (train_dates)
                   OR (e->>'as_of_session')::date = ANY (purge_dates)
            ) THEN
            RAISE EXCEPTION 'walk-forward purge gap is missing or leaked'
                USING ERRCODE = '22023';
        END IF;

        eval_result := strategy_sandbox_evaluate_program_bounded(
            version_row.spec, sliced, 2000, 1048576);
        eval_digest := strategy_sandbox_result_digest(eval_result);

        FOR trade IN SELECT jsonb_array_elements(
                coalesce(eval_result->'trades', '[]'::jsonb)
            ) LOOP
            IF (trade->>'entry_session')::date <> ALL (test_dates)
               OR (trade->>'exit_session')::date <> ALL (test_dates)
               OR (trade->>'entry_session')::date = ANY (train_dates)
               OR (trade->>'exit_session')::date = ANY (train_dates)
               OR (trade->>'entry_session')::date = ANY (purge_dates)
               OR (trade->>'exit_session')::date = ANY (purge_dates) THEN
                RAISE EXCEPTION 'walk-forward purge gap is missing or leaked'
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;

        fold_results := fold_results || jsonb_build_array(
            jsonb_build_object(
                'window_index', (fold->>'window_index')::integer,
                'test_sessions', (fold->>'test_sessions')::integer,
                'result', eval_result,
                'result_digest', eval_digest
            )
        );
    END LOOP;

    manifest_value := jsonb_build_object(
        'engine', 'walk_forward_v1',
        'strategy_version_id', strategy_version_id_value,
        'registration_id', version_row.registration_id,
        'calendar_id', calendar_id_value,
        'calendar_digest', calendar_row.calendar_digest,
        'snapshot_id', snapshot_id_value,
        'window_plan', plan_value,
        'folds', fold_results
    );
    manifest_digest_value := walk_forward_manifest_digest(manifest_value);

    PERFORM pg_advisory_xact_lock(
        hashtextextended(strategy_version_id_value::text, 36024));

    SELECT * INTO existing
    FROM walk_forward_run
    WHERE strategy_version_id = strategy_version_id_value;
    IF FOUND THEN
        IF existing.window_plan_digest IS DISTINCT FROM plan_digest_value
           OR existing.calendar_id IS DISTINCT FROM calendar_id_value
           OR existing.snapshot_id IS DISTINCT FROM snapshot_id_value THEN
            RAISE EXCEPTION
                'walk-forward window placement cannot change after results exist'
                USING ERRCODE = '22023';
        END IF;
        IF existing.manifest_digest IS DISTINCT FROM manifest_digest_value THEN
            RAISE EXCEPTION
                'walk-forward run is not deterministic for this strategy and snapshot'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.walk_forward_write', 'on', true);
    BEGIN
        INSERT INTO walk_forward_run (
            strategy_version_id, registration_id, calendar_id, snapshot_id,
            window_plan, window_plan_digest, manifest, manifest_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            strategy_version_id_value, version_row.registration_id,
            calendar_id_value, snapshot_id_value,
            plan_value, plan_digest_value, manifest_value, manifest_digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.walk_forward_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.walk_forward_write', 'off', true);

    PERFORM append_audit_event(
        'walk-forward:' || created.run_id::text,
        'research.walk_forward_run_recorded',
        now(),
        jsonb_build_object(
            'run_id', created.run_id,
            'strategy_version_id', strategy_version_id_value,
            'registration_id', version_row.registration_id,
            'calendar_id', calendar_id_value,
            'window_plan_digest', plan_digest_value,
            'manifest_digest', manifest_digest_value,
            'walk_forward', plan_value->'walk_forward'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION strategy_sandbox_evaluate_program_bounded(jsonb, jsonb, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION register_walk_forward_calendar(date[], jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_walk_forward_run(uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON walk_forward_calendar FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON walk_forward_run FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
