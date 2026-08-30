-- WU-28 Experimental observation states: Indicator Evidence Stage for
-- Experimental Indicators (issues #40, #42). A successful experiment stays
-- experimental and may become a pinned Strategy Version input only through
-- an immutable #42 preregistration plus a complete lineage manifest. It
-- never becomes Core and never grants Live authority.

CREATE FUNCTION experimental_preregistration_spec_is_complete(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'hypothesis') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'hypothesis'), '') = ''
       OR jsonb_typeof(spec_value->'rationale') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'rationale'), '') = ''
       OR jsonb_typeof(spec_value->'target') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'target'), '') = ''
       OR jsonb_typeof(spec_value->'indicator_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'indicator_key'), '') = ''
       OR jsonb_typeof(spec_value->'primary_metric') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'primary_metric'), '') = ''
       OR jsonb_typeof(spec_value->'experiment_family') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'experiment_family'), '') = ''
       OR jsonb_typeof(spec_value->'multiplicity_plan') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'multiplicity_plan'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'horizon') IS DISTINCT FROM 'string'
       AND jsonb_typeof(spec_value->'horizon') IS DISTINCT FROM 'number' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'horizon') = 'string'
       AND coalesce(btrim(spec_value->>'horizon'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'universe') IS DISTINCT FROM 'string'
       AND jsonb_typeof(spec_value->'universe') IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'universe') = 'string'
       AND coalesce(btrim(spec_value->>'universe'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'universe') = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(spec_value->'universe')) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'stopping_rule') IS DISTINCT FROM 'string'
       AND jsonb_typeof(spec_value->'stopping_rule') IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'stopping_rule') = 'string'
       AND coalesce(btrim(spec_value->>'stopping_rule'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'stopping_rule') = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(spec_value->'stopping_rule')) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'promotion_gate') IS DISTINCT FROM 'string'
       AND jsonb_typeof(spec_value->'promotion_gate') IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'promotion_gate') = 'string'
       AND coalesce(btrim(spec_value->>'promotion_gate'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'promotion_gate') = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(spec_value->'promotion_gate')) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'testing_budget') IS DISTINCT FROM 'string'
       AND jsonb_typeof(spec_value->'testing_budget') IS DISTINCT FROM 'object'
       AND jsonb_typeof(spec_value->'testing_budget') IS DISTINCT FROM 'number' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'testing_budget') = 'string'
       AND coalesce(btrim(spec_value->>'testing_budget'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'testing_budget') = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(spec_value->'testing_budget')) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'windows') IS DISTINCT FROM 'object'
       OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(spec_value->'windows')) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'estimators') = 'object' THEN
        IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(spec_value->'estimators')) THEN
            RETURN false;
        END IF;
    ELSIF jsonb_typeof(spec_value->'estimators') = 'array' THEN
        IF jsonb_array_length(spec_value->'estimators') < 1 THEN
            RETURN false;
        END IF;
    ELSE
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION experimental_indicator_stage_is_legal(
    from_stage_value text,
    to_stage_value text
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT (from_stage_value, to_stage_value) IN (
        VALUES ('unregistered', 'registered'),
               ('registered', 'data_certified'),
               ('data_certified', 'research_qualified'),
               ('research_qualified', 'paper_eligible'),
               ('paper_eligible', 'strategy_eligible')
    );
$$;

CREATE TABLE experimental_indicator_lineage (
    lineage_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_version_id uuid NOT NULL
        REFERENCES indicator_definition_version(definition_version_id),
    registration_id uuid NOT NULL
        REFERENCES experiment_preregistration(registration_id),
    predecessor_stage_record_id uuid,
    lineage_manifest jsonb NOT NULL CHECK (jsonb_typeof(lineage_manifest) = 'object'),
    lineage_digest text NOT NULL CHECK (lineage_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        lineage_digest
        = encode(digest(convert_to(lineage_manifest::text, 'UTF8'), 'sha256'), 'hex')
    )
);

SELECT register_evidence_table('experimental_indicator_lineage');

CREATE TABLE experimental_indicator_stage (
    stage_record_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_version_id uuid NOT NULL
        REFERENCES indicator_definition_version(definition_version_id),
    lineage_id uuid NOT NULL
        REFERENCES experimental_indicator_lineage(lineage_id),
    from_stage text NOT NULL CHECK (from_stage IN (
        'unregistered', 'registered', 'data_certified', 'research_qualified',
        'paper_eligible', 'strategy_eligible'
    )),
    to_stage text NOT NULL CHECK (to_stage IN (
        'registered', 'data_certified', 'research_qualified',
        'paper_eligible', 'strategy_eligible'
    )),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (from_stage <> to_stage),
    CHECK (experimental_indicator_stage_is_legal(from_stage, to_stage)),
    UNIQUE (definition_version_id, to_stage)
);

SELECT register_evidence_table('experimental_indicator_stage');

ALTER TABLE experimental_indicator_lineage
    ADD CONSTRAINT experimental_indicator_lineage_predecessor_fk
    FOREIGN KEY (predecessor_stage_record_id)
    REFERENCES experimental_indicator_stage(stage_record_id);

CREATE UNIQUE INDEX experimental_indicator_lineage_definition_register_uq
    ON experimental_indicator_lineage (definition_version_id)
    WHERE predecessor_stage_record_id IS NULL;
CREATE UNIQUE INDEX experimental_indicator_lineage_registration_register_uq
    ON experimental_indicator_lineage (registration_id)
    WHERE predecessor_stage_record_id IS NULL;
CREATE INDEX experimental_indicator_stage_definition_idx
    ON experimental_indicator_stage (definition_version_id, receipt_time);
CREATE INDEX experimental_indicator_lineage_definition_idx
    ON experimental_indicator_lineage (definition_version_id, receipt_time);

CREATE FUNCTION guard_experimental_indicator_lineage_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'experimental_indicator_lineage is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_experimental_indicator_stage_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'experimental_indicator_stage is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER experimental_indicator_lineage_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON experimental_indicator_lineage
    FOR EACH STATEMENT EXECUTE FUNCTION guard_experimental_indicator_lineage_write();
CREATE TRIGGER experimental_indicator_stage_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON experimental_indicator_stage
    FOR EACH STATEMENT EXECUTE FUNCTION guard_experimental_indicator_stage_write();

CREATE FUNCTION guard_experimental_indicator_lineage_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.experimental_indicator_lineage_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'experimental_indicator_lineage writes must go through register_experimental_indicator_use or advance_experimental_indicator_stage'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_experimental_indicator_stage_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.experimental_indicator_stage_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'experimental_indicator_stage writes must go through register_experimental_indicator_use or advance_experimental_indicator_stage'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER experimental_indicator_lineage_insert_guard
    BEFORE INSERT ON experimental_indicator_lineage
    FOR EACH ROW EXECUTE FUNCTION guard_experimental_indicator_lineage_insert();
CREATE TRIGGER experimental_indicator_stage_insert_guard
    BEFORE INSERT ON experimental_indicator_stage
    FOR EACH ROW EXECUTE FUNCTION guard_experimental_indicator_stage_insert();

CREATE FUNCTION experimental_indicator_current_stage(
    definition_version_id_value uuid
) RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(
        (SELECT s.to_stage
         FROM experimental_indicator_stage s
         WHERE s.definition_version_id = definition_version_id_value
           AND NOT EXISTS (
             SELECT 1
             FROM experimental_indicator_lineage later
             WHERE later.predecessor_stage_record_id = s.stage_record_id
           )
         LIMIT 1),
        'unregistered'
    );
$$;

CREATE FUNCTION experimental_indicator_bound_registration(
    definition_version_id_value uuid
) RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT l.registration_id
    FROM experimental_indicator_lineage l
    WHERE l.definition_version_id = definition_version_id_value
      AND l.predecessor_stage_record_id IS NULL
    LIMIT 1;
$$;

CREATE FUNCTION experimental_indicator_latest_stage_record(
    definition_version_id_value uuid
) RETURNS experimental_indicator_stage
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT s
    FROM experimental_indicator_stage s
    WHERE s.definition_version_id = definition_version_id_value
      AND NOT EXISTS (
        SELECT 1
        FROM experimental_indicator_lineage later
        WHERE later.predecessor_stage_record_id = s.stage_record_id
      )
    LIMIT 1;
$$;

CREATE FUNCTION experimental_indicator_lineage_manifest_is_valid(
    manifest_value jsonb,
    definition_row indicator_definition_version,
    registration_row experiment_preregistration,
    predecessor_stage_record_id_value uuid
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF jsonb_typeof(manifest_value) IS DISTINCT FROM 'object'
       OR definition_row.definition_version_id IS NULL
       OR registration_row.registration_id IS NULL THEN
        RETURN false;
    END IF;
    IF manifest_value->>'definition_version_id'
          IS DISTINCT FROM definition_row.definition_version_id::text
       OR manifest_value->>'definition_digest'
          IS DISTINCT FROM definition_row.definition_digest
       OR manifest_value->>'indicator_key'
          IS DISTINCT FROM definition_row.indicator_key
       OR manifest_value->>'indicator_kind'
          IS DISTINCT FROM 'experimental'
       OR manifest_value->>'registration_id'
          IS DISTINCT FROM registration_row.registration_id::text
       OR manifest_value->>'spec_digest'
          IS DISTINCT FROM registration_row.spec_digest THEN
        RETURN false;
    END IF;
    IF manifest_value->'certified_sources'
          IS DISTINCT FROM definition_row.definition->'certified_sources' THEN
        RETURN false;
    END IF;
    IF NOT (manifest_value ? 'predecessor_stage_record_id') THEN
        RETURN false;
    END IF;
    IF predecessor_stage_record_id_value IS NULL THEN
        IF manifest_value->'predecessor_stage_record_id' IS DISTINCT FROM 'null'::jsonb THEN
            RETURN false;
        END IF;
    ELSE
        IF manifest_value->>'predecessor_stage_record_id'
              IS DISTINCT FROM predecessor_stage_record_id_value::text THEN
            RETURN false;
        END IF;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION register_experimental_indicator_use(
    definition_version_id_value uuid,
    registration_id_value uuid,
    lineage_manifest_value jsonb,
    source_lineage_value jsonb
) RETURNS experimental_indicator_stage
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    definition_row indicator_definition_version%ROWTYPE;
    registration_row experiment_preregistration%ROWTYPE;
    lifecycle_state_value text;
    created_lineage experimental_indicator_lineage%ROWTYPE;
    created_stage experimental_indicator_stage%ROWTYPE;
BEGIN
    IF definition_version_id_value IS NULL
       OR registration_id_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'experimental indicator registration arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO definition_row
    FROM indicator_definition_version
    WHERE definition_version_id = definition_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'indicator definition version % is not registered',
            definition_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF definition_row.indicator_kind IS DISTINCT FROM 'experimental' THEN
        RAISE EXCEPTION
            'core indicators cannot enter experimental evidence stages'
            USING ERRCODE = '22023';
    END IF;
    lifecycle_state_value := indicator_definition_current_state(definition_version_id_value);
    IF lifecycle_state_value IS DISTINCT FROM 'experimental' THEN
        RAISE EXCEPTION
            'retired experimental indicator % cannot be registered for evidence stages',
            definition_row.indicator_key
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
    IF NOT experimental_preregistration_spec_is_complete(registration_row.spec) THEN
        RAISE EXCEPTION
            'experiment preregistration spec is incomplete for experimental indicator promotion'
            USING ERRCODE = '22023';
    END IF;
    IF registration_row.spec->>'indicator_key' IS DISTINCT FROM definition_row.indicator_key THEN
        RAISE EXCEPTION
            'experiment preregistration indicator_key does not match definition %',
            definition_row.indicator_key
            USING ERRCODE = '22023';
    END IF;
    IF NOT experimental_indicator_lineage_manifest_is_valid(
        lineage_manifest_value, definition_row, registration_row, NULL
    ) THEN
        RAISE EXCEPTION
            'experimental indicator lineage manifest is incomplete or does not bind the definition and preregistration'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(definition_version_id_value::text, 29023));
    PERFORM pg_advisory_xact_lock(
        hashtextextended(registration_id_value::text, 29024));

    IF experimental_indicator_current_stage(definition_version_id_value)
          IS DISTINCT FROM 'unregistered' THEN
        RAISE EXCEPTION
            'experimental indicator % already has an evidence stage; registration is immutable',
            definition_row.indicator_key
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM experimental_indicator_lineage l
        WHERE l.registration_id = registration_id_value
          AND l.predecessor_stage_record_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'experiment preregistration % is already bound to an experimental definition',
            registration_id_value
            USING ERRCODE = '23505';
    END IF;

    PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'on', true);
    PERFORM set_config('market_mate.experimental_indicator_stage_write', 'on', true);
    BEGIN
        INSERT INTO experimental_indicator_lineage (
            definition_version_id, registration_id, predecessor_stage_record_id,
            lineage_manifest, lineage_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            definition_version_id_value, registration_id_value, NULL,
            lineage_manifest_value,
            encode(digest(convert_to(lineage_manifest_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created_lineage;

        INSERT INTO experimental_indicator_stage (
            definition_version_id, lineage_id, from_stage, to_stage,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            definition_version_id_value, created_lineage.lineage_id,
            'unregistered', 'registered',
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created_stage;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'off', true);
            PERFORM set_config('market_mate.experimental_indicator_stage_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'off', true);
    PERFORM set_config('market_mate.experimental_indicator_stage_write', 'off', true);

    PERFORM append_audit_event(
        'experimental-indicator-register:' || created_stage.stage_record_id::text,
        'research.experimental_indicator_registered',
        now(),
        jsonb_build_object(
            'stage_record_id', created_stage.stage_record_id,
            'lineage_id', created_lineage.lineage_id,
            'definition_version_id', definition_version_id_value,
            'indicator_key', definition_row.indicator_key,
            'registration_id', registration_id_value,
            'to_stage', created_stage.to_stage,
            'lineage_digest', created_lineage.lineage_digest,
            'spec_digest', registration_row.spec_digest
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created_stage;
END;
$$;

CREATE FUNCTION advance_experimental_indicator_stage(
    definition_version_id_value uuid,
    to_stage_value text,
    lineage_manifest_value jsonb,
    source_lineage_value jsonb
) RETURNS experimental_indicator_stage
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    definition_row indicator_definition_version%ROWTYPE;
    registration_row experiment_preregistration%ROWTYPE;
    latest_stage experimental_indicator_stage%ROWTYPE;
    lifecycle_state_value text;
    from_stage_value text;
    bound_registration_id uuid;
    created_lineage experimental_indicator_lineage%ROWTYPE;
    created_stage experimental_indicator_stage%ROWTYPE;
BEGIN
    IF definition_version_id_value IS NULL
       OR to_stage_value NOT IN (
            'registered', 'data_certified', 'research_qualified',
            'paper_eligible', 'strategy_eligible'
       )
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'experimental indicator stage arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO definition_row
    FROM indicator_definition_version
    WHERE definition_version_id = definition_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'indicator definition version % is not registered',
            definition_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF definition_row.indicator_kind IS DISTINCT FROM 'experimental' THEN
        RAISE EXCEPTION
            'core indicators cannot enter experimental evidence stages'
            USING ERRCODE = '22023';
    END IF;
    lifecycle_state_value := indicator_definition_current_state(definition_version_id_value);
    IF lifecycle_state_value IS DISTINCT FROM 'experimental' THEN
        RAISE EXCEPTION
            'retired experimental indicator % cannot advance evidence stages',
            definition_row.indicator_key
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(definition_version_id_value::text, 29023));

    bound_registration_id := experimental_indicator_bound_registration(
        definition_version_id_value);
    IF bound_registration_id IS NULL THEN
        RAISE EXCEPTION
            'experimental indicator % has no preregistration; promotion requires #42 registration',
            definition_row.indicator_key
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO registration_row
    FROM experiment_preregistration
    WHERE registration_id = bound_registration_id;
    latest_stage := experimental_indicator_latest_stage_record(definition_version_id_value);
    from_stage_value := coalesce(latest_stage.to_stage, 'unregistered');
    IF NOT experimental_indicator_stage_is_legal(from_stage_value, to_stage_value) THEN
        RAISE EXCEPTION
            'experimental indicator transition % -> % is illegal; stages cannot skip, reverse, or become core',
            from_stage_value, to_stage_value
            USING ERRCODE = '22023';
    END IF;
    IF NOT experimental_indicator_lineage_manifest_is_valid(
        lineage_manifest_value, definition_row, registration_row,
        latest_stage.stage_record_id
    ) THEN
        RAISE EXCEPTION
            'experimental indicator lineage manifest is incomplete or does not bind the definition and preregistration'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(bound_registration_id::text, 29024));

    PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'on', true);
    PERFORM set_config('market_mate.experimental_indicator_stage_write', 'on', true);
    BEGIN
        INSERT INTO experimental_indicator_lineage (
            definition_version_id, registration_id, predecessor_stage_record_id,
            lineage_manifest, lineage_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            definition_version_id_value, bound_registration_id,
            latest_stage.stage_record_id,
            lineage_manifest_value,
            encode(digest(convert_to(lineage_manifest_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created_lineage;

        INSERT INTO experimental_indicator_stage (
            definition_version_id, lineage_id, from_stage, to_stage,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            definition_version_id_value, created_lineage.lineage_id,
            from_stage_value, to_stage_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created_stage;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'off', true);
            PERFORM set_config('market_mate.experimental_indicator_stage_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'off', true);
    PERFORM set_config('market_mate.experimental_indicator_stage_write', 'off', true);

    PERFORM append_audit_event(
        'experimental-indicator-stage:' || created_stage.stage_record_id::text,
        'research.experimental_indicator_stage_advanced',
        now(),
        jsonb_build_object(
            'stage_record_id', created_stage.stage_record_id,
            'lineage_id', created_lineage.lineage_id,
            'definition_version_id', definition_version_id_value,
            'indicator_key', definition_row.indicator_key,
            'registration_id', bound_registration_id,
            'from_stage', from_stage_value,
            'to_stage', to_stage_value,
            'lineage_digest', created_lineage.lineage_digest,
            'predecessor_stage_record_id', latest_stage.stage_record_id
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created_stage;
END;
$$;

CREATE VIEW current_experimental_indicator_stage AS
    SELECT
        s.stage_record_id,
        s.definition_version_id,
        v.indicator_key,
        v.indicator_kind,
        s.from_stage,
        s.to_stage AS current_stage,
        l.registration_id,
        l.lineage_digest,
        p.spec_digest,
        s.receipt_time
    FROM experimental_indicator_stage s
    JOIN experimental_indicator_lineage l ON l.lineage_id = s.lineage_id
    JOIN indicator_definition_version v
      ON v.definition_version_id = s.definition_version_id
    JOIN experiment_preregistration p ON p.registration_id = l.registration_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM experimental_indicator_lineage later
        WHERE later.predecessor_stage_record_id = s.stage_record_id
    );

REVOKE ALL ON FUNCTION register_experimental_indicator_use(uuid, uuid, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION advance_experimental_indicator_stage(uuid, text, jsonb, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON experimental_indicator_lineage, experimental_indicator_stage
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
