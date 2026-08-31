-- WU-30 Sealed Release Holdout custody: one-time tamper-evident seal of the
-- chronologically latest >=60 trading-day segment, consumed by a single
-- Holdout Evaluation (issue #42). A failed evaluation still consumes the
-- holdout. A second evaluation attempt is refused.

CREATE FUNCTION release_holdout_session_dates_are_valid(session_dates_value date[])
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
    IF n < 60 THEN
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

CREATE FUNCTION release_holdout_estimator_names(spec_value jsonb)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    node jsonb;
    names text[] := '{}';
BEGIN
    node := experiment_preregistration_spec_node(spec_value, 'estimators', 'estimator');
    IF jsonb_typeof(node) = 'string' THEN
        IF coalesce(btrim(node #>> '{}'), '') = '' THEN
            RETURN '{}';
        END IF;
        RETURN ARRAY[btrim(node #>> '{}')];
    ELSIF jsonb_typeof(node) = 'array' THEN
        SELECT coalesce(array_agg(btrim(x) ORDER BY x), '{}')
        INTO names
        FROM (
            SELECT DISTINCT jsonb_array_elements_text(node) AS x
        ) s
        WHERE coalesce(btrim(s.x), '') <> '';
        RETURN coalesce(names, '{}');
    ELSIF jsonb_typeof(node) = 'object' THEN
        SELECT coalesce(array_agg(s.key ORDER BY s.key), '{}')
        INTO names
        FROM jsonb_each(node) AS s(key, value)
        WHERE coalesce(btrim(s.key), '') <> '';
        RETURN coalesce(names, '{}');
    END IF;
    RETURN '{}';
END;
$$;

CREATE FUNCTION release_holdout_result_matches_registration(
    spec_value jsonb,
    result_value jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[];
BEGIN
    IF jsonb_typeof(result_value) IS DISTINCT FROM 'object'
       OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(result_value)) THEN
        RETURN false;
    END IF;
    allowed := release_holdout_estimator_names(spec_value);
    IF coalesce(cardinality(allowed), 0) < 1 THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_object_keys(result_value) k
        WHERE NOT (k = ANY (allowed))
    ) THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM unnest(allowed) AS a(name)
        WHERE NOT (result_value ? a.name)
    ) THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION release_holdout_seal_digest(
    session_dates_value date[]
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            jsonb_build_object(
                'first_trading_date', to_char(session_dates_value[1], 'YYYY-MM-DD'),
                'last_trading_date', to_char(
                    session_dates_value[cardinality(session_dates_value)],
                    'YYYY-MM-DD'),
                'session_count', cardinality(session_dates_value),
                'session_dates', (
                    SELECT coalesce(jsonb_agg(to_char(d, 'YYYY-MM-DD') ORDER BY d), '[]'::jsonb)
                    FROM unnest(session_dates_value) AS d
                )
            )::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE TABLE release_holdout_seal (
    holdout_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    first_trading_date date NOT NULL,
    last_trading_date date NOT NULL,
    session_count integer NOT NULL CHECK (session_count >= 60),
    session_dates date[] NOT NULL,
    as_of_at timestamptz NOT NULL,
    seal_digest text NOT NULL CHECK (seal_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (first_trading_date <= last_trading_date),
    CHECK (session_count = cardinality(session_dates)),
    CHECK (session_dates[1] = first_trading_date),
    CHECK (session_dates[session_count] = last_trading_date),
    CHECK (release_holdout_session_dates_are_valid(session_dates)),
    CHECK (seal_digest = release_holdout_seal_digest(session_dates)),
    UNIQUE (first_trading_date, last_trading_date),
    UNIQUE (seal_digest)
);

SELECT register_evidence_table('release_holdout_seal');

CREATE TABLE release_holdout_evaluation (
    evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    holdout_id uuid NOT NULL UNIQUE REFERENCES release_holdout_seal(holdout_id),
    registration_id uuid NOT NULL
        REFERENCES experiment_preregistration(registration_id),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    gate_passed boolean NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        result_digest
        = encode(digest(convert_to(result::text, 'UTF8'), 'sha256'), 'hex')
    )
);

SELECT register_evidence_table('release_holdout_evaluation');

CREATE INDEX release_holdout_evaluation_registration_idx
    ON release_holdout_evaluation (registration_id, receipt_time);

CREATE FUNCTION guard_release_holdout_seal_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'release_holdout_seal is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_release_holdout_evaluation_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'release_holdout_evaluation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER release_holdout_seal_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON release_holdout_seal
    FOR EACH STATEMENT EXECUTE FUNCTION guard_release_holdout_seal_write();
CREATE TRIGGER release_holdout_evaluation_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON release_holdout_evaluation
    FOR EACH STATEMENT EXECUTE FUNCTION guard_release_holdout_evaluation_write();

CREATE FUNCTION guard_release_holdout_seal_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.release_holdout_seal_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'release_holdout_seal writes must go through seal_release_holdout'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_release_holdout_evaluation_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.release_holdout_evaluation_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'release_holdout_evaluation writes must go through evaluate_release_holdout'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER release_holdout_seal_insert_guard
    BEFORE INSERT ON release_holdout_seal
    FOR EACH ROW EXECUTE FUNCTION guard_release_holdout_seal_insert();
CREATE TRIGGER release_holdout_evaluation_insert_guard
    BEFORE INSERT ON release_holdout_evaluation
    FOR EACH ROW EXECUTE FUNCTION guard_release_holdout_evaluation_insert();

CREATE FUNCTION release_holdout_is_consumed(holdout_id_value uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM release_holdout_evaluation e
        WHERE e.holdout_id = holdout_id_value
    );
$$;

CREATE FUNCTION seal_release_holdout(
    session_dates_value date[],
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS release_holdout_seal
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    first_date date;
    last_date date;
    as_of_date date;
    digest_value text;
    existing release_holdout_seal%ROWTYPE;
    calendar_dates date[];
    suffix date[];
    created release_holdout_seal%ROWTYPE;
BEGIN
    IF as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'release holdout seal identity or as_of is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT release_holdout_session_dates_are_valid(session_dates_value) THEN
        RAISE EXCEPTION
            'release holdout must be a strictly increasing sequence of at least 60 trading days'
            USING ERRCODE = '22023';
    END IF;

    n := cardinality(session_dates_value);
    first_date := session_dates_value[1];
    last_date := session_dates_value[n];
    as_of_date := (as_of_value AT TIME ZONE 'UTC')::date;
    IF last_date > as_of_date THEN
        RAISE EXCEPTION
            'release holdout last trading date must not be after as_of'
            USING ERRCODE = '22023';
    END IF;

    calendar_dates := core_indicator_session_calendar_as_of(as_of_value);
    IF coalesce(cardinality(calendar_dates), 0) > 0 THEN
        IF cardinality(calendar_dates) < n THEN
            RAISE EXCEPTION
                'release holdout requires % sessions visible at as_of; the calendar has %',
                n, cardinality(calendar_dates)
                USING ERRCODE = '22023';
        END IF;
        suffix := calendar_dates[cardinality(calendar_dates) - n + 1
                                 : cardinality(calendar_dates)];
        IF suffix IS DISTINCT FROM session_dates_value THEN
            RAISE EXCEPTION
                'release holdout must be the most recent % trading days visible at as_of',
                n
                USING ERRCODE = '22023';
        END IF;
    END IF;

    digest_value := release_holdout_seal_digest(session_dates_value);

    PERFORM pg_advisory_xact_lock(hashtextextended('release-holdout', 31023));

    SELECT * INTO existing
    FROM release_holdout_seal
    WHERE seal_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM release_holdout_seal s
        WHERE NOT release_holdout_is_consumed(s.holdout_id)
    ) THEN
        RAISE EXCEPTION
            'an unconsumed release holdout is already sealed'
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.release_holdout_seal_write', 'on', true);
    BEGIN
        INSERT INTO release_holdout_seal (
            first_trading_date, last_trading_date, session_count, session_dates,
            as_of_at, seal_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            first_date, last_date, n, session_dates_value,
            as_of_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.release_holdout_seal_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.release_holdout_seal_write', 'off', true);

    PERFORM append_audit_event(
        'release-holdout-seal:' || created.holdout_id::text,
        'research.release_holdout_sealed',
        now(),
        jsonb_build_object(
            'holdout_id', created.holdout_id,
            'first_trading_date', first_date,
            'last_trading_date', last_date,
            'session_count', n,
            'seal_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE FUNCTION evaluate_release_holdout(
    holdout_id_value uuid,
    registration_id_value uuid,
    result_value jsonb,
    gate_passed_value boolean,
    source_lineage_value jsonb
) RETURNS release_holdout_evaluation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    seal_row release_holdout_seal%ROWTYPE;
    registration_row experiment_preregistration%ROWTYPE;
    existing release_holdout_evaluation%ROWTYPE;
    created release_holdout_evaluation%ROWTYPE;
BEGIN
    IF holdout_id_value IS NULL
       OR registration_id_value IS NULL
       OR gate_passed_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'release holdout evaluation arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO seal_row
    FROM release_holdout_seal
    WHERE holdout_id = holdout_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'release holdout % is not sealed', holdout_id_value
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO registration_row
    FROM experiment_preregistration
    WHERE registration_id = registration_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'experiment preregistration % is not registered',
            registration_id_value
            USING ERRCODE = '22023';
    END IF;
    IF NOT release_holdout_result_matches_registration(
        registration_row.spec, result_value
    ) THEN
        RAISE EXCEPTION
            'holdout evaluation result must contain only preregistered estimator keys'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(holdout_id_value::text, 31024));

    SELECT * INTO existing
    FROM release_holdout_evaluation
    WHERE holdout_id = holdout_id_value;
    IF FOUND THEN
        RAISE EXCEPTION
            'release holdout % is already consumed; a second evaluation is refused',
            holdout_id_value
            USING ERRCODE = '23505';
    END IF;

    PERFORM set_config('market_mate.release_holdout_evaluation_write', 'on', true);
    BEGIN
        INSERT INTO release_holdout_evaluation (
            holdout_id, registration_id, result, result_digest, gate_passed,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            holdout_id_value, registration_id_value, result_value,
            encode(digest(convert_to(result_value::text, 'UTF8'), 'sha256'), 'hex'),
            gate_passed_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.release_holdout_evaluation_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.release_holdout_evaluation_write', 'off', true);

    PERFORM append_audit_event(
        'release-holdout-eval:' || created.evaluation_id::text,
        'research.release_holdout_evaluated',
        now(),
        jsonb_build_object(
            'evaluation_id', created.evaluation_id,
            'holdout_id', holdout_id_value,
            'registration_id', registration_id_value,
            'gate_passed', gate_passed_value,
            'result_digest', created.result_digest,
            'consumed', true
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION seal_release_holdout(date[], timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION evaluate_release_holdout(uuid, uuid, jsonb, boolean, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON release_holdout_seal, release_holdout_evaluation
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
