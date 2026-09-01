-- WU-43 Operating Cost Register and cap tracking. Every expense records
-- payee, category, purpose, amount, timing, commitment, and envelope.
-- Reporting prominence is at least equal to profit reporting. Warning
-- thresholds are configurable below the #41 hard ceilings ($250/month,
-- $2,000 year one). Exceeding a hard ceiling fails closed for new
-- spending-classified work. Cost-model projections belong to WU-44.

CREATE FUNCTION operating_cost_hard_monthly_ceiling_cents()
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT 25000::bigint;
$$;

CREATE FUNCTION operating_cost_hard_year_one_ceiling_cents()
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT 200000::bigint;
$$;

CREATE FUNCTION operating_cost_profit_prominence()
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT 1;
$$;

CREATE FUNCTION operating_cost_envelope_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-operating-cost-envelope-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION operating_cost_entry_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-operating-cost-entry-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION operating_cost_assert_envelope(spec_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'envelope_key',
        'monthly_hard_ceiling_cents',
        'year_one_hard_ceiling_cents',
        'monthly_warn_threshold_cents',
        'year_one_warn_threshold_cents',
        'year_one_starts_at'
    ];
    monthly_hard bigint;
    year_hard bigint;
    monthly_warn bigint;
    year_warn bigint;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RAISE EXCEPTION 'operating cost envelope is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(spec_value->'envelope_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'envelope_key'), '') = '' THEN
        RAISE EXCEPTION 'operating cost envelope is invalid'
            USING ERRCODE = '22023';
    END IF;
    monthly_hard := capital_feasibility_nonneg_int(
        spec_value->'monthly_hard_ceiling_cents');
    year_hard := capital_feasibility_nonneg_int(
        spec_value->'year_one_hard_ceiling_cents');
    monthly_warn := capital_feasibility_nonneg_int(
        spec_value->'monthly_warn_threshold_cents');
    year_warn := capital_feasibility_nonneg_int(
        spec_value->'year_one_warn_threshold_cents');
    IF monthly_hard IS NULL OR monthly_hard < 1
       OR monthly_hard > operating_cost_hard_monthly_ceiling_cents()
       OR year_hard IS NULL OR year_hard < 1
       OR year_hard > operating_cost_hard_year_one_ceiling_cents()
       OR monthly_warn IS NULL
       OR year_warn IS NULL
       OR monthly_warn >= monthly_hard
       OR year_warn >= year_hard
       OR jsonb_typeof(spec_value->'year_one_starts_at') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'year_one_starts_at'), '') = '' THEN
        RAISE EXCEPTION
            'operating cost envelope weakens or omits #41 cap floors'
            USING ERRCODE = '22023';
    END IF;
    BEGIN
        IF NOT isfinite((spec_value->>'year_one_starts_at')::timestamptz) THEN
            RAISE EXCEPTION
                'operating cost envelope weakens or omits #41 cap floors'
                USING ERRCODE = '22023';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION
                'operating cost envelope weakens or omits #41 cap floors'
                USING ERRCODE = '22023';
    END;
END;
$$;

