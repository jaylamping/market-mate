-- WU-14 earnings estimates and EDGAR reconciliation probe. Run inside a
-- caller-managed transaction; the acceptance script rolls all fixture data back.

CREATE TEMP TABLE wu14_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_earnings_source_id uuid := '50000000-0000-0000-0000-000000000001';
  v_earnings_source_v1 uuid := '50000000-0000-0000-0000-000000000101';
  v_earnings_entitlement_id uuid := '50000000-0000-0000-0000-000000000201';
  v_earnings_entitlement_v1 uuid := '50000000-0000-0000-0000-000000000301';
  v_edgar_source_id uuid := '50000000-0000-0000-0000-000000000002';
  v_edgar_source_v1 uuid := '50000000-0000-0000-0000-000000000102';
  v_edgar_entitlement_id uuid := '50000000-0000-0000-0000-000000000202';
  v_edgar_entitlement_v1 uuid := '50000000-0000-0000-0000-000000000302';
  v_issuer_id uuid := '50000000-0000-0000-0000-000000000401';
  v_security_id uuid := '50000000-0000-0000-0000-000000000402';
  v_security_mapping instrument_mapping%ROWTYPE;
  v_issuer_mapping instrument_mapping%ROWTYPE;
  v_estimate earnings_estimate_observation%ROWTYPE;
  v_missing_estimate earnings_estimate_observation%ROWTYPE;
  v_filing edgar_filing%ROWTYPE;
  v_actual edgar_xbrl_actual%ROWTYPE;
  v_reconciliation earnings_actual_reconciliation%ROWTYPE;
  v_lineage jsonb := '{"source":"wu14-probe","entitlement_version":"earnings-v1"}';
  v_results jsonb;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_earnings_source_id, 'licensed-earnings-wu14', 'Licensed Earnings WU-14 Provider', 'fundamental_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_edgar_source_id, 'sec-edgar-wu14', 'SEC EDGAR WU-14 Actuals', 'public_filing',
    '{"source":"sec-edgar-wu14","entitlement_version":"edgar-v1"}',
    '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_earnings_source_v1, v_earnings_source_id, 1, 'active',
    '{"name":"Licensed Earnings WU-14 Terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["vendor_observation_key","as_of_at","announcement_at","received_at"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','source_unavailability','provenance_dispute'],
    '2026-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_edgar_source_v1, v_edgar_source_id, 1, 'active',
    '{"name":"SEC EDGAR public filing terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["accession_number","filed_at","received_at"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','source_unavailability','provenance_dispute'],
    '2026-01-01T00:00:00Z', NULL,
    '{"source":"sec-edgar-wu14","entitlement_version":"edgar-v1"}',
    '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_earnings_entitlement_id, 'licensed-earnings-wu14-entitlement', 'local-research-account',
    'Licensed as-of earnings estimates', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_edgar_entitlement_id, 'sec-edgar-wu14-entitlement', 'local-research-account',
    'SEC EDGAR actual reconciliation access',
    '{"source":"sec-edgar-wu14","entitlement_version":"edgar-v1"}',
    '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_earnings_entitlement_v1, v_earnings_entitlement_id, 1, v_earnings_source_v1, 'certified',
    ARRAY['local_research','paper_validation'],
    '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-earnings-wu14-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_edgar_entitlement_v1, v_edgar_entitlement_id, 1, v_edgar_source_v1, 'certified',
    ARRAY['local_research','paper_validation'],
    '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"public-filing-policy","certificate":"sec-edgar-wu14-2026.1"}',
    '{"source":"sec-edgar-wu14","entitlement_version":"edgar-v1"}',
    '2026-01-01T00:00:00Z', 'local_research'
  );

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  INSERT INTO issuer (
    issuer_id, legal_name, source_lineage, receipt_time, record_environment
  ) VALUES (
    v_issuer_id, 'WU-14 Earnings Holdings, Inc.', v_lineage,
    '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO security (
    security_id, issuer_id, security_class,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_security_id, v_issuer_id, 'common_stock', v_lineage,
    '2026-01-01T00:00:00Z', 'local_research'
  );
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  SELECT * INTO v_security_mapping FROM propose_instrument_mapping(
    'licensed-earnings-wu14', 'WU14', 'security',
    NULL, v_security_id, NULL, '2026-01-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_security_mapping FROM transition_instrument_mapping(
    v_security_mapping.mapping_id, 'corroborated', 'independent earnings identity check', v_lineage
  );
  SELECT * INTO v_security_mapping FROM transition_instrument_mapping(
    v_security_mapping.mapping_id, 'certified', 'WU-14 connector certification fixture', v_lineage
  );
  SELECT * INTO v_issuer_mapping FROM propose_instrument_mapping(
    'sec-edgar-wu14', 'CIK000014', 'issuer',
    v_issuer_id, NULL, NULL, '2026-01-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_issuer_mapping FROM transition_instrument_mapping(
    v_issuer_mapping.mapping_id, 'corroborated', 'EDGAR identity corroboration', v_lineage
  );
  SELECT * INTO v_issuer_mapping FROM transition_instrument_mapping(
    v_issuer_mapping.mapping_id, 'certified', 'EDGAR actual certification fixture', v_lineage
  );

  SELECT * INTO v_estimate FROM ingest_earnings_estimate(
    v_security_mapping.mapping_id, v_earnings_source_v1, v_earnings_entitlement_v1,
    'WU14-EPS-2026Q2', '2026-06-30', 'eps_basic', 2.50, 'USD_PER_SHARE', 'USD',
    '2026-08-05T20:00:00Z', '2026-07-15T12:00:00Z',
    '{"metric":"eps_basic","estimate":2.50,"as_of":"2026-07-15T12:00:00Z"}'::jsonb,
    v_lineage
  );

  BEGIN
    PERFORM ingest_earnings_estimate(
      v_security_mapping.mapping_id, v_earnings_source_v1, v_earnings_entitlement_v1,
      'WU14-missing-as-of', '2026-06-30', 'eps_basic', 2.50, 'USD_PER_SHARE', 'USD',
      '2026-08-05T20:00:00Z', NULL,
      '{"metric":"eps_basic","estimate":2.50}'::jsonb, v_lineage
    );
    RAISE EXCEPTION 'probe corrupted: estimate without as-of timestamp was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'earnings estimate as_of_at is required%' THEN RAISE; END IF;
  END;

  SELECT * INTO v_filing FROM ingest_edgar_filing(
    '0000140000-26-000001', v_issuer_mapping.mapping_id, '8-K',
    v_edgar_source_v1, v_edgar_entitlement_v1, '2026-08-05T20:00:00Z',
    'https://www.sec.gov/Archives/edgar/data/140000/000014000026000001/earnings.htm',
    'text/html', '<html><body>Actual EPS 2.35</body></html>',
    '{"source":"sec-edgar-wu14","entitlement_version":"edgar-v1"}'::jsonb
  );
  SELECT * INTO v_actual FROM ingest_edgar_xbrl_actual(
    v_filing.filing_id, 'eps_basic', '2.35', 'USD_PER_SHARE',
    '2026-04-01T00:00:00Z', '2026-06-30T00:00:00Z',
    '<xbrl><fact name="eps_basic">2.35</fact></xbrl>',
    '{"source":"sec-edgar-wu14","entitlement_version":"edgar-v1"}'::jsonb
  );
  SELECT * INTO v_reconciliation FROM reconcile_earnings_actual(
    v_estimate.estimate_id, v_actual.actual_id, 0.0001, v_lineage
  );

  v_results := jsonb_build_object(
    'estimate_ingested', v_estimate.estimate_id IS NOT NULL,
    'as_of_timestamp_attached', v_estimate.as_of_at = '2026-07-15T12:00:00Z',
    'announcement_timestamp_attached', v_estimate.announcement_at = '2026-08-05T20:00:00Z',
    'missing_as_of_rejected', NOT EXISTS (
      SELECT 1 FROM earnings_estimate_observation
      WHERE vendor_observation_key = 'WU14-missing-as-of'
    ),
    'actual_edgar_linked', (
      SELECT s.source_kind = 'public_filing'
        AND f.issuer_id = v_issuer_id
        AND m.lifecycle = 'certified'
      FROM edgar_xbrl_actual a
      JOIN edgar_filing f ON f.filing_id = a.filing_id
      JOIN source_registry_version sv ON sv.source_version_id = f.source_registry_version_id
      JOIN source_registry s ON s.source_id = sv.source_id
      JOIN instrument_mapping m ON m.mapping_id = f.instrument_mapping_id
      WHERE a.actual_id = v_actual.actual_id
    ),
    'announcement_linked', v_reconciliation.announcement_at = v_reconciliation.actual_filed_at,
    'disagreement_surfaced', v_reconciliation.reconciliation_status = 'disagreement'
      AND v_reconciliation.variance = -0.15,
    'reconciliation_provenance_attached',
      v_reconciliation.estimate_source_registry_version_id = v_earnings_source_v1
      AND v_reconciliation.estimate_entitlement_version_id = v_earnings_entitlement_v1
      AND v_reconciliation.edgar_source_registry_version_id = v_edgar_source_v1
      AND v_reconciliation.edgar_entitlement_version_id = v_edgar_entitlement_v1,
    'entitlement_gate_allowed', (
      SELECT decision = 'allowed'
      FROM entitlement_gate_decision
      WHERE request_key LIKE 'wu14-earnings:WU14-EPS-2026Q2:%'
    ),
    'entitled_uses_recorded', (
      SELECT count(*) = 4
      FROM entitled_use_receipt r
      JOIN entitlement_gate_decision d ON d.decision_id = r.decision_id
      WHERE d.source_registry_version_id IN (v_earnings_source_v1, v_edgar_source_v1)
    ),
    'estimate_update_blocked', false,
    'reconciliation_update_blocked', false,
    'reconciliation_truncate_blocked', false
  );

  BEGIN
    UPDATE earnings_estimate_observation
       SET source_lineage = v_lineage || '{"tamper":"direct-update"}'::jsonb
     WHERE estimate_id = v_estimate.estimate_id;
    RAISE EXCEPTION 'probe corrupted: earnings estimate was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('estimate_update_blocked', true);
  END;

  BEGIN
    UPDATE earnings_actual_reconciliation
       SET source_lineage = v_lineage || '{"tamper":"direct-update"}'::jsonb
     WHERE reconciliation_id = v_reconciliation.reconciliation_id;
    RAISE EXCEPTION 'probe corrupted: reconciliation was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('reconciliation_update_blocked', true);
  END;

  BEGIN
    TRUNCATE earnings_actual_reconciliation;
    RAISE EXCEPTION 'probe corrupted: reconciliation evidence was truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('reconciliation_truncate_blocked', true);
  END;

  INSERT INTO wu14_probe_result (result) VALUES (v_results);
END
$probe$;
