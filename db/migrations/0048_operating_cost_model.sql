-- WU-44 Cost model projections: vendor quotes and usage assumptions
-- produce projected monthly and year-one cash costs compared to the
-- WU-43 envelope and #41 hard ceilings. Escalation thresholds are
-- flagged. The stage-1 vendor set must stay within those caps or name
-- the exact Principal decision required to change that. Dashboard work
-- belongs to WU-45.

CREATE FUNCTION operating_cost_model_quotes_digest(quotes_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-operating-cost-quotes-v1|' || quotes_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION operating_cost_model_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-operating-cost-model-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION operating_cost_assert_quotes(quotes_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'vendor', 'category', 'monthly_cents', 'months', 'one_time_cents'
    ];
    quote jsonb;
    monthly bigint;
    months bigint;
    one_time bigint;
    n integer;
BEGIN
    IF jsonb_typeof(quotes_value) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'operating cost model quotes are invalid'
            USING ERRCODE = '22023';
    END IF;
    n := jsonb_array_length(quotes_value);
    IF n IS NULL OR n < 1 THEN
        RAISE EXCEPTION 'operating cost model quotes are invalid'
            USING ERRCODE = '22023';
    END IF;
    FOR quote IN SELECT jsonb_array_elements(quotes_value) LOOP
        IF jsonb_typeof(quote) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(quote) k
                WHERE k <> ALL (allowed)
           )
           OR jsonb_typeof(quote->'vendor') IS DISTINCT FROM 'string'
           OR coalesce(btrim(quote->>'vendor'), '') = ''
           OR jsonb_typeof(quote->'category') IS DISTINCT FROM 'string'
           OR lower(btrim(quote->>'category')) NOT IN (
                'hosting', 'data', 'models', 'vendor', 'infrastructure', 'other')
           OR NOT (quote ? 'monthly_cents')
           OR NOT (quote ? 'months')
           OR NOT (quote ? 'one_time_cents') THEN
            RAISE EXCEPTION 'operating cost model quotes are invalid'
                USING ERRCODE = '22023';
        END IF;
        monthly := capital_feasibility_nonneg_int(quote->'monthly_cents');
        months := capital_feasibility_nonneg_int(quote->'months');
        one_time := capital_feasibility_nonneg_int(quote->'one_time_cents');
        IF monthly IS NULL OR months IS NULL OR one_time IS NULL
           OR months > 12 THEN
            RAISE EXCEPTION
                'operating cost model quotes are missing required inputs'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION operating_cost_assert_assumptions(assumptions_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'envelope_key', 'vendor_set_key', 'concurrency', 'required_decision'
    ];
