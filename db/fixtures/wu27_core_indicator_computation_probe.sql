-- WU-27 Core indicator computation probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu27_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '28000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '28000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '28000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '28000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '28000000-0000-0000-0000-000000000501';
  v_contract_v1 uuid := '28000000-0000-0000-0000-000000000502';
  v_field_1 uuid := '28000000-0000-0000-0000-000000000601';
  v_field_2 uuid := '28000000-0000-0000-0000-000000000602';
  v_field_3 uuid := '28000000-0000-0000-0000-000000000603';
  v_connector_id uuid := '28000000-0000-0000-0000-000000000701';
  v_lineage jsonb := '{"source":"wu27-probe","entitlement_version":"licensed-eod-v1"}';
  v_sessions date[] := ARRAY[
    DATE '2026-01-05', DATE '2026-01-06', DATE '2026-01-07', DATE '2026-01-08', DATE '2026-01-09',
    DATE '2026-01-12', DATE '2026-01-13', DATE '2026-01-14', DATE '2026-01-15', DATE '2026-01-16',
    DATE '2026-01-19', DATE '2026-01-20', DATE '2026-01-21', DATE '2026-01-22', DATE '2026-01-23',
    DATE '2026-01-26', DATE '2026-01-27', DATE '2026-01-28', DATE '2026-01-29', DATE '2026-01-30',
    DATE '2026-02-02', DATE '2026-02-03', DATE '2026-02-04', DATE '2026-02-05', DATE '2026-02-06',
    DATE '2026-02-09', DATE '2026-02-10'];
  v_selection eod_vendor_selection%ROWTYPE;
  v_core indicator_definition_version%ROWTYPE;
  v_core_v2 indicator_definition_version%ROWTYPE;
  v_experimental indicator_definition_version%ROWTYPE;
  v_unknown indicator_definition_version%ROWTYPE;
  v_issuer_id uuid;
  v_security_id uuid;
  v_mapping instrument_mapping%ROWTYPE;
  v_mapping_b instrument_mapping%ROWTYPE;
  v_labels text[] := ARRAY['series', 'short', 'unmapped', 'conflict', 'pacer'];
  v_security_ids uuid[] := '{}';
  v_series_id uuid;
  v_short_id uuid;
  v_unmapped_id uuid;
  v_conflict_id uuid;
  v_pacer_id uuid;
  v_series_mapping uuid;
  v_short_mapping uuid;
  v_conflict_mapping uuid;
  v_pacer_mapping uuid;
  v_i integer;
  v_s integer;
  v_close numeric;
  v_t1 timestamptz;
  v_t_late timestamptz;
  v_t_v2 timestamptz;
  v_obs_t1 indicator_observation%ROWTYPE;
  v_obs_t1_replay indicator_observation%ROWTYPE;
  v_preview_t1 indicator_observation%ROWTYPE;
  v_obs_short indicator_observation%ROWTYPE;
  v_obs_unmapped indicator_observation%ROWTYPE;
  v_obs_conflict indicator_observation%ROWTYPE;
  v_obs_late indicator_observation%ROWTYPE;
  v_obs_v2 indicator_observation%ROWTYPE;
  v_preview_after_retire indicator_observation%ROWTYPE;
  v_bind_t1 indicator_evaluation_binding%ROWTYPE;
  v_bind_v2 indicator_evaluation_binding%ROWTYPE;
  v_expected_t1 numeric;
  v_expected_late numeric;
  v_results jsonb;
  v_experimental_blocked boolean := false;
  v_unknown_formula_blocked boolean := false;
  v_noncanonical_horizon_blocked boolean := false;
  v_future_as_of_blocked boolean := false;
  v_rebind_blocked boolean := false;
  v_direct_insert_blocked boolean := false;
  v_observation_update_blocked boolean := false;
  v_binding_delete_blocked boolean := false;
  v_observation_truncate_blocked boolean := false;
  v_retired_latest_does_not_fallback boolean := false;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-wu27', 'Licensed EOD WU-27 Provider', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Licensed EOD WU-27 Terms","version":"2026.1"}',
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
    v_entitlement_id, 'licensed-eod-wu27-entitlement', 'local-research-account',
    'Licensed daily EOD access for WU-27 computation', v_lineage,
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
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-eod-wu27-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'daily-eod-contract-wu27', 'market',
    'Point-in-time licensed daily market delivery contract for WU-27',
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
    v_connector_id, 'licensed-eod-connector-wu27', 'daily_eod', v_source_v1, v_contract_v1,
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
    'licensed-eod-provider-wu27', v_source_v1, v_entitlement_v1,
    '{"selected":"licensed-eod-provider-wu27","candidates":[{"vendor":"licensed-eod-provider-wu27","license":"written research license","entitlement":"daily historical OHLCV","monthly_cost_usd":0}]}'::jsonb,
    '{"status":"written_license","raw_retention":"permitted","derived_use":"permitted"}'::jsonb,
    '{"status":"certified","history_years":10,"purposes":["local_research","paper_validation"]}'::jsonb,
    '{"monthly_cost_usd":0,"annual_budget_usd":0,"within_stage_cap":true}'::jsonb,
    'selected after license, entitlement, coverage, and cost comparison', v_lineage
  );

  SELECT * INTO v_core FROM append_indicator_definition_version(
    'close_return_20d_wu27', 1, 'core',
    '{
      "purpose": "Descriptive 20-session close-to-close return for research context; never a universal alpha signal.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped; a horizon shorter than 20 complete sessions yields no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu27"}],
      "certified_sources": ["licensed-eod-wu27"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [{"name": "flat_series", "inputs": {"close": [100, 100, 100]}, "expected": 0.0}],
      "canonical_horizons": [1, 20]
    }'::jsonb,
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );
  SELECT * INTO v_experimental FROM append_indicator_definition_version(
    'experimental_gap_bias_wu27', 1, 'experimental',
    '{
      "purpose": "Preregistered predictive hypothesis excluded from Core computation.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "event-time anchored to announcement receipt",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions with earnings events",
      "missingness": "events without as-of provenance yield no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu27"}],
      "certified_sources": ["licensed-eod-wu27"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 2},
      "valid_ranges": {"min": -1.0, "max": 1.0},
      "golden_cases": [{"name": "no_events", "inputs": {"earnings_flag": []}, "expected": null}],
      "canonical_horizons": [5, 20]
    }'::jsonb,
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );
  SELECT * INTO v_unknown FROM append_indicator_definition_version(
    'unknown_core_formula_wu27', 1, 'core',
    '{
      "purpose": "Core indicator whose formula is not a closed computation family.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1 with volume confirmation",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu27"}],
      "certified_sources": ["licensed-eod-wu27"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [{"name": "flat_series", "inputs": {"close": [100]}, "expected": 0.0}],
      "canonical_horizons": [20]
    }'::jsonb,
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage
  );

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  FOR v_i IN 1 .. array_length(v_labels, 1) LOOP
    INSERT INTO issuer (legal_name, source_lineage, receipt_time, record_environment)
    VALUES ('WU-27 ' || v_labels[v_i] || ' Issuer, Inc.', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING issuer_id INTO v_issuer_id;
    INSERT INTO security (issuer_id, security_class, source_lineage, receipt_time, record_environment)
    VALUES (v_issuer_id, 'common_stock', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
    RETURNING security_id INTO v_security_id;
    INSERT INTO exchange_listing (
      security_id, venue, currency, listing_status, valid_from, valid_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_security_id, 'NASDAQ', 'USD', 'active',
      '2026-01-01T00:00:00Z', NULL, v_lineage, '2026-01-01T00:00:00Z', 'local_research'
    );
    v_security_ids := v_security_ids || v_security_id;
    IF v_labels[v_i] = 'series' THEN v_series_id := v_security_id; END IF;
    IF v_labels[v_i] = 'short' THEN v_short_id := v_security_id; END IF;
    IF v_labels[v_i] = 'unmapped' THEN v_unmapped_id := v_security_id; END IF;
    IF v_labels[v_i] = 'conflict' THEN v_conflict_id := v_security_id; END IF;
    IF v_labels[v_i] = 'pacer' THEN v_pacer_id := v_security_id; END IF;
  END LOOP;
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  v_mapping := propose_instrument_mapping(
    'licensed-eod-wu27', 'WU27-series', 'security',
    NULL, v_series_id, NULL, '2026-01-01T00:00:00Z', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-27 connector certification fixture', v_lineage);
  v_series_mapping := v_mapping.mapping_id;

  v_mapping := propose_instrument_mapping(
    'licensed-eod-wu27', 'WU27-short', 'security',
    NULL, v_short_id, NULL, '2026-01-01T00:00:00Z', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-27 connector certification fixture', v_lineage);
  v_short_mapping := v_mapping.mapping_id;

  v_mapping := propose_instrument_mapping(
    'licensed-eod-wu27', 'WU27-conflict', 'security',
    NULL, v_conflict_id, NULL, '2026-01-01T00:00:00Z', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-27 connector certification fixture', v_lineage);
  v_conflict_mapping := v_mapping.mapping_id;
  v_mapping_b := propose_instrument_mapping(
    'licensed-eod-wu27', 'WU27-conflict-alt', 'security',
    NULL, v_conflict_id, NULL, '2026-01-01T00:00:00Z', v_lineage);
  v_mapping_b := transition_instrument_mapping(
    v_mapping_b.mapping_id, 'corroborated', 'second independent identity check', v_lineage);
  v_mapping_b := transition_instrument_mapping(
    v_mapping_b.mapping_id, 'certified', 'conflicting certified mapping', v_lineage);

  v_mapping := propose_instrument_mapping(
    'licensed-eod-wu27', 'WU27-pacer', 'security',
    NULL, v_pacer_id, NULL, '2026-01-01T00:00:00Z', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-27 connector certification fixture', v_lineage);
  v_pacer_mapping := v_mapping.mapping_id;

  -- First batch: 21 sessions for series, 5 for short. Pacer and later
  -- series bars arrive after the T1 as_of so they cannot leak into it.
  FOR v_s IN 1 .. 21 LOOP
    v_close := 100 + (v_s - 1);
    PERFORM ingest_eod_price_observation(
      v_selection.selection_id, v_series_mapping,
      'WU27-series-' || v_sessions[v_s]::text,
      v_sessions[v_s], 'complete',
      v_close * 0.98, v_close * 1.05, v_close * 0.95, v_close, 100000,
      v_sessions[v_s]::timestamptz + interval '21 hours',
      jsonb_build_object('open', v_close * 0.98, 'high', v_close * 1.05,
                         'low', v_close * 0.95, 'close', v_close, 'volume', 100000),
      v_lineage);
  END LOOP;
  FOR v_s IN 1 .. 5 LOOP
    PERFORM ingest_eod_price_observation(
      v_selection.selection_id, v_short_mapping,
      'WU27-short-' || v_sessions[v_s]::text,
      v_sessions[v_s], 'complete',
      100, 105, 95, 100, 100000,
      v_sessions[v_s]::timestamptz + interval '21 hours',
      jsonb_build_object('open', 100, 'high', 105, 'low', 95, 'close', 100, 'volume', 100000),
      v_lineage);
  END LOOP;

  v_t1 := clock_timestamp();
  v_expected_t1 := round((120::numeric / 100) - 1, 12);
  v_expected_late := round((124::numeric / 104) - 1, 12);

  SELECT * INTO v_obs_t1 FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_series_id, v_t1, 20, v_lineage);
  SELECT * INTO v_obs_short FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_short_id, v_t1, 20, v_lineage);
  SELECT * INTO v_obs_unmapped FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_unmapped_id, v_t1, 20, v_lineage);
  SELECT * INTO v_obs_conflict FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_conflict_id, v_t1, 20, v_lineage);
  SELECT * INTO v_bind_t1 FROM bind_core_indicator_into_evaluation(
    'eval-t1-wu27', v_obs_t1.observation_id, v_lineage);

  BEGIN
    PERFORM compute_core_indicator_observation(
      'experimental_gap_bias_wu27', v_series_id, v_t1, 20, v_lineage);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_experimental_blocked := true; END IF;
  END;
  BEGIN
    PERFORM compute_core_indicator_observation(
      'unknown_core_formula_wu27', v_series_id, v_t1, 20, v_lineage);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_unknown_formula_blocked := true; END IF;
  END;
  BEGIN
    PERFORM compute_core_indicator_observation(
      'close_return_20d_wu27', v_series_id, v_t1, 5, v_lineage);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_noncanonical_horizon_blocked := true; END IF;
  END;
  BEGIN
    PERFORM compute_core_indicator_observation(
      'close_return_20d_wu27', v_series_id,
      clock_timestamp() + interval '1 hour', 20, v_lineage);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN v_future_as_of_blocked := true; END IF;
  END;

  -- Later bars and a two-session calendar pacer. Receipt is after T1.
  FOR v_s IN 22 .. 25 LOOP
    v_close := 100 + (v_s - 1);
    PERFORM ingest_eod_price_observation(
      v_selection.selection_id, v_series_mapping,
      'WU27-series-' || v_sessions[v_s]::text,
      v_sessions[v_s], 'complete',
      v_close * 0.98, v_close * 1.05, v_close * 0.95, v_close, 100000,
      v_sessions[v_s]::timestamptz + interval '21 hours',
      jsonb_build_object('open', v_close * 0.98, 'high', v_close * 1.05,
                         'low', v_close * 0.95, 'close', v_close, 'volume', 100000),
      v_lineage);
  END LOOP;
  FOR v_s IN 26 .. 27 LOOP
    PERFORM ingest_eod_price_observation(
      v_selection.selection_id, v_pacer_mapping,
      'WU27-pacer-' || v_sessions[v_s]::text,
      v_sessions[v_s], 'complete',
      50, 51, 49, 50, 100000,
      v_sessions[v_s]::timestamptz + interval '21 hours',
      jsonb_build_object('open', 50, 'high', 51, 'low', 49, 'close', 50, 'volume', 100000),
      v_lineage);
  END LOOP;

  SELECT * INTO v_obs_t1_replay FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_series_id, v_t1, 20, v_lineage);
  SELECT * INTO v_preview_t1 FROM preview_core_indicator_observation(
    'close_return_20d_wu27', v_series_id, v_t1, 20);

  v_t_late := clock_timestamp();
  SELECT * INTO v_obs_late FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_series_id, v_t_late, 20, v_lineage);

  SELECT * INTO v_core_v2 FROM append_indicator_definition_version(
    'close_return_20d_wu27', 2, 'core',
    '{
      "purpose": "Descriptive 20-session close-to-close return for research context; never a universal alpha signal.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped; a horizon shorter than 20 complete sessions yields no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu27"}, {"name": "session_volume", "source": "licensed-eod-wu27"}],
      "certified_sources": ["licensed-eod-wu27"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [{"name": "flat_series", "inputs": {"close": [100, 100, 100]}, "expected": 0.0}],
      "canonical_horizons": [1, 20]
    }'::jsonb,
    v_core.definition_version_id, clock_timestamp(), v_lineage
  );

  v_t_v2 := clock_timestamp();
  SELECT * INTO v_obs_v2 FROM compute_core_indicator_observation(
    'close_return_20d_wu27', v_series_id, v_t_v2, 20, v_lineage);
  SELECT * INTO v_bind_v2 FROM bind_core_indicator_into_evaluation(
    'eval-v2-wu27', v_obs_v2.observation_id, v_lineage);

  BEGIN
    PERFORM bind_core_indicator_into_evaluation(
      'eval-t1-wu27', v_obs_v2.observation_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: evaluation rebind to a new definition version was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '23505' THEN v_rebind_blocked := true; ELSE RAISE; END IF;
  END;

  PERFORM record_indicator_definition_lifecycle(
    v_core_v2.definition_version_id, 'retired',
    'WU-27 retirement must not resurrect v1', NULL, v_lineage);
  BEGIN
    PERFORM compute_core_indicator_observation(
      'close_return_20d_wu27', v_series_id, clock_timestamp(), 20, v_lineage);
    RAISE EXCEPTION 'probe corrupted: retired v2 fell back to a predecessor';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%retired core indicator % cannot be computed%' THEN RAISE; END IF;
    SELECT * INTO v_preview_after_retire FROM preview_core_indicator_observation(
      'close_return_20d_wu27', v_series_id, v_t1, 20);
    v_retired_latest_does_not_fallback :=
      v_preview_after_retire.definition_version_id = v_core.definition_version_id;
  END;

  BEGIN
    INSERT INTO indicator_observation (
      definition_version_id, security_id, indicator_key, horizon, as_of_at,
      observation_state, observation_value, value_units, precision_scale,
      source_observation_ids, calculation_runtime, correction_status,
      observation_digest, source_lineage, receipt_time, record_environment
    ) VALUES (
      v_core.definition_version_id, v_series_id, 'close_return_20d_wu27', 1,
      v_t1, 'missing', NULL, 'fraction', 12, '{}', 'core-close-return', 'uncorrected',
      repeat('0', 64), v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct observation INSERT was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%must go through compute_core_indicator_observation%' THEN RAISE; END IF;
    v_direct_insert_blocked := true;
  END;

  BEGIN
    UPDATE indicator_observation
    SET observation_value = 0
    WHERE observation_id = v_obs_t1.observation_id;
    RAISE EXCEPTION 'probe corrupted: observation UPDATE was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
    v_observation_update_blocked := true;
  END;
  BEGIN
    DELETE FROM indicator_evaluation_binding
    WHERE binding_id = v_bind_t1.binding_id;
    RAISE EXCEPTION 'probe corrupted: binding DELETE was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
    v_binding_delete_blocked := true;
  END;
  BEGIN
    TRUNCATE indicator_observation, indicator_evaluation_binding;
    RAISE EXCEPTION 'probe corrupted: observation TRUNCATE was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
    v_observation_truncate_blocked := true;
  END;

  v_results := jsonb_build_object(
    't1_current_value',
      v_obs_t1.observation_state = 'current'
      AND v_obs_t1.observation_value = v_expected_t1
      AND v_obs_t1.definition_version_id = v_core.definition_version_id,
    't1_binds_definition_version',
      v_bind_t1.definition_version_id = v_core.definition_version_id
      AND v_bind_t1.observation_id = v_obs_t1.observation_id,
    'lookahead_replay_unchanged',
      v_obs_t1_replay.observation_id = v_obs_t1.observation_id
      AND v_obs_t1_replay.observation_digest = v_obs_t1.observation_digest
      AND v_preview_t1.observation_digest = v_obs_t1.observation_digest
      AND v_preview_t1.observation_value = v_expected_t1,
    'later_as_of_uses_later_bars',
      v_obs_late.observation_id IS DISTINCT FROM v_obs_t1.observation_id
      AND v_obs_late.observation_value = v_expected_late
      AND v_obs_late.definition_version_id = v_core.definition_version_id
      AND v_obs_late.observation_state = 'stale',
    'historical_evaluation_keeps_v1',
      v_obs_t1.definition_version_id = v_core.definition_version_id
      AND v_obs_v2.definition_version_id = v_core_v2.definition_version_id
      AND v_obs_v2.definition_version_id IS DISTINCT FROM v_obs_t1.definition_version_id,
    'later_evaluation_binds_v2',
      v_bind_v2.definition_version_id = v_core_v2.definition_version_id
      AND v_bind_v2.evaluation_key = 'eval-v2-wu27',
    'incomplete_has_no_value',
      v_obs_short.observation_state = 'incomplete'
      AND v_obs_short.observation_value IS NULL,
    'unmapped_is_missing',
      v_obs_unmapped.observation_state = 'missing'
      AND v_obs_unmapped.observation_value IS NULL,
    'identity_conflict_is_disputed',
      v_obs_conflict.observation_state = 'source_disputed'
      AND v_obs_conflict.observation_value IS NULL,
    'experimental_excluded', v_experimental_blocked,
    'unknown_formula_blocked', v_unknown_formula_blocked,
    'noncanonical_horizon_blocked', v_noncanonical_horizon_blocked,
    'future_as_of_blocked', v_future_as_of_blocked,
    'rebind_blocked', v_rebind_blocked,
    'retired_latest_does_not_fallback', v_retired_latest_does_not_fallback,
    'direct_insert_blocked', v_direct_insert_blocked,
    'observation_update_blocked', v_observation_update_blocked,
    'binding_delete_blocked', v_binding_delete_blocked,
    'observation_truncate_blocked', v_observation_truncate_blocked,
    'appends_audited', EXISTS (
      SELECT 1 FROM audit_event
      WHERE event_id = 'core-indicator-obs:' || v_obs_t1.observation_id::text
        AND event_type = 'research.core_indicator_computed'
    ),
    'binding_audited', EXISTS (
      SELECT 1 FROM audit_event
      WHERE event_id = 'core-indicator-bind:' || v_bind_t1.binding_id::text
        AND event_type = 'research.indicator_evaluation_bound'
    )
  );

  INSERT INTO wu27_probe_result VALUES (v_results);
END;
$probe$;
