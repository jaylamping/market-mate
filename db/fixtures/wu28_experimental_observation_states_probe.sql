-- WU-28 Experimental observation states probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu28_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu28-probe","entitlement_version":"indicator-registry-v1"}';
  v_experimental_def jsonb := '{
      "purpose": "Preregistered predictive hypothesis: earnings-day gap bias under a strategy experiment; excluded from Core.",
      "units": "fraction",
      "formula": "mean(gap_return | earnings flag) over lookback",
      "timestamp_semantics": "event-time anchored to announcement receipt",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions with earnings events",
      "missingness": "events without as-of provenance yield no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu28"}, {"name": "earnings_flag", "source": "licensed-eod-wu28"}],
      "certified_sources": ["licensed-eod-wu28"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 2},
      "valid_ranges": {"min": -1.0, "max": 1.0},
      "golden_cases": [
        {"name": "no_events", "inputs": {"earnings_flag": []}, "expected": null}
      ],
      "canonical_horizons": [5, 20, 60]
    }'::jsonb;
  v_core_def jsonb := '{
      "purpose": "Descriptive 20-session close-to-close return for research context; never a universal alpha signal.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped; a horizon shorter than 20 complete sessions yields no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu28"}],
      "certified_sources": ["licensed-eod-wu28"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [
        {"name": "flat_series", "inputs": {"close": [100, 100, 100]}, "expected": 0.0}
      ],
      "canonical_horizons": [1, 20]
    }'::jsonb;
  v_spec jsonb;
  v_incomplete_spec jsonb;
  v_wrong_key_spec jsonb;
  v_experimental indicator_definition_version%ROWTYPE;
  v_experimental_v2 indicator_definition_version%ROWTYPE;
  v_other_experimental indicator_definition_version%ROWTYPE;
  v_retired_experimental indicator_definition_version%ROWTYPE;
  v_core indicator_definition_version%ROWTYPE;
  v_prereg experiment_preregistration%ROWTYPE;
  v_incomplete_prereg experiment_preregistration%ROWTYPE;
  v_wrong_key_prereg experiment_preregistration%ROWTYPE;
  v_other_prereg experiment_preregistration%ROWTYPE;
  v_retired_prereg experiment_preregistration%ROWTYPE;
  v_manifest jsonb;
  v_stage experimental_indicator_stage%ROWTYPE;
  v_latest experimental_indicator_stage%ROWTYPE;
  v_results jsonb := '{}'::jsonb;
  v_current_stage text;
  v_omit text;
  v_omit_spec jsonb;
  v_omit_prereg experiment_preregistration%ROWTYPE;
