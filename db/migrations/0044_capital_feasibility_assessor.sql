-- WU-40 Capital Feasibility Assessor core: defined-risk structures on the
-- $1,000 bankroll. Computes minimum contract units, collateral, approval
-- prerequisites, and commissions/fees from a point-in-time chain and fee
-- schedule. Missing fee schedule, chain snapshot, or certified identity
-- mapping fails closed. Slippage, assignment exposure, Position Risk, and
-- the stock-only fallback belong to WU-41/WU-42.

CREATE FUNCTION capital_feasibility_bankroll_cents()
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT 100000::bigint;
$$;

CREATE FUNCTION capital_feasibility_nonneg_int(node jsonb)
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

CREATE FUNCTION capital_feasibility_share_cents(payload jsonb, side_value text)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    key text;
    n numeric;
BEGIN
    IF jsonb_typeof(payload) IS DISTINCT FROM 'object'
       OR side_value NOT IN ('buy', 'sell') THEN
        RETURN NULL;
    END IF;
    key := CASE side_value WHEN 'buy' THEN 'ask' ELSE 'bid' END;
    IF jsonb_typeof(payload->key) IS DISTINCT FROM 'number' THEN
        RETURN NULL;
    END IF;
    n := (payload->>key)::numeric;
    IF n IS NULL OR n <= 0 THEN
        RETURN NULL;
    END IF;
    IF side_value = 'buy' THEN
        RETURN ceil(n * 100)::bigint;
    END IF;
    RETURN floor(n * 100)::bigint;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE FUNCTION capital_feasibility_fee_schedule_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-capital-feasibility-fee-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION capital_feasibility_structure_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-capital-feasibility-structure-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION capital_feasibility_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-capital-feasibility-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION capital_feasibility_assert_fee_schedule(spec_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'schedule_key',
        'commission_cents_per_contract',
        'exchange_fee_cents_per_contract',
        'regulatory_fee_cents_per_contract'
    ];
    required text;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RAISE EXCEPTION
            'capital feasibility fee schedule is missing required inputs'
            USING ERRCODE = '22023';
    END IF;
    FOREACH required IN ARRAY ARRAY[
        'commission_cents_per_contract',
        'exchange_fee_cents_per_contract',
        'regulatory_fee_cents_per_contract'
    ] LOOP
        IF NOT (spec_value ? required)
           OR capital_feasibility_nonneg_int(spec_value->required) IS NULL
           OR capital_feasibility_nonneg_int(spec_value->required) > 10000 THEN
            RAISE EXCEPTION
                'capital feasibility fee schedule is missing required inputs'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF jsonb_typeof(spec_value->'schedule_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'schedule_key'), '') = '' THEN
        RAISE EXCEPTION
            'capital feasibility fee schedule is missing required inputs'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION capital_feasibility_assert_structure(spec_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY['structure_key', 'structure_kind', 'legs'];
    kind text;
    n integer;
    leg jsonb;
    allowed_leg text[] := ARRAY['contract_id', 'side'];
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RAISE EXCEPTION 'capital feasibility structure is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(spec_value->'structure_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'structure_key'), '') = '' THEN
        RAISE EXCEPTION 'capital feasibility structure is invalid'
            USING ERRCODE = '22023';
    END IF;
    kind := lower(btrim(spec_value->>'structure_kind'));
    IF jsonb_typeof(spec_value->'structure_kind') IS DISTINCT FROM 'string'
       OR kind NOT IN (
            'long_call', 'long_put',
            'debit_call_vertical', 'debit_put_vertical',
            'credit_call_vertical', 'credit_put_vertical'
       ) THEN
        RAISE EXCEPTION
            'capital feasibility structure is not defined-risk'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(spec_value->'legs') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'capital feasibility structure is invalid'
            USING ERRCODE = '22023';
    END IF;
    n := jsonb_array_length(spec_value->'legs');
    IF kind IN ('long_call', 'long_put') AND n <> 1 THEN
        RAISE EXCEPTION
            'capital feasibility structure is not defined-risk'
            USING ERRCODE = '22023';
    END IF;
    IF kind IN (
            'debit_call_vertical', 'debit_put_vertical',
            'credit_call_vertical', 'credit_put_vertical'
        ) AND n <> 2 THEN
        RAISE EXCEPTION
            'capital feasibility structure is not defined-risk'
            USING ERRCODE = '22023';
    END IF;
    FOR leg IN SELECT jsonb_array_elements(spec_value->'legs') LOOP
        IF jsonb_typeof(leg) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(leg) k
                WHERE k <> ALL (allowed_leg)
           )
           OR jsonb_typeof(leg->'contract_id') IS DISTINCT FROM 'string'
           OR coalesce(btrim(leg->>'contract_id'), '') = ''
           OR btrim(leg->>'side') NOT IN ('buy', 'sell') THEN
            RAISE EXCEPTION 'capital feasibility structure is invalid'
                USING ERRCODE = '22023';
        END IF;
        BEGIN
            PERFORM (btrim(leg->>'contract_id'))::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'capital feasibility structure is invalid'
                    USING ERRCODE = '22023';
        END;
    END LOOP;
