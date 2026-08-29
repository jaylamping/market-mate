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
    'not_applicable_has_proved_rule', (
      SELECT bool_and(
        obligation->>'applicability' <> 'not_applicable'
        OR (
          (obligation->'not_applicable_rule'->>'proof_status') = 'proved'
          AND coalesce(obligation->'not_applicable_rule'->>'proof_artifact_digest', '') ~ '^[0-9a-f]{64}$'
        )
      )
      FROM jsonb_array_elements(v_universal.obligations) obligation
    ),
    'no_default_substitution_in_profiles', (
      SELECT bool_and(NOT obligation ? 'default_substitute')
      FROM jsonb_array_elements(
        v_universal.obligations || v_options.obligations
          || v_holding.obligations || v_portfolio.obligations
      ) obligation
    ),
    'unproved_not_applicable_blocked', false,
    'resolution_update_blocked', false,
    'obligation_update_blocked', false
  );

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
