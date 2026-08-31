-- WU-30 Sealed Release Holdout custody probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu30_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu30-probe","entitlement_version":"experiment-registry-v1"}';
  v_spec jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_dates date[];
  v_dates_shift date[];
  v_dates_short date[];
  v_dates_unsorted date[];
  v_as_of timestamptz;
  v_seal release_holdout_seal%ROWTYPE;
  v_seal_again release_holdout_seal%ROWTYPE;
  v_seal_b release_holdout_seal%ROWTYPE;
  v_eval release_holdout_evaluation%ROWTYPE;
  v_eval_b release_holdout_evaluation%ROWTYPE;
  v_digest text;
  v_results jsonb := '{}'::jsonb;
BEGIN
  SELECT array_agg(g::date ORDER BY g) INTO v_dates
  FROM generate_series(DATE '2025-09-01', DATE '2025-09-01' + 59, interval '1 day') g;
  SELECT array_agg(g::date ORDER BY g) INTO v_dates_shift
  FROM generate_series(DATE '2025-09-02', DATE '2025-09-02' + 59, interval '1 day') g;
  SELECT array_agg(g::date ORDER BY g) INTO v_dates_short
  FROM generate_series(DATE '2025-09-01', DATE '2025-09-01' + 58, interval '1 day') g;
  v_dates_unsorted := v_dates;
  v_dates_unsorted[1] := v_dates[2];
  v_dates_unsorted[2] := v_dates[1];
  v_as_of := (v_dates[60]::timestamp AT TIME ZONE 'UTC') + interval '21 hours';

  v_spec := jsonb_build_object(
    'hypothesis', 'Holdout evaluation uses only preregistered estimators.',
    'windows', jsonb_build_object('holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb', 'eis'),
    'budget', jsonb_build_object('holdout_evaluations', 1),
    'stopping_rule', 'single holdout evaluation',
    'multiplicity_plan', 'Holm across the family'
  );
  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu30-holdout', v_spec, NULL, v_lineage);

  BEGIN
    PERFORM seal_release_holdout(v_dates_short, v_as_of, v_lineage);
    RAISE EXCEPTION 'probe corrupted: 59-session holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%at least 60 trading days%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('short_segment_blocked', true);
  END;

  BEGIN
    PERFORM seal_release_holdout(v_dates_unsorted, v_as_of, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unsorted holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%at least 60 trading days%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unsorted_segment_blocked', true);
  END;

  BEGIN
    PERFORM seal_release_holdout(v_dates, clock_timestamp() + interval '1 hour', v_lineage);
    RAISE EXCEPTION 'probe corrupted: future as_of holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%identity or as_of is invalid%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('future_as_of_blocked', true);
  END;

  BEGIN
    PERFORM seal_release_holdout(
      v_dates, (v_dates[1]::timestamp AT TIME ZONE 'UTC'), v_lineage);
    RAISE EXCEPTION 'probe corrupted: holdout last date after as_of was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must not be after as_of%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('last_date_after_as_of_blocked', true);
  END;

  SELECT * INTO v_seal FROM seal_release_holdout(v_dates, v_as_of, v_lineage);
  v_digest := release_holdout_seal_digest(v_dates);
  v_results := v_results || jsonb_build_object(
    'seal_ceremony_recorded',
      v_seal.session_count = 60
      AND v_seal.first_trading_date = DATE '2025-09-01'
      AND v_seal.last_trading_date = DATE '2025-09-01' + 59
      AND v_seal.seal_digest = v_digest
      AND v_digest ~ '^[0-9a-f]{64}$'
      AND NOT release_holdout_is_consumed(v_seal.holdout_id)
  );

  SELECT * INTO v_seal_again FROM seal_release_holdout(v_dates, v_as_of, v_lineage);
  v_results := v_results || jsonb_build_object(
    'idempotent_same_segment',
      v_seal_again.holdout_id = v_seal.holdout_id
      AND (SELECT count(*) FROM release_holdout_seal) = 1
  );

  BEGIN
    PERFORM seal_release_holdout(
      v_dates_shift,
      (v_dates_shift[60]::timestamp AT TIME ZONE 'UTC') + interval '21 hours',
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: second unconsumed holdout was sealed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%unconsumed release holdout is already sealed%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unconsumed_second_seal_blocked', true);
  END;

  BEGIN
    INSERT INTO release_holdout_seal (
      first_trading_date, last_trading_date, session_count, session_dates,
      as_of_at, seal_digest, source_lineage, receipt_time, record_environment
    ) VALUES (
      v_dates[1], v_dates[60], 60, v_dates, v_as_of, v_digest,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct holdout seal INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through seal_release_holdout%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_seal_insert_blocked', true);
  END;

  BEGIN
    PERFORM evaluate_release_holdout(
      v_seal.holdout_id, v_reg.registration_id,
      jsonb_build_object('block_bootstrap_lcb', 0.01, 'eis', 30, 'secret_metric', 1),
      true, v_lineage);
    RAISE EXCEPTION 'probe corrupted: extra result key was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%only preregistered estimator keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('extra_result_key_blocked', true);
  END;
  v_results := v_results || jsonb_build_object(
    'extra_key_does_not_consume',
      NOT release_holdout_is_consumed(v_seal.holdout_id)
  );

  BEGIN
    PERFORM evaluate_release_holdout(
      v_seal.holdout_id, '00000000-0000-0000-0000-000000000000'::uuid,
      jsonb_build_object('block_bootstrap_lcb', 0.01, 'eis', 30),
      true, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown registration was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_registration_blocked', true);
  END;

  BEGIN
    PERFORM evaluate_release_holdout(
      '00000000-0000-0000-0000-000000000000'::uuid, v_reg.registration_id,
      jsonb_build_object('block_bootstrap_lcb', 0.01, 'eis', 30),
      true, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unsealed holdout was evaluated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not sealed%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unsealed_holdout_blocked', true);
  END;

  BEGIN
    PERFORM evaluate_release_holdout(
      v_seal.holdout_id, v_reg.registration_id,
      jsonb_build_object('block_bootstrap_lcb', -0.02),
      false, v_lineage);
    RAISE EXCEPTION 'probe corrupted: incomplete estimator set was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%only preregistered estimator keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_estimator_key_blocked', true);
  END;
  v_results := v_results || jsonb_build_object(
    'missing_key_does_not_consume',
      NOT release_holdout_is_consumed(v_seal.holdout_id)
  );

  SELECT * INTO v_eval FROM evaluate_release_holdout(
    v_seal.holdout_id, v_reg.registration_id,
    jsonb_build_object('block_bootstrap_lcb', -0.02, 'eis', 12),
    false, v_lineage);
  v_results := v_results || jsonb_build_object(
    'failed_evaluation_consumes',
      v_eval.gate_passed IS FALSE
      AND release_holdout_is_consumed(v_seal.holdout_id)
      AND v_eval.holdout_id = v_seal.holdout_id
      AND v_eval.registration_id = v_reg.registration_id
  );

  BEGIN
    PERFORM evaluate_release_holdout(
      v_seal.holdout_id, v_reg.registration_id,
      jsonb_build_object('block_bootstrap_lcb', 0.05, 'eis', 40),
      true, v_lineage);
    RAISE EXCEPTION 'probe corrupted: second holdout evaluation was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already consumed%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('second_evaluation_refused', true);
  END;

  v_results := v_results || jsonb_build_object(
    'seal_unchanged_after_consumption',
      (SELECT seal_digest FROM release_holdout_seal WHERE holdout_id = v_seal.holdout_id)
      = v_digest
      AND (SELECT session_dates FROM release_holdout_seal WHERE holdout_id = v_seal.holdout_id)
      = v_dates
      AND (SELECT count(*) FROM release_holdout_evaluation
           WHERE holdout_id = v_seal.holdout_id) = 1
  );

  SELECT * INTO v_seal_b FROM seal_release_holdout(
    v_dates_shift,
    (v_dates_shift[60]::timestamp AT TIME ZONE 'UTC') + interval '21 hours',
    v_lineage);
  SELECT * INTO v_eval_b FROM evaluate_release_holdout(
    v_seal_b.holdout_id, v_reg.registration_id,
    jsonb_build_object('block_bootstrap_lcb', 0.03, 'eis', 40),
    true, v_lineage);
  v_results := v_results || jsonb_build_object(
    'new_seal_after_consumption',
      v_seal_b.holdout_id IS DISTINCT FROM v_seal.holdout_id
      AND v_eval_b.gate_passed IS TRUE
      AND release_holdout_is_consumed(v_seal_b.holdout_id)
  );

  BEGIN
    UPDATE release_holdout_seal
       SET session_count = 61
     WHERE holdout_id = v_seal.holdout_id;
    RAISE EXCEPTION 'probe corrupted: holdout seal was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('seal_update_blocked', true);
  END;

  BEGIN
    DELETE FROM release_holdout_evaluation
     WHERE evaluation_id = v_eval.evaluation_id;
    RAISE EXCEPTION 'probe corrupted: holdout evaluation was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('evaluation_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE release_holdout_evaluation, release_holdout_seal;
    RAISE EXCEPTION 'probe corrupted: holdout custody was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('holdout_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'seal_audited', (
      SELECT count(*) = 2
      FROM audit_event
      WHERE event_type = 'research.release_holdout_sealed'
    ),
    'evaluation_audited', (
      SELECT count(*) = 2
      FROM audit_event
      WHERE event_type = 'research.release_holdout_evaluated'
        AND (payload->>'consumed')::boolean IS TRUE
    )
  );

  INSERT INTO wu30_probe_result (result) VALUES (v_results);
END
$probe$;
