-- WU-27 Core indicator computation: point-in-time Indicator Observations
-- bound to the Indicator Definition version actually in effect (issues #39,
-- #40). Experimental definitions are excluded from Core. Missing, incomplete,
-- disputed, and invalidated observations store no numeric substitute.

CREATE TABLE indicator_observation (
    observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_version_id uuid NOT NULL
        REFERENCES indicator_definition_version(definition_version_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    indicator_key text NOT NULL CHECK (btrim(indicator_key) <> ''),
    horizon integer NOT NULL CHECK (horizon IN (1, 5, 20, 60, 126, 252)),
    as_of_at timestamptz NOT NULL,
    observation_state text NOT NULL CHECK (observation_state IN (
        'current', 'stale', 'expired', 'missing', 'incomplete',
        'source_disputed', 'invalidated', 'not_applicable'
    )),
    observation_value numeric,
    value_units text NOT NULL CHECK (btrim(value_units) <> ''),
    precision_scale integer NOT NULL CHECK (precision_scale > 0),
    source_observation_ids uuid[] NOT NULL DEFAULT '{}',
    availability_from timestamptz,
    availability_to timestamptz,
    input_receipt_from timestamptz,
    input_receipt_to timestamptz,
    calculation_runtime text NOT NULL CHECK (btrim(calculation_runtime) <> ''),
    correction_status text NOT NULL CHECK (correction_status = 'uncorrected'),
    observation_digest text NOT NULL CHECK (observation_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (
            observation_state IN ('current', 'stale')
            AND observation_value IS NOT NULL
        )
        OR (
            observation_state IN (
                'expired', 'missing', 'incomplete', 'source_disputed',
                'invalidated', 'not_applicable'
            )
            AND observation_value IS NULL
        )
    ),
    UNIQUE (definition_version_id, security_id, as_of_at, horizon)
);

SELECT register_evidence_table('indicator_observation');

CREATE INDEX indicator_observation_lookup_idx
    ON indicator_observation (
        indicator_key, security_id, as_of_at, horizon, receipt_time
    );

CREATE TABLE indicator_evaluation_binding (
    binding_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evaluation_key text NOT NULL CHECK (btrim(evaluation_key) <> ''),
    indicator_key text NOT NULL CHECK (btrim(indicator_key) <> ''),
    definition_version_id uuid NOT NULL
        REFERENCES indicator_definition_version(definition_version_id),
    observation_id uuid NOT NULL REFERENCES indicator_observation(observation_id),
    as_of_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (evaluation_key, indicator_key)
);

SELECT register_evidence_table('indicator_evaluation_binding');

CREATE INDEX indicator_evaluation_binding_obs_idx
    ON indicator_evaluation_binding (observation_id, definition_version_id);

CREATE FUNCTION guard_indicator_observation_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'indicator_observation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_indicator_evaluation_binding_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'indicator_evaluation_binding is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER indicator_observation_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON indicator_observation
    FOR EACH STATEMENT EXECUTE FUNCTION guard_indicator_observation_write();
CREATE TRIGGER indicator_evaluation_binding_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON indicator_evaluation_binding
    FOR EACH STATEMENT EXECUTE FUNCTION guard_indicator_evaluation_binding_write();

CREATE FUNCTION guard_indicator_observation_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.indicator_observation_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'indicator_observation writes must go through compute_core_indicator_observation'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_indicator_evaluation_binding_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.indicator_evaluation_binding_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'indicator_evaluation_binding writes must go through bind_core_indicator_into_evaluation'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER indicator_observation_insert_guard
    BEFORE INSERT ON indicator_observation
    FOR EACH ROW EXECUTE FUNCTION guard_indicator_observation_insert();
CREATE TRIGGER indicator_evaluation_binding_insert_guard
    BEFORE INSERT ON indicator_evaluation_binding
    FOR EACH ROW EXECUTE FUNCTION guard_indicator_evaluation_binding_insert();

CREATE FUNCTION core_indicator_formula_kind(
    definition_value jsonb,
    horizon_value integer
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    formula_value text;
BEGIN
    IF definition_value IS NULL OR horizon_value IS NULL THEN
        RETURN NULL;
    END IF;
    formula_value := btrim(definition_value->>'formula');
    IF formula_value = 'close[t] / close[t-horizon] - 1'
       OR formula_value = 'close[t] / close[t-' || horizon_value::text || '] - 1' THEN
        RETURN 'close_return';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION core_indicator_input_is_declared(
    definition_value jsonb,
    input_name_value text
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(definition_value->'inputs') i
        WHERE jsonb_typeof(i.value) = 'object'
          AND i.value->>'name' = input_name_value
    );
$$;

CREATE FUNCTION core_indicator_definition_for_compute(
    indicator_key_value text,
    as_of_value timestamptz
) RETURNS indicator_definition_version
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row indicator_definition_version%ROWTYPE;
    lifecycle_state_value text;
BEGIN
    IF coalesce(btrim(indicator_key_value), '') = '' OR as_of_value IS NULL THEN
        RAISE EXCEPTION 'core indicator computation identity or as_of is invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT v.* INTO version_row
    FROM indicator_definition_version v
    WHERE v.indicator_key = indicator_key_value
      AND v.effective_from <= as_of_value
      AND v.receipt_time <= as_of_value
    ORDER BY v.version DESC
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no indicator definition is in effect for % at as_of',
            indicator_key_value
            USING ERRCODE = '22023';
    END IF;
    IF version_row.indicator_kind IS DISTINCT FROM 'core' THEN
        RAISE EXCEPTION
            'experimental indicators are excluded from Core computation'
            USING ERRCODE = '22023';
    END IF;

    lifecycle_state_value := coalesce(
        (SELECT l.to_state
         FROM indicator_definition_lifecycle l
         WHERE l.definition_version_id = version_row.definition_version_id
           AND l.receipt_time <= as_of_value
         ORDER BY l.receipt_time DESC, l.transition_id DESC
         LIMIT 1),
        version_row.definition_state
    );
    IF lifecycle_state_value IS DISTINCT FROM 'declared' THEN
        RAISE EXCEPTION
            'retired core indicator % cannot be computed at as_of',
            indicator_key_value
            USING ERRCODE = '22023';
    END IF;
    RETURN version_row;
END;
$$;

CREATE FUNCTION core_indicator_certified_mapping_ids_as_of(
    security_id_value uuid,
    as_of_value timestamptz,
    certified_sources_value text[]
) RETURNS uuid[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(array_agg(m2.mapping_id ORDER BY m2.mapping_id), '{}')
    FROM (
        SELECT m.mapping_id
        FROM instrument_mapping m
        WHERE m.security_id = security_id_value
          AND m.object_kind = 'security'
          AND m.receipt_time <= as_of_value
          AND m.valid_from <= as_of_value
          AND (m.valid_to IS NULL OR m.valid_to > as_of_value)
          AND m.provider = ANY (certified_sources_value)
          AND (
            SELECT t.to_lifecycle
            FROM instrument_mapping_transition t
            WHERE t.mapping_id = m.mapping_id
              AND t.receipt_time <= as_of_value
            ORDER BY t.receipt_time DESC,
                     (CASE t.to_lifecycle
                        WHEN 'retired' THEN 4
                        WHEN 'suspended' THEN 3
                        WHEN 'certified' THEN 2
                        WHEN 'corroborated' THEN 1
                        ELSE 0 END) DESC,
                     t.transition_id
            LIMIT 1
          ) = 'certified'
    ) m2;
$$;

CREATE FUNCTION core_indicator_session_calendar_as_of(as_of_value timestamptz)
RETURNS date[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(array_agg(d ORDER BY d), '{}')
    FROM (
        SELECT DISTINCT o.trading_date AS d
        FROM eod_price_observation o
        WHERE o.available_at <= as_of_value
          AND o.receipt_time <= as_of_value
    ) s;
$$;

CREATE FUNCTION core_indicator_observation_digest(
    definition_version_id_value uuid,
    security_id_value uuid,
    horizon_value integer,
    as_of_value timestamptz,
    observation_state_value text,
    observation_value_value numeric,
    source_observation_ids_value uuid[],
    availability_from_value timestamptz,
    availability_to_value timestamptz,
    input_receipt_from_value timestamptz,
    input_receipt_to_value timestamptz,
    calculation_runtime_value text,
    correction_status_value text
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            jsonb_build_object(
                'definition_version_id', definition_version_id_value,
                'security_id', security_id_value,
                'horizon', horizon_value,
                'as_of', to_char(
                    as_of_value AT TIME ZONE 'UTC',
                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                'state', observation_state_value,
                'value', observation_value_value,
                'source_observation_ids', (
                    SELECT coalesce(jsonb_agg(x ORDER BY x), '[]'::jsonb)
                    FROM unnest(coalesce(source_observation_ids_value, '{}'::uuid[])) AS x
                ),
                'availability_from', CASE WHEN availability_from_value IS NULL THEN NULL
                    ELSE to_char(availability_from_value AT TIME ZONE 'UTC',
                                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
                'availability_to', CASE WHEN availability_to_value IS NULL THEN NULL
                    ELSE to_char(availability_to_value AT TIME ZONE 'UTC',
                                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
                'input_receipt_from', CASE WHEN input_receipt_from_value IS NULL THEN NULL
                    ELSE to_char(input_receipt_from_value AT TIME ZONE 'UTC',
                                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
                'input_receipt_to', CASE WHEN input_receipt_to_value IS NULL THEN NULL
                    ELSE to_char(input_receipt_to_value AT TIME ZONE 'UTC',
                                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
                'calculation_runtime', calculation_runtime_value,
                'correction_status', correction_status_value
            )::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION preview_core_indicator_observation(
    indicator_key_value text,
    security_id_value uuid,
    as_of_value timestamptz,
    horizon_value integer
) RETURNS indicator_observation
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row indicator_definition_version%ROWTYPE;
    created indicator_observation%ROWTYPE;
    formula_kind_value text;
    certified_sources_value text[];
    mapping_ids uuid[];
    mapping_id_value uuid;
    bar eod_price_observation%ROWTYPE;
    close_ids uuid[] := '{}';
    close_dates date[] := '{}';
    close_values numeric[] := '{}';
    close_available timestamptz[] := '{}';
    close_receipts timestamptz[] := '{}';
    n integer;
    needed integer;
    close_t numeric;
    close_th numeric;
    used_ids uuid[];
    range_min numeric;
    range_max numeric;
    lag_limit integer;
    calendar_dates date[];
    sessions_after integer;
    state_value text;
    value_value numeric;
    units_value text;
    precision_value integer;
    availability_from_value timestamptz;
    availability_to_value timestamptz;
    input_receipt_from_value timestamptz;
    input_receipt_to_value timestamptz;
    runtime_value text := 'core-close-return';
BEGIN
    IF security_id_value IS NULL
       OR as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR horizon_value IS NULL THEN
        RAISE EXCEPTION 'core indicator observation identity or as_of is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM security s
        WHERE s.security_id = security_id_value
          AND s.receipt_time <= as_of_value
    ) THEN
        RAISE EXCEPTION 'security % is not known at as_of', security_id_value
            USING ERRCODE = '22023';
    END IF;

    version_row := core_indicator_definition_for_compute(indicator_key_value, as_of_value);
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(version_row.definition->'canonical_horizons') h
        WHERE (h.value)::numeric = horizon_value
    ) THEN
        RAISE EXCEPTION 'horizon % is not a canonical horizon of indicator %',
            horizon_value, indicator_key_value
            USING ERRCODE = '22023';
    END IF;

    formula_kind_value := core_indicator_formula_kind(version_row.definition, horizon_value);
    IF formula_kind_value IS DISTINCT FROM 'close_return' THEN
        RAISE EXCEPTION
            'core indicator formula is not a computable Core family'
            USING ERRCODE = '22023';
    END IF;
    IF NOT core_indicator_input_is_declared(version_row.definition, 'session_close') THEN
        RAISE EXCEPTION
            'close-return computation requires a declared session_close input'
            USING ERRCODE = '22023';
    END IF;

    SELECT coalesce(array_agg(s ORDER BY s), '{}')
    INTO certified_sources_value
    FROM jsonb_array_elements_text(version_row.definition->'certified_sources') s;

    units_value := version_row.definition->>'units';
    precision_value := (version_row.definition->'precision')::integer;
    range_min := (version_row.definition->'valid_ranges'->>'min')::numeric;
    range_max := (version_row.definition->'valid_ranges'->>'max')::numeric;
    lag_limit := (version_row.definition->'freshness'->>'max_receipt_lag_sessions')::integer;
    IF precision_value IS NULL OR range_min IS NULL OR range_max IS NULL
       OR lag_limit IS NULL OR lag_limit < 0 THEN
        RAISE EXCEPTION 'core indicator freshness, precision, or valid_ranges is incomplete'
            USING ERRCODE = '22023';
    END IF;

    mapping_ids := core_indicator_certified_mapping_ids_as_of(
        security_id_value, as_of_value, certified_sources_value);
    state_value := NULL;
    value_value := NULL;
    used_ids := '{}';

    IF coalesce(array_length(mapping_ids, 1), 0) = 0 THEN
        state_value := 'missing';
    ELSIF array_length(mapping_ids, 1) > 1 THEN
        state_value := 'source_disputed';
    ELSE
        mapping_id_value := mapping_ids[1];
        FOR bar IN
            SELECT DISTINCT ON (o.trading_date) o.*
            FROM eod_price_observation o
            JOIN source_registry_version srv
              ON srv.source_version_id = o.source_registry_version_id
            JOIN source_registry sr ON sr.source_id = srv.source_id
            WHERE o.instrument_mapping_id = mapping_id_value
              AND o.available_at <= as_of_value
              AND o.receipt_time <= as_of_value
              AND sr.source_key = ANY (certified_sources_value)
            ORDER BY o.trading_date, o.receipt_time DESC, o.revision DESC
        LOOP
            IF bar.observation_status IN ('complete', 'revised')
               AND bar.close_price IS NOT NULL THEN
                close_ids := close_ids || bar.observation_id;
                close_dates := close_dates || bar.trading_date;
                close_values := close_values || bar.close_price;
                close_available := close_available || bar.available_at;
                close_receipts := close_receipts || bar.receipt_time;
            END IF;
        END LOOP;

        n := coalesce(array_length(close_values, 1), 0);
        needed := horizon_value + 1;
        IF n = 0 THEN
            state_value := 'missing';
        ELSIF n < needed THEN
            state_value := 'incomplete';
            used_ids := close_ids;
            availability_from_value := close_available[1];
            availability_to_value := close_available[n];
            input_receipt_from_value := close_receipts[1];
            input_receipt_to_value := close_receipts[n];
        ELSE
            close_t := close_values[n];
            close_th := close_values[n - horizon_value];
            used_ids := ARRAY[close_ids[n - horizon_value], close_ids[n]];
            availability_from_value := close_available[n - horizon_value];
            availability_to_value := close_available[n];
            input_receipt_from_value := close_receipts[n - horizon_value];
            input_receipt_to_value := close_receipts[n];
            value_value := round((close_t / close_th) - 1, precision_value);
            IF value_value < range_min OR value_value > range_max THEN
                state_value := 'invalidated';
                value_value := NULL;
            ELSE
                calendar_dates := core_indicator_session_calendar_as_of(as_of_value);
                SELECT count(*)::integer INTO sessions_after
                FROM unnest(calendar_dates) d
                WHERE d > close_dates[n];
                IF sessions_after > lag_limit THEN
                    state_value := 'stale';
                ELSE
                    state_value := 'current';
                END IF;
            END IF;
        END IF;
    END IF;

    created.observation_id := gen_random_uuid();
    created.definition_version_id := version_row.definition_version_id;
    created.security_id := security_id_value;
    created.indicator_key := version_row.indicator_key;
    created.horizon := horizon_value;
    created.as_of_at := as_of_value;
    created.observation_state := state_value;
    created.observation_value := value_value;
    created.value_units := units_value;
    created.precision_scale := precision_value;
    created.source_observation_ids := used_ids;
    created.availability_from := availability_from_value;
    created.availability_to := availability_to_value;
    created.input_receipt_from := input_receipt_from_value;
    created.input_receipt_to := input_receipt_to_value;
    created.calculation_runtime := runtime_value;
    created.correction_status := 'uncorrected';
    created.source_lineage := '{}'::jsonb;
    created.receipt_time := as_of_value;
    created.record_environment := 'local_research';
    created.observation_digest := core_indicator_observation_digest(
        created.definition_version_id, created.security_id, created.horizon,
        created.as_of_at, created.observation_state, created.observation_value,
        created.source_observation_ids, created.availability_from,
        created.availability_to, created.input_receipt_from,
        created.input_receipt_to, created.calculation_runtime,
        created.correction_status);
    RETURN created;
END;
$$;

CREATE FUNCTION compute_core_indicator_observation(
    indicator_key_value text,
    security_id_value uuid,
    as_of_value timestamptz,
    horizon_value integer,
    source_lineage_value jsonb
) RETURNS indicator_observation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    preview_row indicator_observation%ROWTYPE;
    existing indicator_observation%ROWTYPE;
    created indicator_observation%ROWTYPE;
    lock_key text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'core indicator observation source_lineage is invalid'
            USING ERRCODE = '22023';
    END IF;

    preview_row := preview_core_indicator_observation(
        indicator_key_value, security_id_value, as_of_value, horizon_value);

    lock_key := preview_row.definition_version_id::text || ':'
        || preview_row.security_id::text || ':'
        || to_char(preview_row.as_of_at AT TIME ZONE 'UTC',
                   'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || ':'
        || preview_row.horizon::text;
    PERFORM pg_advisory_xact_lock(hashtextextended(lock_key, 28023));

    SELECT * INTO existing
    FROM indicator_observation o
    WHERE o.definition_version_id = preview_row.definition_version_id
      AND o.security_id = preview_row.security_id
      AND o.as_of_at = preview_row.as_of_at
      AND o.horizon = preview_row.horizon;
    IF FOUND THEN
        IF existing.observation_digest IS DISTINCT FROM preview_row.observation_digest THEN
            RAISE EXCEPTION
                'stored core indicator observation digest diverges from point-in-time replay'
                USING ERRCODE = '55000';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.indicator_observation_write', 'on', true);
    BEGIN
        INSERT INTO indicator_observation (
            definition_version_id, security_id, indicator_key, horizon, as_of_at,
            observation_state, observation_value, value_units, precision_scale,
            source_observation_ids, availability_from, availability_to,
            input_receipt_from, input_receipt_to, calculation_runtime,
            correction_status, observation_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            preview_row.definition_version_id, preview_row.security_id,
            preview_row.indicator_key, preview_row.horizon, preview_row.as_of_at,
            preview_row.observation_state, preview_row.observation_value,
            preview_row.value_units, preview_row.precision_scale,
            preview_row.source_observation_ids, preview_row.availability_from,
            preview_row.availability_to, preview_row.input_receipt_from,
            preview_row.input_receipt_to, preview_row.calculation_runtime,
            preview_row.correction_status, preview_row.observation_digest,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.indicator_observation_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.indicator_observation_write', 'off', true);

    PERFORM append_audit_event(
        'core-indicator-obs:' || created.observation_id::text,
        'research.core_indicator_computed',
        now(),
        jsonb_build_object(
            'observation_id', created.observation_id,
            'definition_version_id', created.definition_version_id,
            'indicator_key', created.indicator_key,
            'security_id', created.security_id,
            'horizon', created.horizon,
            'observation_state', created.observation_state,
            'observation_digest', created.observation_digest
        ),
        source_lineage_value,
        now(),
        'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION bind_core_indicator_into_evaluation(
    evaluation_key_value text,
    observation_id_value uuid,
    source_lineage_value jsonb
) RETURNS indicator_evaluation_binding
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    observation_row indicator_observation%ROWTYPE;
    existing indicator_evaluation_binding%ROWTYPE;
    created indicator_evaluation_binding%ROWTYPE;
BEGIN
    IF coalesce(btrim(evaluation_key_value), '') = ''
       OR observation_id_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'indicator evaluation binding arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO observation_row
    FROM indicator_observation
    WHERE observation_id = observation_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'indicator observation % is not registered', observation_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        evaluation_key_value || ':' || observation_row.indicator_key, 28024));

    SELECT * INTO existing
    FROM indicator_evaluation_binding
    WHERE evaluation_key = evaluation_key_value
      AND indicator_key = observation_row.indicator_key;
    IF FOUND THEN
        IF existing.definition_version_id IS DISTINCT FROM observation_row.definition_version_id
           OR existing.observation_id IS DISTINCT FROM observation_id_value THEN
            RAISE EXCEPTION
                'evaluation % already bound indicator % to definition version %',
                evaluation_key_value, observation_row.indicator_key,
                existing.definition_version_id
                USING ERRCODE = '23505';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.indicator_evaluation_binding_write', 'on', true);
    BEGIN
        INSERT INTO indicator_evaluation_binding (
            evaluation_key, indicator_key, definition_version_id, observation_id,
            as_of_at, source_lineage, receipt_time, record_environment
        ) VALUES (
            evaluation_key_value, observation_row.indicator_key,
            observation_row.definition_version_id, observation_id_value,
            observation_row.as_of_at, source_lineage_value,
            clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.indicator_evaluation_binding_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.indicator_evaluation_binding_write', 'off', true);

    PERFORM append_audit_event(
        'core-indicator-bind:' || created.binding_id::text,
        'research.indicator_evaluation_bound',
        now(),
        jsonb_build_object(
            'binding_id', created.binding_id,
            'evaluation_key', evaluation_key_value,
            'indicator_key', created.indicator_key,
            'definition_version_id', created.definition_version_id,
            'observation_id', created.observation_id
        ),
        source_lineage_value,
        now(),
        'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION indicator_observation_at(
    indicator_key_value text,
    security_id_value uuid,
    as_of_value timestamptz,
    horizon_value integer
) RETURNS indicator_observation
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT o
    FROM indicator_observation o
    WHERE o.indicator_key = indicator_key_value
      AND o.security_id = security_id_value
      AND o.horizon = horizon_value
      AND o.as_of_at <= as_of_value
      AND o.receipt_time <= as_of_value
    ORDER BY o.as_of_at DESC, o.receipt_time DESC, o.observation_id DESC
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION compute_core_indicator_observation(text, uuid, timestamptz, integer, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION bind_core_indicator_into_evaluation(text, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON indicator_observation, indicator_evaluation_binding
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
