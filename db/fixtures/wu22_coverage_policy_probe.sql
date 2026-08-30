-- WU-22 Coverage Policy probe.  The acceptance script runs this inside a
-- caller-managed transaction and rolls all fixture evidence back.

CREATE TEMP TABLE wu22_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
    v_lineage jsonb := '{"source":"wu22-probe","entitlement_version":"coverage-policy-v1"}'::jsonb;
    v_now timestamptz := clock_timestamp();
    v_policy coverage_policy_version%ROWTYPE;
    v_approval coverage_policy_approval%ROWTYPE;
    v_direct_approval_policy coverage_policy_version%ROWTYPE;
    v_evaluation coverage_policy_evaluation%ROWTYPE;
    v_candidate jsonb := $$
    {
      "current_stage": "research_candidate",
      "requested_stage": "trade_eligible",
      "requested_capability": "stock_eligible",
      "system_selected": true,
      "is_new_system_member": false,
      "quality_floor_pass": true,
      "data_gate_pass": true,
      "liquidity_gate_pass": true,
      "diversification_gate_pass": true,
      "unresolved_anomaly": false,
      "pinned": false,
      "has_open_obligation": false,
      "hard_failure": false,
      "is_enhanced_risk": false,
      "is_replacement": false,
      "replacement_resolves_deficiency": false,
      "requested_live": false,
      "requested_stock": true,
      "requested_options": false,
      "enhanced_live_authorized": false,
      "enhanced_live_exception_authorized": false,
      "system_selected_count": 39,
      "options_eligible_count": 24,
      "trade_eligible_count": 24,
      "research_candidate_count": 14,
      "forward_complete_sessions": 20,
      "eligibility_floor_failures": 0,
      "bottom_fitness_sessions": 0,
      "candidate_sessions": 20,
      "fitness_percentile": 0.50,
      "incumbent_fitness": 70,
      "replacement_fitness": 80,
      "routine_replacements_this_month": 0,
      "enhanced_position_utilization": 0,
      "enhanced_position_risk": 0,
      "enhanced_aggregate_utilization": 0,
      "venue_min_utilization": 0,
      "options_gates": {
        "approved_expirations": true,
        "nbbo_quality": true,
        "spreads": true,
        "open_interest_volume": true,
        "lifecycle_metadata": true,
        "defined_risk_execution": true
      },
      "enhanced_risk_gates": {
        "identity": true,
        "reporting": true,
        "authorized_quote": true,
        "liquidity_spread": true,
        "settlement": true,
        "manipulation": true,
        "forward_paper": true
      }
    }
    $$::jsonb;
    v_unapproved coverage_policy_evaluation%ROWTYPE;
    v_unapproved_replacement coverage_policy_evaluation%ROWTYPE;
    v_unapproved_archive coverage_policy_evaluation%ROWTYPE;
    v_unapproved_demotion coverage_policy_evaluation%ROWTYPE;
    v_before_approval coverage_policy_evaluation%ROWTYPE;
    v_admission coverage_policy_evaluation%ROWTYPE;
    v_frozen coverage_policy_evaluation%ROWTYPE;
    v_trade_full coverage_policy_evaluation%ROWTYPE;
    v_research_full coverage_policy_evaluation%ROWTYPE;
    v_mandatory coverage_policy_evaluation%ROWTYPE;
    v_options_allowed coverage_policy_evaluation%ROWTYPE;
    v_options_blocked coverage_policy_evaluation%ROWTYPE;
    v_demotion_promotion_blocked coverage_policy_evaluation%ROWTYPE;
    v_demotion_admission_blocked coverage_policy_evaluation%ROWTYPE;
    v_quality_blocked coverage_policy_evaluation%ROWTYPE;
    v_data_blocked coverage_policy_evaluation%ROWTYPE;
    v_liquidity_blocked coverage_policy_evaluation%ROWTYPE;
    v_diversification_blocked coverage_policy_evaluation%ROWTYPE;
    v_anomaly_blocked coverage_policy_evaluation%ROWTYPE;
    v_forward_blocked coverage_policy_evaluation%ROWTYPE;
    v_demotion coverage_policy_evaluation%ROWTYPE;
    v_floor_demotion coverage_policy_evaluation%ROWTYPE;
    v_bottom_demotion coverage_policy_evaluation%ROWTYPE;
    v_archive coverage_policy_evaluation%ROWTYPE;
    v_pinned_archive coverage_policy_evaluation%ROWTYPE;
    v_replacement coverage_policy_evaluation%ROWTYPE;
    v_weak_replacement coverage_policy_evaluation%ROWTYPE;
    v_enhanced coverage_policy_evaluation%ROWTYPE;
    v_enhanced_blocked coverage_policy_evaluation%ROWTYPE;
    v_enhanced_live coverage_policy_evaluation%ROWTYPE;
    v_enhanced_live_input jsonb;
    v_live_position_blocked coverage_policy_evaluation%ROWTYPE;
    v_live_risk_blocked coverage_policy_evaluation%ROWTYPE;
    v_live_aggregate_blocked coverage_policy_evaluation%ROWTYPE;
    v_live_venue_blocked coverage_policy_evaluation%ROWTYPE;
    v_live_exception coverage_policy_evaluation%ROWTYPE;
    v_results jsonb;
    v_direct_insert_blocked boolean := false;
    v_direct_update_blocked boolean := false;
    v_direct_delete_blocked boolean := false;
    v_direct_truncate_blocked boolean := false;
    v_approval_insert_blocked boolean := false;
    v_evaluation_insert_blocked boolean := false;
    v_self_approval_blocked boolean := false;
    v_policy_actor_approval_blocked boolean := false;
    v_invalid_definition_blocked boolean := false;
    v_invalid_version_blocked boolean := false;
    v_invalid_stage_blocked boolean := false;
    v_negative_input_blocked boolean := false;
    v_future_as_of_blocked boolean := false;
    v_before_effective_blocked boolean := false;
    v_wrong_type_input_blocked boolean := false;
    v_large_input_blocked boolean := false;
    v_policy_definition_valid boolean;
