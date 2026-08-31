-- WU-39 Incubator substrate probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu39_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu39-probe","entitlement_version":"incubator-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_source_id uuid := '39000000-0000-0000-0000-000000000001';
  v_source_v uuid := '39000000-0000-0000-0000-000000000101';
  v_ent_id uuid := '39000000-0000-0000-0000-000000000301';
  v_ent_ok uuid := '39000000-0000-0000-0000-000000000302';
  v_ent_bad_id uuid := '39000000-0000-0000-0000-000000000303';
  v_ent_bad uuid := '39000000-0000-0000-0000-000000000304';
  v_prereg jsonb;
  v_reg experiment_preregistration%ROWTYPE;
  v_spec jsonb;
  v_child jsonb;
  v_manager jsonb;
  v_risk jsonb;
  v_compliance jsonb;
  v_paper jsonb;
  v_result jsonb;
  v_fail jsonb;
  v_shot alpha_shot%ROWTYPE;
  v_shot_again alpha_shot%ROWTYPE;
  v_child_shot alpha_shot%ROWTYPE;
  v_decision entitlement_gate_decision%ROWTYPE;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'wu39-licensed-eod', 'WU-39 Licensed EOD', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v, v_source_id, 1, 'active',
    '{"name":"WU-39 Licensed Terms","version":"2026.1"}',
    '{"purposes":["local_research"]}',
    '{"required_fields":["source_observation_id","received_at"]}',
    ARRAY['current','stale','missing','incomplete'],
    ARRAY['factual_correction','retraction','source_unavailability'],
    '2026-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_ent_id, 'wu39-certified-entitlement', 'local-research-account',
    'WU-39 certified plan', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ), (
    v_ent_bad_id, 'wu39-uncertified-entitlement', 'local-research-account',
    'WU-39 uncertified plan', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_ent_ok, v_ent_id, 1, v_source_v, 'certified',
    ARRAY['local_research'], '2026-01-01T00:00:00Z', NULL,
    '{"authority":"principal-approved-research-plan","certificate":"wu39-cert"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ), (
    v_ent_bad, v_ent_bad_id, 1, v_source_v, 'uncertified',
    ARRAY['local_research'], '2026-01-01T00:00:00Z', NULL,
    '{"authority":"pending","certificate":"not-issued"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  v_prereg := jsonb_build_object(
    'hypothesis', 'Point-in-time earnings direction beats cash.',
    'windows', jsonb_build_object('walk_forward', 3, 'holdout_sessions', 60),
    'estimators', jsonb_build_array('block_bootstrap_lcb'),
    'budget', jsonb_build_object('family_trials', 4),
    'stopping_rule', 'halt when testing budget is exhausted',
    'multiplicity_plan', 'Holm across the earnings-direction family',
    'experiment_family', 'wu39-earnings-direction'
  );
  SELECT * INTO v_reg FROM register_experiment_preregistration(
    'wu39-earnings-direction', v_prereg, NULL, v_lineage);

  v_spec := jsonb_build_object(
    'assignment_key', 'wu39-alpha-1',
    'lane', 'research',
    'desk_role', 'quantitative_research_and_experimentation',
    'profit_contribution_hypothesis', jsonb_build_object(
      'claim', 'A cheap earnings-direction Alpha Shot can falsify a weak thesis quickly.',
      'metric', 'net_excess_return_bps',
      'cost_envelope', jsonb_build_object('family_trials', 1),
      'stopping_rule', 'stop after one recorded result'
    ),
    'budget', jsonb_build_object('family_trials', 1),
    'stopping_rule', 'stop after one recorded result',
    'registration_id', v_reg.registration_id
  );
  v_result := jsonb_build_object(
    'outcome', 'failed',
    'reason', 'insufficient independent clusters'
  );
  SELECT * INTO v_shot FROM record_alpha_shot(
    v_spec, v_result, NULL, 'insufficient_sample', v_lineage);
  SELECT * INTO v_shot_again FROM record_alpha_shot(
    v_spec, v_result, NULL, 'insufficient_sample', v_lineage);

  v_child := jsonb_set(v_spec, '{assignment_key}', '"wu39-alpha-2"'::jsonb);
  v_fail := jsonb_build_object(
    'outcome', 'completed',
    'reason', 'successor after failed parent'
  );
  SELECT * INTO v_child_shot FROM record_alpha_shot(
    v_child, v_fail, v_shot.shot_id, NULL, v_lineage);

  v_results := jsonb_build_object(
    'alpha_shot_recorded',
      v_shot.shot_id IS NOT NULL
      AND v_shot.record_environment = 'local_research'
      AND v_shot.hypothesis->>'claim' IS NOT NULL
      AND v_shot.hypothesis ? 'metric'
      AND v_shot.hypothesis ? 'cost_envelope'
      AND v_shot.hypothesis ? 'stopping_rule'
      AND v_shot.budget ? 'family_trials'
      AND v_shot.result->>'outcome' = 'failed'
      AND v_shot.failure_class = 'insufficient_sample'
      AND v_shot.parent_shot_id IS NULL
      AND v_shot.shot_digest ~ '^[0-9a-f]{64}$',
    'failure_lineage',
      v_child_shot.parent_shot_id = v_shot.shot_id
      AND v_child_shot.result->>'outcome' = 'completed'
      AND (SELECT count(*) FROM alpha_shot
           WHERE parent_shot_id = v_shot.shot_id) = 1,
    'single_research_lane',
      (SELECT bool_and(lane = 'research') FROM incubator_assignment)
      AND (SELECT assignment_id FROM incubator_assignment
           WHERE assignment_id = v_shot.assignment_id) IS NOT NULL
      AND (SELECT state FROM incubator_assignment
           WHERE assignment_id = v_shot.assignment_id) = 'scheduled',
    'record_is_idempotent',
      v_shot_again.shot_id = v_shot.shot_id
      AND (SELECT count(*) FROM alpha_shot
           WHERE assignment_id = v_shot.assignment_id) = 1
  );

  SELECT * INTO v_decision FROM sentinel_allow_alpha_shot_evidence(
    v_shot.shot_id, v_ent_ok, 'local_research',
    '2026-08-01T00:00:00Z'::timestamptz, v_lineage);
  v_results := v_results || jsonb_build_object(
    'sentinel_allows_entitled_use',
      v_decision.decision = 'allowed'
  );

  BEGIN
    PERFORM sentinel_allow_alpha_shot_evidence(
      v_shot.shot_id, v_ent_bad, 'local_research',
      '2026-08-01T00:00:00Z'::timestamptz, v_lineage);
    RAISE EXCEPTION 'probe corrupted: uncertified evidence use was allowed';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%sentinel denied non-entitled evidence use%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('sentinel_denies_non_entitled_use', true);
  END;

  v_manager := jsonb_set(v_spec, '{assignment_key}', '"wu39-manager"'::jsonb);
  v_manager := jsonb_set(v_manager, '{desk_role}', '"manager"'::jsonb);
  BEGIN
    PERFORM record_alpha_shot(
      v_manager, jsonb_build_object('outcome', 'completed'), NULL, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: manager assignment was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%nonconforming assignment%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('manager_assignment_rejected', true);
  END;

  v_risk := jsonb_set(v_spec, '{assignment_key}', '"wu39-risk"'::jsonb);
  v_risk := jsonb_set(v_risk, '{desk_role}', '"risk"'::jsonb);
  BEGIN
    PERFORM engine_admit_research_assignment(v_risk, v_lineage);
    RAISE EXCEPTION 'probe corrupted: risk assignment was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%nonconforming assignment%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('risk_assignment_rejected', true);
  END;

  v_compliance := jsonb_set(v_spec, '{assignment_key}', '"wu39-compliance"'::jsonb);
  v_compliance := jsonb_set(v_compliance, '{desk_role}', '"compliance"'::jsonb);
  BEGIN
    PERFORM engine_admit_research_assignment(v_compliance, v_lineage);
    RAISE EXCEPTION 'probe corrupted: compliance assignment was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%nonconforming assignment%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('compliance_assignment_rejected', true);
  END;

  BEGIN
    PERFORM record_alpha_shot(
      jsonb_set(v_spec, '{assignment_key}', '"wu39-null-outcome"'::jsonb),
      jsonb_build_object('outcome', NULL),
      NULL, NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: null outcome was recorded';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%alpha shot arguments are invalid%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('null_outcome_blocked', true);
  END;

  BEGIN
    PERFORM engine_admit_research_assignment(
      jsonb_set(
        jsonb_set(v_spec, '{assignment_key}', '"wu39-empty-stop"'::jsonb),
        '{stopping_rule}', '{}'::jsonb
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: empty stopping_rule was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%nonconforming assignment%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('empty_stopping_rule_blocked', true);
  END;

  BEGIN
    PERFORM engine_admit_research_assignment(
      jsonb_set(v_spec, '{budget}', jsonb_build_object('family_trials', 9)),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: assignment spec mutation was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already registered with a different spec%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('spec_mismatch_blocked', true);
  END;

  v_paper := jsonb_set(v_spec, '{assignment_key}', '"wu39-paper"'::jsonb);
  v_paper := jsonb_set(v_paper, '{lane}', '"paper"'::jsonb);
  BEGIN
    PERFORM engine_admit_research_assignment(v_paper, v_lineage);
    RAISE EXCEPTION 'probe corrupted: paper lane assignment was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%nonconforming assignment%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('paper_lane_rejected', true);
  END;

  BEGIN
    INSERT INTO alpha_shot (
      assignment_id, hypothesis, budget, stopping_rule, result, shot_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_shot.assignment_id, v_shot.hypothesis, v_shot.budget, v_shot.stopping_rule,
      v_shot.result, v_shot.shot_digest, v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct alpha_shot INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the incubator workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE alpha_shot SET result = v_shot.result WHERE shot_id = v_shot.shot_id;
    RAISE EXCEPTION 'probe corrupted: alpha shot was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('shot_update_blocked', true);
  END;

  BEGIN
    DELETE FROM alpha_shot WHERE shot_id = v_shot.shot_id;
    RAISE EXCEPTION 'probe corrupted: alpha shot was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('shot_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE alpha_shot, incubator_assignment;
    RAISE EXCEPTION 'probe corrupted: alpha shot was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('shot_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'shot_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.alpha_shot_recorded'
        AND payload->>'shot_digest' = v_shot.shot_digest
    ),
    'no_authority_grant',
      v_shot.record_environment = 'local_research'
      AND (SELECT bool_and(record_environment = 'local_research')
           FROM incubator_assignment)
  );

  INSERT INTO wu39_probe_result (result) VALUES (v_results);
END
$probe$;
