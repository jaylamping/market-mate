-- WU-37 Net-of-cost research accounting: commissions, exchange/regulatory
-- fees, and slippage from a declared schedule attach to each simulated
-- research position before performance is reported. Missing cost inputs
-- fail closed rather than assuming zero.

CREATE FUNCTION research_cost_nonneg_int(node jsonb)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n bigint;
BEGIN
    n := strategy_sandbox_integer(node);
    IF n IS NULL OR n < 0 THEN
        RETURN NULL;
    END IF;
    RETURN n;
END;
$$;

CREATE FUNCTION research_cost_schedule_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-research-cost-schedule-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION research_cost_trades_digest(trades_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-research-cost-trades-v1|' || trades_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION research_cost_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-research-cost-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION research_cost_assert_schedule(spec_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'schedule_key',
        'commission_cents_per_unit',
        'exchange_fee_cents_per_unit',
        'regulatory_fee_cents_per_unit',
        'slippage_bps_per_side'
    ];
    required text;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RAISE EXCEPTION 'research cost schedule contains out-of-scope keys'
            USING ERRCODE = '22023';
    END IF;
    FOREACH required IN ARRAY ARRAY[
        'commission_cents_per_unit',
        'exchange_fee_cents_per_unit',
        'regulatory_fee_cents_per_unit',
        'slippage_bps_per_side'
    ] LOOP
        IF NOT (spec_value ? required)
           OR research_cost_nonneg_int(spec_value->required) IS NULL
           OR research_cost_nonneg_int(spec_value->required) > 10000 THEN
            RAISE EXCEPTION
                'research cost schedule is missing required cost inputs'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF jsonb_typeof(spec_value->'schedule_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'schedule_key'), '') = '' THEN
        RAISE EXCEPTION 'research cost schedule is missing required cost inputs'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION research_cost_assert_trades(trades_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    trade jsonb;
    allowed text[] := ARRAY[
        'symbol', 'side', 'units', 'entry_session', 'exit_session',
        'entry_cents', 'exit_cents'
    ];
    side_text text;
    units bigint;
    entry_cents bigint;
    exit_cents bigint;
    entry_session text;
    exit_session text;
BEGIN
    IF jsonb_typeof(trades_value) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'research cost trades are not admissible'
            USING ERRCODE = '22023';
    END IF;
    n := jsonb_array_length(trades_value);
    IF n < 1 OR n > 256 THEN
        RAISE EXCEPTION 'research cost trades exceed the resource bound'
            USING ERRCODE = '22023';
    END IF;
    FOR trade IN SELECT jsonb_array_elements(trades_value) LOOP
        IF jsonb_typeof(trade) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(trade) k
                WHERE k <> ALL (allowed)
           ) THEN
            RAISE EXCEPTION 'research cost trades contain out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
        side_text := btrim(trade->>'side');
        units := strategy_sandbox_integer(trade->'units');
        entry_cents := strategy_sandbox_integer(trade->'entry_cents');
        exit_cents := strategy_sandbox_integer(trade->'exit_cents');
        entry_session := btrim(trade->>'entry_session');
        exit_session := btrim(trade->>'exit_session');
        IF jsonb_typeof(trade->'symbol') IS DISTINCT FROM 'string'
           OR coalesce(btrim(trade->>'symbol'), '') = ''
           OR jsonb_typeof(trade->'side') IS DISTINCT FROM 'string'
           OR side_text NOT IN ('long', 'short')
           OR units IS NULL OR units < 1 OR units > 10
           OR entry_cents IS NULL OR entry_cents < 1
           OR exit_cents IS NULL OR exit_cents < 1
           OR jsonb_typeof(trade->'entry_session') IS DISTINCT FROM 'string'
           OR entry_session IS NULL
           OR entry_session !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           OR jsonb_typeof(trade->'exit_session') IS DISTINCT FROM 'string'
           OR exit_session IS NULL
           OR exit_session !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           OR exit_session <= entry_session THEN
            RAISE EXCEPTION
                'research cost schedule is missing required cost inputs'
                USING ERRCODE = '22023';
        END IF;
        IF trade ? 'return_bps' THEN
            RAISE EXCEPTION 'research cost trades contain out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION apply_research_costs(
    trades_value jsonb,
    schedule_value jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    commission_unit bigint;
    exchange_unit bigint;
    regulatory_unit bigint;
    slippage_bps bigint;
    trade jsonb;
    units bigint;
    entry_cents bigint;
    exit_cents bigint;
    signed integer;
    notional bigint;
    gross_pnl bigint;
    commission_cents bigint;
    exchange_cents bigint;
    regulatory_cents bigint;
    slippage_cents bigint;
    net_pnl bigint;
    gross_bps bigint;
    net_bps bigint;
    priced jsonb := '[]'::jsonb;
    gross_sum bigint := 0;
    net_sum bigint := 0;
    commission_sum bigint := 0;
    exchange_sum bigint := 0;
    regulatory_sum bigint := 0;
    slippage_sum bigint := 0;
    n integer := 0;
    result jsonb;
BEGIN
    PERFORM research_cost_assert_schedule(schedule_value);
    PERFORM research_cost_assert_trades(trades_value);

    commission_unit := research_cost_nonneg_int(
        schedule_value->'commission_cents_per_unit');
    exchange_unit := research_cost_nonneg_int(
        schedule_value->'exchange_fee_cents_per_unit');
    regulatory_unit := research_cost_nonneg_int(
        schedule_value->'regulatory_fee_cents_per_unit');
    slippage_bps := research_cost_nonneg_int(
        schedule_value->'slippage_bps_per_side');

    FOR trade IN SELECT jsonb_array_elements(trades_value) LOOP
        units := strategy_sandbox_integer(trade->'units');
        entry_cents := strategy_sandbox_integer(trade->'entry_cents');
        exit_cents := strategy_sandbox_integer(trade->'exit_cents');
        signed := CASE btrim(trade->>'side') WHEN 'long' THEN 1 ELSE -1 END;
        notional := units * entry_cents;
        gross_pnl := signed * units * (exit_cents - entry_cents);
        commission_cents := 2 * units * commission_unit;
        exchange_cents := 2 * units * exchange_unit;
        regulatory_cents := 2 * units * regulatory_unit;
        slippage_cents :=
            (units * entry_cents * slippage_bps) / 10000
            + (units * exit_cents * slippage_bps) / 10000;
        net_pnl := gross_pnl
            - commission_cents - exchange_cents - regulatory_cents - slippage_cents;
        gross_bps := (gross_pnl * 10000) / notional;
        net_bps := (net_pnl * 10000) / notional;
        n := n + 1;
        gross_sum := gross_sum + gross_bps;
        net_sum := net_sum + net_bps;
        commission_sum := commission_sum + commission_cents;
        exchange_sum := exchange_sum + exchange_cents;
        regulatory_sum := regulatory_sum + regulatory_cents;
        slippage_sum := slippage_sum + slippage_cents;
        priced := priced || jsonb_build_array(
            trade || jsonb_build_object(
                'gross_pnl_cents', gross_pnl,
                'commission_cents', commission_cents,
                'exchange_fee_cents', exchange_cents,
                'regulatory_fee_cents', regulatory_cents,
                'slippage_cents', slippage_cents,
                'net_pnl_cents', net_pnl,
                'gross_return_bps', gross_bps,
                'net_return_bps', net_bps
            )
        );
    END LOOP;

    result := jsonb_build_object(
        'engine', 'research_cost_v1',
        'schedule_key', btrim(schedule_value->>'schedule_key'),
        'schedule_digest', research_cost_schedule_digest(schedule_value),
        'trade_count', n,
        'gross_mean_return_bps', gross_sum / n,
        'mean_return_bps', net_sum / n,
        'total_commission_cents', commission_sum,
        'total_exchange_fee_cents', exchange_sum,
        'total_regulatory_fee_cents', regulatory_sum,
        'total_slippage_cents', slippage_sum,
        'trades', priced
    );
    RETURN result || jsonb_build_object(
        'result_digest', research_cost_result_digest(result));
END;
$$;

CREATE TABLE research_cost_schedule (
    schedule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_key text NOT NULL CHECK (btrim(schedule_key) <> ''),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    schedule_digest text NOT NULL CHECK (schedule_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (schedule_digest = research_cost_schedule_digest(spec)),
    CHECK (schedule_key = btrim(spec->>'schedule_key')),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('research_cost_schedule');

CREATE UNIQUE INDEX research_cost_schedule_digest_uq
    ON research_cost_schedule (schedule_digest);

CREATE TABLE research_cost_application (
    application_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_id uuid NOT NULL
        REFERENCES research_cost_schedule(schedule_id),
    strategy_version_id uuid
        REFERENCES strategy_version(strategy_version_id),
    trades jsonb NOT NULL CHECK (jsonb_typeof(trades) = 'array'),
    trades_digest text NOT NULL CHECK (trades_digest ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (trades_digest = research_cost_trades_digest(trades)),
    CHECK (result_digest = research_cost_result_digest(result - 'result_digest')),
    CHECK ((result->>'mean_return_bps') IS NOT NULL),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('research_cost_application');

CREATE UNIQUE INDEX research_cost_application_content_uq
    ON research_cost_application (trades_digest, schedule_id);
CREATE UNIQUE INDEX research_cost_application_strategy_trades_uq
    ON research_cost_application (strategy_version_id, trades_digest)
    WHERE strategy_version_id IS NOT NULL;

CREATE FUNCTION guard_research_cost_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cost_schedule_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_cost_schedule
    FOR EACH STATEMENT EXECUTE FUNCTION guard_research_cost_write();

CREATE TRIGGER research_cost_application_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_cost_application
    FOR EACH STATEMENT EXECUTE FUNCTION guard_research_cost_write();

CREATE FUNCTION guard_research_cost_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.cost_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the research cost workflow', TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cost_schedule_insert_guard
    BEFORE INSERT ON research_cost_schedule
    FOR EACH ROW EXECUTE FUNCTION guard_research_cost_insert();

CREATE TRIGGER research_cost_application_insert_guard
    BEFORE INSERT ON research_cost_application
    FOR EACH ROW EXECUTE FUNCTION guard_research_cost_insert();

CREATE FUNCTION register_research_cost_schedule(
    spec_value jsonb,
    source_lineage_value jsonb
) RETURNS research_cost_schedule
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    digest_value text;
    existing research_cost_schedule%ROWTYPE;
    created research_cost_schedule%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research cost schedule arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM research_cost_assert_schedule(spec_value);
    digest_value := research_cost_schedule_digest(spec_value);
    PERFORM pg_advisory_xact_lock(hashtextextended(digest_value, 39023));

    SELECT * INTO existing
    FROM research_cost_schedule
    WHERE schedule_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.cost_write', 'on', true);
    BEGIN
        INSERT INTO research_cost_schedule (
            schedule_key, spec, schedule_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            btrim(spec_value->>'schedule_key'), spec_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.cost_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.cost_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION record_research_cost_application(
    trades_value jsonb,
    schedule_spec_value jsonb,
    strategy_version_id_value uuid,
    source_lineage_value jsonb
) RETURNS research_cost_application
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row strategy_version%ROWTYPE;
    schedule_row research_cost_schedule%ROWTYPE;
    computed jsonb;
    stored_result jsonb;
    digest_value text;
    trades_digest_value text;
    existing research_cost_application%ROWTYPE;
    created research_cost_application%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research cost application arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO schedule_row
    FROM register_research_cost_schedule(schedule_spec_value, source_lineage_value);

    IF strategy_version_id_value IS NOT NULL THEN
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
                'research costs can bind only a frozen deterministic DSL Strategy Version'
                USING ERRCODE = '22023';
        END IF;
        PERFORM pg_advisory_xact_lock(
            hashtextextended(strategy_version_id_value::text, 39024));
    END IF;

    computed := apply_research_costs(trades_value, schedule_row.spec);
    stored_result := computed - 'result_digest';
    digest_value := research_cost_result_digest(stored_result);
    trades_digest_value := research_cost_trades_digest(trades_value);

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            trades_digest_value || ':' || schedule_row.schedule_id::text, 39025));

    SELECT * INTO existing
    FROM research_cost_application
    WHERE trades_digest = trades_digest_value
      AND schedule_id = schedule_row.schedule_id;
    IF FOUND THEN
        IF existing.strategy_version_id IS DISTINCT FROM strategy_version_id_value THEN
            RAISE EXCEPTION
                'research cost application is already recorded on a different lineage'
                USING ERRCODE = '23505';
        END IF;
        IF existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'research cost application is not deterministic for this schedule'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    IF strategy_version_id_value IS NOT NULL THEN
        SELECT * INTO existing
        FROM research_cost_application
        WHERE strategy_version_id = strategy_version_id_value
        LIMIT 1;
        IF FOUND AND existing.schedule_id IS DISTINCT FROM schedule_row.schedule_id THEN
            RAISE EXCEPTION
                'research cost schedule cannot change after results exist'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.cost_write', 'on', true);
    BEGIN
        INSERT INTO research_cost_application (
            schedule_id, strategy_version_id, trades, trades_digest,
            result, result_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            schedule_row.schedule_id, strategy_version_id_value,
            trades_value, trades_digest_value, stored_result, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.cost_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.cost_write', 'off', true);

    PERFORM append_audit_event(
        'research-cost:' || created.application_id::text,
        'research.cost_application_recorded',
        now(),
        jsonb_build_object(
            'application_id', created.application_id,
            'schedule_id', schedule_row.schedule_id,
            'strategy_version_id', strategy_version_id_value,
            'schedule_digest', schedule_row.schedule_digest,
            'result_digest', digest_value,
            'mean_return_bps', stored_result->>'mean_return_bps',
            'gross_mean_return_bps', stored_result->>'gross_mean_return_bps'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_research_cost_schedule(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_research_cost_application(jsonb, jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_cost_schedule FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_cost_application FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
