-- WU-25 Principal-Pinned Overlay probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu25_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu25-probe","entitlement_version":"licensed-eod-v1"}';
  v_sessions date[] := ARRAY[
    DATE '2026-08-17', DATE '2026-08-18', DATE '2026-08-19',
    DATE '2026-08-20', DATE '2026-08-21'];
  v_run_date date := DATE '2026-08-21';
  v_source_id uuid := '43000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '43000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '43000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '43000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '43000000-0000-0000-0000-000000000501';
  v_contract_v1 uuid := '43000000-0000-0000-0000-000000000502';
  v_field_1 uuid := '43000000-0000-0000-0000-000000000601';
  v_field_2 uuid := '43000000-0000-0000-0000-000000000602';
  v_field_3 uuid := '43000000-0000-0000-0000-000000000603';
  v_connector_id uuid := '43000000-0000-0000-0000-000000000701';
  v_selection eod_vendor_selection%ROWTYPE;
  v_policy coverage_policy_version%ROWTYPE;
  v_config discovery_screen_config_version%ROWTYPE;
  v_screen discovery_screen_run%ROWTYPE;
  v_fitness coverage_fitness_run%ROWTYPE;
  v_universe coverage_universe_version%ROWTYPE;
  v_core indicator_definition_version%ROWTYPE;
  v_mapping instrument_mapping%ROWTYPE;
  v_sys_ids uuid[] := '{}';
  v_sys_issuers uuid[] := '{}';
  v_sys_maps uuid[] := '{}';
  v_pin_ids uuid[] := '{}';
  v_pin_issuers uuid[] := '{}';
  v_noms principal_nominated_candidate[] := '{}';
  v_pins principal_pin[] := '{}';
  v_pin principal_pin%ROWTYPE;
  v_pin6 principal_pin%ROWTYPE;
  v_nom principal_nominated_candidate%ROWTYPE;
  v_life principal_pin_lifecycle%ROWTYPE;
  v_eval_promote coverage_policy_evaluation%ROWTYPE;
  v_eval_pinned_promote coverage_policy_evaluation%ROWTYPE;
  v_eval_archive coverage_policy_evaluation%ROWTYPE;
  v_eval_demote coverage_policy_evaluation%ROWTYPE;
  v_issuer uuid;
  v_sec uuid;
  v_i integer;
  v_s integer;
  v_admitted_before integer;
  v_admitted_after integer;
  v_active_after_five integer;
  v_active_after_demote integer;
  v_sixth_blocked boolean := false;
  v_sixth_after_demote_ok boolean := false;
  v_dup_blocked boolean := false;
  v_sys_pin_blocked boolean := false;
  v_expire_early_blocked boolean := false;
  v_renew_no_reason_blocked boolean := false;
  v_direct_insert_blocked boolean := false;
  v_pin_update_blocked boolean := false;
  v_nom_delete_blocked boolean := false;
  v_revival_blocked boolean := false;
  v_te_blocked boolean := false;
  v_candidate jsonb;
  v_results jsonb;
