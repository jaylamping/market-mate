-- WU-42 Executable Capital Feasibility artifact: which defined-risk
-- structures qualify at the $1,000 bankroll after WU-41 Position Risk.
-- If none qualify, the stage-4 stock-only fallback is recorded explicitly.
-- Floors cannot be weakened to make a structure fit. Operating-cost
-- register work belongs to WU-43.

CREATE FUNCTION executable_feasibility_models_digest(model_ids jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-executable-feasibility-models-v1|' || model_ids::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION executable_feasibility_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-executable-feasibility-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION executable_feasibility_sorted_model_ids(model_ids jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    sorted jsonb;
    n integer;
    n_distinct integer;
BEGIN
    IF jsonb_typeof(model_ids) IS DISTINCT FROM 'array'
       OR jsonb_array_length(model_ids) < 1 THEN
        RETURN NULL;
    END IF;
    SELECT jsonb_agg(to_jsonb(u.model_id::text) ORDER BY u.model_id::text)
    INTO sorted
    FROM (
        SELECT DISTINCT (value #>> '{}')::uuid AS model_id
        FROM jsonb_array_elements(model_ids)
    ) u;
    n := jsonb_array_length(model_ids);
    n_distinct := jsonb_array_length(sorted);
    IF n IS DISTINCT FROM n_distinct THEN
        RETURN NULL;
    END IF;
    RETURN sorted;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE TABLE executable_capital_feasibility (
    artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_key text NOT NULL CHECK (btrim(artifact_key) <> ''),
    model_ids jsonb NOT NULL CHECK (jsonb_typeof(model_ids) = 'array'),
    models_digest text NOT NULL CHECK (models_digest ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    stock_only_fallback boolean NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (models_digest = executable_feasibility_models_digest(model_ids)),
    CHECK (result_digest = executable_feasibility_result_digest(result - 'result_digest')),
    CHECK ((result->>'bankroll_cents')::bigint = capital_feasibility_bankroll_cents()),
    CHECK ((result->>'utilization_ceiling_cents')::bigint
        = capital_feasibility_utilization_ceiling_cents()),
    CHECK (stock_only_fallback = ((result->>'stock_only_fallback')::boolean)),
    CHECK (
        (stock_only_fallback
         AND (result->>'options_qualify')::boolean IS DISTINCT FROM true
         AND jsonb_typeof(result->'qualifying_structures') = 'array'
         AND jsonb_array_length(result->'qualifying_structures') = 0
         AND jsonb_typeof(result->'fallback_reason') = 'string'
         AND btrim(result->>'fallback_reason') <> '')
        OR
        (NOT stock_only_fallback
         AND (result->>'options_qualify')::boolean = true
         AND jsonb_typeof(result->'qualifying_structures') = 'array'
         AND jsonb_array_length(result->'qualifying_structures') >= 1
         AND jsonb_typeof(result->'fallback_reason') IS DISTINCT FROM 'string')
    ),
    CHECK (record_environment = 'local_research'),
    UNIQUE (artifact_key)
);

SELECT register_evidence_table('executable_capital_feasibility');

CREATE UNIQUE INDEX executable_capital_feasibility_models_uq
    ON executable_capital_feasibility (models_digest);

CREATE FUNCTION guard_executable_feasibility_write() RETURNS trigger
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

CREATE TRIGGER executable_capital_feasibility_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON executable_capital_feasibility
    FOR EACH STATEMENT EXECUTE FUNCTION guard_executable_feasibility_write();

CREATE FUNCTION guard_executable_feasibility_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(
          current_setting('market_mate.feasibility_artifact_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the executable feasibility workflow',
            TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER executable_capital_feasibility_insert_guard
    BEFORE INSERT ON executable_capital_feasibility
    FOR EACH ROW EXECUTE FUNCTION guard_executable_feasibility_insert();

CREATE FUNCTION compute_executable_capital_feasibility(model_ids jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    sorted jsonb;
    model_id_value uuid;
    model_row position_risk_model%ROWTYPE;
    assessment_row capital_feasibility_assessment%ROWTYPE;
    bankroll bigint;
    utilization bigint;
    qualifies boolean;
    qualifying jsonb := '[]'::jsonb;
    rejected jsonb := '[]'::jsonb;
    n integer := 0;
    stock_only boolean;
    fallback_reason text;
    result jsonb;
BEGIN
    sorted := executable_feasibility_sorted_model_ids(model_ids);
    IF sorted IS NULL THEN
        RAISE EXCEPTION
            'executable capital feasibility assessments are incomplete'
            USING ERRCODE = '22023';
    END IF;

    bankroll := capital_feasibility_bankroll_cents();
    utilization := capital_feasibility_utilization_ceiling_cents();

    FOR model_id_value IN
        SELECT (value #>> '{}')::uuid
        FROM jsonb_array_elements(sorted)
    LOOP
        SELECT * INTO model_row
        FROM position_risk_model
        WHERE model_id = model_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'executable capital feasibility assessments are incomplete'
                USING ERRCODE = '22023';
        END IF;
        SELECT * INTO assessment_row
        FROM capital_feasibility_assessment
        WHERE assessment_id = model_row.assessment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'executable capital feasibility assessments are incomplete'
                USING ERRCODE = '22023';
        END IF;

        n := n + 1;
        qualifies := model_row.admitted
            AND (model_row.result->>'bankroll_cents')::bigint = bankroll
            AND (model_row.result->>'utilization_ceiling_cents')::bigint
                = utilization
            AND (model_row.result->>'position_risk_cents')::bigint
                >= (model_row.result->>'contractual_max_cents')::bigint
            AND (model_row.result->>'assignment_exposure_cents')::bigint
                <= bankroll
            AND (model_row.result->>'position_risk_cents')::bigint <= bankroll
            AND (model_row.result->>'position_risk_cents')::bigint <= utilization
            AND (model_row.result->>'entry_capital_cents')::bigint <= bankroll;

        IF qualifies THEN
            qualifying := qualifying || jsonb_build_array(jsonb_build_object(
                'model_id', model_row.model_id,
                'assessment_id', model_row.assessment_id,
                'structure_key', assessment_row.structure->>'structure_key',
                'structure_kind', assessment_row.structure->>'structure_kind',
                'position_risk_cents',
                    (model_row.result->>'position_risk_cents')::bigint,
                'assignment_exposure_cents',
                    (model_row.result->>'assignment_exposure_cents')::bigint
            ));
        ELSE
            rejected := rejected || jsonb_build_array(jsonb_build_object(
                'model_id', model_row.model_id,
                'assessment_id', model_row.assessment_id,
                'structure_key', assessment_row.structure->>'structure_key',
                'structure_kind', assessment_row.structure->>'structure_kind',
                'rejection_reason', coalesce(
                    model_row.rejection_reason, 'floors_not_satisfied')
            ));
        END IF;
    END LOOP;

    IF n < 1 THEN
        RAISE EXCEPTION
            'executable capital feasibility assessments are incomplete'
            USING ERRCODE = '22023';
    END IF;

    stock_only := jsonb_array_length(qualifying) = 0;
    IF stock_only THEN
        fallback_reason := 'no_defined_risk_structure_qualifies_at_bankroll';
    ELSE
        fallback_reason := NULL;
    END IF;

    result := jsonb_build_object(
        'engine', 'executable_capital_feasibility_v1',
        'bankroll_cents', bankroll,
        'utilization_ceiling_cents', utilization,
        'assessed_count', n,
        'qualifying_count', jsonb_array_length(qualifying),
        'qualifying_structures', qualifying,
        'rejected_structures', rejected,
        'options_qualify', NOT stock_only,
        'stock_only_fallback', stock_only,
        'fallback_reason', to_jsonb(fallback_reason),
        'fallback_statement', CASE WHEN stock_only THEN
            'stage-4 stock-only Restricted Live proceeds; options remain ineligible without weakening safety'
            ELSE NULL END
    );
    RETURN result || jsonb_build_object(
        'result_digest', executable_feasibility_result_digest(result));
END;
$$;

CREATE FUNCTION record_executable_capital_feasibility(
    artifact_key_value text,
    model_ids jsonb,
    source_lineage_value jsonb
) RETURNS executable_capital_feasibility
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    key_text text;
    sorted jsonb;
    models_digest_value text;
    computed jsonb;
    stored_result jsonb;
    digest_value text;
    stock_only boolean;
    existing executable_capital_feasibility%ROWTYPE;
    created executable_capital_feasibility%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'executable capital feasibility arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(artifact_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'executable capital feasibility arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    sorted := executable_feasibility_sorted_model_ids(model_ids);
    IF sorted IS NULL THEN
        RAISE EXCEPTION
            'executable capital feasibility assessments are incomplete'
            USING ERRCODE = '22023';
    END IF;
    models_digest_value := executable_feasibility_models_digest(sorted);

    computed := compute_executable_capital_feasibility(sorted);
    stored_result := computed - 'result_digest';
    digest_value := executable_feasibility_result_digest(stored_result);
    stock_only := (stored_result->>'stock_only_fallback')::boolean;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 46023));
    PERFORM pg_advisory_xact_lock(hashtextextended(models_digest_value, 46024));

    SELECT * INTO existing
    FROM executable_capital_feasibility
    WHERE artifact_key = key_text;
    IF FOUND THEN
        IF existing.models_digest IS DISTINCT FROM models_digest_value
           OR existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'executable capital feasibility % is already recorded with a different result or lineage',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    SELECT * INTO existing
    FROM executable_capital_feasibility
    WHERE models_digest = models_digest_value;
    IF FOUND THEN
        IF existing.artifact_key IS DISTINCT FROM key_text
           OR existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'executable capital feasibility is already recorded on a different lineage'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.feasibility_artifact_write', 'on', true);
    BEGIN
        INSERT INTO executable_capital_feasibility (
            artifact_key, model_ids, models_digest, result, result_digest,
            stock_only_fallback, source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, sorted, models_digest_value, stored_result, digest_value,
            stock_only, source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config('market_mate.feasibility_artifact_write', 'off', true);
            SELECT * INTO existing
            FROM executable_capital_feasibility
            WHERE artifact_key = key_text
               OR models_digest = models_digest_value
            LIMIT 1;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.result_digest IS DISTINCT FROM digest_value THEN
                RAISE EXCEPTION
                    'executable capital feasibility is already recorded with a different result or lineage'
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.feasibility_artifact_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.feasibility_artifact_write', 'off', true);

    PERFORM append_audit_event(
        'executable-feasibility:' || created.artifact_id::text,
        'research.executable_capital_feasibility_recorded',
        now(),
        jsonb_build_object(
            'artifact_id', created.artifact_id,
            'artifact_key', key_text,
            'models_digest', models_digest_value,
            'qualifying_count', stored_result->>'qualifying_count',
            'stock_only_fallback', stock_only,
            'result_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION compute_executable_capital_feasibility(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_executable_capital_feasibility(text, jsonb, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON executable_capital_feasibility FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
