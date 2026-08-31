-- Cross-WU thermo-nuclear hardening probe (migration 0033). Run inside a
-- caller-managed transaction; all fixture evidence is rolled back.

CREATE TEMP TABLE harden_wu28_31_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '33000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '33000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '33000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '33000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '33000000-0000-0000-0000-000000000501';
  v_contract_v1 uuid := '33000000-0000-0000-0000-000000000502';
  v_field_1 uuid := '33000000-0000-0000-0000-000000000601';
  v_field_2 uuid := '33000000-0000-0000-0000-000000000602';
  v_field_3 uuid := '33000000-0000-0000-0000-000000000603';
  v_connector_id uuid := '33000000-0000-0000-0000-000000000701';
  v_lineage jsonb := '{"source":"harden-wu28-31-probe","entitlement_version":"licensed-eod-v1"}';
  v_exp_lineage jsonb := '{"source":"harden-wu28-31-probe","entitlement_version":"indicator-registry-v1"}';
  v_selection eod_vendor_selection%ROWTYPE;
  v_issuer_id uuid;
  v_security_id uuid;
  v_mapping instrument_mapping%ROWTYPE;
  v_all_dates date[];
  v_prefix date[];
  v_suffix date[];
  v_as_of timestamptz;
  v_i integer;
  v_close numeric;
  v_seal release_holdout_seal%ROWTYPE;
  v_spec jsonb;
  v_spec_a jsonb;
  v_spec_b jsonb;
  v_spec_c jsonb;
  v_a experiment_preregistration%ROWTYPE;
  v_b experiment_preregistration%ROWTYPE;
  v_c experiment_preregistration%ROWTYPE;
  v_corr experiment_family_correction%ROWTYPE;
  v_trial experiment_trial%ROWTYPE;
  v_experimental indicator_definition_version%ROWTYPE;
  v_prereg experiment_preregistration%ROWTYPE;
  v_manifest jsonb;
  v_stage experimental_indicator_stage%ROWTYPE;
  v_advanced experimental_indicator_stage%ROWTYPE;
  v_results jsonb := '{}'::jsonb;