BEGIN
    SELECT * INTO v_policy
    FROM coverage_policy_version
    WHERE policy_key = 'coverage-policy' AND version = 1;
    v_policy_definition_valid := coverage_policy_definition_is_valid(v_policy.definition);
    IF v_policy.policy_version_id IS NULL OR NOT v_policy_definition_valid THEN
        RAISE EXCEPTION 'baseline coverage policy version is unavailable or invalid';
    END IF;

    SELECT * INTO v_unapproved FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-unapproved', v_now, v_candidate, v_lineage
    );
    SELECT * INTO v_unapproved_replacement FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-unapproved-replacement', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{is_replacement}', 'true'::jsonb), '{replacement_fitness}', '81'::jsonb), '{incumbent_fitness}', '70'::jsonb), '{routine_replacements_this_month}', '3'::jsonb),
        v_lineage
    );
    SELECT * INTO v_unapproved_archive FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-unapproved-archive', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"research_candidate"'::jsonb), '{requested_stage}', '"archived"'::jsonb), '{candidate_sessions}', '60'::jsonb),
        v_lineage
    );
    SELECT * INTO v_unapproved_demotion FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-unapproved-demotion', v_now,
        jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{hard_failure}', 'true'::jsonb),
        v_lineage
    );

    BEGIN
        PERFORM record_coverage_policy_approval(
            v_policy.policy_version_id, 'principal', 'coverage-policy', v_lineage
        );
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_self_approval_blocked := true;
    END;
    IF current_setting('market_mate.coverage_policy_approval_write', true) = 'on' THEN
        RAISE EXCEPTION 'approval write flag remained armed after rejected self approval';
    END IF;

    SELECT * INTO v_approval FROM record_coverage_policy_approval(
        v_policy.policy_version_id, 'principal', 'principal-wu22', v_lineage
    );
    SELECT * INTO v_before_approval FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-before-approval', v_approval.approved_at - interval '1 second',
        v_candidate, v_lineage
    );
    v_now := clock_timestamp();
    SELECT * INTO v_evaluation FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion', v_now, v_candidate, v_lineage
    );

    SELECT * INTO v_admission FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-admission', v_now,
        jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb),
        v_lineage
    );
    SELECT * INTO v_frozen FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-capacity-frozen', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{system_selected_count}', '40'::jsonb), '{is_new_system_member}', 'true'::jsonb),
        v_lineage
    );
    SELECT * INTO v_trade_full FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-trade-stage-full', v_now,
        jsonb_set(v_candidate, '{trade_eligible_count}', '25'::jsonb), v_lineage
    );
    SELECT * INTO v_research_full FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-research-stage-full', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{research_candidate_count}', '15'::jsonb),
        v_lineage
    );
    SELECT * INTO v_mandatory FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-mandatory-holding', v_now,
        jsonb_set(jsonb_set(v_candidate, '{has_open_obligation}', 'true'::jsonb), '{current_stage}', '"trade_eligible"'::jsonb),
        v_lineage
    );

    SELECT * INTO v_options_allowed FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-options-gate-pass', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{requested_capability}', '"options_eligible"'::jsonb), '{requested_stock}', 'false'::jsonb), '{requested_options}', 'true'::jsonb),
        v_lineage
    );
    SELECT * INTO v_options_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-options-gate', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{requested_capability}', '"options_eligible"'::jsonb), '{requested_stock}', 'false'::jsonb), '{requested_options}', 'true'::jsonb)
            || jsonb_build_object('options_gates', jsonb_build_object(
                'approved_expirations', false, 'nbbo_quality', true, 'spreads', true,
                'open_interest_volume', true, 'lifecycle_metadata', true, 'defined_risk_execution', true
            )),
        v_lineage
    );
    SELECT * INTO v_demotion_promotion_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-demotion-blocks-promotion', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{eligibility_floor_failures}', '3'::jsonb), '{hard_failure}', 'false'::jsonb), '{fitness_percentile}', '0.50'::jsonb),
        v_lineage
    );
    SELECT * INTO v_demotion_admission_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-demotion-blocks-admission', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{eligibility_floor_failures}', '3'::jsonb), '{hard_failure}', 'false'::jsonb),
        v_lineage
    );
    SELECT * INTO v_quality_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion-quality-failure', v_now,
        jsonb_set(v_candidate, '{quality_floor_pass}', 'false'::jsonb), v_lineage
    );
    SELECT * INTO v_data_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion-data-failure', v_now,
        jsonb_set(v_candidate, '{data_gate_pass}', 'false'::jsonb), v_lineage
    );
    SELECT * INTO v_liquidity_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion-liquidity-failure', v_now,
        jsonb_set(v_candidate, '{liquidity_gate_pass}', 'false'::jsonb), v_lineage
    );
    SELECT * INTO v_diversification_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion-diversification-failure', v_now,
        jsonb_set(v_candidate, '{diversification_gate_pass}', 'false'::jsonb), v_lineage
    );
    SELECT * INTO v_anomaly_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion-anomaly', v_now,
        jsonb_set(v_candidate, '{unresolved_anomaly}', 'true'::jsonb), v_lineage
    );
    SELECT * INTO v_forward_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-promotion-forward-failure', v_now,
        jsonb_set(v_candidate, '{forward_complete_sessions}', '19'::jsonb), v_lineage
    );
    SELECT * INTO v_demotion FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-hard-failure', v_now,
        jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{hard_failure}', 'true'::jsonb),
        v_lineage
    );
    SELECT * INTO v_floor_demotion FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-floor-failure', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{eligibility_floor_failures}', '3'::jsonb), '{hard_failure}', 'false'::jsonb),
        v_lineage
    );
    SELECT * INTO v_bottom_demotion FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-bottom-fitness', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{bottom_fitness_sessions}', '10'::jsonb), '{fitness_percentile}', '0.10'::jsonb), '{hard_failure}', 'false'::jsonb),
        v_lineage
    );
    SELECT * INTO v_archive FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-archive', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"research_candidate"'::jsonb), '{requested_stage}', '"archived"'::jsonb), '{candidate_sessions}', '60'::jsonb),
        v_lineage
    );
    SELECT * INTO v_pinned_archive FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-pinned-retained', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"research_candidate"'::jsonb), '{requested_stage}', '"archived"'::jsonb), '{candidate_sessions}', '60'::jsonb), '{pinned}', 'true'::jsonb),
        v_lineage
    );

    SELECT * INTO v_replacement FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-replacement', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{is_replacement}', 'true'::jsonb), '{replacement_fitness}', '81'::jsonb), '{incumbent_fitness}', '70'::jsonb), '{routine_replacements_this_month}', '3'::jsonb),
        v_lineage
    );
    SELECT * INTO v_weak_replacement FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-weak-replacement', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"trade_eligible"'::jsonb), '{is_replacement}', 'true'::jsonb), '{replacement_fitness}', '75'::jsonb), '{incumbent_fitness}', '70'::jsonb), '{replacement_resolves_deficiency}', 'false'::jsonb),
        v_lineage
    );

    SELECT * INTO v_enhanced FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-enhanced-research', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{is_enhanced_risk}', 'true'::jsonb),
        v_lineage
    );
    SELECT * INTO v_enhanced_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-enhanced-gate-failure', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{is_enhanced_risk}', 'true'::jsonb)
            || jsonb_build_object('enhanced_risk_gates', jsonb_build_object(
                'identity', true, 'reporting', true, 'authorized_quote', false,
                'liquidity_spread', true, 'settlement', true, 'manipulation', true, 'forward_paper', true
            )),
        v_lineage
    );
    SELECT * INTO v_enhanced_live FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-enhanced-live-boundary', v_now,
        jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{is_enhanced_risk}', 'true'::jsonb), '{requested_live}', 'true'::jsonb), '{enhanced_live_authorized}', 'true'::jsonb),
        v_lineage
    );
    v_enhanced_live_input := jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate, '{current_stage}', '"discovery_pool"'::jsonb), '{requested_stage}', '"research_candidate"'::jsonb), '{is_enhanced_risk}', 'true'::jsonb), '{requested_live}', 'true'::jsonb), '{enhanced_live_authorized}', 'true'::jsonb);
    SELECT * INTO v_live_position_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-live-position-limit', v_now,
        jsonb_set(v_enhanced_live_input, '{enhanced_position_utilization}', '0.0101'::jsonb), v_lineage
    );
    SELECT * INTO v_live_risk_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-live-risk-limit', v_now,
        jsonb_set(v_enhanced_live_input, '{enhanced_position_risk}', '0.0051'::jsonb), v_lineage
    );
    SELECT * INTO v_live_aggregate_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-live-aggregate-limit', v_now,
        jsonb_set(v_enhanced_live_input, '{enhanced_aggregate_utilization}', '0.0301'::jsonb), v_lineage
    );
    SELECT * INTO v_live_venue_blocked FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-live-venue-limit', v_now,
        jsonb_set(v_enhanced_live_input, '{venue_min_utilization}', '0.0201'::jsonb), v_lineage
    );
    SELECT * INTO v_live_exception FROM evaluate_coverage_policy(
        v_policy.policy_version_id, 'WU22-live-authorized-exception', v_now,
        jsonb_set(jsonb_set(jsonb_set(v_enhanced_live_input, '{enhanced_live_exception_authorized}', 'true'::jsonb), '{enhanced_position_utilization}', '0.015'::jsonb), '{venue_min_utilization}', '0.015'::jsonb), v_lineage
    );

    BEGIN
        PERFORM evaluate_coverage_policy(
            v_policy.policy_version_id, 'WU22-negative-input', v_now,
            jsonb_set(v_candidate, '{system_selected_count}', '-1'::jsonb), v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_negative_input_blocked := true;
    END;
    BEGIN
        PERFORM evaluate_coverage_policy(
            v_policy.policy_version_id, 'WU22-future-as-of', v_now + interval '1 hour',
            v_candidate, v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_future_as_of_blocked := true;
    END;
    BEGIN
        PERFORM evaluate_coverage_policy(
            v_policy.policy_version_id, 'WU22-before-effective', v_policy.effective_from - interval '1 second',
            v_candidate, v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_before_effective_blocked := true;
    END;
    BEGIN
        PERFORM evaluate_coverage_policy(
            v_policy.policy_version_id, 'WU22-invalid-stage', v_now,
            jsonb_set(v_candidate, '{current_stage}', '"typo_stage"'::jsonb), v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_invalid_stage_blocked := true;
    END;
    BEGIN
        PERFORM evaluate_coverage_policy(
            v_policy.policy_version_id, 'WU22-wrong-type-input', v_now,
            jsonb_set(v_candidate, '{enhanced_live_exception_authorized}', '"true"'::jsonb), v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_wrong_type_input_blocked := true;
    END;
    BEGIN
        PERFORM evaluate_coverage_policy(
            v_policy.policy_version_id, 'WU22-large-input', v_now,
            jsonb_set(v_candidate, '{system_selected_count}', '100000000000000000000'::jsonb), v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_large_input_blocked := true;
    END;

    BEGIN
        PERFORM append_coverage_policy_version(
            'coverage-policy', 3, v_policy.definition, v_now, v_lineage
        );
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_invalid_version_blocked := true;
    END;

    BEGIN
        INSERT INTO coverage_policy_version (
            policy_key, version, definition, definition_digest, effective_from,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            'coverage-policy-direct', 1, v_policy.definition,
            encode(digest(v_policy.definition::text, 'sha256'), 'hex'), v_now,
            v_lineage, v_now, 'local_research'
        );
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_direct_insert_blocked := true;
    END;

    BEGIN
        UPDATE coverage_policy_version
        SET policy_key = 'coverage-policy-mutated'
        WHERE policy_version_id = v_policy.policy_version_id;
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_direct_update_blocked := true;
    END;

    BEGIN
        DELETE FROM coverage_policy_version
        WHERE policy_version_id = v_policy.policy_version_id;
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_direct_delete_blocked := true;
    END;

    BEGIN
        TRUNCATE coverage_policy_evaluation;
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_direct_truncate_blocked := true;
    END;

    SELECT * INTO v_direct_approval_policy FROM append_coverage_policy_version(
        'coverage-policy-direct-approval', 1, v_policy.definition, v_now, v_lineage
    );
    BEGIN
        INSERT INTO coverage_policy_approval (
            policy_version_id, approver_kind, approver_key, approved_at,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            v_direct_approval_policy.policy_version_id, 'principal', 'direct-insert', v_now,
            v_lineage, v_now, 'local_research'
        );
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_approval_insert_blocked := true;
    END;

    BEGIN
        INSERT INTO coverage_policy_evaluation (
            policy_version_id, subject_key, as_of_at, input, result,
            decision_state, source_lineage, receipt_time, record_environment
        ) VALUES (
            v_policy.policy_version_id, 'direct-insert', v_now, v_candidate, v_evaluation.result,
            'block', v_lineage, v_now, 'local_research'
        );
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_evaluation_insert_blocked := true;
    END;

    BEGIN
        PERFORM record_coverage_policy_approval(
            v_policy.policy_version_id, 'policy', 'coverage-policy', v_lineage
        );
    EXCEPTION WHEN SQLSTATE '55000' THEN
        v_policy_actor_approval_blocked := true;
    END;

    BEGIN
        PERFORM append_coverage_policy_version(
            'coverage-policy', 2, '{}'::jsonb, v_now, v_lineage
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_invalid_definition_blocked := true;
    END;

    v_results := jsonb_build_object(
        'policy_version_valid', v_policy_definition_valid,
        'policy_digest_valid', v_policy.definition_digest = encode(digest(v_policy.definition::text, 'sha256'), 'hex'),
        'capacity_40_target_50_ceiling', (v_policy.definition #>> '{capacity,system_selected_target}')::integer = 40
            AND (v_policy.definition #>> '{capacity,system_selected_ceiling}')::integer = 50,
        'capacity_target_freezes_automatic_admission', (v_frozen.result #>> '{capacity,automatic_net_new_frozen}')::boolean
            AND NOT (v_frozen.result #>> '{stage,admission_allowed}')::boolean,
        'capacity_ceiling_is_recorded', (v_policy.definition #>> '{capacity,system_selected_ceiling}')::integer = 50,
        'stages_and_capabilities_encoded', v_policy.definition->'stages' =
            '["discovery_pool","research_candidate","trade_eligible","mandatory_holding","exit_monitoring","archived"]'::jsonb
            AND v_policy.definition->'capabilities' = '["stock_eligible","options_eligible","both","none"]'::jsonb,
        'policy_approval_required', NOT (v_unapproved.result #>> '{stage,promotion_allowed}')::boolean
            AND NOT (v_unapproved.result #>> '{policy_approved}')::boolean
            AND NOT (v_unapproved_replacement.result #>> '{replacement,replacement_allowed}')::boolean
            AND NOT (v_unapproved_archive.result #>> '{stage,archive_allowed}')::boolean
            AND (v_unapproved_demotion.result #>> '{stage,demotion_required}')::boolean
            AND v_unapproved_demotion.decision_state = 'block',
        'approval_before_grant_blocked', NOT (v_before_approval.result #>> '{policy_approved}')::boolean
            AND v_before_approval.decision_state = 'block'
            AND NOT (v_before_approval.result #>> '{stage,promotion_allowed}')::boolean,
        'approval_is_time_bound', v_approval.approved_at <= v_evaluation.as_of_at
            AND (v_evaluation.result #>> '{policy_approved}')::boolean,
        'independent_principal_approval_allows_promotion', v_approval.approver_kind = 'principal'
            AND (v_evaluation.result #>> '{stage,promotion_allowed}')::boolean
            AND v_evaluation.decision_state = 'promote',
        'admission_before_target_allowed', v_admission.decision_state = 'admit'
            AND (v_admission.result #>> '{stage,admission_allowed}')::boolean,
        'mandatory_holding_ignores_capacity', v_mandatory.decision_state = 'retain'
            AND (v_mandatory.result #>> '{stage,mandatory_holding_preserved}')::boolean,
        'stage_capacity_limits_enforced', v_trade_full.decision_state = 'block'
            AND v_research_full.decision_state = 'block',
        'options_capability_gate_blocks', v_options_allowed.decision_state = 'promote'
            AND (v_options_allowed.result #>> '{capability,request_shape_valid}')::boolean
            AND (v_options_allowed.result #>> '{capability,options_gates_pass}')::boolean
            AND v_options_blocked.decision_state = 'block'
            AND NOT (v_options_blocked.result #>> '{capability,options_gates_pass}')::boolean,
        'promotion_gates_fail_closed', v_quality_blocked.decision_state = 'block'
            AND NOT (v_quality_blocked.result #>> '{stage,promotion_allowed}')::boolean
            AND v_data_blocked.decision_state = 'block'
            AND NOT (v_data_blocked.result #>> '{stage,promotion_allowed}')::boolean
            AND v_liquidity_blocked.decision_state = 'block'
            AND NOT (v_liquidity_blocked.result #>> '{stage,promotion_allowed}')::boolean
            AND v_diversification_blocked.decision_state = 'block'
            AND NOT (v_diversification_blocked.result #>> '{stage,promotion_allowed}')::boolean
            AND v_anomaly_blocked.decision_state = 'block'
            AND NOT (v_anomaly_blocked.result #>> '{stage,promotion_allowed}')::boolean
            AND v_forward_blocked.decision_state = 'block'
            AND NOT (v_forward_blocked.result #>> '{stage,promotion_allowed}')::boolean,
        'demotion_blocks_forward_transitions', v_demotion_promotion_blocked.decision_state = 'block'
            AND (v_demotion_promotion_blocked.result #>> '{stage,demotion_required}')::boolean
            AND NOT (v_demotion_promotion_blocked.result #>> '{stage,promotion_allowed}')::boolean
            AND v_demotion_admission_blocked.decision_state = 'block'
            AND (v_demotion_admission_blocked.result #>> '{stage,demotion_required}')::boolean
            AND NOT (v_demotion_admission_blocked.result #>> '{stage,admission_allowed}')::boolean,
        'hard_failure_demotes_immediately', v_demotion.decision_state = 'demote'
            AND (v_demotion.result #>> '{stage,demotion_required}')::boolean
            AND v_demotion.result->'stage'->>'next' = 'research_candidate',
        'three_floor_failures_demote', v_floor_demotion.decision_state = 'demote'
            AND (v_floor_demotion.result #>> '{stage,demotion_required}')::boolean,
        'bottom_fitness_demotes', v_bottom_demotion.decision_state = 'demote'
            AND (v_bottom_demotion.result #>> '{stage,demotion_required}')::boolean,
        'candidate_archive_after_60_sessions', v_archive.decision_state = 'archive'
            AND (v_archive.result #>> '{stage,archive_allowed}')::boolean,
        'principal_pin_prevents_archive', v_pinned_archive.decision_state = 'block'
            AND NOT (v_pinned_archive.result #>> '{stage,archive_allowed}')::boolean,
        'anti_chasing_replacement_gate', v_replacement.decision_state = 'replace'
            AND (v_replacement.result #>> '{replacement,replacement_allowed}')::boolean
            AND NOT (v_weak_replacement.result #>> '{replacement,replacement_allowed}')::boolean,
        'enhanced_risk_research_gates', (v_enhanced.result #>> '{enhanced_risk,research_gates_pass}')::boolean
            AND (v_enhanced.result #>> '{enhanced_risk,research_allowed}')::boolean
            AND NOT (v_enhanced_blocked.result #>> '{enhanced_risk,research_allowed}')::boolean,
        'enhanced_risk_live_limits_encoded', (v_enhanced_live.result #>> '{enhanced_risk,live_gate_pass}')::boolean
            AND NOT (v_enhanced_live.result #>> '{enhanced_risk,live_authority_granted}')::boolean
            AND (v_enhanced_live.result #>> '{enhanced_risk,live_requires_separate_authorization}')::boolean,
        'enhanced_risk_live_boundaries_fail_closed', NOT (v_live_position_blocked.result #>> '{enhanced_risk,live_gate_pass}')::boolean
            AND NOT (v_live_risk_blocked.result #>> '{enhanced_risk,live_gate_pass}')::boolean
            AND NOT (v_live_aggregate_blocked.result #>> '{enhanced_risk,live_gate_pass}')::boolean
            AND NOT (v_live_venue_blocked.result #>> '{enhanced_risk,live_gate_pass}')::boolean
            AND (v_live_exception.result #>> '{enhanced_risk,live_gate_pass}')::boolean
            AND NOT (v_live_exception.result #>> '{enhanced_risk,live_authority_granted}')::boolean,
        'direct_version_insert_blocked', v_direct_insert_blocked,
        'direct_version_update_blocked', v_direct_update_blocked,
        'direct_version_delete_blocked', v_direct_delete_blocked,
        'direct_evaluation_truncate_blocked', v_direct_truncate_blocked,
        'direct_approval_insert_blocked', v_approval_insert_blocked,
        'direct_evaluation_insert_blocked', v_evaluation_insert_blocked,
        'policy_self_approval_blocked', v_self_approval_blocked,
        'policy_actor_approval_blocked', v_policy_actor_approval_blocked,
        'invalid_definition_append_blocked', v_invalid_definition_blocked,
        'invalid_version_append_blocked', v_invalid_version_blocked,
        'invalid_stage_blocked', v_invalid_stage_blocked,
        'negative_input_blocked', v_negative_input_blocked,
        'future_as_of_blocked', v_future_as_of_blocked,
        'before_effective_blocked', v_before_effective_blocked,
        'wrong_type_input_blocked', v_wrong_type_input_blocked,
        'large_input_blocked', v_large_input_blocked,
        'workflow_flags_reset', current_setting('market_mate.coverage_policy_version_write', true) IS DISTINCT FROM 'on'
            AND current_setting('market_mate.coverage_policy_approval_write', true) IS DISTINCT FROM 'on'
            AND current_setting('market_mate.coverage_policy_evaluation_write', true) IS DISTINCT FROM 'on'
    );

    INSERT INTO wu22_probe_result(result) VALUES (v_results);
END;
$probe$;
