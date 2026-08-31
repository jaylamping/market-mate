-- WU-36 Block-bootstrap LCB probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu36_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu36-probe","entitlement_version":"bootstrap-lcb-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_const jsonb := '[]'::jsonb;
  v_vary jsonb := '[]'::jsonb;
  v_sp jsonb := '[]'::jsonb;
  v_cons jsonb;
  v_cons_alt jsonb;
  v_r jsonb;
  v_r2 jsonb;
  v_r_alt jsonb;
  v_run block_bootstrap_run%ROWTYPE;
  v_run_again block_bootstrap_run%ROWTYPE;
  v_run_sv block_bootstrap_run%ROWTYPE;
  v_obs jsonb;
  v_eis eis_estimate%ROWTYPE;
  v_from_eis jsonb;
  v_prereg jsonb;
  v_spec jsonb;
  v_binding jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_sv strategy_version%ROWTYPE;
  v_i integer;
BEGIN
  FOR v_i IN 1 .. 8 LOOP
    v_const := v_const || jsonb_build_array(
      jsonb_build_object(
        'session', to_char(DATE '2010-01-04' + (v_i - 1), 'YYYY-MM-DD'),
        'strategy_bps', 100,
        'comparator_bps', 0
      )
    );
    v_vary := v_vary || jsonb_build_array(
      jsonb_build_object(
        'session', to_char(DATE '2010-01-04' + (v_i - 1), 'YYYY-MM-DD'),
        'strategy_bps', (v_i * 20) - 10,
        'comparator_bps', 5
      )
    );
    v_sp := v_sp || jsonb_build_array(
      jsonb_build_object(
        'session', to_char(DATE '2010-01-04' + (v_i - 1), 'YYYY-MM-DD'),
        'strategy_bps', (v_i * 20) - 10,
        'comparator_bps', 8
      )
    );
  END LOOP;

  v_cons := jsonb_build_object(
    'method', 'moving_block_bootstrap',
    'block_length', 2,
    'replications', 100,
    'seed', 42,
    'confidence', 95,
    'side', 'one_sided_lower'
  );
  v_cons_alt := jsonb_set(v_cons, '{seed}', '7'::jsonb);

  v_r := compute_block_bootstrap_lcb(v_const, v_cons);
  v_r2 := compute_block_bootstrap_lcb(v_const, v_cons);
  v_results := jsonb_build_object(
    'constant_series_lcb',
      (v_r->>'mean_excess_bps')::bigint = 100
      AND (v_r->>'lcb_excess_bps')::bigint = 100
      AND (v_r->>'n')::integer = 8
      AND (v_r->>'replications')::integer = 100
      AND (v_r->>'seed')::bigint = 42
      AND v_r->>'method' = 'moving_block_bootstrap'
      AND v_r->>'side' = 'one_sided_lower',
    'seeded_replay_identical',
      v_r = v_r2
      AND v_r->>'result_digest' = bootstrap_result_digest(v_r - 'result_digest')
      AND (v_r->>'result_digest') ~ '^[0-9a-f]{64}$'
      AND (v_r->>'means_digest') ~ '^[0-9a-f]{64}$'
  );

  v_r := compute_block_bootstrap_lcb(v_vary, v_cons);
  v_r_alt := compute_block_bootstrap_lcb(v_vary, v_cons_alt);
  v_r2 := compute_block_bootstrap_lcb(v_vary, v_cons);
  v_results := v_results || jsonb_build_object(
    'varying_replay_identical',
      v_r = v_r2
      AND v_r->>'result_digest' = v_r2->>'result_digest',
    'seed_is_material',
      v_r->>'means_digest' IS DISTINCT FROM v_r_alt->>'means_digest'
      AND (v_r->>'seed')::bigint = 42
      AND (v_r_alt->>'seed')::bigint = 7,
    'lcb_is_one_sided',
      (v_r->>'lcb_excess_bps')::bigint <= (v_r->>'mean_excess_bps')::bigint
      AND (v_r->>'quantile_index')::integer = 5
  );

  v_obs := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'i1', 'thesis_key', 't', 'issuer', 'AAA',
      'issuer_event_id', 'AAA:1', 'entry_session', '2010-01-04',
      'exit_session', '2010-01-05', 'attempt_group_id', 'i1', 'return_bps', 40),
    jsonb_build_object(
      'observation_id', 'i2', 'thesis_key', 't', 'issuer', 'BBB',
      'issuer_event_id', 'BBB:1', 'entry_session', '2010-01-06',
      'exit_session', '2010-01-07', 'attempt_group_id', 'i2', 'return_bps', 10),
    jsonb_build_object(
      'observation_id', 'i3', 'thesis_key', 't', 'issuer', 'CCC',
      'issuer_event_id', 'CCC:1', 'entry_session', '2010-01-08',
      'exit_session', '2010-01-09', 'attempt_group_id', 'i3', 'return_bps', -20)
  );
  SELECT * INTO v_eis FROM record_eis_estimate(v_obs, NULL, v_lineage);
  v_from_eis := bootstrap_pairs_from_eis_result(v_eis.result);
  v_r := compute_block_bootstrap_lcb(v_from_eis, v_cons);
  v_results := v_results || jsonb_build_object(
    'pairs_from_eis_clusters',
      jsonb_array_length(v_from_eis) = 3
      AND (v_from_eis->0->>'comparator_bps')::bigint = 0
      AND (v_r->>'n')::integer = 3
      AND (v_r->>'lcb_excess_bps') IS NOT NULL
  );

  SELECT * INTO v_run FROM record_block_bootstrap_lcb(
    v_const, v_cons, NULL, NULL, v_lineage);
  SELECT * INTO v_run_again FROM record_block_bootstrap_lcb(
    v_const, v_cons, NULL, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'recorded_run',
      v_run.run_id IS NOT NULL
      AND v_run.record_environment = 'local_research'
      AND (v_run.result->>'lcb_excess_bps')::bigint = 100
      AND (v_run.result->>'seed')::bigint = 42
      AND v_run.result_digest ~ '^[0-9a-f]{64}$',
    'record_is_idempotent',
      v_run_again.run_id = v_run.run_id
      AND (SELECT count(*) FROM block_bootstrap_run
           WHERE pairs_digest = v_run.pairs_digest
             AND construction_digest = v_run.construction_digest) = 1
  );

  SELECT * INTO v_run FROM record_block_bootstrap_lcb(
    NULL, v_cons, NULL, v_eis.estimate_id, v_lineage);
  v_results := v_results || jsonb_build_object(
    'recorded_from_eis',
      v_run.eis_estimate_id = v_eis.estimate_id
      AND v_run.pairs = v_from_eis
      AND (v_run.result->>'n')::integer = 3
  );

  v_prereg := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash and the S&P 500.',
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu36-earnings-direction'
  );
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
  v_binding := jsonb_build_object(
    'engine_key', 'market-mate-dsl-v1',
    'engine_kind', 'deterministic_dsl',
    'engine_version', '1'
  );
  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu36-earnings-direction', v_prereg, NULL, v_lineage);
  SELECT * INTO v_sv FROM register_strategy_version(
    'wu36-earnings-direction', v_spec, v_binding, v_reg.registration_id, NULL, v_lineage);
  SELECT * INTO v_run_sv FROM record_block_bootstrap_lcb(
    v_vary, v_cons, v_sv.strategy_version_id, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'construction_bound_to_strategy',
      v_run_sv.strategy_version_id = v_sv.strategy_version_id
      AND v_run_sv.construction = v_cons
      AND (v_run_sv.result->>'seed')::bigint = 42
  );

  SELECT * INTO v_run FROM record_block_bootstrap_lcb(
    v_sp, v_cons, v_sv.strategy_version_id, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'second_comparator_same_construction',
      v_run.strategy_version_id = v_sv.strategy_version_id
      AND v_run.run_id IS DISTINCT FROM v_run_sv.run_id
      AND v_run.construction_digest = v_run_sv.construction_digest
      AND v_run.pairs_digest IS DISTINCT FROM v_run_sv.pairs_digest
  );

  BEGIN
    PERFORM record_block_bootstrap_lcb(
      v_const, v_cons_alt, v_sv.strategy_version_id, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: construction changed after results';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot change after results exist%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('construction_frozen_after_results', true);
  END;

  BEGIN
    PERFORM compute_block_bootstrap_lcb(
      v_const, jsonb_set(v_cons, '{method}', '"iid_bootstrap"'::jsonb));
    RAISE EXCEPTION 'probe corrupted: non-block method was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not preregistered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('other_method_blocked', true);
  END;

  BEGIN
    PERFORM compute_block_bootstrap_lcb(
      v_const, jsonb_set(v_cons, '{replications}', '10'::jsonb));
    RAISE EXCEPTION 'probe corrupted: short replication count was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not preregistered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('short_replications_blocked', true);
  END;

  BEGIN
    PERFORM compute_block_bootstrap_lcb(
      v_const, jsonb_set(v_cons, '{block_length}', '9'::jsonb));
    RAISE EXCEPTION 'probe corrupted: block length longer than the series was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not preregistered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('oversized_block_blocked', true);
  END;

  BEGIN
    PERFORM compute_block_bootstrap_lcb(
      v_const || jsonb_build_array(
        jsonb_build_object(
          'session', '2010-01-20', 'strategy_bps', 1, 'comparator_bps', 0,
          'api_key', 'not-a-real-secret')
      ),
      v_cons
    );
    RAISE EXCEPTION 'probe corrupted: credential pair key was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('credential_key_blocked', true);
  END;

  BEGIN
    PERFORM compute_block_bootstrap_lcb(
      jsonb_set(v_const, '{0,paper_eligible}', 'true'::jsonb), v_cons);
    RAISE EXCEPTION 'probe corrupted: paper_eligible pair was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('paper_key_blocked', true);
  END;

  BEGIN
    PERFORM compute_block_bootstrap_lcb('[]'::jsonb, v_cons);
    RAISE EXCEPTION 'probe corrupted: empty pairs were accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%resource bound%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('empty_pairs_blocked', true);
  END;

  BEGIN
    PERFORM record_block_bootstrap_lcb(
      v_const, v_cons, '00000000-0000-0000-0000-000000000000'::uuid, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown strategy version was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_strategy_blocked', true);
  END;

  BEGIN
    INSERT INTO block_bootstrap_run (
      construction, construction_digest, pairs, pairs_digest,
      result, result_digest, source_lineage, receipt_time, record_environment
    ) VALUES (
      v_run.construction, v_run.construction_digest, v_run.pairs, v_run.pairs_digest,
      v_run.result, v_run.result_digest, v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct block_bootstrap_run INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through record_block_bootstrap_lcb%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE block_bootstrap_run SET result = v_run.result WHERE run_id = v_run.run_id;
    RAISE EXCEPTION 'probe corrupted: bootstrap run was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_update_blocked', true);
  END;

  BEGIN
    DELETE FROM block_bootstrap_run WHERE run_id = v_run.run_id;
    RAISE EXCEPTION 'probe corrupted: bootstrap run was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE block_bootstrap_run;
    RAISE EXCEPTION 'probe corrupted: bootstrap run was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%block_bootstrap_run is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'run_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.block_bootstrap_lcb_recorded'
        AND payload->>'result_digest' = v_run_sv.result_digest
    )
  );

  INSERT INTO wu36_probe_result (result) VALUES (v_results);
END
$probe$;