BEGIN
  SELECT array_agg(d::date ORDER BY d) INTO v_all_dates
  FROM generate_series(
    ((clock_timestamp() AT TIME ZONE 'UTC')::date - 61),
    ((clock_timestamp() AT TIME ZONE 'UTC')::date - 1),
    interval '1 day') d;
  v_prefix := v_all_dates[1:60];
  v_suffix := v_all_dates[2:61];
  v_as_of := clock_timestamp();

  BEGIN
    PERFORM seal_release_holdout(v_suffix, v_as_of, v_lineage);
    RAISE EXCEPTION 'probe corrupted: empty-calendar holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%the calendar has 0%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('empty_calendar_blocked', true);
  END;

  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-harden-wu28-31', 'Licensed EOD harden WU-28-31', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Licensed EOD harden terms","version":"2026.1"}',
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
    v_entitlement_id, 'licensed-eod-harden-wu28-31-entitlement', 'local-research-account',
    'Licensed daily EOD access for WU-28-31 hardening', v_lineage,
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
    '2026-01-01T00:00:00Z', '2028-01-01T00:00:00Z',
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-eod-harden-wu28-31-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'daily-eod-contract-harden-wu28-31', 'market',
    'Point-in-time licensed daily market delivery contract for hardening',
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
    v_connector_id, 'licensed-eod-connector-harden-wu28-31', 'daily_eod',
    v_source_v1, v_contract_v1, 'active', v_lineage, now(), 'local_research'
  );
  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id,
    source_lineage, receipt_time, record_environment
  ) VALUES
    (v_connector_id, v_contract_v1, v_field_1, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_2, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_3, v_lineage, now(), 'local_research');

  SELECT * INTO v_selection FROM record_eod_vendor_selection(
    'licensed-eod-provider-harden-wu28-31', v_source_v1, v_entitlement_v1,
    '{"selected":"licensed-eod-provider-harden-wu28-31","candidates":[{"vendor":"licensed-eod-provider-harden-wu28-31","license":"written research license","entitlement":"daily historical OHLCV","monthly_cost_usd":0}]}'::jsonb,
    '{"status":"written_license","raw_retention":"permitted","derived_use":"permitted"}'::jsonb,
    '{"status":"certified","history_years":10,"purposes":["local_research","paper_validation"]}'::jsonb,
    '{"monthly_cost_usd":0,"annual_budget_usd":0,"within_stage_cap":true}'::jsonb,
    'selected after license, entitlement, coverage, and cost comparison', v_lineage
  );

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  INSERT INTO issuer (legal_name, source_lineage, receipt_time, record_environment)
  VALUES ('Harden WU-28-31 Issuer, Inc.', v_lineage, '2026-01-01T00:00:00Z', 'local_research')
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
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  v_mapping := propose_instrument_mapping(
    'licensed-eod-harden-wu28-31', 'HARDEN-series', 'security',
    NULL, v_security_id, NULL, '2026-01-01T00:00:00Z', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
  v_mapping := transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'harden connector certification fixture', v_lineage);

  FOR v_i IN 1 .. 59 LOOP
    v_close := 100 + v_i;
    PERFORM ingest_eod_price_observation(
      v_selection.selection_id, v_mapping.mapping_id,
      'HARDEN-series-' || v_all_dates[v_i]::text,
      v_all_dates[v_i], 'complete',
      v_close * 0.98, v_close * 1.05, v_close * 0.95, v_close, 100000,
      (v_all_dates[v_i]::timestamp AT TIME ZONE 'UTC') + interval '21 hours',
      jsonb_build_object('open', v_close * 0.98, 'high', v_close * 1.05,
                         'low', v_close * 0.95, 'close', v_close, 'volume', 100000),
      v_lineage);
  END LOOP;
  IF (SELECT count(DISTINCT trading_date) FROM eod_price_observation) <> 59 THEN
    RAISE EXCEPTION 'probe corrupted: expected 59 EOD sessions, got %',
      (SELECT count(DISTINCT trading_date) FROM eod_price_observation);
  END IF;
  v_as_of := clock_timestamp();

  BEGIN
    PERFORM seal_release_holdout(v_prefix, v_as_of, v_lineage);
    RAISE EXCEPTION 'probe corrupted: 59-session calendar holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%sessions visible at as_of%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('short_calendar_blocked', true);
  END;

  FOR v_i IN 60 .. 61 LOOP
    v_close := 100 + v_i;
    PERFORM ingest_eod_price_observation(
      v_selection.selection_id, v_mapping.mapping_id,
      'HARDEN-series-' || v_all_dates[v_i]::text,
      v_all_dates[v_i], 'complete',
      v_close * 0.98, v_close * 1.05, v_close * 0.95, v_close, 100000,
      (v_all_dates[v_i]::timestamp AT TIME ZONE 'UTC') + interval '21 hours',
      jsonb_build_object('open', v_close * 0.98, 'high', v_close * 1.05,
                         'low', v_close * 0.95, 'close', v_close, 'volume', 100000),
      v_lineage);
  END LOOP;
  IF (SELECT count(DISTINCT trading_date) FROM eod_price_observation) <> 61 THEN
    RAISE EXCEPTION 'probe corrupted: expected 61 EOD sessions, got %',
      (SELECT count(DISTINCT trading_date) FROM eod_price_observation);
  END IF;
  v_as_of := clock_timestamp();

  BEGIN
    PERFORM seal_release_holdout(v_prefix, v_as_of, v_lineage);
    RAISE EXCEPTION 'probe corrupted: non-suffix holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%most recent % trading days visible at as_of%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('non_suffix_blocked', true);
  END;

  SELECT * INTO v_seal FROM seal_release_holdout(v_suffix, v_as_of, v_lineage);
  v_results := v_results || jsonb_build_object(
    'suffix_seal_recorded',
      v_seal.session_count = 60
      AND v_seal.session_dates = v_suffix
      AND v_seal.first_trading_date = v_suffix[1]
      AND v_seal.last_trading_date = v_suffix[60]
      AND v_seal.seal_digest = release_holdout_seal_digest(v_suffix)
      AND NOT release_holdout_is_consumed(v_seal.holdout_id)
  );

  v_spec := jsonb_build_object(
    'hypothesis', 'Declared family size includes members without a measured p-value.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', 'Holm across the family'
  );
  v_spec_a := v_spec || jsonb_build_object(
    'hypothesis', 'Declared-family member A.',
    'experiment_family', 'harden-holm-declared');
  v_spec_b := v_spec || jsonb_build_object(
    'hypothesis', 'Declared-family member B.',
    'experiment_family', 'harden-holm-declared');
  v_spec_c := v_spec || jsonb_build_object(
    'hypothesis', 'Declared-family member C never records a p-value.',
    'experiment_family', 'harden-holm-declared');
  SELECT * INTO v_a FROM register_experiment_preregistration(
    'harden-holm-a', v_spec_a, NULL, v_exp_lineage);
  SELECT * INTO v_b FROM register_experiment_preregistration(
    'harden-holm-b', v_spec_b, NULL, v_exp_lineage);
  SELECT * INTO v_c FROM register_experiment_preregistration(
    'harden-holm-c', v_spec_c, NULL, v_exp_lineage);

  PERFORM record_experiment_trial(v_a.registration_id, 'successful', 0.01, v_exp_lineage);
  PERFORM record_experiment_trial(v_b.registration_id, 'successful', 0.04, v_exp_lineage);
  SELECT * INTO v_corr FROM compute_experiment_family_correction(
    'harden-holm-declared', v_exp_lineage);
  v_results := v_results || jsonb_build_object(
    'holm_uses_declared_family_size',
      v_corr.method = 'holm'
      AND v_corr.member_count = 3
      AND jsonb_array_length(v_corr.adjustments) = 3
      AND (v_corr.adjustments->0->>'p_value')::numeric = 0.01
      AND (v_corr.adjustments->1->>'p_value')::numeric = 0.04
      AND (v_corr.adjustments->2->>'p_value')::numeric = 1
      AND (v_corr.adjustments->0->>'adjusted_p')::numeric = 0.03
      AND (v_corr.adjustments->1->>'adjusted_p')::numeric = 0.08
      AND (v_corr.adjustments->2->>'adjusted_p')::numeric = 1
      AND (v_corr.adjustments->0->>'rejected')::boolean IS TRUE
      AND (v_corr.adjustments->1->>'rejected')::boolean IS FALSE
      AND (v_corr.adjustments->2->>'rejected')::boolean IS FALSE
  );

  BEGIN
    PERFORM record_experiment_trial(v_c.registration_id, 'successful', NULL, v_exp_lineage);
    RAISE EXCEPTION 'probe corrupted: result-bearing trial without p_value was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%p_value is required for result-bearing outcomes%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('result_bearing_null_p_blocked', true);
  END;

  SELECT * INTO v_trial FROM record_experiment_trial(
    v_c.registration_id, 'aborted', NULL, v_exp_lineage);
  v_results := v_results || jsonb_build_object(
    'aborted_null_p_allowed',
      v_trial.trial_id IS NOT NULL
      AND v_trial.outcome = 'aborted'
      AND v_trial.p_value IS NULL
  );

  SELECT * INTO v_a FROM register_experiment_preregistration(
    'harden-aborted-only',
    v_spec || jsonb_build_object(
      'hypothesis', 'Aborted-only family has no real p-values.',
      'experiment_family', 'harden-aborted-only',
      'budget', jsonb_build_object('family_trials', 1)
    ),
    NULL, v_exp_lineage);
  PERFORM record_experiment_trial(v_a.registration_id, 'aborted', NULL, v_exp_lineage);
  BEGIN
    PERFORM compute_experiment_family_correction('harden-aborted-only', v_exp_lineage);
    RAISE EXCEPTION 'probe corrupted: aborted-only family correction was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%has no p-values to correct%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('aborted_only_correction_blocked', true);
  END;

  v_spec_a := v_spec || jsonb_build_object(
    'hypothesis', 'Successor-family member A.',
    'experiment_family', 'harden-holm-successor');
  v_spec_b := v_spec || jsonb_build_object(
    'hypothesis', 'Successor-family member B.',
    'experiment_family', 'harden-holm-successor');
  SELECT * INTO v_a FROM register_experiment_preregistration(
    'harden-succ-a', v_spec_a, NULL, v_exp_lineage);
  SELECT * INTO v_b FROM register_experiment_preregistration(
    'harden-succ-b', v_spec_b, NULL, v_exp_lineage);
  PERFORM record_experiment_trial(v_a.registration_id, 'successful', 0.01, v_exp_lineage);
  PERFORM record_experiment_trial(v_b.registration_id, 'successful', 0.04, v_exp_lineage);

  SELECT * INTO v_c FROM register_experiment_preregistration(
    'harden-succ-b',
    v_spec_b || jsonb_build_object('hypothesis', 'Same-family successor of B.'),
    v_b.registration_id, v_exp_lineage);
  SELECT * INTO v_corr FROM compute_experiment_family_correction(
    'harden-holm-successor', v_exp_lineage);
  v_results := v_results || jsonb_build_object(
    'holm_successor_keeps_declared_size',
      v_corr.method = 'holm'
      AND v_corr.member_count = 2
      AND jsonb_array_length(v_corr.adjustments) = 2
      AND (v_corr.adjustments->0->>'p_value')::numeric = 0.01
      AND (v_corr.adjustments->1->>'p_value')::numeric = 1
      AND (v_corr.adjustments->0->>'adjusted_p')::numeric = 0.02
      AND (v_corr.adjustments->1->>'adjusted_p')::numeric = 1
  );

  BEGIN
    PERFORM register_experiment_preregistration(
      'harden-succ-a',
      v_spec_a || jsonb_build_object('experiment_family', 'harden-holm-other'),
      v_a.registration_id, v_exp_lineage);
    RAISE EXCEPTION 'probe corrupted: successor leaving the family was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%family cannot change along a registration successor chain%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('family_change_successor_blocked', true);
  END;

  BEGIN
    PERFORM register_experiment_preregistration(
      'harden-succ-a',
      (v_spec - 'experiment_family') || jsonb_build_object(
        'hypothesis', 'Successor omitting experiment_family.'),
      v_a.registration_id, v_exp_lineage);
    RAISE EXCEPTION 'probe corrupted: successor omitting experiment_family was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%family cannot change along a registration successor chain%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('family_omitted_successor_blocked', true);
  END;

  SELECT * INTO v_experimental FROM append_indicator_definition_version(
    'experimental_harden_gap_wu28_31', 1, 'experimental',
    '{
      "purpose": "Hardening fixture for unique experimental lineage predecessor.",
      "units": "fraction",
      "formula": "mean(gap_return | earnings flag) over lookback",
      "timestamp_semantics": "event-time anchored to announcement receipt",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions with earnings events",
      "missingness": "events without as-of provenance yield no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-harden-wu28-31"}],
      "certified_sources": ["licensed-eod-harden-wu28-31"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 2},
      "valid_ranges": {"min": -1.0, "max": 1.0},
      "golden_cases": [{"name": "no_events", "inputs": {"earnings_flag": []}, "expected": null}],
      "canonical_horizons": [5, 20]
    }'::jsonb,
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_exp_lineage);

  SELECT * INTO v_prereg FROM register_experiment_preregistration(
    'harden-lineage-unique',
    jsonb_build_object(
      'hypothesis', 'Lineage predecessor uniqueness.',
      'rationale', 'A stage record cannot fork two successors.',
      'target', 'next-session open-to-close residual',
      'horizon', 1,
      'universe', 'NYSE common shares with certified earnings provenance',
      'indicator_key', 'experimental_harden_gap_wu28_31',
      'primary_metric', 'net excess return vs cash',
      'stopping_rule', 'halt when testing budget is exhausted',
      'promotion_gate', 'strategy_eligible requires sealed holdout and ablation',
      'experiment_family', 'harden-lineage-unique',
      'testing_budget', jsonb_build_object('family_trials', 2),
      'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
      'estimators', jsonb_build_array('block_bootstrap_lcb'),
      'multiplicity_plan', 'Holm across the family'
    ),
    NULL, v_exp_lineage);

  v_manifest := jsonb_build_object(
    'definition_version_id', v_experimental.definition_version_id,
    'definition_digest', v_experimental.definition_digest,
    'indicator_key', v_experimental.indicator_key,
    'indicator_kind', 'experimental',
    'certified_sources', v_experimental.definition->'certified_sources',
    'registration_id', v_prereg.registration_id,
    'spec_digest', v_prereg.spec_digest,
    'predecessor_stage_record_id', NULL
  );
  SELECT * INTO v_stage FROM register_experimental_indicator_use(
    v_experimental.definition_version_id, v_prereg.registration_id,
    v_manifest, v_exp_lineage);
  SELECT * INTO v_advanced FROM advance_experimental_indicator_stage(
    v_experimental.definition_version_id, 'data_certified',
    jsonb_build_object(
      'definition_version_id', v_experimental.definition_version_id,
      'definition_digest', v_experimental.definition_digest,
      'indicator_key', v_experimental.indicator_key,
      'indicator_kind', 'experimental',
      'certified_sources', v_experimental.definition->'certified_sources',
      'registration_id', v_prereg.registration_id,
      'spec_digest', v_prereg.spec_digest,
      'predecessor_stage_record_id', v_stage.stage_record_id
    ),
    v_exp_lineage);

  BEGIN
    PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'on', true);
    INSERT INTO experimental_indicator_lineage (
      definition_version_id, registration_id, predecessor_stage_record_id,
      lineage_manifest, lineage_digest,
      source_lineage, receipt_time, record_environment
    )
    SELECT
      definition_version_id, registration_id, predecessor_stage_record_id,
      lineage_manifest, lineage_digest,
      source_lineage, clock_timestamp(), record_environment
    FROM experimental_indicator_lineage
    WHERE lineage_id = v_advanced.lineage_id;
    PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'off', true);
    RAISE EXCEPTION 'probe corrupted: duplicate lineage predecessor was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('market_mate.experimental_indicator_lineage_write', 'off', true);
      IF SQLERRM NOT LIKE '%experimental_indicator_lineage_predecessor_uq%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('duplicate_predecessor_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'seal_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.release_holdout_sealed'
    ),
    'correction_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.experiment_family_correction_computed'
        AND payload->>'family_key' = 'harden-holm-declared'
        AND (payload->>'member_count')::integer = 3
    )
  );

  INSERT INTO harden_wu28_31_probe_result (result) VALUES (v_results);
END
$probe$;
