-- WU-24 Coverage Fitness + first-seed probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu24_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '42000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '42000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '42000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '42000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '42000000-0000-0000-0000-000000000501';
  v_contract_v1 uuid := '42000000-0000-0000-0000-000000000502';
  v_field_1 uuid := '42000000-0000-0000-0000-000000000601';
  v_field_2 uuid := '42000000-0000-0000-0000-000000000602';
  v_field_3 uuid := '42000000-0000-0000-0000-000000000603';
  v_connector_id uuid := '42000000-0000-0000-0000-000000000701';
  v_lineage jsonb := '{"source":"wu24-probe","entitlement_version":"licensed-eod-v1"}';
  v_sessions date[] := ARRAY[
    DATE '2026-08-17', DATE '2026-08-18', DATE '2026-08-19',
    DATE '2026-08-20', DATE '2026-08-21'];
  v_run_date date := DATE '2026-08-21';
  v_as_of timestamptz;
  v_selection eod_vendor_selection%ROWTYPE;
  v_config discovery_screen_config_version%ROWTYPE;
  v_empty_config discovery_screen_config_version%ROWTYPE;
  v_policy coverage_policy_version%ROWTYPE;
  v_policy_v2 coverage_policy_version%ROWTYPE;
  v_approval coverage_policy_approval%ROWTYPE;
  v_screen discovery_screen_run%ROWTYPE;
  v_empty_screen discovery_screen_run%ROWTYPE;
  v_fitness coverage_fitness_run%ROWTYPE;
  v_fitness_v2 coverage_fitness_run%ROWTYPE;
  v_empty_fitness coverage_fitness_run%ROWTYPE;
  v_universe coverage_universe_version%ROWTYPE;
  v_failed_universe coverage_universe_version%ROWTYPE;
  v_core indicator_definition_version%ROWTYPE;
  v_experimental indicator_definition_version%ROWTYPE;
  v_mapping instrument_mapping%ROWTYPE;
  v_issuer_id uuid;
  v_security_id uuid;
  v_labels text[];
  v_sectors text[];
  v_venues text[];
  v_security_ids uuid[] := '{}';
  v_issuer_ids uuid[] := '{}';
  v_mapping_ids uuid[] := '{}';
  v_i integer;
  v_s integer;
  v_close numeric;
  v_volume bigint;
  v_twin_flat_id uuid;
  v_twin_rally_id uuid;
  v_nogics_late_id uuid;
  v_otc_id uuid;
  v_flat_fitness numeric;
  v_rally_fitness numeric;
  v_replay record;
  v_replay_matches boolean := true;
  v_seed_replay record;
  v_seed_replay_matches boolean := true;
  v_late_preview record;
  v_resolution research_evidence_profile_resolution%ROWTYPE;
  v_results jsonb;
  v_direct_gics_blocked boolean := false;
  v_direct_fitness_blocked boolean := false;
  v_fitness_update_blocked boolean := false;
  v_universe_delete_blocked boolean := false;
  v_membership_truncate_blocked boolean := false;
  v_invalid_gics_blocked boolean := false;
  v_future_as_of_blocked boolean := false;
  v_duplicate_fitness_blocked boolean := false;
  v_duplicate_seed_blocked boolean := false;
  v_predictive_absent boolean;
