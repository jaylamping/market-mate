-- WU-15 historical options-chain connector probe. Run inside a
-- caller-managed transaction; the acceptance script rolls fixture data back.

CREATE TEMP TABLE wu15_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '60000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '60000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '60000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '60000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '60000000-0000-0000-0000-000000000501';
  v_contract_v1 uuid := '60000000-0000-0000-0000-000000000502';
  v_snapshot_field uuid := '60000000-0000-0000-0000-000000000601';
  v_available_field uuid := '60000000-0000-0000-0000-000000000602';
  v_received_field uuid := '60000000-0000-0000-0000-000000000603';
  v_deliverable_field uuid := '60000000-0000-0000-0000-000000000604';
  v_connector_id uuid := '60000000-0000-0000-0000-000000000701';
  v_issuer_id uuid := '60000000-0000-0000-0000-000000000401';
  v_security_id uuid := '60000000-0000-0000-0000-000000000402';
  v_mapping instrument_mapping%ROWTYPE;
  v_first_snapshot option_chain_snapshot%ROWTYPE;
  v_second_snapshot option_chain_snapshot%ROWTYPE;
  v_realtime_snapshot option_chain_snapshot%ROWTYPE;
  v_first_contract option_chain_contract%ROWTYPE;
  v_second_contract option_chain_contract%ROWTYPE;
  v_first_deliverable option_deliverable_version%ROWTYPE;
  v_lineage jsonb := '{"source":"wu15-probe","entitlement_version":"historical-options-v1"}';
  v_results jsonb;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'historical-options-wu15', 'Historical Options WU-15 Provider', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Historical Options WU-15 Terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["snapshot_at","available_at","received_at","deliverable_version"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','source_unavailability','provenance_dispute'],
    '2020-01-01T00:00:00Z', NULL,
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_id, 'historical-options-wu15-entitlement', 'local-research-account',
    'Historical options-chain snapshots only', v_lineage,
    '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_v1, v_entitlement_id, 1, v_source_v1, 'certified',
    ARRAY['local_research','paper_validation'],
    '2020-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"principal-approved-paper-plan","certificate":"historical-options-wu15-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'historical-options-contract-wu15', 'market',
    'Historical options chain and immutable deliverable contract',
    v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_version (
    contract_version_id, contract_id, contract_version, source_registry_version_id,
    effective_from, effective_to, availability_time_rules,
    instrument_identity_rules, provenance_requirements,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_v1, v_contract_id, 1, v_source_v1,
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
    (v_snapshot_field, v_contract_v1, 'snapshot_at', 'timestamp', ARRAY['current','stale','missing'], '{"required":true,"point_in_time":true}'::jsonb, v_lineage, now(), 'local_research'),
    (v_available_field, v_contract_v1, 'available_at', 'timestamp', ARRAY['current','stale','missing'], '{"required":true,"point_in_time":true}'::jsonb, v_lineage, now(), 'local_research'),
    (v_received_field, v_contract_v1, 'received_at', 'timestamp', ARRAY['current'], '{"required":true}'::jsonb, v_lineage, now(), 'local_research'),
    (v_deliverable_field, v_contract_v1, 'deliverable_version', 'json', ARRAY['current','stale','missing'], '{"required":true,"immutable":true}'::jsonb, v_lineage, now(), 'local_research');
  INSERT INTO source_connector (
    connector_id, connector_key, connector_kind,
    source_registry_version_id, contract_version_id, lifecycle,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_connector_id, 'historical-options-connector-wu15', 'historical_options', v_source_v1, v_contract_v1,
    'active', v_lineage, now(), 'local_research'
  );
  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id,
    source_lineage, receipt_time, record_environment
  ) VALUES
    (v_connector_id, v_contract_v1, v_snapshot_field, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_available_field, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_received_field, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_deliverable_field, v_lineage, now(), 'local_research');

  PERFORM set_config('market_mate.security_master_write', 'on', true);
  INSERT INTO issuer (
    issuer_id, legal_name, source_lineage, receipt_time, record_environment
  ) VALUES (
    v_issuer_id, 'WU-15 Options Holdings, Inc.', v_lineage,
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
    'historical-options-wu15', 'WU15', 'security',
    NULL, v_security_id, NULL, '2020-01-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent underlying identity check', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-15 historical chain certification fixture', v_lineage
  );

  SELECT * INTO v_first_snapshot FROM record_historical_option_chain_snapshot(
    v_mapping.mapping_id, v_source_v1, v_entitlement_v1, 'historical',
    '2024-01-19T21:00:00Z', '2024-01-19T22:00:00Z',
    '{"snapshot_date":"2024-01-19","underlying":"WU15"}'::jsonb, v_lineage
  );
  SELECT * INTO v_first_contract FROM append_option_chain_contract(
    v_first_snapshot.snapshot_id, 'WU15-2026C100', '2026-01-16',
    'call', 100, '{"underlying":"WU15","quantity":100,"multiplier":100,"settlement":"physical","currency":"USD"}'::jsonb,
    '{"contract":"WU15-2026C100","bid":4.10,"ask":4.25}'::jsonb, v_lineage
  );
  SELECT * INTO v_first_deliverable FROM option_deliverable_version
  WHERE deliverable_version_id = v_first_contract.deliverable_version_id;

  SELECT * INTO v_second_snapshot FROM record_historical_option_chain_snapshot(
    v_mapping.mapping_id, v_source_v1, v_entitlement_v1, 'historical',
    '2025-01-17T21:00:00Z', '2025-01-17T22:00:00Z',
    '{"snapshot_date":"2025-01-17","underlying":"WU15"}'::jsonb, v_lineage
  );
  SELECT * INTO v_second_contract FROM append_option_chain_contract(
    v_second_snapshot.snapshot_id, 'WU15-2027P090', '2027-01-15',
    'put', 90, '{"underlying":"WU15","quantity":100,"multiplier":100,"settlement":"physical","currency":"USD"}'::jsonb,
    '{"contract":"WU15-2027P090","bid":3.05,"ask":3.20}'::jsonb, v_lineage
  );

  BEGIN
    SELECT * INTO v_realtime_snapshot FROM record_historical_option_chain_snapshot(
      v_mapping.mapping_id, v_source_v1, v_entitlement_v1, 'real_time',
      '2026-08-29T20:00:00Z', '2026-08-29T20:00:01Z',
      '{"snapshot_date":"2026-08-29","underlying":"WU15"}'::jsonb, v_lineage
    );
    RAISE EXCEPTION 'probe corrupted: real-time options entitlement was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'real-time options entitlements are deferred%' THEN RAISE; END IF;
      v_results := jsonb_build_object('realtime_rejected', true);
  END;

  v_results := coalesce(v_results, '{}'::jsonb) || jsonb_build_object(
    'snapshot_dates_preserved', (
      SELECT count(*) = 2 AND min(snapshot_at) = '2024-01-19T21:00:00Z'
        AND max(snapshot_at) = '2025-01-17T21:00:00Z'
      FROM option_chain_snapshot
    ),
    'historical_mode_only', (
      SELECT bool_and(data_mode = 'historical') FROM option_chain_snapshot
    ),
    'point_in_time_provenance_preserved', v_first_snapshot.snapshot_at IS NOT NULL
      AND v_first_snapshot.available_at IS NOT NULL
      AND v_first_snapshot.receipt_time IS NOT NULL,
    'connector_contract_bound', v_first_snapshot.connector_id = v_connector_id
      AND v_first_snapshot.contract_version_id = v_contract_v1
      AND v_first_contract.connector_id = v_connector_id
      AND v_first_deliverable.contract_version_id = v_contract_v1,
    'certified_mapping_attached', (
      SELECT m.lifecycle = 'certified' AND s.security_id = v_security_id
      FROM option_chain_snapshot o
      JOIN instrument_mapping m ON m.mapping_id = o.instrument_mapping_id
      JOIN security s ON s.security_id = o.underlying_security_id
      WHERE o.snapshot_id = v_first_snapshot.snapshot_id
    ),
    'contracts_mapped_to_snapshots', (
      SELECT count(*) = 2 AND count(DISTINCT snapshot_id) = 2
      FROM option_chain_contract
    ),
    'deliverable_semantics_attached', v_first_deliverable.underlying_quantity = 100
      AND v_first_deliverable.multiplier = 100
      AND v_first_deliverable.settlement_method = 'physical'
      AND v_first_deliverable.terms ->> 'currency' = 'USD',
    'entitlement_gate_allowed', (
      SELECT bool_and(decision = 'allowed')
      FROM entitlement_gate_decision
      WHERE request_key LIKE 'wu15-options:%'
    ),
    'historical_use_receipts_recorded', (
      SELECT count(*) = 4
      FROM entitled_use_receipt r
      JOIN entitlement_gate_decision d ON d.decision_id = r.decision_id
      WHERE d.source_registry_version_id = v_source_v1
        AND d.entitlement_version_id = v_entitlement_v1
    ),
    'snapshot_source_lineage_attached', v_first_snapshot.source_lineage = v_lineage,
    'contract_source_lineage_attached', v_first_contract.source_lineage = v_lineage,
    'snapshot_update_blocked', false,
    'deliverable_update_blocked', false,
    'contract_truncate_blocked', false
  );

  BEGIN
    UPDATE option_chain_snapshot
       SET source_lineage = v_lineage || '{"tamper":"direct-update"}'::jsonb
     WHERE snapshot_id = v_first_snapshot.snapshot_id;
    RAISE EXCEPTION 'probe corrupted: option snapshot was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('snapshot_update_blocked', true);
  END;

  BEGIN
    UPDATE option_deliverable_version
       SET source_lineage = v_lineage || '{"tamper":"direct-update"}'::jsonb
     WHERE deliverable_version_id = v_first_contract.deliverable_version_id;
    RAISE EXCEPTION 'probe corrupted: option deliverable was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('deliverable_update_blocked', true);
  END;

  BEGIN
    TRUNCATE option_chain_contract;
    RAISE EXCEPTION 'probe corrupted: option contracts were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('contract_truncate_blocked', true);
  END;

  INSERT INTO wu15_probe_result (result) VALUES (v_results);
END
$probe$;
