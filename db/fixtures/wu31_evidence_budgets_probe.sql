-- WU-31 Evidence budgets and multiplicity probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu31_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu31-probe","entitlement_version":"experiment-registry-v1"}';
  v_spec_a jsonb;
  v_spec_b jsonb;
  v_spec_b_default jsonb;
  v_spec_bonf jsonb;
  v_spec_conflict jsonb;
  v_spec_nofamily jsonb;
  v_spec_nobudget jsonb;
  v_a experiment_preregistration%ROWTYPE;
  v_b experiment_preregistration%ROWTYPE;
  v_c experiment_preregistration%ROWTYPE;
  v_d experiment_preregistration%ROWTYPE;
  v_e experiment_preregistration%ROWTYPE;
  v_f experiment_preregistration%ROWTYPE;
  v_trial experiment_trial%ROWTYPE;
  v_corr experiment_family_correction%ROWTYPE;
  v_corr_bonf experiment_family_correction%ROWTYPE;
  v_holm numeric[];
  v_bonf numeric[];
  v_results jsonb := '{}'::jsonb;
BEGIN
  v_spec_a := jsonb_build_object(
    'hypothesis', 'Member A of the Holm family.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 2),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', 'Holm across the family',
    'experiment_family', 'wu31-holm-family'
  );
  v_spec_b_default := jsonb_build_object(
    'hypothesis', 'Member B uses the default family-wise plan.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 2),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', 'family-wise error at 5%',
    'experiment_family', 'wu31-holm-family'
  );
  v_spec_bonf := jsonb_build_object(
    'hypothesis', 'Bonferroni family member.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 3),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', jsonb_build_object('method', 'bonferroni', 'alpha', 0.05),
    'experiment_family', 'wu31-bonferroni-family'
  );
  v_spec_conflict := jsonb_build_object(
    'hypothesis', 'Conflicting method in the Holm family.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 2),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', jsonb_build_object('method', 'bonferroni', 'alpha', 0.05),
    'experiment_family', 'wu31-holm-family'
  );
  v_spec_nofamily := jsonb_build_object(
    'hypothesis', 'No family key.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 2),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', 'Holm'
  );
  v_spec_nobudget := jsonb_build_object(
    'hypothesis', 'Budget object without a trial reservation.',
    'windows', jsonb_build_object('walk_forward', 3),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('purpose', 'compute only'),
    'stopping_rule', 'budget exhausted',
    'multiplicity_plan', 'Holm',
    'experiment_family', 'wu31-nobudget-family'
  );

  v_holm := holm_adjusted_p(ARRAY[0.04, 0.01]::numeric[]);
  v_bonf := bonferroni_adjusted_p(ARRAY[0.04, 0.01]::numeric[]);
  v_results := jsonb_build_object(
    'holm_default_vector',
      v_holm[1] = 0.04 AND v_holm[2] = 0.02,
    'bonferroni_vector',
      v_bonf[1] = 0.08 AND v_bonf[2] = 0.02,
    'default_plan_is_holm',
      experiment_family_correction_method(v_spec_b_default) = 'holm'
      AND experiment_family_correction_method(v_spec_a) = 'holm',
    'preregistered_bonferroni',
      experiment_family_correction_method(v_spec_bonf) = 'bonferroni'
  );

  BEGIN
    PERFORM experiment_family_correction_method(
      jsonb_build_object(
        'multiplicity_plan', jsonb_build_object('method', 'none')
      )
    );
    RAISE EXCEPTION 'probe corrupted: method none was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not an allowed preregistered method%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('uncorrected_method_blocked', true);
  END;

  SELECT * INTO v_a FROM register_experiment_preregistration(
    'wu31-holm-a', v_spec_a, NULL, v_lineage);
  SELECT * INTO v_b FROM register_experiment_preregistration(
    'wu31-holm-b', v_spec_b_default, NULL, v_lineage);
  SELECT * INTO v_c FROM register_experiment_preregistration(
    'wu31-holm-conflict', v_spec_conflict, NULL, v_lineage);

  BEGIN
    PERFORM record_experiment_trial(v_a.registration_id, 'successful', 0.01, v_lineage);
    RAISE EXCEPTION 'probe corrupted: conflicting family methods were accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%same correction method%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('conflicting_methods_blocked', true);
  END;

  -- Isolate Holm on a family without the conflicting member.
  v_spec_b := jsonb_set(v_spec_b_default, '{experiment_family}', '"wu31-holm-isolated"'::jsonb);
  v_spec_a := jsonb_set(v_spec_a, '{experiment_family}', '"wu31-holm-isolated"'::jsonb);
  SELECT * INTO v_d FROM register_experiment_preregistration(
    'wu31-holm-iso-a', v_spec_a, NULL, v_lineage);
  SELECT * INTO v_e FROM register_experiment_preregistration(
    'wu31-holm-iso-b', v_spec_b, NULL, v_lineage);

  PERFORM record_experiment_trial(v_d.registration_id, 'successful', 0.01, v_lineage);
  PERFORM record_experiment_trial(v_e.registration_id, 'successful', 0.04, v_lineage);
  SELECT * INTO v_corr FROM compute_experiment_family_correction(
    'wu31-holm-isolated', v_lineage);

  v_results := v_results || jsonb_build_object(
    'holm_applies_by_default',
      v_corr.method = 'holm'
      AND v_corr.alpha = 0.05
      AND v_corr.member_count = 2
      AND (v_corr.adjustments->0->>'adjusted_p')::numeric = 0.02
      AND (v_corr.adjustments->1->>'adjusted_p')::numeric = 0.04
      AND (v_corr.adjustments->0->>'rejected')::boolean IS TRUE
      AND (v_corr.adjustments->1->>'rejected')::boolean IS TRUE
  );

  SELECT * INTO v_trial FROM record_experiment_trial(
    v_d.registration_id, 'failed', 0.50, v_lineage);
  IF v_trial.trial_id IS NOT NULL THEN
    RAISE EXCEPTION 'probe corrupted: exhausted budget accepted another trial';
  END IF;
  v_results := v_results || jsonb_build_object(
    'exhausted_budget_refused', true,
    'refusal_recorded',
      (SELECT count(*) FROM experiment_trial_refusal
       WHERE family_key = 'wu31-holm-isolated') = 1
      AND (SELECT consumed_trials FROM experiment_trial_refusal
           WHERE family_key = 'wu31-holm-isolated' LIMIT 1) = 2
      AND (SELECT count(*) FROM experiment_trial
           WHERE family_key = 'wu31-holm-isolated') = 2
  );

  SELECT * INTO v_a FROM register_experiment_preregistration(
    'wu31-bonf-a',
    jsonb_set(v_spec_bonf, '{hypothesis}', '"Bonferroni A."'::jsonb),
    NULL, v_lineage);
  SELECT * INTO v_b FROM register_experiment_preregistration(
    'wu31-bonf-b',
    jsonb_set(v_spec_bonf, '{hypothesis}', '"Bonferroni B."'::jsonb),
    NULL, v_lineage);
  PERFORM record_experiment_trial(v_a.registration_id, 'successful', 0.01, v_lineage);
  PERFORM record_experiment_trial(v_b.registration_id, 'successful', 0.04, v_lineage);
  SELECT * INTO v_corr_bonf FROM compute_experiment_family_correction(
    'wu31-bonferroni-family', v_lineage);
  v_results := v_results || jsonb_build_object(
    'preregistered_bonferroni_applies',
      v_corr_bonf.method = 'bonferroni'
      AND (v_corr_bonf.adjustments->0->>'adjusted_p')::numeric = 0.02
      AND (v_corr_bonf.adjustments->1->>'adjusted_p')::numeric = 0.08
      AND (v_corr_bonf.adjustments->1->>'rejected')::boolean IS FALSE
  );

  SELECT * INTO v_f FROM register_experiment_preregistration(
    'wu31-nofamily', v_spec_nofamily, NULL, v_lineage);
  BEGIN
    PERFORM record_experiment_trial(v_f.registration_id, 'successful', 0.01, v_lineage);
    RAISE EXCEPTION 'probe corrupted: trial without experiment_family was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%requires a preregistered experiment_family%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_family_blocked', true);
  END;

  SELECT * INTO v_f FROM register_experiment_preregistration(
    'wu31-nobudget', v_spec_nobudget, NULL, v_lineage);
  BEGIN
    PERFORM record_experiment_trial(v_f.registration_id, 'successful', 0.01, v_lineage);
    RAISE EXCEPTION 'probe corrupted: trial without testing budget was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%requires a preregistered family testing budget%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_budget_blocked', true);
  END;

  BEGIN
    PERFORM record_experiment_trial(v_d.registration_id, 'successful', 1.2, v_lineage);
    RAISE EXCEPTION 'probe corrupted: p_value outside [0,1] was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%p_value must be in [0, 1]%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('invalid_p_value_blocked', true);
  END;

  BEGIN
    PERFORM compute_experiment_family_correction('wu31-nobudget-family', v_lineage);
    RAISE EXCEPTION 'probe corrupted: correction with no p-values was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%has no p-values to correct%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('empty_correction_blocked', true);
  END;

  BEGIN
    INSERT INTO experiment_trial (
      registration_id, family_key, outcome, p_value, trial_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_d.registration_id, 'wu31-holm-isolated', 'successful', 0.01,
      experiment_trial_digest(v_d.registration_id, 'wu31-holm-isolated', 'successful', 0.01),
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct trial INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through record_experiment_trial%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_trial_insert_blocked', true);
  END;

  BEGIN
    UPDATE experiment_trial SET outcome = 'failed' WHERE family_key = 'wu31-holm-isolated';
    RAISE EXCEPTION 'probe corrupted: trial was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('trial_update_blocked', true);
  END;

  BEGIN
    DELETE FROM experiment_trial_refusal WHERE family_key = 'wu31-holm-isolated';
    RAISE EXCEPTION 'probe corrupted: refusal was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('refusal_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE experiment_trial;
    RAISE EXCEPTION 'probe corrupted: experiment_trial was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%experiment_trial is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('trial_truncate_blocked', true);
  END;

  BEGIN
    TRUNCATE experiment_trial_refusal;
    RAISE EXCEPTION 'probe corrupted: experiment_trial_refusal was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%experiment_trial_refusal is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('refusal_truncate_blocked', true);
  END;

  BEGIN
    TRUNCATE experiment_family_correction;
    RAISE EXCEPTION 'probe corrupted: experiment_family_correction was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%experiment_family_correction is append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('correction_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'trials_audited', (
      SELECT count(*) >= 4
      FROM audit_event
      WHERE event_type = 'research.experiment_trial_recorded'
    ),
    'refusal_audited', (
      SELECT count(*) = 1
      FROM audit_event
      WHERE event_type = 'research.experiment_trial_refused'
        AND payload->>'family_key' = 'wu31-holm-isolated'
    ),
    'correction_audited', (
      SELECT count(*) = 2
      FROM audit_event
      WHERE event_type = 'research.experiment_family_correction_computed'
    )
  );

  INSERT INTO wu31_probe_result (result) VALUES (v_results);
END
$probe$;
