-- WU-29 Experiment Registry preregistration probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu29_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu29-probe","entitlement_version":"experiment-registry-v1"}';
  v_spec jsonb;
  v_spec_v2 jsonb;
  v_alias_spec jsonb;
  v_omit text;
  v_omit_spec jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_reg_again experiment_preregistration%ROWTYPE;
  v_reg_v2 experiment_preregistration%ROWTYPE;
  v_reg_alias experiment_preregistration%ROWTYPE;
  v_other experiment_preregistration%ROWTYPE;
  v_snapshot_id uuid;
  v_original_digest text;
  v_results jsonb := '{}'::jsonb;
BEGIN
  v_spec := jsonb_build_object(
    'hypothesis', 'Earnings-day gap bias is predictive under the preregistered windows.',
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 8),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-gap-bias family'
  );
  v_spec_v2 := jsonb_set(
    v_spec, '{hypothesis}',
    '"Post-hoc: gap bias restricted to large-cap names after the first result."'::jsonb);
  v_alias_spec := jsonb_build_object(
    'experiment_key', 'wu29-alias-toy',
    'hypothesis', 'Alias-shaped tracer spec still satisfies the registry contract.',
    'window', jsonb_build_object('trading_days', 10, 'kind', 'synthetic_chronological'),
    'estimator', 'mean_return_difference_bps',
    'testing_budget', jsonb_build_object('trials', 1),
    'stopping_rule', 'single_pass',
    'multiplicity', 'none'
  );

  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu29-earnings-gap', v_spec, NULL, v_lineage);

  v_original_digest := v_reg.spec_digest;
  v_results := jsonb_build_object(
    'registered_before_result',
      v_reg.registration_id IS NOT NULL
      AND v_reg.successor_of IS NULL
      AND v_reg.experiment_key = 'wu29-earnings-gap'
      AND NOT EXISTS (
        SELECT 1 FROM evaluation_result e
        WHERE e.registration_id = v_reg.registration_id
      ),
    'content_addressed',
      v_reg.spec_digest
      = encode(digest('market-mate-preregistration-v1|' || v_spec::text, 'sha256'), 'hex')
      AND v_reg.spec_digest ~ '^[0-9a-f]{64}$',
    'spec_fields_recorded',
      v_reg.spec->>'hypothesis' = v_spec->>'hypothesis'
      AND v_reg.spec->'windows' = v_spec->'windows'
      AND v_reg.spec->'estimators' = v_spec->'estimators'
      AND v_reg.spec->'budget' = v_spec->'budget'
      AND v_reg.spec->>'stopping_rule' = v_spec->>'stopping_rule'
      AND v_reg.spec->>'multiplicity_plan' = v_spec->>'multiplicity_plan'
  );

  SELECT * INTO v_reg_again FROM register_experiment_preregistration(
    'wu29-earnings-gap', v_spec, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'idempotent_same_spec',
      v_reg_again.registration_id = v_reg.registration_id
      AND (SELECT count(*) FROM experiment_preregistration
           WHERE experiment_key = 'wu29-earnings-gap') = 1
  );

  BEGIN
    INSERT INTO experiment_preregistration (
      experiment_key, spec, spec_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'wu29-smuggled',
      v_spec,
      encode(digest('market-mate-preregistration-v1|' || v_spec::text, 'sha256'), 'hex'),
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct preregistration INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through register_experiment_preregistration%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE experiment_preregistration
       SET spec = spec || '{"tamper":true}'::jsonb
     WHERE registration_id = v_reg.registration_id;
    RAISE EXCEPTION 'probe corrupted: preregistration spec was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('spec_update_blocked', true);
  END;

  BEGIN
    DELETE FROM experiment_preregistration
     WHERE registration_id = v_reg.registration_id;
    RAISE EXCEPTION 'probe corrupted: preregistration was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('registration_delete_blocked', true);
  END;

  FOREACH v_omit IN ARRAY ARRAY[
    'hypothesis', 'windows', 'estimators', 'budget', 'stopping_rule', 'multiplicity_plan'
  ]
  LOOP
    v_omit_spec := v_spec - v_omit;
    BEGIN
      PERFORM register_experiment_preregistration(
        'wu29-omit-' || v_omit, v_omit_spec, NULL, v_lineage);
      RAISE EXCEPTION 'probe corrupted: spec missing % was accepted', v_omit;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%spec is incomplete%' THEN RAISE; END IF;
        v_results := v_results || jsonb_build_object('incomplete_' || v_omit || '_blocked', true);
    END;
  END LOOP;

  BEGIN
    PERFORM register_experiment_preregistration(
      'wu29-earnings-gap', v_spec_v2, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: post-hoc spec without successor_of was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already has a registration%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('posthoc_without_successor_blocked', true);
  END;

  INSERT INTO research_snapshot (
    snapshot_kind, payload, payload_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    'wu29-probe',
    '{"probe":true}'::jsonb,
    encode(digest('{"probe":true}'::jsonb::text, 'sha256'), 'hex'),
    v_lineage, clock_timestamp(), 'local_research'
  ) RETURNING snapshot_id INTO v_snapshot_id;

  INSERT INTO evaluation_result (
    registration_id, snapshot_id, result, result_digest,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_reg.registration_id,
    v_snapshot_id,
    '{"decision":"recorded"}'::jsonb,
    encode(digest('{"decision":"recorded"}'::jsonb::text, 'sha256'), 'hex'),
    v_lineage, clock_timestamp(), 'local_research'
  );

  SELECT * INTO v_reg_v2 FROM register_experiment_preregistration(
    'wu29-earnings-gap', v_spec_v2, v_reg.registration_id, v_lineage);

  v_results := v_results || jsonb_build_object(
    'posthoc_creates_linked_successor',
      v_reg_v2.registration_id IS DISTINCT FROM v_reg.registration_id
      AND v_reg_v2.successor_of = v_reg.registration_id
      AND v_reg_v2.spec_digest IS DISTINCT FROM v_original_digest
      AND v_reg_v2.experiment_key = 'wu29-earnings-gap',
    'original_never_mutates',
      (SELECT spec_digest FROM experiment_preregistration
       WHERE registration_id = v_reg.registration_id) = v_original_digest
      AND (SELECT spec FROM experiment_preregistration
           WHERE registration_id = v_reg.registration_id) = v_spec
      AND (SELECT successor_of FROM experiment_preregistration
           WHERE registration_id = v_reg.registration_id) IS NULL,
    'result_stays_on_original',
      (SELECT count(*) FROM evaluation_result
       WHERE registration_id = v_reg.registration_id) = 1
      AND NOT EXISTS (
        SELECT 1 FROM evaluation_result
        WHERE registration_id = v_reg_v2.registration_id
      ),
    'tip_is_successor',
      (SELECT registration_id FROM experiment_preregistration_tip('wu29-earnings-gap'))
      = v_reg_v2.registration_id
  );

  BEGIN
    PERFORM register_experiment_preregistration(
      'wu29-earnings-gap',
      jsonb_set(v_spec_v2, '{hypothesis}', '"third amendment"'::jsonb),
      v_reg.registration_id,
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: successor of a non-tip registration was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must be the current registration%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('stale_successor_blocked', true);
  END;

  SELECT * INTO v_other FROM register_experiment_preregistration(
    'wu29-other-family', v_spec, NULL, v_lineage);
  BEGIN
    PERFORM register_experiment_preregistration(
      'wu29-other-family', v_spec_v2, v_reg_v2.registration_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: successor_of from another experiment was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must belong to experiment %' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('cross_experiment_successor_blocked', true);
  END;

  BEGIN
    PERFORM register_experiment_preregistration(
      'wu29-mismatch-key',
      v_alias_spec, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: spec experiment_key mismatch was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%spec experiment_key does not match%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('spec_key_mismatch_blocked', true);
  END;

  SELECT * INTO v_reg_alias FROM register_experiment_preregistration(
    'wu29-alias-toy', v_alias_spec, NULL, v_lineage);
  v_results := v_results || jsonb_build_object(
    'alias_fields_accepted',
      v_reg_alias.experiment_key = 'wu29-alias-toy'
      AND experiment_preregistration_spec_is_complete(v_alias_spec)
  );

  BEGIN
    TRUNCATE experiment_preregistration, evaluation_result,
             experimental_indicator_lineage, experimental_indicator_stage;
    RAISE EXCEPTION 'probe corrupted: preregistration was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('registration_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'appends_audited', (
      SELECT count(*) >= 3
      FROM audit_event
      WHERE event_type = 'research.experiment_preregistration_registered'
        AND payload->>'experiment_key' IN (
          'wu29-earnings-gap', 'wu29-other-family', 'wu29-alias-toy')
    )
  );

  INSERT INTO wu29_probe_result (result) VALUES (v_results);
END
$probe$;
