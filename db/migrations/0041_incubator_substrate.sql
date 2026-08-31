-- WU-39 Incubator substrate: Alpha Shots record a Profit Contribution
-- Hypothesis, budget, stopping rule, result, and failure lineage.
-- Engine-lite admits and schedules assignments in a single research lane.
-- Sentinel denies non-entitled evidence use. Manager, desk-head, risk,
-- and compliance assignments are charter-nonconforming and rejected.

CREATE FUNCTION incubator_charter_role_is_forbidden(role_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT lower(btrim(role_value)) IN (
        'manager', 'supervisor', 'desk_head', 'desk-head', 'deskhead',
        'risk', 'compliance', 'entitlement', 'entitlement_certification',
        'accounting', 'lifecycle', 'safety', 'security',
        'platform_reliability', 'control_enforcement', 'control',
        'paper', 'live', 'broker', 'paper_execution',
        'execution_edge_and_paper_trading'
    );
$$;

CREATE FUNCTION incubator_desk_role_is_allowed(role_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT lower(btrim(role_value)) IN (
        'market_intelligence_and_thesis',
        'quantitative_research_and_experimentation',
        'data_and_feature_research',
        'strategy_incubation',
        'portfolio_and_capital_efficiency',
        'economic_evaluation_and_challenge'
    );
$$;

CREATE FUNCTION incubator_hypothesis_is_complete(node jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF jsonb_typeof(node) IS DISTINCT FROM 'object' THEN
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

CREATE FUNCTION incubator_assignment_spec_is_conforming(spec_value jsonb)
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
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION alpha_shot_digest(
    assignment_id_value uuid,
    hypothesis_value jsonb,
    budget_value jsonb,
    stopping_rule_value jsonb,
    result_value jsonb,
    parent_shot_id_value uuid
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-alpha-shot-v1|' || jsonb_build_object(
                'assignment_id', assignment_id_value,
                'hypothesis', hypothesis_value,
                'budget', budget_value,
                'stopping_rule', stopping_rule_value,
                'result', result_value,
                'parent_shot_id', parent_shot_id_value
            )::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE TABLE incubator_assignment (
    assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_key text NOT NULL CHECK (btrim(assignment_key) <> ''),
    lane text NOT NULL CHECK (lane = 'research'),
    desk_role text NOT NULL,
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    registration_id uuid
        REFERENCES experiment_preregistration(registration_id),
    state text NOT NULL CHECK (state IN ('scheduled', 'completed', 'failed')),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (incubator_desk_role_is_allowed(desk_role)),
    CHECK (NOT incubator_charter_role_is_forbidden(desk_role)),
    CHECK (record_environment = 'local_research'),
    UNIQUE (assignment_key)
);

SELECT register_evidence_table('incubator_assignment');

CREATE TABLE alpha_shot (
    shot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id uuid NOT NULL
        REFERENCES incubator_assignment(assignment_id),
    parent_shot_id uuid,
    hypothesis jsonb NOT NULL CHECK (jsonb_typeof(hypothesis) = 'object'),
    budget jsonb NOT NULL,
    stopping_rule jsonb NOT NULL,
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    failure_class text,
    shot_digest text NOT NULL CHECK (shot_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (incubator_hypothesis_is_complete(hypothesis)),
    CHECK (result ? 'outcome'),
    CHECK (jsonb_typeof(result->'outcome') = 'string'),
    CHECK (btrim(result->>'outcome') IN (
        'completed', 'failed', 'null_result', 'invalid'
    )),
    CHECK (
        shot_digest = alpha_shot_digest(
            assignment_id, hypothesis, budget, stopping_rule, result, parent_shot_id)
    ),
    CHECK (parent_shot_id IS DISTINCT FROM shot_id),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('alpha_shot');

ALTER TABLE alpha_shot
    ADD CONSTRAINT alpha_shot_parent_fk
    FOREIGN KEY (parent_shot_id) REFERENCES alpha_shot(shot_id);

CREATE INDEX alpha_shot_parent_idx ON alpha_shot (parent_shot_id, receipt_time);
CREATE UNIQUE INDEX alpha_shot_assignment_uq ON alpha_shot (assignment_id);

CREATE FUNCTION guard_incubator_write() RETURNS trigger
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

CREATE TRIGGER incubator_assignment_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON incubator_assignment
    FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();

CREATE TRIGGER alpha_shot_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON alpha_shot
    FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write();

CREATE FUNCTION guard_incubator_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.incubator_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the incubator workflow', TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER incubator_assignment_insert_guard
    BEFORE INSERT ON incubator_assignment
    FOR EACH ROW EXECUTE FUNCTION guard_incubator_insert();

CREATE TRIGGER alpha_shot_insert_guard
    BEFORE INSERT ON alpha_shot
    FOR EACH ROW EXECUTE FUNCTION guard_incubator_insert();

CREATE FUNCTION engine_admit_research_assignment(
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
    outcome text;
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
    registration_id_value := NULL;
    IF spec_value ? 'registration_id' THEN
        BEGIN
            registration_id_value := (spec_value->>'registration_id')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'incubator assignment arguments are invalid'
                    USING ERRCODE = '22023';
        END;
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
        IF existing.spec IS DISTINCT FROM spec_value THEN
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
            spec_value, registration_id_value, 'scheduled',
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

CREATE FUNCTION record_alpha_shot(
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
    assignment_state text;
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
    outcome := btrim(result_value->>'outcome');
    IF outcome IS NULL
       OR outcome NOT IN ('completed', 'failed', 'null_result', 'invalid') THEN
        RAISE EXCEPTION 'alpha shot arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    assignment_row := engine_admit_research_assignment(
        spec_value, source_lineage_value);

    IF jsonb_typeof(assignment_row.spec->'stopping_rule') = 'string' THEN
        stopping := to_jsonb(btrim(assignment_row.spec->>'stopping_rule'));
    ELSE
        stopping := assignment_row.spec->'stopping_rule';
    END IF;
    digest_value := alpha_shot_digest(
        assignment_row.assignment_id,
        assignment_row.spec->'profit_contribution_hypothesis',
        assignment_row.spec->'budget',
        stopping,
        result_value,
        parent_shot_id_value
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

    PERFORM pg_advisory_xact_lock(
        hashtextextended(assignment_row.assignment_id::text, 41024));

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
            nullif(btrim(failure_class_value), ''), digest_value,
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

CREATE FUNCTION sentinel_allow_alpha_shot_evidence(
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
BEGIN
    IF shot_id_value IS NULL
       OR entitlement_version_id_value IS NULL
       OR coalesce(btrim(requested_purpose_value), '') = ''
       OR requested_at_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'sentinel evidence-use arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO shot_row
    FROM alpha_shot
    WHERE shot_id = shot_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'alpha shot % is not registered', shot_id_value
            USING ERRCODE = '22023';
    END IF;

    request_key_value := 'alpha-shot-evidence:' || shot_id_value::text
        || ':' || entitlement_version_id_value::text
        || ':' || btrim(requested_purpose_value)
        || ':' || to_char(requested_at_value AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');

    decision_row := evaluate_entitlement_gate(
        request_key_value,
        entitlement_version_id_value,
        btrim(requested_purpose_value),
        requested_at_value,
        source_lineage_value
    );

    IF decision_row.decision IS DISTINCT FROM 'allowed' THEN
        RAISE EXCEPTION
            'sentinel denied non-entitled evidence use: %',
            coalesce(decision_row.denial_reason, 'denied')
            USING ERRCODE = '42501';
    END IF;

    RETURN decision_row;
END;
$$;

REVOKE ALL ON FUNCTION engine_admit_research_assignment(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_alpha_shot(jsonb, jsonb, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION sentinel_allow_alpha_shot_evidence(
    uuid, uuid, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON incubator_assignment FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON alpha_shot FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
