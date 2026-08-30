-- WU-26 Indicator definition registry: immutable, versioned Indicator
-- Definitions for Core and Experimental indicators (issue #40).
--
-- A definition version is append-only evidence.  A semantic change creates
-- a new version linked to its predecessor; historical evaluations keep
-- their pinned definition versions and the decision-time view resolves the
-- version actually in effect at any as-of moment.  Definitions retire
-- through an immutable lifecycle record -- never deletion or silent
-- substitution -- so the current state of a definition is the latest
-- lifecycle transition over its initial state, never an edited column.

CREATE FUNCTION indicator_definition_is_valid(definition_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF jsonb_typeof(definition_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(definition_value->'purpose') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'units') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'formula') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'timestamp_semantics') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'adjustment_semantics') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'calendar') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'missingness') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'ownership') IS DISTINCT FROM 'string'
       OR jsonb_typeof(definition_value->'inputs') IS DISTINCT FROM 'array'
       OR jsonb_typeof(definition_value->'certified_sources') IS DISTINCT FROM 'array'
       OR jsonb_typeof(definition_value->'precision') IS DISTINCT FROM 'number'
       OR jsonb_typeof(definition_value->'freshness') IS DISTINCT FROM 'object'
       OR jsonb_typeof(definition_value->'valid_ranges') IS DISTINCT FROM 'object'
       OR jsonb_typeof(definition_value->'golden_cases') IS DISTINCT FROM 'array'
       OR jsonb_typeof(definition_value->'canonical_horizons') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;

    IF coalesce(btrim(definition_value->>'purpose'), '') = ''
       OR coalesce(btrim(definition_value->>'units'), '') = ''
       OR coalesce(btrim(definition_value->>'formula'), '') = ''
       OR coalesce(btrim(definition_value->>'timestamp_semantics'), '') = ''
       OR coalesce(btrim(definition_value->>'adjustment_semantics'), '') = ''
       OR coalesce(btrim(definition_value->>'calendar'), '') = ''
       OR coalesce(btrim(definition_value->>'missingness'), '') = ''
       OR coalesce(btrim(definition_value->>'ownership'), '') = '' THEN
        RETURN false;
    END IF;

    IF (definition_value->'precision')::numeric <= 0
       OR (definition_value->'precision')::numeric
          <> floor((definition_value->'precision')::numeric) THEN
        RETURN false;
    END IF;

    -- Freshness and valid-ranges contracts must actually be fixed, not vacuous.
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_object_keys(definition_value->'freshness')
    ) OR NOT EXISTS (
        SELECT 1 FROM jsonb_object_keys(definition_value->'valid_ranges')
    ) THEN
        RETURN false;
    END IF;

    -- Golden reference cases are named, structured fixtures.
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(definition_value->'golden_cases') g
        WHERE jsonb_typeof(g.value) IS DISTINCT FROM 'object'
           OR jsonb_typeof(g.value->'name') IS DISTINCT FROM 'string'
           OR coalesce(btrim(g.value->>'name'), '') = ''
           OR NOT (g.value ? 'expected')
    ) THEN
        RETURN false;
    END IF;

    -- Ordered certified sources must all name registered sources.
    IF jsonb_array_length(definition_value->'inputs') < 1
       OR jsonb_array_length(definition_value->'certified_sources') < 1
       OR jsonb_array_length(definition_value->'golden_cases') < 1 THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(definition_value->'certified_sources') s
        WHERE coalesce(btrim(s.value), '') = ''
    ) THEN
        RETURN false;
    END IF;

    -- Every input naming a source must cite one of the certified sources,
    -- so an unregistered provider cannot sneak in through the inputs list.
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(definition_value->'inputs') i
        WHERE jsonb_typeof(i.value) IS DISTINCT FROM 'object'
           OR jsonb_typeof(i.value->'name') IS DISTINCT FROM 'string'
           OR coalesce(btrim(i.value->>'name'), '') = ''
           OR (
                i.value ? 'source'
                AND (
                  jsonb_typeof(i.value->'source') IS DISTINCT FROM 'string'
                  OR NOT ((i.value->>'source') IN (
                        SELECT jsonb_array_elements_text(definition_value->'certified_sources')))
                )
           )
    ) THEN
        RETURN false;
    END IF;

    -- Canonical session horizons are fixed by issue #40.
    IF jsonb_array_length(definition_value->'canonical_horizons') < 1
       OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(definition_value->'canonical_horizons') h
            WHERE jsonb_typeof(h.value) <> 'number'
               OR (h.value)::numeric NOT IN (1, 5, 20, 60, 126, 252)
       ) THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE TABLE indicator_definition_version (
    definition_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    indicator_key text NOT NULL CHECK (btrim(indicator_key) <> ''),
    version integer NOT NULL CHECK (version >= 1),
    indicator_kind text NOT NULL CHECK (indicator_kind IN ('core', 'experimental')),
    definition_state text NOT NULL CHECK (definition_state IN ('declared', 'experimental')),
    definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    definition_digest text NOT NULL CHECK (definition_digest ~ '^[0-9a-f]{64}$'),
    successor_of uuid REFERENCES indicator_definition_version(definition_version_id),
    effective_from timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        definition_digest
        = encode(digest(convert_to(definition::text, 'UTF8'), 'sha256'), 'hex')
    ),
    CHECK (
        (indicator_kind = 'core' AND definition_state = 'declared')
        OR (indicator_kind = 'experimental' AND definition_state = 'experimental')
    ),
    UNIQUE (indicator_key, version)
);