CREATE FUNCTION operating_cost_assert_entry(spec_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'payee', 'category', 'purpose', 'amount_cents',
        'occurred_at', 'commitment', 'envelope_key',
        'spending_classified', 'experiment_ref'
    ];
    amount bigint;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RAISE EXCEPTION 'operating cost entry is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(spec_value->'payee') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'payee'), '') = ''
       OR jsonb_typeof(spec_value->'category') IS DISTINCT FROM 'string'
       OR lower(btrim(spec_value->>'category')) NOT IN (
            'hosting', 'data', 'models', 'vendor', 'infrastructure', 'other')
       OR jsonb_typeof(spec_value->'purpose') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'purpose'), '') = ''
       OR jsonb_typeof(spec_value->'commitment') IS DISTINCT FROM 'string'
       OR lower(btrim(spec_value->>'commitment')) NOT IN (
            'one_time', 'monthly', 'annual')
       OR jsonb_typeof(spec_value->'envelope_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'envelope_key'), '') = ''
       OR jsonb_typeof(spec_value->'occurred_at') IS DISTINCT FROM 'string'
       OR jsonb_typeof(spec_value->'spending_classified') IS DISTINCT FROM 'boolean'
    THEN
        RAISE EXCEPTION 'operating cost entry is invalid'
            USING ERRCODE = '22023';
    END IF;
    amount := capital_feasibility_nonneg_int(spec_value->'amount_cents');
    IF amount IS NULL OR amount < 1 THEN
        RAISE EXCEPTION 'operating cost entry is invalid'
            USING ERRCODE = '22023';
    END IF;
    BEGIN
        IF NOT isfinite((spec_value->>'occurred_at')::timestamptz) THEN
            RAISE EXCEPTION 'operating cost entry is invalid'
                USING ERRCODE = '22023';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'operating cost entry is invalid'
                USING ERRCODE = '22023';
    END;
    IF spec_value ? 'experiment_ref'
       AND (jsonb_typeof(spec_value->'experiment_ref') IS DISTINCT FROM 'string'
            OR coalesce(btrim(spec_value->>'experiment_ref'), '') = '') THEN
        RAISE EXCEPTION 'operating cost entry is invalid'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE TABLE operating_cost_envelope (
    envelope_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    envelope_key text NOT NULL CHECK (btrim(envelope_key) <> ''),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    envelope_digest text NOT NULL CHECK (envelope_digest ~ '^[0-9a-f]{64}$'),
    monthly_hard_ceiling_cents bigint NOT NULL,
    year_one_hard_ceiling_cents bigint NOT NULL,
    monthly_warn_threshold_cents bigint NOT NULL,
    year_one_warn_threshold_cents bigint NOT NULL,
    year_one_starts_at timestamptz NOT NULL CHECK (isfinite(year_one_starts_at)),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (envelope_digest = operating_cost_envelope_digest(spec)),
    CHECK (envelope_key = btrim(spec->>'envelope_key')),
    CHECK (monthly_hard_ceiling_cents >= 1
        AND monthly_hard_ceiling_cents
            <= operating_cost_hard_monthly_ceiling_cents()),
    CHECK (year_one_hard_ceiling_cents >= 1
        AND year_one_hard_ceiling_cents
            <= operating_cost_hard_year_one_ceiling_cents()),
    CHECK (monthly_warn_threshold_cents >= 0
        AND monthly_warn_threshold_cents < monthly_hard_ceiling_cents),
    CHECK (year_one_warn_threshold_cents >= 0
        AND year_one_warn_threshold_cents < year_one_hard_ceiling_cents),
    CHECK (record_environment = 'local_research'),
    UNIQUE (envelope_key)
);

SELECT register_evidence_table('operating_cost_envelope');

CREATE TABLE operating_cost_entry (
    entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    envelope_id uuid NOT NULL
        REFERENCES operating_cost_envelope(envelope_id),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    entry_digest text NOT NULL CHECK (entry_digest ~ '^[0-9a-f]{64}$'),
    payee text NOT NULL CHECK (btrim(payee) <> ''),
    category text NOT NULL,
    purpose text NOT NULL CHECK (btrim(purpose) <> ''),
    amount_cents bigint NOT NULL CHECK (amount_cents >= 1),
    occurred_at timestamptz NOT NULL CHECK (isfinite(occurred_at)),
    commitment text NOT NULL CHECK (commitment IN ('one_time', 'monthly', 'annual')),
    spending_classified boolean NOT NULL,
    reporting_prominence integer NOT NULL
        CHECK (reporting_prominence >= operating_cost_profit_prominence()),
    cap_status jsonb NOT NULL CHECK (jsonb_typeof(cap_status) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (entry_digest = operating_cost_entry_digest(spec)),
    CHECK (payee = btrim(spec->>'payee')),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('operating_cost_entry');

CREATE UNIQUE INDEX operating_cost_entry_digest_uq
    ON operating_cost_entry (entry_digest);

CREATE FUNCTION guard_operating_cost_write() RETURNS trigger
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

CREATE TRIGGER operating_cost_envelope_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON operating_cost_envelope
    FOR EACH STATEMENT EXECUTE FUNCTION guard_operating_cost_write();

CREATE TRIGGER operating_cost_entry_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON operating_cost_entry
    FOR EACH STATEMENT EXECUTE FUNCTION guard_operating_cost_write();

CREATE FUNCTION guard_operating_cost_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.operating_cost_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the operating cost workflow', TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER operating_cost_envelope_insert_guard
    BEFORE INSERT ON operating_cost_envelope
    FOR EACH ROW EXECUTE FUNCTION guard_operating_cost_insert();

CREATE TRIGGER operating_cost_entry_insert_guard
    BEFORE INSERT ON operating_cost_entry
    FOR EACH ROW EXECUTE FUNCTION guard_operating_cost_insert();

CREATE FUNCTION register_operating_cost_envelope(
    spec_value jsonb,
    source_lineage_value jsonb
) RETURNS operating_cost_envelope
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    digest_value text;
    key_text text;
    existing operating_cost_envelope%ROWTYPE;
    created operating_cost_envelope%ROWTYPE;
    stored jsonb;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'operating cost envelope arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM operating_cost_assert_envelope(spec_value);
    key_text := btrim(spec_value->>'envelope_key');
    stored := spec_value || jsonb_build_object('envelope_key', key_text);
    digest_value := operating_cost_envelope_digest(stored);
    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 47023));

    SELECT * INTO existing
    FROM operating_cost_envelope
    WHERE envelope_key = key_text;
    IF FOUND THEN
        IF existing.envelope_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'operating cost envelope % is already recorded with a different spec',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.operating_cost_write', 'on', true);
    BEGIN
        INSERT INTO operating_cost_envelope (
            envelope_key, spec, envelope_digest,
            monthly_hard_ceiling_cents, year_one_hard_ceiling_cents,
            monthly_warn_threshold_cents, year_one_warn_threshold_cents,
            year_one_starts_at, source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, stored, digest_value,
            (stored->>'monthly_hard_ceiling_cents')::bigint,
            (stored->>'year_one_hard_ceiling_cents')::bigint,
            (stored->>'monthly_warn_threshold_cents')::bigint,
            (stored->>'year_one_warn_threshold_cents')::bigint,
            (stored->>'year_one_starts_at')::timestamptz,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.operating_cost_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.operating_cost_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION compute_operating_cost_cap_status(
    envelope_id_value uuid,
    occurred_at_value timestamptz,
    additional_cents bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
SET timezone = 'UTC'
AS $$
DECLARE
    env operating_cost_envelope%ROWTYPE;
    occurred_utc timestamp;
    month_start timestamp;
    month_end timestamp;
    year_start timestamp;
    year_end timestamp;
    monthly_spent bigint;
    year_spent bigint;
    monthly_add bigint;
    year_add bigint;
    monthly_after bigint;
    year_after bigint;
    monthly_state text;
    year_state text;
    warning boolean;
BEGIN
    IF envelope_id_value IS NULL OR occurred_at_value IS NULL
       OR NOT isfinite(occurred_at_value)
       OR additional_cents IS NULL OR additional_cents < 0 THEN
        RAISE EXCEPTION 'operating cost cap status arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO env
    FROM operating_cost_envelope
    WHERE envelope_id = envelope_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'operating cost envelope is not registered'
            USING ERRCODE = '22023';
    END IF;
    IF NOT isfinite(env.year_one_starts_at) THEN
        RAISE EXCEPTION 'operating cost envelope is not registered'
            USING ERRCODE = '22023';
    END IF;

    occurred_utc := occurred_at_value AT TIME ZONE 'UTC';
    month_start := date_trunc('month', occurred_utc);
    month_end := month_start + interval '1 month';
    year_start := env.year_one_starts_at AT TIME ZONE 'UTC';
    year_end := year_start + interval '365 days';

    SELECT coalesce(sum(amount_cents), 0) INTO monthly_spent
    FROM operating_cost_entry
    WHERE envelope_id = envelope_id_value
      AND spending_classified
      AND (occurred_at AT TIME ZONE 'UTC') >= month_start
      AND (occurred_at AT TIME ZONE 'UTC') < month_end;

    SELECT coalesce(sum(amount_cents), 0) INTO year_spent
    FROM operating_cost_entry
    WHERE envelope_id = envelope_id_value
      AND spending_classified
      AND (occurred_at AT TIME ZONE 'UTC') >= year_start
      AND (occurred_at AT TIME ZONE 'UTC') < year_end;

    monthly_add := additional_cents;
    IF occurred_utc >= year_start AND occurred_utc < year_end THEN
        year_add := additional_cents;
    ELSE
        year_add := 0;
    END IF;
    monthly_after := monthly_spent + monthly_add;
    year_after := year_spent + year_add;

    IF monthly_after > env.monthly_hard_ceiling_cents THEN
        monthly_state := 'exceeded';
    ELSIF monthly_after >= env.monthly_warn_threshold_cents THEN
        monthly_state := 'warning';
    ELSE
        monthly_state := 'ok';
    END IF;
    IF year_after > env.year_one_hard_ceiling_cents THEN
        year_state := 'exceeded';
    ELSIF year_after >= env.year_one_warn_threshold_cents THEN
        year_state := 'warning';
    ELSE
        year_state := 'ok';
    END IF;
    warning := monthly_state = 'warning' OR year_state = 'warning';

    RETURN jsonb_build_object(
        'monthly_spent_cents', monthly_after,
        'year_one_spent_cents', year_after,
        'monthly_warn_threshold_cents', env.monthly_warn_threshold_cents,
        'year_one_warn_threshold_cents', env.year_one_warn_threshold_cents,
        'monthly_hard_ceiling_cents', env.monthly_hard_ceiling_cents,
        'year_one_hard_ceiling_cents', env.year_one_hard_ceiling_cents,
        'absolute_monthly_hard_ceiling_cents',
            operating_cost_hard_monthly_ceiling_cents(),
        'absolute_year_one_hard_ceiling_cents',
            operating_cost_hard_year_one_ceiling_cents(),
        'monthly_state', monthly_state,
        'year_one_state', year_state,
        'warning', warning,
        'reporting_prominence', operating_cost_profit_prominence(),
        'profit_reporting_prominence', operating_cost_profit_prominence()
    );
END;
$$;

CREATE FUNCTION record_operating_cost(
    spec_value jsonb,
    source_lineage_value jsonb
) RETURNS operating_cost_entry
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    stored jsonb;
    digest_value text;
    env operating_cost_envelope%ROWTYPE;
    existing operating_cost_entry%ROWTYPE;
    created operating_cost_entry%ROWTYPE;
    amount bigint;
    occurred timestamptz;
    spending boolean;
    additional bigint;
    cap jsonb;
    monthly_state text;
    year_state text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'operating cost arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM operating_cost_assert_entry(spec_value);
    stored := spec_value
        || jsonb_build_object(
            'payee', btrim(spec_value->>'payee'),
            'category', lower(btrim(spec_value->>'category')),
            'purpose', btrim(spec_value->>'purpose'),
            'commitment', lower(btrim(spec_value->>'commitment')),
            'envelope_key', btrim(spec_value->>'envelope_key')
        );
    digest_value := operating_cost_entry_digest(stored);
    amount := (stored->>'amount_cents')::bigint;
    occurred := (stored->>'occurred_at')::timestamptz;
    spending := (stored->>'spending_classified')::boolean;

    SELECT * INTO env
    FROM operating_cost_envelope
    WHERE envelope_key = stored->>'envelope_key';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'operating cost envelope is not registered'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(digest_value, 47024));
    PERFORM pg_advisory_xact_lock(
        hashtextextended(env.envelope_id::text, 47025));

    SELECT * INTO existing
    FROM operating_cost_entry
    WHERE entry_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    additional := CASE WHEN spending THEN amount ELSE 0 END;
    cap := compute_operating_cost_cap_status(env.envelope_id, occurred, additional);
    monthly_state := cap->>'monthly_state';
    year_state := cap->>'year_one_state';
    IF spending AND (monthly_state = 'exceeded' OR year_state = 'exceeded') THEN
        RAISE EXCEPTION
            'operating cost hard ceiling would be exceeded; spending-classified work is refused'
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.operating_cost_write', 'on', true);
    BEGIN
        INSERT INTO operating_cost_entry (
            envelope_id, spec, entry_digest, payee, category, purpose,
            amount_cents, occurred_at, commitment, spending_classified,
            reporting_prominence, cap_status,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            env.envelope_id, stored, digest_value,
            stored->>'payee', stored->>'category', stored->>'purpose',
            amount, occurred, stored->>'commitment', spending,
            operating_cost_profit_prominence(), cap,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config('market_mate.operating_cost_write', 'off', true);
            SELECT * INTO existing
            FROM operating_cost_entry
            WHERE entry_digest = digest_value;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.operating_cost_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.operating_cost_write', 'off', true);

    PERFORM append_audit_event(
        'operating-cost:' || created.entry_id::text,
        'research.operating_cost_recorded',
        now(),
        jsonb_build_object(
            'entry_id', created.entry_id,
            'envelope_id', env.envelope_id,
            'payee', created.payee,
            'amount_cents', created.amount_cents,
            'warning', cap->'warning',
            'monthly_state', monthly_state,
            'year_one_state', year_state,
            'reporting_prominence', created.reporting_prominence,
            'entry_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_operating_cost_envelope(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION compute_operating_cost_cap_status(uuid, timestamptz, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_operating_cost(jsonb, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON operating_cost_envelope FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON operating_cost_entry FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
