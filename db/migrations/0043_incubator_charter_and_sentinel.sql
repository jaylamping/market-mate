-- WU-39 interrogate Consider items that stay inside original intent:
--  Sentinel records entitled use, pins local_research, and evaluates as of
--  clock_timestamp(); charter lives on the row; spec is canonicalized;
--  shot identity is locked before read; nested paper/live/authority keys
--  are rejected. registration_id stays optional (cheap Alpha Shots).
--  Applied 0041 and 0042 are left unchanged.

CREATE FUNCTION incubator_json_claims_authority(node jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE jsonb_typeof(node)
        WHEN 'object' THEN EXISTS (
            SELECT 1 FROM jsonb_object_keys(node) k
            WHERE lower(k) IN (
                'authority', 'lifecycle_state', 'execution_environment',
                'execution_authority', 'strategy_eligible', 'paper_eligible',
                'trade_eligible', 'paper', 'live', 'broker',
                'execution_edge_and_paper_trading'
            )
        ) OR EXISTS (
            SELECT 1 FROM jsonb_each(node) e
            WHERE incubator_json_claims_authority(e.value)
        )
        WHEN 'array' THEN EXISTS (
            SELECT 1 FROM jsonb_array_elements(node) elem
            WHERE incubator_json_claims_authority(elem)
        )
        ELSE false
    END;
$$;

CREATE OR REPLACE FUNCTION incubator_hypothesis_is_complete(node jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'claim', 'metric', 'cost_envelope', 'stopping_rule'
    ];
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_object_keys(node) k
        WHERE k <> ALL (allowed)
    ) THEN
        RETURN false;
    END IF;
    IF incubator_json_claims_authority(node) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'claim') IS DISTINCT FROM 'string'
       OR coalesce(btrim(node->>'claim'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'metric') IS DISTINCT FROM 'string'
       OR coalesce(btrim(node->>'metric'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'cost_envelope') IS DISTINCT FROM 'object'
       AND jsonb_typeof(node->'cost_envelope') IS DISTINCT FROM 'string'
       AND jsonb_typeof(node->'cost_envelope') IS DISTINCT FROM 'number' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'cost_envelope') = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(node->'cost_envelope')) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'cost_envelope') = 'string'
       AND coalesce(btrim(node->>'cost_envelope'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'stopping_rule') IS DISTINCT FROM 'string'
       AND jsonb_typeof(node->'stopping_rule') IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'stopping_rule') = 'string'
       AND coalesce(btrim(node->>'stopping_rule'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(node->'stopping_rule') = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(node->'stopping_rule')) THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION incubator_assignment_spec_is_conforming(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY[
        'assignment_key', 'lane', 'desk_role',
        'profit_contribution_hypothesis', 'budget', 'stopping_rule',
        'registration_id'
    ];
    role_text text;
    budget jsonb;
BEGIN
    IF jsonb_typeof(spec_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(spec_value) k
            WHERE k <> ALL (allowed)
       ) THEN
        RETURN false;
    END IF;
    IF incubator_json_claims_authority(spec_value) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'assignment_key') IS DISTINCT FROM 'string'
       OR coalesce(btrim(spec_value->>'assignment_key'), '') = '' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(spec_value->'lane') IS DISTINCT FROM 'string'
       OR btrim(spec_value->>'lane') IS DISTINCT FROM 'research' THEN
        RETURN false;
    END IF;
    role_text := btrim(spec_value->>'desk_role');
    IF jsonb_typeof(spec_value->'desk_role') IS DISTINCT FROM 'string'
       OR incubator_charter_role_is_forbidden(role_text)
       OR NOT incubator_desk_role_is_allowed(role_text) THEN
        RETURN false;
    END IF;
    IF NOT incubator_hypothesis_is_complete(
            spec_value->'profit_contribution_hypothesis') THEN
        RETURN false;
    END IF;
    budget := spec_value->'budget';
    IF jsonb_typeof(budget) IS DISTINCT FROM 'object'
       AND jsonb_typeof(budget) IS DISTINCT FROM 'number' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(budget) = 'object'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(budget)) THEN
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
    IF spec_value->'stopping_rule' IS DISTINCT FROM
          spec_value->'profit_contribution_hypothesis'->'stopping_rule' THEN
        RETURN false;
    END IF;
    IF spec_value->'budget' IS DISTINCT FROM
          spec_value->'profit_contribution_hypothesis'->'cost_envelope' THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

