-- WU-33 Deterministic evaluation sandbox: evaluate a frozen Strategy Version
-- against a Research Snapshot with a closed DSL v1 program. Same inputs
-- yield byte-identical outputs. Evaluation is resource-bounded, uses no
-- clock or network, and fails closed on non-executable rules, missing
-- coverage, credential-shaped payloads, or out-of-scope signals.

CREATE FUNCTION strategy_sandbox_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-strategy-sandbox-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION strategy_sandbox_integer(node jsonb)
RETURNS bigint
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
    IF n IS NULL OR n <> floor(n) OR n < -9223372036854775808::numeric
       OR n > 9223372036854775807::numeric THEN
        RETURN NULL;
    END IF;
    RETURN n::bigint;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE FUNCTION strategy_sandbox_predicate(
    surprise_value bigint,
    op_value text,
    threshold_value bigint
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE op_value
        WHEN 'gt' THEN surprise_value > threshold_value
        WHEN 'gte' THEN surprise_value >= threshold_value
        WHEN 'lt' THEN surprise_value < threshold_value
        WHEN 'lte' THEN surprise_value <= threshold_value
        WHEN 'eq' THEN surprise_value = threshold_value
        ELSE NULL
    END;
$$;

CREATE FUNCTION strategy_sandbox_program_is_executable(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    entry jsonb;
    exit jsonb;
    sizing jsonb;
    threshold bigint;
    horizon bigint;
    units bigint;
BEGIN
    IF NOT strategy_dsl_spec_is_complete(spec_value) THEN
        RETURN false;
    END IF;
    IF btrim(spec_value->>'target') IS DISTINCT FROM 'earnings_direction' THEN
        RETURN false;
    END IF;
    entry := spec_value->'rules'->'entry';
    exit := spec_value->'rules'->'exit';
    sizing := spec_value->'rules'->'sizing';
    IF jsonb_typeof(entry) IS DISTINCT FROM 'object'
       OR jsonb_typeof(exit) IS DISTINCT FROM 'object'
       OR jsonb_typeof(sizing) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF EXISTS (
            SELECT 1 FROM jsonb_object_keys(entry) k
            WHERE k NOT IN ('signal', 'op', 'threshold', 'side')
        )
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(exit) k
            WHERE k NOT IN ('horizon_sessions')
        )
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(sizing) k
            WHERE k NOT IN ('units')
        ) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(entry->'signal') IS DISTINCT FROM 'string'
       OR btrim(entry->>'signal') IS DISTINCT FROM 'earnings_surprise_bps'
       OR jsonb_typeof(entry->'op') IS DISTINCT FROM 'string'
       OR btrim(entry->>'op') NOT IN ('gt', 'gte', 'lt', 'lte', 'eq')
       OR jsonb_typeof(entry->'side') IS DISTINCT FROM 'string'
       OR btrim(entry->>'side') NOT IN ('long', 'short') THEN
        RETURN false;
    END IF;
    threshold := strategy_sandbox_integer(entry->'threshold');
    horizon := strategy_sandbox_integer(exit->'horizon_sessions');
    units := strategy_sandbox_integer(sizing->'units');
    IF threshold IS NULL
       OR horizon IS NULL OR horizon < 1 OR horizon > 20
       OR units IS NULL OR units < 1 OR units > 10 THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION strategy_sandbox_payload_is_forbidden(payload_value jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT payload_value ?| ARRAY[
        'password', 'api_key', 'api-key', 'secret', 'token',
        'broker_token', 'authorization', 'credential',
        'url', 'uri', 'http', 'https', 'endpoint', 'host', 'hostname'
    ];
$$;

CREATE FUNCTION strategy_sandbox_close_cents(
    payload_value jsonb,
    symbol_value text,
    session_value text
) RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    cents bigint;
    n integer := 0;
    block jsonb;
    bar jsonb;
BEGIN
    FOR block IN SELECT jsonb_array_elements(payload_value->'eod') LOOP
        IF block->>'symbol' IS DISTINCT FROM symbol_value THEN
            CONTINUE;
        END IF;
        FOR bar IN SELECT jsonb_array_elements(block->'bars') LOOP
            IF bar->>'session' IS DISTINCT FROM session_value THEN
                CONTINUE;
            END IF;
            cents := strategy_sandbox_integer(bar->'close_cents');
            n := n + 1;
        END LOOP;
    END LOOP;
    IF n <> 1 OR cents IS NULL OR cents < 1 THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot is missing a complete close for % at %',
            symbol_value, session_value
            USING ERRCODE = '22023';
    END IF;
    RETURN cents;
END;
$$;

CREATE FUNCTION strategy_sandbox_surprise_bps(
    payload_value jsonb,
    symbol_value text,
    session_value text
) RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    surprise bigint;
    n integer := 0;
    row jsonb;
BEGIN
    FOR row IN SELECT jsonb_array_elements(payload_value->'earnings') LOOP
        IF row->>'symbol' IS DISTINCT FROM symbol_value
           OR row->>'as_of_session' IS DISTINCT FROM session_value THEN
            CONTINUE;
        END IF;
        surprise := strategy_sandbox_integer(row->'earnings_surprise_bps');
        n := n + 1;
    END LOOP;
    IF n = 0 THEN
        RETURN NULL;
    END IF;
    IF n <> 1 OR surprise IS NULL THEN
        RAISE EXCEPTION
            'strategy sandbox snapshot earnings coverage is invalid for % at %',
            symbol_value, session_value
            USING ERRCODE = '22023';
    END IF;
    RETURN surprise;
END;
$$;

CREATE FUNCTION strategy_sandbox_evaluate_program(
    spec_value jsonb,
    payload_value jsonb
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
    IF octet_length(payload_value::text) > 65536 THEN
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
    IF n < 2 OR n > 60 THEN
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

CREATE TABLE strategy_sandbox_evaluation (
    evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_version_id uuid NOT NULL
        REFERENCES strategy_version(strategy_version_id),
    snapshot_id uuid NOT NULL
        REFERENCES research_snapshot(snapshot_id),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (result_digest = strategy_sandbox_result_digest(result)),
    UNIQUE (strategy_version_id, snapshot_id)
);

SELECT register_evidence_table('strategy_sandbox_evaluation');

CREATE INDEX strategy_sandbox_evaluation_snapshot_idx
    ON strategy_sandbox_evaluation (snapshot_id, receipt_time);

CREATE FUNCTION guard_strategy_sandbox_evaluation_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'strategy_sandbox_evaluation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER strategy_sandbox_evaluation_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON strategy_sandbox_evaluation
    FOR EACH STATEMENT EXECUTE FUNCTION guard_strategy_sandbox_evaluation_write();

CREATE FUNCTION guard_strategy_sandbox_evaluation_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.strategy_sandbox_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            'strategy_sandbox_evaluation writes must go through record_strategy_sandbox_evaluation'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER strategy_sandbox_evaluation_insert_guard
    BEFORE INSERT ON strategy_sandbox_evaluation
    FOR EACH ROW EXECUTE FUNCTION guard_strategy_sandbox_evaluation_insert();

CREATE FUNCTION record_strategy_sandbox_evaluation(
    strategy_version_id_value uuid,
    snapshot_id_value uuid,
    source_lineage_value jsonb
) RETURNS strategy_sandbox_evaluation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row strategy_version%ROWTYPE;
    snapshot_row research_snapshot%ROWTYPE;
    result_value jsonb;
    digest_value text;
    existing strategy_sandbox_evaluation%ROWTYPE;
    created strategy_sandbox_evaluation%ROWTYPE;
BEGIN
    IF strategy_version_id_value IS NULL
       OR snapshot_id_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'strategy sandbox evaluation arguments are invalid'
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
            'strategy sandbox can evaluate only a frozen deterministic DSL Strategy Version'
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
        RAISE EXCEPTION
            'strategy sandbox can evaluate only a Local Research snapshot'
            USING ERRCODE = '22023';
    END IF;

    result_value := strategy_sandbox_evaluate_program(
        version_row.spec, snapshot_row.payload);
    digest_value := strategy_sandbox_result_digest(result_value);

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            strategy_version_id_value::text || ':' || snapshot_id_value::text,
            35023));

    SELECT * INTO existing
    FROM strategy_sandbox_evaluation
    WHERE strategy_version_id = strategy_version_id_value
      AND snapshot_id = snapshot_id_value;
    IF FOUND THEN
        IF existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'strategy sandbox evaluation is not deterministic for this strategy and snapshot'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.strategy_sandbox_write', 'on', true);
    BEGIN
        INSERT INTO strategy_sandbox_evaluation (
            strategy_version_id, snapshot_id, result, result_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            strategy_version_id_value, snapshot_id_value, result_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.strategy_sandbox_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.strategy_sandbox_write', 'off', true);

    PERFORM append_audit_event(
        'strategy-sandbox:' || created.evaluation_id::text,
        'research.strategy_sandbox_evaluated',
        now(),
        jsonb_build_object(
            'evaluation_id', created.evaluation_id,
            'strategy_version_id', strategy_version_id_value,
            'snapshot_id', snapshot_id_value,
            'result_digest', digest_value,
            'trade_count', created.result->>'trade_count'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION record_strategy_sandbox_evaluation(uuid, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON strategy_sandbox_evaluation FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
