-- PR2 Institutional Memory admission + containment (wayfinder map #171,
-- decision #173, rollout #176).
--
-- Versioned, queryable durable lessons with full lineage, lineage-disjoint
-- support, typed scope + expiry, versioned dissent, duplicate linkage, and
-- sticky containment (suspend / supersede / expire / contaminate). Memory
-- admits methods guidance only: recipe, acceptance-check, and authority
-- semantics can never be promoted through admission and are rejected at the
-- boundary by a keyword gate (the text analogue of
-- incubator_json_claims_authority plus recipe/acceptance keywords).
--
-- Additive only. Applied migration bytes stay immutable. No model, cost,
-- Paper, or Live authority change: this migration touches no capacity,
-- route-tier, or execution tables, grants no worker roles, and starts no
-- services. Ships dark: every new function is revoked from PUBLIC and no
-- worker-role GRANT is issued. Retrieval is a read path for later recipe
-- integration (PR3); no worker calls it yet.
--
-- Guard pattern note: research_lesson carries a status lifecycle, so the
-- verbatim append-only statement guard cannot apply to its UPDATEs. Inserts
-- reuse guard_incubator_insert unchanged. UPDATE/DELETE/TRUNCATE go through
-- guard_research_lesson_write (statement level: workflow flag must be armed
-- by one of the transition functions below) plus
-- guard_research_lesson_transition (row level: only status,
-- successor_lesson_key, and admitted_at may change, and only along the legal
-- edges in research_lesson_transition_is_legal). research_lesson_status_event
-- is history and uses the verbatim append-only + insert guards, so history
-- is never rewritten.
--
-- Compatibility: depends on 0096 (research_assignment,
-- research_artifact_manifest, posture/profile validators). Rollback is a new
-- migration; this file has no DOWN. Numbering: this branch heads at 0096 on
-- origin/main 3455b07, so the memory migration lands here as 0097. Rename on
-- rebase if later migrations merge first; the migrator requires contiguity.

-- UUID-or-blank shape check used by the lineage validators below. Blank
-- (whitespace-only, matching the SQL NULLIF(btrim,'') convention) is false;
-- anything else must cast to uuid, else false.
CREATE FUNCTION research_lesson_uuid_is_wellformed(value text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(btrim(value), '') = '' THEN
        RETURN false;
    END IF;
    PERFORM (NULLIF(btrim(value), ''))::uuid;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- Decision #173.1: full lineage required. Shape only (no table access, so
-- this stays IMMUTABLE and CHECK-safe); the propose/admit functions verify
-- existence against the authoritative rows with intent-style linkage checks.
-- Exactly the twelve lineage keys: proposing + critiquing assignment/run,
-- actual provider/session/model + config revision, recipe/contract versions,
-- canonical source artifact IDs, declared shared dependencies.
CREATE FUNCTION research_lesson_provenance_is_complete(node jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'proposing_assignment_id', 'proposing_run_key',
        'critiquing_assignment_id', 'critiquing_run_key',
        'provider_id', 'provider_session', 'model_id', 'config_revision',
        'recipe_version', 'contract_runner',
        'source_artifact_ids', 'shared_dependencies'
    ];
    elem jsonb;
    revision_value bigint;
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(node)) <> 12 THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_object_keys(node) k
        WHERE k <> ALL (allowed)
    ) THEN
        RETURN false;
    END IF;
    IF NOT research_lesson_uuid_is_wellformed(
            node->>'proposing_assignment_id') THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(node->>'proposing_run_key'), '') = '' THEN
        RETURN false;
    END IF;
    IF NOT research_lesson_uuid_is_wellformed(
            node->>'critiquing_assignment_id') THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(node->>'critiquing_run_key'), '') = '' THEN
        RETURN false;
    END IF;
    -- Separate critique: different assignment AND different run.
    IF lower(btrim(node->>'critiquing_assignment_id'))
        IS NOT DISTINCT FROM
       lower(btrim(node->>'proposing_assignment_id')) THEN
        RETURN false;
    END IF;
    IF btrim(node->>'critiquing_run_key')
        IS NOT DISTINCT FROM btrim(node->>'proposing_run_key') THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(node->>'provider_id'), '') = '' THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(node->>'provider_session'), '') = '' THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(node->>'model_id'), '') = '' THEN
        RETURN false;
    END IF;
    revision_value := strategy_sandbox_integer(node->'config_revision');
    IF revision_value IS NULL OR revision_value < 0 THEN
        RETURN false;
    END IF;
    IF coalesce(btrim(node->>'recipe_version'), '') = '' THEN
        RETURN false;
    END IF;
    -- Bounded release: lessons cover the existing momentum_v1 workflow only.
    IF btrim(node->>'contract_runner') IS DISTINCT FROM 'momentum_v1' THEN
        RETURN false;
    END IF;
    -- Canonical source artifacts: non-empty array of UUID-shaped IDs.
    -- Existence is verified by the admission functions.
    IF jsonb_typeof(node->'source_artifact_ids') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    IF (SELECT count(*)
        FROM jsonb_array_elements(node->'source_artifact_ids')) < 1 THEN
        RETURN false;
    END IF;
    FOR elem IN
        SELECT * FROM jsonb_array_elements(node->'source_artifact_ids')
    LOOP
        IF jsonb_typeof(elem) IS DISTINCT FROM 'string'
           OR NOT research_lesson_uuid_is_wellformed(elem #>> '{}') THEN
            RETURN false;
        END IF;
    END LOOP;
    -- Declared shared dependencies: array, possibly empty, of non-blank
    -- opaque strings.
    IF jsonb_typeof(node->'shared_dependencies') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    FOR elem IN
        SELECT * FROM jsonb_array_elements(node->'shared_dependencies')
    LOOP
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

-- Decision #173.2: support attestations are wellformed when the value is a
-- non-empty array of exactly {assignment_id, run_key, provider_session,
-- model_id} objects (deny-unknown-fields parity with the Rust types).
CREATE FUNCTION research_lesson_support_is_wellformed(node jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'assignment_id', 'run_key', 'provider_session', 'model_id'
    ];
    elem jsonb;
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(node)) < 1 THEN
        RETURN false;
    END IF;
    FOR elem IN SELECT * FROM jsonb_array_elements(node) LOOP
        IF jsonb_typeof(elem) IS DISTINCT FROM 'object' THEN
            RETURN false;
        END IF;
        IF (SELECT count(*) FROM jsonb_object_keys(elem)) <> 4 THEN
            RETURN false;
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_object_keys(elem) k
            WHERE k <> ALL (allowed)
        ) THEN
            RETURN false;
        END IF;
        IF NOT research_lesson_uuid_is_wellformed(elem->>'assignment_id') THEN
            RETURN false;
        END IF;
        IF coalesce(btrim(elem->>'run_key'), '') = '' THEN
            RETURN false;
        END IF;
        IF coalesce(btrim(elem->>'provider_session'), '') = '' THEN
            RETURN false;
        END IF;
        IF coalesce(btrim(elem->>'model_id'), '') = '' THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- Decision #173.2: support counts only with disjoint lineages. Every
