-- WU-13 licensed EOD and corporate-actions connector probe. Run inside a
-- caller-managed transaction; all fixture evidence is rolled back by the
-- acceptance script.

CREATE TEMP TABLE wu13_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '40000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '40000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '40000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '40000000-0000-0000-0000-000000000301';
  v_uncertified_entitlement_id uuid := '40000000-0000-0000-0000-000000000202';
  v_uncertified_entitlement_v1 uuid := '40000000-0000-0000-0000-000000000302';
  v_issuer_id uuid := '40000000-0000-0000-0000-000000000401';
  v_security_id uuid := '40000000-0000-0000-0000-000000000402';
  v_mapping instrument_mapping%ROWTYPE;
  v_selection eod_vendor_selection%ROWTYPE;
  v_uncertified_selection eod_vendor_selection%ROWTYPE;
  v_first_bar eod_price_observation%ROWTYPE;
  v_revised_bar eod_price_observation%ROWTYPE;
  v_missing_bar eod_price_observation%ROWTYPE;
  v_denied_bar eod_price_observation%ROWTYPE;
  v_historical_bar eod_price_observation%ROWTYPE;
  v_first_action eod_corporate_action_observation%ROWTYPE;
  v_revised_action eod_corporate_action_observation%ROWTYPE;
  v_lineage jsonb := '{"source":"wu13-probe","entitlement_version":"licensed-eod-v1"}';
  v_results jsonb;
