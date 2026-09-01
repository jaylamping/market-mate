-- WU-40 Capital Feasibility Assessor probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu40_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu40-probe","entitlement_version":"feasibility-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_source_id uuid := '40000000-0000-0000-0000-000000000001';
  v_source_v uuid := '40000000-0000-0000-0000-000000000101';
  v_ent_id uuid := '40000000-0000-0000-0000-000000000201';
  v_ent_v uuid := '40000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '40000000-0000-0000-0000-000000000501';
  v_contract_v uuid := '40000000-0000-0000-0000-000000000502';
  v_snapshot_field uuid := '40000000-0000-0000-0000-000000000601';
  v_available_field uuid := '40000000-0000-0000-0000-000000000602';
  v_received_field uuid := '40000000-0000-0000-0000-000000000603';
  v_deliverable_field uuid := '40000000-0000-0000-0000-000000000604';
  v_connector_id uuid := '40000000-0000-0000-0000-000000000701';
  v_issuer_id uuid := '40000000-0000-0000-0000-000000000401';
  v_security_id uuid := '40000000-0000-0000-0000-000000000402';
  v_mapping instrument_mapping%ROWTYPE;
  v_uncert instrument_mapping%ROWTYPE;
  v_snapshot option_chain_snapshot%ROWTYPE;
  v_c100 option_chain_contract%ROWTYPE;
  v_c105 option_chain_contract%ROWTYPE;
  v_p100 option_chain_contract%ROWTYPE;
  v_p095 option_chain_contract%ROWTYPE;
  v_cexp option_chain_contract%ROWTYPE;
  v_cnoq option_chain_contract%ROWTYPE;
  v_cfrac option_chain_contract%ROWTYPE;
  v_terms jsonb := '{"quantity":100,"multiplier":100,"settlement":"physical","currency":"USD"}';
  v_fee jsonb;
  v_long jsonb;
  v_vertical jsonb;
  v_credit jsonb;
  v_expensive jsonb;
  v_naked jsonb;
  v_noq jsonb;
  v_fit capital_feasibility_assessment%ROWTYPE;
  v_again capital_feasibility_assessment%ROWTYPE;
  v_miss capital_feasibility_assessment%ROWTYPE;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'wu40-historical-options', 'WU-40 Historical Options', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v, v_source_id, 1, 'active',
    '{"name":"WU-40 Licensed Terms","version":"2026.1"}',
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
    v_ent_id, 'wu40-options-entitlement', 'local-research-account',
    'WU-40 historical options', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_ent_v, v_ent_id, 1, v_source_v, 'certified',
    ARRAY['local_research'], '2020-01-01T00:00:00Z', NULL,
    '{"authority":"principal-approved-research-plan","certificate":"wu40-opt"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'wu40-options-contract', 'market',
    'WU-40 historical options contract', v_lineage, now(), 'local_research'
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
    v_connector_id, 'wu40-options-connector', 'historical_options',
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
    v_issuer_id, 'WU-40 Feasibility Holdings, Inc.', v_lineage,
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
    'wu40-options', 'WU40', 'security',
    NULL, v_security_id, NULL, '2020-01-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'corroborated', 'independent identity check', v_lineage
  );
  SELECT * INTO v_mapping FROM transition_instrument_mapping(
    v_mapping.mapping_id, 'certified', 'WU-40 chain certification', v_lineage
  );
  SELECT * INTO v_uncert FROM propose_instrument_mapping(
    'wu40-uncertified', 'WU40U', 'security',
    NULL, v_security_id, NULL, '2020-01-01T00:00:00Z', v_lineage
  );

  SELECT * INTO v_snapshot FROM record_historical_option_chain_snapshot(
    v_mapping.mapping_id, v_source_v, v_ent_v, 'historical',
    '2026-01-16T21:00:00Z', '2026-01-16T22:00:00Z',
    '{"snapshot_date":"2026-01-16","underlying":"WU40"}'::jsonb, v_lineage
  );
  SELECT * INTO v_c100 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026C100', '2026-06-19',
    'call', 100, v_terms, '{"contract":"WU40-2026C100","bid":1.40,"ask":1.50}'::jsonb, v_lineage
  );
  SELECT * INTO v_c105 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026C105', '2026-06-19',
    'call', 105, v_terms, '{"contract":"WU40-2026C105","bid":0.80,"ask":0.90}'::jsonb, v_lineage
  );
  SELECT * INTO v_p100 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026P100', '2026-06-19',
    'put', 100, v_terms, '{"contract":"WU40-2026P100","bid":2.00,"ask":2.10}'::jsonb, v_lineage
  );
  SELECT * INTO v_p095 FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026P095', '2026-06-19',
    'put', 95, v_terms, '{"contract":"WU40-2026P095","bid":0.80,"ask":0.90}'::jsonb, v_lineage
  );
  SELECT * INTO v_cexp FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026C200', '2026-06-19',
    'call', 80, v_terms, '{"contract":"WU40-2026C200","bid":19.00,"ask":20.00}'::jsonb, v_lineage
  );
  SELECT * INTO v_cnoq FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026CNOQ', '2026-06-19',
    'call', 110, v_terms, '{"contract":"WU40-2026CNOQ"}'::jsonb, v_lineage
  );
  SELECT * INTO v_cfrac FROM append_option_chain_contract(
    v_snapshot.snapshot_id, 'WU40-2026CFRAC', '2026-06-19',
    'call', 112,
    '{"quantity":100,"multiplier":0.4,"settlement":"physical","currency":"USD"}'::jsonb,
    '{"contract":"WU40-2026CFRAC","bid":1.00,"ask":1.10}'::jsonb, v_lineage
  );

  v_fee := jsonb_build_object(
    'schedule_key', 'wu40-ibkr-defined-risk',
    'commission_cents_per_contract', 65,
    'exchange_fee_cents_per_contract', 10,
    'regulatory_fee_cents_per_contract', 5
  );
  v_vertical := jsonb_build_object(
    'structure_key', 'wu40-debit-call-vertical',
    'structure_kind', 'debit_call_vertical',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_c100.contract_id, 'side', 'buy'),
      jsonb_build_object('contract_id', v_c105.contract_id, 'side', 'sell')
    )
  );
  SELECT * INTO v_fit FROM record_capital_feasibility_assessment(
    v_vertical, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  SELECT * INTO v_again FROM record_capital_feasibility_assessment(
    v_vertical, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);

  v_long := jsonb_build_object(
    'structure_key', 'wu40-long-call',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_c100.contract_id, 'side', 'buy')
    )
  );
  v_credit := jsonb_build_object(
    'structure_key', 'wu40-credit-put-vertical',
    'structure_kind', 'credit_put_vertical',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_p100.contract_id, 'side', 'sell'),
      jsonb_build_object('contract_id', v_p095.contract_id, 'side', 'buy')
    )
  );
  v_expensive := jsonb_build_object(
    'structure_key', 'wu40-expensive-long',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_cexp.contract_id, 'side', 'buy')
    )
  );
  SELECT * INTO v_miss FROM record_capital_feasibility_assessment(
    v_expensive, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);

  v_results := jsonb_build_object(
    'min_units_computed',
      (v_fit.result->>'min_contract_units')::bigint = 1
      AND (v_fit.result->>'bankroll_cents')::bigint = 100000,
    'collateral_computed',
      (v_fit.result->>'collateral_cents')::bigint = 7000
      AND (v_fit.result->>'premium_debit_cents')::bigint = 7000,
    'fees_computed',
      (v_fit.result->>'commission_cents')::bigint = 130
      AND (v_fit.result->>'exchange_fee_cents')::bigint = 20
      AND (v_fit.result->>'regulatory_fee_cents')::bigint = 10
      AND (v_fit.result->>'total_fee_cents')::bigint = 160,
    'approvals_recorded',
      v_fit.result->'approval_prerequisites' @> '["options_spreads"]'::jsonb
      AND v_fit.result->'approval_prerequisites' @> '["multi_leg"]'::jsonb,
    'fits_bankroll',
      (v_fit.result->>'capital_required_cents')::bigint = 7160
      AND (v_fit.result->>'fits_bankroll')::boolean = true
      AND v_fit.record_environment = 'local_research',
    'expensive_does_not_fit',
      (v_miss.result->>'fits_bankroll')::boolean = false
      AND (v_miss.result->>'capital_required_cents')::bigint > 100000,
    'record_is_idempotent',
      v_again.assessment_id = v_fit.assessment_id
      AND (SELECT count(*) FROM capital_feasibility_assessment
           WHERE structure_digest = v_fit.structure_digest) = 1
  );

  PERFORM record_capital_feasibility_assessment(
    v_long, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  PERFORM record_capital_feasibility_assessment(
    v_credit, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
  v_results := v_results || jsonb_build_object(
    'long_and_credit_assessed', (
      SELECT count(*) = 4 FROM capital_feasibility_assessment
    )
  );

  BEGIN
    PERFORM record_capital_feasibility_assessment(
      v_vertical,
      jsonb_build_object(
        'schedule_key', 'wu40-missing-commission',
        'exchange_fee_cents_per_contract', 10,
        'regulatory_fee_cents_per_contract', 5
      ),
      v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: missing fee schedule was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%fee schedule is missing required inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_fee_schedule_blocked', true);
  END;

  BEGIN
    PERFORM record_capital_feasibility_assessment(
      v_vertical, v_fee, NULL, v_mapping.mapping_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: missing chain snapshot was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%chain snapshot is missing%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_chain_snapshot_blocked', true);
  END;

  BEGIN
    PERFORM record_capital_feasibility_assessment(
      v_vertical, v_fee, v_snapshot.snapshot_id, v_uncert.mapping_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: uncertified mapping was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%identity mapping is missing or not certified%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('uncertified_mapping_blocked', true);
  END;

  v_naked := jsonb_build_object(
    'structure_key', 'wu40-naked-short',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_c105.contract_id, 'side', 'sell')
    )
  );
  BEGIN
    PERFORM record_capital_feasibility_assessment(
      v_naked, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: naked short was admitted as defined-risk';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not defined-risk%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('naked_short_blocked', true);
  END;

  v_noq := jsonb_build_object(
    'structure_key', 'wu40-no-quotes',
    'structure_kind', 'long_call',
    'legs', jsonb_build_array(
      jsonb_build_object('contract_id', v_cnoq.contract_id, 'side', 'buy')
    )
  );
  BEGIN
    PERFORM record_capital_feasibility_assessment(
      v_noq, v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: missing quotes were admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%chain snapshot is missing required contracts%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_quotes_blocked', true);
  END;

  BEGIN
    PERFORM record_capital_feasibility_assessment(
      jsonb_build_object(
        'structure_key', 'wu40-frac-mult',
        'structure_kind', 'long_call',
        'legs', jsonb_build_array(
          jsonb_build_object('contract_id', v_cfrac.contract_id, 'side', 'buy')
        )
      ),
      v_fee, v_snapshot.snapshot_id, v_mapping.mapping_id, v_lineage);
    RAISE EXCEPTION 'probe corrupted: fractional multiplier was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%chain snapshot is missing required contracts%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('fractional_multiplier_blocked', true);
  END;

  BEGIN
    INSERT INTO capital_feasibility_assessment (
      schedule_id, snapshot_id, instrument_mapping_id,
      structure, structure_digest, result, result_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_fit.schedule_id, v_fit.snapshot_id, v_fit.instrument_mapping_id,
      v_fit.structure, v_fit.structure_digest, v_fit.result, v_fit.result_digest,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct assessment INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the capital feasibility workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE capital_feasibility_assessment
       SET result = v_fit.result
     WHERE assessment_id = v_fit.assessment_id;
    RAISE EXCEPTION 'probe corrupted: assessment was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('assessment_update_blocked', true);
  END;

  BEGIN
    DELETE FROM capital_feasibility_assessment
     WHERE assessment_id = v_fit.assessment_id;
    RAISE EXCEPTION 'probe corrupted: assessment was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('assessment_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE capital_feasibility_assessment, capital_feasibility_fee_schedule;
    RAISE EXCEPTION 'probe corrupted: assessment was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('assessment_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'assessment_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.capital_feasibility_assessed'
        AND payload->>'result_digest' = v_fit.result_digest
    ),
    'no_authority_grant',
      v_fit.record_environment = 'local_research'
      AND (SELECT bool_and(record_environment = 'local_research')
           FROM capital_feasibility_assessment)
  );

  INSERT INTO wu40_probe_result (result) VALUES (v_results);
END
$probe$;
