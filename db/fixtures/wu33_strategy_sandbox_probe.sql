-- WU-33 Deterministic evaluation sandbox probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu33_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu33-probe","entitlement_version":"strategy-sandbox-v1"}';
  v_prereg_spec jsonb;
  v_spec jsonb;
  v_spec_prose jsonb;
  v_binding jsonb;
  v_payload jsonb;
  v_payload_secret jsonb;
  v_payload_url jsonb;
  v_payload_big jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_sv strategy_version%ROWTYPE;
  v_sv_prose strategy_version%ROWTYPE;
  v_snap research_snapshot%ROWTYPE;
  v_eval strategy_sandbox_evaluation%ROWTYPE;
  v_eval_again strategy_sandbox_evaluation%ROWTYPE;
  v_first jsonb;
  v_second jsonb;
  v_digest text;
  v_results jsonb := '{}'::jsonb;
  v_symbols jsonb := '[]'::jsonb;
  v_i integer;
BEGIN
  v_prereg_spec := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash and the S&P 500.',
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu33-earnings-direction'
  );
  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu33-earnings-direction', v_prereg_spec, NULL, v_lineage);

  v_spec := jsonb_build_object(
    'dsl_version', 1,
    'universe', jsonb_build_object('instrument_class', 'common_stock', 'sentiment', false),
    'target', 'earnings_direction',
    'rules', jsonb_build_object(
      'entry', jsonb_build_object(
        'signal', 'earnings_surprise_bps', 'op', 'gt', 'threshold', 0, 'side', 'long'),
      'exit', jsonb_build_object('horizon_sessions', 1),
      'sizing', jsonb_build_object('units', 1)
    ),
    'comparators', jsonb_build_array('cash', 'sp500'),
    'sp500_comparator', 'hard'
  );
  v_spec_prose := jsonb_build_object(
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
  v_binding := jsonb_build_object(
    'engine_key', 'market-mate-dsl-v1',
    'engine_kind', 'deterministic_dsl',
    'engine_version', '1'
  );
  v_payload := jsonb_build_object(
    'symbols', jsonb_build_array('AAA', 'BBB'),
    'sessions', jsonb_build_array('2026-01-05', '2026-01-06', '2026-01-07'),
    'eod', jsonb_build_array(
      jsonb_build_object(
        'symbol', 'AAA',
        'bars', jsonb_build_array(
          jsonb_build_object('session', '2026-01-05', 'close_cents', 10000),
          jsonb_build_object('session', '2026-01-06', 'close_cents', 10100),
          jsonb_build_object('session', '2026-01-07', 'close_cents', 10200)
        )
      ),
      jsonb_build_object(
        'symbol', 'BBB',
        'bars', jsonb_build_array(
          jsonb_build_object('session', '2026-01-05', 'close_cents', 10000),
          jsonb_build_object('session', '2026-01-06', 'close_cents', 9900),
          jsonb_build_object('session', '2026-01-07', 'close_cents', 9800)
        )
      )
    ),
    'earnings', jsonb_build_array(
      jsonb_build_object(
        'symbol', 'AAA', 'as_of_session', '2026-01-05', 'earnings_surprise_bps', 150),
      jsonb_build_object(
        'symbol', 'BBB', 'as_of_session', '2026-01-05', 'earnings_surprise_bps', -50)
    ),
    'sp500', jsonb_build_object(
      'bars', jsonb_build_array(
        jsonb_build_object('session', '2026-01-05', 'close_cents', 10000),
        jsonb_build_object('session', '2026-01-06', 'close_cents', 10050),
        jsonb_build_object('session', '2026-01-07', 'close_cents', 10100)
      )
    )
  );

  v_first := strategy_sandbox_evaluate_program(v_spec, v_payload);
  v_second := strategy_sandbox_evaluate_program(v_spec, v_payload);
  v_digest := strategy_sandbox_result_digest(v_first);
  v_results := jsonb_build_object(
    'double_run_digest_match',
      v_first = v_second
      AND v_digest = strategy_sandbox_result_digest(v_second)
      AND v_digest ~ '^[0-9a-f]{64}$',
    'fixture_evaluation_deterministic',
      (v_first->>'trade_count')::integer = 1
      AND (v_first->>'mean_return_bps')::bigint = 100
      AND (v_first->>'cash_return_bps')::bigint = 0
      AND (v_first->>'excess_vs_cash_bps')::bigint = 100
      AND (v_first->>'sp500_return_bps')::bigint = 50
      AND (v_first->>'excess_vs_sp500_bps')::bigint = 50
      AND v_first->>'engine_kind' = 'deterministic_dsl'
      AND v_first->>'target' = 'earnings_direction'
      AND v_first->'trades'->0->>'symbol' = 'AAA'
      AND (v_first->'trades'->0->>'return_bps')::bigint = 100
  );

  BEGIN
    PERFORM strategy_sandbox_evaluate_program(v_spec_prose, v_payload);
    RAISE EXCEPTION 'probe corrupted: prose DSL rules were evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not executable in the deterministic sandbox%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('prose_rules_blocked', true);
  END;

  BEGIN
    PERFORM strategy_sandbox_evaluate_program(
      jsonb_set(v_spec, '{rules,entry,signal}', '"http_url"'::jsonb),
      v_payload);
    RAISE EXCEPTION 'probe corrupted: out-of-scope signal was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not executable in the deterministic sandbox%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('out_of_scope_signal_blocked', true);
  END;

  v_payload_secret := v_payload || jsonb_build_object('api_key', 'not-a-real-secret');
  BEGIN
    PERFORM strategy_sandbox_evaluate_program(v_spec, v_payload_secret);
    RAISE EXCEPTION 'probe corrupted: credential-shaped snapshot was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%credential-shaped or out of scope%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('credential_payload_blocked', true);
  END;

  v_payload_url := v_payload || jsonb_build_object('url', 'https://example.invalid');
  BEGIN
    PERFORM strategy_sandbox_evaluate_program(v_spec, v_payload_url);
    RAISE EXCEPTION 'probe corrupted: network-shaped snapshot was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%credential-shaped or out of scope%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('network_payload_blocked', true);
  END;

  BEGIN
    PERFORM strategy_sandbox_evaluate_program(
      v_spec,
      jsonb_set(
        v_payload,
        '{sp500,bars,0}',
        (v_payload->'sp500'->'bars'->0) || jsonb_build_object('url', 'https://example.invalid')
      )
    );
    RAISE EXCEPTION 'probe corrupted: network-shaped SP500 bar was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('sp500_bar_out_of_scope_blocked', true);
  END;

  BEGIN
    PERFORM strategy_sandbox_evaluate_program(
      v_spec, v_payload || jsonb_build_object('notes', 'extra'));
    RAISE EXCEPTION 'probe corrupted: extra snapshot key was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('extra_snapshot_key_blocked', true);
  END;

  FOR v_i IN 1 .. 33 LOOP
    v_symbols := v_symbols || jsonb_build_array('S' || lpad(v_i::text, 2, '0'));
  END LOOP;
  v_payload_big := jsonb_set(v_payload, '{symbols}', v_symbols);
  BEGIN
    PERFORM strategy_sandbox_evaluate_program(v_spec, v_payload_big);
    RAISE EXCEPTION 'probe corrupted: 33-symbol snapshot was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%exceeds the resource bound%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('resource_bound_blocked', true);
  END;

  SELECT * INTO v_sv FROM register_strategy_version(
    'wu33-earnings-direction', v_spec, v_binding, v_reg.registration_id, NULL, v_lineage);
  SELECT * INTO v_sv_prose FROM register_strategy_version(
    'wu33-prose', v_spec_prose, v_binding, v_reg.registration_id, NULL, v_lineage);
  SELECT * INTO v_snap FROM append_research_snapshot(
    'strategy_sandbox_v1', v_payload, v_lineage, NULL, NULL);

  SELECT * INTO v_eval FROM record_strategy_sandbox_evaluation(
    v_sv.strategy_version_id, v_snap.snapshot_id, v_lineage);
  SELECT * INTO v_eval_again FROM record_strategy_sandbox_evaluation(
    v_sv.strategy_version_id, v_snap.snapshot_id, v_lineage);
  v_results := v_results || jsonb_build_object(
    'recorded_evaluation',
      v_eval.evaluation_id IS NOT NULL
      AND v_eval.strategy_version_id = v_sv.strategy_version_id
      AND v_eval.snapshot_id = v_snap.snapshot_id
      AND v_eval.result_digest = v_digest
      AND v_eval.result = v_first
      AND v_eval.record_environment = 'local_research',
    'record_is_idempotent',
      v_eval_again.evaluation_id = v_eval.evaluation_id
      AND (SELECT count(*) FROM strategy_sandbox_evaluation
           WHERE strategy_version_id = v_sv.strategy_version_id
             AND snapshot_id = v_snap.snapshot_id) = 1
  );

  BEGIN
    PERFORM record_strategy_sandbox_evaluation(
      v_sv_prose.strategy_version_id, v_snap.snapshot_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: prose Strategy Version was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not executable in the deterministic sandbox%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('prose_strategy_record_blocked', true);
  END;

  BEGIN
    PERFORM record_strategy_sandbox_evaluation(
      '00000000-0000-0000-0000-000000000000'::uuid, v_snap.snapshot_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown strategy version was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_strategy_blocked', true);
  END;

  BEGIN
    PERFORM record_strategy_sandbox_evaluation(
      v_sv.strategy_version_id, '00000000-0000-0000-0000-000000000000'::uuid, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown snapshot was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_snapshot_blocked', true);
  END;

  BEGIN
    INSERT INTO strategy_sandbox_evaluation (
      strategy_version_id, snapshot_id, result, result_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_sv.strategy_version_id, v_snap.snapshot_id, v_first, v_digest,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct sandbox evaluation INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through record_strategy_sandbox_evaluation%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE strategy_sandbox_evaluation
       SET result = v_first
     WHERE evaluation_id = v_eval.evaluation_id;
    RAISE EXCEPTION 'probe corrupted: sandbox evaluation was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('evaluation_update_blocked', true);
  END;

  BEGIN
    DELETE FROM strategy_sandbox_evaluation
     WHERE evaluation_id = v_eval.evaluation_id;
    RAISE EXCEPTION 'probe corrupted: sandbox evaluation was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('evaluation_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE strategy_sandbox_evaluation;
    RAISE EXCEPTION 'probe corrupted: sandbox evaluation was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%strategy_sandbox_evaluation is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('evaluation_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'evaluation_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.strategy_sandbox_evaluated'
        AND payload->>'result_digest' = v_digest
    )
  );

  INSERT INTO wu33_probe_result (result) VALUES (v_results);
END
$probe$;