BEGIN
  -- 25 tech (ceiling probe) + 20 mixed + 2 missing-GICS + 1 OTC enhanced-risk.
  v_labels := ARRAY[
    'tech_01','tech_02','tech_03','tech_04','tech_05',
    'tech_06','tech_07','tech_08','tech_09','tech_10',
    'tech_11','tech_12','tech_13','tech_14','tech_15',
    'tech_16','tech_17','tech_18','tech_19','tech_20',
    'tech_21','tech_22','tech_23','tech_24','tech_25',
    'energy_01','energy_02','energy_03','energy_04','energy_05','energy_06',
    'health_01','health_02','health_03','health_04',
    'ind_01','ind_02','ind_03',
    'disc_01','disc_02','stap_01','stap_02','util_01',
    'twin_flat','twin_rally',
    'nogics_a','nogics_late','otc_enh'];
  v_sectors := ARRAY[
    'information_technology','information_technology','information_technology','information_technology','information_technology',
    'information_technology','information_technology','information_technology','information_technology','information_technology',
    'information_technology','information_technology','information_technology','information_technology','information_technology',
    'information_technology','information_technology','information_technology','information_technology','information_technology',
    'information_technology','information_technology','information_technology','information_technology','information_technology',
    'energy','energy','energy','energy','energy','energy',
    'health_care','health_care','health_care','health_care',
    'industrials','industrials','industrials',
    'consumer_discretionary','consumer_discretionary','consumer_staples','consumer_staples','utilities',
    'financials','financials',
    NULL, NULL, 'financials'];
  v_venues := ARRAY[
    'NASDAQ','NASDAQ','NASDAQ','NASDAQ','NASDAQ',
    'NASDAQ','NASDAQ','NASDAQ','NASDAQ','NASDAQ',
    'NASDAQ','NASDAQ','NASDAQ','NASDAQ','NASDAQ',
    'NYSE','NYSE','NYSE','NYSE','NYSE',
    'NASDAQ','NASDAQ','NASDAQ','NASDAQ','NASDAQ',
    'NYSE','NYSE','NYSE','NYSE','NYSE','NYSE',
    'NASDAQ','NASDAQ','NASDAQ','NASDAQ',
    'NYSE','NYSE','NYSE',
    'NASDAQ','NASDAQ','NYSE','NYSE','NYSE',
    'NASDAQ','NASDAQ',
    'NASDAQ','NASDAQ','OTCMKTS'];

  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-wu24', 'Licensed EOD WU-24 Provider', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Licensed EOD WU-24 Terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["vendor_observation_key","available_at","received_at"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','source_unavailability','provenance_dispute'],
    '2026-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_id, 'licensed-eod-wu24-entitlement', 'local-research-account',
    'Licensed daily EOD access for the WU-24 scorer', v_lineage,
    '2026-01-01T00:00:00Z', 'local_research'
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
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-eod-wu24-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'daily-eod-contract-wu24', 'market',
    'Point-in-time licensed daily market delivery contract for WU-24',
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
    (v_field_1, v_contract_v1, 'vendor_observation_key', 'text', ARRAY['current','stale','missing'], '{"required":true}'::jsonb, v_lineage, now(), 'local_research'),
    (v_field_2, v_contract_v1, 'available_at', 'timestamp', ARRAY['current','stale','missing'], '{"required":true,"as_of":"point_in_time"}'::jsonb, v_lineage, now(), 'local_research'),
    (v_field_3, v_contract_v1, 'received_at', 'timestamp', ARRAY['current'], '{"required":true}'::jsonb, v_lineage, now(), 'local_research');
  INSERT INTO source_connector (
    connector_id, connector_key, connector_kind,
    source_registry_version_id, contract_version_id, lifecycle,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_connector_id, 'licensed-eod-connector-wu24', 'daily_eod', v_source_v1, v_contract_v1,
    'active', v_lineage, now(), 'local_research'
  );
  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id,
    source_lineage, receipt_time, record_environment
  ) VALUES
    (v_connector_id, v_contract_v1, v_field_1, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_2, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_3, v_lineage, now(), 'local_research');

  SELECT * INTO v_selection FROM record_eod_vendor_selection(
    'licensed-eod-provider-wu24', v_source_v1, v_entitlement_v1,
    '{"selected":"licensed-eod-provider-wu24","candidates":[{"vendor":"licensed-eod-provider-wu24","license":"written research license","entitlement":"daily historical OHLCV","monthly_cost_usd":0}]}'::jsonb,
    '{"status":"written_license","raw_retention":"permitted","derived_use":"permitted"}'::jsonb,
    '{"status":"certified","history_years":10,"purposes":["local_research","paper_validation"]}'::jsonb,
    '{"monthly_cost_usd":0,"annual_budget_usd":0,"within_stage_cap":true}'::jsonb,
    'selected after license, entitlement, coverage, and cost comparison', v_lineage
  );

  SELECT * INTO v_core FROM append_indicator_definition_version(
    'close_return_20d_wu24', 1, 'core',
    '{
      "purpose": "Descriptive 20-session close-to-close return for research context; never a universal alpha signal.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped; a horizon shorter than 20 complete sessions yields no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu24"}],
      "certified_sources": ["licensed-eod-wu24"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [{"name": "flat_series", "inputs": {"close": [100, 100, 100]}, "expected": 0.0}],
      "canonical_horizons": [1, 20]
    }'::jsonb,
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );
  SELECT * INTO v_experimental FROM append_indicator_definition_version(
    'experimental_gap_bias_wu24', 1, 'experimental',
    '{
      "purpose": "Preregistered predictive hypothesis excluded from Core observability.",
      "units": "fraction",
      "formula": "mean(gap_return | earnings flag)",
      "timestamp_semantics": "event-time anchored to announcement receipt",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions with earnings events",
      "missingness": "events without as-of provenance yield no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu24"}],
      "certified_sources": ["licensed-eod-wu24"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 2},
      "valid_ranges": {"min": -1.0, "max": 1.0},
      "golden_cases": [{"name": "no_events", "inputs": {"earnings_flag": []}, "expected": null}],
      "canonical_horizons": [5, 20]
    }'::jsonb,
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  FOR v_i IN 1 .. array_length(v_labels, 1) LOOP
    INSERT INTO issuer (legal_name, source_lineage, receipt_time, record_environment)
    VALUES ('WU-24 ' || v_labels[v_i] || ' Issuer, Inc.', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING issuer_id INTO v_issuer_id;
    INSERT INTO security (issuer_id, security_class, source_lineage, receipt_time, record_environment)
    VALUES (v_issuer_id, 'common_stock', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING security_id INTO v_security_id;
    INSERT INTO exchange_listing (
      security_id, venue, currency, listing_status, valid_from, valid_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_security_id, v_venues[v_i], 'USD', 'active',
      '2026-01-01T00:00:00Z', NULL, v_lineage, '2026-01-01T00:00:00Z', 'local_research'
    );
    INSERT INTO security_symbol_alias (
      security_id, symbol, source, valid_from, valid_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_security_id, 'W24' || lpad(v_i::text, 2, '0'), 'wu24-probe',
      '2026-01-01T00:00:00Z', NULL, v_lineage, '2026-01-01T00:00:00Z', 'local_research'
    );
    v_issuer_ids := v_issuer_ids || v_issuer_id;
    v_security_ids := v_security_ids || v_security_id;
    IF v_labels[v_i] = 'twin_flat' THEN v_twin_flat_id := v_security_id; END IF;
    IF v_labels[v_i] = 'twin_rally' THEN v_twin_rally_id := v_security_id; END IF;
    IF v_labels[v_i] = 'nogics_late' THEN v_nogics_late_id := v_security_id; END IF;
    IF v_labels[v_i] = 'otc_enh' THEN v_otc_id := v_security_id; END IF;
  END LOOP;
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  FOR v_i IN 1 .. array_length(v_labels, 1) LOOP
    IF v_sectors[v_i] IS NOT NULL THEN
      PERFORM append_issuer_gics_classification(
        v_issuer_ids[v_i], v_sectors[v_i], '2026-01-01T00:00:00Z'::timestamptz, v_lineage);
    END IF;
  END LOOP;

  FOR v_i IN 1 .. array_length(v_labels, 1) LOOP
    v_mapping := propose_instrument_mapping(
      'licensed-eod-wu24', 'WU24-' || v_labels[v_i], 'security',
      NULL, v_security_ids[v_i], NULL, '2026-01-01T00:00:00Z', v_lineage);
    v_mapping := transition_instrument_mapping(
      v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
    v_mapping := transition_instrument_mapping(
      v_mapping.mapping_id, 'certified', 'WU-24 connector certification fixture', v_lineage);
    v_mapping_ids := v_mapping_ids || v_mapping.mapping_id;
  END LOOP;

  FOR v_i IN 1 .. array_length(v_labels, 1) LOOP
    FOR v_s IN 1 .. 5 LOOP
      IF v_labels[v_i] = 'twin_rally' THEN
        v_close := (ARRAY[50, 64, 80, 100, 125])[v_s];
        v_volume := (ARRAY[200000, 156250, 125000, 100000, 80000])[v_s];
      ELSIF v_labels[v_i] LIKE 'tech_%' THEN
        v_close := 100;
        v_volume := 5000000;
      ELSIF v_labels[v_i] = 'otc_enh' THEN
        v_close := 20;
        v_volume := 500000;
      ELSE
        v_close := 100;
        v_volume := 100000;
      END IF;
      PERFORM ingest_eod_price_observation(
        v_selection.selection_id, v_mapping_ids[v_i],
        'WU24-' || v_labels[v_i] || '-' || v_sessions[v_s]::text,
        v_sessions[v_s], 'complete',
        v_close * 0.98, v_close * 1.05, v_close * 0.95, v_close, v_volume,
        v_sessions[v_s]::timestamptz + interval '21 hours',
        jsonb_build_object('open', v_close * 0.98, 'high', v_close * 1.05,
                           'low', v_close * 0.95, 'close', v_close, 'volume', v_volume),
        v_lineage);
    END LOOP;
  END LOOP;

  FOR v_i IN 1 .. array_length(v_labels, 1) LOOP
    PERFORM append_discovery_universe_entry(
      'sp500-wu24', 'index_constituent', v_security_ids[v_i],
      DATE '2026-01-01', NULL, 'sp500-wu24:' || v_labels[v_i], v_lineage);
  END LOOP;

  SELECT * INTO v_policy
  FROM coverage_policy_version
  WHERE policy_key = 'coverage-policy' AND version = 1;
  SELECT * INTO v_approval FROM record_coverage_policy_approval(
    v_policy.policy_version_id, 'principal', 'wu24-probe-principal', v_lineage);

  SELECT * INTO v_config FROM append_discovery_screen_config_version(
    'discovery-screen-wu24', 1, v_policy.policy_version_id,
    '{
      "governing_policy_key": "coverage-policy",
      "lookback_sessions": 5,
      "min_close_price": 5.00,
      "penny_price_ceiling": 1.00,
      "min_median_dollar_volume": 5000000,
      "allowed_security_classes": ["common_stock", "etf_broad_market", "etf_sector"],
      "ordinary_venues": ["NASDAQ", "NYSE", "NYSE_ARCA"]
    }'::jsonb,
    '2026-01-01T00:00:00Z'::timestamptz,
    v_lineage
  );

  v_as_of := clock_timestamp();
  SELECT * INTO v_screen FROM run_discovery_screen(
    v_config.config_version_id, v_run_date, v_as_of, v_lineage);
  SELECT * INTO v_fitness FROM run_coverage_fitness_score(
    v_policy.policy_version_id, v_screen.run_id, clock_timestamp(), v_lineage);
  SELECT * INTO v_universe FROM run_coverage_universe_first_seed(
    v_fitness.run_id, 'coverage-universe', 1, v_lineage);

  SELECT fitness INTO v_flat_fitness
  FROM coverage_fitness_score
  WHERE run_id = v_fitness.run_id AND security_id = v_twin_flat_id;
  SELECT fitness INTO v_rally_fitness
  FROM coverage_fitness_score
  WHERE run_id = v_fitness.run_id AND security_id = v_twin_rally_id;

  SELECT * INTO v_resolution
  FROM research_evidence_profile_resolution
  WHERE resolution_id = v_universe.profile_resolution_id;

  FOR v_replay IN
    SELECT p.security_id, p.fitness, p.quality_floor_pass,
           s.fitness AS stored_fitness, s.quality_floor_pass AS stored_floor
    FROM coverage_fitness_score_preview(
           v_policy.policy_version_id, v_screen.run_id, v_fitness.as_of_at) p
    JOIN coverage_fitness_score s
      ON s.run_id = v_fitness.run_id AND s.security_id = p.security_id
  LOOP
    IF v_replay.fitness IS DISTINCT FROM v_replay.stored_fitness
       OR v_replay.quality_floor_pass IS DISTINCT FROM v_replay.stored_floor THEN
      v_replay_matches := false;
    END IF;
  END LOOP;

  FOR v_seed_replay IN
    SELECT p.security_id, p.admission_decision, p.rejection_reasons, p.admitted_rank,
           m.admission_decision AS stored_decision,
           m.rejection_reasons AS stored_reasons,
           m.admitted_rank AS stored_rank
    FROM coverage_first_seed_preview(v_fitness.run_id) p
    JOIN coverage_universe_membership m
      ON m.universe_version_id = v_universe.universe_version_id
     AND m.security_id = p.security_id
  LOOP
    IF v_seed_replay.admission_decision IS DISTINCT FROM v_seed_replay.stored_decision
       OR v_seed_replay.rejection_reasons IS DISTINCT FROM v_seed_replay.stored_reasons
       OR v_seed_replay.admitted_rank IS DISTINCT FROM v_seed_replay.stored_rank THEN
      v_seed_replay_matches := false;
    END IF;
  END LOOP;

  PERFORM append_issuer_gics_classification(
    v_issuer_ids[array_position(v_labels, 'nogics_late')],
    'financials', '2026-01-01T00:00:00Z'::timestamptz, v_lineage);
  SELECT * INTO v_late_preview
  FROM coverage_fitness_score_preview(
    v_policy.policy_version_id, v_screen.run_id, v_fitness.as_of_at)
  WHERE security_id = v_nogics_late_id;

  SELECT NOT EXISTS (
    SELECT 1
    FROM jsonb_object_keys(s.score_facts) k
    WHERE k IN ('return', 'returns', 'sentiment', 'profit', 'alpha', 'expected_return')
  ) AND (s.score_facts->>'last_close') IS NOT NULL
    AND abs(
      s.fitness - round(
        s.data_quality * (s.score_facts->'weights'->>'data_quality')::numeric / 100
        + s.stock_liquidity * (s.score_facts->'weights'->>'stock_liquidity')::numeric / 100
        + s.observability * (s.score_facts->'weights'->>'observability')::numeric / 100
        + s.diversification * (s.score_facts->'weights'->>'diversification')::numeric / 100
        + s.stability * (s.score_facts->'weights'->>'stability')::numeric / 100
      , 4)
    ) < 0.001
  INTO v_predictive_absent
  FROM coverage_fitness_score s
  WHERE s.run_id = v_fitness.run_id AND s.security_id = v_twin_rally_id;

  BEGIN
    PERFORM run_coverage_fitness_score(
      v_policy.policy_version_id, v_screen.run_id, clock_timestamp(), v_lineage);
  EXCEPTION
    WHEN unique_violation THEN v_duplicate_fitness_blocked := true;
  END;
  BEGIN
    PERFORM run_coverage_universe_first_seed(
      v_fitness.run_id, 'coverage-universe', 2, v_lineage);
  EXCEPTION
    WHEN unique_violation THEN v_duplicate_seed_blocked := true;
  END;

  SELECT * INTO v_policy_v2 FROM append_coverage_policy_version(
    'coverage-policy', 2, v_policy.definition,
    '2026-02-01T00:00:00Z'::timestamptz, v_lineage);
  SELECT * INTO v_fitness_v2 FROM run_coverage_fitness_score(
    v_policy_v2.policy_version_id, v_screen.run_id, clock_timestamp(), v_lineage);
  BEGIN
    SELECT * INTO v_failed_universe FROM run_coverage_universe_first_seed(
      v_fitness_v2.run_id, 'coverage-universe-unapproved', 1, v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN
        v_failed_universe.admission_state := 'failed';
        v_failed_universe.failure_reason := 'policy_unapproved';
        v_failed_universe.admitted_count := 0;
      END IF;
  END;

  SELECT * INTO v_empty_config FROM append_discovery_screen_config_version(
    'discovery-screen-wu24-empty', 1, v_policy.policy_version_id,
    '{
      "governing_policy_key": "coverage-policy",
      "lookback_sessions": 5,
      "min_close_price": 100000,
      "penny_price_ceiling": 1.00,
      "min_median_dollar_volume": 5000000,
      "allowed_security_classes": ["common_stock", "etf_broad_market", "etf_sector"],
      "ordinary_venues": ["NASDAQ", "NYSE", "NYSE_ARCA"]
    }'::jsonb,
    '2026-01-01T00:00:00Z'::timestamptz,
    v_lineage
  );
  SELECT * INTO v_empty_screen FROM run_discovery_screen(
    v_empty_config.config_version_id, v_run_date, clock_timestamp(), v_lineage);
  SELECT * INTO v_empty_fitness FROM run_coverage_fitness_score(
    v_policy.policy_version_id, v_empty_screen.run_id, clock_timestamp(), v_lineage);

  BEGIN
    PERFORM run_coverage_fitness_score(
      v_policy.policy_version_id, v_screen.run_id,
      clock_timestamp() + interval '1 day', v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '22023' THEN v_future_as_of_blocked := true; END IF;
  END;
  BEGIN
    PERFORM append_issuer_gics_classification(
      v_issuer_ids[1], 'not_a_sector', '2026-01-01T00:00:00Z'::timestamptz, v_lineage);
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '22023' THEN v_invalid_gics_blocked := true; END IF;
  END;
  BEGIN
    INSERT INTO issuer_gics_classification (
      issuer_id, scheme, sector_key, sector_name, valid_from,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_issuer_ids[1], 'gics', 'energy', 'Energy', '2026-01-01T00:00:00Z',
      v_lineage, now(), 'local_research'
    );
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_direct_gics_blocked := true; END IF;
  END;
  BEGIN
    INSERT INTO coverage_fitness_run (
      policy_version_id, discovery_run_id, trading_date, as_of_at,
      run_state, scored_count, below_floor_count, failure_reason, run_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_policy.policy_version_id, v_screen.run_id, DATE '2025-01-01', now(),
      'complete', 0, 0, NULL, repeat('ab', 32),
      v_lineage, now(), 'local_research'
    );
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_direct_fitness_blocked := true; END IF;
  END;
  BEGIN
    UPDATE coverage_fitness_run SET scored_count = scored_count WHERE run_id = v_fitness.run_id;
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_fitness_update_blocked := true; END IF;
  END;
  BEGIN
    DELETE FROM coverage_universe_version WHERE universe_version_id = v_universe.universe_version_id;
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_universe_delete_blocked := true; END IF;
  END;
  BEGIN
    TRUNCATE coverage_universe_membership;
  EXCEPTION
    WHEN others THEN
      IF SQLSTATE = '55000' THEN v_membership_truncate_blocked := true; END IF;
  END;

  v_results := jsonb_build_object(
    'fitness_run_complete', v_fitness.run_state = 'complete',
    'fitness_counts_consistent',
      v_fitness.scored_count = v_screen.included_count
      AND v_fitness.scored_count = (
        SELECT count(*) FROM coverage_fitness_score WHERE run_id = v_fitness.run_id)
      AND v_fitness.below_floor_count = (
        SELECT count(*) FROM coverage_fitness_score
        WHERE run_id = v_fitness.run_id AND NOT quality_floor_pass),
    'fitness_digest_valid', v_fitness.run_digest ~ '^[0-9a-f]{64}$',
    'twins_equal_fitness', v_flat_fitness IS NOT NULL
      AND v_flat_fitness = v_rally_fitness,
    'twins_ignore_returns', v_flat_fitness = v_rally_fitness
      AND (
        SELECT s_flat.score_facts->>'last_close' IS DISTINCT FROM s_rally.score_facts->>'last_close'
        FROM coverage_fitness_score s_flat, coverage_fitness_score s_rally
        WHERE s_flat.run_id = v_fitness.run_id AND s_flat.security_id = v_twin_flat_id
          AND s_rally.run_id = v_fitness.run_id AND s_rally.security_id = v_twin_rally_id
      ),
    'experimental_excluded_from_observability',
      (SELECT (score_facts->>'experimental_excluded')::boolean
            AND (score_facts->>'experimental_definition_count')::integer >= 1
            AND (score_facts->>'core_definition_count')::integer = 1
       FROM coverage_fitness_score
       WHERE run_id = v_fitness.run_id AND security_id = v_twin_flat_id),
    'core_definition_bound',
      v_universe.core_indicator_definition_ids = ARRAY[v_core.definition_version_id]
      AND NOT (v_experimental.definition_version_id = ANY (v_universe.core_indicator_definition_ids)),
    'missing_gics_below_floor', (
      SELECT NOT quality_floor_pass
      FROM coverage_fitness_score
      WHERE run_id = v_fitness.run_id AND security_id = v_nogics_late_id
    ) AND (
      SELECT admission_decision = 'rejected'
         AND 'below_quality_floor' = ANY (rejection_reasons)
      FROM coverage_universe_membership
      WHERE universe_version_id = v_universe.universe_version_id
        AND security_id = v_nogics_late_id
    ),
    'late_gics_invisible_at_run_as_of',
      v_late_preview.quality_floor_pass IS NOT TRUE
      AND (v_late_preview.score_facts->>'sector_key') IS NULL,
    'late_gics_visible_after_receipt', (
      SELECT quality_floor_pass AND score_facts->>'sector_key' = 'financials'
      FROM coverage_fitness_score_preview(
        v_policy.policy_version_id, v_screen.run_id, clock_timestamp())
      WHERE security_id = v_nogics_late_id
    ),
    'otc_scored_not_admitted_enhanced_gates', (
      SELECT m.enhanced_risk AND m.admission_decision = 'rejected'
         AND 'enhanced_risk_gates_incomplete' = ANY (m.rejection_reasons)
         AND s.quality_floor_pass
      FROM coverage_universe_membership m
      JOIN coverage_fitness_score s ON s.score_id = m.score_id
      WHERE m.universe_version_id = v_universe.universe_version_id
        AND m.security_id = v_otc_id
    ),
    'universe_complete', v_universe.admission_state = 'complete'
      AND v_universe.admission_kind = 'first_seed'
      AND v_universe.universe_digest ~ '^[0-9a-f]{64}$',
    'admitted_count_is_40', v_universe.admitted_count = 40
      AND v_universe.target_count = 40
      AND (
        SELECT count(*) FROM coverage_universe_membership
        WHERE universe_version_id = v_universe.universe_version_id
          AND admission_decision = 'admitted') = 40,
    'all_admitted_research_candidates', NOT EXISTS (
      SELECT 1 FROM coverage_universe_membership
      WHERE universe_version_id = v_universe.universe_version_id
        AND admission_decision = 'admitted'
        AND coverage_stage <> 'research_candidate'),
    'admitted_stock_eligible', NOT EXISTS (
      SELECT 1 FROM coverage_universe_membership
      WHERE universe_version_id = v_universe.universe_version_id
        AND admission_decision = 'admitted'
        AND (coverage_capability <> 'stock_eligible' OR NOT system_selected)),
    'obligations_active', v_resolution.obligation_count > 0
      AND v_resolution.coverage_stage = 'research_candidate'
      AND v_resolution.coverage_capability = 'stock_eligible'
      AND v_resolution.decision_purpose = 'research'
      AND jsonb_array_length(v_resolution.obligations) = v_resolution.obligation_count,
    'tech_admitted_at_ceiling', (
      SELECT count(*) FROM coverage_universe_membership m
      JOIN coverage_fitness_score s ON s.score_id = m.score_id
      WHERE m.universe_version_id = v_universe.universe_version_id
        AND m.admission_decision = 'admitted'
        AND s.score_facts->>'sector_key' = 'information_technology') = 20,
    'tech_excess_rejected_sector_ceiling', (
      SELECT count(*) FROM coverage_universe_membership m
      JOIN coverage_fitness_score s ON s.score_id = m.score_id
      WHERE m.universe_version_id = v_universe.universe_version_id
        AND m.admission_decision = 'rejected'
        AND 'sector_ceiling' = ANY (m.rejection_reasons)
        AND s.score_facts->>'sector_key' = 'information_technology') = 5,
    'others_admitted', (
      SELECT count(*) FROM coverage_universe_membership m
      JOIN coverage_fitness_score s ON s.score_id = m.score_id
      WHERE m.universe_version_id = v_universe.universe_version_id
        AND m.admission_decision = 'admitted'
        AND s.score_facts->>'sector_key' IS DISTINCT FROM 'information_technology') = 20,
    'quality_floor_never_admitted', NOT EXISTS (
      SELECT 1 FROM coverage_universe_membership m
      JOIN coverage_fitness_score s ON s.score_id = m.score_id
      WHERE m.universe_version_id = v_universe.universe_version_id
        AND m.admission_decision = 'admitted'
        AND NOT s.quality_floor_pass),
    'deterministic_score_replay_matches', v_replay_matches
      AND v_fitness.scored_count = (
        SELECT count(*) FROM coverage_fitness_score_preview(
          v_policy.policy_version_id, v_screen.run_id, v_fitness.as_of_at)),
    'deterministic_seed_replay_matches', v_seed_replay_matches,
    'duplicate_fitness_blocked', v_duplicate_fitness_blocked,
    'duplicate_seed_blocked', v_duplicate_seed_blocked,
    'unapproved_policy_seed_blocked',
      v_failed_universe.admission_state = 'failed'
      AND v_failed_universe.failure_reason = 'policy_unapproved'
      AND v_failed_universe.admitted_count = 0
      AND NOT EXISTS (
        SELECT 1 FROM coverage_universe_version
        WHERE fitness_run_id = v_fitness_v2.run_id),
    'empty_pool_fails_closed',
      v_empty_fitness.run_state = 'failed'
      AND v_empty_fitness.failure_reason = 'empty_discovery_pool'
      AND v_empty_screen.included_count = 0,
    'future_as_of_blocked', v_future_as_of_blocked,
    'invalid_gics_blocked', v_invalid_gics_blocked,
    'direct_gics_insert_blocked', v_direct_gics_blocked,
    'direct_fitness_insert_blocked', v_direct_fitness_blocked,
    'fitness_update_blocked', v_fitness_update_blocked,
    'universe_delete_blocked', v_universe_delete_blocked,
    'membership_truncate_blocked', v_membership_truncate_blocked,
    'fitness_audited', EXISTS (
      SELECT 1 FROM audit_event
      WHERE event_type = 'research.coverage_fitness_scored'
        AND payload->>'run_id' = v_fitness.run_id::text),
    'seed_audited', EXISTS (
      SELECT 1 FROM audit_event
      WHERE event_type = 'research.coverage_universe_first_seeded'
        AND payload->>'universe_version_id' = v_universe.universe_version_id::text),
    'predictive_fields_absent', v_predictive_absent,
    'screen_included_count', v_screen.included_count
  );

  INSERT INTO wu24_probe_result VALUES (v_results);
END;
$probe$;
