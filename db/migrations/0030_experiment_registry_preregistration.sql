-- WU-29 Experiment Registry preregistration: immutable, content-addressed
-- Experiment Registration (issues #42, #40). A post-hoc change appends a
-- successor linked to the current registration; the original row never
-- mutates. Registration is recorded before any evaluation result exists
-- for that registration_id.

ALTER TABLE experiment_preregistration
    ADD COLUMN successor_of uuid
        REFERENCES experiment_preregistration(registration_id);

ALTER TABLE experiment_preregistration
    ADD CONSTRAINT experiment_preregistration_successor_not_self
    CHECK (successor_of IS DISTINCT FROM registration_id);

CREATE UNIQUE INDEX experiment_preregistration_content_uq
    ON experiment_preregistration (experiment_key, spec_digest);
CREATE UNIQUE INDEX experiment_preregistration_root_uq
    ON experiment_preregistration (experiment_key)
    WHERE successor_of IS NULL;
CREATE UNIQUE INDEX experiment_preregistration_successor_uq
    ON experiment_preregistration (successor_of)
    WHERE successor_of IS NOT NULL;

CREATE FUNCTION experiment_preregistration_spec_node(
    spec_value jsonb,
    primary_name text,
    alias_name text
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN spec_value ? primary_name THEN spec_value -> primary_name
        ELSE spec_value -> alias_name
    END;
$$;

CREATE FUNCTION experiment_preregistration_spec_is_complete(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    windows_node jsonb;
    estimators_node jsonb;
    budget_node jsonb;
    stopping_node jsonb;
    multiplicity_node jsonb;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'hypothesis') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'hypothesis'), '') = '' THEN
        RETURN false;
    END IF;

    windows_node := experiment_preregistration_spec_node(
        spec_value, 'windows', 'window');
    IF jsonb_typeof(windows_node) IS DISTINCT FROM 'object'
       OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(windows_node)) THEN
        RETURN false;
    END IF;

    estimators_node := experiment_preregistration_spec_node(
        spec_value, 'estimators', 'estimator');
    IF jsonb_typeof(estimators_node) IS DISTINCT FROM 'string'
       AND jsonb_typeof(estimators_node) IS DISTINCT FROM 'object'
       AND jsonb_typeof(estimators_node) IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(estimators_node) = 'string'
       AND coalesce(btrim(estimators_node #>> '{}'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(estimators_node) = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(estimators_node)) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(estimators_node) = 'array'
       AND jsonb_array_length(estimators_node) < 1 THEN
        RETURN false;
    END IF;

    budget_node := experiment_preregistration_spec_node(
        spec_value, 'budget', 'testing_budget');
    IF jsonb_typeof(budget_node) IS DISTINCT FROM 'string'
       AND jsonb_typeof(budget_node) IS DISTINCT FROM 'object'
       AND jsonb_typeof(budget_node) IS DISTINCT FROM 'number' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(budget_node) = 'string'
       AND coalesce(btrim(budget_node #>> '{}'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(budget_node) = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(budget_node)) THEN
        RETURN false;
    END IF;

    stopping_node := spec_value->'stopping_rule';
    IF jsonb_typeof(stopping_node) IS DISTINCT FROM 'string'
       AND jsonb_typeof(stopping_node) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(stopping_node) = 'string'
       AND coalesce(btrim(spec_value->>'stopping_rule'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(stopping_node) = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(stopping_node)) THEN
        RETURN false;
    END IF;

    multiplicity_node := experiment_preregistration_spec_node(
        spec_value, 'multiplicity_plan', 'multiplicity');
    IF jsonb_typeof(multiplicity_node) IS DISTINCT FROM 'string'
       AND jsonb_typeof(multiplicity_node) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(multiplicity_node) = 'string'
       AND coalesce(btrim(multiplicity_node #>> '{}'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(multiplicity_node) = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(multiplicity_node)) THEN
        RETURN false;
    END IF;

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION experiment_preregistration_tip(
    experiment_key_value text
) RETURNS experiment_preregistration
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT r
    FROM experiment_preregistration r
    WHERE r.experiment_key = experiment_key_value
      AND NOT EXISTS (
        SELECT 1
        FROM experiment_preregistration later
        WHERE later.successor_of = r.registration_id
      )
    LIMIT 1;
$$;

CREATE FUNCTION guard_experiment_preregistration_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.experiment_preregistration_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            'experiment_preregistration writes must go through register_experiment_preregistration'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER experiment_preregistration_insert_guard
    BEFORE INSERT ON experiment_preregistration
    FOR EACH ROW EXECUTE FUNCTION guard_experiment_preregistration_insert();

CREATE FUNCTION register_experiment_preregistration(
    experiment_key_value text,
    spec_value jsonb,
    successor_of_value uuid,
    source_lineage_value jsonb
) RETURNS experiment_preregistration
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    spec_digest_value text;
    existing experiment_preregistration%ROWTYPE;
    tip_row experiment_preregistration%ROWTYPE;
    predecessor experiment_preregistration%ROWTYPE;
    created experiment_preregistration%ROWTYPE;
BEGIN
    IF coalesce(btrim(experiment_key_value), '') = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'experiment preregistration arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT experiment_preregistration_spec_is_complete(spec_value) THEN
        RAISE EXCEPTION
            'experiment preregistration spec is incomplete; hypothesis, windows, estimators, budget, stopping rule, and multiplicity plan are required'
            USING ERRCODE = '22023';
    END IF;
    IF spec_value ? 'experiment_key'
       AND spec_value->>'experiment_key' IS DISTINCT FROM experiment_key_value THEN
        RAISE EXCEPTION
            'experiment preregistration spec experiment_key does not match %',
            experiment_key_value
            USING ERRCODE = '22023';
    END IF;

    spec_digest_value := encode(
        digest('market-mate-preregistration-v1|' || spec_value::text, 'sha256'),
        'hex');

    PERFORM pg_advisory_xact_lock(hashtextextended(experiment_key_value, 30023));

    SELECT * INTO existing
    FROM experiment_preregistration
    WHERE experiment_key = experiment_key_value
      AND spec_digest = spec_digest_value;
    IF FOUND THEN
        IF existing.successor_of IS DISTINCT FROM successor_of_value THEN
            RAISE EXCEPTION
                'experiment % spec is already registered on a different successor lineage',
                experiment_key_value
            USING ERRCODE = '23505';
        END IF;
        RETURN existing;
    END IF;

    tip_row := experiment_preregistration_tip(experiment_key_value);
    IF successor_of_value IS NULL THEN
        IF tip_row.registration_id IS NOT NULL THEN
            RAISE EXCEPTION
                'experiment % already has a registration; post-hoc changes must set successor_of to the current registration',
                experiment_key_value
                USING ERRCODE = '22023';
        END IF;
    ELSE
        SELECT * INTO predecessor
        FROM experiment_preregistration
        WHERE registration_id = successor_of_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'experiment preregistration % is not registered',
                successor_of_value
                USING ERRCODE = '22023';
        END IF;
        IF predecessor.experiment_key IS DISTINCT FROM experiment_key_value THEN
            RAISE EXCEPTION
                'successor_of must belong to experiment %',
                experiment_key_value
                USING ERRCODE = '22023';
        END IF;
        IF tip_row.registration_id IS DISTINCT FROM successor_of_value THEN
            RAISE EXCEPTION
                'successor_of must be the current registration for %',
                experiment_key_value
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.experiment_preregistration_write', 'on', true);
    BEGIN
        INSERT INTO experiment_preregistration (
            experiment_key, spec, spec_digest, successor_of,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            experiment_key_value, spec_value, spec_digest_value, successor_of_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.experiment_preregistration_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.experiment_preregistration_write', 'off', true);

    PERFORM append_audit_event(
        'experiment-preregistration:' || created.registration_id::text,
        'research.experiment_preregistration_registered',
        now(),
        jsonb_build_object(
            'registration_id', created.registration_id,
            'experiment_key', experiment_key_value,
            'spec_digest', spec_digest_value,
            'successor_of', successor_of_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_experiment_preregistration(text, jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON experiment_preregistration FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
