-- WU-38 Qualification report probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu38_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu38-probe","entitlement_version":"qualification-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_source_id uuid := '38000000-0000-0000-0000-000000000001';
  v_source_v uuid := '38000000-0000-0000-0000-000000000101';
  v_contract_id uuid := '38000000-0000-0000-0000-000000000201';
  v_contract_v uuid := '38000000-0000-0000-0000-000000000202';
  v_entitlement_id uuid := '38000000-0000-0000-0000-000000000301';
  v_entitlement_v uuid := '38000000-0000-0000-0000-000000000302';
  v_cal date[] := '{}';
  v_d date := DATE '2010-01-04';
  v_prereg jsonb;
  v_spec jsonb;
  v_binding jsonb;
  v_payload jsonb;
  v_sessions jsonb;
  v_aaa_bars jsonb;
  v_bbb_bars jsonb;
  v_sp_bars jsonb;
  v_earnings jsonb;
  v_cons jsonb;
  v_cash_pairs jsonb := '[]'::jsonb;
  v_sp_pairs jsonb := '[]'::jsonb;
  v_schedule jsonb;
  v_cost_trades jsonb;
  v_fail_obs jsonb;
  v_pass_obs jsonb := '[]'::jsonb;
  v_reg_fail experiment_preregistration%ROWTYPE;
  v_reg_pass experiment_preregistration%ROWTYPE;
  v_sv_fail strategy_version%ROWTYPE;
  v_sv_pass strategy_version%ROWTYPE;
  v_cal_row walk_forward_calendar%ROWTYPE;
  v_snap research_snapshot%ROWTYPE;
  v_wf_fail walk_forward_run%ROWTYPE;
  v_wf_pass walk_forward_run%ROWTYPE;
  v_eis_fail eis_estimate%ROWTYPE;
  v_eis_pass eis_estimate%ROWTYPE;
  v_cash_fail block_bootstrap_run%ROWTYPE;
  v_sp_fail block_bootstrap_run%ROWTYPE;
  v_cash_pass block_bootstrap_run%ROWTYPE;
  v_sp_pass block_bootstrap_run%ROWTYPE;
  v_cost_fail research_cost_application%ROWTYPE;
  v_cost_pass research_cost_application%ROWTYPE;
  v_rep research_qualification_report%ROWTYPE;
  v_rep_again research_qualification_report%ROWTYPE;
  v_rep_pass research_qualification_report%ROWTYPE;
  v_replay jsonb;
  v_i integer;
  v_entry date;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'wu38-licensed-eod', 'WU-38 Licensed EOD', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v, v_source_id, 1, 'active',
    '{"name":"WU-38 Licensed Terms","version":"2026.1"}',
    '{"purposes":["local_research"]}',
    '{"required_fields":["source_observation_id","received_at"]}',
    ARRAY['current','stale','missing','incomplete'],
    ARRAY['factual_correction','retraction','source_unavailability'],
    '2026-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'wu38-daily-eod', 'market',
    'WU-38 point-in-time daily market observations',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract_version (
    contract_version_id, contract_id, contract_version, source_registry_version_id,
    effective_from, effective_to, availability_time_rules,
    instrument_identity_rules, provenance_requirements,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_v, v_contract_id, 1, v_source_v,
    '2026-01-01T00:00:00Z', NULL,
    '{"as_of_required":true,"receipt_time_required":true}',
    '{"security_id_required":true}',
    '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_id, 'wu38-licensed-entitlement', 'local-research-account',
    'WU-38 local certification plan', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_v, v_entitlement_id, 1, v_source_v, 'certified',
    ARRAY['local_research'], '2026-01-01T00:00:00Z', NULL,
    '{"authority":"principal-approved-research-plan","certificate":"wu38-cert"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  WHILE cardinality(v_cal) < 845 LOOP
    IF extract(isodow FROM v_d) < 6 THEN
      v_cal := v_cal || v_d;
    END IF;
    v_d := v_d + 1;
  END LOOP;

  v_prereg := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash and the S&P 500.',
    'windows', jsonb_build_object(
      'walk_forward', 3,
      'holdout_sessions', 60,
      'purge_gap_sessions', 5,
      'folds', jsonb_build_array(
        jsonb_build_object(
          'train_start', to_char(v_cal[1], 'YYYY-MM-DD'),
          'train_end', to_char(v_cal[20], 'YYYY-MM-DD'),
          'purge_start', to_char(v_cal[21], 'YYYY-MM-DD'),
          'purge_end', to_char(v_cal[25], 'YYYY-MM-DD'),
          'test_start', to_char(v_cal[26], 'YYYY-MM-DD'),
          'test_end', to_char(v_cal[275], 'YYYY-MM-DD')
        ),
        jsonb_build_object(
          'train_start', to_char(v_cal[1], 'YYYY-MM-DD'),
          'train_end', to_char(v_cal[275], 'YYYY-MM-DD'),
          'purge_start', to_char(v_cal[276], 'YYYY-MM-DD'),
          'purge_end', to_char(v_cal[280], 'YYYY-MM-DD'),
          'test_start', to_char(v_cal[281], 'YYYY-MM-DD'),
          'test_end', to_char(v_cal[530], 'YYYY-MM-DD')
        ),
        jsonb_build_object(
          'train_start', to_char(v_cal[1], 'YYYY-MM-DD'),
          'train_end', to_char(v_cal[530], 'YYYY-MM-DD'),
          'purge_start', to_char(v_cal[531], 'YYYY-MM-DD'),
          'purge_end', to_char(v_cal[535], 'YYYY-MM-DD'),
          'test_start', to_char(v_cal[536], 'YYYY-MM-DD'),
          'test_end', to_char(v_cal[785], 'YYYY-MM-DD')
        )
      )
    ),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu38-earnings-direction'
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
           'session', to_char(d, 'YYYY-MM-DD'), 'close_cents', 10000
         ) ORDER BY ord),
         jsonb_agg(jsonb_build_object(
           'session', to_char(d, 'YYYY-MM-DD'), 'close_cents', 10050
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
  FROM unnest(ARRAY[v_cal[26], v_cal[281], v_cal[536]]) AS d;
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

  SELECT * INTO v_reg_fail FROM register_experiment_preregistration(
    'wu38-fail', v_prereg, NULL, v_lineage);
  SELECT * INTO v_reg_pass FROM register_experiment_preregistration(
    'wu38-pass', jsonb_set(v_prereg, '{experiment_family}', '"wu38-pass"'::jsonb),
    NULL, v_lineage);
  SELECT * INTO v_sv_fail FROM register_strategy_version(
    'wu38-fail', v_spec, v_binding, v_reg_fail.registration_id, NULL, v_lineage);
  SELECT * INTO v_sv_pass FROM register_strategy_version(
    'wu38-pass', v_spec, v_binding, v_reg_pass.registration_id, NULL, v_lineage);
  SELECT * INTO v_cal_row FROM register_walk_forward_calendar(v_cal, v_lineage);
  SELECT * INTO v_snap FROM append_research_snapshot(
    'walk_forward_v1', v_payload, v_lineage, NULL, NULL);
  SELECT * INTO v_wf_fail FROM record_walk_forward_run(
    v_sv_fail.strategy_version_id, v_cal_row.calendar_id, v_snap.snapshot_id, v_lineage);
  SELECT * INTO v_wf_pass FROM record_walk_forward_run(
    v_sv_pass.strategy_version_id, v_cal_row.calendar_id, v_snap.snapshot_id, v_lineage);

  v_fail_obs := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'f1', 'thesis_key', 't', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-08',
      'attempt_group_id', 'f1', 'return_bps', 40),
    jsonb_build_object(
      'observation_id', 'f2', 'thesis_key', 't', 'issuer', 'AAA',
      'entry_session', '2010-01-06', 'exit_session', '2010-01-10',
      'attempt_group_id', 'f2', 'return_bps', 20)
  );
  FOR v_i IN 1 .. 32 LOOP
    v_entry := DATE '2010-01-04' + ((v_i - 1) * 2);
    v_pass_obs := v_pass_obs || jsonb_build_array(
      jsonb_build_object(
        'observation_id', 'p' || v_i::text,
        'thesis_key', 't',
        'issuer', 'S' || lpad(v_i::text, 2, '0'),
        'issuer_event_id', 'S' || lpad(v_i::text, 2, '0') || ':1',
        'entry_session', to_char(v_entry, 'YYYY-MM-DD'),
        'exit_session', to_char(v_entry + 1, 'YYYY-MM-DD'),
        'attempt_group_id', 'p' || v_i::text,
        'return_bps', CASE WHEN v_i % 2 = 1 THEN 80 ELSE 20 END
      )
    );
  END LOOP;
  SELECT * INTO v_eis_fail FROM record_eis_estimate(v_fail_obs, NULL, v_lineage);
  SELECT * INTO v_eis_pass FROM record_eis_estimate(v_pass_obs, NULL, v_lineage);

  v_cons := jsonb_build_object(
    'method', 'moving_block_bootstrap',
    'block_length', 2,
    'replications', 100,
    'seed', 42,
    'confidence', 95,
    'side', 'one_sided_lower'
  );
  FOR v_i IN 1 .. 8 LOOP
    v_cash_pairs := v_cash_pairs || jsonb_build_array(
      jsonb_build_object(
        'session', to_char(DATE '2010-01-04' + (v_i - 1), 'YYYY-MM-DD'),
        'strategy_bps', 100, 'comparator_bps', 0
      )
    );
    v_sp_pairs := v_sp_pairs || jsonb_build_array(
      jsonb_build_object(
        'session', to_char(DATE '2010-01-04' + (v_i - 1), 'YYYY-MM-DD'),
        'strategy_bps', 100, 'comparator_bps', 40
      )
    );
  END LOOP;
  SELECT * INTO v_cash_fail FROM record_block_bootstrap_lcb(
    v_cash_pairs, v_cons, v_sv_fail.strategy_version_id, NULL, v_lineage);
  SELECT * INTO v_sp_fail FROM record_block_bootstrap_lcb(
    v_sp_pairs, v_cons, v_sv_fail.strategy_version_id, NULL, v_lineage);
  SELECT * INTO v_cash_pass FROM record_block_bootstrap_lcb(
    v_cash_pairs, jsonb_set(v_cons, '{seed}', '43'::jsonb),
    v_sv_pass.strategy_version_id, NULL, v_lineage);
  SELECT * INTO v_sp_pass FROM record_block_bootstrap_lcb(
    v_sp_pairs, jsonb_set(v_cons, '{seed}', '43'::jsonb),
    v_sv_pass.strategy_version_id, NULL, v_lineage);

  v_schedule := jsonb_build_object(
    'schedule_key', 'wu38-stock-research-v1',
    'commission_cents_per_unit', 1,
    'exchange_fee_cents_per_unit', 1,
    'regulatory_fee_cents_per_unit', 1,
    'slippage_bps_per_side', 10
  );
  v_cost_trades := jsonb_build_array(
    jsonb_build_object(
      'symbol', 'AAA', 'side', 'long', 'units', 1,
      'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
      'entry_cents', 10000, 'exit_cents', 10100
    )
  );
  SELECT * INTO v_cost_fail FROM record_research_cost_application(
    v_cost_trades, v_schedule, v_sv_fail.strategy_version_id, v_lineage);
  SELECT * INTO v_cost_pass FROM record_research_cost_application(
    jsonb_build_array(
      jsonb_build_object(
        'symbol', 'BBB', 'side', 'long', 'units', 1,
        'entry_session', '2010-01-06', 'exit_session', '2010-01-07',
        'entry_cents', 10000, 'exit_cents', 10100
      )
    ),
    v_schedule, v_sv_pass.strategy_version_id, v_lineage
  );

  SELECT * INTO v_rep FROM record_research_qualification_report(
    v_sv_fail.strategy_version_id, v_wf_fail.run_id, v_eis_fail.estimate_id,
    v_cash_fail.run_id, v_sp_fail.run_id, v_cost_fail.application_id,
    v_contract_v, v_entitlement_v, v_lineage);
  SELECT * INTO v_rep_again FROM record_research_qualification_report(
    v_sv_fail.strategy_version_id, v_wf_fail.run_id, v_eis_fail.estimate_id,
    v_cash_fail.run_id, v_sp_fail.run_id, v_cost_fail.application_id,
    v_contract_v, v_entitlement_v, v_lineage);
  v_replay := compute_research_qualification_report(
    v_sv_fail.strategy_version_id, v_wf_fail.run_id, v_eis_fail.estimate_id,
    v_cash_fail.run_id, v_sp_fail.run_id, v_cost_fail.application_id,
    v_contract_v, v_entitlement_v);
  SELECT * INTO v_rep_pass FROM record_research_qualification_report(
    v_sv_pass.strategy_version_id, v_wf_pass.run_id, v_eis_pass.estimate_id,
    v_cash_pass.run_id, v_sp_pass.run_id, v_cost_pass.application_id,
    v_contract_v, v_entitlement_v, v_lineage);

  v_results := jsonb_build_object(
    'failed_evaluation_complete',
      v_rep.report->>'status' = 'failed'
      AND v_rep.report->'failure_reasons' @> '["eis_floor_below_30"]'::jsonb
      AND v_rep.report->>'strategy_version_digest' = v_sv_fail.version_digest
      AND v_rep.report->>'data_contract_version_id' = v_contract_v::text
      AND v_rep.report->>'data_entitlement_version_id' = v_entitlement_v::text
      AND v_rep.report->>'window_plan_digest' = v_wf_fail.window_plan_digest
      AND (v_rep.report->>'bootstrap_seed')::bigint = 42
      AND v_rep.report ? 'cluster_count'
      AND v_rep.report ? 'eis'
      AND v_rep.report ? 'eis_floor'
      AND v_rep.report ? 'lcb_vs_cash_bps'
      AND v_rep.report ? 'lcb_vs_sp500_bps'
      AND v_rep.report ? 'net_mean_return_bps'
      AND v_rep.report->>'lifecycle_state' = 'frozen'
      AND (v_rep.report->>'replayed')::boolean IS TRUE,
    'passed_evaluation_complete',
      v_rep_pass.report->>'status' = 'passed'
      AND jsonb_array_length(v_rep_pass.report->'failure_reasons') = 0
      AND (v_rep_pass.report->>'eis_floor')::bigint >= 30
      AND (v_rep_pass.report->>'lcb_vs_cash_bps')::bigint >= 0
      AND (v_rep_pass.report->>'lcb_vs_sp500_bps')::bigint >= 0
      AND v_rep_pass.report->>'strategy_version_digest' = v_sv_pass.version_digest
      AND v_rep_pass.report ? 'windows'
      AND v_rep_pass.report ? 'bootstrap_seed'
      AND v_rep_pass.report ? 'net_mean_return_bps'
      AND v_rep_pass.report->>'lifecycle_state' = 'frozen',
    'equal_completeness',
      (SELECT array_agg(k ORDER BY k)
       FROM jsonb_object_keys(v_rep.report - 'result_digest') k)
      =
      (SELECT array_agg(k ORDER BY k)
       FROM jsonb_object_keys(v_rep_pass.report - 'result_digest') k),
    'deterministic_replay',
      v_replay - 'result_digest' = v_rep.report
      AND v_replay->>'result_digest' = v_rep.result_digest
      AND v_rep.result_digest = qualification_report_digest(v_rep.report),
    'record_is_idempotent',
      v_rep_again.report_id = v_rep.report_id
      AND (SELECT count(*) FROM research_qualification_report
           WHERE strategy_version_id = v_sv_fail.strategy_version_id) = 1,
    'does_not_grant_authority',
      v_sv_fail.lifecycle_state = 'frozen'
      AND v_sv_pass.lifecycle_state = 'frozen'
      AND v_rep.report->>'lifecycle_state' = 'frozen'
      AND v_rep.record_environment = 'local_research'
  );

  BEGIN
    PERFORM record_research_qualification_report(
      v_sv_fail.strategy_version_id, v_wf_fail.run_id, v_eis_fail.estimate_id,
      v_sp_fail.run_id, v_cash_fail.run_id, v_cost_fail.application_id,
      v_contract_v, v_entitlement_v, v_lineage);
    RAISE EXCEPTION 'probe corrupted: qualification report mutated after results';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot change after results exist%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('report_frozen_after_results', true);
  END;

  BEGIN
    PERFORM record_research_qualification_report(
      v_sv_fail.strategy_version_id, v_wf_fail.run_id, v_eis_fail.estimate_id,
      v_cash_fail.run_id, NULL, v_cost_fail.application_id,
      v_contract_v, v_entitlement_v, v_lineage);
    RAISE EXCEPTION 'probe corrupted: hard S&P LCB was optional';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%incomplete%'
         AND SQLERRM NOT LIKE '%cannot change after results exist%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('hard_sp500_required', true);
  END;

  BEGIN
    INSERT INTO research_qualification_report (
      strategy_version_id, walk_forward_run_id, eis_estimate_id,
      cash_bootstrap_run_id, sp500_bootstrap_run_id, cost_application_id,
      data_contract_version_id, data_entitlement_version_id,
      report, result_digest, source_lineage, receipt_time, record_environment
    ) VALUES (
      v_rep.strategy_version_id, v_rep.walk_forward_run_id, v_rep.eis_estimate_id,
      v_rep.cash_bootstrap_run_id, v_rep.sp500_bootstrap_run_id,
      v_rep.cost_application_id, v_rep.data_contract_version_id,
      v_rep.data_entitlement_version_id, v_rep.report, v_rep.result_digest,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct qualification report INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through record_research_qualification_report%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE research_qualification_report
       SET report = v_rep.report
     WHERE report_id = v_rep.report_id;
    RAISE EXCEPTION 'probe corrupted: qualification report was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('report_update_blocked', true);
  END;

  BEGIN
    DELETE FROM research_qualification_report WHERE report_id = v_rep.report_id;
    RAISE EXCEPTION 'probe corrupted: qualification report was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('report_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE research_qualification_report;
    RAISE EXCEPTION 'probe corrupted: qualification report was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('report_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'report_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.qualification_report_recorded'
        AND payload->>'result_digest' = v_rep.result_digest
        AND payload->>'status' = 'failed'
    )
  );

  INSERT INTO wu38_probe_result (result) VALUES (v_results);
END
$probe$;
