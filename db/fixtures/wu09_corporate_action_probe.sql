-- WU-09 corporate-action lifecycle probe. Run inside a caller-managed
-- transaction; asserts the full state progression, time-travel queries, and
-- refusal paths, then leaves one JSON row in wu09_probe_result.

CREATE TEMP TABLE wu09_probe_result (result jsonb NOT NULL);

DO $$ BEGIN PERFORM set_config('market_mate.security_master_write', 'on', true); END $$;

INSERT INTO issuer (issuer_id, legal_name, source_lineage, receipt_time, record_environment)
VALUES (
  '99999999-0000-0000-0000-000000000001', 'Probe Issuer',
  '{"source":"wu09-probe","entitlement_version":"local-v1"}',
  '2026-01-01T00:00:00Z', 'local_research'
);

INSERT INTO security (security_id, issuer_id, security_class, source_lineage, receipt_time, record_environment)
VALUES (
  '99999999-0000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000001', 'common_stock',
  '{"source":"wu09-probe","entitlement_version":"local-v1"}',
  '2026-01-01T00:00:00Z', 'local_research'
);

DO $probe$
DECLARE
  v_case_id uuid;
  v_terms_v1 uuid;
  v_terms_v2 uuid;
  v_state_at_rumor text;
  v_state_at_confirm text;
  v_state_at_effective text;
  v_state_at_final text;
  v_terms_at_rumor jsonb;
  v_terms_at_current jsonb;
  v_digest_v1 text;
  v_digest_v2 text;
  v_superseded_link uuid;
  v_results jsonb := '{}'::jsonb;
  v_lineage jsonb := '{"source":"wu09-probe","entitlement_version":"local-v1"}';
BEGIN
  v_case_id := (open_corporate_action_case(
    '99999999-0000-0000-0000-000000000002', 'stock_split', 'rumored', v_lineage
  )).case_id;
  v_results := v_results || jsonb_build_object('case_opened_rumored', true);

  v_state_at_rumor := corporate_action_case_state(v_case_id, now());
  v_results := v_results || jsonb_build_object('state_rumored', v_state_at_rumor = 'rumored');

  PERFORM record_corporate_action_observation(
    v_case_id, 'announced', 'company press release', '2-for-1 split expected', v_lineage);
  PERFORM record_corporate_action_observation(
    v_case_id, 'terms_pending', 'exchange notice', 'awaiting official terms', v_lineage);

  v_terms_v1 := (add_corporate_action_terms(
    v_case_id,
    '{"ratio": "2-for-1", "pay_date": "2026-03-02", "ex_date": "2026-03-03"}'::jsonb,
    v_lineage
  )).terms_id;
  v_digest_v1 := (SELECT terms_digest FROM corporate_action_terms_version t WHERE t.terms_id = v_terms_v1);
  v_results := v_results || jsonb_build_object(
    'terms_v1_digest_shape', v_digest_v1 ~ '^[0-9a-f]{64}$'
  );

  PERFORM record_corporate_action_observation(
    v_case_id, 'authoritatively_confirmed', 'SEC filing 8-K', 'official terms published', v_lineage);
  v_state_at_confirm := corporate_action_case_state(v_case_id, now());
  v_results := v_results || jsonb_build_object('state_confirmed', v_state_at_confirm = 'authoritatively_confirmed');

  PERFORM record_corporate_action_observation(
    v_case_id, 'effective', 'ex-date reached', NULL, v_lineage);
  v_state_at_effective := corporate_action_case_state(v_case_id, now());
  v_results := v_results || jsonb_build_object('state_effective', v_state_at_effective = 'effective');

  v_terms_v2 := (add_corporate_action_terms(
    v_case_id,
    '{"ratio": "2-for-1", "pay_date": "2026-03-02", "ex_date": "2026-03-03", "fractional_handling": "cash_in_lieu"}'::jsonb,
    v_lineage
  )).terms_id;
  v_digest_v2 := (SELECT terms_digest FROM corporate_action_terms_version t WHERE t.terms_id = v_terms_v2);
  v_superseded_link := (SELECT superseded_by_terms_id FROM corporate_action_terms_version t WHERE t.terms_id = v_terms_v1);
  v_results := v_results || jsonb_build_object(
    'terms_v2_supersedes_v1', v_superseded_link = v_terms_v2,
    'digests_distinct', v_digest_v1 <> v_digest_v2
  );

  PERFORM record_corporate_action_observation(
    v_case_id, 'broker_reconciled', 'broker position reflects split', NULL, v_lineage);
  PERFORM record_corporate_action_observation(
    v_case_id, 'final', 'evidence complete', NULL, v_lineage);
  v_state_at_final := corporate_action_case_state(v_case_id, now());
  v_results := v_results || jsonb_build_object('state_final', v_state_at_final = 'final');
  v_results := v_results || jsonb_build_object(
    'observed_state_names',
    (SELECT jsonb_agg(observed_state ORDER BY observation_seq)
     FROM corporate_action_state_observation o WHERE o.case_id = v_case_id)
  );

  v_results := v_results || jsonb_build_object(
    'full_progression_recorded',
    (SELECT count(*) = 7 FROM corporate_action_state_observation o WHERE o.case_id = v_case_id)
  );

  BEGIN
    PERFORM record_corporate_action_observation(
      v_case_id, 'announced', 'regression attempt', NULL, v_lineage);
    RAISE EXCEPTION 'probe corrupted: final -> announced was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'corporate action state progression%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('no_regression_after_final', true);
  END;

  v_terms_at_rumor := (corporate_action_terms_at(v_case_id, now() - interval '1 hour')).terms;
  v_results := v_results || jsonb_build_object('terms_before_publication_absent', v_terms_at_rumor IS NULL);

  v_terms_at_current := (corporate_action_terms_at(v_case_id, clock_timestamp())).terms;
  v_results := v_results || jsonb_build_object(
    'terms_time_travel_current', v_terms_at_current ->> 'fractional_handling' = 'cash_in_lieu'
  );

  BEGIN
    PERFORM open_corporate_action_case(
      '99999999-0000-0000-0000-000000000002', 'stock_split', 'effective', v_lineage);
    RAISE EXCEPTION 'probe corrupted: case opened directly at effective was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'corporate action state progression%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('new_case_cannot_skip_to_effective', true);
  END;

  BEGIN
    DELETE FROM corporate_action_case t WHERE t.case_id = v_case_id;
    RAISE EXCEPTION 'probe corrupted: DELETE was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'corporate action records are never deleted%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('delete_blocked', true);
  END;

  BEGIN
    UPDATE corporate_action_terms_version t SET terms = '{"tampered": true}'::jsonb WHERE t.terms_id = v_terms_v1;
    RAISE EXCEPTION 'probe corrupted: terms UPDATE was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'corporate action writes must go through%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('terms_update_blocked', true);
  END;

  INSERT INTO wu09_probe_result (result) VALUES (v_results);
END
$probe$;
