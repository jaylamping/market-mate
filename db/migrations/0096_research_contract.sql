-- PR1 research contracts + artifact verification (wayfinder map #171, decision #172).
--
-- Minimal immutable assignment pins (Desk Role, Strategy Thesis ID, Research
-- Posture profile+version, recipe/contract version, cosmetic-only Presentation
-- Persona; momentum_v1 params fixed by contract) plus full-chain artifact
-- provenance (Evidence Lineage Manifest + Agent Provenance Chain carried on the
-- artifact as a checkable copy; the driver dispatch record stays
-- authoritative) and three narrow verification gates that assert no
-- edge/profit: contract validity, reproducibility, methodological readiness.
--
-- Additive only. Applied migration bytes stay immutable. No model, cost,
-- Paper, or Live authority change: this migration touches no capacity,
-- route-tier, or execution tables, grants no worker roles, and starts no
-- services. Lesson versions stay opaque pinned jsonb; memory admission
-- belongs to a later PR.
--
-- NOTE on numbering: this worktree heads at 0095 on origin/main 251ace5, so
-- the contract migration lands here as 0096. The 0096-0101 files visible
-- elsewhere are uncommitted work, not ancestors of this branch. Rename to
-- 0102 on rebase if they merge first; the migrator requires contiguity.

CREATE FUNCTION research_posture_profile_is_canonical(profile_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT btrim(profile_value) IN (
        'Passive Observer',
        'Conservative Verifier',
        'Balanced Investigator',
        'Aggressive Explorer',
        'Extreme Frontier',
        'Skeptical Reviewer',
        'Adversarial Red Team'
    );
$$;

-- Pure pin check shared by admission and the validity gate. Research
-- aggressiveness (posture) is validated here and never confers position-risk
-- authority: no sizing or risk fields exist in the pin set.
CREATE FUNCTION research_assignment_pins_valid(pins_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'assignment_key', 'desk_role', 'strategy_thesis_id',
        'posture_profile', 'posture_version', 'recipe_version',
        'contract_runner', 'persona_id', 'persona_cosmetic',
        'expires_at', 'parent_assignment_id'
    ];
BEGIN
    IF jsonb_typeof(pins_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_object_keys(pins_value) k
        WHERE k <> ALL (allowed)
    ) THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(pins_value->>'assignment_key'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(pins_value->'desk_role') IS DISTINCT FROM 'string'
       OR incubator_charter_role_is_forbidden(btrim(pins_value->>'desk_role'))
       OR NOT incubator_desk_role_is_allowed(btrim(pins_value->>'desk_role')) THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(pins_value->>'strategy_thesis_id'), '') = '' THEN
        RETURN false;
    END IF;
    IF NOT research_posture_profile_is_canonical(
            pins_value->>'posture_profile') THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(pins_value->>'posture_version'), '') = '' THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(pins_value->>'recipe_version'), '') = '' THEN
        RETURN false;
    END IF;
    IF btrim(pins_value->>'contract_runner') IS DISTINCT FROM 'momentum_v1' THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(pins_value->>'persona_id'), '') = '' THEN
        RETURN false;
    END IF;
    IF (pins_value->'persona_cosmetic') IS DISTINCT FROM to_jsonb(true) THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(pins_value->>'expires_at'), '') = '' THEN
        RETURN false;
    END IF;
    BEGIN
        PERFORM (pins_value->>'expires_at')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN false;
    END;
    IF pins_value ? 'parent_assignment_id'
       AND (pins_value->>'parent_assignment_id') IS NOT NULL
       AND btrim(pins_value->>'parent_assignment_id') <> '' THEN
        BEGIN
            PERFORM (pins_value->>'parent_assignment_id')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                RETURN false;
        END;
    END IF;
    IF incubator_json_claims_authority(pins_value) THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- Momentum scope fixed by contract: exactly the five momentum_v1 keys with