BEGIN
  INSERT INTO source_registry (
    source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'licensed-eod-wu28', 'Licensed EOD WU-28 Provider', 'market_data',
    v_lineage, now(), 'local_research'
  );

  SELECT * INTO v_experimental FROM append_indicator_definition_version(
    'experimental_earnings_gap_bias_wu28', 1, 'experimental',
    v_experimental_def, NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage);

  SELECT * INTO v_other_experimental FROM append_indicator_definition_version(
    'experimental_volume_shock_wu28', 1, 'experimental',
    jsonb_set(v_experimental_def, '{purpose}',
      '"Separate experimental indicator used to prove one preregistration cannot bind two definitions."'::jsonb),
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage);

  SELECT * INTO v_retired_experimental FROM append_indicator_definition_version(
    'experimental_retired_gap_wu28', 1, 'experimental',
    jsonb_set(v_experimental_def, '{purpose}',
      '"Retired experimental indicator must not enter evidence stages."'::jsonb),
    NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage);
  PERFORM record_indicator_definition_lifecycle(
    v_retired_experimental.definition_version_id, 'retired',
    'retired before experimental evidence-stage registration', NULL, v_lineage);

  SELECT * INTO v_core FROM append_indicator_definition_version(
    'close_return_20d_wu28', 1, 'core',
    v_core_def, NULL, '2026-01-01T00:00:00Z'::timestamptz, v_lineage);

  v_spec := jsonb_build_object(
    'hypothesis', 'Earnings-day gap bias is predictive under the preregistered windows.',
    'rationale', 'Event-time gap after certified as-of estimates, never a Core signal.',
    'target', 'next-session open-to-close residual',
    'horizon', 1,
    'universe', 'NYSE common shares with certified earnings provenance',
    'indicator_key', 'experimental_earnings_gap_bias_wu28',
    'primary_metric', 'net excess return vs cash',
    'stopping_rule', 'halt when testing budget is exhausted',
    'promotion_gate', 'strategy_eligible requires sealed holdout and ablation',
    'experiment_family', 'earnings-gap-bias-wu28',
    'testing_budget', jsonb_build_object('family_trials', 8),
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'multiplicity_plan', 'Holm across the earnings-gap-bias family'
  );
  v_incomplete_spec := v_spec - 'hypothesis';
  v_wrong_key_spec := jsonb_set(v_spec, '{indicator_key}', '"close_return_20d_wu28"'::jsonb);

  INSERT INTO experiment_preregistration (
    experiment_key, spec, spec_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'wu28-earnings-gap',
    v_spec,
    encode(digest('market-mate-preregistration-v1|' || v_spec::text, 'sha256'), 'hex'),
    v_lineage, now(), 'local_research'
  ) RETURNING * INTO v_prereg;

  INSERT INTO experiment_preregistration (
    experiment_key, spec, spec_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'wu28-earnings-gap-incomplete',
    v_incomplete_spec,
    encode(digest('market-mate-preregistration-v1|' || v_incomplete_spec::text, 'sha256'), 'hex'),
    v_lineage, now(), 'local_research'
  ) RETURNING * INTO v_incomplete_prereg;

  INSERT INTO experiment_preregistration (
    experiment_key, spec, spec_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'wu28-earnings-gap-wrong-key',
    v_wrong_key_spec,
    encode(digest('market-mate-preregistration-v1|' || v_wrong_key_spec::text, 'sha256'), 'hex'),
    v_lineage, now(), 'local_research'
  ) RETURNING * INTO v_wrong_key_prereg;

  INSERT INTO experiment_preregistration (
    experiment_key, spec, spec_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'wu28-volume-shock',
    jsonb_set(v_spec, '{indicator_key}', '"experimental_volume_shock_wu28"'::jsonb),
    encode(digest(
      'market-mate-preregistration-v1|'
      || jsonb_set(v_spec, '{indicator_key}', '"experimental_volume_shock_wu28"'::jsonb)::text,
      'sha256'), 'hex'),
    v_lineage, now(), 'local_research'
  ) RETURNING * INTO v_other_prereg;

  INSERT INTO experiment_preregistration (
    experiment_key, spec, spec_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'wu28-retired-gap',
    jsonb_set(v_spec, '{indicator_key}', '"experimental_retired_gap_wu28"'::jsonb),
    encode(digest(
      'market-mate-preregistration-v1|'
      || jsonb_set(v_spec, '{indicator_key}', '"experimental_retired_gap_wu28"'::jsonb)::text,
      'sha256'), 'hex'),
    v_lineage, now(), 'local_research'
  ) RETURNING * INTO v_retired_prereg;

  v_results := jsonb_build_object(
    'recorded_as_experimental',
      v_experimental.indicator_kind = 'experimental'
      AND v_experimental.definition_state = 'experimental'
      AND indicator_definition_current_state(v_experimental.definition_version_id) = 'experimental'
  );

  BEGIN
    PERFORM core_indicator_definition_for_compute(
      'experimental_earnings_gap_bias_wu28', now());
    RAISE EXCEPTION 'probe corrupted: experimental indicator was accepted as Core';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%experimental indicators are excluded from Core computation%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('experimental_excluded_from_core', true);
  END;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental.definition_version_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', '00000000-0000-0000-0000-000000000000',
        'spec_digest', v_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown preregistration was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%experiment preregistration % is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_preregistration_blocked', true);
  END;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental.definition_version_id,
      v_incomplete_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_incomplete_prereg.registration_id,
        'spec_digest', v_incomplete_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: incomplete preregistration spec was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%spec is incomplete for experimental indicator promotion%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('incomplete_preregistration_blocked', true);
  END;

  FOREACH v_omit IN ARRAY ARRAY[
    'horizon', 'universe', 'stopping_rule', 'promotion_gate', 'testing_budget'
  ]
  LOOP
    v_omit_spec := v_spec - v_omit;
    INSERT INTO experiment_preregistration (
      experiment_key, spec, spec_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'wu28-omit-' || v_omit,
      v_omit_spec,
      encode(digest('market-mate-preregistration-v1|' || v_omit_spec::text, 'sha256'), 'hex'),
      v_lineage, now(), 'local_research'
    ) RETURNING * INTO v_omit_prereg;
    BEGIN
      PERFORM register_experimental_indicator_use(
        v_experimental.definition_version_id,
        v_omit_prereg.registration_id,
        jsonb_build_object(
          'definition_version_id', v_experimental.definition_version_id,
          'definition_digest', v_experimental.definition_digest,
          'indicator_key', v_experimental.indicator_key,
          'indicator_kind', 'experimental',
          'certified_sources', v_experimental.definition->'certified_sources',
          'registration_id', v_omit_prereg.registration_id,
          'spec_digest', v_omit_prereg.spec_digest,
          'predecessor_stage_record_id', NULL
        ),
        v_lineage);
      RAISE EXCEPTION 'probe corrupted: spec missing % was accepted', v_omit;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%spec is incomplete for experimental indicator promotion%' THEN RAISE; END IF;
        v_results := v_results || jsonb_build_object('incomplete_' || v_omit || '_blocked', true);
    END;
  END LOOP;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental.definition_version_id,
      v_wrong_key_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_wrong_key_prereg.registration_id,
        'spec_digest', v_wrong_key_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: mismatched preregistration indicator_key was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%indicator_key does not match definition%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('mismatched_preregistration_indicator_blocked', true);
  END;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental.definition_version_id,
      v_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_prereg.registration_id,
        'spec_digest', v_prereg.spec_digest
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: lineage missing predecessor_stage_record_id was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%lineage manifest is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('lineage_missing_predecessor_blocked', true);
  END;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental.definition_version_id,
      v_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', repeat('0', 64),
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_prereg.registration_id,
        'spec_digest', v_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: lineage with the wrong definition digest was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%lineage manifest is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('lineage_digest_mismatch_blocked', true);
  END;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_core.definition_version_id,
      v_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_core.definition_version_id,
        'definition_digest', v_core.definition_digest,
        'indicator_key', v_core.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_core.definition->'certified_sources',
        'registration_id', v_prereg.registration_id,
        'spec_digest', v_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: core indicator entered experimental evidence stages';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%core indicators cannot enter experimental evidence stages%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('core_cannot_enter_experimental_stages', true);
  END;

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_retired_experimental.definition_version_id,
      v_retired_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_retired_experimental.definition_version_id,
        'definition_digest', v_retired_experimental.definition_digest,
        'indicator_key', v_retired_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_retired_experimental.definition->'certified_sources',
        'registration_id', v_retired_prereg.registration_id,
        'spec_digest', v_retired_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: retired experimental indicator was registered';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%retired experimental indicator % cannot be registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('retired_experimental_register_blocked', true);
  END;

  BEGIN
    PERFORM advance_experimental_indicator_stage(
      v_experimental.definition_version_id, 'data_certified',
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_prereg.registration_id,
        'spec_digest', v_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: stage advanced without preregistration';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%has no preregistration%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('advance_without_preregistration_blocked', true);
  END;

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
    v_manifest, v_lineage);

  v_results := v_results || jsonb_build_object(
    'registered_with_preregistration_and_lineage',
      v_stage.to_stage = 'registered'
      AND v_stage.from_stage = 'unregistered'
      AND experimental_indicator_current_stage(v_experimental.definition_version_id) = 'registered'
      AND experimental_indicator_bound_registration(v_experimental.definition_version_id)
            = v_prereg.registration_id
      AND (SELECT lineage_digest FROM experimental_indicator_lineage
           WHERE lineage_id = v_stage.lineage_id)
            = encode(digest(convert_to(v_manifest::text, 'UTF8'), 'sha256'), 'hex')
  );

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental.definition_version_id, v_prereg.registration_id,
      v_manifest, v_lineage);
    RAISE EXCEPTION 'probe corrupted: duplicate experimental registration was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already has an evidence stage%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('duplicate_registration_blocked', true);
  END;

  SELECT * INTO v_experimental_v2 FROM append_indicator_definition_version(
    'experimental_earnings_gap_bias_wu28', 2, 'experimental',
    jsonb_set(v_experimental_def, '{formula}',
      '"mean(gap_return | earnings flag) over lookback with volume confirmation"'::jsonb),
    v_experimental.definition_version_id,
    '2026-03-01T00:00:00Z'::timestamptz, v_lineage);

  BEGIN
    PERFORM register_experimental_indicator_use(
      v_experimental_v2.definition_version_id, v_prereg.registration_id,
      jsonb_build_object(
        'definition_version_id', v_experimental_v2.definition_version_id,
        'definition_digest', v_experimental_v2.definition_digest,
        'indicator_key', v_experimental_v2.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental_v2.definition->'certified_sources',
        'registration_id', v_prereg.registration_id,
        'spec_digest', v_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: one preregistration bound two experimental definitions';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already bound to an experimental definition%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('preregistration_cannot_bind_second_definition', true);
  END;

  BEGIN
    PERFORM advance_experimental_indicator_stage(
      v_experimental.definition_version_id, 'paper_eligible',
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
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: skipped experimental evidence stage was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%transition registered -> paper_eligible is illegal%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stage_skip_blocked', true);
  END;



  BEGIN
    PERFORM record_indicator_definition_lifecycle(
      v_experimental.definition_version_id, 'declared',
      'promote experiment to core', v_prereg.registration_id::text, v_lineage);
    RAISE EXCEPTION 'probe corrupted: experimental -> declared was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%transition experimental -> declared is illegal%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('experimental_never_becomes_core', true);
  END;

  BEGIN
    PERFORM advance_experimental_indicator_stage(
      v_experimental.definition_version_id, 'data_certified',
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_other_prereg.registration_id,
        'spec_digest', v_other_prereg.spec_digest,
        'predecessor_stage_record_id', v_stage.stage_record_id
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: stage advanced under a different preregistration';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%lineage manifest is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('foreign_preregistration_advance_blocked', true);
  END;

  BEGIN
    PERFORM advance_experimental_indicator_stage(
      v_experimental.definition_version_id, 'data_certified',
      jsonb_build_object(
        'definition_version_id', v_experimental.definition_version_id,
        'definition_digest', v_experimental.definition_digest,
        'indicator_key', v_experimental.indicator_key,
        'indicator_kind', 'experimental',
        'certified_sources', v_experimental.definition->'certified_sources',
        'registration_id', v_prereg.registration_id,
        'spec_digest', v_prereg.spec_digest,
        'predecessor_stage_record_id', NULL
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: advance with a null predecessor was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%lineage manifest is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stale_predecessor_blocked', true);
  END;

  v_latest := v_stage;
  SELECT * INTO v_stage FROM advance_experimental_indicator_stage(
    v_experimental.definition_version_id, 'data_certified',
    jsonb_build_object(
      'definition_version_id', v_experimental.definition_version_id,
      'definition_digest', v_experimental.definition_digest,
      'indicator_key', v_experimental.indicator_key,
      'indicator_kind', 'experimental',
      'certified_sources', v_experimental.definition->'certified_sources',
      'registration_id', v_prereg.registration_id,
      'spec_digest', v_prereg.spec_digest,
      'predecessor_stage_record_id', v_latest.stage_record_id
    ),
    v_lineage);
  v_latest := v_stage;
  SELECT * INTO v_stage FROM advance_experimental_indicator_stage(
    v_experimental.definition_version_id, 'research_qualified',
    jsonb_build_object(
      'definition_version_id', v_experimental.definition_version_id,
      'definition_digest', v_experimental.definition_digest,
      'indicator_key', v_experimental.indicator_key,
      'indicator_kind', 'experimental',
      'certified_sources', v_experimental.definition->'certified_sources',
      'registration_id', v_prereg.registration_id,
      'spec_digest', v_prereg.spec_digest,
      'predecessor_stage_record_id', v_latest.stage_record_id
    ),
    v_lineage);
  v_latest := v_stage;
  SELECT * INTO v_stage FROM advance_experimental_indicator_stage(
    v_experimental.definition_version_id, 'paper_eligible',
    jsonb_build_object(
      'definition_version_id', v_experimental.definition_version_id,
      'definition_digest', v_experimental.definition_digest,
      'indicator_key', v_experimental.indicator_key,
      'indicator_kind', 'experimental',
      'certified_sources', v_experimental.definition->'certified_sources',
      'registration_id', v_prereg.registration_id,
      'spec_digest', v_prereg.spec_digest,
      'predecessor_stage_record_id', v_latest.stage_record_id
    ),
    v_lineage);
  v_latest := v_stage;
  SELECT * INTO v_stage FROM advance_experimental_indicator_stage(
    v_experimental.definition_version_id, 'strategy_eligible',
    jsonb_build_object(
      'definition_version_id', v_experimental.definition_version_id,
      'definition_digest', v_experimental.definition_digest,
      'indicator_key', v_experimental.indicator_key,
      'indicator_kind', 'experimental',
      'certified_sources', v_experimental.definition->'certified_sources',
      'registration_id', v_prereg.registration_id,
      'spec_digest', v_prereg.spec_digest,
      'predecessor_stage_record_id', v_latest.stage_record_id
    ),
    v_lineage);

  v_current_stage := experimental_indicator_current_stage(v_experimental.definition_version_id);
  v_results := v_results || jsonb_build_object(
    'full_stage_path_recorded',
      v_current_stage = 'strategy_eligible'
      AND v_stage.to_stage = 'strategy_eligible'
      AND (SELECT count(*) FROM experimental_indicator_stage
           WHERE definition_version_id = v_experimental.definition_version_id) = 5
      AND (SELECT count(*) FROM experimental_indicator_lineage
           WHERE definition_version_id = v_experimental.definition_version_id) = 5,
    'strategy_eligible_stays_experimental',
      v_experimental.indicator_kind = 'experimental'
      AND (SELECT definition_state FROM indicator_definition_version
           WHERE definition_version_id = v_experimental.definition_version_id) = 'experimental'
      AND indicator_definition_current_state(v_experimental.definition_version_id) = 'experimental'
      AND (SELECT current_stage FROM current_experimental_indicator_stage
           WHERE definition_version_id = v_experimental.definition_version_id) = 'strategy_eligible'
      AND (SELECT indicator_kind FROM current_experimental_indicator_stage
           WHERE definition_version_id = v_experimental.definition_version_id) = 'experimental'
  );

  BEGIN
    PERFORM core_indicator_definition_for_compute(
      'experimental_earnings_gap_bias_wu28', now());
    RAISE EXCEPTION 'probe corrupted: strategy_eligible experimental indicator became Core';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%experimental indicators are excluded from Core computation%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('strategy_eligible_still_excluded_from_core', true);
  END;

  BEGIN
    PERFORM advance_experimental_indicator_stage(
      v_experimental.definition_version_id, 'paper_eligible',
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
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: reverse experimental evidence stage was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%transition strategy_eligible -> paper_eligible is illegal%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stage_reverse_blocked', true);
  END;

  BEGIN
    INSERT INTO experimental_indicator_lineage (
      definition_version_id, registration_id, lineage_manifest, lineage_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_experimental.definition_version_id, v_prereg.registration_id,
      '{}'::jsonb, repeat('a', 64),
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct lineage INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through register_experimental_indicator_use or advance_experimental_indicator_stage%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_lineage_insert_blocked', true);
  END;

  BEGIN
    INSERT INTO experimental_indicator_stage (
      definition_version_id, lineage_id, from_stage, to_stage,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_experimental.definition_version_id, v_stage.lineage_id,
      'strategy_eligible', 'paper_eligible',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct stage INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through register_experimental_indicator_use or advance_experimental_indicator_stage%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_stage_insert_blocked', true);
  END;

  BEGIN
    UPDATE experimental_indicator_stage
       SET to_stage = 'registered'
     WHERE stage_record_id = v_stage.stage_record_id;
    RAISE EXCEPTION 'probe corrupted: experimental stage was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stage_update_blocked', true);
  END;

  BEGIN
    DELETE FROM experimental_indicator_lineage
     WHERE lineage_id = v_stage.lineage_id;
    RAISE EXCEPTION 'probe corrupted: experimental lineage was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('lineage_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE experimental_indicator_stage, experimental_indicator_lineage;
    RAISE EXCEPTION 'probe corrupted: experimental evidence stages were truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stage_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'appends_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.experimental_indicator_registered'
        AND payload->>'definition_version_id' = v_experimental.definition_version_id::text
    ),
    'advances_audited', (
      SELECT count(*) = 4
      FROM audit_event
      WHERE event_type = 'research.experimental_indicator_stage_advanced'
        AND payload->>'definition_version_id' = v_experimental.definition_version_id::text
    )
  );

  INSERT INTO wu28_probe_result (result) VALUES (v_results);
END
$probe$;
