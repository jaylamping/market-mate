-- WU-41 Assignment, slippage, and Position Risk modeling.
-- Conservative valuation on a WU-40 defined-risk assessment: entry/exit
-- slippage, assignment exposure, and cost-inclusive Position Risk. Risk
-- Policy floors (#5 utilization ceiling 75% of the $1,000 bankroll, and
-- the bankroll itself) cannot be weakened. Worst-case over capacity is
-- recorded as a rejection. The feasibility artifact and stock-only
-- fallback belong to WU-42.

CREATE FUNCTION capital_feasibility_utilization_ceiling_cents()
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT (capital_feasibility_bankroll_cents() * 75) / 100;
$$;

CREATE FUNCTION position_risk_apply_bps(
    cents_value bigint,
    bps_value bigint,
    worsen_up boolean
) RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF cents_value IS NULL OR bps_value IS NULL OR cents_value < 0
       OR bps_value < 0 OR bps_value > 10000 THEN
        RETURN NULL;
    END IF;
    IF worsen_up THEN
        RETURN (cents_value * (10000 + bps_value) + 9999) / 10000;
    END IF;
    RETURN (cents_value * (10000 - bps_value)) / 10000;
END;
$$;

CREATE FUNCTION position_risk_schedule_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-position-risk-schedule-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION position_risk_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-position-risk-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION position_risk_assert_schedule(spec_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'schedule_key',
        'entry_slippage_bps',
        'exit_slippage_bps',
        'assignment_fee_cents_per_contract'
    ];
    required text;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RAISE EXCEPTION
            'position risk schedule is missing required inputs'
            USING ERRCODE = '22023';
    END IF;
    FOREACH required IN ARRAY ARRAY[
        'entry_slippage_bps',
        'exit_slippage_bps',
        'assignment_fee_cents_per_contract'
    ] LOOP
        IF NOT (spec_value ? required)
           OR capital_feasibility_nonneg_int(spec_value->required) IS NULL
           OR capital_feasibility_nonneg_int(spec_value->required) > 10000 THEN
            RAISE EXCEPTION
                'position risk schedule is missing required inputs'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF jsonb_typeof(spec_value->'schedule_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'schedule_key'), '') = '' THEN
        RAISE EXCEPTION
            'position risk schedule is missing required inputs'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE TABLE position_risk_schedule (
    schedule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_key text NOT NULL CHECK (btrim(schedule_key) <> ''),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    schedule_digest text NOT NULL CHECK (schedule_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (schedule_digest = position_risk_schedule_digest(spec)),
    CHECK (schedule_key = btrim(spec->>'schedule_key')),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('position_risk_schedule');

CREATE UNIQUE INDEX position_risk_schedule_digest_uq
    ON position_risk_schedule (schedule_digest);

CREATE TABLE position_risk_model (
    model_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id uuid NOT NULL
        REFERENCES capital_feasibility_assessment(assessment_id),
    schedule_id uuid NOT NULL
        REFERENCES position_risk_schedule(schedule_id),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    admitted boolean NOT NULL,
    rejection_reason text,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (result_digest = position_risk_result_digest(result - 'result_digest')),
    CHECK ((result->>'bankroll_cents')::bigint = capital_feasibility_bankroll_cents()),
    CHECK ((result->>'utilization_ceiling_cents')::bigint
        = capital_feasibility_utilization_ceiling_cents()),
    CHECK ((result->>'position_risk_cents')::bigint
        >= (result->>'contractual_max_cents')::bigint),
    CHECK (result ? 'entry_slippage_cents'),
    CHECK (result ? 'exit_slippage_cents'),
    CHECK (result ? 'assignment_exposure_cents'),
    CHECK (admitted = ((result->>'admitted')::boolean)),
    CHECK (
        (admitted AND rejection_reason IS NULL)
        OR (NOT admitted AND btrim(rejection_reason) <> '')
    ),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('position_risk_model');

CREATE UNIQUE INDEX position_risk_model_identity_uq
    ON position_risk_model (assessment_id, schedule_id);

CREATE FUNCTION guard_position_risk_write() RETURNS trigger
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

CREATE TRIGGER position_risk_schedule_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON position_risk_schedule
    FOR EACH STATEMENT EXECUTE FUNCTION guard_position_risk_write();

CREATE TRIGGER position_risk_model_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON position_risk_model
    FOR EACH STATEMENT EXECUTE FUNCTION guard_position_risk_write();

CREATE FUNCTION guard_position_risk_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.position_risk_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the position risk workflow', TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER position_risk_schedule_insert_guard
    BEFORE INSERT ON position_risk_schedule
    FOR EACH ROW EXECUTE FUNCTION guard_position_risk_insert();

CREATE TRIGGER position_risk_model_insert_guard
    BEFORE INSERT ON position_risk_model
    FOR EACH ROW EXECUTE FUNCTION guard_position_risk_insert();

CREATE FUNCTION register_position_risk_schedule(
    spec_value jsonb,
    source_lineage_value jsonb
) RETURNS position_risk_schedule
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    digest_value text;
    existing position_risk_schedule%ROWTYPE;
    created position_risk_schedule%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'position risk schedule arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM position_risk_assert_schedule(spec_value);
    digest_value := position_risk_schedule_digest(spec_value);
    PERFORM pg_advisory_xact_lock(hashtextextended(digest_value, 45023));

    SELECT * INTO existing
    FROM position_risk_schedule
    WHERE schedule_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.position_risk_write', 'on', true);
    BEGIN
        INSERT INTO position_risk_schedule (
            schedule_key, spec, schedule_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            btrim(spec_value->>'schedule_key'), spec_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.position_risk_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.position_risk_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION compute_position_risk(
    assessment_id_value uuid,
    risk_schedule_spec jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    assessment_row capital_feasibility_assessment%ROWTYPE;
    fee_row capital_feasibility_fee_schedule%ROWTYPE;
    kind text;
    leg jsonb;
    contract_row option_chain_contract%ROWTYPE;
    deliverable_row option_deliverable_version%ROWTYPE;
    side_value text;
    share_cents bigint;
    premium_cents bigint;
    slipped_premium bigint;
    buy_premium bigint := 0;
    sell_premium bigint := 0;
    slipped_buy bigint := 0;
    slipped_sell bigint := 0;
    short_count integer := 0;
    assignment_exposure bigint := 0;
    multiplier numeric;
    width_cents bigint;
    buy_strike numeric;
    sell_strike numeric;
    contractual_max bigint;
    slipped_collateral bigint;
    entry_slippage bigint;
    exit_slippage bigint;
    entry_bps bigint;
    exit_bps bigint;
    assignment_fee_unit bigint;
    assignment_fee bigint;
    entry_fees bigint;
    exit_fees bigint;
    position_risk bigint;
    entry_capital bigint;
    bankroll bigint;
    utilization bigint;
    admitted boolean;
    rejection text;
    result jsonb;
BEGIN
    PERFORM position_risk_assert_schedule(risk_schedule_spec);
    IF assessment_id_value IS NULL THEN
        RAISE EXCEPTION 'position risk assessment is missing'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO assessment_row
    FROM capital_feasibility_assessment
    WHERE assessment_id = assessment_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'position risk assessment is missing'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO fee_row
    FROM capital_feasibility_fee_schedule
    WHERE schedule_id = assessment_row.schedule_id;

    kind := assessment_row.structure->>'structure_kind';
    contractual_max := (assessment_row.result->>'collateral_cents')::bigint;
    entry_fees := (assessment_row.result->>'total_fee_cents')::bigint;
    entry_bps := capital_feasibility_nonneg_int(
        risk_schedule_spec->'entry_slippage_bps');
    exit_bps := capital_feasibility_nonneg_int(
        risk_schedule_spec->'exit_slippage_bps');
    assignment_fee_unit := capital_feasibility_nonneg_int(
        risk_schedule_spec->'assignment_fee_cents_per_contract');

    FOR leg IN SELECT jsonb_array_elements(assessment_row.structure->'legs') LOOP
        side_value := btrim(leg->>'side');
        SELECT * INTO contract_row
        FROM option_chain_contract
        WHERE contract_id = (btrim(leg->>'contract_id'))::uuid
          AND snapshot_id = assessment_row.snapshot_id;
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
        multiplier := deliverable_row.multiplier;
        premium_cents := share_cents * deliverable_row.multiplier::bigint;
        slipped_premium := position_risk_apply_bps(
            premium_cents, entry_bps, side_value = 'buy');
        IF slipped_premium IS NULL THEN
            RAISE EXCEPTION
                'position risk schedule is missing required inputs'
                USING ERRCODE = '22023';
        END IF;
        IF side_value = 'buy' THEN
            buy_premium := buy_premium + premium_cents;
            slipped_buy := slipped_buy + slipped_premium;
            buy_strike := contract_row.strike_price;
        ELSE
            sell_premium := sell_premium + premium_cents;
            slipped_sell := slipped_sell + slipped_premium;
            sell_strike := contract_row.strike_price;
            short_count := short_count + 1;
            assignment_exposure := assignment_exposure
                + round(contract_row.strike_price * 100 * multiplier)::bigint;
        END IF;
    END LOOP;

    IF kind IN ('long_call', 'long_put') THEN
        slipped_collateral := slipped_buy;
    ELSE
        width_cents := round(abs(buy_strike - sell_strike) * 100 * multiplier)::bigint;
        IF kind IN ('debit_call_vertical', 'debit_put_vertical') THEN
            slipped_collateral := slipped_buy - slipped_sell;
        ELSE
            slipped_collateral := width_cents - (slipped_sell - slipped_buy);
            IF slipped_collateral < 0 THEN
                slipped_collateral := width_cents;
            END IF;
        END IF;
    END IF;
    IF slipped_collateral < contractual_max THEN
        slipped_collateral := contractual_max;
    END IF;

    entry_slippage := slipped_collateral - contractual_max;
    exit_fees := entry_fees;
    exit_slippage := coalesce(position_risk_apply_bps(
        buy_premium + sell_premium, exit_bps, true) - (buy_premium + sell_premium),
        0);
    assignment_fee := short_count * assignment_fee_unit;
    position_risk := slipped_collateral + entry_fees + exit_fees
        + exit_slippage + assignment_fee;
    IF position_risk < contractual_max THEN
        position_risk := contractual_max;
    END IF;
    entry_capital := slipped_collateral + entry_fees;
    bankroll := capital_feasibility_bankroll_cents();
    utilization := capital_feasibility_utilization_ceiling_cents();

    admitted := true;
    rejection := NULL;
    IF assignment_exposure > bankroll THEN
        admitted := false;
        rejection := 'assignment_exposure_exceeds_bankroll';
    ELSIF position_risk > bankroll THEN
        admitted := false;
        rejection := 'position_risk_exceeds_bankroll';
    ELSIF position_risk > utilization THEN
        admitted := false;
        rejection := 'position_risk_exceeds_utilization_ceiling';
    ELSIF entry_capital > bankroll THEN
        admitted := false;
        rejection := 'entry_capital_exceeds_bankroll';
    END IF;

    result := jsonb_build_object(
        'engine', 'position_risk_v1',
        'bankroll_cents', bankroll,
        'utilization_ceiling_cents', utilization,
        'contractual_max_cents', contractual_max,
        'entry_slippage_cents', entry_slippage,
        'exit_slippage_cents', exit_slippage,
        'entry_fee_cents', entry_fees,
        'exit_fee_cents', exit_fees,
        'assignment_fee_cents', assignment_fee,
        'assignment_exposure_cents', assignment_exposure,
        'position_risk_cents', position_risk,
        'entry_capital_cents', entry_capital,
        'admitted', admitted,
        'rejection_reason', to_jsonb(rejection)
    );
    RETURN result || jsonb_build_object(
        'result_digest', position_risk_result_digest(result));
END;
$$;

CREATE FUNCTION record_position_risk_model(
    assessment_id_value uuid,
    risk_schedule_spec jsonb,
    source_lineage_value jsonb
) RETURNS position_risk_model
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    schedule_row position_risk_schedule%ROWTYPE;
    computed jsonb;
    stored_result jsonb;
    digest_value text;
    existing position_risk_model%ROWTYPE;
    created position_risk_model%ROWTYPE;
    admitted_value boolean;
    rejection_value text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'position risk arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO schedule_row
    FROM register_position_risk_schedule(
        risk_schedule_spec, source_lineage_value);

    computed := compute_position_risk(assessment_id_value, schedule_row.spec);
    stored_result := computed - 'result_digest';
    digest_value := position_risk_result_digest(stored_result);
    admitted_value := (stored_result->>'admitted')::boolean;
    IF jsonb_typeof(stored_result->'rejection_reason') = 'string' THEN
        rejection_value := stored_result->>'rejection_reason';
    ELSE
        rejection_value := NULL;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        assessment_id_value::text || ':' || schedule_row.schedule_id::text,
        45024));

    SELECT * INTO existing
    FROM position_risk_model
    WHERE assessment_id = assessment_id_value
      AND schedule_id = schedule_row.schedule_id;
    IF FOUND THEN
        IF existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'position risk model is already recorded with a different result'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.position_risk_write', 'on', true);
    BEGIN
        INSERT INTO position_risk_model (
            assessment_id, schedule_id, result, result_digest,
            admitted, rejection_reason,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            assessment_id_value, schedule_row.schedule_id,
            stored_result, digest_value, admitted_value, rejection_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config('market_mate.position_risk_write', 'off', true);
            SELECT * INTO existing
            FROM position_risk_model
            WHERE assessment_id = assessment_id_value
              AND schedule_id = schedule_row.schedule_id;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.result_digest IS DISTINCT FROM digest_value THEN
                RAISE EXCEPTION
                    'position risk model is already recorded with a different result'
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.position_risk_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.position_risk_write', 'off', true);

    PERFORM append_audit_event(
        'position-risk:' || created.model_id::text,
        'research.position_risk_modeled',
        now(),
        jsonb_build_object(
            'model_id', created.model_id,
            'assessment_id', assessment_id_value,
            'schedule_id', schedule_row.schedule_id,
            'position_risk_cents', stored_result->>'position_risk_cents',
            'assignment_exposure_cents', stored_result->>'assignment_exposure_cents',
            'admitted', admitted_value,
            'rejection_reason', to_jsonb(rejection_value),
            'result_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_position_risk_schedule(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION compute_position_risk(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_position_risk_model(uuid, jsonb, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON position_risk_schedule FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON position_risk_model FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
