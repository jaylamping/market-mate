-- WU-32 Strategy Version artifact and registration (issues #42, #40).
-- A declarative DSL spec (v1) plus its engine binding is frozen as an
-- immutable, content-addressed Strategy Version with lineage to its
-- Experiment Registration. Changing spec or binding appends a successor;
-- the original row never mutates. Freezing grants no Paper or Live
-- authority (lifecycle_state is frozen only).

CREATE FUNCTION strategy_dsl_rule_is_present(node jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN jsonb_typeof(node) = 'string' THEN coalesce(btrim(node #>> '{}'), '') <> ''
        WHEN jsonb_typeof(node) = 'object' THEN EXISTS (SELECT 1 FROM jsonb_object_keys(node))
        ELSE false
    END;
$$;

CREATE FUNCTION strategy_dsl_spec_is_complete(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    universe jsonb;
    comparators jsonb;
    has_cash boolean := false;
    has_sp500 boolean := false;
    comparator text;
    n numeric;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'dsl_version') IS DISTINCT FROM 'number' THEN
        RETURN false;
    END IF;
    n := (spec_value->'dsl_version')::numeric;
    IF n IS NULL OR n <> 1 OR n <> floor(n) THEN
        RETURN false;
    END IF;

    universe := spec_value->'universe';
    IF jsonb_typeof(universe) IS DISTINCT FROM 'object'
       OR jsonb_typeof(universe->'instrument_class') IS DISTINCT FROM 'string'
       OR btrim(universe->>'instrument_class') IS DISTINCT FROM 'common_stock' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(universe->'sentiment') IS DISTINCT FROM 'boolean'
       OR universe->'sentiment' IS DISTINCT FROM 'false'::jsonb THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(spec_value->'target') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'target'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'rules') IS DISTINCT FROM 'object'
       OR NOT strategy_dsl_rule_is_present(spec_value->'rules'->'entry')
       OR NOT strategy_dsl_rule_is_present(spec_value->'rules'->'exit')
       OR NOT strategy_dsl_rule_is_present(spec_value->'rules'->'sizing') THEN
        RETURN false;
    END IF;

    comparators := spec_value->'comparators';
    IF jsonb_typeof(comparators) IS DISTINCT FROM 'array'
       OR jsonb_array_length(comparators) < 1 THEN
        RETURN false;
    END IF;
    FOR comparator IN
        SELECT jsonb_array_elements_text(comparators)
    LOOP
        IF coalesce(btrim(comparator), '') = '' THEN
            RETURN false;
        END IF;
        IF comparator = 'cash' THEN
            has_cash := true;
        END IF;
        IF comparator IN ('sp500', 's&p_500', 'spx') THEN
            has_sp500 := true;
        END IF;
    END LOOP;
    IF NOT has_cash THEN
        RETURN false;
    END IF;
    IF has_sp500 THEN
        IF jsonb_typeof(spec_value->'sp500_comparator') IS DISTINCT FROM 'string'
           OR btrim(spec_value->>'sp500_comparator') NOT IN ('hard', 'soft') THEN
            RETURN false;
        END IF;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION strategy_engine_binding_is_complete(binding_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF jsonb_typeof(binding_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(binding_value->'engine_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(binding_value->>'engine_key'), '') = ''
       OR jsonb_typeof(binding_value->'engine_kind') IS DISTINCT FROM 'string'
       OR jsonb_typeof(binding_value->'engine_version') IS DISTINCT FROM 'string'
       OR coalesce(btrim(binding_value->>'engine_version'), '') = '' THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION strategy_version_claims_execution_authority(
    spec_value jsonb,
    binding_value jsonb
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT spec_value ? 'authority'
        OR spec_value ? 'lifecycle_state'
        OR spec_value ? 'execution_environment'
        OR spec_value ? 'execution_authority'
        OR spec_value ? 'strategy_eligible'
        OR spec_value ? 'paper_eligible'
        OR spec_value ? 'trade_eligible'
        OR binding_value ? 'authority'
        OR binding_value ? 'lifecycle_state'
        OR binding_value ? 'execution_environment'
        OR binding_value ? 'execution_authority'
        OR binding_value ? 'strategy_eligible'
        OR binding_value ? 'paper_eligible'
        OR binding_value ? 'trade_eligible';
$$;

CREATE FUNCTION strategy_version_artifact_keys_are_allowed(
    spec_value jsonb,
    binding_value jsonb
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT jsonb_typeof(spec_value) = 'object'
       AND jsonb_typeof(binding_value) = 'object'
       AND jsonb_typeof(spec_value->'universe') = 'object'
       AND jsonb_typeof(spec_value->'rules') = 'object'
       AND NOT EXISTS (
            SELECT 1
            FROM jsonb_object_keys(spec_value) k
            WHERE k NOT IN (
                'dsl_version', 'universe', 'target', 'rules',
                'comparators', 'sp500_comparator', 'strategy_key'
            )
       )
       AND NOT EXISTS (
            SELECT 1
            FROM jsonb_object_keys(spec_value->'universe') k
            WHERE k NOT IN ('instrument_class', 'sentiment')
       )
       AND NOT EXISTS (
            SELECT 1
            FROM jsonb_object_keys(spec_value->'rules') k
            WHERE k NOT IN ('entry', 'exit', 'sizing')
       )
       AND NOT EXISTS (
            SELECT 1
            FROM jsonb_object_keys(binding_value) k
            WHERE k NOT IN ('engine_key', 'engine_kind', 'engine_version')
       );
$$;

CREATE FUNCTION strategy_version_digest(
    strategy_key_value text,
    spec_value jsonb,
    engine_binding_value jsonb,
    registration_id_value uuid
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-strategy-version-v1|' || jsonb_build_object(
                'strategy_key', strategy_key_value,
                'spec', spec_value,
                'engine_binding', engine_binding_value,
                'registration_id', registration_id_value
            )::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE TABLE strategy_version (
    strategy_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_key text NOT NULL CHECK (btrim(strategy_key) <> ''),
    version integer NOT NULL CHECK (version >= 1),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    engine_binding jsonb NOT NULL CHECK (jsonb_typeof(engine_binding) = 'object'),
    registration_id uuid NOT NULL
        REFERENCES experiment_preregistration(registration_id),
    successor_of uuid,
    lifecycle_state text NOT NULL CHECK (lifecycle_state = 'frozen'),
    version_digest text NOT NULL CHECK (version_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (successor_of IS DISTINCT FROM strategy_version_id),
    CHECK (
        version_digest = strategy_version_digest(
            strategy_key, spec, engine_binding, registration_id)
    ),
    CHECK (strategy_dsl_spec_is_complete(spec)),
    CHECK (strategy_engine_binding_is_complete(engine_binding)),
    CHECK (lower(btrim(engine_binding->>'engine_kind')) = 'deterministic_dsl'),
    CHECK (NOT strategy_version_claims_execution_authority(spec, engine_binding)),
    CHECK (strategy_version_artifact_keys_are_allowed(spec, engine_binding)),
    UNIQUE (strategy_key, version)
);

SELECT register_evidence_table('strategy_version');

ALTER TABLE strategy_version
    ADD CONSTRAINT strategy_version_successor_fk
    FOREIGN KEY (successor_of) REFERENCES strategy_version(strategy_version_id);

CREATE UNIQUE INDEX strategy_version_content_uq
    ON strategy_version (strategy_key, version_digest);
CREATE UNIQUE INDEX strategy_version_root_uq
    ON strategy_version (strategy_key)
    WHERE successor_of IS NULL;
CREATE UNIQUE INDEX strategy_version_successor_uq
    ON strategy_version (successor_of)
    WHERE successor_of IS NOT NULL;
CREATE INDEX strategy_version_registration_idx
    ON strategy_version (registration_id, receipt_time);

CREATE FUNCTION guard_strategy_version_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'strategy_version is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER strategy_version_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON strategy_version
    FOR EACH STATEMENT EXECUTE FUNCTION guard_strategy_version_write();

CREATE FUNCTION guard_strategy_version_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.strategy_version_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'strategy_version writes must go through register_strategy_version'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER strategy_version_insert_guard
    BEFORE INSERT ON strategy_version
    FOR EACH ROW EXECUTE FUNCTION guard_strategy_version_insert();

CREATE FUNCTION strategy_version_tip(strategy_key_value text)
RETURNS strategy_version
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT v
    FROM strategy_version v
    WHERE v.strategy_key = strategy_key_value
      AND NOT EXISTS (
        SELECT 1
        FROM strategy_version later
        WHERE later.successor_of = v.strategy_version_id
      )
    LIMIT 1;
$$;

CREATE VIEW current_strategy_version AS
    SELECT
        v.strategy_version_id,
        v.strategy_key,
        v.version,
        v.spec,
        v.engine_binding,
        v.registration_id,
        v.successor_of,
        v.lifecycle_state,
        v.version_digest,
        v.receipt_time
    FROM strategy_version v
    WHERE NOT EXISTS (
        SELECT 1
        FROM strategy_version later
        WHERE later.successor_of = v.strategy_version_id
    );

CREATE FUNCTION register_strategy_version(
    strategy_key_value text,
    spec_value jsonb,
    engine_binding_value jsonb,
    registration_id_value uuid,
    successor_of_value uuid,
    source_lineage_value jsonb
) RETURNS strategy_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    digest_value text;
    existing strategy_version%ROWTYPE;
    tip_row strategy_version%ROWTYPE;
    predecessor strategy_version%ROWTYPE;
    registration_row experiment_preregistration%ROWTYPE;
    created strategy_version%ROWTYPE;
    next_version integer;
    engine_kind_text text;
BEGIN
    IF coalesce(btrim(strategy_key_value), '') = ''
       OR registration_id_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'strategy version arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT strategy_dsl_spec_is_complete(spec_value) THEN
        RAISE EXCEPTION
            'strategy dsl spec is incomplete; dsl_version 1, stock-only universe, target, entry/exit/sizing rules, and cash comparator are required'
            USING ERRCODE = '22023';
    END IF;
    IF spec_value ? 'strategy_key'
       AND spec_value->>'strategy_key' IS DISTINCT FROM strategy_key_value THEN
        RAISE EXCEPTION
            'strategy version spec strategy_key does not match %',
            strategy_key_value
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(engine_binding_value->'engine_kind') = 'string' THEN
        engine_kind_text := lower(btrim(engine_binding_value->>'engine_kind'));
        IF engine_kind_text IS DISTINCT FROM 'deterministic_dsl' THEN
            RAISE EXCEPTION
                'strategy engine binding must be deterministic_dsl for DSL v1'
                USING ERRCODE = '22023';
        END IF;
    END IF;
    IF NOT strategy_engine_binding_is_complete(engine_binding_value) THEN
        RAISE EXCEPTION
            'strategy engine binding is incomplete; engine_key, deterministic_dsl engine_kind, and engine_version are required'
            USING ERRCODE = '22023';
    END IF;
    IF strategy_version_claims_execution_authority(spec_value, engine_binding_value) THEN
        RAISE EXCEPTION
            'strategy version cannot grant Paper or Live authority'
            USING ERRCODE = '22023';
    END IF;
    IF NOT strategy_version_artifact_keys_are_allowed(spec_value, engine_binding_value) THEN
        RAISE EXCEPTION
            'strategy dsl spec or engine binding contains keys that are not part of DSL v1'
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

    digest_value := strategy_version_digest(
        strategy_key_value, spec_value, engine_binding_value, registration_id_value);

    PERFORM pg_advisory_xact_lock(hashtextextended(strategy_key_value, 34023));

    SELECT * INTO existing
    FROM strategy_version
    WHERE strategy_key = strategy_key_value
      AND version_digest = digest_value;
    IF FOUND THEN
        IF existing.successor_of IS DISTINCT FROM successor_of_value THEN
            RAISE EXCEPTION
                'strategy % spec is already registered on a different successor lineage',
                strategy_key_value
                USING ERRCODE = '23505';
        END IF;
        RETURN existing;
    END IF;

    tip_row := strategy_version_tip(strategy_key_value);
    IF successor_of_value IS NULL THEN
        IF tip_row.strategy_version_id IS NOT NULL THEN
            RAISE EXCEPTION
                'strategy % already has a version; mutations must set successor_of to the current version',
                strategy_key_value
                USING ERRCODE = '22023';
        END IF;
        next_version := 1;
    ELSE
        SELECT * INTO predecessor
        FROM strategy_version
        WHERE strategy_version_id = successor_of_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'strategy version % is not registered', successor_of_value
                USING ERRCODE = '22023';
        END IF;
        IF predecessor.strategy_key IS DISTINCT FROM strategy_key_value THEN
            RAISE EXCEPTION
                'successor_of must belong to strategy %',
                strategy_key_value
                USING ERRCODE = '22023';
        END IF;
        IF tip_row.strategy_version_id IS DISTINCT FROM successor_of_value THEN
            RAISE EXCEPTION
                'successor_of must be the current version for %',
                strategy_key_value
                USING ERRCODE = '22023';
        END IF;
        next_version := predecessor.version + 1;
    END IF;

    PERFORM set_config('market_mate.strategy_version_write', 'on', true);
    BEGIN
        INSERT INTO strategy_version (
            strategy_key, version, spec, engine_binding, registration_id,
            successor_of, lifecycle_state, version_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            strategy_key_value, next_version, spec_value, engine_binding_value,
            registration_id_value, successor_of_value, 'frozen', digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.strategy_version_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.strategy_version_write', 'off', true);

    PERFORM append_audit_event(
        'strategy-version:' || created.strategy_version_id::text,
        'research.strategy_version_registered',
        now(),
        jsonb_build_object(
            'strategy_version_id', created.strategy_version_id,
            'strategy_key', strategy_key_value,
            'version', next_version,
            'version_digest', digest_value,
            'registration_id', registration_id_value,
            'successor_of', successor_of_value,
            'lifecycle_state', 'frozen'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_strategy_version(text, jsonb, jsonb, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON strategy_version FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