ALTER TABLE incubator_assignment
    ADD CONSTRAINT incubator_assignment_spec_conforming
    CHECK (incubator_assignment_spec_is_conforming(spec));

ALTER TABLE incubator_assignment
    ADD CONSTRAINT incubator_assignment_key_matches_spec
    CHECK (assignment_key = btrim(spec->>'assignment_key'));

ALTER TABLE incubator_assignment
    ADD CONSTRAINT incubator_assignment_lane_matches_spec
    CHECK (lane = btrim(spec->>'lane'));

ALTER TABLE incubator_assignment
    ADD CONSTRAINT incubator_assignment_desk_role_matches_spec
    CHECK (desk_role = lower(btrim(spec->>'desk_role')));

ALTER TABLE alpha_shot
    ADD CONSTRAINT alpha_shot_result_claims_no_authority
    CHECK (NOT incubator_json_claims_authority(result));

CREATE OR REPLACE FUNCTION engine_admit_research_assignment(
    spec_value jsonb,
    source_lineage_value jsonb
) RETURNS incubator_assignment
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    existing incubator_assignment%ROWTYPE;
    created incubator_assignment%ROWTYPE;
    key_text text;
    registration_id_value uuid;
    spec_stored jsonb;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'incubator assignment arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT incubator_assignment_spec_is_conforming(spec_value) THEN
        RAISE EXCEPTION
            'engine rejected nonconforming assignment; charter invariants forbid manager, desk-head, risk, compliance, and non-research lanes'
            USING ERRCODE = '22023';
    END IF;

    key_text := btrim(spec_value->>'assignment_key');
    spec_stored := spec_value || jsonb_build_object(
        'assignment_key', key_text,
        'lane', 'research',
        'desk_role', lower(btrim(spec_value->>'desk_role'))
    );
    registration_id_value := NULL;
    IF spec_value ? 'registration_id' THEN
        BEGIN
            registration_id_value := (spec_value->>'registration_id')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'incubator assignment arguments are invalid'
                    USING ERRCODE = '22023';
        END;
        IF registration_id_value IS NULL THEN
            RAISE EXCEPTION 'incubator assignment arguments are invalid'
                USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM experiment_preregistration
            WHERE registration_id = registration_id_value
        ) THEN
            RAISE EXCEPTION 'experiment preregistration % is not registered',
                registration_id_value
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(key_text, 41023));

    SELECT * INTO existing
    FROM incubator_assignment
    WHERE assignment_key = key_text;
    IF FOUND THEN
        IF existing.spec IS DISTINCT FROM spec_stored THEN
            RAISE EXCEPTION
                'incubator assignment % is already registered with a different spec',
                key_text
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        INSERT INTO incubator_assignment (
            assignment_key, lane, desk_role, spec, registration_id, state,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, 'research', lower(btrim(spec_value->>'desk_role')),
            spec_stored, registration_id_value, 'scheduled',
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
        'incubator-assignment:' || created.assignment_id::text,
        'research.incubator_assignment_scheduled',
        now(),
        jsonb_build_object(
            'assignment_id', created.assignment_id,
            'assignment_key', key_text,
            'lane', 'research',
            'desk_role', created.desk_role
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE OR REPLACE FUNCTION record_alpha_shot(
    spec_value jsonb,
    result_value jsonb,
    parent_shot_id_value uuid,
    failure_class_value text,
    source_lineage_value jsonb
) RETURNS alpha_shot
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    assignment_row incubator_assignment%ROWTYPE;
    parent_row alpha_shot%ROWTYPE;
    stopping jsonb;
    created alpha_shot%ROWTYPE;
    existing alpha_shot%ROWTYPE;
    digest_value text;
    outcome text;
    failure_class_stored text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value)
       OR jsonb_typeof(result_value) IS DISTINCT FROM 'object'
       OR NOT (result_value ? 'outcome') THEN
        RAISE EXCEPTION 'alpha shot arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(result_value->'outcome') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'alpha shot arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF incubator_json_claims_authority(result_value) THEN
        RAISE EXCEPTION 'alpha shot arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    outcome := btrim(result_value->>'outcome');
    IF outcome IS NULL
       OR outcome NOT IN ('completed', 'failed', 'null_result', 'invalid') THEN
        RAISE EXCEPTION 'alpha shot arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    assignment_row := engine_admit_research_assignment(
        spec_value, source_lineage_value);

    PERFORM pg_advisory_xact_lock(
        hashtextextended(assignment_row.assignment_id::text, 41024));

    stopping := assignment_row.spec->'stopping_rule';
    failure_class_stored := nullif(btrim(failure_class_value), '');
    digest_value := alpha_shot_digest(
        assignment_row.assignment_id,
        assignment_row.spec->'profit_contribution_hypothesis',
        assignment_row.spec->'budget',
        stopping,
        result_value,
        parent_shot_id_value,
        failure_class_stored,
        source_lineage_value
    );

    SELECT * INTO existing
    FROM alpha_shot
    WHERE assignment_id = assignment_row.assignment_id;
    IF FOUND THEN
        IF existing.shot_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION
                'alpha shot for assignment % is already recorded with a different result or lineage',
                assignment_row.assignment_key
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    IF parent_shot_id_value IS NOT NULL THEN
        SELECT * INTO parent_row
        FROM alpha_shot
        WHERE shot_id = parent_shot_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'alpha shot % is not registered', parent_shot_id_value
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.incubator_write', 'on', true);
    BEGIN
        INSERT INTO alpha_shot (
            assignment_id, parent_shot_id, hypothesis, budget, stopping_rule,
            result, failure_class, shot_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            assignment_row.assignment_id, parent_shot_id_value,
            assignment_row.spec->'profit_contribution_hypothesis',
            assignment_row.spec->'budget', stopping, result_value,
            failure_class_stored, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            SELECT * INTO existing
            FROM alpha_shot
            WHERE assignment_id = assignment_row.assignment_id;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.shot_digest IS DISTINCT FROM digest_value THEN
                RAISE EXCEPTION
                    'alpha shot for assignment % is already recorded with a different result or lineage',
                    assignment_row.assignment_key
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.incubator_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.incubator_write', 'off', true);

    PERFORM append_audit_event(
        'alpha-shot:' || created.shot_id::text,
        'research.alpha_shot_recorded',
        now(),
        jsonb_build_object(
            'shot_id', created.shot_id,
            'assignment_id', created.assignment_id,
            'parent_shot_id', parent_shot_id_value,
            'outcome', outcome,
            'shot_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE OR REPLACE FUNCTION sentinel_allow_alpha_shot_evidence(
    shot_id_value uuid,
    entitlement_version_id_value uuid,
    requested_purpose_value text,
    requested_at_value timestamptz,
    source_lineage_value jsonb
) RETURNS entitlement_gate_decision
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    shot_row alpha_shot%ROWTYPE;
    decision_row entitlement_gate_decision%ROWTYPE;
    request_key_value text;
    evaluation_at timestamptz;
BEGIN
    IF shot_id_value IS NULL
       OR entitlement_version_id_value IS NULL
       OR coalesce(btrim(requested_purpose_value), '') = ''
       OR requested_at_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'sentinel evidence-use arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF btrim(requested_purpose_value) IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION
            'sentinel denied non-entitled evidence use: purpose_not_authorized'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO shot_row
    FROM alpha_shot
    WHERE shot_id = shot_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'alpha shot % is not registered', shot_id_value
            USING ERRCODE = '22023';
    END IF;
    IF source_lineage_value IS DISTINCT FROM shot_row.source_lineage THEN
        RAISE EXCEPTION
            'sentinel denied non-entitled evidence use: lineage_mismatch'
            USING ERRCODE = '42501';
    END IF;

    evaluation_at := clock_timestamp();
    request_key_value := 'alpha-shot-evidence:' || shot_id_value::text
        || ':' || entitlement_version_id_value::text
        || ':local_research:'
        || to_char(evaluation_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');

    decision_row := evaluate_entitlement_gate(
        request_key_value,
        entitlement_version_id_value,
        'local_research',
        evaluation_at,
        shot_row.source_lineage
    );

    IF decision_row.decision IS DISTINCT FROM 'allowed' THEN
        RAISE EXCEPTION
            'sentinel denied non-entitled evidence use: %',
            coalesce(decision_row.denial_reason, 'denied')
            USING ERRCODE = '42501';
    END IF;

    PERFORM record_entitled_use(
        'alpha-shot-use:' || shot_id_value::text || ':' || decision_row.decision_id::text,
        decision_row.decision_id,
        'incubator-sentinel',
        shot_row.source_lineage
    );

    RETURN decision_row;
END;
$$;

REVOKE ALL ON FUNCTION engine_admit_research_assignment(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_alpha_shot(jsonb, jsonb, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION sentinel_allow_alpha_shot_evidence(
    uuid, uuid, text, timestamptz, jsonb) FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
