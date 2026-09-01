-- WU-47 Restricted-Issuer screening probe. Run inside a caller-managed
-- transaction; fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu47_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu47-probe","entitlement_version":"restricted-issuer-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_clean_issuer uuid := '47000000-0000-0000-0000-000000000401';
  v_restricted_issuer uuid := '47000000-0000-0000-0000-000000000402';
  v_clean_security uuid := '47000000-0000-0000-0000-000000000501';
  v_restricted_security uuid := '47000000-0000-0000-0000-000000000502';
  v_list1 restricted_issuer_list_version%ROWTYPE;
  v_list2 restricted_issuer_list_version%ROWTYPE;
  v_allow restricted_issuer_screening_decision%ROWTYPE;
  v_block_admit restricted_issuer_screening_decision%ROWTYPE;
  v_block_target restricted_issuer_screening_decision%ROWTYPE;
BEGIN
  PERFORM set_config('market_mate.security_master_write', 'on', true);
  INSERT INTO issuer (
    issuer_id, legal_name, source_lineage, receipt_time, record_environment
  ) VALUES
    (v_clean_issuer, 'WU-47 Clean Holdings, Inc.', v_lineage,
     '2026-01-01T00:00:00Z', 'local_research'),
    (v_restricted_issuer, 'WU-47 Employer Corp.', v_lineage,
     '2026-01-01T00:00:00Z', 'local_research');
  INSERT INTO security (
    security_id, issuer_id, security_class,
    source_lineage, receipt_time, record_environment
  ) VALUES
    (v_clean_security, v_clean_issuer, 'common_stock', v_lineage,
     '2026-01-01T00:00:00Z', 'local_research'),
    (v_restricted_security, v_restricted_issuer, 'common_stock', v_lineage,
     '2026-01-01T00:00:00Z', 'local_research');
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  BEGIN
    PERFORM screen_restricted_issuer(
      v_clean_security, 'universe_admission', v_lineage);
    RAISE EXCEPTION 'probe corrupted: screening succeeded with no list';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%list is not registered%' THEN RAISE; END IF;
      v_results := jsonb_build_object('unregistered_list_fail_closed', true);
  END;

  SELECT * INTO v_list1 FROM register_restricted_issuer_list(
    '[]'::jsonb, NULL, v_lineage);
  SELECT * INTO v_allow FROM screen_restricted_issuer(
    v_clean_security, 'universe_admission', v_lineage);

  SELECT * INTO v_list2 FROM register_restricted_issuer_list(
    jsonb_build_array(jsonb_build_object(
      'issuer_id', v_restricted_issuer,
      'restriction_class', 'employer',
      'reason', 'Principal employment relationship'
    )),
    v_list1.list_version_id,
    v_lineage);

  SELECT * INTO v_block_admit FROM screen_restricted_issuer(
    v_restricted_security, 'universe_admission', v_lineage);
  SELECT * INTO v_block_target FROM screen_restricted_issuer(
    v_restricted_security, 'research_targeting', v_lineage);
  SELECT * INTO v_allow FROM screen_restricted_issuer(
    v_clean_security, 'research_targeting', v_lineage);

  v_results := v_results || jsonb_build_object(
    'clean_allowed',
      v_allow.decision = 'allowed'
      AND v_allow.compliance_decision = 'not_restricted',
    'match_blocks_admission',
      v_block_admit.decision = 'blocked'
      AND v_block_admit.compliance_decision = 'restricted_issuer_match'
      AND v_block_admit.purpose = 'universe_admission',
    'match_blocks_targeting',
      v_block_target.decision = 'blocked'
      AND v_block_target.compliance_decision = 'restricted_issuer_match'
      AND v_block_target.purpose = 'research_targeting',
    'list_change_freezes_instruments',
      EXISTS (
        SELECT 1 FROM restricted_issuer_instrument_freeze f
        WHERE f.security_id = v_restricted_security
          AND f.list_version_id = v_list2.list_version_id
          AND f.freeze_kind = 'research_promotion'
      )
      AND NOT EXISTS (
        SELECT 1 FROM restricted_issuer_instrument_freeze f
        WHERE f.security_id = v_clean_security
      )
  );

  BEGIN
    PERFORM register_restricted_issuer_list(
      '[]'::jsonb, v_list2.list_version_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: list loosening was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%tighten-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('tighten_only_holds', true);
  END;

  BEGIN
    INSERT INTO restricted_issuer_screening_decision (
      list_version_id, security_id, issuer_id, purpose,
      decision, compliance_decision,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_list2.list_version_id, v_clean_security, v_clean_issuer,
      'universe_admission', 'allowed', 'not_restricted',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct screening INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the restricted-issuer workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE restricted_issuer_screening_decision
       SET decision = 'allowed'
     WHERE decision_id = v_block_admit.decision_id;
    RAISE EXCEPTION 'probe corrupted: screening decision was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('decision_update_blocked', true);
  END;

  BEGIN
    DELETE FROM restricted_issuer_screening_decision
     WHERE decision_id = v_block_admit.decision_id;
    RAISE EXCEPTION 'probe corrupted: screening decision was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('decision_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE restricted_issuer_screening_decision, restricted_issuer_instrument_freeze,
             restricted_issuer_membership, restricted_issuer_list_version;
    RAISE EXCEPTION 'probe corrupted: restricted-issuer tables were truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('decision_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'decision_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.restricted_issuer_screened'
        AND payload->>'compliance_decision' = 'restricted_issuer_match'
    ),
    'no_authority_grant',
      v_block_admit.record_environment = 'local_research'
      AND v_list2.record_environment = 'local_research'
  );

  INSERT INTO wu47_probe_result (result) VALUES (v_results);
END
$probe$;
