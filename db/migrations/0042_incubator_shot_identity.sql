-- WU-39 interrogate Act On: Alpha Shot identity includes failure_class
-- and source_lineage, and assignment stopping_rule/budget must equal the
-- Profit Contribution Hypothesis copies. Applied 0041 is left unchanged.

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

DO $drop_digest_check$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.conname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'alpha_shot'
          AND c.contype = 'c'
          AND pg_get_constraintdef(c.oid) LIKE '%alpha_shot_digest%'
    LOOP
        EXECUTE format('ALTER TABLE alpha_shot DROP CONSTRAINT %I', r.conname);
    END LOOP;
END
$drop_digest_check$;

DROP FUNCTION IF EXISTS alpha_shot_digest(uuid, jsonb, jsonb, jsonb, jsonb, uuid);

CREATE FUNCTION alpha_shot_digest(
    assignment_id_value uuid,
    hypothesis_value jsonb,
    budget_value jsonb,
    stopping_rule_value jsonb,
    result_value jsonb,
    parent_shot_id_value uuid,
    failure_class_value text,
    source_lineage_value jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-alpha-shot-v2|' || jsonb_build_object(
                'assignment_id', assignment_id_value,
                'hypothesis', hypothesis_value,
                'budget', budget_value,
                'stopping_rule', stopping_rule_value,
                'result', result_value,
                'parent_shot_id', parent_shot_id_value,
                'failure_class', coalesce(failure_class_value, ''),
                'source_lineage', source_lineage_value
            )::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

ALTER TABLE incubator_assignment
    ADD CONSTRAINT incubator_assignment_stopping_rule_matches_hypothesis
    CHECK (
        spec->'stopping_rule' IS NOT DISTINCT FROM
        spec->'profit_contribution_hypothesis'->'stopping_rule'
    );

ALTER TABLE incubator_assignment
    ADD CONSTRAINT incubator_assignment_budget_matches_hypothesis_envelope
    CHECK (
        spec->'budget' IS NOT DISTINCT FROM
        spec->'profit_contribution_hypothesis'->'cost_envelope'
    );

ALTER TABLE alpha_shot
    ADD CONSTRAINT alpha_shot_digest_matches
    CHECK (
        shot_digest = alpha_shot_digest(
            assignment_id, hypothesis, budget, stopping_rule, result,
            parent_shot_id, failure_class, source_lineage)
    );

ALTER TABLE alpha_shot
    ADD CONSTRAINT alpha_shot_stopping_rule_matches_hypothesis
    CHECK (hypothesis->'stopping_rule' IS NOT DISTINCT FROM stopping_rule);

ALTER TABLE alpha_shot
    ADD CONSTRAINT alpha_shot_budget_matches_hypothesis_envelope
    CHECK (hypothesis->'cost_envelope' IS NOT DISTINCT FROM budget);

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
    outcome := btrim(result_value->>'outcome');
    IF outcome IS NULL
       OR outcome NOT IN ('completed', 'failed', 'null_result', 'invalid') THEN
        RAISE EXCEPTION 'alpha shot arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    assignment_row := engine_admit_research_assignment(
        spec_value, source_lineage_value);

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
            failure_class_stored, digest_value,
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

REVOKE ALL ON FUNCTION record_alpha_shot(jsonb, jsonb, uuid, text, jsonb) FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