BEGIN
    IF jsonb_typeof(assumptions_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(assumptions_value) k
            WHERE k <> ALL (allowed)
       )
       OR jsonb_typeof(assumptions_value->'envelope_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(assumptions_value->>'envelope_key'), '') = ''
       OR jsonb_typeof(assumptions_value->'vendor_set_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(assumptions_value->>'vendor_set_key'), '') = ''
       OR jsonb_typeof(assumptions_value->'concurrency') IS DISTINCT FROM 'string'
       OR lower(btrim(assumptions_value->>'concurrency')) NOT IN (
            'sequential', 'concurrent') THEN
        RAISE EXCEPTION 'operating cost model assumptions are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF assumptions_value ? 'required_decision'
       AND (jsonb_typeof(assumptions_value->'required_decision')
                IS DISTINCT FROM 'string'
            OR coalesce(btrim(assumptions_value->>'required_decision'), '') = '') THEN
        RAISE EXCEPTION 'operating cost model assumptions are invalid'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE TABLE operating_cost_model (
    model_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    model_key text NOT NULL CHECK (btrim(model_key) <> ''),
    envelope_id uuid NOT NULL
        REFERENCES operating_cost_envelope(envelope_id),
    quotes jsonb NOT NULL CHECK (jsonb_typeof(quotes) = 'array'),
    quotes_digest text NOT NULL CHECK (quotes_digest ~ '^[0-9a-f]{64}$'),
    assumptions jsonb NOT NULL CHECK (jsonb_typeof(assumptions) = 'object'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    within_caps boolean NOT NULL,
    required_decision text,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (quotes_digest = operating_cost_model_quotes_digest(quotes)),
    CHECK (result_digest = operating_cost_model_result_digest(result - 'result_digest')),
    CHECK (within_caps = ((result->>'within_caps')::boolean)),
    CHECK (
        (within_caps AND required_decision IS NULL)
        OR (NOT within_caps AND btrim(required_decision) <> '')
    ),
    CHECK ((result->>'absolute_monthly_hard_ceiling_cents')::bigint
        = operating_cost_hard_monthly_ceiling_cents()),
    CHECK ((result->>'absolute_year_one_hard_ceiling_cents')::bigint
        = operating_cost_hard_year_one_ceiling_cents()),
    CHECK (record_environment = 'local_research'),
    UNIQUE (model_key)
);

SELECT register_evidence_table('operating_cost_model');

CREATE UNIQUE INDEX operating_cost_model_quotes_uq
    ON operating_cost_model (quotes_digest, envelope_id);

CREATE FUNCTION guard_operating_cost_model_write() RETURNS trigger
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

CREATE TRIGGER operating_cost_model_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON operating_cost_model
    FOR EACH STATEMENT EXECUTE FUNCTION guard_operating_cost_model_write();

CREATE FUNCTION guard_operating_cost_model_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.cost_model_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the operating cost model workflow',
            TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER operating_cost_model_insert_guard
    BEFORE INSERT ON operating_cost_model
    FOR EACH ROW EXECUTE FUNCTION guard_operating_cost_model_insert();

CREATE FUNCTION compute_operating_cost_model(
    quotes_value jsonb,
    assumptions_value jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    env operating_cost_envelope%ROWTYPE;
    quote jsonb;
    monthly bigint;
    months bigint;
    one_time bigint;
    line_year bigint;
    monthly_projected bigint := 0;
    year_one_projected bigint := 0;
    concurrency text;
    within_caps boolean;
    required_decision text;
    monthly_flag text;
    year_flag text;
    result jsonb;
BEGIN
    PERFORM operating_cost_assert_quotes(quotes_value);
    PERFORM operating_cost_assert_assumptions(assumptions_value);

    SELECT * INTO env
    FROM operating_cost_envelope
    WHERE envelope_key = btrim(assumptions_value->>'envelope_key');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'operating cost envelope is not registered'
            USING ERRCODE = '22023';
    END IF;

    concurrency := lower(btrim(assumptions_value->>'concurrency'));
    FOR quote IN SELECT jsonb_array_elements(quotes_value) LOOP
        monthly := capital_feasibility_nonneg_int(quote->'monthly_cents');
        months := capital_feasibility_nonneg_int(quote->'months');
        one_time := capital_feasibility_nonneg_int(quote->'one_time_cents');
        line_year := monthly * months + one_time;
        year_one_projected := year_one_projected + line_year;
        IF concurrency = 'concurrent' THEN
            monthly_projected := monthly_projected + monthly;
        ELSIF monthly > monthly_projected THEN
            monthly_projected := monthly;
        END IF;
    END LOOP;

    IF monthly_projected > env.monthly_hard_ceiling_cents
       OR monthly_projected > operating_cost_hard_monthly_ceiling_cents()
       OR year_one_projected > env.year_one_hard_ceiling_cents
       OR year_one_projected > operating_cost_hard_year_one_ceiling_cents() THEN
        within_caps := false;
        monthly_flag := CASE
            WHEN monthly_projected > env.monthly_hard_ceiling_cents
              OR monthly_projected > operating_cost_hard_monthly_ceiling_cents()
            THEN 'exceeded'
            WHEN monthly_projected >= env.monthly_warn_threshold_cents
            THEN 'warning'
            ELSE 'ok' END;
        year_flag := CASE
            WHEN year_one_projected > env.year_one_hard_ceiling_cents
              OR year_one_projected > operating_cost_hard_year_one_ceiling_cents()
            THEN 'exceeded'
            WHEN year_one_projected >= env.year_one_warn_threshold_cents
            THEN 'warning'
            ELSE 'ok' END;
        IF jsonb_typeof(assumptions_value->'required_decision')
              IS DISTINCT FROM 'string'
           OR coalesce(btrim(assumptions_value->>'required_decision'), '') = '' THEN
            RAISE EXCEPTION
                'operating cost model exceeds caps and does not name the required decision'
                USING ERRCODE = '22023';
        END IF;
        required_decision := btrim(assumptions_value->>'required_decision');
    ELSE
        within_caps := true;
        required_decision := NULL;
        monthly_flag := CASE
            WHEN monthly_projected >= env.monthly_warn_threshold_cents
            THEN 'warning' ELSE 'ok' END;
        year_flag := CASE
            WHEN year_one_projected >= env.year_one_warn_threshold_cents
            THEN 'warning' ELSE 'ok' END;
    END IF;

    result := jsonb_build_object(
        'engine', 'operating_cost_model_v1',
        'vendor_set_key', btrim(assumptions_value->>'vendor_set_key'),
        'concurrency', concurrency,
        'monthly_projected_cents', monthly_projected,
        'year_one_projected_cents', year_one_projected,
        'monthly_warn_threshold_cents', env.monthly_warn_threshold_cents,
        'year_one_warn_threshold_cents', env.year_one_warn_threshold_cents,
        'monthly_hard_ceiling_cents', env.monthly_hard_ceiling_cents,
        'year_one_hard_ceiling_cents', env.year_one_hard_ceiling_cents,
        'absolute_monthly_hard_ceiling_cents',
            operating_cost_hard_monthly_ceiling_cents(),
        'absolute_year_one_hard_ceiling_cents',
            operating_cost_hard_year_one_ceiling_cents(),
        'monthly_escalation', monthly_flag,
        'year_one_escalation', year_flag,
        'within_caps', within_caps,
        'required_decision', to_jsonb(required_decision)
    );
    RETURN result || jsonb_build_object(
        'result_digest', operating_cost_model_result_digest(result));
END;
$$;

CREATE FUNCTION record_operating_cost_model(
    model_key_value text,
    quotes_value jsonb,
    assumptions_value jsonb,
    source_lineage_value jsonb
) RETURNS operating_cost_model
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    key_text text;
    env operating_cost_envelope%ROWTYPE;
    computed jsonb;
    stored_result jsonb;
    digest_value text;
    quotes_digest_value text;
    stored_assumptions jsonb;
    existing operating_cost_model%ROWTYPE;
    created operating_cost_model%ROWTYPE;
    within_caps boolean;
    required_decision text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'operating cost model arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(model_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'operating cost model arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM operating_cost_assert_quotes(quotes_value);
    PERFORM operating_cost_assert_assumptions(assumptions_value);
    stored_assumptions := assumptions_value || jsonb_build_object(
        'envelope_key', btrim(assumptions_value->>'envelope_key'),
        'vendor_set_key', btrim(assumptions_value->>'vendor_set_key'),
        'concurrency', lower(btrim(assumptions_value->>'concurrency'))
    );

    SELECT * INTO env
    FROM operating_cost_envelope
    WHERE envelope_key = stored_assumptions->>'envelope_key';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'operating cost envelope is not registered'
            USING ERRCODE = '22023';
    END IF;

    computed := compute_operating_cost_model(quotes_value, stored_assumptions);
    stored_result := computed - 'result_digest';
    digest_value := operating_cost_model_result_digest(stored_result);
    quotes_digest_value := operating_cost_model_quotes_digest(quotes_value);
    within_caps := (stored_result->>'within_caps')::boolean;
    IF jsonb_typeof(stored_result->'required_decision') = 'string' THEN
        required_decision := stored_result->>'required_decision';
    ELSE
        required_decision := NULL;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 48023));
    PERFORM pg_advisory_xact_lock(hashtextextended(quotes_digest_value, 48024));

    SELECT * INTO existing
    FROM operating_cost_model
    WHERE model_key = key_text;
    IF FOUND THEN
        IF existing.quotes_digest IS DISTINCT FROM quotes_digest_value
           OR existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'operating cost model % is already recorded with a different result or lineage',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.cost_model_write', 'on', true);
    BEGIN
        INSERT INTO operating_cost_model (
            model_key, envelope_id, quotes, quotes_digest, assumptions,
            result, result_digest, within_caps, required_decision,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, env.envelope_id, quotes_value, quotes_digest_value,
            stored_assumptions, stored_result, digest_value,
            within_caps, required_decision,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config('market_mate.cost_model_write', 'off', true);
            SELECT * INTO existing
            FROM operating_cost_model
            WHERE model_key = key_text
               OR (quotes_digest = quotes_digest_value
                   AND envelope_id = env.envelope_id)
            LIMIT 1;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.result_digest IS DISTINCT FROM digest_value THEN
                RAISE EXCEPTION
                    'operating cost model is already recorded with a different result or lineage'
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.cost_model_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.cost_model_write', 'off', true);

    PERFORM append_audit_event(
        'operating-cost-model:' || created.model_id::text,
        'research.operating_cost_model_recorded',
        now(),
        jsonb_build_object(
            'model_id', created.model_id,
            'model_key', key_text,
            'within_caps', within_caps,
            'monthly_projected_cents', stored_result->>'monthly_projected_cents',
            'year_one_projected_cents', stored_result->>'year_one_projected_cents',
            'year_one_escalation', stored_result->>'year_one_escalation',
            'result_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION compute_operating_cost_model(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_operating_cost_model(text, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON operating_cost_model FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