SELECT register_evidence_table('indicator_definition_version');

CREATE TABLE indicator_definition_lifecycle (
    transition_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_version_id uuid NOT NULL
        REFERENCES indicator_definition_version(definition_version_id),
    from_state text NOT NULL CHECK (from_state IN ('declared', 'experimental', 'retired')),
    to_state text NOT NULL CHECK (to_state IN ('declared', 'experimental', 'retired')),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    preregistration_ref text,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (from_state <> to_state)
);

SELECT register_evidence_table('indicator_definition_lifecycle');

CREATE INDEX indicator_definition_version_key_idx
    ON indicator_definition_version (indicator_key, effective_from, version);
CREATE INDEX indicator_definition_lifecycle_version_idx
    ON indicator_definition_lifecycle (definition_version_id, receipt_time);

CREATE FUNCTION guard_indicator_definition_version_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'indicator_definition_version is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_indicator_definition_lifecycle_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'indicator_definition_lifecycle is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER indicator_definition_version_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON indicator_definition_version
    FOR EACH STATEMENT EXECUTE FUNCTION guard_indicator_definition_version_write();
CREATE TRIGGER indicator_definition_lifecycle_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON indicator_definition_lifecycle
    FOR EACH STATEMENT EXECUTE FUNCTION guard_indicator_definition_lifecycle_write();