BEGIN
  PERFORM set_config('market_mate.security_master_write', 'on', true);
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-wu13', 'Licensed EOD WU-13 Provider', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Licensed EOD WU-13 Terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["vendor_observation_key","available_at","received_at"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','source_unavailability','provenance_dispute'],
    '2026-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_entitlement_id, 'licensed-eod-wu13-entitlement', 'local-research-account',
    'Licensed daily EOD and corporate-actions access', v_lineage,
    '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_uncertified_entitlement_id, 'unlicensed-eod-wu13-entitlement', 'local-research-account',
    'Pending daily EOD access', v_lineage,
    '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_entitlement_v1, v_entitlement_id, 1, v_source_v1, 'certified',
    ARRAY['local_research','paper_validation'],
    '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-eod-wu13-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_uncertified_entitlement_v1, v_uncertified_entitlement_id, 1, v_source_v1, 'uncertified',
    ARRAY['local_research'],
    '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"pending","certificate":"not-issued"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO issuer (
    issuer_id, legal_name, source_lineage, receipt_time, record_environment
  ) VALUES (
    v_issuer_id, 'WU-13 EOD Holdings, Inc.', v_lineage,
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

  SELECT * INTO v_mapping FROM propose_instrument_mapping(
    'licensed-eod-wu13', 'WU13', 'security',
    NULL, v_security_id, NULL, '2026-01-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-13 connector certification fixture', v_lineage
  );

  SELECT * INTO v_selection FROM record_eod_vendor_selection(
    'licensed-eod-provider-wu13', v_source_v1, v_entitlement_v1,
    '{"selected":"licensed-eod-provider-wu13","candidates":[{"vendor":"licensed-eod-provider-wu13","license":"written research license","entitlement":"daily historical OHLCV and corporate actions","monthly_cost_usd":0},{"vendor":"alternative-eod-provider","license":"review required","entitlement":"daily OHLCV only","monthly_cost_usd":25}]}'::jsonb,
    '{"status":"written_license","raw_retention":"permitted","derived_use":"permitted"}'::jsonb,
    '{"status":"certified","history_years":10,"purposes":["local_research","paper_validation"]}'::jsonb,
    '{"monthly_cost_usd":0,"annual_budget_usd":0,"within_stage_cap":true}'::jsonb,
    'selected after license, entitlement, coverage, and cost comparison', v_lineage
  );
  SELECT * INTO v_uncertified_selection FROM record_eod_vendor_selection(
    'wu13-unlicensed-provider', v_source_v1, v_uncertified_entitlement_v1,
    '{"selected":"wu13-unlicensed-provider","candidates":[]}'::jsonb,
    '{"status":"pending"}'::jsonb,
    '{"status":"uncertified"}'::jsonb,
    '{"monthly_cost_usd":0,"within_stage_cap":true}'::jsonb,
    'negative gate fixture only; not eligible for production evidence', v_lineage
  );

  SELECT * INTO v_first_bar FROM ingest_eod_price_observation(
    v_selection.selection_id, v_mapping.mapping_id, 'WU13-2026-08-20',
    '2026-08-20', 'complete', 100, 105, 99, 102, 1000000,
    '2026-08-20T21:00:00Z', '{"open":100,"high":105,"low":99,"close":102,"volume":1000000}'::jsonb,
    v_lineage
  );
  SELECT * INTO v_historical_bar FROM eod_price_observation_at(
    v_mapping.mapping_id, '2026-08-20', v_first_bar.receipt_time
  );
  SELECT * INTO v_revised_bar FROM ingest_eod_price_observation(
    v_selection.selection_id, v_mapping.mapping_id, 'WU13-2026-08-20',
    '2026-08-20', 'revised', 100, 106, 99, 103, 1100000,
    '2026-08-20T21:00:00Z', '{"open":100,"high":106,"low":99,"close":103,"volume":1100000,"revision":"vendor-correction"}'::jsonb,
    v_lineage
  );
  SELECT * INTO v_missing_bar FROM ingest_eod_price_observation(
    v_selection.selection_id, v_mapping.mapping_id, 'WU13-2026-08-21',
    '2026-08-21', 'missing', NULL, NULL, NULL, NULL, NULL,
    '2026-08-22T21:00:00Z', '{"status":"missing","reason":"vendor_gap"}'::jsonb,
    v_lineage
  );

  SELECT * INTO v_first_action FROM ingest_eod_corporate_action(
    v_selection.selection_id, v_mapping.mapping_id, 'WU13-CA-0001',
    'stock_split', 'announced', '2026-09-01T00:00:00Z',
    '{"ratio":"2-for-1","ex_date":"2026-09-01"}'::jsonb,
    '{"event":"WU13-CA-0001","ratio":"2-for-1"}'::jsonb, v_lineage
  );
  SELECT * INTO v_revised_action FROM ingest_eod_corporate_action(
    v_selection.selection_id, v_mapping.mapping_id, 'WU13-CA-0001',
    'stock_split', 'terms_pending', '2026-09-01T00:00:00Z',
    '{"ratio":"2-for-1","ex_date":"2026-09-01","fractional_handling":"cash_in_lieu"}'::jsonb,
    '{"event":"WU13-CA-0001","ratio":"2-for-1","revision":"vendor-correction"}'::jsonb, v_lineage
  );

  SELECT * INTO v_denied_bar FROM ingest_eod_price_observation(
    v_uncertified_selection.selection_id, v_mapping.mapping_id, 'WU13-denied-bar',
    '2026-08-22', 'complete', 100, 101, 99, 100, 1000,
    '2026-08-22T21:00:00Z', '{"open":100,"high":101,"low":99,"close":100,"volume":1000}'::jsonb,
    v_lineage
  );

  v_results := jsonb_build_object(
    'vendor_selection_recorded', (
      SELECT selection_state = 'selected'
        AND license_criteria ->> 'status' = 'written_license'
        AND entitlement_criteria ->> 'status' = 'certified'
        AND (cost_criteria ->> 'within_stage_cap')::boolean
      FROM eod_vendor_selection WHERE selection_id = v_selection.selection_id
    ),
    'daily_bar_ingested', v_first_bar.observation_id IS NOT NULL,
    'missing_observation_ingested', v_missing_bar.observation_id IS NOT NULL
      AND v_missing_bar.observation_status = 'missing'
      AND v_missing_bar.close_price IS NULL,
    'revision_appended', (
      SELECT count(*) = 2 AND min(revision) = 1 AND max(revision) = 2
      FROM eod_price_observation
      WHERE vendor_observation_key = 'WU13-2026-08-20'
    ),
    'point_in_time_preserved', v_historical_bar.close_price = 102
      AND v_revised_bar.close_price = 103
      AND v_revised_bar.revision = 2,
    'corporate_action_ingested', v_first_action.observation_id IS NOT NULL,
    'corporate_action_revision_appended', (
      SELECT count(*) = 2 AND min(revision) = 1 AND max(revision) = 2
        AND count(DISTINCT case_id) = 1
      FROM eod_corporate_action_observation
      WHERE vendor_observation_key = 'WU13-CA-0001'
    ),
    'corporate_action_terms_revised', (
      SELECT count(*) = 2
        AND (SELECT terms ->> 'fractional_handling'
             FROM corporate_action_terms_version
             WHERE terms_id = v_revised_action.terms_id) = 'cash_in_lieu'
      FROM corporate_action_terms_version
      WHERE case_id = v_revised_action.case_id
    ),
    'entitlement_gate_allowed', (
      SELECT decision = 'allowed'
      FROM entitlement_gate_decision
      WHERE request_key LIKE 'wu13-eod:licensed-eod-provider-wu13:WU13-2026-08-20:%'
      ORDER BY requested_at LIMIT 1
    ),
    'allowed_use_receipts_recorded', (
      SELECT count(*) = 5
      FROM entitled_use_receipt r
      JOIN entitlement_gate_decision d ON d.decision_id = r.decision_id
      WHERE d.source_registry_version_id = v_source_v1
        AND d.entitlement_version_id = v_entitlement_v1
    ),
    'denied_use_has_no_observation', v_denied_bar.observation_id IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM eod_price_observation
        WHERE vendor_observation_key = 'WU13-denied-bar'
      ),
    'denial_recorded', (
      SELECT decision = 'denied' AND denial_reason = 'not_certified'
      FROM entitlement_gate_decision
      WHERE request_key LIKE 'wu13-eod:wu13-unlicensed-provider:WU13-denied-bar:%'
    ),
    'price_source_lineage_attached', v_revised_bar.source_lineage = v_lineage,
    'corporate_action_source_lineage_attached', v_revised_action.source_lineage = v_lineage,
    'price_update_blocked', false,
    'corporate_action_update_blocked', false,
    'price_truncate_blocked', false
  );

  BEGIN
    UPDATE eod_price_observation
       SET source_lineage = v_lineage || '{"tamper":"direct-update"}'::jsonb
     WHERE observation_id = v_first_bar.observation_id;
    RAISE EXCEPTION 'probe corrupted: EOD observation was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('price_update_blocked', true);
  END;

  BEGIN
    UPDATE eod_corporate_action_observation
       SET source_lineage = v_lineage || '{"tamper":"direct-update"}'::jsonb
     WHERE observation_id = v_first_action.observation_id;
    RAISE EXCEPTION 'probe corrupted: corporate-action observation was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('corporate_action_update_blocked', true);
  END;

  BEGIN
    TRUNCATE eod_price_observation;
    RAISE EXCEPTION 'probe corrupted: EOD observations were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('price_truncate_blocked', true);
  END;

  INSERT INTO wu13_probe_result (result) VALUES (v_results);
END
$probe$;