-- attestation must differ from the proposing and critiquing lineage on all
-- four coordinates (assignment, run, provider session, model), and every
-- pair of attestations must differ on all four. Model agreement, repeats,
-- and self-review collapse here: identical attestations share every
-- coordinate, so exact repeats fail the pairwise leg.
CREATE FUNCTION research_lesson_support_is_disjoint(
    provenance_value jsonb,
    support_value jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    support_count integer;
    first_index integer;
    second_index integer;
    first_elem jsonb;
    second_elem jsonb;
    proposing_assignment text :=
        lower(btrim(provenance_value->>'proposing_assignment_id'));
    proposing_run text := btrim(provenance_value->>'proposing_run_key');
    critiquing_assignment text :=
        lower(btrim(provenance_value->>'critiquing_assignment_id'));
    critiquing_run text := btrim(provenance_value->>'critiquing_run_key');
    proposing_session text := btrim(provenance_value->>'provider_session');
    proposing_model text := btrim(provenance_value->>'model_id');
BEGIN
    IF NOT research_lesson_provenance_is_complete(provenance_value) THEN
        RETURN false;
    END IF;
    IF NOT research_lesson_support_is_wellformed(support_value) THEN
        RETURN false;
    END IF;
    support_count := jsonb_array_length(support_value);
    FOR first_index IN 0..support_count - 1 LOOP
        first_elem := support_value->first_index;
        -- Evaluator never reviews its own lineage: disjoint from both the
        -- proposing and the critiquing coordinates.
        IF lower(btrim(first_elem->>'assignment_id'))
            IN (proposing_assignment, critiquing_assignment) THEN
            RETURN false;
        END IF;
        IF btrim(first_elem->>'run_key') IN (proposing_run, critiquing_run) THEN
            RETURN false;
        END IF;
        IF btrim(first_elem->>'provider_session')
            IS NOT DISTINCT FROM proposing_session THEN
            RETURN false;
        END IF;
        IF btrim(first_elem->>'model_id')
            IS NOT DISTINCT FROM proposing_model THEN
            RETURN false;
        END IF;
        FOR second_index IN first_index + 1..support_count - 1 LOOP
            second_elem := support_value->second_index;
            IF lower(btrim(first_elem->>'assignment_id'))
                IS NOT DISTINCT FROM
               lower(btrim(second_elem->>'assignment_id')) THEN
                RETURN false;
            END IF;
            IF btrim(first_elem->>'run_key')
                IS NOT DISTINCT FROM btrim(second_elem->>'run_key') THEN
                RETURN false;
            END IF;
            IF btrim(first_elem->>'provider_session')
                IS NOT DISTINCT FROM
               btrim(second_elem->>'provider_session') THEN
                RETURN false;
            END IF;
            IF btrim(first_elem->>'model_id')
                IS NOT DISTINCT FROM btrim(second_elem->>'model_id') THEN
                RETURN false;
            END IF;
        END LOOP;
    END LOOP;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- Decision #173.3: typed scope. global carries an empty object;
-- role_posture carries exactly {desk_role, posture_profile} drawn from the
-- canonical 0096 sets; method_data carries exactly {contract_runner,
-- recipe_version} so retrieval can filter against assignment pins.
CREATE FUNCTION research_lesson_scope_is_valid(
    scope_type_value text,
    scope_key_value jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    scope_stored text := lower(btrim(scope_type_value));
BEGIN
    IF jsonb_typeof(scope_key_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF scope_stored = 'global' THEN
        RETURN (SELECT count(*)
                FROM jsonb_object_keys(scope_key_value)) = 0;
    ELSIF scope_stored = 'role_posture' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(scope_key_value)) <> 2 THEN
            RETURN false;
        END IF;
        IF NOT (scope_key_value ?& ARRAY['desk_role', 'posture_profile']) THEN
            RETURN false;
        END IF;
        IF incubator_charter_role_is_forbidden(
                btrim(scope_key_value->>'desk_role')) THEN
            RETURN false;
        END IF;
        IF NOT incubator_desk_role_is_allowed(
                btrim(scope_key_value->>'desk_role')) THEN
            RETURN false;
        END IF;
        IF NOT research_posture_profile_is_canonical(
                scope_key_value->>'posture_profile') THEN
            RETURN false;
        END IF;
        RETURN true;
    ELSIF scope_stored = 'method_data' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(scope_key_value)) <> 2 THEN
            RETURN false;
        END IF;
        IF NOT (scope_key_value
                ?& ARRAY['contract_runner', 'recipe_version']) THEN
            RETURN false;
        END IF;
        IF btrim(scope_key_value->>'contract_runner')
            IS DISTINCT FROM 'momentum_v1' THEN
            RETURN false;
        END IF;
        IF coalesce(btrim(scope_key_value->>'recipe_version'), '') = '' THEN
            RETURN false;
        END IF;
        RETURN true;
    ELSE
        RETURN false;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- Decision #173.4: dissent stays versioned on the lesson. Exactly
-- {version, entries}; version is an integer >= 1; entries is an array
-- (possibly empty) of exactly {assignment_id, run_key, note} with all three
-- non-blank. Existence of the dissenting assignments is verified by the
-- admission functions.
CREATE FUNCTION research_lesson_dissent_is_wellformed(node jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    elem jsonb;
    version_value bigint;
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(node)) <> 2 THEN
        RETURN false;
    END IF;
    IF NOT (node ?& ARRAY['version', 'entries']) THEN
        RETURN false;
    END IF;
    version_value := strategy_sandbox_integer(node->'version');
    IF version_value IS NULL OR version_value < 1 THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'entries') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    FOR elem IN SELECT * FROM jsonb_array_elements(node->'entries') LOOP
        IF jsonb_typeof(elem) IS DISTINCT FROM 'object' THEN
            RETURN false;
        END IF;
        IF (SELECT count(*) FROM jsonb_object_keys(elem)) <> 3 THEN
            RETURN false;
        END IF;
        IF NOT (elem ?& ARRAY['assignment_id', 'run_key', 'note']) THEN
            RETURN false;
        END IF;
        IF NOT research_lesson_uuid_is_wellformed(elem->>'assignment_id') THEN
            RETURN false;
        END IF;
        IF coalesce(btrim(elem->>'run_key'), '') = '' THEN
            RETURN false;
        END IF;
        IF coalesce(btrim(elem->>'note'), '') = '' THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- Decision #173.6: admission boundary. Memory admits methods guidance only.