-- The owning role still owns these tables in stage 1 (issue #97), so direct
-- INSERTs are gated behind the same session flag the workflow functions set,
-- mirroring the coverage-policy registry: no smuggled versions, lineages, or
-- unaudited lifecycle rows.
CREATE FUNCTION guard_indicator_definition_version_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.indicator_definition_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'indicator_definition_version writes must go through append_indicator_definition_version'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_indicator_definition_lifecycle_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.indicator_definition_lifecycle_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'indicator_definition_lifecycle writes must go through record_indicator_definition_lifecycle'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER indicator_definition_version_insert_guard
    BEFORE INSERT ON indicator_definition_version
    FOR EACH ROW EXECUTE FUNCTION guard_indicator_definition_version_insert();
CREATE TRIGGER indicator_definition_lifecycle_insert_guard
    BEFORE INSERT ON indicator_definition_lifecycle
    FOR EACH ROW EXECUTE FUNCTION guard_indicator_definition_lifecycle_insert();

CREATE FUNCTION indicator_definition_transition_is_legal(
    from_state_value text,
    to_state_value text
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT (from_state_value, to_state_value) IN (
        VALUES ('declared', 'retired'),
               ('experimental', 'retired')
    );
$$;

CREATE FUNCTION indicator_definition_current_state(
    definition_version_id_value uuid
) RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(
        (SELECT to_state
         FROM indicator_definition_lifecycle l
         WHERE l.definition_version_id = definition_version_id_value
         ORDER BY l.receipt_time DESC, l.transition_id DESC
         LIMIT 1),
        (SELECT definition_state
         FROM indicator_definition_version v
         WHERE v.definition_version_id = definition_version_id_value)
    );
$$;

-- The corrected-research view: the latest version per indicator with its
-- current lifecycle state.  This is deliberately "latest version", not
-- "in effect now" -- use indicator_definition_at for the decision-time view
-- of what a historical evaluation actually resolved.
CREATE VIEW current_indicator_definition AS
    SELECT DISTINCT ON (v.indicator_key)
        v.indicator_key,
        v.definition_version_id,
        v.indicator_kind,
        indicator_definition_current_state(v.definition_version_id) AS current_state,
        v.version,
        v.definition,
        v.definition_digest,
        v.successor_of,
        v.effective_from,
        v.receipt_time
    FROM indicator_definition_version v
    ORDER BY v.indicator_key, v.version DESC;

CREATE FUNCTION append_indicator_definition_version(
    indicator_key_value text,
    version_value integer,
    indicator_kind_value text,
    definition_value jsonb,
    successor_of_value uuid,
    effective_from_value timestamptz,
    source_lineage_value jsonb
) RETURNS indicator_definition_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created indicator_definition_version%ROWTYPE;
    latest_row indicator_definition_version%ROWTYPE;
    initial_state_value text;
    source_key_value text;
BEGIN
    IF coalesce(btrim(indicator_key_value), '') = ''
       OR version_value IS NULL OR version_value < 1
       OR indicator_kind_value NOT IN ('core', 'experimental')
       OR effective_from_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'indicator definition version arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT indicator_definition_is_valid(definition_value) THEN
        RAISE EXCEPTION 'indicator definition is incomplete, mistyped, or uses a noncanonical horizon'
            USING ERRCODE = '22023';
    END IF;

    FOR source_key_value IN
        SELECT s.value FROM jsonb_array_elements_text(definition_value->'certified_sources') s
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM source_registry r
            WHERE r.source_key = source_key_value
        ) THEN
            RAISE EXCEPTION 'indicator definition cites unregistered source %', source_key_value
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    -- Serialize per-key version allocation and enforce the #40 contracts:
    -- consecutive versions, an unchanging indicator kind (an experiment can
    -- never be re-versioned into a core indicator), and a strictly advancing
    -- effective_from so a later append can never rewrite decision-time
    -- resolution of earlier as-of moments.
    PERFORM pg_advisory_xact_lock(hashtextextended(indicator_key_value, 25023));
    SELECT * INTO latest_row
    FROM indicator_definition_version
    WHERE indicator_key = indicator_key_value
    ORDER BY version DESC
    LIMIT 1;

    IF version_value = 1 THEN
        IF latest_row.definition_version_id IS NOT NULL THEN
            RAISE EXCEPTION 'indicator % already has version %; versions are immutable',
                indicator_key_value, latest_row.version
                USING ERRCODE = '23505';
        END IF;
        IF successor_of_value IS NOT NULL THEN
            RAISE EXCEPTION 'indicator definition version 1 cannot have a predecessor'
                USING ERRCODE = '22023';
        END IF;
    ELSE
        IF latest_row.definition_version_id IS NULL
           OR latest_row.version <> version_value - 1 THEN
            RAISE EXCEPTION
                'indicator % must define version % directly after its latest version',
                indicator_key_value, version_value
                USING ERRCODE = '22023';
        END IF;
        IF successor_of_value IS DISTINCT FROM latest_row.definition_version_id THEN
            RAISE EXCEPTION
                'indicator definition version % must declare the latest version as its successor_of',
                version_value
                USING ERRCODE = '22023';
        END IF;
        IF indicator_kind_value <> latest_row.indicator_kind THEN
            RAISE EXCEPTION
                'indicator % cannot change kind from % to %; a successful experiment never becomes a core indicator and a new experiment needs a new indicator key',
                indicator_key_value, latest_row.indicator_kind, indicator_kind_value
                USING ERRCODE = '22023';
        END IF;
        IF effective_from_value <= latest_row.effective_from THEN
            RAISE EXCEPTION
                'indicator definition effective_from must advance past the previous version; backdating would rewrite decision-time resolution'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    IF indicator_kind_value = 'core' THEN
        initial_state_value := 'declared';
    ELSE
        initial_state_value := 'experimental';
    END IF;

    PERFORM set_config('market_mate.indicator_definition_write', 'on', true);
    BEGIN
        INSERT INTO indicator_definition_version (
            indicator_key, version, indicator_kind, definition_state,
            definition, definition_digest, successor_of, effective_from,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            indicator_key_value, version_value, indicator_kind_value, initial_state_value,
            definition_value,
            encode(digest(convert_to(definition_value::text, 'UTF8'), 'sha256'), 'hex'),
            successor_of_value, effective_from_value,
            source_lineage_value, now(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.indicator_definition_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.indicator_definition_write', 'off', true);

    PERFORM append_audit_event(
        'indicator-definition:' || indicator_key_value || ':' || version_value::text,
        'research.indicator_definition_appended',
        now(),
        jsonb_build_object(
            'definition_version_id', created.definition_version_id,
            'indicator_key', indicator_key_value,
            'version', version_value,
            'indicator_kind', indicator_kind_value,
            'definition_state', initial_state_value,
            'successor_of', successor_of_value,
            'definition_digest', created.definition_digest
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE FUNCTION record_indicator_definition_lifecycle(
    definition_version_id_value uuid,
    to_state_value text,
    reason_value text,
    preregistration_ref_value text,
    source_lineage_value jsonb
) RETURNS indicator_definition_lifecycle
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row indicator_definition_version%ROWTYPE;
    from_state_value text;
    created indicator_definition_lifecycle%ROWTYPE;
BEGIN
    IF definition_version_id_value IS NULL
       OR to_state_value NOT IN ('declared', 'experimental', 'retired')
       OR coalesce(btrim(reason_value), '') = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'indicator definition lifecycle arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO version_row
    FROM indicator_definition_version
    WHERE definition_version_id = definition_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'indicator definition version % is not registered',
            definition_version_id_value
            USING ERRCODE = '22023';
    END IF;
    from_state_value := indicator_definition_current_state(definition_version_id_value);
    IF NOT indicator_definition_transition_is_legal(from_state_value, to_state_value) THEN
        RAISE EXCEPTION
            'indicator definition transition % -> % is illegal; a successful experiment never becomes a core indicator and retired definitions never revive',
            from_state_value, to_state_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(definition_version_id_value::text, 25024));
    PERFORM set_config('market_mate.indicator_definition_lifecycle_write', 'on', true);
    BEGIN
        INSERT INTO indicator_definition_lifecycle (
            definition_version_id, from_state, to_state, reason,
            preregistration_ref,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            definition_version_id_value, from_state_value, to_state_value, reason_value,
            preregistration_ref_value,
            source_lineage_value, now(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.indicator_definition_lifecycle_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.indicator_definition_lifecycle_write', 'off', true);

    PERFORM append_audit_event(
        'indicator-lifecycle:' || definition_version_id_value::text || ':' || to_state_value,
        'research.indicator_definition_lifecycle_recorded',
        now(),
        jsonb_build_object(
            'transition_id', created.transition_id,
            'definition_version_id', definition_version_id_value,
            'indicator_key', version_row.indicator_key,
            'version', version_row.version,
            'from_state', from_state_value,
            'to_state', to_state_value,
            'preregistration_ref', preregistration_ref_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE FUNCTION indicator_definition_at(
    indicator_key_value text,
    as_of_value timestamptz
) RETURNS indicator_definition_version
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT v
    FROM indicator_definition_version v
    WHERE v.indicator_key = indicator_key_value
      AND v.effective_from <= as_of_value
    ORDER BY v.version DESC
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION append_indicator_definition_version(text, integer, text, jsonb, uuid, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_indicator_definition_lifecycle(uuid, text, text, text, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON indicator_definition_version, indicator_definition_lifecycle
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