-- the Spec ranges, except quantile_count which the contract pins to the
-- executable set {2,4,5,10}. Mirrors momentum::Spec::valid.
CREATE FUNCTION research_momentum_spec_is_valid(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'runner', 'lookback_sessions', 'quantile_count',
        'one_way_cost_bps', 'borrow_bps_per_session'
    ];
    lookback_value bigint;
    quantile_value bigint;
    cost_value bigint;
    borrow_value bigint;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(spec_value)) <> 5 THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_object_keys(spec_value) k
        WHERE k <> ALL (allowed)
    ) THEN
        RETURN false;
    END IF;
    IF btrim(spec_value->>'runner') IS DISTINCT FROM 'momentum_v1' THEN
        RETURN false;
    END IF;
    lookback_value := strategy_sandbox_integer(
        spec_value->'lookback_sessions');
    IF lookback_value IS NULL OR lookback_value NOT BETWEEN 1 AND 5 THEN
        RETURN false;
    END IF;
    quantile_value := strategy_sandbox_integer(
        spec_value->'quantile_count');
    IF quantile_value IS NULL OR quantile_value NOT IN (2, 4, 5, 10) THEN
        RETURN false;
    END IF;
    cost_value := strategy_sandbox_integer(spec_value->'one_way_cost_bps');
    IF cost_value IS NULL OR cost_value NOT BETWEEN 0 AND 100 THEN
        RETURN false;
    END IF;
    borrow_value := strategy_sandbox_integer(
        spec_value->'borrow_bps_per_session');
    IF borrow_value IS NULL OR borrow_value NOT BETWEEN 0 AND 100 THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION research_spec_digest(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-research-spec-v1|' || spec_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION research_artifact_digest(artifact_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-research-artifact-v1|' || artifact_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION research_ancestry_is_wellformed(node jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    elem jsonb;
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    FOR elem IN SELECT * FROM jsonb_array_elements(node) LOOP
        IF jsonb_typeof(elem) IS DISTINCT FROM 'string'
           OR coalesce(btrim(elem #>> '{}'), '') = '' THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE TABLE research_assignment (
    assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_key text NOT NULL CHECK (btrim(assignment_key) <> ''),
    desk_role text NOT NULL,
    strategy_thesis_id text NOT NULL
        CHECK (btrim(strategy_thesis_id) <> ''),
    posture_profile text NOT NULL,
    posture_version text NOT NULL CHECK (btrim(posture_version) <> ''),
    recipe_version text NOT NULL CHECK (btrim(recipe_version) <> ''),
    contract_runner text NOT NULL CHECK (contract_runner = 'momentum_v1'),
    persona_id text NOT NULL CHECK (btrim(persona_id) <> ''),
    persona_cosmetic boolean NOT NULL DEFAULT true,
    expires_at timestamptz NOT NULL,
    parent_assignment_id uuid REFERENCES research_assignment(assignment_id),
    pins jsonb NOT NULL CHECK (jsonb_typeof(pins) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (incubator_desk_role_is_allowed(desk_role)),
    CHECK (NOT incubator_charter_role_is_forbidden(desk_role)),
    CHECK (research_posture_profile_is_canonical(posture_profile)),
    CHECK (persona_cosmetic IS TRUE),
    CHECK (research_assignment_pins_valid(pins)),
    CHECK (NOT incubator_json_claims_authority(pins)),
    CHECK (assignment_key = btrim(pins->>'assignment_key')),
    CHECK (desk_role = lower(btrim(pins->>'desk_role'))),
    CHECK (strategy_thesis_id = btrim(pins->>'strategy_thesis_id')),
    CHECK (posture_profile = btrim(pins->>'posture_profile')),
    CHECK (posture_version = btrim(pins->>'posture_version')),
    CHECK (recipe_version = btrim(pins->>'recipe_version')),
    CHECK (contract_runner = btrim(pins->>'contract_runner')),
    CHECK (persona_id = btrim(pins->>'persona_id')),
    CHECK ((pins->'persona_cosmetic') IS NOT DISTINCT FROM
        to_jsonb(persona_cosmetic)),
    CHECK (expires_at = (NULLIF(btrim(pins->>'expires_at'), ''))::timestamptz),
    CHECK ((NULLIF(btrim(pins->>'parent_assignment_id'), ''))::uuid
        IS NOT DISTINCT FROM parent_assignment_id),
    CHECK (parent_assignment_id IS DISTINCT FROM assignment_id),
    CHECK (record_environment = 'local_research'),
    UNIQUE (assignment_key)
);

SELECT register_evidence_table('research_assignment');

CREATE TABLE research_artifact_manifest (
    artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_key text NOT NULL CHECK (btrim(artifact_key) <> ''),
    assignment_id uuid NOT NULL REFERENCES research_assignment(assignment_id),
    run_key text NOT NULL CHECK (btrim(run_key) <> ''),
    intent_id text,
    attempt_id text,
    requested_route jsonb NOT NULL CHECK (jsonb_typeof(requested_route) = 'object'),
    actual_route jsonb NOT NULL CHECK (jsonb_typeof(actual_route) = 'object'),
    config_revision bigint NOT NULL CHECK (config_revision >= 0),
    fallback_ancestry jsonb NOT NULL DEFAULT '[]'::jsonb
        CHECK (research_ancestry_is_wellformed(fallback_ancestry)),
    author_assignment_id uuid NOT NULL
        REFERENCES research_assignment(assignment_id),
    author_run_key text NOT NULL CHECK (btrim(author_run_key) <> ''),
    author_role text NOT NULL CHECK (btrim(author_role) <> ''),
    refiner_assignment_id uuid REFERENCES research_assignment(assignment_id),
    refiner_run_key text,
    refiner_role text,
    author_family text NOT NULL CHECK (btrim(author_family) <> ''),
    reviewer_assignment_id uuid REFERENCES research_assignment(assignment_id),
    reviewer_run_key text,
    reviewer_role text,
    reviewer_family text,
    recipe_versions jsonb NOT NULL CHECK (jsonb_typeof(recipe_versions) = 'object'),
    lesson_versions jsonb NOT NULL CHECK (jsonb_typeof(lesson_versions) = 'object'),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    spec_digest text NOT NULL CHECK (spec_digest ~ '^[0-9a-f]{64}$'),
    artifact jsonb NOT NULL CHECK (jsonb_typeof(artifact) = 'object'),
    artifact_digest text NOT NULL CHECK (artifact_digest ~ '^[0-9a-f]{64}$'),
    dissent_preserved boolean NOT NULL DEFAULT false,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (research_momentum_spec_is_valid(spec)),
    CHECK (NOT incubator_json_claims_authority(spec)),
    CHECK (NOT incubator_json_claims_authority(artifact)),
    CHECK (NOT incubator_json_claims_authority(requested_route)),
    CHECK (NOT incubator_json_claims_authority(actual_route)),
    CHECK (spec_digest = research_spec_digest(spec)),
    CHECK (artifact_digest = research_artifact_digest(artifact)),
    CHECK (
        (refiner_assignment_id IS NULL
            AND refiner_run_key IS NULL
            AND refiner_role IS NULL)
        OR (refiner_assignment_id IS NOT NULL
            AND refiner_run_key IS NOT NULL
            AND refiner_role IS NOT NULL)
    ),
    CHECK (
        (reviewer_assignment_id IS NULL
            AND reviewer_run_key IS NULL
            AND reviewer_role IS NULL
            AND reviewer_family IS NULL)
        OR (reviewer_assignment_id IS NOT NULL
            AND reviewer_run_key IS NOT NULL
            AND reviewer_role IS NOT NULL
            AND reviewer_family IS NOT NULL)
    ),
    CHECK (record_environment = 'local_research'),
    UNIQUE (artifact_key)
);

SELECT register_evidence_table('research_artifact_manifest');

CREATE INDEX research_artifact_assignment_idx
    ON research_artifact_manifest (assignment_id, receipt_time);

CREATE TRIGGER research_assignment_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_assignment
    FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();

CREATE TRIGGER research_artifact_manifest_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_artifact_manifest
    FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();

CREATE TRIGGER research_assignment_insert_guard
    BEFORE INSERT ON research_assignment
    FOR EACH ROW EXECUTE FUNCTION guard_incubator_insert();

CREATE TRIGGER research_artifact_manifest_insert_guard
    BEFORE INSERT ON research_artifact_manifest
    FOR EACH ROW EXECUTE FUNCTION guard_incubator_insert();

CREATE FUNCTION admit_research_assignment(
    pins_value jsonb,
    source_lineage_value jsonb
) RETURNS research_assignment
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    existing research_assignment%ROWTYPE;
    created research_assignment%ROWTYPE;
    key_text text;
    desk_text text;
    thesis_text text;
    posture_text text;
    posture_version_text text;
    recipe_text text;
    persona_text text;
    expires_value timestamptz;
    parent_value uuid;
    pins_stored jsonb;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research assignment arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_assignment_pins_valid(pins_value) THEN
        RAISE EXCEPTION 'research assignment pins are invalid; Desk Role, Strategy Thesis ID, Research Posture profile+version, recipe/contract version, cosmetic-only Presentation Persona, momentum_v1 runner, and expiry are all required'
            USING ERRCODE = '22023';
    END IF;

    key_text := btrim(pins_value->>'assignment_key');
    desk_text := lower(btrim(pins_value->>'desk_role'));
    thesis_text := btrim(pins_value->>'strategy_thesis_id');
    posture_text := btrim(pins_value->>'posture_profile');
    posture_version_text := btrim(pins_value->>'posture_version');
    recipe_text := btrim(pins_value->>'recipe_version');
    persona_text := btrim(pins_value->>'persona_id');
    BEGIN
        expires_value := btrim(pins_value->>'expires_at')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'research assignment arguments are invalid'
                USING ERRCODE = '22023';
    END;
    parent_value := NULL;
    IF (pins_value->>'parent_assignment_id') IS NOT NULL
       AND btrim(pins_value->>'parent_assignment_id') <> '' THEN
        BEGIN
            parent_value := (pins_value->>'parent_assignment_id')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'research assignment arguments are invalid'
                    USING ERRCODE = '22023';
        END;
        IF NOT EXISTS (
            SELECT 1 FROM research_assignment
            WHERE assignment_id = parent_value
        ) THEN
            RAISE EXCEPTION 'research parent assignment % is not registered',
                parent_value
                USING ERRCODE = '22023';
        END IF;
    END IF;

    pins_stored := jsonb_build_object(
        'assignment_key', key_text,
        'desk_role', desk_text,
        'strategy_thesis_id', thesis_text,
        'posture_profile', posture_text,
        'posture_version', posture_version_text,
        'recipe_version', recipe_text,
        'contract_runner', 'momentum_v1',
        'persona_id', persona_text,
        'persona_cosmetic', true,
        -- Canonical UTC instant so the idempotency compare does not depend
        -- on the session TimeZone (S3): identical instants compare equal.
        'expires_at', to_char(
            expires_value AT TIME ZONE 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    );
    IF parent_value IS NOT NULL THEN
        pins_stored := pins_stored
            || jsonb_build_object('parent_assignment_id', parent_value::text);
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96001));

    SELECT * INTO existing
    FROM research_assignment
    WHERE assignment_key = key_text;
    IF FOUND THEN
        IF existing.pins IS DISTINCT FROM pins_stored THEN
            RAISE EXCEPTION
                'research assignment % is already registered with different pins',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        INSERT INTO research_assignment (
            assignment_key, desk_role, strategy_thesis_id,
            posture_profile, posture_version, recipe_version,
            contract_runner, persona_id, persona_cosmetic,
            expires_at, parent_assignment_id, pins,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, desk_text, thesis_text,
            posture_text, posture_version_text, recipe_text,
            'momentum_v1', persona_text, true,
            expires_value, parent_value, pins_stored,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-assignment:' || created.assignment_id::text,
        'research.research_assignment_admitted',
        now(),
        jsonb_build_object(
            'assignment_id', created.assignment_id,
            'assignment_key', key_text,
            'desk_role', desk_text,
            'posture_profile', posture_text,
            'recipe_version', recipe_text
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE FUNCTION record_research_artifact_manifest(
    artifact_key_value text,
    assignment_id_value uuid,
    run_key_value text,
    intent_id_value text,
    attempt_id_value text,
    requested_route_value jsonb,
    actual_route_value jsonb,
    config_revision_value bigint,
    fallback_ancestry_value jsonb,
    author_assignment_id_value uuid,
    author_run_key_value text,
    author_role_value text,
    refiner_assignment_id_value uuid,
    refiner_run_key_value text,
    refiner_role_value text,
    author_family_value text,
    reviewer_assignment_id_value uuid,
    reviewer_run_key_value text,
    reviewer_role_value text,
    reviewer_family_value text,
    recipe_versions_value jsonb,
    lesson_versions_value jsonb,
    spec_value jsonb,
    artifact_value jsonb,
    dissent_preserved_value boolean,
    source_lineage_value jsonb
) RETURNS research_artifact_manifest
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    existing research_artifact_manifest%ROWTYPE;
    created research_artifact_manifest%ROWTYPE;
    key_text text;
    run_text text;
    author_run_text text;
    author_role_text text;
    author_family_text text;
    reviewer_run_text text;
    reviewer_role_text text;
    reviewer_family_text text;
    refiner_run_text text;
    refiner_role_text text;
    intent_text text;
    attempt_text text;
    ancestry_elem jsonb;
    spec_digest_value text;
    artifact_digest_value text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(artifact_key_value);
    run_text := btrim(run_key_value);
    author_run_text := btrim(author_run_key_value);
    author_role_text := btrim(author_role_value);
    author_family_text := btrim(author_family_value);
    IF coalesce(key_text, '') = ''
       OR coalesce(run_text, '') = ''
       OR assignment_id_value IS NULL
       OR coalesce(author_run_text, '') = ''
       OR coalesce(author_role_text, '') = ''
       OR coalesce(author_family_text, '') = ''
       OR author_assignment_id_value IS NULL
       OR dissent_preserved_value IS NULL THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research assignment % is not registered',
            assignment_id_value
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = author_assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research author assignment % is not registered',
            author_assignment_id_value
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(requested_route_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(actual_route_value) IS DISTINCT FROM 'object'
       OR config_revision_value IS NULL
       OR config_revision_value < 0 THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_ancestry_is_wellformed(fallback_ancestry_value) THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF refiner_assignment_id_value IS NULL
       AND (refiner_run_key_value IS NOT NULL
            OR refiner_role_value IS NOT NULL) THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF refiner_assignment_id_value IS NOT NULL THEN
        refiner_run_text := btrim(refiner_run_key_value);
        refiner_role_text := btrim(refiner_role_value);
        IF coalesce(refiner_run_text, '') = ''
           OR coalesce(refiner_role_text, '') = '' THEN
            RAISE EXCEPTION 'research artifact arguments are invalid'
                USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM research_assignment
            WHERE assignment_id = refiner_assignment_id_value
        ) THEN
            RAISE EXCEPTION 'research refiner assignment % is not registered',
                refiner_assignment_id_value
                USING ERRCODE = '22023';
        END IF;
    END IF;
    IF reviewer_assignment_id_value IS NULL
       AND (reviewer_run_key_value IS NOT NULL
            OR reviewer_role_value IS NOT NULL
            OR reviewer_family_value IS NOT NULL) THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF reviewer_assignment_id_value IS NOT NULL THEN
        reviewer_run_text := btrim(reviewer_run_key_value);
        reviewer_role_text := btrim(reviewer_role_value);
        reviewer_family_text := btrim(reviewer_family_value);
        IF coalesce(reviewer_run_text, '') = ''
           OR coalesce(reviewer_role_text, '') = ''
           OR coalesce(reviewer_family_text, '') = '' THEN
            RAISE EXCEPTION 'research artifact arguments are invalid'
                USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM research_assignment
            WHERE assignment_id = reviewer_assignment_id_value
        ) THEN
            RAISE EXCEPTION 'research reviewer assignment % is not registered',
                reviewer_assignment_id_value
                USING ERRCODE = '22023';
        END IF;
    END IF;
    IF jsonb_typeof(recipe_versions_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(lesson_versions_value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_momentum_spec_is_valid(spec_value) THEN
        RAISE EXCEPTION 'research artifact spec is outside the momentum_v1 contract'
            USING ERRCODE = '22023';
    END IF;
    IF incubator_json_claims_authority(spec_value)
       OR incubator_json_claims_authority(artifact_value)
       OR incubator_json_claims_authority(requested_route_value)
       OR incubator_json_claims_authority(actual_route_value) THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(artifact_value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'research artifact arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    -- S2: when both linkage fields are present, they must agree with the
    -- authoritative driver dispatch record (0088 dispatch_attempt.intent_id).
    -- A missing attempt row stays allowed here; the reproducibility gate
    -- reports it as indeterminate, never failed.
    intent_text := nullif(btrim(intent_id_value), '');
    attempt_text := nullif(btrim(attempt_id_value), '');
    IF intent_text IS NOT NULL AND attempt_text IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM dispatch_attempt d
            WHERE d.attempt_id = attempt_text
              AND d.intent_id IS DISTINCT FROM intent_text
        ) THEN
            RAISE EXCEPTION
                'research artifact intent % does not match authoritative intent for attempt %',
                intent_text, attempt_text
                USING ERRCODE = '22023';
        END IF;
    END IF;

    spec_digest_value := research_spec_digest(spec_value);
    artifact_digest_value := research_artifact_digest(artifact_value);

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96002));

    SELECT * INTO existing
    FROM research_artifact_manifest
    WHERE artifact_key = key_text;
    IF FOUND THEN
        -- S1: idempotency requires the FULL stored inputs to match, not
        -- just key+digests. Any divergence in run/routes/ancestry/author/
        -- refiner/reviewer/versions/dissent/intent/attempt/revision raises.
        IF existing.assignment_id IS DISTINCT FROM assignment_id_value
           OR existing.run_key IS DISTINCT FROM run_text
           OR existing.intent_id IS DISTINCT FROM intent_text
           OR existing.attempt_id IS DISTINCT FROM attempt_text
           OR existing.requested_route IS DISTINCT FROM requested_route_value
           OR existing.actual_route IS DISTINCT FROM actual_route_value
           OR existing.config_revision IS DISTINCT FROM config_revision_value
           OR existing.fallback_ancestry IS DISTINCT FROM fallback_ancestry_value
           OR existing.author_assignment_id IS DISTINCT FROM author_assignment_id_value
           OR existing.author_run_key IS DISTINCT FROM author_run_text
           OR existing.author_role IS DISTINCT FROM author_role_text
           OR existing.refiner_assignment_id IS DISTINCT FROM refiner_assignment_id_value
           OR existing.refiner_run_key IS DISTINCT FROM refiner_run_text
           OR existing.refiner_role IS DISTINCT FROM refiner_role_text
           OR existing.author_family IS DISTINCT FROM author_family_text
           OR existing.reviewer_assignment_id IS DISTINCT FROM reviewer_assignment_id_value
           OR existing.reviewer_run_key IS DISTINCT FROM reviewer_run_text
           OR existing.reviewer_role IS DISTINCT FROM reviewer_role_text
           OR existing.reviewer_family IS DISTINCT FROM reviewer_family_text
           OR existing.recipe_versions IS DISTINCT FROM recipe_versions_value
           OR existing.lesson_versions IS DISTINCT FROM lesson_versions_value
           OR existing.spec IS DISTINCT FROM spec_value
           OR existing.spec_digest IS DISTINCT FROM spec_digest_value
           OR existing.artifact IS DISTINCT FROM artifact_value
           OR existing.artifact_digest IS DISTINCT FROM artifact_digest_value
           OR existing.dissent_preserved IS DISTINCT FROM dissent_preserved_value THEN
            RAISE EXCEPTION
                'research artifact % is already recorded with different inputs',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        INSERT INTO research_artifact_manifest (
            artifact_key, assignment_id, run_key,
            intent_id, attempt_id,
            requested_route, actual_route, config_revision,
            fallback_ancestry,
            author_assignment_id, author_run_key, author_role,
            refiner_assignment_id, refiner_run_key, refiner_role,
            author_family,
            reviewer_assignment_id, reviewer_run_key,
            reviewer_role, reviewer_family,
            recipe_versions, lesson_versions,
            spec, spec_digest, artifact, artifact_digest,
            dissent_preserved,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, assignment_id_value, run_text,
            intent_text,
            attempt_text,
            requested_route_value, actual_route_value,
            config_revision_value,
            fallback_ancestry_value,
            author_assignment_id_value, author_run_text, author_role_text,
            refiner_assignment_id_value, refiner_run_text, refiner_role_text,
            author_family_text,
            reviewer_assignment_id_value, reviewer_run_text,
            reviewer_role_text, reviewer_family_text,
            recipe_versions_value, lesson_versions_value,
            spec_value, spec_digest_value,
            artifact_value, artifact_digest_value,
            dissent_preserved_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-artifact:' || created.artifact_id::text,
        'research.research_artifact_recorded',
        now(),
        jsonb_build_object(
            'artifact_id', created.artifact_id,
            'artifact_key', key_text,
            'assignment_id', assignment_id_value,
            'spec_digest', spec_digest_value,
            'artifact_digest', artifact_digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

-- Gate (a) contract validity: schema + pinned fields + momentum_v1 scope.
-- Returns 'valid' or 'invalid:<reason>'. Never asserts edge or profit.
CREATE FUNCTION research_contract_validity(artifact_id_value uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    manifest_row research_artifact_manifest%ROWTYPE;
    assignment_row research_assignment%ROWTYPE;
BEGIN
    SELECT * INTO manifest_row
    FROM research_artifact_manifest
    WHERE artifact_id = artifact_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research artifact % is not registered',
            artifact_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO assignment_row
    FROM research_assignment
    WHERE assignment_id = manifest_row.assignment_id;
    IF NOT FOUND
       OR NOT research_assignment_pins_valid(assignment_row.pins) THEN
        RETURN 'invalid:assignment_pins';
    END IF;
    IF NOT research_momentum_spec_is_valid(manifest_row.spec) THEN
        RETURN 'invalid:spec_schema';
    END IF;
    IF incubator_json_claims_authority(manifest_row.spec)
       OR incubator_json_claims_authority(manifest_row.artifact)
       OR incubator_json_claims_authority(manifest_row.requested_route)
       OR incubator_json_claims_authority(manifest_row.actual_route) THEN
        RETURN 'invalid:authority_claim';
    END IF;
    IF assignment_row.expires_at <= now() THEN
        RETURN 'invalid:assignment_expired';
    END IF;
    RETURN 'valid';
END;
$$;

-- Gate (b) reproducibility: replay pinned inputs to byte-identical digests
-- plus lineage closure. Uncertain dispatch outcomes stay indeterminate;
-- they are reconciled before redispatch, never failed by this gate.
CREATE FUNCTION research_reproducibility(artifact_id_value uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    manifest_row research_artifact_manifest%ROWTYPE;
    outcome_row dispatch_outcome%ROWTYPE;
    ancestry_elem jsonb;
BEGIN
    SELECT * INTO manifest_row
    FROM research_artifact_manifest
    WHERE artifact_id = artifact_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research artifact % is not registered',
            artifact_id_value
            USING ERRCODE = '22023';
    END IF;
    IF manifest_row.attempt_id IS NOT NULL THEN
        SELECT * INTO outcome_row
        FROM dispatch_outcome
        WHERE attempt_id = manifest_row.attempt_id;
        IF NOT FOUND THEN
            RETURN 'indeterminate:dispatch_outcome_unknown';
        END IF;
        IF outcome_row.state = 'indeterminate' THEN
            RETURN 'indeterminate:dispatch_indeterminate';
        END IF;
        IF outcome_row.state = 'cancelled' THEN
            RETURN 'diverged:dispatch_cancelled';
        END IF;
        IF outcome_row.state = 'failed' THEN
            RETURN 'diverged:dispatch_failed';
        END IF;
    END IF;
    IF research_artifact_digest(manifest_row.artifact)
        IS DISTINCT FROM manifest_row.artifact_digest THEN
        RETURN 'diverged:digest_mismatch';
    END IF;
    IF research_spec_digest(manifest_row.spec)
        IS DISTINCT FROM manifest_row.spec_digest THEN
        RETURN 'diverged:spec_digest_mismatch';
    END IF;
    FOR ancestry_elem IN
        SELECT * FROM jsonb_array_elements(manifest_row.fallback_ancestry)
    LOOP
        IF jsonb_typeof(ancestry_elem) IS DISTINCT FROM 'string'
           OR NOT EXISTS (
                SELECT 1 FROM dispatch_attempt d
                WHERE d.attempt_id = btrim(ancestry_elem #>> '{}')
           ) THEN
            RETURN 'diverged:lineage_open';
        END IF;
    END LOOP;
    RETURN 'reproduced';
END;
$$;

-- Gate (c) methodological readiness: separate-assignment critique passed with
-- dissent preserved. Same-family approval never counts as critique: it holds.
-- This is methodological critique only, not Economic Evaluation Family
-- independence, and never asserts edge or profit.
CREATE FUNCTION research_methodological_readiness(artifact_id_value uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    manifest_row research_artifact_manifest%ROWTYPE;
BEGIN
    SELECT * INTO manifest_row
    FROM research_artifact_manifest
    WHERE artifact_id = artifact_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research artifact % is not registered',
            artifact_id_value
            USING ERRCODE = '22023';
    END IF;
    IF manifest_row.reviewer_assignment_id IS NULL
       OR manifest_row.reviewer_run_key IS NULL THEN
        RETURN 'held:missing_critique';
    END IF;
    IF manifest_row.reviewer_assignment_id
        IS NOT DISTINCT FROM manifest_row.author_assignment_id
       OR btrim(manifest_row.reviewer_run_key)
        IS NOT DISTINCT FROM btrim(manifest_row.author_run_key) THEN
        RETURN 'held:same_assignment_or_run';
    END IF;
    IF lower(btrim(manifest_row.reviewer_role))
        IS NOT DISTINCT FROM lower(btrim(manifest_row.author_role)) THEN
        RETURN 'held:same_role';
    END IF;
    IF lower(btrim(manifest_row.reviewer_family))
        IS NOT DISTINCT FROM lower(btrim(manifest_row.author_family)) THEN
        RETURN 'held:same_family';
    END IF;
    IF manifest_row.dissent_preserved IS DISTINCT FROM true THEN
        RETURN 'held:dissent_not_preserved';
    END IF;
    RETURN 'ready';
END;
$$;

REVOKE ALL ON FUNCTION research_posture_profile_is_canonical(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_assignment_pins_valid(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_momentum_spec_is_valid(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_spec_digest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_artifact_digest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_ancestry_is_wellformed(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION admit_research_assignment(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_research_artifact_manifest(
    text, uuid, text, text, text, jsonb, jsonb, bigint, jsonb,
    uuid, text, text, uuid, text, text, text,
    uuid, text, text, text, jsonb, jsonb, jsonb, jsonb,
    boolean, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_contract_validity(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_reproducibility(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_methodological_readiness(uuid) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_assignment FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_artifact_manifest FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
