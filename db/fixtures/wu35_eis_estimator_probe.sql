-- WU-35 EIS estimator probe. Run inside a caller-managed transaction;
-- all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu35_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu35-probe","entitlement_version":"eis-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_indep jsonb;
  v_overlap jsonb;
  v_legs jsonb;
  v_retries jsonb;
  v_event jsonb;
  v_shock jsonb;
  v_dep_exit jsonb;
  v_auto jsonb;
  v_neg jsonb;
  v_r jsonb;
  v_r2 jsonb;
  v_est eis_estimate%ROWTYPE;
  v_est_again eis_estimate%ROWTYPE;
  v_manifest jsonb;
  v_from_run jsonb;
  v_obs jsonb;
BEGIN
  v_indep := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'i1', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'issuer_event_id', 'AAA:2010-01-04', 'entry_session', '2010-01-04',
      'exit_session', '2010-01-05', 'attempt_group_id', 'i1', 'return_bps', 7),
    jsonb_build_object(
      'observation_id', 'i2', 'thesis_key', 'earnings_direction', 'issuer', 'BBB',
      'issuer_event_id', 'BBB:2010-01-06', 'entry_session', '2010-01-06',
      'exit_session', '2010-01-07', 'attempt_group_id', 'i2', 'return_bps', -3),
    jsonb_build_object(
      'observation_id', 'i3', 'thesis_key', 'earnings_direction', 'issuer', 'CCC',
      'issuer_event_id', 'CCC:2010-01-08', 'entry_session', '2010-01-08',
      'exit_session', '2010-01-09', 'attempt_group_id', 'i3', 'return_bps', 5)
  );
  v_r := compute_eis_estimate(v_indep);
  v_r2 := compute_eis_estimate(v_indep);
  v_results := jsonb_build_object(
    'independent_not_collapsed',
      (v_r->>'observation_count')::integer = 3
      AND (v_r->>'cluster_count')::integer = 3
      AND (v_r->>'eis')::bigint = 3
      AND (v_r->>'floor')::bigint = 3
      AND (v_r->>'lag1_autocorr_e6')::bigint < 0,
    'double_run_digest_match',
      v_r = v_r2
      AND v_r->>'result_digest' = eis_result_digest(v_r - 'result_digest')
      AND (v_r->>'result_digest') ~ '^[0-9a-f]{64}$',
    'floor_is_lower_of_clusters_and_eis',
      (v_r->>'floor')::bigint = LEAST(
        (v_r->>'cluster_count')::bigint, (v_r->>'eis')::bigint)
  );

  v_overlap := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'o1', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-08',
      'attempt_group_id', 'o1', 'return_bps', 40),
    jsonb_build_object(
      'observation_id', 'o2', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-06', 'exit_session', '2010-01-10',
      'attempt_group_id', 'o2', 'return_bps', 20)
  );
  v_r := compute_eis_estimate(v_overlap);
  v_results := v_results || jsonb_build_object(
    'overlapping_holdings_one_cluster',
      (v_r->>'observation_count')::integer = 2
      AND (v_r->>'cluster_count')::integer = 1
      AND (v_r->>'eis')::bigint = 1
      AND (v_r->>'floor')::bigint = 1
  );

  v_legs := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'leg-root', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-06',
      'attempt_group_id', 'leg-root', 'return_bps', 100),
    jsonb_build_object(
      'observation_id', 'leg-a', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-06',
      'parent_observation_id', 'leg-root', 'attempt_group_id', 'leg-a',
      'return_bps', 40),
    jsonb_build_object(
      'observation_id', 'leg-b', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-06',
      'parent_observation_id', 'leg-root', 'attempt_group_id', 'leg-b',
      'return_bps', 60)
  );
  v_r := compute_eis_estimate(v_legs);
  v_results := v_results || jsonb_build_object(
    'legs_do_not_inflate',
      (v_r->>'observation_count')::integer = 3
      AND (v_r->>'cluster_count')::integer = 1
      AND (v_r->>'floor')::bigint = 1
  );

  v_retries := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'f1', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
      'attempt_group_id', 'retry-1', 'return_bps', 10),
    jsonb_build_object(
      'observation_id', 'f2', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
      'attempt_group_id', 'retry-1', 'return_bps', 10),
    jsonb_build_object(
      'observation_id', 'f3', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
      'attempt_group_id', 'retry-1', 'return_bps', 10)
  );
  v_r := compute_eis_estimate(v_retries);
  v_results := v_results || jsonb_build_object(
    'retries_do_not_inflate',
      (v_r->>'observation_count')::integer = 3
      AND (v_r->>'cluster_count')::integer = 1
      AND (v_r->>'floor')::bigint = 1
  );

  v_event := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'e1', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'issuer_event_id', 'AAA:earn-1', 'entry_session', '2010-01-04',
      'exit_session', '2010-01-05', 'attempt_group_id', 'e1', 'return_bps', 12),
    jsonb_build_object(
      'observation_id', 'e2', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'issuer_event_id', 'AAA:earn-1', 'entry_session', '2010-02-01',
      'exit_session', '2010-02-02', 'attempt_group_id', 'e2', 'return_bps', 8)
  );
  v_r := compute_eis_estimate(v_event);
  v_results := v_results || jsonb_build_object(
    'issuer_event_one_cluster',
      (v_r->>'observation_count')::integer = 2
      AND (v_r->>'cluster_count')::integer = 1
      AND (v_r->>'floor')::bigint = 1
  );

  v_shock := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 's1', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'shock_id', 'vol-2010-05', 'entry_session', '2010-05-03',
      'exit_session', '2010-05-04', 'attempt_group_id', 's1', 'return_bps', -80),
    jsonb_build_object(
      'observation_id', 's2', 'thesis_key', 'earnings_direction', 'issuer', 'BBB',
      'shock_id', 'vol-2010-05', 'entry_session', '2010-05-10',
      'exit_session', '2010-05-11', 'attempt_group_id', 's2', 'return_bps', -40)
  );
  v_r := compute_eis_estimate(v_shock);
  v_results := v_results || jsonb_build_object(
    'common_shock_one_cluster',
      (v_r->>'observation_count')::integer = 2
      AND (v_r->>'cluster_count')::integer = 1
      AND (v_r->>'floor')::bigint = 1
  );

  v_dep_exit := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'd1', 'thesis_key', 'earnings_direction', 'issuer', 'AAA',
      'entry_session', '2010-01-04', 'exit_session', '2010-01-05',
      'attempt_group_id', 'd1', 'return_bps', 15),
    jsonb_build_object(
      'observation_id', 'd2', 'thesis_key', 'earnings_direction', 'issuer', 'BBB',
      'entry_session', '2010-03-01', 'exit_session', '2010-03-02',
      'dependent_exit_of', 'd1', 'attempt_group_id', 'd2', 'return_bps', 9)
  );
  v_r := compute_eis_estimate(v_dep_exit);
  v_results := v_results || jsonb_build_object(
    'dependent_exit_one_cluster',
      (v_r->>'observation_count')::integer = 2
      AND (v_r->>'cluster_count')::integer = 1
      AND (v_r->>'floor')::bigint = 1
  );

  v_auto := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'a1', 'thesis_key', 't', 'issuer', 'W',
      'issuer_event_id', 'W:1', 'entry_session', '2010-01-04',
      'exit_session', '2010-01-05', 'attempt_group_id', 'a1', 'return_bps', 10),
    jsonb_build_object(
      'observation_id', 'a2', 'thesis_key', 't', 'issuer', 'X',
      'issuer_event_id', 'X:1', 'entry_session', '2010-01-06',
      'exit_session', '2010-01-07', 'attempt_group_id', 'a2', 'return_bps', 20),
    jsonb_build_object(
      'observation_id', 'a3', 'thesis_key', 't', 'issuer', 'Y',
      'issuer_event_id', 'Y:1', 'entry_session', '2010-01-08',
      'exit_session', '2010-01-09', 'attempt_group_id', 'a3', 'return_bps', 30),
    jsonb_build_object(
      'observation_id', 'a4', 'thesis_key', 't', 'issuer', 'Z',
      'issuer_event_id', 'Z:1', 'entry_session', '2010-01-11',
      'exit_session', '2010-01-12', 'attempt_group_id', 'a4', 'return_bps', 40)
  );
  v_r := compute_eis_estimate(v_auto);
  v_results := v_results || jsonb_build_object(
    'autocorr_reduces_eis',
      (v_r->>'cluster_count')::integer = 4
      AND (v_r->>'lag1_autocorr_e6')::bigint = 1000000
      AND (v_r->>'eis')::bigint = 1
      AND (v_r->>'floor')::bigint = 1
      AND (v_r->>'floor')::bigint = LEAST(
        (v_r->>'cluster_count')::bigint, (v_r->>'eis')::bigint)
  );

  v_neg := jsonb_build_array(
    jsonb_build_object(
      'observation_id', 'n1', 'thesis_key', 't', 'issuer', 'W',
      'issuer_event_id', 'W:n', 'entry_session', '2010-01-04',
      'exit_session', '2010-01-05', 'attempt_group_id', 'n1', 'return_bps', 10),
    jsonb_build_object(
      'observation_id', 'n2', 'thesis_key', 't', 'issuer', 'X',
      'issuer_event_id', 'X:n', 'entry_session', '2010-01-06',
      'exit_session', '2010-01-07', 'attempt_group_id', 'n2', 'return_bps', -10),
    jsonb_build_object(
      'observation_id', 'n3', 'thesis_key', 't', 'issuer', 'Y',
      'issuer_event_id', 'Y:n', 'entry_session', '2010-01-08',
      'exit_session', '2010-01-09', 'attempt_group_id', 'n3', 'return_bps', 10),
    jsonb_build_object(
      'observation_id', 'n4', 'thesis_key', 't', 'issuer', 'Z',
      'issuer_event_id', 'Z:n', 'entry_session', '2010-01-11',
      'exit_session', '2010-01-12', 'attempt_group_id', 'n4', 'return_bps', -10)
  );
  v_r := compute_eis_estimate(v_neg);
  v_results := v_results || jsonb_build_object(
    'negative_autocorr_does_not_inflate',
      (v_r->>'cluster_count')::integer = 4
      AND (v_r->>'lag1_autocorr_e6')::bigint < 0
      AND (v_r->>'eis')::bigint = 4
      AND (v_r->>'floor')::bigint = 4
  );

  v_manifest := jsonb_build_object(
    'engine', 'walk_forward_v1',
    'folds', jsonb_build_array(
      jsonb_build_object(
        'window_index', 1,
        'result', jsonb_build_object(
          'trades', jsonb_build_array(
            jsonb_build_object(
              'symbol', 'AAA', 'entry_session', '2010-01-04',
              'exit_session', '2010-01-05', 'return_bps', 100)
          )
        )
      ),
      jsonb_build_object(
        'window_index', 2,
        'result', jsonb_build_object(
          'trades', jsonb_build_array(
            jsonb_build_object(
              'symbol', 'BBB', 'entry_session', '2011-01-04',
              'exit_session', '2011-01-05', 'return_bps', 50)
          )
        )
      )
    )
  );
  v_from_run := eis_observations_from_walk_forward_manifest(
    v_manifest, 'strategy-fixture');
  v_r := compute_eis_estimate(v_from_run);
  v_results := v_results || jsonb_build_object(
    'walk_forward_trades_mapped',
      jsonb_array_length(v_from_run) = 2
      AND (v_r->>'cluster_count')::integer = 2
      AND (v_r->>'floor')::bigint = LEAST(
        (v_r->>'cluster_count')::bigint, (v_r->>'eis')::bigint)
  );

  SELECT * INTO v_est FROM record_eis_estimate(v_indep, NULL, v_lineage);
  SELECT * INTO v_est_again FROM record_eis_estimate(v_indep, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'recorded_estimate',
      v_est.estimate_id IS NOT NULL
      AND v_est.record_environment = 'local_research'
      AND (v_est.result->>'cluster_count')::integer = 3
      AND (v_est.result->>'floor')::integer = 3
      AND v_est.result_digest ~ '^[0-9a-f]{64}$',
    'record_is_idempotent',
      v_est_again.estimate_id = v_est.estimate_id
      AND (SELECT count(*) FROM eis_estimate
           WHERE observations_digest = v_est.observations_digest) = 1
  );

  BEGIN
    PERFORM compute_eis_estimate(
      v_indep || jsonb_build_array(
        jsonb_build_object(
          'observation_id', 'bad', 'thesis_key', 'earnings_direction',
          'issuer', 'AAA', 'entry_session', '2010-01-04',
          'exit_session', '2010-01-05', 'attempt_group_id', 'bad',
          'return_bps', 1, 'api_key', 'not-a-real-secret')
      )
    );
    RAISE EXCEPTION 'probe corrupted: extra credential key was estimated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('credential_key_blocked', true);
  END;

  BEGIN
    PERFORM compute_eis_estimate(
      jsonb_set(v_indep, '{0,paper_eligible}', 'true'::jsonb));
    RAISE EXCEPTION 'probe corrupted: paper_eligible observation was estimated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%out-of-scope keys%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('paper_key_blocked', true);
  END;

  BEGIN
    PERFORM compute_eis_estimate('[]'::jsonb);
    RAISE EXCEPTION 'probe corrupted: empty observations were estimated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%resource bound%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('empty_observations_blocked', true);
  END;

  BEGIN
    PERFORM record_eis_estimate(v_indep, '00000000-0000-0000-0000-000000000000'::uuid, v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown walk-forward run was estimated';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_run_blocked', true);
  END;

  BEGIN
    INSERT INTO eis_estimate (
      observations, observations_digest, result, result_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_est.observations, v_est.observations_digest, v_est.result, v_est.result_digest,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct eis_estimate INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through record_eis_estimate%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE eis_estimate SET result = v_est.result WHERE estimate_id = v_est.estimate_id;
    RAISE EXCEPTION 'probe corrupted: eis estimate was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('estimate_update_blocked', true);
  END;

  BEGIN
    DELETE FROM eis_estimate WHERE estimate_id = v_est.estimate_id;
    RAISE EXCEPTION 'probe corrupted: eis estimate was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('estimate_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE eis_estimate;
    RAISE EXCEPTION 'probe corrupted: eis estimate was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%eis_estimate is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('estimate_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'estimate_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.eis_estimate_recorded'
        AND payload->>'result_digest' = v_est.result_digest
    )
  );

  INSERT INTO wu35_probe_result (result) VALUES (v_results);
END
$probe$;
