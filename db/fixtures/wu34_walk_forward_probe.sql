-- WU-34 Walk-forward engine probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu34_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu34-probe","entitlement_version":"walk-forward-v1"}';
  v_cal date[] := '{}';
  v_cal_alt date[] := '{}';
  v_d date := DATE '2010-01-04';
  v_prereg_spec jsonb;
  v_spec jsonb;
  v_binding jsonb;
  v_payload jsonb;
  v_payload_61 jsonb;
  v_sessions_61 jsonb := '[]'::jsonb;
  v_bars_61 jsonb := '[]'::jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_sv strategy_version%ROWTYPE;
  v_cal_row walk_forward_calendar%ROWTYPE;
  v_cal_row_again walk_forward_calendar%ROWTYPE;
  v_cal_alt_row walk_forward_calendar%ROWTYPE;
  v_snap research_snapshot%ROWTYPE;
  v_run walk_forward_run%ROWTYPE;
  v_run_again walk_forward_run%ROWTYPE;
  v_plan jsonb;
  v_fold jsonb;
  v_results jsonb := '{}'::jsonb;
  v_i integer;
  v_idx integer;
  v_test1_start date;
  v_test1_end date;
  v_test2_start date;
  v_test2_end date;
  v_test3_start date;
  v_test3_end date;
  v_train1_start date;
  v_train1_end date;
  v_purge1_start date;
  v_purge1_end date;
  v_train2_start date;
  v_train2_end date;
  v_purge2_start date;
  v_purge2_end date;
  v_train3_start date;
  v_train3_end date;
  v_purge3_start date;
  v_purge3_end date;
  v_entry_dates date[] := '{}';
  v_sessions jsonb;
  v_aaa_bars jsonb;
  v_bbb_bars jsonb;
  v_sp_bars jsonb;
  v_earnings jsonb := '[]'::jsonb;
  v_sliced jsonb;
  v_first jsonb;
  v_second jsonb;
