-- WU-25 Principal-Pinned Overlay: at most five Principal-Nominated
-- Candidates receive full Research Candidate coverage without consuming
-- system-selected capacity (issue #14).
--
-- A pin cannot grant Trade Eligible status, bypass evidence gates, or
-- prevent mandatory safety demotion. Retention (no archive while active)
-- is the only stage effect. Overlay membership is a parallel evidence
-- set; it does not insert system_selected rows into coverage_universe_membership.

-- A pin cannot grant Trade Eligible: promotion_allowed requires NOT pinned.
CREATE OR REPLACE FUNCTION evaluate_coverage_policy(
    policy_version_id_value uuid,
    subject_key_value text,
    as_of_value timestamptz,
    input_value jsonb,
    source_lineage_value jsonb
) RETURNS coverage_policy_evaluation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    policy_row coverage_policy_version%ROWTYPE;
    created coverage_policy_evaluation%ROWTYPE;
    definition_value jsonb;
    current_stage_value text;
    requested_stage_value text;
    requested_capability_value text;
    system_selected_count_value integer;
    options_eligible_count_value integer;
    trade_eligible_count_value integer;
    research_candidate_count_value integer;
    forward_sessions_value integer;
    floor_failures_value integer;
    bottom_fitness_sessions_value integer;
    candidate_sessions_value integer;
    fitness_percentile_value numeric;
    routine_replacements_value integer;
    incumbent_fitness_value numeric;
    replacement_fitness_value numeric;
    target_value integer;
    ceiling_value integer;
    max_trade_eligible_value integer;
    max_research_candidates_value integer;
    routine_replacement_limit_value integer;
    promotion_allowed_value boolean;
    admission_allowed_value boolean;
    demotion_required_value boolean;
    archive_allowed_value boolean;
    replacement_allowed_value boolean;
    options_gates_pass_value boolean;
    enhanced_gates_pass_value boolean;
    capability_request_valid_value boolean;
    enhanced_research_allowed_value boolean;
    enhanced_live_gate_pass_value boolean;
    live_authority_granted_value boolean := false;
    approved_value boolean;
    decision_state_value text;
    next_stage_value text;
    result_value jsonb;
BEGIN
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = policy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage policy version % is not registered', policy_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF coalesce(btrim(subject_key_value), '') = '' OR as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR as_of_value < policy_row.effective_from THEN
        RAISE EXCEPTION 'coverage policy evaluation identity or as_of time is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT coverage_policy_evaluation_input_is_valid(input_value) THEN
        RAISE EXCEPTION
            'coverage policy evaluation input is incomplete or has an invalid type'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'coverage policy evaluation source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    definition_value := policy_row.definition;
    current_stage_value := input_value->>'current_stage';
    requested_stage_value := input_value->>'requested_stage';
    requested_capability_value := input_value->>'requested_capability';
    system_selected_count_value := (input_value->>'system_selected_count')::integer;
    options_eligible_count_value := (input_value->>'options_eligible_count')::integer;
    trade_eligible_count_value := (input_value->>'trade_eligible_count')::integer;
    research_candidate_count_value := (input_value->>'research_candidate_count')::integer;
    forward_sessions_value := (input_value->>'forward_complete_sessions')::integer;
    floor_failures_value := (input_value->>'eligibility_floor_failures')::integer;
    bottom_fitness_sessions_value := (input_value->>'bottom_fitness_sessions')::integer;
    candidate_sessions_value := (input_value->>'candidate_sessions')::integer;
    fitness_percentile_value := (input_value->>'fitness_percentile')::numeric;
    routine_replacements_value := (input_value->>'routine_replacements_this_month')::integer;
    incumbent_fitness_value := (input_value->>'incumbent_fitness')::numeric;
    replacement_fitness_value := (input_value->>'replacement_fitness')::numeric;
    target_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_target'])::integer;
    ceiling_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_ceiling'])::integer;
    max_trade_eligible_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_trade_eligible'])::integer;
    max_research_candidates_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_research_candidates'])::integer;
    routine_replacement_limit_value := ceil(
        target_value * coverage_policy_number_at(definition_value, ARRAY['replacement', 'routine_churn_fraction'])
    )::integer;
    approved_value := EXISTS (
        SELECT 1 FROM coverage_policy_approval
        WHERE policy_version_id = policy_version_id_value
          AND approved_at <= as_of_value
    );

    options_gates_pass_value := (input_value->'options_gates'->>'approved_expirations')::boolean
        AND (input_value->'options_gates'->>'nbbo_quality')::boolean
        AND (input_value->'options_gates'->>'spreads')::boolean
        AND (input_value->'options_gates'->>'open_interest_volume')::boolean
        AND (input_value->'options_gates'->>'lifecycle_metadata')::boolean
        AND (input_value->'options_gates'->>'defined_risk_execution')::boolean;
    enhanced_gates_pass_value := (input_value->'enhanced_risk_gates'->>'identity')::boolean
        AND (input_value->'enhanced_risk_gates'->>'reporting')::boolean
        AND (input_value->'enhanced_risk_gates'->>'authorized_quote')::boolean
        AND (input_value->'enhanced_risk_gates'->>'liquidity_spread')::boolean
        AND (input_value->'enhanced_risk_gates'->>'settlement')::boolean
        AND (input_value->'enhanced_risk_gates'->>'manipulation')::boolean
        AND (input_value->'enhanced_risk_gates'->>'forward_paper')::boolean;
    capability_request_valid_value :=
        (requested_capability_value = 'stock_eligible'
            AND (input_value->>'requested_stock')::boolean
            AND NOT (input_value->>'requested_options')::boolean)
        OR (requested_capability_value = 'options_eligible'
            AND NOT (input_value->>'requested_stock')::boolean
            AND (input_value->>'requested_options')::boolean)
        OR (requested_capability_value = 'both'
            AND (input_value->>'requested_stock')::boolean
            AND (input_value->>'requested_options')::boolean)
        OR (requested_capability_value = 'none'
            AND NOT (input_value->>'requested_stock')::boolean
            AND NOT (input_value->>'requested_options')::boolean);

    demotion_required_value := ((input_value->>'hard_failure')::boolean
            AND coverage_policy_boolean_at(definition_value, ARRAY['demotion', 'hard_failure_immediate']))
        OR floor_failures_value >= coverage_policy_number_at(definition_value, ARRAY['demotion', 'eligibility_floor_failures'])
        OR (
            fitness_percentile_value <= coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_percentile'])
            AND bottom_fitness_sessions_value >= coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_consecutive_sessions'])
        );

    admission_allowed_value := approved_value
        AND current_stage_value = 'discovery_pool'
        AND requested_stage_value = 'research_candidate'
        AND NOT demotion_required_value
        AND NOT (input_value->>'has_open_obligation')::boolean
        AND (NOT (input_value->>'is_new_system_member')::boolean
             OR NOT (input_value->>'system_selected')::boolean
             OR system_selected_count_value < target_value)
        AND system_selected_count_value < ceiling_value
        AND research_candidate_count_value < max_research_candidates_value
        AND (input_value->>'quality_floor_pass')::boolean
        AND (input_value->>'data_gate_pass')::boolean
        AND (input_value->>'liquidity_gate_pass')::boolean
        AND (input_value->>'diversification_gate_pass')::boolean
        AND NOT (input_value->>'unresolved_anomaly')::boolean
        AND capability_request_valid_value
        AND (NOT (input_value->>'is_enhanced_risk')::boolean OR enhanced_gates_pass_value);

    promotion_allowed_value := approved_value
        AND current_stage_value = 'research_candidate'
        AND requested_stage_value = 'trade_eligible'
        AND NOT (input_value->>'is_enhanced_risk')::boolean
        AND forward_sessions_value >= coverage_policy_number_at(definition_value, ARRAY['promotion', 'forward_complete_sessions'])
        AND (input_value->>'quality_floor_pass')::boolean
        AND (input_value->>'data_gate_pass')::boolean
        AND (input_value->>'liquidity_gate_pass')::boolean
        AND (input_value->>'diversification_gate_pass')::boolean
        AND NOT (input_value->>'unresolved_anomaly')::boolean
        AND system_selected_count_value <= ceiling_value
        AND trade_eligible_count_value < max_trade_eligible_value
        AND capability_request_valid_value
        AND (requested_capability_value <> 'options_eligible' OR options_gates_pass_value)
        AND (requested_capability_value <> 'both' OR options_gates_pass_value)
        AND NOT demotion_required_value
        AND NOT (input_value->>'pinned')::boolean;
    archive_allowed_value := approved_value
        AND current_stage_value = 'research_candidate'
        AND requested_stage_value = 'archived'
        AND NOT (input_value->>'pinned')::boolean
        AND NOT (input_value->>'has_open_obligation')::boolean
        AND candidate_sessions_value >= coverage_policy_number_at(definition_value, ARRAY['promotion', 'research_candidate_archive_sessions']);
    replacement_allowed_value := approved_value
        AND (input_value->>'is_replacement')::boolean
        AND (
            replacement_fitness_value >= incumbent_fitness_value
                + coverage_policy_number_at(definition_value, ARRAY['replacement', 'minimum_fitness_delta'])
            OR (input_value->>'replacement_resolves_deficiency')::boolean
        )
        AND (
            ((input_value->>'hard_failure')::boolean
                AND coverage_policy_boolean_at(definition_value, ARRAY['replacement', 'hard_failure_exempt']))
            OR routine_replacements_value < routine_replacement_limit_value
        );
    enhanced_research_allowed_value := approved_value
        AND (input_value->>'is_enhanced_risk')::boolean
        AND requested_stage_value = 'research_candidate'
        AND enhanced_gates_pass_value;
    enhanced_live_gate_pass_value := approved_value
        AND (input_value->>'is_enhanced_risk')::boolean
        AND (input_value->>'requested_live')::boolean
        AND (input_value->>'enhanced_live_authorized')::boolean
        AND enhanced_gates_pass_value
        AND (input_value->>'requested_stock')::boolean
        AND NOT (input_value->>'requested_options')::boolean
        AND (
            (
                (input_value->>'enhanced_position_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization'])
                AND (input_value->>'venue_min_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization'])
            )
            OR (
                (input_value->>'enhanced_live_exception_authorized')::boolean
                AND
                (input_value->>'enhanced_position_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization'])
                AND (input_value->>'venue_min_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_venue_min_utilization'])
            )
        )
        AND (input_value->>'enhanced_position_risk')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_risk'])
        AND (input_value->>'enhanced_aggregate_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']);

    IF (input_value->>'has_open_obligation')::boolean THEN
        next_stage_value := 'mandatory_holding';
        decision_state_value := 'retain';
    ELSIF NOT approved_value THEN
        next_stage_value := current_stage_value;
        decision_state_value := 'block';
    ELSIF demotion_required_value AND current_stage_value = 'trade_eligible' THEN
        next_stage_value := 'research_candidate';
        decision_state_value := 'demote';
    ELSIF archive_allowed_value THEN
        next_stage_value := 'archived';
        decision_state_value := 'archive';
    ELSIF promotion_allowed_value THEN
        next_stage_value := 'trade_eligible';
        decision_state_value := 'promote';
    ELSIF admission_allowed_value THEN
        next_stage_value := 'research_candidate';
        decision_state_value := 'admit';
    ELSIF replacement_allowed_value THEN
        next_stage_value := current_stage_value;
        decision_state_value := 'replace';
    ELSE
        next_stage_value := current_stage_value;
        decision_state_value := 'block';
    END IF;

    result_value := jsonb_build_object(
        'policy_key', policy_row.policy_key,
        'policy_version', policy_row.version,
        'policy_approved', approved_value,
        'capacity', jsonb_build_object(
            'system_selected_target', target_value,
            'system_selected_ceiling', ceiling_value,
            'system_selected_count', system_selected_count_value,
            'max_trade_eligible', max_trade_eligible_value,
            'trade_eligible_count', trade_eligible_count_value,
            'max_research_candidates', max_research_candidates_value,
            'research_candidate_count', research_candidate_count_value,
            'target_reached', system_selected_count_value >= target_value,
            'ceiling_reached', system_selected_count_value >= ceiling_value,
            'automatic_net_new_frozen', system_selected_count_value >= target_value,
            'routine_replacement_limit', routine_replacement_limit_value,
            'options_target_fraction', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']),
            'options_target_met', options_eligible_count_value >= ceil(system_selected_count_value * coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']))
        ),
        'stage', jsonb_build_object(
            'current', current_stage_value,
            'requested', requested_stage_value,
            'next', next_stage_value,
            'admission_allowed', admission_allowed_value,
            'promotion_allowed', promotion_allowed_value,
            'demotion_required', demotion_required_value,
            'archive_allowed', archive_allowed_value,
            'pin_blocks_promotion', (input_value->>'pinned')::boolean,
            'mandatory_holding_preserved', (input_value->>'has_open_obligation')::boolean
        ),
        'capability', jsonb_build_object(
            'requested', requested_capability_value,
            'options_gates_pass', options_gates_pass_value,
            'request_shape_valid', capability_request_valid_value,
            'allowed', approved_value
                AND capability_request_valid_value
                AND (requested_capability_value IN ('stock_eligible', 'none')
                    OR (requested_capability_value IN ('options_eligible', 'both') AND options_gates_pass_value))
        ),
        'replacement', jsonb_build_object(
            'is_replacement', (input_value->>'is_replacement')::boolean,
            'minimum_fitness_delta', coverage_policy_number_at(definition_value, ARRAY['replacement', 'minimum_fitness_delta']),
            'replacement_allowed', replacement_allowed_value,
            'hard_failure_exempt_from_routine_churn', coverage_policy_boolean_at(definition_value, ARRAY['replacement', 'hard_failure_exempt'])
        ),
        'enhanced_risk', jsonb_build_object(
            'research_gates_pass', enhanced_gates_pass_value,
            'research_allowed', enhanced_research_allowed_value,
            'live_gate_pass', enhanced_live_gate_pass_value,
            'live_authority_granted', live_authority_granted_value,
            'live_requires_separate_authorization', true,
            'live_stock_only', coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_stock_only']),
            'live_options_allowed', coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_options_allowed']),
            'live_margin_allowed', coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_margin_allowed']),
            'max_position_utilization', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization']),
            'max_position_risk', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_risk']),
            'max_aggregate_utilization', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']),
            'exception_max_position_utilization', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization'])
        ),
        'fitness_weights', definition_value->'fitness_weights',
        'sector_limits', definition_value->'sector_limits'
    );

    PERFORM set_config('market_mate.coverage_policy_evaluation_write', 'on', true);
    BEGIN
        INSERT INTO coverage_policy_evaluation (
            policy_version_id, subject_key, as_of_at, input, result,
            decision_state, source_lineage, receipt_time, record_environment
        ) VALUES (
            policy_version_id_value, subject_key_value, as_of_value, input_value, result_value,
            decision_state_value, source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.coverage_policy_evaluation_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.coverage_policy_evaluation_write', 'off', true);
    RETURN created;
END;
$$;

CREATE TABLE principal_nominated_candidate (
    nomination_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    security_id uuid NOT NULL REFERENCES security(security_id),
    nominator_kind text NOT NULL CHECK (nominator_kind = 'principal'),
    nominator_key text NOT NULL CHECK (btrim(nominator_key) <> ''),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    nominated_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('principal_nominated_candidate');

CREATE TABLE principal_pin (
    pin_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    overlay_key text NOT NULL CHECK (btrim(overlay_key) <> ''),
    security_id uuid NOT NULL REFERENCES security(security_id),
    nomination_id uuid NOT NULL REFERENCES principal_nominated_candidate(nomination_id),
    universe_version_id uuid NOT NULL REFERENCES coverage_universe_version(universe_version_id),
    policy_version_id uuid NOT NULL REFERENCES coverage_policy_version(policy_version_id),
    profile_resolution_id uuid NOT NULL REFERENCES research_evidence_profile_resolution(resolution_id),
    successor_of uuid REFERENCES principal_pin(pin_id),
    coverage_stage text NOT NULL CHECK (coverage_stage = 'research_candidate'),
    coverage_capability text NOT NULL CHECK (coverage_capability = 'stock_eligible'),
    system_selected boolean NOT NULL CHECK (system_selected = false),
    pinned_from timestamptz NOT NULL,
    review_at timestamptz NOT NULL,
    warning_at timestamptz NOT NULL,
    pin_facts jsonb NOT NULL CHECK (jsonb_typeof(pin_facts) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (review_at > pinned_from),
    CHECK (warning_at >= pinned_from AND warning_at <= review_at),
    CHECK (successor_of IS DISTINCT FROM pin_id)
);

SELECT register_evidence_table('principal_pin');

CREATE TABLE principal_pin_lifecycle (
    transition_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pin_id uuid NOT NULL REFERENCES principal_pin(pin_id),
    from_state text NOT NULL CHECK (from_state IN ('active', 'released', 'expired', 'superseded', 'demoted')),
    to_state text NOT NULL CHECK (to_state IN ('active', 'released', 'expired', 'superseded', 'demoted')),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    policy_evaluation_id uuid REFERENCES coverage_policy_evaluation(evaluation_id),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (from_state <> to_state)
);

SELECT register_evidence_table('principal_pin_lifecycle');

CREATE INDEX principal_pin_overlay_idx
    ON principal_pin (overlay_key, security_id, receipt_time);
CREATE INDEX principal_pin_lifecycle_pin_idx
    ON principal_pin_lifecycle (pin_id, receipt_time);

CREATE FUNCTION guard_principal_nominated_candidate_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'principal_nominated_candidate is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_principal_pin_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'principal_pin is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_principal_pin_lifecycle_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'principal_pin_lifecycle is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER principal_nominated_candidate_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON principal_nominated_candidate
    FOR EACH STATEMENT EXECUTE FUNCTION guard_principal_nominated_candidate_write();
CREATE TRIGGER principal_pin_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON principal_pin
    FOR EACH STATEMENT EXECUTE FUNCTION guard_principal_pin_write();
CREATE TRIGGER principal_pin_lifecycle_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON principal_pin_lifecycle
    FOR EACH STATEMENT EXECUTE FUNCTION guard_principal_pin_lifecycle_write();

CREATE FUNCTION guard_principal_nominated_candidate_insert() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF coalesce(current_setting('market_mate.principal_nomination_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'principal_nominated_candidate writes must go through nominate_principal_candidate'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_principal_pin_insert() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF coalesce(current_setting('market_mate.principal_pin_write', true), '') <> 'on' THEN
        RAISE EXCEPTION 'principal_pin writes must go through pin_principal_overlay'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_principal_pin_lifecycle_insert() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF coalesce(current_setting('market_mate.principal_pin_lifecycle_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'principal_pin_lifecycle writes must go through record_principal_pin_lifecycle'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER principal_nominated_candidate_insert_guard
    BEFORE INSERT ON principal_nominated_candidate
    FOR EACH ROW EXECUTE FUNCTION guard_principal_nominated_candidate_insert();
CREATE TRIGGER principal_pin_insert_guard
    BEFORE INSERT ON principal_pin
    FOR EACH ROW EXECUTE FUNCTION guard_principal_pin_insert();
CREATE TRIGGER principal_pin_lifecycle_insert_guard
    BEFORE INSERT ON principal_pin_lifecycle
    FOR EACH ROW EXECUTE FUNCTION guard_principal_pin_lifecycle_insert();

CREATE FUNCTION principal_pin_transition_is_legal(from_state_value text, to_state_value text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
    SELECT (from_state_value, to_state_value) IN (
        VALUES ('active', 'released'),
               ('active', 'expired'),
               ('active', 'superseded'),
               ('active', 'demoted')
    );
$$;

CREATE FUNCTION principal_pin_current_state_at(
    pin_id_value uuid,
    as_of_value timestamptz
) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
    SELECT CASE
        WHEN p.pin_id IS NULL OR p.receipt_time > as_of_value THEN NULL
        ELSE coalesce(
            (SELECT l.to_state
             FROM principal_pin_lifecycle l
             WHERE l.pin_id = pin_id_value
               AND l.receipt_time <= as_of_value
             ORDER BY l.receipt_time DESC, l.transition_id DESC
             LIMIT 1),
            'active')
    END
    FROM principal_pin p
    WHERE p.pin_id = pin_id_value;
$$;

CREATE FUNCTION principal_pin_current_state(pin_id_value uuid)
RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
    SELECT principal_pin_current_state_at(pin_id_value, clock_timestamp());
$$;

CREATE FUNCTION principal_active_pin_count_at(
    overlay_key_value text,
    as_of_value timestamptz
) RETURNS integer
LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
    SELECT count(*)::integer
    FROM principal_pin p
    WHERE p.overlay_key = overlay_key_value
      AND principal_pin_current_state_at(p.pin_id, as_of_value) = 'active';
$$;

CREATE FUNCTION nominate_principal_candidate(
    security_id_value uuid,
    nominator_key_value text,
    reason_value text,
    source_lineage_value jsonb
) RETURNS principal_nominated_candidate
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    created principal_nominated_candidate%ROWTYPE;
BEGIN
    IF security_id_value IS NULL
       OR coalesce(btrim(nominator_key_value), '') = ''
       OR lower(btrim(nominator_key_value)) = 'principal-pinned-overlay'
       OR coalesce(btrim(reason_value), '') = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'principal nomination arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM security WHERE security_id = security_id_value) THEN
        RAISE EXCEPTION 'nomination security % is not registered', security_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.principal_nomination_write', 'on', true);
    BEGIN
        INSERT INTO principal_nominated_candidate (
            security_id, nominator_kind, nominator_key, reason, nominated_at,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            security_id_value, 'principal', nominator_key_value, reason_value, clock_timestamp(),
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.principal_nomination_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.principal_nomination_write', 'off', true);

    PERFORM append_audit_event(
        'principal-nomination:' || created.nomination_id::text,
        'research.principal_candidate_nominated',
        clock_timestamp(),
        jsonb_build_object(
            'nomination_id', created.nomination_id,
            'security_id', security_id_value,
            'nominator_key', nominator_key_value
        ),
        source_lineage_value, clock_timestamp(), 'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION record_principal_pin_lifecycle(
    pin_id_value uuid,
    to_state_value text,
    reason_value text,
    policy_evaluation_id_value uuid,
    source_lineage_value jsonb
) RETURNS principal_pin_lifecycle
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    pin_row principal_pin%ROWTYPE;
    from_state_value text;
    created principal_pin_lifecycle%ROWTYPE;
BEGIN
    IF pin_id_value IS NULL
       OR to_state_value NOT IN ('released', 'expired', 'superseded', 'demoted')
       OR coalesce(btrim(reason_value), '') = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'principal pin lifecycle arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO pin_row FROM principal_pin WHERE pin_id = pin_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'principal pin % is not registered', pin_id_value
            USING ERRCODE = '22023';
    END IF;
    from_state_value := principal_pin_current_state(pin_id_value);
    IF NOT principal_pin_transition_is_legal(from_state_value, to_state_value) THEN
        RAISE EXCEPTION 'principal pin transition % -> % is illegal',
            from_state_value, to_state_value
            USING ERRCODE = '22023';
    END IF;
    IF to_state_value = 'demoted' AND policy_evaluation_id_value IS NULL THEN
        RAISE EXCEPTION 'safety demotion of a pin requires a coverage policy evaluation'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(pin_id_value::text, 27024));
    PERFORM set_config('market_mate.principal_pin_lifecycle_write', 'on', true);
    BEGIN
        INSERT INTO principal_pin_lifecycle (
            pin_id, from_state, to_state, reason, policy_evaluation_id,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            pin_id_value, from_state_value, to_state_value, reason_value,
            policy_evaluation_id_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.principal_pin_lifecycle_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.principal_pin_lifecycle_write', 'off', true);

    PERFORM append_audit_event(
        'principal-pin-lifecycle:' || created.transition_id::text,
        'research.principal_pin_lifecycle_recorded',
        clock_timestamp(),
        jsonb_build_object(
            'transition_id', created.transition_id,
            'pin_id', pin_id_value,
            'from_state', from_state_value,
            'to_state', to_state_value,
            'policy_evaluation_id', policy_evaluation_id_value
        ),
        source_lineage_value, clock_timestamp(), 'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION pin_principal_overlay(
    nomination_id_value uuid,
    universe_version_id_value uuid,
    overlay_key_value text,
    pinned_from_value timestamptz,
    successor_of_value uuid,
    source_lineage_value jsonb
) RETURNS principal_pin
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    nomination_row principal_nominated_candidate%ROWTYPE;
    universe_row coverage_universe_version%ROWTYPE;
    policy_row coverage_policy_version%ROWTYPE;
    predecessor principal_pin%ROWTYPE;
    created principal_pin%ROWTYPE;
    resolution_row research_evidence_profile_resolution%ROWTYPE;
    overlay_max integer;
    review_days integer;
    warning_days integer;
    review_at_value timestamptz;
    warning_at_value timestamptz;
    active_count integer;
BEGIN
    IF nomination_id_value IS NULL
       OR universe_version_id_value IS NULL
       OR coalesce(btrim(overlay_key_value), '') = ''
       OR pinned_from_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'principal pin arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO nomination_row
    FROM principal_nominated_candidate WHERE nomination_id = nomination_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'principal nomination % is not registered', nomination_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO universe_row
    FROM coverage_universe_version WHERE universe_version_id = universe_version_id_value;
    IF NOT FOUND OR universe_row.admission_state <> 'complete' THEN
        RAISE EXCEPTION 'principal pin requires a complete coverage universe version'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO policy_row
    FROM coverage_policy_version WHERE policy_version_id = universe_row.policy_version_id;
    IF NOT EXISTS (
        SELECT 1 FROM coverage_policy_approval
        WHERE policy_version_id = policy_row.policy_version_id
          AND approved_at <= pinned_from_value
    ) THEN
        RAISE EXCEPTION 'principal pin requires Principal approval of the governing policy'
            USING ERRCODE = '55000';
    END IF;
    IF pinned_from_value > clock_timestamp()
       OR pinned_from_value < universe_row.as_of_at THEN
        RAISE EXCEPTION 'principal pin pinned_from is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM coverage_universe_membership m
        WHERE m.universe_version_id = universe_version_id_value
          AND m.security_id = nomination_row.security_id
          AND m.admission_decision = 'admitted'
          AND m.system_selected
    ) THEN
        RAISE EXCEPTION
            'principal-pinned overlay is outside system-selected capacity; this security is already a system-selected member'
            USING ERRCODE = '22023';
    END IF;

    overlay_max := coverage_policy_number_at(
        policy_row.definition, ARRAY['capacity', 'principal_pinned_overlay_max'])::integer;
    review_days := coverage_policy_number_at(
        policy_row.definition, ARRAY['promotion', 'pin_review_days'])::integer;
    warning_days := coverage_policy_number_at(
        policy_row.definition, ARRAY['promotion', 'pin_warning_days'])::integer;
    IF overlay_max < 1 OR review_days < 1 OR warning_days < 0 OR warning_days >= review_days THEN
        RAISE EXCEPTION 'principal pin policy review window is invalid'
            USING ERRCODE = '22023';
    END IF;
    review_at_value := pinned_from_value + make_interval(days => review_days);
    warning_at_value := review_at_value - make_interval(days => warning_days);

    IF successor_of_value IS NOT NULL THEN
        SELECT * INTO predecessor FROM principal_pin WHERE pin_id = successor_of_value;
        IF NOT FOUND
           OR predecessor.overlay_key IS DISTINCT FROM overlay_key_value
           OR predecessor.security_id IS DISTINCT FROM nomination_row.security_id THEN
            RAISE EXCEPTION 'principal pin successor_of must be the same overlay security'
                USING ERRCODE = '22023';
        END IF;
        IF principal_pin_current_state(successor_of_value) <> 'active' THEN
            RAISE EXCEPTION 'only an active pin can be superseded by renewal'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(overlay_key_value, 27023));
    PERFORM pg_advisory_xact_lock(hashtextextended(
        overlay_key_value || ':' || nomination_row.security_id::text, 27025));

    IF EXISTS (
        SELECT 1 FROM principal_pin p
        WHERE p.overlay_key = overlay_key_value
          AND p.security_id = nomination_row.security_id
          AND principal_pin_current_state_at(p.pin_id, clock_timestamp()) = 'active'
          AND (successor_of_value IS NULL OR p.pin_id IS DISTINCT FROM successor_of_value)
    ) THEN
        RAISE EXCEPTION 'security % already has an active principal pin', nomination_row.security_id
            USING ERRCODE = '23505';
    END IF;

    active_count := principal_active_pin_count_at(overlay_key_value, clock_timestamp());
    IF successor_of_value IS NULL AND active_count >= overlay_max THEN
        RAISE EXCEPTION 'principal-pinned overlay is full (% active of % max)',
            active_count, overlay_max
            USING ERRCODE = '55000';
    END IF;

    SELECT * INTO resolution_row
    FROM resolve_research_evidence_profile(
        'research_candidate', 'stock_eligible', 'research',
        pinned_from_value, source_lineage_value);
    IF resolution_row.obligation_count IS NULL OR resolution_row.obligation_count < 1 THEN
        RAISE EXCEPTION 'pinned overlay research obligations did not resolve'
            USING ERRCODE = '55000';
    END IF;

    IF successor_of_value IS NOT NULL THEN
        PERFORM record_principal_pin_lifecycle(
            successor_of_value, 'superseded',
            'renewed with recorded reason', NULL, source_lineage_value);
    END IF;

    PERFORM set_config('market_mate.principal_pin_write', 'on', true);
    BEGIN
        INSERT INTO principal_pin (
            overlay_key, security_id, nomination_id, universe_version_id, policy_version_id,
            profile_resolution_id, successor_of, coverage_stage, coverage_capability,
            system_selected, pinned_from, review_at, warning_at, pin_facts,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            overlay_key_value, nomination_row.security_id, nomination_id_value,
            universe_version_id_value, policy_row.policy_version_id,
            resolution_row.resolution_id, successor_of_value,
            'research_candidate', 'stock_eligible', false,
            pinned_from_value, review_at_value, warning_at_value,
            jsonb_build_object(
                'overlay_max', overlay_max,
                'review_days', review_days,
                'warning_days', warning_days,
                'universe_admitted_count', universe_row.admitted_count,
                'consumes_system_selected_capacity', false
            ),
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.principal_pin_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.principal_pin_write', 'off', true);

    PERFORM append_audit_event(
        'principal-pin:' || created.pin_id::text,
        'research.principal_pin_recorded',
        clock_timestamp(),
        jsonb_build_object(
            'pin_id', created.pin_id,
            'security_id', created.security_id,
            'universe_version_id', universe_version_id_value,
            'system_selected', false,
            'review_at', review_at_value,
            'warning_at', warning_at_value,
            'successor_of', successor_of_value,
            'active_count', principal_active_pin_count_at(overlay_key_value, clock_timestamp()),
            'universe_admitted_count', universe_row.admitted_count
        ),
        source_lineage_value, clock_timestamp(), 'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION release_principal_pin(
    pin_id_value uuid,
    reason_value text,
    source_lineage_value jsonb
) RETURNS principal_pin_lifecycle
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    RETURN record_principal_pin_lifecycle(
        pin_id_value, 'released', reason_value, NULL, source_lineage_value);
END;
$$;

CREATE FUNCTION expire_principal_pin(
    pin_id_value uuid,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS principal_pin_lifecycle
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    pin_row principal_pin%ROWTYPE;
BEGIN
    SELECT * INTO pin_row FROM principal_pin WHERE pin_id = pin_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'principal pin % is not registered', pin_id_value
            USING ERRCODE = '22023';
    END IF;
    IF as_of_value IS NULL OR as_of_value > clock_timestamp() THEN
        RAISE EXCEPTION 'principal pin expiry as_of is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF as_of_value < pin_row.review_at THEN
        RAISE EXCEPTION 'principal pin cannot expire before its review date'
            USING ERRCODE = '22023';
    END IF;
    RETURN record_principal_pin_lifecycle(
        pin_id_value, 'expired', 'review date reached without renewal',
        NULL, source_lineage_value);
END;
$$;

CREATE FUNCTION record_principal_pin_safety_demotion(
    pin_id_value uuid,
    policy_evaluation_id_value uuid,
    reason_value text,
    source_lineage_value jsonb
) RETURNS principal_pin_lifecycle
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    pin_row principal_pin%ROWTYPE;
    evaluation_row coverage_policy_evaluation%ROWTYPE;
BEGIN
    SELECT * INTO pin_row FROM principal_pin WHERE pin_id = pin_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'principal pin % is not registered', pin_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO evaluation_row
    FROM coverage_policy_evaluation WHERE evaluation_id = policy_evaluation_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage policy evaluation % is not registered',
            policy_evaluation_id_value
            USING ERRCODE = '22023';
    END IF;
    IF evaluation_row.subject_key IS DISTINCT FROM pin_row.security_id::text THEN
        RAISE EXCEPTION 'safety demotion evaluation subject does not match the pinned security'
            USING ERRCODE = '22023';
    END IF;
    IF coalesce((evaluation_row.input->>'pinned')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'safety demotion evaluation must be scored as a pinned subject'
            USING ERRCODE = '22023';
    END IF;
    IF coalesce((evaluation_row.result #>> '{stage,demotion_required}')::boolean, false)
       IS NOT TRUE THEN
        RAISE EXCEPTION 'safety demotion requires demotion_required on the evaluation'
            USING ERRCODE = '22023';
    END IF;
    RETURN record_principal_pin_lifecycle(
        pin_id_value, 'demoted', reason_value,
        policy_evaluation_id_value, source_lineage_value);
END;
$$;

REVOKE ALL ON FUNCTION nominate_principal_candidate(uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pin_principal_overlay(uuid, uuid, text, timestamptz, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_principal_pin_lifecycle(uuid, text, text, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION release_principal_pin(uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION expire_principal_pin(uuid, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_principal_pin_safety_demotion(uuid, uuid, text, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON principal_nominated_candidate, principal_pin, principal_pin_lifecycle
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
