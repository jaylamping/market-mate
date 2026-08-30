-- WU-18 Evidence Profile and Obligation probe. Run inside a
-- caller-managed transaction; the acceptance script rolls fixture data back.

CREATE TEMP TABLE wu18_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu18-probe","entitlement_version":"evidence-profile-v1"}';
  v_universal research_evidence_profile_resolution%ROWTYPE;
  v_options research_evidence_profile_resolution%ROWTYPE;
  v_holding research_evidence_profile_resolution%ROWTYPE;
  v_portfolio research_evidence_profile_resolution%ROWTYPE;
  v_pending_artifact_body jsonb := '{"assertions":{"pending_proof_must_not_resolve":true},"proof_expression":{"test":"wu18_pending_proof_probe"}}'::jsonb;
  v_pending_artifact_digest text;
  v_pending_rule_id uuid;
  v_results jsonb;
BEGIN
  SELECT * INTO v_universal FROM resolve_research_evidence_profile(
    'research_candidate', 'stock_eligible', 'research',
    '2026-08-29T20:00:00Z', v_lineage
  );
  SELECT * INTO v_options FROM resolve_research_evidence_profile(
    'trade_eligible', 'options_eligible', 'new_exposure',
    '2026-08-29T20:00:00Z', v_lineage
  );
  SELECT * INTO v_holding FROM resolve_research_evidence_profile(
    'mandatory_holding', 'options_eligible', 'holding_management',
    '2026-08-29T20:00:00Z', v_lineage
  );
  SELECT * INTO v_portfolio FROM resolve_research_evidence_profile(
    'trade_eligible', 'both', 'portfolio_review',
    '2026-08-29T20:00:00Z', v_lineage
  );

  v_results := jsonb_build_object(
    'universal_profile_resolved', v_universal.profile_kind = 'universal'
      AND v_universal.obligation_count >= 3,
    'options_profile_resolved', v_options.profile_kind = 'options'
      AND v_options.obligation_count >= 2,
    'holding_profile_resolved', v_holding.profile_kind = 'holding'
      AND v_holding.obligation_count >= 2,
    'portfolio_profile_resolved', v_portfolio.profile_kind = 'portfolio'
      AND v_portfolio.obligation_count >= 2,
    'profiles_are_typed_and_distinct', (
      SELECT count(DISTINCT profile_kind) = 4
      FROM research_evidence_profile_resolution
      WHERE resolution_id IN (
        v_universal.resolution_id, v_options.resolution_id,
        v_holding.resolution_id, v_portfolio.resolution_id
      )
    ),
    'proof_artifact_bound', (
      SELECT count(*) = 1
        AND bool_and(a.verification_state = 'verified')
        AND bool_and(r.proof_artifact_digest = a.artifact_digest)
        AND bool_and(a.artifact_body -> 'proof_expression' IS NOT DISTINCT FROM r.proof_expression)
        AND bool_and(a.artifact_digest = encode(digest(a.artifact_body::text, 'sha256'), 'hex'))
      FROM research_evidence_contract_rule r
      JOIN research_evidence_proof_artifact a
        ON a.artifact_ref = r.proof_artifact_ref
       AND a.artifact_digest = r.proof_artifact_digest
      WHERE r.rule_key = 'stock-coverage-options-not-applicable-v1'
    ),
    'not_applicable_has_proved_rule', (
      SELECT bool_and(
        obligation->>'applicability' <> 'not_applicable'
        OR (
          (obligation->'not_applicable_rule'->>'proof_status') = 'proved'
          AND (obligation->'not_applicable_rule'->>'verification_state') = 'verified'
          AND coalesce(obligation->'not_applicable_rule'->>'proof_artifact_digest', '') ~ '^[0-9a-f]{64}$'
        )
      )
      FROM jsonb_array_elements(v_universal.obligations) obligation
    ),
    'no_default_substitution_in_profiles', (
      SELECT bool_and(default_substitute IS NULL)
      FROM research_evidence_obligation
      WHERE profile_version_id IN (
        v_universal.profile_version_id, v_options.profile_version_id,
        v_holding.profile_version_id, v_portfolio.profile_version_id
      )
    ),
    'overlapping_route_blocked', false,
    'unproved_not_applicable_blocked', false,
    'unverified_proof_blocked', false,
    'proof_expression_binding_blocked', false,
    'verified_artifact_direct_insert_blocked', false,
    'proof_artifact_update_blocked', false,
    'resolution_update_blocked', false,
    'obligation_update_blocked', false
  );

  BEGIN
    INSERT INTO research_evidence_profile_route (
      coverage_stage, coverage_capability, decision_purpose,
      profile_version_id, valid_from, valid_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'research_candidate', 'stock_eligible', 'research',
      v_options.profile_version_id, '2026-06-01T00:00:00Z', NULL,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted an overlapping typed evidence profile route';
  EXCEPTION
    WHEN exclusion_violation THEN
      IF SQLERRM NOT LIKE '%research_evidence_profile_route_no_overlap%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('overlapping_route_blocked', true);
  END;

  BEGIN
    INSERT INTO research_evidence_proof_artifact (
      proof_artifact_id, artifact_ref, artifact_body, artifact_digest,
      verification_state, verification_result, source_lineage,
      receipt_time, record_environment
    ) VALUES (
      '18000000-0000-0000-0000-000000000003',
      'probe:wu18:direct-verified',
      '{"proof_expression":{"test":"direct"}}'::jsonb,
      encode(digest('{"proof_expression":{"test":"direct"}}'::jsonb::text, 'sha256'), 'hex'),
      'verified', '{"status":"verified"}'::jsonb, v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted a directly inserted verified proof artifact';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%proof artifacts must be recorded%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('verified_artifact_direct_insert_blocked', true);
  END;

  BEGIN
    INSERT INTO research_evidence_obligation (
      profile_version_id, obligation_key, evidence_family, description,
      applicability, required_observation_states, not_applicable_rule_id,
      default_substitute, source_lineage, receipt_time, record_environment
    ) VALUES (
      v_universal.profile_version_id, 'WU18-invalid-na', 'options_structure',
      'intentionally unproved Not Applicable obligation', 'not_applicable',
      '[]'::jsonb, NULL, NULL, v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted Not Applicable without a proved rule';
  EXCEPTION
    WHEN check_violation THEN
      IF SQLERRM NOT LIKE '%not_applicable_requires_proof%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unproved_not_applicable_blocked', true);
  END;

  BEGIN
    PERFORM record_research_evidence_contract_rule(
      'WU18-mismatched-proof-rule', 'Probe-only rule with the wrong proof expression.',
      '{"test":"wu18_mismatched_proof_probe"}'::jsonb, 'proved',
      'migration:0018:wu18_stock_options_contract_v1',
      (SELECT artifact_digest
       FROM research_evidence_proof_artifact
       WHERE artifact_ref = 'migration:0018:wu18_stock_options_contract_v1'),
      v_lineage
    );
    RAISE EXCEPTION 'probe accepted a rule with a mismatched proof artifact';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%does not match its proof artifact%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('proof_expression_binding_blocked', true);
  END;

  v_pending_artifact_digest := encode(digest(v_pending_artifact_body::text, 'sha256'), 'hex');
  PERFORM record_research_evidence_proof_artifact(
    'probe:wu18:pending-proof', v_pending_artifact_body,
    'pending', '{"status":"pending"}'::jsonb, v_lineage
  );

  SELECT rule_id INTO v_pending_rule_id
  FROM record_research_evidence_contract_rule(
    'WU18-pending-proof-rule', 'Probe-only rule with an unverified artifact.',
    '{"test":"wu18_pending_proof_probe"}'::jsonb, 'proved',
    'probe:wu18:pending-proof', v_pending_artifact_digest,
    v_lineage
  );

  INSERT INTO research_evidence_obligation (
    profile_version_id, obligation_key, evidence_family, description,
    applicability, required_observation_states, not_applicable_rule_id,
    default_substitute, source_lineage, receipt_time, record_environment
  ) VALUES (
    v_universal.profile_version_id, 'WU18-unverified-na', 'options_structure',
    'probe-only Not Applicable obligation with an unverified proof artifact',
    'not_applicable', '[]'::jsonb, v_pending_rule_id,
    NULL, v_lineage, now(), 'local_research'
  );

  BEGIN
    PERFORM resolve_research_evidence_profile(
      'research_candidate', 'stock_eligible', 'research',
      '2026-08-29T20:00:00Z', v_lineage
    );
    RAISE EXCEPTION 'probe accepted Not Applicable with an unverified proof artifact';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%lacks a proved contract rule%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unverified_proof_blocked', true);
  END;

  BEGIN
    UPDATE research_evidence_proof_artifact
       SET verification_result = '{"status":"tampered"}'::jsonb
     WHERE artifact_ref = 'migration:0018:wu18_stock_options_contract_v1';
    RAISE EXCEPTION 'probe corrupted: proof artifact was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('proof_artifact_update_blocked', true);
  END;

  BEGIN
    UPDATE research_evidence_profile_resolution
       SET obligation_count = obligation_count + 1
     WHERE resolution_id = v_options.resolution_id;
    RAISE EXCEPTION 'probe corrupted: profile resolution was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('resolution_update_blocked', true);
  END;

  BEGIN
    UPDATE research_evidence_obligation
       SET description = 'tampered but valid description'
     WHERE profile_version_id = v_options.profile_version_id
       AND obligation_key = 'options_chain';
    RAISE EXCEPTION 'probe corrupted: evidence obligation was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('obligation_update_blocked', true);
  END;

  INSERT INTO wu18_probe_result (result) VALUES (v_results);
END
$probe$;