BEGIN
  WHILE cardinality(v_cal) < 845 LOOP
    IF extract(isodow FROM v_d) < 6 THEN
      v_cal := v_cal || v_d;
    END IF;
    v_d := v_d + 1;
  END LOOP;
  v_d := DATE '2009-12-01';
  WHILE cardinality(v_cal_alt) < 5 LOOP
    IF extract(isodow FROM v_d) < 6 THEN
      v_cal_alt := v_cal_alt || v_d;
    END IF;
    v_d := v_d + 1;
  END LOOP;
  v_cal_alt := v_cal_alt || v_cal;

  v_train1_start := v_cal[1];
  v_train1_end := v_cal[20];
  v_purge1_start := v_cal[21];
  v_purge1_end := v_cal[25];
  v_test1_start := v_cal[26];
  v_test1_end := v_cal[275];
  v_train2_start := v_cal[1];
  v_train2_end := v_cal[275];
  v_purge2_start := v_cal[276];
  v_purge2_end := v_cal[280];
  v_test2_start := v_cal[281];
  v_test2_end := v_cal[530];
  v_train3_start := v_cal[1];
  v_train3_end := v_cal[530];
  v_purge3_start := v_cal[531];
  v_purge3_end := v_cal[535];
  v_test3_start := v_cal[536];
  v_test3_end := v_cal[785];
  v_entry_dates := ARRAY[v_test1_start, v_test2_start, v_test3_start];

  v_prereg_spec := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash and the S&P 500.',
    'windows', jsonb_build_object(
      'walk_forward', 3,
      'holdout_sessions', 60,
      'purge_gap_sessions', 5,
      'folds', jsonb_build_array(
        jsonb_build_object(
          'train_start', to_char(v_train1_start, 'YYYY-MM-DD'),
          'train_end', to_char(v_train1_end, 'YYYY-MM-DD'),
          'purge_start', to_char(v_purge1_start, 'YYYY-MM-DD'),
          'purge_end', to_char(v_purge1_end, 'YYYY-MM-DD'),
          'test_start', to_char(v_test1_start, 'YYYY-MM-DD'),
          'test_end', to_char(v_test1_end, 'YYYY-MM-DD')
        ),
        jsonb_build_object(
          'train_start', to_char(v_train2_start, 'YYYY-MM-DD'),
          'train_end', to_char(v_train2_end, 'YYYY-MM-DD'),
          'purge_start', to_char(v_purge2_start, 'YYYY-MM-DD'),
          'purge_end', to_char(v_purge2_end, 'YYYY-MM-DD'),
          'test_start', to_char(v_test2_start, 'YYYY-MM-DD'),
          'test_end', to_char(v_test2_end, 'YYYY-MM-DD')
        ),
        jsonb_build_object(
          'train_start', to_char(v_train3_start, 'YYYY-MM-DD'),
          'train_end', to_char(v_train3_end, 'YYYY-MM-DD'),
          'purge_start', to_char(v_purge3_start, 'YYYY-MM-DD'),
          'purge_end', to_char(v_purge3_end, 'YYYY-MM-DD'),
          'test_start', to_char(v_test3_start, 'YYYY-MM-DD'),
          'test_end', to_char(v_test3_end, 'YYYY-MM-DD')
        )
      )
    ),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu34-earnings-direction'
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

  SELECT jsonb_agg(to_char(d, 'YYYY-MM-DD') ORDER BY ord),
         jsonb_agg(jsonb_build_object(
           'session', to_char(d, 'YYYY-MM-DD'),
           'close_cents', CASE
             WHEN d IN (v_cal[27], v_cal[282], v_cal[537]) THEN 10100
             ELSE 10000
           END
         ) ORDER BY ord),
         jsonb_agg(jsonb_build_object(
           'session', to_char(d, 'YYYY-MM-DD'),
           'close_cents', 10000
         ) ORDER BY ord),
         jsonb_agg(jsonb_build_object(
           'session', to_char(d, 'YYYY-MM-DD'),
           'close_cents', 10050
         ) ORDER BY ord)
  INTO v_sessions, v_aaa_bars, v_bbb_bars, v_sp_bars
  FROM unnest(v_cal) WITH ORDINALITY AS t(d, ord);

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'symbol', 'AAA',
      'as_of_session', to_char(d, 'YYYY-MM-DD'),
      'earnings_surprise_bps', 150
    ) ORDER BY d
  ), '[]'::jsonb)
  INTO v_earnings
  FROM unnest(v_entry_dates) AS d;

  v_payload := jsonb_build_object(
    'symbols', jsonb_build_array('AAA', 'BBB'),
    'sessions', v_sessions,
    'eod', jsonb_build_array(
      jsonb_build_object('symbol', 'AAA', 'bars', v_aaa_bars),
      jsonb_build_object('symbol', 'BBB', 'bars', v_bbb_bars)
    ),
    'earnings', v_earnings,
    'sp500', jsonb_build_object('bars', v_sp_bars)
  );

  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu34-earnings-direction', v_prereg_spec, NULL, v_lineage);
  SELECT * INTO v_sv FROM register_strategy_version(
    'wu34-earnings-direction', v_spec, v_binding, v_reg.registration_id, NULL, v_lineage);
  SELECT * INTO v_cal_row FROM register_walk_forward_calendar(v_cal, v_lineage);
  SELECT * INTO v_cal_row_again FROM register_walk_forward_calendar(v_cal, v_lineage);
  SELECT * INTO v_snap FROM append_research_snapshot(
    'walk_forward_v1', v_payload, v_lineage, NULL, NULL);

  v_plan := walk_forward_compile_plan(v_prereg_spec, v_cal);
  v_sliced := walk_forward_slice_payload(
    v_payload, walk_forward_sessions_in_range(v_cal, v_test1_start, v_test1_end));
  v_first := strategy_sandbox_evaluate_program_bounded(v_spec, v_sliced, 2000, 1048576);
  v_second := strategy_sandbox_evaluate_program_bounded(v_spec, v_sliced, 2000, 1048576);

  SELECT * INTO v_run FROM record_walk_forward_run(
    v_sv.strategy_version_id, v_cal_row.calendar_id, v_snap.snapshot_id, v_lineage);
  SELECT * INTO v_run_again FROM record_walk_forward_run(
    v_sv.strategy_version_id, v_cal_row.calendar_id, v_snap.snapshot_id, v_lineage);

  v_results := jsonb_build_object(
    'calendar_registered',
      v_cal_row.session_count = 845
      AND v_cal_row.record_environment = 'local_research'
      AND v_cal_row.calendar_digest ~ '^[0-9a-f]{64}$'
      AND v_cal_row_again.calendar_id = v_cal_row.calendar_id,
    'three_windows_recorded',
      (v_run.window_plan->>'walk_forward')::integer = 3
      AND jsonb_array_length(v_run.window_plan->'folds') = 3
      AND jsonb_array_length(v_run.manifest->'folds') = 3
      AND v_run.record_environment = 'local_research',
    'each_test_ge_250',
      (SELECT bool_and((f->>'test_sessions')::integer >= 250)
       FROM jsonb_array_elements(v_run.window_plan->'folds') f),
    'disjoint_tests',
      (v_run.window_plan->'folds'->0->>'test_end')::date
        < (v_run.window_plan->'folds'->1->>'test_start')::date
      AND (v_run.window_plan->'folds'->1->>'test_end')::date
        < (v_run.window_plan->'folds'->2->>'test_start')::date,
    'purge_gap_present',
      (SELECT bool_and((f->>'purge_sessions')::integer >= 5)
       FROM jsonb_array_elements(v_run.window_plan->'folds') f),
    'no_train_test_overlap',
      (SELECT bool_and(
          (f->>'train_end')::date < (f->>'purge_start')::date
          AND (f->>'purge_end')::date < (f->>'test_start')::date
        )
       FROM jsonb_array_elements(v_run.window_plan->'folds') f),
    'no_purge_leakage',
      (SELECT bool_and(
          (t->>'entry_session')::date >= (f->>'test_start')::date
          AND (t->>'exit_session')::date <= (f->>'test_end')::date
          AND (t->>'entry_session')::date > (f->>'purge_end')::date
        )
       FROM jsonb_array_elements(v_run.manifest->'folds') mf
       JOIN jsonb_array_elements(v_run.window_plan->'folds') f
         ON (f->>'window_index')::integer = (mf->>'window_index')::integer
       CROSS JOIN jsonb_array_elements(mf->'result'->'trades') t),
    'holdout_excluded',
      (v_run.window_plan->'folds'->2->>'test_end')::date
        < (v_run.window_plan->>'holdout_start')::date
      AND (v_run.window_plan->>'holdout_sessions')::integer = 60,
    'slice_excludes_train_and_purge',
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(v_sliced->'sessions') s
        WHERE s::date <= v_purge1_end
      ),
    'double_run_digest_match',
      v_first = v_second
      AND strategy_sandbox_result_digest(v_first)
        = strategy_sandbox_result_digest(v_second)
      AND (v_first->>'trade_count')::integer = 1
      AND (v_first->>'mean_return_bps')::bigint = 100,
    'record_is_idempotent',
      v_run_again.run_id = v_run.run_id
      AND (SELECT count(*) FROM walk_forward_run
           WHERE strategy_version_id = v_sv.strategy_version_id) = 1
      AND v_run.manifest_digest ~ '^[0-9a-f]{64}$',
    'fixture_evaluation_deterministic',
      v_run.manifest->>'engine' = 'walk_forward_v1'
      AND v_run.manifest->'folds'->0->>'result_digest'
        = strategy_sandbox_result_digest(v_first)
  );

  BEGIN
    PERFORM walk_forward_slice_payload(
      v_payload || jsonb_build_object('api_key', 'not-a-real-secret'),
      walk_forward_sessions_in_range(v_cal, v_test1_start, v_test1_end));
    RAISE EXCEPTION 'probe corrupted: credential-shaped source payload was sliced';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%credential-shaped or out of scope%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('credential_source_payload_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_slice_payload(
      v_payload || jsonb_build_object('notes', 'extra'),
      walk_forward_sessions_in_range(v_cal, v_test1_start, v_test1_end));
    RAISE EXCEPTION 'probe corrupted: extra source key was sliced away';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('extra_source_key_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_slice_payload(
      jsonb_set(
        v_payload,
        '{eod,0,bars,0}',
        (v_payload->'eod'->0->'bars'->0) || jsonb_build_object('url', 'https://example.invalid')
      ),
      walk_forward_sessions_in_range(v_cal, v_test1_start, v_test1_end)
    );
    RAISE EXCEPTION 'probe corrupted: network-shaped source bar was sliced away';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('source_bar_out_of_scope_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_slice_payload(
      jsonb_set(v_payload, '{sessions}', jsonb_build_object('api_key', 'not-a-real-secret')),
      walk_forward_sessions_in_range(v_cal, v_test1_start, v_test1_end));
    RAISE EXCEPTION 'probe corrupted: credential-shaped sessions node was sliced away';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not admissible%'
         AND SQLERRM NOT LIKE '%credential-shaped or out of scope%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('sessions_object_blocked', true);
  END;

  BEGIN
    PERFORM strategy_sandbox_evaluate_program(v_spec, v_sliced);
    RAISE EXCEPTION 'probe corrupted: 250-session slice passed the 60-session cap';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%exceeds the resource bound%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('sandbox_session_cap_still_enforced', true);
  END;

  FOR v_i IN 0 .. 60 LOOP
    v_sessions_61 := v_sessions_61 || jsonb_build_array(to_char(v_cal[v_i + 1], 'YYYY-MM-DD'));
    v_bars_61 := v_bars_61 || jsonb_build_array(
      jsonb_build_object('session', to_char(v_cal[v_i + 1], 'YYYY-MM-DD'), 'close_cents', 10000)
    );
  END LOOP;
  v_payload_61 := jsonb_build_object(
    'symbols', jsonb_build_array('AAA'),
    'sessions', v_sessions_61,
    'eod', jsonb_build_array(jsonb_build_object('symbol', 'AAA', 'bars', v_bars_61)),
    'earnings', '[]'::jsonb,
    'sp500', jsonb_build_object('bars', v_bars_61)
  );
  BEGIN
    PERFORM strategy_sandbox_evaluate_program(v_spec, v_payload_61);
    RAISE EXCEPTION 'probe corrupted: 61-session snapshot was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%exceeds the resource bound%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('sixty_one_session_snapshot_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_compile_plan(
      jsonb_set(
        v_prereg_spec,
        '{windows,folds,0,test_end}',
        to_jsonb(to_char(v_cal[274], 'YYYY-MM-DD'))
      ),
      v_cal
    );
    RAISE EXCEPTION 'probe corrupted: 249-day test window was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%shorter than 250 trading days%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('short_window_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_compile_plan(
      jsonb_set(
        jsonb_set(v_prereg_spec, '{windows,walk_forward}', '2'::jsonb),
        '{windows,folds}',
        (v_prereg_spec->'windows'->'folds') - 2
      ),
      v_cal
    );
    RAISE EXCEPTION 'probe corrupted: two walk-forward windows were accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%windows are not preregistered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('two_windows_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_compile_plan(
      jsonb_set(
        v_prereg_spec,
        '{windows,folds,0,test_end}',
        to_jsonb(to_char(v_cal[300], 'YYYY-MM-DD'))
      ),
      v_cal
    );
    RAISE EXCEPTION 'probe corrupted: overlapping test windows were accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%windows are not disjoint%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('overlapping_windows_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_compile_plan(
      jsonb_set(
        v_prereg_spec,
        '{windows,folds,0,train_end}',
        to_jsonb(to_char(v_test1_end, 'YYYY-MM-DD'))
      ),
      v_cal
    );
    RAISE EXCEPTION 'probe corrupted: train/test overlap was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%train and test overlap%'
         AND SQLERRM NOT LIKE '%purge gap is missing or leaked%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('train_test_overlap_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_compile_plan(
      jsonb_set(
        v_prereg_spec,
        '{windows,folds,0,purge_end}',
        to_jsonb(to_char(v_test1_start, 'YYYY-MM-DD'))
      ),
      v_cal
    );
    RAISE EXCEPTION 'probe corrupted: purge leakage was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%purge gap is missing or leaked%'
         AND SQLERRM NOT LIKE '%train and test overlap%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('purge_leakage_blocked', true);
  END;

  BEGIN
    PERFORM walk_forward_compile_plan(
      jsonb_set(
        v_prereg_spec,
        '{windows,folds,2,test_end}',
        to_jsonb(to_char(v_cal[845], 'YYYY-MM-DD'))
      ),
      v_cal
    );
    RAISE EXCEPTION 'probe corrupted: holdout overlap was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%overlap the release holdout%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('holdout_overlap_blocked', true);
  END;

  SELECT * INTO v_cal_alt_row FROM register_walk_forward_calendar(v_cal_alt, v_lineage);
  BEGIN
    PERFORM record_walk_forward_run(
      v_sv.strategy_version_id, v_cal_alt_row.calendar_id, v_snap.snapshot_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: window placement changed after results';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot change after results exist%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('placement_frozen_after_results', true);
  END;

  BEGIN
    INSERT INTO walk_forward_run (
      strategy_version_id, registration_id, calendar_id, snapshot_id,
      window_plan, window_plan_digest, manifest, manifest_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_sv.strategy_version_id, v_reg.registration_id, v_cal_row.calendar_id,
      v_snap.snapshot_id, v_run.window_plan, v_run.window_plan_digest,
      v_run.manifest, v_run.manifest_digest, v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct walk-forward run INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through record_walk_forward_run%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE walk_forward_run
       SET manifest = v_run.manifest
     WHERE run_id = v_run.run_id;
    RAISE EXCEPTION 'probe corrupted: walk-forward run was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_update_blocked', true);
  END;

  BEGIN
    DELETE FROM walk_forward_run WHERE run_id = v_run.run_id;
    RAISE EXCEPTION 'probe corrupted: walk-forward run was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE walk_forward_run;
    RAISE EXCEPTION 'probe corrupted: walk-forward run was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%walk_forward_run is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_truncate_blocked', true);
  END;

  BEGIN
    TRUNCATE walk_forward_calendar, walk_forward_run;
    RAISE EXCEPTION 'probe corrupted: walk-forward calendar was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('calendar_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'run_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.walk_forward_run_recorded'
        AND payload->>'manifest_digest' = v_run.manifest_digest
    )
  );

  INSERT INTO wu34_probe_result (result) VALUES (v_results);
END
$probe$;
