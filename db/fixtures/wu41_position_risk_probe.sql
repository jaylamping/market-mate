-- WU-41 Position Risk model probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu41_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu41-probe","entitlement_version":"position-risk-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_source_id uuid := '41000000-0000-0000-0000-000000000001';
  v_source_v uuid := '41000000-0000-0000-0000-000000000101';
  v_ent_id uuid := '41000000-0000-0000-0000-000000000201';
  v_ent_v uuid := '41000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '41000000-0000-0000-0000-000000000501';
  v_contract_v uuid := '41000000-0000-0000-0000-000000000502';
  v_snapshot_field uuid := '41000000-0000-0000-0000-000000000601';
  v_available_field uuid := '41000000-0000-0000-0000-000000000602';
  v_received_field uuid := '41000000-0000-0000-0000-000000000603';
  v_deliverable_field uuid := '41000000-0000-0000-0000-000000000604';
  v_connector_id uuid := '41000000-0000-0000-0000-000000000701';
  v_issuer_id uuid := '41000000-0000-0000-0000-000000000401';
  v_security_id uuid := '41000000-0000-0000-0000-000000000402';
  v_mapping instrument_mapping%ROWTYPE;
  v_snapshot option_chain_snapshot%ROWTYPE;
  v_c100 option_chain_contract%ROWTYPE;
  v_c105 option_chain_contract%ROWTYPE;
  v_p100 option_chain_contract%ROWTYPE;
  v_p095 option_chain_contract%ROWTYPE;
  v_cexp option_chain_contract%ROWTYPE;
  v_cutil option_chain_contract%ROWTYPE;
  v_terms jsonb := '{"quantity":100,"multiplier":100,"settlement":"physical","currency":"USD"}';
  v_fee jsonb;
  v_risk jsonb;
  v_long jsonb;
  v_vertical jsonb;
  v_credit jsonb;
  v_expensive jsonb;
  v_util jsonb;
  v_assess_long capital_feasibility_assessment%ROWTYPE;
  v_assess_vert capital_feasibility_assessment%ROWTYPE;
  v_assess_exp capital_feasibility_assessment%ROWTYPE;
  v_assess_util capital_feasibility_assessment%ROWTYPE;
  v_assess_credit capital_feasibility_assessment%ROWTYPE;
  v_model position_risk_model%ROWTYPE;
  v_again position_risk_model%ROWTYPE;
  v_vert_model position_risk_model%ROWTYPE;
  v_exp_model position_risk_model%ROWTYPE;
  v_util_model position_risk_model%ROWTYPE;
  v_credit_model position_risk_model%ROWTYPE;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'wu41-historical-options', 'WU-41 Historical Options', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v, v_source_id, 1, 'active',
    '{"name":"WU-41 Licensed Terms","version":"2026.1"}',
    '{"purposes":["local_research"]}',
    '{"required_fields":["snapshot_at","available_at","received_at"]}',
    ARRAY['current','stale','missing','incomplete'],
    ARRAY['factual_correction','retraction','source_unavailability'],
    '2020-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_ent_id, 'wu41-options-entitlement', 'local-research-account',
    'WU-41 historical options', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_ent_v, v_ent_id, 1, v_source_v, 'certified',
    ARRAY['local_research'], '2020-01-01T00:00:00Z', NULL,
    '{"authority":"principal-approved-research-plan","certificate":"wu41-opt"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'wu41-options-contract', 'market',
    'WU-41 historical options contract', v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_version (
    contract_version_id, contract_id, contract_version, source_registry_version_id,
    effective_from, effective_to, availability_time_rules,
    instrument_identity_rules, provenance_requirements,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_v, v_contract_id, 1, v_source_v,
    '2020-01-01T00:00:00Z', NULL,
    '{"as_of_required":true,"receipt_time_required":true,"availability_time_required":true,"data_mode":"historical"}',
    '{"security_id_required":true,"mapping_must_be_certified":true}',
    '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
    v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_field (
    field_id, contract_version_id, field_key, value_type,
    observation_states, field_semantics, source_lineage, receipt_time, record_environment
  ) VALUES
    (v_snapshot_field, v_contract_v, 'snapshot_at', 'timestamp', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research'),
    (v_available_field, v_contract_v, 'available_at', 'timestamp', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research'),
    (v_received_field, v_contract_v, 'received_at', 'timestamp', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research'),
    (v_deliverable_field, v_contract_v, 'deliverable_version', 'json', ARRAY['current'], '{}'::jsonb, v_lineage, now(), 'local_research');
  INSERT INTO source_connector (
    connector_id, connector_key, connector_kind,
    source_registry_version_id, contract_version_id, lifecycle,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_connector_id, 'wu41-options-connector', 'historical_options',
    v_source_v, v_contract_v, 'active', v_lineage, now(), 'local_research'
  );
  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id,
    source_lineage, receipt_time, record_environment
  ) VALUES
    (v_connector_id, v_contract_v, v_snapshot_field, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v, v_available_field, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v, v_received_field, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v, v_deliverable_field, v_lineage, now(), 'local_research');

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  INSERT INTO issuer (
    issuer_id, legal_name, source_lineage, receipt_time, record_environment
  ) VALUES (
    v_issuer_id, 'WU-41 Position Risk Holdings, Inc.', v_lineage,
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
    'wu41-options', 'WU41', 'security',
    NULL, v_security_id, NULL, '2020-01-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent identity check', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-41 chain certification', v_lineage
  );

  SELECT * INTO v_snapshot FROM record_historical_option_chain_snapshot(
    v_mapping.mapping_id, v_source_v, v_ent_v, 'historical',
    '2026-01-16T21:00:00Z', '2026-01-16T22:00:00Z',
    '{"snapshot_date":"2026-01-16","underlying":"WU41"}'::jsonb, v_lineage
  );
  SELECT * INTO v_c100 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU41-2026C100', '2026-06-19',
    'call', 100, v_terms, '{"contract":"WU41-2026C100","bid":1.40,"ask":1.50}'::jsonb, v_lineage
  );
  SELECT * INTO v_c105 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU41-2026C105', '2026-06-19',
    'call', 105, v_terms, '{"contract":"WU41-2026C105","bid":0.80,"ask":0.90}'::jsonb, v_lineage
  );
  SELECT * INTO v_p100 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU41-2026P100', '2026-06-19',
    'put', 100, v_terms, '{"contract":"WU41-2026P100","bid":2.00,"ask":2.10}'::jsonb, v_lineage
  );
  SELECT * INTO v_p095 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU41-2026P095', '2026-06-19',
    'put', 95, v_terms, '{"contract":"WU41-2026P095","bid":0.80,"ask":0.90}'::jsonb, v_lineage
  );
  SELECT * INTO v_cexp FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU41-2026CEXP', '2026-06-19',
    'call', 80, v_terms, '{"contract":"WU41-2026CEXP","bid":19.00,"ask":20.00}'::jsonb, v_lineage
  );
  SELECT * INTO v_cutil FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU41-2026CUTIL', '2026-06-19',
    'call', 90, v_terms, '{"contract":"WU41-2026CUTIL","bid":7.40,"ask":7.50}'::jsonb, v_lineage
  );

  v_fee := jsonb_build_object(
    'schedule_key', 'wu41-ibkr-defined-risk',
    'commission_cents_per_contract', 65,
    'exchange_fee_cents_per_contract', 10,
    'regulatory_fee_cents_per_contract', 5
  );
  v_risk := jsonb_build_object(
    'schedule_key', 'wu41-conservative-slippage',
    'entry_slippage_bps', 50,
    'exit_slippage_bps', 50,
    'assignment_fee_cents_per_contract', 50
  );
  v_long := jsonb_build_object(
    'structure_key', 'wu41-long-call',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_c100.contract_id, 'side', 'buy')
    )
  );
  v_vertical := jsonb_build_object(
    'structure_key', 'wu41-debit-call-vertical',
    'structure_kind', 'debit_call_vertical',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_c100.contract_id, 'side', 'buy'),
      jsonb_build_object('contract_id', v_c105.contract_id, 'side', 'sell')
    )
  );
  v_credit := jsonb_build_object(
    'structure_key', 'wu41-credit-put-vertical',
    'structure_kind', 'credit_put_vertical',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_p100.contract_id, 'side', 'sell'),
      jsonb_build_object('contract_id', v_p095.contract_id, 'side', 'buy')
    )
  );
  v_expensive := jsonb_build_object(
    'structure_key', 'wu41-expensive-long',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_cexp.contract_id, 'side', 'buy')
    )
  );
  v_util := jsonb_build_object(
    'structure_key', 'wu41-utilization-long',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_cutil.contract_id, 'side', 'buy')
    )
  );

  SELECT * INTO v_assess_long FROM record_capital_feasibility_assessment(
    v_long, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  SELECT * INTO v_assess_vert FROM record_capital_feasibility_assessment(
    v_vertical, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  SELECT * INTO v_assess_exp FROM record_capital_feasibility_assessment(
    v_expensive, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  SELECT * INTO v_assess_util FROM record_capital_feasibility_assessment(
    v_util, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  SELECT * INTO v_assess_credit FROM record_capital_feasibility_assessment(
    v_credit, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);

  SELECT * INTO v_model FROM record_position_risk_model(
    v_assess_long.assessment_id, v_risk, v_lineage);
  SELECT * INTO v_again FROM record_position_risk_model(
    v_assess_long.assessment_id, v_risk, v_lineage);
  SELECT * INTO v_vert_model FROM record_position_risk_model(
    v_assess_vert.assessment_id, v_risk, v_lineage);
  SELECT * INTO v_exp_model FROM record_position_risk_model(
    v_assess_exp.assessment_id, v_risk, v_lineage);
  SELECT * INTO v_util_model FROM record_position_risk_model(
    v_assess_util.assessment_id, v_risk, v_lineage);
  SELECT * INTO v_credit_model FROM record_position_risk_model(
    v_assess_credit.assessment_id, v_risk, v_lineage);

  v_results := jsonb_build_object(
    'slippage_applied',
      (v_model.result->>'entry_slippage_cents')::bigint = 75
      AND (v_model.result->>'exit_slippage_cents')::bigint = 75
      AND (v_model.result->>'position_risk_cents')::bigint = 15310
      AND (v_model.result->>'position_risk_cents')::bigint
          >= (v_assess_long.result->>'collateral_cents')::bigint,
    'assignment_exposure_recorded',
      (v_model.result->>'assignment_exposure_cents')::bigint = 0
      AND (v_vert_model.result->>'assignment_exposure_cents')::bigint = 1050000
      AND (v_credit_model.result->>'assignment_exposure_cents')::bigint = 1000000,
    'admitted_within_floors',
      v_model.admitted = true
      AND v_model.rejection_reason IS NULL
      AND (v_model.result->>'utilization_ceiling_cents')::bigint = 75000
      AND (v_model.result->>'bankroll_cents')::bigint = 100000,
    'assignment_rejects_short_leg',
      v_vert_model.admitted = false
      AND v_vert_model.rejection_reason = 'assignment_exposure_exceeds_bankroll'
      AND v_credit_model.admitted = false
      AND v_credit_model.rejection_reason = 'assignment_exposure_exceeds_bankroll',
    'bankroll_floor_holds',
      v_exp_model.admitted = false
      AND v_exp_model.rejection_reason = 'position_risk_exceeds_bankroll',
    'utilization_floor_holds',
      v_util_model.admitted = false
      AND v_util_model.rejection_reason = 'position_risk_exceeds_utilization_ceiling'
      AND (v_util_model.result->>'position_risk_cents')::bigint > 75000
      AND (v_util_model.result->>'position_risk_cents')::bigint <= 100000,
    'record_is_idempotent',
      v_again.model_id = v_model.model_id
      AND (SELECT count(*) FROM position_risk_model
           WHERE assessment_id = v_assess_long.assessment_id) = 1
  );

  BEGIN
    PERFORM record_position_risk_model(
      v_assess_long.assessment_id,
      jsonb_build_object(
        'schedule_key', 'wu41-missing-slippage',
        'exit_slippage_bps', 50,
        'assignment_fee_cents_per_contract', 50
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: missing slippage was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%position risk schedule is missing required inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_slippage_blocked', true);
  END;

  BEGIN
    PERFORM record_position_risk_model(NULL, v_risk, v_lineage);
    RAISE EXCEPTION 'probe corrupted: missing assessment was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%position risk assessment is missing%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_assessment_blocked', true);
  END;

  BEGIN
    INSERT INTO position_risk_model (
      assessment_id, schedule_id, result, result_digest, admitted,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_model.assessment_id, v_model.schedule_id, v_model.result,
      v_model.result_digest, v_model.admitted,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct position_risk INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the position risk workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE position_risk_model SET admitted = false WHERE model_id = v_model.model_id;
    RAISE EXCEPTION 'probe corrupted: position risk model was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('model_update_blocked', true);
  END;

  BEGIN
    DELETE FROM position_risk_model WHERE model_id = v_model.model_id;
    RAISE EXCEPTION 'probe corrupted: position risk model was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('model_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE position_risk_model, position_risk_schedule;
    RAISE EXCEPTION 'probe corrupted: position risk model was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('model_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'model_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.position_risk_modeled'
        AND payload->>'result_digest' = v_model.result_digest
    ),
    'no_authority_grant',
      v_model.record_environment = 'local_research'
      AND (SELECT bool_and(record_environment = 'local_research')
           FROM position_risk_model)
  );

  INSERT INTO wu41_probe_result (result) VALUES (v_results);
END
$probe$;