BEGIN
  v_candidate := $$
    {
      "current_stage": "research_candidate",
      "requested_stage": "trade_eligible",
      "requested_capability": "stock_eligible",
      "system_selected": false,
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
      "system_selected_count": 3,
      "options_eligible_count": 0,
      "trade_eligible_count": 0,
      "research_candidate_count": 3,
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
        "approved_expirations": true, "nbbo_quality": true, "spreads": true,
        "open_interest_volume": true, "lifecycle_metadata": true, "defined_risk_execution": true
      },
      "enhanced_risk_gates": {
        "identity": true, "reporting": true, "authorized_quote": true,
        "liquidity_spread": true, "settlement": true, "manipulation": true, "forward_paper": true
      }
    }
  $$::jsonb;

  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-wu25', 'Licensed EOD WU-25 Provider', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Licensed EOD WU-25 Terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["vendor_observation_key","available_at","received_at"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','source_unavailability','provenance_dispute'],
    '2026-01-01T00:00:00Z', NULL, v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_id, 'licensed-eod-wu25-entitlement', 'local-research-account',
    'WU-25 licensed EOD', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_v1, v_entitlement_id, 1, v_source_v1, 'certified',
    ARRAY['local_research','paper_validation'],
    '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-eod-wu25-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'daily-eod-contract-wu25', 'market', 'WU-25 EOD contract',
    v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_version (
    contract_version_id, contract_id, contract_version, source_registry_version_id,
    effective_from, effective_to, availability_time_rules,
    instrument_identity_rules, provenance_requirements,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_v1, v_contract_id, 1, v_source_v1,
    '2026-01-01T00:00:00Z', NULL,
    '{"as_of_required":true,"receipt_time_required":true,"availability_time_required":true}',
    '{"security_id_required":true,"mapping_must_be_certified":true}',
    '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
    v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_field (
    field_id, contract_version_id, field_key, value_type,
    observation_states, field_semantics, source_lineage, receipt_time, record_environment
  ) VALUES
    (v_field_1, v_contract_v1, 'vendor_observation_key', 'text', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research'),
    (v_field_2, v_contract_v1, 'available_at', 'timestamp', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research'),
    (v_field_3, v_contract_v1, 'received_at', 'timestamp', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research');
  INSERT INTO source_connector (
    connector_id, connector_key, connector_kind,
    source_registry_version_id, contract_version_id, lifecycle,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_connector_id, 'licensed-eod-connector-wu25', 'daily_eod', v_source_v1, v_contract_v1,
    'active', v_lineage, now(), 'local_research'
  );
  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id, source_lineage, receipt_time, record_environment
  ) VALUES
    (v_connector_id, v_contract_v1, v_field_1, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_2, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_3, v_lineage, now(), 'local_research');

  SELECT * INTO v_selection FROM record_eod_vendor_selection(
    'licensed-eod-provider-wu25', v_source_v1, v_entitlement_v1,
    '{"selected":"licensed-eod-provider-wu25","candidates":[{"vendor":"licensed-eod-provider-wu25","license":"written","entitlement":"daily OHLCV","monthly_cost_usd":0}]}'::jsonb,
    '{"status":"written_license"}'::jsonb,
    '{"status":"certified","history_years":10}'::jsonb,
    '{"monthly_cost_usd":0,"annual_budget_usd":0,"within_stage_cap":true}'::jsonb,
    'selected for WU-25 overlay fixture', v_lineage
  );
  SELECT * INTO v_core FROM append_indicator_definition_version(
    'close_return_20d_wu25', 1, 'core',
    '{
      "purpose": "Descriptive 20-session close-to-close return.",
      "units": "fraction", "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "session close", "adjustment_semantics": "split-adjusted",
      "calendar": "NYSE", "missingness": "skip missing sessions",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu25"}],
      "certified_sources": ["licensed-eod-wu25"], "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [{"name": "flat", "expected": 0.0}],
      "canonical_horizons": [1, 20]
    }'::jsonb, NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  FOR v_i IN 1 .. 3 LOOP
    INSERT INTO issuer (legal_name, source_lineage, receipt_time, record_environment)
    VALUES ('WU-25 SYS ' || v_i, v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING issuer_id INTO v_issuer;
    INSERT INTO security (issuer_id, security_class, source_lineage, receipt_time, record_environment)
    VALUES (v_issuer, 'common_stock', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING security_id INTO v_sec;
    INSERT INTO exchange_listing (
      security_id, venue, currency, listing_status, valid_from, valid_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_sec, 'NASDAQ', 'USD', 'active', '2026-01-01T00:00:00Z', NULL,
      v_lineage, '2026-01-01T00:00:00Z', 'local_research'
    );
    INSERT INTO security_symbol_alias (
      security_id, symbol, source, valid_from, valid_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_sec, 'S25' || v_i::text, 'wu25-probe', '2026-01-01T00:00:00Z', NULL,
      v_lineage, '2026-01-01T00:00:00Z', 'local_research'
    );
    v_sys_issuers := v_sys_issuers || v_issuer;
    v_sys_ids := v_sys_ids || v_sec;
  END LOOP;
  FOR v_i IN 1 .. 6 LOOP
    INSERT INTO issuer (legal_name, source_lineage, receipt_time, record_environment)
    VALUES ('WU-25 PIN ' || v_i, v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING issuer_id INTO v_issuer;
    INSERT INTO security (issuer_id, security_class, source_lineage, receipt_time, record_environment)
    VALUES (v_issuer, 'common_stock', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING security_id INTO v_sec;
    v_pin_issuers := v_pin_issuers || v_issuer;
    v_pin_ids := v_pin_ids || v_sec;
  END LOOP;
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  FOR v_i IN 1 .. 3 LOOP
    PERFORM append_issuer_gics_classification(
      v_sys_issuers[v_i], 'information_technology', '2026-01-01T00:00:00Z'::timestamptz, v_lineage);
    v_mapping := propose_instrument_mapping(
      'licensed-eod-wu25', 'WU25-SYS-' || v_i::text, 'security',
      NULL, v_sys_ids[v_i], NULL, '2026-01-01T00:00:00Z', v_lineage);
    v_mapping := transition_instrument_mapping(
      v_mapping.mapping_id, 'corroborated', 'identity check', v_lineage);
    v_mapping := transition_instrument_mapping(
      v_mapping.mapping_id, 'certified', 'WU-25 cert', v_lineage);
    v_sys_maps := v_sys_maps || v_mapping.mapping_id;
    FOR v_s IN 1 .. 5 LOOP
      PERFORM ingest_eod_price_observation(
        v_selection.selection_id, v_sys_maps[v_i],
        'WU25-SYS-' || v_i::text || '-' || v_sessions[v_s]::text,
        v_sessions[v_s], 'complete', 98, 105, 95, 100, 200000,
        v_sessions[v_s]::timestamptz + interval '21 hours',
        jsonb_build_object('close', 100, 'volume', 200000), v_lineage);
    END LOOP;
    PERFORM append_discovery_universe_entry(
      'sp500-wu25', 'index_constituent', v_sys_ids[v_i],
      DATE '2026-01-01', NULL, 'sp500-wu25:sys' || v_i::text, v_lineage);
  END LOOP;

  SELECT * INTO v_policy FROM coverage_policy_version
  WHERE policy_key = 'coverage-policy' AND version = 1;
  PERFORM record_coverage_policy_approval(
    v_policy.policy_version_id, 'principal', 'wu25-probe-principal', v_lineage);
  SELECT * INTO v_config FROM append_discovery_screen_config_version(
    'discovery-screen-wu25', 1, v_policy.policy_version_id,
    '{
      "governing_policy_key": "coverage-policy",
      "lookback_sessions": 5, "min_close_price": 5.00, "penny_price_ceiling": 1.00,
      "min_median_dollar_volume": 5000000,
      "allowed_security_classes": ["common_stock"],
      "ordinary_venues": ["NASDAQ", "NYSE"]
    }'::jsonb, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );
  SELECT * INTO v_screen FROM run_discovery_screen(
    v_config.config_version_id, v_run_date, clock_timestamp(), v_lineage);
  SELECT * INTO v_fitness FROM run_coverage_fitness_score(
    v_policy.policy_version_id, v_screen.run_id, clock_timestamp(), v_lineage);
  SELECT * INTO v_universe FROM run_coverage_universe_first_seed(
    v_fitness.run_id, 'coverage-universe-wu25', 1, v_lineage);
  v_admitted_before := v_universe.admitted_count;

  FOR v_i IN 1 .. 6 LOOP
    v_nom := nominate_principal_candidate(
      v_pin_ids[v_i], 'wu25-principal', 'research request ' || v_i::text, v_lineage);
    v_noms := array_append(v_noms, v_nom);
  END LOOP;
  FOR v_i IN 1 .. 5 LOOP
    v_pin := pin_principal_overlay(
      v_noms[v_i].nomination_id, v_universe.universe_version_id,
      'principal-pinned-overlay', clock_timestamp(), NULL, v_lineage);
    v_pins := array_append(v_pins, v_pin);
  END LOOP;
  v_active_after_five := principal_active_pin_count_at('principal-pinned-overlay', clock_timestamp());
  BEGIN
    v_pin6 := pin_principal_overlay(
      v_noms[6].nomination_id, v_universe.universe_version_id,
      'principal-pinned-overlay', clock_timestamp(), NULL, v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_sixth_blocked := true; END IF;
  END;
  BEGIN
    PERFORM pin_principal_overlay(
      v_noms[1].nomination_id, v_universe.universe_version_id,
      'principal-pinned-overlay', clock_timestamp(), NULL, v_lineage);
  EXCEPTION
    WHEN unique_violation THEN v_dup_blocked := true;
    WHEN others THEN
      IF SQLSTATE = '23505' THEN v_dup_blocked := true; END IF;
  END;
  BEGIN
    v_nom := nominate_principal_candidate(
      v_sys_ids[1], 'wu25-principal', 'cannot pin system-selected', v_lineage);
    PERFORM pin_principal_overlay(
      v_nom.nomination_id, v_universe.universe_version_id,
      'principal-pinned-overlay', clock_timestamp(), NULL, v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '22023' THEN v_sys_pin_blocked := true; END IF;
  END;

  SELECT admitted_count INTO v_admitted_after
  FROM coverage_universe_version WHERE universe_version_id = v_universe.universe_version_id;

  SELECT * INTO v_eval_promote FROM evaluate_coverage_policy(
    v_policy.policy_version_id, v_pins[1].security_id::text, clock_timestamp(),
    v_candidate, v_lineage);
  SELECT * INTO v_eval_pinned_promote FROM evaluate_coverage_policy(
    v_policy.policy_version_id, v_pins[1].security_id::text, clock_timestamp(),
    jsonb_set(v_candidate, '{pinned}', 'true'::jsonb), v_lineage);
  SELECT * INTO v_eval_archive FROM evaluate_coverage_policy(
    v_policy.policy_version_id, v_pins[1].security_id::text, clock_timestamp(),
    jsonb_set(jsonb_set(jsonb_set(v_candidate, '{pinned}', 'true'::jsonb),
                        '{requested_stage}', '"archived"'::jsonb),
              '{candidate_sessions}', '60'::jsonb),
    v_lineage);
  SELECT * INTO v_eval_demote FROM evaluate_coverage_policy(
    v_policy.policy_version_id, v_pins[2].security_id::text, clock_timestamp(),
    jsonb_set(jsonb_set(jsonb_set(v_candidate, '{pinned}', 'true'::jsonb),
                        '{hard_failure}', 'true'::jsonb),
              '{current_stage}', '"trade_eligible"'::jsonb),
    v_lineage);
  v_life := record_principal_pin_safety_demotion(
    v_pins[2].pin_id, v_eval_demote.evaluation_id,
    'hard identity failure; pin cannot retain', v_lineage);
  v_active_after_demote := principal_active_pin_count_at('principal-pinned-overlay', clock_timestamp());
  BEGIN
    v_pin6 := pin_principal_overlay(
      v_noms[6].nomination_id, v_universe.universe_version_id,
      'principal-pinned-overlay', clock_timestamp(), NULL, v_lineage);
    v_sixth_after_demote_ok := v_pin6.pin_id IS NOT NULL
      AND principal_pin_current_state(v_pin6.pin_id) = 'active';
  EXCEPTION
    WHEN others THEN
      v_sixth_after_demote_ok := false;
  END;

  BEGIN
    PERFORM expire_principal_pin(v_pins[3].pin_id, clock_timestamp(), v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '22023' THEN v_expire_early_blocked := true; END IF;
  END;
  BEGIN
    PERFORM nominate_principal_candidate(
      v_pin_ids[3], 'wu25-principal', '', v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '22023' THEN v_renew_no_reason_blocked := true; END IF;
  END;
  v_nom := nominate_principal_candidate(
    v_pin_ids[3], 'wu25-principal', 'renew pin 3 with recorded reason', v_lineage);
  v_pin := pin_principal_overlay(
    v_nom.nomination_id, v_universe.universe_version_id,
    'principal-pinned-overlay', clock_timestamp(), v_pins[3].pin_id, v_lineage);

  BEGIN
    PERFORM record_principal_pin_lifecycle(
      v_pins[2].pin_id, 'active', 'cannot revive after demotion', NULL, v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '22023' THEN v_revival_blocked := true; END IF;
  END;
  BEGIN
    UPDATE principal_pin SET coverage_stage = 'trade_eligible' WHERE pin_id = v_pins[1].pin_id;
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE IN ('55000', '23514') THEN v_te_blocked := true; END IF;
  END;
  BEGIN
    INSERT INTO principal_pin (
      overlay_key, security_id, nomination_id, universe_version_id, policy_version_id,
      profile_resolution_id, coverage_stage, coverage_capability, system_selected,
      pinned_from, review_at, warning_at, pin_facts,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'principal-pinned-overlay', v_pin_ids[6], v_noms[6].nomination_id,
      v_universe.universe_version_id, v_policy.policy_version_id,
      v_pins[1].profile_resolution_id, 'research_candidate', 'stock_eligible', false,
      clock_timestamp(), clock_timestamp() + interval '30 days',
      clock_timestamp() + interval '23 days', '{}'::jsonb,
      v_lineage, clock_timestamp(), 'local_research'
    );
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_direct_insert_blocked := true; END IF;
  END;
  BEGIN
    UPDATE principal_pin SET review_at = review_at WHERE pin_id = v_pins[1].pin_id;
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_pin_update_blocked := true; END IF;
  END;
  BEGIN
    DELETE FROM principal_nominated_candidate WHERE nomination_id = v_noms[1].nomination_id;
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_nom_delete_blocked := true; END IF;
  END;

  v_results := jsonb_build_object(
    'universe_seeded', v_universe.admission_state = 'complete' AND v_admitted_before = 3,
    'nominations_recorded', (
      SELECT count(*) FROM principal_nominated_candidate
      WHERE nominator_key = 'wu25-principal') >= 6,
    'five_active_pins', v_active_after_five = 5,
    'pins_are_research_candidates', NOT EXISTS (
      SELECT 1 FROM principal_pin p
      WHERE p.universe_version_id = v_universe.universe_version_id
        AND p.coverage_stage <> 'research_candidate'),
    'pins_not_system_selected', NOT EXISTS (
      SELECT 1 FROM principal_pin p
      WHERE p.universe_version_id = v_universe.universe_version_id
        AND p.system_selected),
    'overlay_does_not_consume_capacity',
      v_admitted_after = v_admitted_before
      AND v_admitted_after = 3
      AND (v_pins[1].pin_facts->>'consumes_system_selected_capacity')::boolean IS NOT TRUE,
    'review_at_is_30_days',
      v_pins[1].review_at = v_pins[1].pinned_from + interval '30 days',
    'warning_is_7_days_before_review',
      v_pins[1].warning_at = v_pins[1].review_at - interval '7 days',
    'obligations_active', EXISTS (
      SELECT 1 FROM research_evidence_profile_resolution r
      WHERE r.resolution_id = v_pins[1].profile_resolution_id
        AND r.coverage_stage = 'research_candidate'
        AND r.obligation_count > 0),
    'sixth_pin_blocked', v_sixth_blocked,
    'demotion_frees_overlay_slot', v_active_after_demote = 4 AND v_sixth_after_demote_ok,
    'duplicate_active_pin_blocked', v_dup_blocked,
    'system_selected_pin_blocked', v_sys_pin_blocked,
    'unpinned_promotion_still_allowed',
      v_eval_promote.decision_state = 'promote'
      AND (v_eval_promote.result #>> '{stage,promotion_allowed}')::boolean,
    'pin_blocks_promotion',
      v_eval_pinned_promote.decision_state = 'block'
      AND (v_eval_pinned_promote.result #>> '{stage,promotion_allowed}') IS DISTINCT FROM 'true'
      AND (v_eval_pinned_promote.result #>> '{stage,pin_blocks_promotion}')::boolean,
    'pin_prevents_archive',
      v_eval_archive.decision_state = 'block'
      AND (v_eval_archive.result #>> '{stage,archive_allowed}') IS DISTINCT FROM 'true',
    'pin_cannot_block_safety_demotion',
      v_eval_demote.decision_state = 'demote'
      AND (v_eval_demote.result #>> '{stage,demotion_required}')::boolean
      AND principal_pin_current_state(v_pins[2].pin_id) = 'demoted',
    'demoted_pin_not_active',
      principal_pin_current_state_at(v_pins[2].pin_id, clock_timestamp()) = 'demoted',
    'renewal_reason_required', v_renew_no_reason_blocked,
    'expire_before_review_blocked', v_expire_early_blocked,
    'renewal_supersedes',
      principal_pin_current_state(v_pins[3].pin_id) = 'superseded'
      AND v_pin.successor_of = v_pins[3].pin_id
      AND principal_pin_current_state(v_pin.pin_id) = 'active',
    'revival_blocked', v_revival_blocked,
    'trade_eligible_write_blocked', v_te_blocked,
    'direct_insert_blocked', v_direct_insert_blocked,
    'pin_update_blocked', v_pin_update_blocked,
    'nomination_delete_blocked', v_nom_delete_blocked,
    'pin_audited', EXISTS (
      SELECT 1 FROM audit_event
      WHERE event_type = 'research.principal_pin_recorded'
        AND payload->>'pin_id' = v_pins[1].pin_id::text),
    'demotion_audited', EXISTS (
      SELECT 1 FROM audit_event
      WHERE event_type = 'research.principal_pin_lifecycle_recorded'
        AND payload->>'pin_id' = v_pins[2].pin_id::text
        AND payload->>'to_state' = 'demoted'),
    'late_demotion_invisible_before_receipt',
      principal_pin_current_state_at(v_pins[2].pin_id, v_pins[2].receipt_time) = 'active'
  );

  INSERT INTO wu25_probe_result VALUES (v_results);
END;
$probe$;
