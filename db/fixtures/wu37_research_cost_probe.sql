-- WU-37 Net-of-cost research accounting probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu37_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu37-probe","entitlement_version":"research-cost-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_schedule jsonb;
  v_zero jsonb;
  v_alt jsonb;
  v_trades jsonb;
  v_trades2 jsonb;
  v_trades3 jsonb;
  v_r jsonb;
  v_r2 jsonb;
  v_sched research_cost_schedule%ROWTYPE;
  v_app research_cost_application%ROWTYPE;
  v_app_again research_cost_application%ROWTYPE;
  v_prereg jsonb;
  v_spec jsonb;
  v_binding jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_sv strategy_version%ROWTYPE;
BEGIN
  v_schedule := jsonb_build_object(
    'schedule_key', 'wu37-stock-research-v1',
    'commission_cents_per_unit', 1,
    'exchange_fee_cents_per_unit', 1,
    'regulatory_fee_cents_per_unit', 1,
    'slippage_bps_per_side', 10
  );
  v_zero := jsonb_build_object(
    'schedule_key', 'wu37-zero-declared-v1',
    'commission_cents_per_unit', 0,
    'exchange_fee_cents_per_unit', 0,
    'regulatory_fee_cents_per_unit', 0,
    'slippage_bps_per_side', 0
  );
  v_alt := jsonb_set(v_schedule, '{commission_cents_per_unit}', '2'::jsonb);
  v_trades := jsonb_build_array(
    jsonb_build_object(
      'symbol', 'AAA', 'side', 'long', 'units', 1,
      'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
      'entry_cents', 10000, 'exit_cents', 10100
    )
  );
  v_trades2 := jsonb_build_array(
    jsonb_build_object(
      'symbol', 'BBB', 'side', 'long', 'units', 1,
      'entry_session', '2010-01-06', 'exit_session', '2010-01-07',
      'entry_cents', 10000, 'exit_cents', 10200
    )
  );
  v_trades3 := jsonb_build_array(
    jsonb_build_object(
      'symbol', 'CCC', 'side', 'long', 'units', 1,
      'entry_session', '2010-01-08', 'exit_session', '2010-01-09',
      'entry_cents', 10000, 'exit_cents', 10300
    )
  );

  v_r := apply_research_costs(v_trades, v_schedule);
  v_r2 := apply_research_costs(v_trades, v_schedule);
  v_results := jsonb_build_object(
    'costs_attached_before_performance',
      (v_r->>'gross_mean_return_bps')::bigint = 100
      AND (v_r->>'mean_return_bps')::bigint = 74
      AND (v_r->>'total_commission_cents')::bigint = 2
      AND (v_r->>'total_exchange_fee_cents')::bigint = 2
      AND (v_r->>'total_regulatory_fee_cents')::bigint = 2
      AND (v_r->>'total_slippage_cents')::bigint = 20
      AND (v_r->'trades'->0->>'net_return_bps')::bigint = 74
      AND (v_r->>'mean_return_bps')::bigint
        IS DISTINCT FROM (v_r->>'gross_mean_return_bps')::bigint,
    'double_run_digest_match',
      v_r = v_r2
      AND v_r->>'result_digest' = research_cost_result_digest(v_r - 'result_digest')
      AND (v_r->>'result_digest') ~ '^[0-9a-f]{64}$'
  );

  v_r := apply_research_costs(v_trades, v_zero);
  v_results := v_results || jsonb_build_object(
    'declared_zero_is_not_assumed',
      (v_r->>'mean_return_bps')::bigint = 100
      AND (v_r->>'gross_mean_return_bps')::bigint = 100
      AND (v_r->>'total_commission_cents')::bigint = 0
      AND (v_r->>'total_slippage_cents')::bigint = 0
  );

  SELECT * INTO v_sched FROM register_research_cost_schedule(v_schedule, v_lineage);
  SELECT * INTO v_app FROM record_research_cost_application(
    v_trades, v_schedule, NULL, v_lineage);
  SELECT * INTO v_app_again FROM record_research_cost_application(
    v_trades, v_schedule, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'recorded_application',
      v_app.application_id IS NOT NULL
      AND v_app.schedule_id = v_sched.schedule_id
      AND v_app.record_environment = 'local_research'
      AND (v_app.result->>'mean_return_bps')::bigint = 74
      AND v_app.result_digest ~ '^[0-9a-f]{64}$',
    'record_is_idempotent',
      v_app_again.application_id = v_app.application_id
      AND (SELECT count(*) FROM research_cost_application
           WHERE trades_digest = v_app.trades_digest
             AND schedule_id = v_app.schedule_id) = 1
  );

  v_prereg := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash and the S&P 500.',
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu37-earnings-direction'
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
    'wu37-earnings-direction', v_prereg, NULL, v_lineage);
  SELECT * INTO v_sv FROM register_strategy_version(
    'wu37-earnings-direction', v_spec, v_binding, v_reg.registration_id, NULL, v_lineage);
  SELECT * INTO v_app FROM record_research_cost_application(
    v_trades2, v_schedule, v_sv.strategy_version_id, v_lineage);
  SELECT * INTO v_app_again FROM record_research_cost_application(
    v_trades3, v_schedule, v_sv.strategy_version_id, v_lineage);
  v_results := v_results || jsonb_build_object(
    'schedule_bound_to_strategy',
      v_app.strategy_version_id = v_sv.strategy_version_id
      AND v_app_again.strategy_version_id = v_sv.strategy_version_id
      AND v_app.schedule_id = v_app_again.schedule_id
      AND v_app.application_id IS DISTINCT FROM v_app_again.application_id
  );

  BEGIN
    PERFORM record_research_cost_application(
      v_trades, v_alt, v_sv.strategy_version_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: cost schedule changed after results';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%cannot change after results exist%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('schedule_frozen_after_results', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      v_trades, v_schedule - 'slippage_bps_per_side');
    RAISE EXCEPTION 'probe corrupted: missing slippage assumed zero';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%missing required cost inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_slippage_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      v_trades, v_schedule - 'commission_cents_per_unit');
    RAISE EXCEPTION 'probe corrupted: missing commission assumed zero';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%missing required cost inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_commission_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      v_trades, v_schedule - 'exchange_fee_cents_per_unit');
    RAISE EXCEPTION 'probe corrupted: missing exchange fee assumed zero';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%missing required cost inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_exchange_fee_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      v_trades, v_schedule - 'regulatory_fee_cents_per_unit');
    RAISE EXCEPTION 'probe corrupted: missing regulatory fee assumed zero';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%missing required cost inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_regulatory_fee_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      jsonb_build_array(
        jsonb_build_object(
          'symbol', 'AAA', 'side', 'long', 'units', 1,
          'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
          'return_bps', 100
        )
      ),
      v_schedule
    );
    RAISE EXCEPTION 'probe corrupted: unpriced sandbox trade was costed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%'
         AND SQLERRM NOT LIKE '%missing required cost inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unpriced_trade_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      v_trades || jsonb_build_array(
        (v_trades->0) || jsonb_build_object('api_key', 'not-a-real-secret')
      ),
      v_schedule
    );
    RAISE EXCEPTION 'probe corrupted: credential trade key was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('credential_key_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs(
      jsonb_set(v_trades, '{0,paper_eligible}', 'true'::jsonb), v_schedule);
    RAISE EXCEPTION 'probe corrupted: paper_eligible trade was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('paper_key_blocked', true);
  END;

  BEGIN
    PERFORM apply_research_costs('[]'::jsonb, v_schedule);
    RAISE EXCEPTION 'probe corrupted: empty trades were accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%resource bound%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('empty_trades_blocked', true);
  END;

  BEGIN
    INSERT INTO research_cost_application (
      schedule_id, trades, trades_digest, result, result_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_app.schedule_id, v_app.trades, v_app.trades_digest,
      v_app.result, v_app.result_digest, v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct cost application INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the research cost workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE research_cost_application
       SET result = v_app.result
     WHERE application_id = v_app.application_id;
    RAISE EXCEPTION 'probe corrupted: cost application was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('application_update_blocked', true);
  END;

  BEGIN
    DELETE FROM research_cost_application WHERE application_id = v_app.application_id;
    RAISE EXCEPTION 'probe corrupted: cost application was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('application_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE research_cost_application;
    RAISE EXCEPTION 'probe corrupted: cost application was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('application_truncate_blocked', true);
  END;

  BEGIN
    TRUNCATE research_cost_schedule, research_cost_application;
    RAISE EXCEPTION 'probe corrupted: cost schedule was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('schedule_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'application_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.cost_application_recorded'
        AND payload->>'result_digest' = v_app.result_digest
    )
  );

  INSERT INTO wu37_probe_result (result) VALUES (v_results);
END
$probe$;