END;
$$;

CREATE TABLE capital_feasibility_fee_schedule (
    schedule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_key text NOT NULL CHECK (btrim(schedule_key) <> ''),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    schedule_digest text NOT NULL CHECK (schedule_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (schedule_digest = capital_feasibility_fee_schedule_digest(spec)),
    CHECK (schedule_key = btrim(spec->>'schedule_key')),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('capital_feasibility_fee_schedule');

CREATE UNIQUE INDEX capital_feasibility_fee_schedule_digest_uq
    ON capital_feasibility_fee_schedule (schedule_digest);

CREATE TABLE capital_feasibility_assessment (
    assessment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_id uuid NOT NULL
        REFERENCES capital_feasibility_fee_schedule(schedule_id),
    snapshot_id uuid NOT NULL,
    instrument_mapping_id uuid NOT NULL
        REFERENCES instrument_mapping(mapping_id),
    structure jsonb NOT NULL CHECK (jsonb_typeof(structure) = 'object'),
    structure_digest text NOT NULL CHECK (structure_digest ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (structure_digest = capital_feasibility_structure_digest(structure)),
    CHECK (result_digest = capital_feasibility_result_digest(result - 'result_digest')),
    CHECK ((result->>'bankroll_cents')::bigint = capital_feasibility_bankroll_cents()),
    CHECK ((result->>'min_contract_units')::bigint = 1),
    CHECK (result ? 'collateral_cents'),
    CHECK (result ? 'approval_prerequisites'),
    CHECK (result ? 'total_fee_cents'),
    CHECK (result ? 'fits_bankroll'),
    CHECK (record_environment = 'local_research'),
    FOREIGN KEY (snapshot_id)
        REFERENCES option_chain_snapshot (snapshot_id)
);

SELECT register_evidence_table('capital_feasibility_assessment');

CREATE UNIQUE INDEX capital_feasibility_assessment_identity_uq
    ON capital_feasibility_assessment (
        structure_digest, schedule_id, snapshot_id);

CREATE FUNCTION guard_capital_feasibility_write() RETURNS trigger
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

CREATE TRIGGER capital_feasibility_fee_schedule_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON capital_feasibility_fee_schedule
    FOR EACH STATEMENT EXECUTE FUNCTION guard_capital_feasibility_write();

CREATE TRIGGER capital_feasibility_assessment_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON capital_feasibility_assessment
    FOR EACH STATEMENT EXECUTE FUNCTION guard_capital_feasibility_write();

CREATE FUNCTION guard_capital_feasibility_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.feasibility_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the capital feasibility workflow',
            TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER capital_feasibility_fee_schedule_insert_guard
    BEFORE INSERT ON capital_feasibility_fee_schedule
    FOR EACH ROW EXECUTE FUNCTION guard_capital_feasibility_insert();

CREATE TRIGGER capital_feasibility_assessment_insert_guard
    BEFORE INSERT ON capital_feasibility_assessment
    FOR EACH ROW EXECUTE FUNCTION guard_capital_feasibility_insert();

CREATE FUNCTION register_capital_feasibility_fee_schedule(
    spec_value jsonb,
    source_lineage_value jsonb
) RETURNS capital_feasibility_fee_schedule
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    digest_value text;
    existing capital_feasibility_fee_schedule%ROWTYPE;
    created capital_feasibility_fee_schedule%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'capital feasibility fee schedule arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM capital_feasibility_assert_fee_schedule(spec_value);
    digest_value := capital_feasibility_fee_schedule_digest(spec_value);
    PERFORM pg_advisory_xact_lock(hashtextextended(digest_value, 44023));

    SELECT * INTO existing
    FROM capital_feasibility_fee_schedule
    WHERE schedule_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.feasibility_write', 'on', true);
    BEGIN
        INSERT INTO capital_feasibility_fee_schedule (
            schedule_key, spec, schedule_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            btrim(spec_value->>'schedule_key'), spec_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.feasibility_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.feasibility_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION compute_capital_feasibility(
    structure_value jsonb,
    fee_schedule_spec jsonb,
    snapshot_id_value uuid,
    instrument_mapping_id_value uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    snapshot_row option_chain_snapshot%ROWTYPE;
    mapping_row instrument_mapping%ROWTYPE;
    kind text;
    stored jsonb;
    leg jsonb;
    contract_row option_chain_contract%ROWTYPE;
    deliverable_row option_deliverable_version%ROWTYPE;
    side_value text;
    share_cents bigint;
    premium_cents bigint;
    buy_count integer := 0;
    sell_count integer := 0;
    buy_right text;
    sell_right text;
    buy_expiry date;
    sell_expiry date;
    buy_strike numeric;
    sell_strike numeric;
    buy_premium bigint := 0;
    sell_premium bigint := 0;
    multiplier numeric;
    width_cents bigint;
    net_debit bigint;
    collateral bigint;
    commission_unit bigint;
    exchange_unit bigint;
    regulatory_unit bigint;
    n_legs integer;
    commission_cents bigint;
    exchange_cents bigint;
    regulatory_cents bigint;
    total_fee bigint;
    capital_required bigint;
    approvals jsonb;
    priced jsonb := '[]'::jsonb;
    result jsonb;
BEGIN
    PERFORM capital_feasibility_assert_fee_schedule(fee_schedule_spec);
    PERFORM capital_feasibility_assert_structure(structure_value);

    IF snapshot_id_value IS NULL THEN
        RAISE EXCEPTION 'capital feasibility chain snapshot is missing'
            USING ERRCODE = '22023';
    END IF;
    IF instrument_mapping_id_value IS NULL THEN
        RAISE EXCEPTION
            'capital feasibility identity mapping is missing or not certified'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO snapshot_row
    FROM option_chain_snapshot
    WHERE snapshot_id = snapshot_id_value;
    IF NOT FOUND OR snapshot_row.data_mode IS DISTINCT FROM 'historical' THEN
        RAISE EXCEPTION 'capital feasibility chain snapshot is missing'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO mapping_row
    FROM instrument_mapping
    WHERE mapping_id = instrument_mapping_id_value;
    IF NOT FOUND
       OR mapping_row.lifecycle IS DISTINCT FROM 'certified'
       OR mapping_row.object_kind IS DISTINCT FROM 'security'
       OR mapping_row.mapping_id IS DISTINCT FROM snapshot_row.instrument_mapping_id
       OR mapping_row.security_id IS DISTINCT FROM snapshot_row.underlying_security_id THEN
        RAISE EXCEPTION
            'capital feasibility identity mapping is missing or not certified'
            USING ERRCODE = '22023';
    END IF;

    kind := lower(btrim(structure_value->>'structure_kind'));
    stored := jsonb_build_object(
        'structure_key', btrim(structure_value->>'structure_key'),
        'structure_kind', kind,
        'legs', structure_value->'legs'
    );

    FOR leg IN SELECT jsonb_array_elements(stored->'legs') LOOP
        side_value := btrim(leg->>'side');
        SELECT * INTO contract_row
        FROM option_chain_contract
        WHERE contract_id = (btrim(leg->>'contract_id'))::uuid
          AND snapshot_id = snapshot_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'capital feasibility chain snapshot is missing required contracts'
                USING ERRCODE = '22023';
        END IF;
        SELECT * INTO deliverable_row
        FROM option_deliverable_version
        WHERE deliverable_version_id = contract_row.deliverable_version_id;
        IF NOT FOUND OR deliverable_row.multiplier IS NULL
           OR deliverable_row.multiplier <> floor(deliverable_row.multiplier)
           OR deliverable_row.multiplier < 1 THEN
            RAISE EXCEPTION
                'capital feasibility chain snapshot is missing required contracts'
                USING ERRCODE = '22023';
        END IF;
        share_cents := capital_feasibility_share_cents(
            contract_row.raw_payload, side_value);
        IF share_cents IS NULL THEN
            RAISE EXCEPTION
                'capital feasibility chain snapshot is missing required contracts'
                USING ERRCODE = '22023';
        END IF;
        IF multiplier IS NULL THEN
            multiplier := deliverable_row.multiplier;
        ELSIF multiplier IS DISTINCT FROM deliverable_row.multiplier THEN
            RAISE EXCEPTION 'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        premium_cents := share_cents * deliverable_row.multiplier::bigint;
        IF side_value = 'buy' THEN
            buy_count := buy_count + 1;
            buy_right := contract_row.option_right;
            buy_expiry := contract_row.expiration_date;
            buy_strike := contract_row.strike_price;
            buy_premium := buy_premium + premium_cents;
        ELSE
            sell_count := sell_count + 1;
            sell_right := contract_row.option_right;
            sell_expiry := contract_row.expiration_date;
            sell_strike := contract_row.strike_price;
            sell_premium := sell_premium + premium_cents;
        END IF;
        priced := priced || jsonb_build_array(jsonb_build_object(
            'contract_id', contract_row.contract_id,
            'side', side_value,
            'option_right', contract_row.option_right,
            'expiration_date', contract_row.expiration_date,
            'strike_price', contract_row.strike_price,
            'share_cents', share_cents,
            'premium_cents', premium_cents
        ));
    END LOOP;

    IF kind IN ('long_call', 'long_put') THEN
        IF buy_count <> 1 OR sell_count <> 0
           OR (kind = 'long_call' AND buy_right IS DISTINCT FROM 'call')
           OR (kind = 'long_put' AND buy_right IS DISTINCT FROM 'put') THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        net_debit := buy_premium;
        collateral := net_debit;
        approvals := jsonb_build_array('options_long');
    ELSE
        IF buy_count <> 1 OR sell_count <> 1
           OR buy_right IS DISTINCT FROM sell_right
           OR buy_expiry IS DISTINCT FROM sell_expiry
           OR buy_strike IS NOT DISTINCT FROM sell_strike THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        IF kind IN ('debit_call_vertical', 'credit_call_vertical')
           AND buy_right IS DISTINCT FROM 'call' THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        IF kind IN ('debit_put_vertical', 'credit_put_vertical')
           AND buy_right IS DISTINCT FROM 'put' THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        IF kind = 'debit_call_vertical' AND buy_strike >= sell_strike THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        IF kind = 'debit_put_vertical' AND buy_strike <= sell_strike THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        IF kind = 'credit_call_vertical' AND sell_strike >= buy_strike THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        IF kind = 'credit_put_vertical' AND sell_strike <= buy_strike THEN
            RAISE EXCEPTION
                'capital feasibility structure is not defined-risk'
                USING ERRCODE = '22023';
        END IF;
        width_cents := round(abs(buy_strike - sell_strike) * 100 * multiplier)::bigint;
        net_debit := buy_premium - sell_premium;
        IF kind IN ('debit_call_vertical', 'debit_put_vertical') THEN
            IF net_debit <= 0 OR net_debit > width_cents THEN
                RAISE EXCEPTION
                    'capital feasibility structure is not defined-risk'
                    USING ERRCODE = '22023';
            END IF;
            collateral := net_debit;
        ELSE
            IF net_debit >= 0 OR (-net_debit) >= width_cents THEN
                RAISE EXCEPTION
                    'capital feasibility structure is not defined-risk'
                    USING ERRCODE = '22023';
            END IF;
            collateral := width_cents + net_debit;
        END IF;
        approvals := jsonb_build_array(
            'options_long', 'options_spreads', 'multi_leg');
    END IF;

    n_legs := jsonb_array_length(stored->'legs');
    commission_unit := capital_feasibility_nonneg_int(
        fee_schedule_spec->'commission_cents_per_contract');
    exchange_unit := capital_feasibility_nonneg_int(
        fee_schedule_spec->'exchange_fee_cents_per_contract');
    regulatory_unit := capital_feasibility_nonneg_int(
        fee_schedule_spec->'regulatory_fee_cents_per_contract');
    commission_cents := n_legs * commission_unit;
    exchange_cents := n_legs * exchange_unit;
    regulatory_cents := n_legs * regulatory_unit;
    total_fee := commission_cents + exchange_cents + regulatory_cents;
    capital_required := collateral + total_fee;

    result := jsonb_build_object(
        'engine', 'capital_feasibility_v1',
        'bankroll_cents', capital_feasibility_bankroll_cents(),
        'structure_key', stored->>'structure_key',
        'structure_kind', kind,
        'min_contract_units', 1,
        'multiplier', multiplier,
        'premium_debit_cents', net_debit,
        'collateral_cents', collateral,
        'commission_cents', commission_cents,
        'exchange_fee_cents', exchange_cents,
        'regulatory_fee_cents', regulatory_cents,
        'total_fee_cents', total_fee,
        'capital_required_cents', capital_required,
        'fits_bankroll', capital_required <= capital_feasibility_bankroll_cents(),
        'approval_prerequisites', approvals,
        'legs', priced
    );
    RETURN result || jsonb_build_object(
        'result_digest', capital_feasibility_result_digest(result));
END;
$$;

CREATE FUNCTION record_capital_feasibility_assessment(
    structure_value jsonb,
    fee_schedule_spec jsonb,
    snapshot_id_value uuid,
    instrument_mapping_id_value uuid,
    source_lineage_value jsonb
) RETURNS capital_feasibility_assessment
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    schedule_row capital_feasibility_fee_schedule%ROWTYPE;
    computed jsonb;
    stored_result jsonb;
    stored_structure jsonb;
    digest_value text;
    structure_digest_value text;
    existing capital_feasibility_assessment%ROWTYPE;
    created capital_feasibility_assessment%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'capital feasibility arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO schedule_row
    FROM register_capital_feasibility_fee_schedule(
        fee_schedule_spec, source_lineage_value);

    computed := compute_capital_feasibility(
        structure_value, schedule_row.spec,
        snapshot_id_value, instrument_mapping_id_value);
    stored_result := computed - 'result_digest';
    digest_value := capital_feasibility_result_digest(stored_result);
    stored_structure := jsonb_build_object(
        'structure_key', btrim(structure_value->>'structure_key'),
        'structure_kind', lower(btrim(structure_value->>'structure_kind')),
        'legs', structure_value->'legs'
    );
    structure_digest_value := capital_feasibility_structure_digest(stored_structure);

    PERFORM pg_advisory_xact_lock(hashtextextended(
        structure_digest_value || ':' || schedule_row.schedule_id::text
            || ':' || snapshot_id_value::text,
        44024));

    SELECT * INTO existing
    FROM capital_feasibility_assessment
    WHERE structure_digest = structure_digest_value
      AND schedule_id = schedule_row.schedule_id
      AND snapshot_id = snapshot_id_value;
    IF FOUND THEN
        IF existing.result_digest IS DISTINCT FROM digest_value
           OR existing.instrument_mapping_id IS DISTINCT FROM instrument_mapping_id_value THEN
            RAISE EXCEPTION
                'capital feasibility assessment is already recorded with a different result or lineage'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.feasibility_write', 'on', true);
    BEGIN
        INSERT INTO capital_feasibility_assessment (
            schedule_id, snapshot_id, instrument_mapping_id,
            structure, structure_digest, result, result_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            schedule_row.schedule_id, snapshot_id_value, instrument_mapping_id_value,
            stored_structure, structure_digest_value, stored_result, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config('market_mate.feasibility_write', 'off', true);
            SELECT * INTO existing
            FROM capital_feasibility_assessment
            WHERE structure_digest = structure_digest_value
              AND schedule_id = schedule_row.schedule_id
              AND snapshot_id = snapshot_id_value;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.result_digest IS DISTINCT FROM digest_value
               OR existing.instrument_mapping_id IS DISTINCT FROM instrument_mapping_id_value THEN
                RAISE EXCEPTION
                    'capital feasibility assessment is already recorded with a different result or lineage'
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.feasibility_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.feasibility_write', 'off', true);

    PERFORM append_audit_event(
        'capital-feasibility:' || created.assessment_id::text,
        'research.capital_feasibility_assessed',
        now(),
        jsonb_build_object(
            'assessment_id', created.assessment_id,
            'schedule_id', schedule_row.schedule_id,
            'snapshot_id', snapshot_id_value,
            'structure_kind', stored_structure->>'structure_kind',
            'collateral_cents', stored_result->>'collateral_cents',
            'total_fee_cents', stored_result->>'total_fee_cents',
            'fits_bankroll', stored_result->'fits_bankroll',
            'result_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_capital_feasibility_fee_schedule(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION compute_capital_feasibility(jsonb, jsonb, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_capital_feasibility_assessment(
    jsonb, jsonb, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON capital_feasibility_fee_schedule FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON capital_feasibility_assessment FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
