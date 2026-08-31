-- WU-32 Strategy Version registry probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu32_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu32-probe","entitlement_version":"strategy-registry-v1"}';
  v_prereg_spec jsonb;
  v_spec jsonb;
  v_spec_v2 jsonb;
  v_binding jsonb;
  v_binding_wasm jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_other experiment_preregistration%ROWTYPE;
  v_sv strategy_version%ROWTYPE;
  v_sv_again strategy_version%ROWTYPE;
  v_sv_v2 strategy_version%ROWTYPE;
  v_digest text;
  v_results jsonb := '{}'::jsonb;
BEGIN
  v_prereg_spec := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash and the S&P 500.',
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu32-earnings-direction'
  );
  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu32-earnings-direction', v_prereg_spec, NULL, v_lineage);
  SELECT * INTO v_other FROM register_experiment_preregistration(
    'wu32-other',
    jsonb_set(v_prereg_spec, '{hypothesis}', '"Unrelated preregistration."'::jsonb),
    NULL, v_lineage);

  v_spec := jsonb_build_object(
    'dsl_version', 1,
    'universe', jsonb_build_object('instrument_class', 'common_stock', 'sentiment', false),
    'target', 'earnings_direction',
    'rules', jsonb_build_object(
      'entry', 'long when as-of earnings estimate direction is positive vs prior session close',
      'exit', 'flat at next session close',
      'sizing', 'one share unit, no leverage'
    ),
    'comparators', jsonb_build_array('cash', 'sp500'),
    'sp500_comparator', 'hard'
  );
  v_spec_v2 := jsonb_set(
    v_spec, '{rules,sizing}', '"one share unit, no leverage, max 1 position"'::jsonb);
  v_binding := jsonb_build_object(
    'engine_key', 'market-mate-dsl-v1',
    'engine_kind', 'deterministic_dsl',
    'engine_version', '1'
  );
  v_binding_wasm := jsonb_build_object(
    'engine_key', 'market-mate-wasm-escape',
    'engine_kind', 'wasm',
    'engine_version', '1'
  );

  SELECT * INTO v_sv FROM register_strategy_version(
    'wu32-earnings-direction', v_spec, v_binding, v_reg.registration_id, NULL, v_lineage);
  v_digest := strategy_version_digest(
    'wu32-earnings-direction', v_spec, v_binding, v_reg.registration_id);

  v_results := jsonb_build_object(
    'registered_with_preregistration_lineage',
      v_sv.strategy_version_id IS NOT NULL
      AND v_sv.strategy_key = 'wu32-earnings-direction'
      AND v_sv.version = 1
      AND v_sv.registration_id = v_reg.registration_id
      AND v_sv.successor_of IS NULL
      AND v_sv.lifecycle_state = 'frozen'
      AND v_sv.record_environment = 'local_research',
    'content_addressed',
      v_sv.version_digest = v_digest
      AND v_digest ~ '^[0-9a-f]{64}$'
      AND v_digest = encode(
        digest(convert_to(
          'market-mate-strategy-version-v1|' || jsonb_build_object(
            'strategy_key', 'wu32-earnings-direction',
            'spec', v_spec,
            'engine_binding', v_binding,
            'registration_id', v_reg.registration_id
          )::text,
          'UTF8'), 'sha256'),
        'hex'),
    'fixture_strategy_recorded',
      v_sv.spec->>'target' = 'earnings_direction'
      AND v_sv.spec->'universe'->>'instrument_class' = 'common_stock'
      AND (v_sv.spec->'universe'->>'sentiment')::boolean IS FALSE
      AND v_sv.spec->>'sp500_comparator' = 'hard'
      AND v_sv.engine_binding->>'engine_kind' = 'deterministic_dsl'
      AND v_sv.engine_binding->>'engine_key' = 'market-mate-dsl-v1'
  );

  SELECT * INTO v_sv_again FROM register_strategy_version(
    'wu32-earnings-direction', v_spec, v_binding, v_reg.registration_id, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'idempotent_same_artifact',
      v_sv_again.strategy_version_id = v_sv.strategy_version_id
      AND (SELECT count(*) FROM strategy_version
           WHERE strategy_key = 'wu32-earnings-direction') = 1
  );

  BEGIN
    PERFORM register_strategy_version(
      'wu32-earnings-direction', v_spec_v2, v_binding, v_reg.registration_id,
      NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: mutation without successor_of was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already has a version%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('mutation_without_successor_blocked', true);
  END;

  SELECT * INTO v_sv_v2 FROM register_strategy_version(
    'wu32-earnings-direction', v_spec_v2, v_binding, v_reg.registration_id,
    v_sv.strategy_version_id, v_lineage);
  v_results := v_results || jsonb_build_object(
    'mutation_creates_new_version',
      v_sv_v2.strategy_version_id IS DISTINCT FROM v_sv.strategy_version_id
      AND v_sv_v2.version = 2
      AND v_sv_v2.successor_of = v_sv.strategy_version_id
      AND v_sv_v2.lifecycle_state = 'frozen'
      AND v_sv_v2.version_digest IS DISTINCT FROM v_sv.version_digest
      AND (SELECT spec FROM strategy_version
           WHERE strategy_version_id = v_sv.strategy_version_id) = v_spec
      AND (SELECT count(*) FROM strategy_version
           WHERE strategy_key = 'wu32-earnings-direction') = 2
      AND (SELECT strategy_version_id FROM strategy_version_tip('wu32-earnings-direction'))
            = v_sv_v2.strategy_version_id
      AND (SELECT strategy_version_id FROM current_strategy_version
           WHERE strategy_key = 'wu32-earnings-direction')
            = v_sv_v2.strategy_version_id
  );

  BEGIN
    PERFORM register_strategy_version(
      'wu32-earnings-direction',
      jsonb_set(v_spec_v2, '{rules,exit}', '"exit at two sessions"'::jsonb),
      v_binding, v_reg.registration_id, v_sv.strategy_version_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: stale successor_of was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must be the current version%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stale_successor_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-cross', v_spec, v_binding, v_other.registration_id,
      v_sv_v2.strategy_version_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: cross-strategy successor was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must belong to strategy %' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('cross_strategy_successor_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-no-prereg', v_spec, v_binding,
      '00000000-0000-0000-0000-000000000000'::uuid, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown preregistration was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_registration_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-incomplete-dsl', v_spec - 'dsl_version', v_binding,
      v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: spec missing dsl_version was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy dsl spec is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('incomplete_dsl_version_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-incomplete-rules', v_spec - 'rules', v_binding,
      v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: spec missing rules was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy dsl spec is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('incomplete_rules_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-no-cash',
      jsonb_set(v_spec, '{comparators}', '["sp500"]'::jsonb),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: spec without cash comparator was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy dsl spec is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_cash_comparator_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-options',
      jsonb_set(v_spec, '{universe,instrument_class}', '"option"'::jsonb),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: non-stock universe was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy dsl spec is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('non_stock_universe_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-sentiment',
      jsonb_set(v_spec, '{universe,sentiment}', 'true'::jsonb),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: sentiment-enabled universe was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy dsl spec is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('sentiment_universe_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-wasm', v_spec, v_binding_wasm, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: wasm engine binding was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must be deterministic_dsl for DSL v1%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('wasm_engine_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-incomplete-engine', v_spec, v_binding - 'engine_version',
      v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: incomplete engine binding was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%engine binding is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('incomplete_engine_binding_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-live',
      v_spec || jsonb_build_object('authority', 'live'),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: live authority claim was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot grant Paper or Live authority%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('live_authority_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-paper',
      v_spec,
      v_binding || jsonb_build_object('execution_environment', 'paper'),
      v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: paper execution claim was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot grant Paper or Live authority%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('paper_authority_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-key-mismatch',
      v_spec || jsonb_build_object('strategy_key', 'other-key'),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: strategy_key mismatch was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy_key does not match%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('spec_key_mismatch_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-omit-sentiment',
      jsonb_set(v_spec, '{universe}', '{"instrument_class":"common_stock"}'::jsonb),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: universe omitting sentiment was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy dsl spec is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('omitted_sentiment_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-eligible',
      v_spec || jsonb_build_object('strategy_eligible', true),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: strategy_eligible claim was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot grant Paper or Live authority%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('strategy_eligible_claim_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-glossary-live',
      v_spec || jsonb_build_object('lifecycle_state', 'Live Eligible'),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: glossary Live Eligible claim was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot grant Paper or Live authority%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('glossary_live_eligible_blocked', true);
  END;

  BEGIN
    PERFORM register_strategy_version(
      'wu32-unknown-key',
      v_spec || jsonb_build_object('notes', 'not part of dsl v1'),
      v_binding, v_reg.registration_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown spec key was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not part of DSL v1%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_spec_key_blocked', true);
  END;

  BEGIN
    INSERT INTO strategy_version (
      strategy_key, version, spec, engine_binding, registration_id,
      successor_of, lifecycle_state, version_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'wu32-direct', 1, v_spec, v_binding, v_reg.registration_id,
      NULL, 'frozen',
      strategy_version_digest('wu32-direct', v_spec, v_binding, v_reg.registration_id),
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct strategy_version INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through register_strategy_version%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE strategy_version
       SET spec = v_spec_v2
     WHERE strategy_version_id = v_sv.strategy_version_id;
    RAISE EXCEPTION 'probe corrupted: strategy_version was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('version_update_blocked', true);
  END;

  BEGIN
    DELETE FROM strategy_version WHERE strategy_version_id = v_sv.strategy_version_id;
    RAISE EXCEPTION 'probe corrupted: strategy_version was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('version_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE strategy_version;
    RAISE EXCEPTION 'probe corrupted: strategy_version was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy_version is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('version_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'appends_audited', (
      SELECT count(*) = 2
      FROM audit_event
      WHERE event_type = 'research.strategy_version_registered'
        AND payload->>'strategy_key' = 'wu32-earnings-direction'
        AND payload->>'lifecycle_state' = 'frozen'
    ),
    'original_never_mutates',
      (SELECT spec FROM strategy_version
       WHERE strategy_version_id = v_sv.strategy_version_id) = v_spec
      AND (SELECT version_digest FROM strategy_version
           WHERE strategy_version_id = v_sv.strategy_version_id) = v_digest
  );

  INSERT INTO wu32_probe_result (result) VALUES (v_results);
END
$probe$;
