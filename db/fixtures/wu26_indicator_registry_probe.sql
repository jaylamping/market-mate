-- WU-26 Indicator definition registry probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu26_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu26-probe","entitlement_version":"indicator-registry-v1"}';
  v_core_v1 indicator_definition_version%ROWTYPE;
  v_core_v2 indicator_definition_version%ROWTYPE;
  v_experimental indicator_definition_version%ROWTYPE;
  v_core_v1_lifecycle indicator_definition_lifecycle%ROWTYPE;
  v_early_row indicator_definition_version%ROWTYPE;
  v_late_row indicator_definition_version%ROWTYPE;
  v_current_state text;
  v_results jsonb;
BEGIN
  -- One registered source the definitions may cite.
  INSERT INTO source_registry (
    source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'licensed-eod-wu26', 'Licensed EOD WU-26 Provider', 'market_data',
    v_lineage, now(), 'local_research'
  );

  SELECT * INTO v_core_v1 FROM append_indicator_definition_version(
    'close_return_20d', 1, 'core',
    '{
      "purpose": "Descriptive 20-session close-to-close return for research context; never a universal alpha signal.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped; a horizon shorter than 20 complete sessions yields no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu26"}],
      "certified_sources": ["licensed-eod-wu26"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [
        {"name": "flat_series", "inputs": {"close": [100, 100, 100]}, "expected": 0.0}
      ],
      "canonical_horizons": [1, 20]
    }'::jsonb,
    NULL,
    '2026-01-01T00:00:00Z'::timestamptz,
    v_lineage
  );

  SELECT * INTO v_experimental FROM append_indicator_definition_version(
    'experimental_earnings_gap_bias', 1, 'experimental',
    '{
      "purpose": "Preregistered predictive hypothesis: earnings-day gap bias under a strategy experiment; excluded from Core.",
      "units": "fraction",
      "formula": "mean(gap_return | earnings flag) over lookback",
      "timestamp_semantics": "event-time anchored to announcement receipt",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions with earnings events",
      "missingness": "events without as-of provenance yield no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu26"}, {"name": "earnings_flag", "source": "licensed-eod-wu26"}],
      "certified_sources": ["licensed-eod-wu26"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 2},
      "valid_ranges": {"min": -1.0, "max": 1.0},
      "golden_cases": [
        {"name": "no_events", "inputs": {"earnings_flag": []}, "expected": null}
      ],
      "canonical_horizons": [5, 20, 60]
    }'::jsonb,
    NULL,
    '2026-01-01T00:00:00Z'::timestamptz,
    v_lineage
  );

  -- A semantic change creates a new version, linked to its predecessor.
  SELECT * INTO v_core_v2 FROM append_indicator_definition_version(
    'close_return_20d', 2, 'core',
    '{
      "purpose": "Descriptive 20-session close-to-close return for research context; never a universal alpha signal.",
      "units": "fraction",
      "formula": "close[t] / close[t-20] - 1 with volume confirmation",
      "timestamp_semantics": "session close, point-in-time at cycle as_of",
      "adjustment_semantics": "split-adjusted, dividend-unadjusted",
      "calendar": "NYSE trading sessions",
      "missingness": "missing sessions are skipped; a horizon shorter than 20 complete sessions yields no observation",
      "ownership": "research-engine",
      "inputs": [{"name": "session_close", "source": "licensed-eod-wu26"}, {"name": "session_volume", "source": "licensed-eod-wu26"}],
      "certified_sources": ["licensed-eod-wu26"],
      "precision": 12,
      "freshness": {"max_receipt_lag_sessions": 1},
      "valid_ranges": {"min": -1.0, "max": 25.0},
      "golden_cases": [
        {"name": "flat_series", "inputs": {"close": [100, 100, 100]}, "expected": 0.0}
      ],
      "canonical_horizons": [1, 20]
    }'::jsonb,
    v_core_v1.definition_version_id,
    '2026-03-01T00:00:00Z'::timestamptz,
    v_lineage
  );

  v_results := jsonb_build_object(
    'core_v1_declared', v_core_v1.definition_state = 'declared'
      AND v_core_v1.indicator_kind = 'core',
    'digest_content_addressed',
      v_core_v1.definition_digest
      = encode(digest(convert_to(v_core_v1.definition::text, 'UTF8'), 'sha256'), 'hex')
      AND v_core_v1.definition_digest <> v_core_v2.definition_digest,
    'experimental_starts_experimental',
      v_experimental.definition_state = 'experimental'
      AND v_experimental.indicator_kind = 'experimental',
    'semantic_change_creates_new_version',
      v_core_v2.version = 2
      AND v_core_v1.version = 1
      AND v_core_v1.definition <> v_core_v2.definition,
    'successor_lineage_recorded',
      v_core_v2.successor_of = v_core_v1.definition_version_id
  );

  -- Historical evaluations keep their definition versions: the decision-time
  -- view before v2's effective date still resolves v1.
  SELECT * INTO v_early_row
  FROM indicator_definition_version v
  WHERE v.indicator_key = 'close_return_20d'
    AND v.effective_from <= '2026-02-01T00:00:00Z'::timestamptz
  ORDER BY v.version DESC LIMIT 1;
  SELECT * INTO v_late_row
  FROM indicator_definition_version v
  WHERE v.indicator_key = 'close_return_20d'
    AND v.effective_from <= '2026-04-01T00:00:00Z'::timestamptz
  ORDER BY v.version DESC LIMIT 1;
  v_results := v_results || jsonb_build_object(
    'historical_evaluation_keeps_its_version', v_early_row.version = 1,
    'later_as_of_resolves_new_version', v_late_row.version = 2
  );

  -- The current view resolves the latest version per indicator.
  v_results := v_results || jsonb_build_object('current_view_latest_versions', (
    SELECT count(*) = 2
      AND count(*) FILTER (WHERE indicator_key = 'close_return_20d' AND version = 2) = 1
      AND count(*) FILTER (WHERE indicator_key = 'experimental_earnings_gap_bias' AND version = 1) = 1
    FROM current_indicator_definition
  ));

  -- Invalid definitions fail closed.
  BEGIN
    PERFORM append_indicator_definition_version(
      'invalid_indicator', 1, 'core',
      '{
        "purpose": "Missing golden cases and horizon discipline.",
        "units": "fraction", "formula": "x", "timestamp_semantics": "s",
        "adjustment_semantics": "s", "calendar": "c", "missingness": "m",
        "ownership": "o", "inputs": [{"name": "x"}], "certified_sources": ["licensed-eod-wu26"],
        "precision": 1, "freshness": {}, "valid_ranges": {},
        "golden_cases": [], "canonical_horizons": [13]
      }'::jsonb,
      NULL, '2026-01-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: invalid definition was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%incomplete, mistyped, or uses a noncanonical horizon%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object(
        'missing_golden_cases_blocked', true, 'noncanonical_horizon_blocked', true);
  END;

  -- Unregistered sources fail closed.
  BEGIN
    PERFORM append_indicator_definition_version(
      'bad_source_indicator', 1, 'core',
      '{
        "purpose": "Cites an unregistered source.",
        "units": "fraction", "formula": "x", "timestamp_semantics": "s",
        "adjustment_semantics": "s", "calendar": "c", "missingness": "m",
        "ownership": "o", "inputs": [{"name": "x", "source": "not-registered"}],
        "certified_sources": ["not-registered"],
        "precision": 1, "freshness": {}, "valid_ranges": {},
        "golden_cases": [{"name": "g", "expected": 1}],
        "canonical_horizons": [5]
      }'::jsonb,
      NULL, '2026-01-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: unregistered source was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%unregistered source%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unregistered_source_blocked', true);
  END;

  -- Duplicate versions and version skips fail closed.
  BEGIN
    PERFORM append_indicator_definition_version(
      'close_return_20d', 1, 'core',
      '{
        "purpose": "Duplicate of an immutable version.",
        "units": "fraction", "formula": "x", "timestamp_semantics": "s",
        "adjustment_semantics": "s", "calendar": "c", "missingness": "m",
        "ownership": "o", "inputs": [{"name": "x"}], "certified_sources": ["licensed-eod-wu26"],
        "precision": 1, "freshness": {}, "valid_ranges": {},
        "golden_cases": [{"name": "g", "expected": 1}],
        "canonical_horizons": [5]
      }'::jsonb,
      NULL, '2026-01-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: duplicate version was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%versions are immutable%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('duplicate_version_blocked', true);
  END;

  BEGIN
    PERFORM append_indicator_definition_version(
      'close_return_20d', 4, 'core',
      '{
        "purpose": "Version skip.",
        "units": "fraction", "formula": "x", "timestamp_semantics": "s",
        "adjustment_semantics": "s", "calendar": "c", "missingness": "m",
        "ownership": "o", "inputs": [{"name": "x"}], "certified_sources": ["licensed-eod-wu26"],
        "precision": 1, "freshness": {}, "valid_ranges": {},
        "golden_cases": [{"name": "g", "expected": 1}],
        "canonical_horizons": [5]
      }'::jsonb,
      NULL, '2026-01-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: version skip was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%directly after its latest version%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('version_skip_blocked', true);
  END;

  -- A new version must declare the latest version as its successor.
  BEGIN
    PERFORM append_indicator_definition_version(
      'close_return_20d', 3, 'core',
      '{
        "purpose": "Wrong successor lineage.",
        "units": "fraction", "formula": "x", "timestamp_semantics": "s",
        "adjustment_semantics": "s", "calendar": "c", "missingness": "m",
        "ownership": "o", "inputs": [{"name": "x"}], "certified_sources": ["licensed-eod-wu26"],
        "precision": 1, "freshness": {}, "valid_ranges": {},
        "golden_cases": [{"name": "g", "expected": 1}],
        "canonical_horizons": [5]
      }'::jsonb,
      v_core_v1.definition_version_id, '2026-05-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: wrong successor_of was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%declare the latest version as its successor_of%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('wrong_successor_blocked', true);
  END;

  -- A successful experiment never becomes a core indicator.
  BEGIN
    PERFORM record_indicator_definition_lifecycle(
      v_experimental.definition_version_id, 'declared',
      'promote experiment to core', NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: experimental -> declared was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%transition experimental -> declared is illegal%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('experimental_to_declared_blocked', true);
  END;

  -- Unknown definitions cannot transition.
  BEGIN
    PERFORM record_indicator_definition_lifecycle(
      '00000000-0000-0000-0000-000000000000'::uuid, 'retired',
      'unknown version', NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown definition transitioned';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_definition_lifecycle_blocked', true);
  END;

  -- Retirement is an appended lifecycle record; the version row never mutates.
  v_core_v1_lifecycle := record_indicator_definition_lifecycle(
    v_core_v1.definition_version_id, 'retired',
    'superseded by version 2', NULL, v_lineage);

  v_current_state := indicator_definition_current_state(v_core_v1.definition_version_id);
  v_results := v_results || jsonb_build_object(
    'retirement_is_lifecycle_record',
      v_current_state = 'retired'
      AND (SELECT definition_state FROM indicator_definition_version
           WHERE definition_version_id = v_core_v1.definition_version_id) = 'declared'
      AND v_core_v1_lifecycle.from_state = 'declared',
    'retired_definition_still_resolvable_by_version', (
      SELECT definition_version_id = v_core_v1.definition_version_id
      FROM indicator_definition_version
      WHERE definition_version_id = v_core_v1.definition_version_id
    )
  );

  BEGIN
    PERFORM record_indicator_definition_lifecycle(
      v_core_v1.definition_version_id, 'declared',
      'revive retired definition', NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: retired definition revived';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%transition retired -> declared is illegal%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('retired_never_revisible', true);
  END;

  -- Append-only guards.
  BEGIN
    UPDATE indicator_definition_version
       SET definition = definition || '{"tamper":true}'::jsonb
     WHERE definition_version_id = v_core_v1.definition_version_id;
    RAISE EXCEPTION 'probe corrupted: definition was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('definition_update_blocked', true);
  END;

  BEGIN
    DELETE FROM indicator_definition_version
     WHERE definition_version_id = v_core_v1.definition_version_id;
    RAISE EXCEPTION 'probe corrupted: definition was deletable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('definition_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE indicator_definition_lifecycle;
    RAISE EXCEPTION 'probe corrupted: lifecycle was truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('lifecycle_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'appends_audited', (
      SELECT count(*) = 3
      FROM audit_event
      WHERE event_type = 'research.indicator_definition_appended'
    ),
    'retirement_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.indicator_definition_lifecycle_recorded'
        AND payload->>'to_state' = 'retired'
    )
  );

  INSERT INTO wu26_probe_result (result) VALUES (v_results);
END
$probe$;