-- The text analogue of the AUTHORITY_KEYS deny list in research_contract.rs
-- (0043 authority keys) plus recipe/acceptance keywords. Word-boundary
-- matching (\y treats underscore as a word character) so "deliver" does not
-- trip on "live", while "live trading" and "paper eligible" are rejected.
CREATE FUNCTION research_lesson_guidance_is_admissible(guidance_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(btrim(guidance_value), '') <> ''
       AND NOT (btrim(guidance_value) ~*
            '\y(authority|lifecycle_state|execution_environment|execution_authority|strategy_eligible|paper_eligible|trade_eligible|paper|live|broker|execution_edge_and_paper_trading|recipe|acceptance)\y');
$$;

-- Decision #173.5: legal status edges. Containment is sticky: suspended,
-- expired, and contaminated are terminal, and superseded resolves forward
-- only. There is no re-admission edge; recovery is a new lesson.
CREATE FUNCTION research_lesson_transition_is_legal(
    from_value text,
    to_value text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE btrim(from_value)
        WHEN 'proposed' THEN
            btrim(to_value) IN (
                'admitted', 'suspended', 'contaminated', 'expired')
        WHEN 'admitted' THEN
            btrim(to_value) IN (
                'suspended', 'superseded', 'contaminated', 'expired')
        WHEN 'suspended' THEN
            btrim(to_value) IN ('contaminated', 'expired')
        ELSE false
    END;
$$;

CREATE TABLE research_lesson (
    lesson_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lesson_key text NOT NULL CHECK (btrim(lesson_key) <> ''),
    scope_type text NOT NULL,
    scope_key jsonb NOT NULL CHECK (jsonb_typeof(scope_key) = 'object'),
    guidance text NOT NULL CHECK (btrim(guidance) <> ''),
    provenance jsonb NOT NULL CHECK (jsonb_typeof(provenance) = 'object'),
    support jsonb NOT NULL CHECK (jsonb_typeof(support) = 'array'),
    dissent jsonb NOT NULL CHECK (jsonb_typeof(dissent) = 'object'),
    status text NOT NULL DEFAULT 'proposed'
        CHECK (btrim(status) IN (
            'proposed', 'admitted', 'suspended',
            'superseded', 'expired', 'contaminated')),
    successor_lesson_key text,
    canonical_lesson_key text,
    admitted_at timestamptz,
    expires_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (research_lesson_scope_is_valid(scope_type, scope_key)),
    CHECK (research_lesson_provenance_is_complete(provenance)),
    CHECK (research_lesson_support_is_wellformed(support)),
    CHECK (research_lesson_support_is_disjoint(provenance, support)),
    CHECK (research_lesson_dissent_is_wellformed(dissent)),
    CHECK (research_lesson_guidance_is_admissible(guidance)),
    CHECK (NOT incubator_json_claims_authority(provenance)),
    CHECK (NOT incubator_json_claims_authority(support)),
    CHECK (NOT incubator_json_claims_authority(scope_key)),
    CHECK (NOT incubator_json_claims_authority(dissent)),
    CHECK (successor_lesson_key IS NULL
        OR btrim(successor_lesson_key) <> ''),
    CHECK (canonical_lesson_key IS NULL
        OR btrim(canonical_lesson_key) <> ''),
    CHECK (canonical_lesson_key IS DISTINCT FROM lesson_key),
    CHECK (status <> 'superseded' OR successor_lesson_key IS NOT NULL),
    CHECK (status = 'superseded' OR successor_lesson_key IS NULL),
    CHECK ((status = 'proposed') = (admitted_at IS NULL)),
    CHECK (record_environment = 'local_research'),
    FOREIGN KEY (successor_lesson_key)
        REFERENCES research_lesson(lesson_key),
    FOREIGN KEY (canonical_lesson_key)
        REFERENCES research_lesson(lesson_key),
    UNIQUE (lesson_key)
);

SELECT register_evidence_table('research_lesson');

-- Decision #173.5: every transition is recorded; history is never rewritten.
-- from_status is NULL only for the genesis propose event.
CREATE TABLE research_lesson_status_event (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lesson_key text NOT NULL REFERENCES research_lesson(lesson_key),
    from_status text
        CHECK (from_status IS NULL OR btrim(from_status) IN (
            'proposed', 'admitted', 'suspended',
            'superseded', 'expired', 'contaminated')),
    to_status text NOT NULL
        CHECK (btrim(to_status) IN (
            'proposed', 'admitted', 'suspended',
            'superseded', 'expired', 'contaminated')),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    actor_assignment_id uuid NOT NULL
        REFERENCES research_assignment(assignment_id),
    actor_run_key text NOT NULL CHECK (btrim(actor_run_key) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (from_status IS DISTINCT FROM to_status),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('research_lesson_status_event');

CREATE INDEX research_lesson_status_expires_idx
    ON research_lesson (status, expires_at);

-- Statement-level gate for lesson UPDATE/DELETE/TRUNCATE: only the workflow
-- functions below (which arm the incubator flag) may transition a lesson.
-- Inserts reuse the existing guard_incubator_insert unchanged.
CREATE FUNCTION guard_research_lesson_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF current_setting('market_mate.incubator_write', true)
        IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION '% is append-only; % is forbidden',
            TG_TABLE_NAME, TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NULL;
END;
$$;

-- Row-level transition discipline: lifecycle columns only, legal edges only,
-- linkage coherence on every write, admitted_at pinned after admission.
CREATE FUNCTION guard_research_lesson_transition() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NEW.lesson_id IS DISTINCT FROM OLD.lesson_id
       OR NEW.lesson_key IS DISTINCT FROM OLD.lesson_key
       OR NEW.scope_type IS DISTINCT FROM OLD.scope_type
       OR NEW.scope_key IS DISTINCT FROM OLD.scope_key
       OR NEW.guidance IS DISTINCT FROM OLD.guidance
       OR NEW.provenance IS DISTINCT FROM OLD.provenance
       OR NEW.support IS DISTINCT FROM OLD.support
       OR NEW.dissent IS DISTINCT FROM OLD.dissent
       OR NEW.canonical_lesson_key IS DISTINCT FROM OLD.canonical_lesson_key
       OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
       OR NEW.source_lineage IS DISTINCT FROM OLD.source_lineage
       OR NEW.receipt_time IS DISTINCT FROM OLD.receipt_time
       OR NEW.record_environment IS DISTINCT FROM OLD.record_environment THEN
        RAISE EXCEPTION
            'research_lesson history is immutable; only status transitions are allowed'
            USING ERRCODE = '55000';
    END IF;
    IF NOT research_lesson_transition_is_legal(OLD.status, NEW.status) THEN
        RAISE EXCEPTION
            'research_lesson transition % -> % is not a legal lifecycle move',
            OLD.status, NEW.status
            USING ERRCODE = '55000';
    END IF;
    IF NEW.status = 'superseded'
       AND NEW.successor_lesson_key IS NULL THEN
        RAISE EXCEPTION
            'research_lesson supersession requires a successor'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.status <> 'superseded'
       AND NEW.successor_lesson_key IS NOT NULL THEN
        RAISE EXCEPTION
            'research_lesson successor is only set on supersession'
            USING ERRCODE = '55000';
    END IF;
    IF OLD.status = 'proposed' AND NEW.status = 'admitted'
       AND NEW.admitted_at IS NULL THEN
        RAISE EXCEPTION
            'research_lesson admission requires admitted_at'
            USING ERRCODE = '55000';
    END IF;
    IF OLD.admitted_at IS NOT NULL
       AND NEW.admitted_at IS DISTINCT FROM OLD.admitted_at THEN
        RAISE EXCEPTION
            'research_lesson admitted_at is pinned after admission'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_lesson_write_guard
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_lesson
    FOR EACH STATEMENT EXECUTE FUNCTION guard_research_lesson_write();

CREATE TRIGGER research_lesson_transition_guard
    BEFORE UPDATE ON research_lesson
    FOR EACH ROW EXECUTE FUNCTION guard_research_lesson_transition();

CREATE TRIGGER research_lesson_insert_guard
    BEFORE INSERT ON research_lesson
    FOR EACH ROW EXECUTE FUNCTION guard_incubator_insert();

CREATE TRIGGER research_lesson_status_event_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_lesson_status_event
    FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();

CREATE TRIGGER research_lesson_status_event_insert_guard
    BEFORE INSERT ON research_lesson_status_event
    FOR EACH ROW EXECUTE FUNCTION guard_incubator_insert();

-- Propose a lesson: full static validation, authoritative existence linkage,
-- canonicalization (trim/case) so idempotency compares do not depend on
-- cosmetic rendering, then insert plus the genesis status event. Re-proposal
-- with identical full inputs returns the existing row; any divergence raises.
CREATE FUNCTION propose_research_lesson(
    lesson_key_value text,
    scope_type_value text,
    scope_key_value jsonb,
    guidance_value text,
    provenance_value jsonb,
    support_value jsonb,
    dissent_value jsonb,
    expires_at_value timestamptz,
    canonical_lesson_key_value text,
    source_lineage_value jsonb
) RETURNS research_lesson
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    existing research_lesson%ROWTYPE;
    created research_lesson%ROWTYPE;
    canonical_row research_lesson%ROWTYPE;
    key_text text;
    scope_stored text;
    scope_key_stored jsonb;
    guidance_stored text;
    provenance_stored jsonb;
    support_stored jsonb;
    dissent_stored jsonb;
    canonical_stored text;
    source_ids jsonb;
    shared_deps jsonb;
    dissent_entries jsonb;
    elem jsonb;
    elem_ord integer;
    support_assignment uuid;
    dissent_assignment uuid;
    source_artifact uuid;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research lesson arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(lesson_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson key is required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_scope_is_valid(
            scope_type_value, scope_key_value) THEN
        RAISE EXCEPTION 'research lesson scope is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_guidance_is_admissible(guidance_value) THEN
        RAISE EXCEPTION
            'research lesson guidance touches recipe, acceptance-check, or authority semantics'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_provenance_is_complete(provenance_value) THEN
        RAISE EXCEPTION 'research lesson provenance is incomplete'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_support_is_wellformed(support_value) THEN
        RAISE EXCEPTION 'research lesson support is not wellformed'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_support_is_disjoint(
            provenance_value, support_value) THEN
        RAISE EXCEPTION 'research lesson support is not lineage-disjoint'
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_dissent_is_wellformed(dissent_value) THEN
        RAISE EXCEPTION 'research lesson dissent is not wellformed'
            USING ERRCODE = '22023';
    END IF;
    IF expires_at_value IS NULL
       OR expires_at_value <= clock_timestamp() THEN
        RAISE EXCEPTION 'research lesson expiry must be in the future'
            USING ERRCODE = '22023';
    END IF;
    canonical_stored :=
        NULLIF(btrim(canonical_lesson_key_value), '');

    -- Canonical stored forms: trim/case folded so identical lessons compare
    -- equal regardless of cosmetic rendering.
    scope_stored := lower(btrim(scope_type_value));
    IF scope_stored = 'global' THEN
        scope_key_stored := '{}'::jsonb;
    ELSIF scope_stored = 'role_posture' THEN
        scope_key_stored := jsonb_build_object(
            'desk_role', lower(btrim(scope_key_value->>'desk_role')),
            'posture_profile', btrim(scope_key_value->>'posture_profile'));
    ELSE
        scope_key_stored := jsonb_build_object(
            'contract_runner', 'momentum_v1',
            'recipe_version', btrim(scope_key_value->>'recipe_version'));
    END IF;
    guidance_stored := btrim(guidance_value);

    SELECT coalesce(jsonb_agg(
                lower(btrim(arr_elem #>> '{}')) ORDER BY arr_ord),
            '[]'::jsonb)
    INTO source_ids
    FROM jsonb_array_elements(provenance_value->'source_artifact_ids')
        WITH ORDINALITY AS t(arr_elem, arr_ord);
    SELECT coalesce(jsonb_agg(
                btrim(arr_elem #>> '{}') ORDER BY arr_ord),
            '[]'::jsonb)
    INTO shared_deps
    FROM jsonb_array_elements(provenance_value->'shared_dependencies')
        WITH ORDINALITY AS t(arr_elem, arr_ord);
    provenance_stored := jsonb_build_object(
        'proposing_assignment_id',
            lower(btrim(provenance_value->>'proposing_assignment_id')),
        'proposing_run_key', btrim(provenance_value->>'proposing_run_key'),
        'critiquing_assignment_id',
            lower(btrim(provenance_value->>'critiquing_assignment_id')),
        'critiquing_run_key', btrim(provenance_value->>'critiquing_run_key'),
        'provider_id', btrim(provenance_value->>'provider_id'),
        'provider_session', btrim(provenance_value->>'provider_session'),
        'model_id', btrim(provenance_value->>'model_id'),
        'config_revision',
            strategy_sandbox_integer(provenance_value->'config_revision'),
        'recipe_version', btrim(provenance_value->>'recipe_version'),
        'contract_runner', 'momentum_v1',
        'source_artifact_ids', source_ids,
        'shared_dependencies', shared_deps);

    SELECT coalesce(jsonb_agg(
                jsonb_build_object(
                    'assignment_id',
                        lower(btrim(arr_elem->>'assignment_id')),
                    'run_key', btrim(arr_elem->>'run_key'),
                    'provider_session',
                        btrim(arr_elem->>'provider_session'),
                    'model_id', btrim(arr_elem->>'model_id'))
                ORDER BY arr_ord),
            '[]'::jsonb)
    INTO support_stored
    FROM jsonb_array_elements(support_value)
        WITH ORDINALITY AS t(arr_elem, arr_ord);

    SELECT coalesce(jsonb_agg(
                jsonb_build_object(
                    'assignment_id',
                        lower(btrim(arr_elem->>'assignment_id')),
                    'run_key', btrim(arr_elem->>'run_key'),
                    'note', btrim(arr_elem->>'note'))
                ORDER BY arr_ord),
            '[]'::jsonb)
    INTO dissent_entries
    FROM jsonb_array_elements(dissent_value->'entries')
        WITH ORDINALITY AS t(arr_elem, arr_ord);
    dissent_stored := jsonb_build_object(
        'version', strategy_sandbox_integer(dissent_value->'version'),
        'entries', dissent_entries);

    IF incubator_json_claims_authority(provenance_stored)
       OR incubator_json_claims_authority(support_stored)
       OR incubator_json_claims_authority(scope_key_stored)
       OR incubator_json_claims_authority(dissent_stored) THEN
        RAISE EXCEPTION 'research lesson inputs claim authority'
            USING ERRCODE = '22023';
    END IF;

    -- Authoritative existence linkage (verify-style, like the 0096
    -- intent/attempt check): every referenced assignment and artifact must be
    -- registered.
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id =
            (provenance_stored->>'proposing_assignment_id')::uuid
    ) THEN
        RAISE EXCEPTION
            'research lesson proposing assignment % is not registered',
            provenance_stored->>'proposing_assignment_id'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id =
            (provenance_stored->>'critiquing_assignment_id')::uuid
    ) THEN
        RAISE EXCEPTION
            'research lesson critiquing assignment % is not registered',
            provenance_stored->>'critiquing_assignment_id'
            USING ERRCODE = '22023';
    END IF;
    FOR elem IN SELECT * FROM jsonb_array_elements(support_stored) LOOP
        support_assignment := (NULLIF(btrim(elem->>'assignment_id'), ''))::uuid;
        IF NOT EXISTS (
            SELECT 1 FROM research_assignment
            WHERE assignment_id = support_assignment
        ) THEN
            RAISE EXCEPTION
                'research lesson support assignment % is not registered',
                elem->>'assignment_id'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
    FOR elem IN SELECT * FROM jsonb_array_elements(dissent_entries) LOOP
        dissent_assignment := (NULLIF(btrim(elem->>'assignment_id'), ''))::uuid;
        IF NOT EXISTS (
            SELECT 1 FROM research_assignment
            WHERE assignment_id = dissent_assignment
        ) THEN
            RAISE EXCEPTION
                'research lesson dissent assignment % is not registered',
                elem->>'assignment_id'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
    FOR elem IN SELECT * FROM jsonb_array_elements(source_ids) LOOP
        source_artifact := (NULLIF(btrim(elem #>> '{}'), ''))::uuid;
        IF NOT EXISTS (
            SELECT 1 FROM research_artifact_manifest
            WHERE artifact_id = source_artifact
        ) THEN
            RAISE EXCEPTION
                'research lesson source artifact % is not registered',
                elem #>> '{}'
                USING ERRCODE = '22023';
        END IF;
        -- Evaluator never reviews its own lineage, closed against the
        -- authoritative manifests: no supporter may be the author, reviewer,
        -- or refiner of any canonical source artifact.
        IF EXISTS (
            SELECT 1
            FROM research_artifact_manifest manifest_row,
                 jsonb_array_elements(support_stored) support_elem
            WHERE manifest_row.artifact_id = source_artifact
              AND (manifest_row.author_assignment_id =
                       (NULLIF(btrim(
                            support_elem->>'assignment_id'), ''))::uuid
                   OR manifest_row.reviewer_assignment_id =
                       (NULLIF(btrim(
                            support_elem->>'assignment_id'), ''))::uuid
                   OR manifest_row.refiner_assignment_id =
                       (NULLIF(btrim(
                            support_elem->>'assignment_id'), ''))::uuid)
        ) THEN
            RAISE EXCEPTION
                'research lesson support reviews its own lineage'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    -- Duplicates link to the canonical lesson and never manufacture
    -- corroboration: the canonical lesson must exist, must itself be
    -- canonical (no chains), and the duplicate must not reuse any of the
    -- canonical lesson's supporting assignments as separate support.
    IF canonical_stored IS NOT NULL THEN
        SELECT * INTO canonical_row
        FROM research_lesson
        WHERE lesson_key = canonical_stored;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'research lesson canonical lesson % is not registered',
                canonical_stored
                USING ERRCODE = '22023';
        END IF;
        IF canonical_row.canonical_lesson_key IS NOT NULL THEN
            RAISE EXCEPTION
                'research lesson canonical lesson % is itself a duplicate',
                canonical_stored
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(support_stored) support_elem,
                 jsonb_array_elements(canonical_row.support) canonical_elem
            WHERE lower(btrim(support_elem->>'assignment_id'))
                IS NOT DISTINCT FROM
                  lower(btrim(canonical_elem->>'assignment_id'))
        ) THEN
            RAISE EXCEPTION
                'research lesson duplicate support reuses canonical lesson support'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96003));

    SELECT * INTO existing
    FROM research_lesson
    WHERE lesson_key = key_text;
    IF FOUND THEN
        -- Full-input idempotency: the whole stored inputs must match, not
        -- just the key.
        IF existing.scope_type IS DISTINCT FROM scope_stored
           OR existing.scope_key IS DISTINCT FROM scope_key_stored
           OR existing.guidance IS DISTINCT FROM guidance_stored
           OR existing.provenance IS DISTINCT FROM provenance_stored
           OR existing.support IS DISTINCT FROM support_stored
           OR existing.dissent IS DISTINCT FROM dissent_stored
           OR existing.expires_at IS DISTINCT FROM expires_at_value
           OR existing.canonical_lesson_key IS DISTINCT FROM canonical_stored THEN
            RAISE EXCEPTION
                'research lesson % is already proposed with different inputs',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        INSERT INTO research_lesson (
            lesson_key, scope_type, scope_key, guidance,
            provenance, support, dissent,
            status, successor_lesson_key, canonical_lesson_key,
            admitted_at, expires_at,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, scope_stored, scope_key_stored, guidance_stored,
            provenance_stored, support_stored, dissent_stored,
            'proposed', NULL, canonical_stored,
            NULL, expires_at_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;

        INSERT INTO research_lesson_status_event (
            lesson_key, from_status, to_status, reason,
            actor_assignment_id, actor_run_key,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, NULL, 'proposed', 'lesson_proposed',
            (provenance_stored->>'proposing_assignment_id')::uuid,
            btrim(provenance_stored->>'proposing_run_key'),
            source_lineage_value, clock_timestamp(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-lesson:' || created.lesson_id::text || ':proposed',
        'research.research_lesson_proposed',
        now(),
        jsonb_build_object(
            'lesson_id', created.lesson_id,
            'lesson_key', key_text,
            'scope_type', scope_stored,
            'status', 'proposed',
            -- Canonical UTC instant so audit JSON does not depend on the
            -- session TimeZone.
            'expires_at', to_char(
                expires_at_value AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

-- Admit a proposed lesson: the lesson must be proposed (already admitted is
-- idempotent; any other status raises), and every admission check is
-- re-validated against the stored row, including expiry at admit time.
CREATE FUNCTION admit_research_lesson(
    lesson_key_value text,
    actor_assignment_id_value uuid,
    actor_run_key_value text,
    source_lineage_value jsonb
) RETURNS research_lesson
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    lesson_row research_lesson%ROWTYPE;
    key_text text;
    actor_run_text text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research lesson arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(lesson_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson key is required'
            USING ERRCODE = '22023';
    END IF;
    actor_run_text := btrim(actor_run_key_value);
    IF actor_assignment_id_value IS NULL
       OR coalesce(actor_run_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson actor assignment and run are required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = actor_assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research lesson actor assignment % is not registered',
            actor_assignment_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96003));

    SELECT * INTO lesson_row
    FROM research_lesson
    WHERE lesson_key = key_text;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research lesson % is not registered',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lesson_row.status = 'admitted' THEN
        RETURN lesson_row;
    END IF;
    IF lesson_row.status <> 'proposed' THEN
        RAISE EXCEPTION
            'research lesson % cannot transition from % to admitted',
            key_text, lesson_row.status
            USING ERRCODE = '55000';
    END IF;

    IF NOT research_lesson_provenance_is_complete(lesson_row.provenance) THEN
        RAISE EXCEPTION
            'research lesson % failed admission: incomplete provenance',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_support_is_disjoint(
            lesson_row.provenance, lesson_row.support) THEN
        RAISE EXCEPTION
            'research lesson % failed admission: support is not lineage-disjoint',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_scope_is_valid(
            lesson_row.scope_type, lesson_row.scope_key) THEN
        RAISE EXCEPTION
            'research lesson % failed admission: invalid scope',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_dissent_is_wellformed(lesson_row.dissent) THEN
        RAISE EXCEPTION
            'research lesson % failed admission: dissent is not wellformed',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF NOT research_lesson_guidance_is_admissible(lesson_row.guidance) THEN
        RAISE EXCEPTION
            'research lesson % failed admission: guidance touches recipe, acceptance-check, or authority semantics',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lesson_row.expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'research lesson % expired before admission',
            key_text
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        UPDATE research_lesson
        SET status = 'admitted',
            admitted_at = clock_timestamp()
        WHERE lesson_key = key_text
        RETURNING * INTO lesson_row;

        INSERT INTO research_lesson_status_event (
            lesson_key, from_status, to_status, reason,
            actor_assignment_id, actor_run_key,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, 'proposed', 'admitted', 'admission_checks_passed',
            actor_assignment_id_value, actor_run_text,
            source_lineage_value, clock_timestamp(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-lesson:' || lesson_row.lesson_id::text || ':admitted',
        'research.research_lesson_admitted',
        now(),
        jsonb_build_object(
            'lesson_id', lesson_row.lesson_id,
            'lesson_key', key_text,
            'scope_type', lesson_row.scope_type,
            'status', 'admitted'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN lesson_row;
END;
$$;

-- Shared containment skeleton note: each transition below locks the lesson
-- key, returns the row unchanged when already in the target status (no new
-- event), raises 55000 on an illegal edge, and otherwise advances the status
-- with a status event plus an audit event.

-- Suspend: the lesson leaves future retrieval. Already-pinned consumers keep
-- history and are flagged via research_lesson_pinned_review.
CREATE FUNCTION suspend_research_lesson(
    lesson_key_value text,
    reason_value text,
    actor_assignment_id_value uuid,
    actor_run_key_value text,
    source_lineage_value jsonb
) RETURNS research_lesson
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    lesson_row research_lesson%ROWTYPE;
    key_text text;
    reason_text text;
    actor_run_text text;
    from_text text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research lesson arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(lesson_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson key is required'
            USING ERRCODE = '22023';
    END IF;
    reason_text := btrim(reason_value);
    IF coalesce(reason_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson suspension requires a reason'
            USING ERRCODE = '22023';
    END IF;
    actor_run_text := btrim(actor_run_key_value);
    IF actor_assignment_id_value IS NULL
       OR coalesce(actor_run_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson actor assignment and run are required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = actor_assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research lesson actor assignment % is not registered',
            actor_assignment_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96003));

    SELECT * INTO lesson_row
    FROM research_lesson
    WHERE lesson_key = key_text;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research lesson % is not registered',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lesson_row.status = 'suspended' THEN
        RETURN lesson_row;
    END IF;
    IF NOT research_lesson_transition_is_legal(
            lesson_row.status, 'suspended') THEN
        RAISE EXCEPTION
            'research lesson % cannot transition from % to suspended',
            key_text, lesson_row.status
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        from_text := lesson_row.status;
        UPDATE research_lesson
        SET status = 'suspended'
        WHERE lesson_key = key_text
        RETURNING * INTO lesson_row;

        INSERT INTO research_lesson_status_event (
            lesson_key, from_status, to_status, reason,
            actor_assignment_id, actor_run_key,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, from_text, 'suspended', reason_text,
            actor_assignment_id_value, actor_run_text,
            source_lineage_value, clock_timestamp(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-lesson:' || lesson_row.lesson_id::text || ':suspended',
        'research.research_lesson_suspended',
        now(),
        jsonb_build_object(
            'lesson_id', lesson_row.lesson_id,
            'lesson_key', key_text,
            'status', 'suspended'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN lesson_row;
END;
$$;

-- Supersede: the lesson leaves future retrieval directly; retrieval resolves
-- to the successor instead. The successor must already be registered.
CREATE FUNCTION supersede_research_lesson(
    lesson_key_value text,
    successor_lesson_key_value text,
    actor_assignment_id_value uuid,
    actor_run_key_value text,
    source_lineage_value jsonb
) RETURNS research_lesson
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    lesson_row research_lesson%ROWTYPE;
    key_text text;
    successor_text text;
    actor_run_text text;
    from_text text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research lesson arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(lesson_key_value);
    successor_text := btrim(successor_lesson_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson key is required'
            USING ERRCODE = '22023';
    END IF;
    IF coalesce(successor_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson supersession requires a successor'
            USING ERRCODE = '22023';
    END IF;
    IF successor_text = key_text THEN
        RAISE EXCEPTION
            'research lesson supersession requires a different successor'
            USING ERRCODE = '22023';
    END IF;
    actor_run_text := btrim(actor_run_key_value);
    IF actor_assignment_id_value IS NULL
       OR coalesce(actor_run_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson actor assignment and run are required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = actor_assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research lesson actor assignment % is not registered',
            actor_assignment_id_value
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_lesson
        WHERE lesson_key = successor_text
    ) THEN
        RAISE EXCEPTION
            'research lesson successor % is not registered',
            successor_text
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96003));

    SELECT * INTO lesson_row
    FROM research_lesson
    WHERE lesson_key = key_text;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research lesson % is not registered',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lesson_row.status = 'superseded' THEN
        IF lesson_row.successor_lesson_key IS DISTINCT FROM successor_text THEN
            RAISE EXCEPTION
                'research lesson % is already superseded by a different successor',
                key_text
                USING ERRCODE = '55000';
        END IF;
        RETURN lesson_row;
    END IF;
    IF NOT research_lesson_transition_is_legal(
            lesson_row.status, 'superseded') THEN
        RAISE EXCEPTION
            'research lesson % cannot transition from % to superseded',
            key_text, lesson_row.status
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        from_text := lesson_row.status;
        UPDATE research_lesson
        SET status = 'superseded',
            successor_lesson_key = successor_text
        WHERE lesson_key = key_text
        RETURNING * INTO lesson_row;

        INSERT INTO research_lesson_status_event (
            lesson_key, from_status, to_status, reason,
            actor_assignment_id, actor_run_key,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, from_text, 'superseded',
            'superseded_by_successor',
            actor_assignment_id_value, actor_run_text,
            source_lineage_value, clock_timestamp(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-lesson:' || lesson_row.lesson_id::text || ':superseded',
        'research.research_lesson_superseded',
        now(),
        jsonb_build_object(
            'lesson_id', lesson_row.lesson_id,
            'lesson_key', key_text,
            'status', 'superseded',
            'successor_lesson_key', successor_text
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN lesson_row;
END;
$$;

-- Contaminate: the lesson leaves future retrieval; a reason is required so
-- the contamination record stays reviewable.
CREATE FUNCTION contaminate_research_lesson(
    lesson_key_value text,
    reason_value text,
    actor_assignment_id_value uuid,
    actor_run_key_value text,
    source_lineage_value jsonb
) RETURNS research_lesson
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    lesson_row research_lesson%ROWTYPE;
    key_text text;
    reason_text text;
    actor_run_text text;
    from_text text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research lesson arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(lesson_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson key is required'
            USING ERRCODE = '22023';
    END IF;
    reason_text := btrim(reason_value);
    IF coalesce(reason_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson contamination requires a reason'
            USING ERRCODE = '22023';
    END IF;
    actor_run_text := btrim(actor_run_key_value);
    IF actor_assignment_id_value IS NULL
       OR coalesce(actor_run_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson actor assignment and run are required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = actor_assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research lesson actor assignment % is not registered',
            actor_assignment_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96003));

    SELECT * INTO lesson_row
    FROM research_lesson
    WHERE lesson_key = key_text;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research lesson % is not registered',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lesson_row.status = 'contaminated' THEN
        RETURN lesson_row;
    END IF;
    IF NOT research_lesson_transition_is_legal(
            lesson_row.status, 'contaminated') THEN
        RAISE EXCEPTION
            'research lesson % cannot transition from % to contaminated',
            key_text, lesson_row.status
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        from_text := lesson_row.status;
        UPDATE research_lesson
        SET status = 'contaminated'
        WHERE lesson_key = key_text
        RETURNING * INTO lesson_row;

        INSERT INTO research_lesson_status_event (
            lesson_key, from_status, to_status, reason,
            actor_assignment_id, actor_run_key,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, from_text, 'contaminated', reason_text,
            actor_assignment_id_value, actor_run_text,
            source_lineage_value, clock_timestamp(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-lesson:' || lesson_row.lesson_id::text || ':contaminated',
        'research.research_lesson_contaminated',
        now(),
        jsonb_build_object(
            'lesson_id', lesson_row.lesson_id,
            'lesson_key', key_text,
            'status', 'contaminated'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN lesson_row;
END;
$$;

-- Expire: explicit administrative expiry (stale method, withdrawn data
-- contract). Freshness is also enforced at retrieval time via the `at`
-- argument, so expiry here and filtering there agree.
CREATE FUNCTION expire_research_lesson(
    lesson_key_value text,
    actor_assignment_id_value uuid,
    actor_run_key_value text,
    source_lineage_value jsonb
) RETURNS research_lesson
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    lesson_row research_lesson%ROWTYPE;
    key_text text;
    actor_run_text text;
    from_text text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research lesson arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(lesson_key_value);
    IF coalesce(key_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson key is required'
            USING ERRCODE = '22023';
    END IF;
    actor_run_text := btrim(actor_run_key_value);
    IF actor_assignment_id_value IS NULL
       OR coalesce(actor_run_text, '') = '' THEN
        RAISE EXCEPTION 'research lesson actor assignment and run are required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_assignment
        WHERE assignment_id = actor_assignment_id_value
    ) THEN
        RAISE EXCEPTION 'research lesson actor assignment % is not registered',
            actor_assignment_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 96003));

    SELECT * INTO lesson_row
    FROM research_lesson
    WHERE lesson_key = key_text;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research lesson % is not registered',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lesson_row.status = 'expired' THEN
        RETURN lesson_row;
    END IF;
    IF NOT research_lesson_transition_is_legal(
            lesson_row.status, 'expired') THEN
        RAISE EXCEPTION
            'research lesson % cannot transition from % to expired',
            key_text, lesson_row.status
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        from_text := lesson_row.status;
        UPDATE research_lesson
        SET status = 'expired'
        WHERE lesson_key = key_text
        RETURNING * INTO lesson_row;

        INSERT INTO research_lesson_status_event (
            lesson_key, from_status, to_status, reason,
            actor_assignment_id, actor_run_key,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, from_text, 'expired', 'expiry_reached',
            actor_assignment_id_value, actor_run_text,
            source_lineage_value, clock_timestamp(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'research-lesson:' || lesson_row.lesson_id::text || ':expired',
        'research.research_lesson_expired',
        now(),
        jsonb_build_object(
            'lesson_id', lesson_row.lesson_id,
            'lesson_key', key_text,
            'status', 'expired'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN lesson_row;
END;
$$;

-- Decision #173.3 + #173.5: retrieve the lessons applicable to one pinned
-- assignment at one instant. Only admitted, in-scope, unexpired lessons are
-- returned, with their exact stored versions (rows are pinned content, never
-- latest-floating references). Superseded lessons resolve transitively to
-- their successor (cycle-safe; a broken link or cycle excludes the lesson);
-- duplicates resolve to their canonical lesson. The caller pins are verified
-- against the registered row on the scope-relevant fields so stale pins fail
-- closed instead of retrieving under the wrong scope. Recording the check in
-- the Retrieved Context Envelope belongs to recipe integration (PR3).
CREATE FUNCTION retrieve_lessons_for_assignment(
    pins_value jsonb,
    at_value timestamptz
) RETURNS SETOF research_lesson
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    assignment_row research_assignment%ROWTYPE;
    key_text text;
    lesson_row research_lesson%ROWTYPE;
    next_row research_lesson%ROWTYPE;
    resolved research_lesson%ROWTYPE;
    next_key text;
    visited text[];
    emitted text[] := ARRAY[]::text[];
    resolved_missing boolean;
    hop_count integer;
BEGIN
    IF NOT research_assignment_pins_valid(pins_value) THEN
        RAISE EXCEPTION 'research retrieval pins are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF at_value IS NULL THEN
        RAISE EXCEPTION 'research retrieval instant is required'
            USING ERRCODE = '22023';
    END IF;
    key_text := btrim(pins_value->>'assignment_key');
    SELECT * INTO assignment_row
    FROM research_assignment
    WHERE assignment_key = key_text;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'research assignment % is not registered',
            key_text
            USING ERRCODE = '22023';
    END IF;
    IF lower(btrim(pins_value->>'desk_role'))
            IS DISTINCT FROM assignment_row.desk_role
       OR btrim(pins_value->>'posture_profile')
            IS DISTINCT FROM assignment_row.posture_profile
       OR btrim(pins_value->>'recipe_version')
            IS DISTINCT FROM assignment_row.recipe_version
       OR btrim(pins_value->>'contract_runner')
            IS DISTINCT FROM assignment_row.contract_runner THEN
        RAISE EXCEPTION
            'research retrieval pins do not match the registered assignment'
            USING ERRCODE = '22023';
    END IF;

    FOR lesson_row IN
        SELECT * FROM research_lesson ORDER BY lesson_key
    LOOP
        -- Resolve duplicates to canonical and superseded to successor,
        -- transitively. Cycles and broken links fail closed (excluded).
        resolved := lesson_row;
        visited := ARRAY[]::text[];
        resolved_missing := false;
        hop_count := 0;
        LOOP
            IF resolved.canonical_lesson_key IS NOT NULL THEN
                next_key := btrim(resolved.canonical_lesson_key);
            ELSIF resolved.status = 'superseded' THEN
                next_key := btrim(resolved.successor_lesson_key);
            ELSE
                EXIT;
            END IF;
            IF next_key = ANY (visited) OR hop_count > 16 THEN
                resolved_missing := true;
                EXIT;
            END IF;
            visited := visited || resolved.lesson_key;
            SELECT * INTO next_row
            FROM research_lesson
            WHERE lesson_key = next_key;
            IF NOT FOUND THEN
                resolved_missing := true;
                EXIT;
            END IF;
            resolved := next_row;
            hop_count := hop_count + 1;
        END LOOP;
        IF resolved_missing THEN
            CONTINUE;
        END IF;
        IF resolved.lesson_key = ANY (emitted) THEN
            CONTINUE;
        END IF;
        IF resolved.status <> 'admitted' THEN
            CONTINUE;
        END IF;
        IF resolved.canonical_lesson_key IS NOT NULL THEN
            CONTINUE;
        END IF;
        IF resolved.expires_at <= at_value THEN
            CONTINUE;
        END IF;
        IF resolved.scope_type = 'global' THEN
            NULL;
        ELSIF resolved.scope_type = 'role_posture' THEN
            IF btrim(resolved.scope_key->>'desk_role')
                    IS DISTINCT FROM assignment_row.desk_role
               OR btrim(resolved.scope_key->>'posture_profile')
                    IS DISTINCT FROM assignment_row.posture_profile THEN
                CONTINUE;
            END IF;
        ELSIF resolved.scope_type = 'method_data' THEN
            IF btrim(resolved.scope_key->>'contract_runner')
                    IS DISTINCT FROM assignment_row.contract_runner
               OR btrim(resolved.scope_key->>'recipe_version')
                    IS DISTINCT FROM assignment_row.recipe_version THEN
                CONTINUE;
            END IF;
        ELSE
            CONTINUE;
        END IF;
        emitted := emitted || resolved.lesson_key;
        RETURN NEXT resolved;
    END LOOP;
END;
$$;

-- Decision #173.5: already-pinned consumers keep history but are flagged for
-- explicit review, never silently re-pinned. Given a pinned
-- lesson-versions object ({lesson_key: <exact version>}, as carried on
-- artifact manifests), report each pinned key with its current status; any
-- key whose status is not admitted -- including unknown keys -- needs
-- review.
CREATE FUNCTION research_lesson_pinned_review(
    lesson_versions_value jsonb
)
RETURNS TABLE (
    pinned_lesson_key text,
    current_status text,
    needs_review boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_key text;
    known_status text;
BEGIN
    IF jsonb_typeof(lesson_versions_value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'research pinned lesson versions must be an object'
            USING ERRCODE = '22023';
    END IF;
    FOR version_key IN
        SELECT jsonb_object_keys(lesson_versions_value)
    LOOP
        IF coalesce(btrim(version_key), '') = '' THEN
            RAISE EXCEPTION 'research pinned lesson key must not be blank'
                USING ERRCODE = '22023';
        END IF;
        SELECT status INTO known_status
        FROM research_lesson
        WHERE lesson_key = btrim(version_key);
        IF NOT FOUND THEN
            pinned_lesson_key := btrim(version_key);
            current_status := NULL;
            needs_review := true;
            RETURN NEXT;
        ELSE
            pinned_lesson_key := btrim(version_key);
            current_status := known_status;
            needs_review := (known_status IS DISTINCT FROM 'admitted');
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION research_lesson_uuid_is_wellformed(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_provenance_is_complete(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_support_is_wellformed(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_support_is_disjoint(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_scope_is_valid(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_dissent_is_wellformed(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_guidance_is_admissible(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_transition_is_legal(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION guard_research_lesson_write() FROM PUBLIC;
REVOKE ALL ON FUNCTION guard_research_lesson_transition() FROM PUBLIC;
REVOKE ALL ON FUNCTION propose_research_lesson(
    text, text, jsonb, text, jsonb, jsonb, jsonb, timestamptz, text, jsonb)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION admit_research_lesson(text, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION suspend_research_lesson(
    text, text, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION supersede_research_lesson(
    text, text, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION contaminate_research_lesson(
    text, text, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION expire_research_lesson(text, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION retrieve_lessons_for_assignment(jsonb, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION research_lesson_pinned_review(jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_lesson FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_lesson_status_event FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
