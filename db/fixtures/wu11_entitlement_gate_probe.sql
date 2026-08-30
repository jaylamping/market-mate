-- WU-11 entitlement certification gate probe. Run inside a caller-managed
-- transaction; the fixture rows are rolled back by the acceptance script.

CREATE TEMP TABLE wu11_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '20000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '20000000-0000-0000-0000-000000000101';
  v_source_v2 uuid := '20000000-0000-0000-0000-000000000102';
  v_entitlement_id uuid := '20000000-0000-0000-0000-000000000201';
  v_expired_entitlement_id uuid := '20000000-0000-0000-0000-000000000202';
  v_entitlement_v1 uuid := '20000000-0000-0000-0000-000000000301';
  v_entitlement_v2 uuid := '20000000-0000-0000-0000-000000000302';
  v_entitlement_v3 uuid := '20000000-0000-0000-0000-000000000304';
  v_expired_entitlement_v1 uuid := '20000000-0000-0000-0000-000000000303';
  v_uncertified_decision entitlement_gate_decision%ROWTYPE;
  v_retry_decision entitlement_gate_decision%ROWTYPE;
  v_certified_decision entitlement_gate_decision%ROWTYPE;
  v_expired_decision entitlement_gate_decision%ROWTYPE;
  v_expired_allowed_decision entitlement_gate_decision%ROWTYPE;
  v_use_receipt entitled_use_receipt%ROWTYPE;
  v_lineage jsonb := '{"source":"wu11-probe","entitlement_version":"local-v1"}';
  v_expired_effective timestamptz;
  v_expired_at timestamptz;
  v_results jsonb;
BEGIN
  v_expired_effective := clock_timestamp() - interval '2 days';
  v_expired_at := clock_timestamp() - interval '1 hour';

  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-wu11-source', 'Licensed WU-11 Source', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_source_v1, v_source_id, 1, 'retired',
    '{"name":"WU-11 Licensed Terms","version":"2026.1"}',
    '{"purposes":["local_research"]}',
    '{"required_fields":["source_observation_id","received_at"]}',
    ARRAY['current','stale','missing','incomplete'],
    ARRAY['factual_correction','retraction','source_unavailability'],
    '2026-01-01T00:00:00Z', '2026-07-01T00:00:00Z',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_source_v2, v_source_id, 2, 'active',
    '{"name":"WU-11 Licensed Terms","version":"2026.2"}',
    '{"purposes":["local_research","paper_validation"]}',
    '{"required_fields":["source_observation_id","received_at","correction_id"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','rights_restriction','required_deletion','source_unavailability','provenance_dispute'],
    '2026-07-01T00:00:00Z', NULL,
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement (
    entitlement_id, entitlement_key, account_scope, plan_name,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_id, 'wu11-licensed-source-entitlement', 'paper-research-account',
    'WU-11 local certification plan', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ), (
    v_expired_entitlement_id, 'wu11-expired-source-entitlement', 'paper-research-account',
    'WU-11 expired certification regression plan', v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_entitlement_v1, v_entitlement_id, 1, v_source_v1, 'uncertified',
    ARRAY['local_research'], '2026-01-01T00:00:00Z', '2026-07-01T00:00:00Z',
    '{"authority":"pending","certificate":"not-issued"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_entitlement_v2, v_entitlement_id, 2, v_source_v2, 'certified',
    ARRAY['local_research','paper_validation'],
    '2026-07-01T00:00:00Z', NULL,
    '{"authority":"principal-approved-paper-plan","certificate":"wu11-local-cert-2026.2"}',
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  ), (
    v_expired_entitlement_v1, v_expired_entitlement_id, 1, v_source_v2, 'certified',
    ARRAY['local_research'],
    v_expired_effective, v_expired_at,
    '{"authority":"principal-approved-paper-plan","certificate":"wu11-expired-regression-cert"}',
    v_lineage, v_expired_effective, 'local_research'
  );

  INSERT INTO data_entitlement_version (
    entitlement_version_id, entitlement_id, entitlement_version,
    source_registry_version_id, certification_state, authorized_purposes,
    effective_from, expires_at, certification_basis,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_entitlement_v3, v_entitlement_id, 3, v_source_v2, 'certified',
    ARRAY['local_research','paper_validation'], '2090-01-01T00:00:00Z', NULL,
    '{"authority":"principal-approved-paper-plan","certificate":"wu11-local-cert-2090.3"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  SELECT * INTO v_uncertified_decision FROM evaluate_entitlement_gate(
    'wu11-uncertified-request', v_entitlement_v1, 'local_research',
    '2026-03-01T00:00:00Z', v_lineage
  );
  SELECT * INTO v_retry_decision FROM evaluate_entitlement_gate(
    'wu11-uncertified-request', v_entitlement_v2, 'local_research',
    clock_timestamp(), v_lineage
  );
  SELECT * INTO v_certified_decision FROM evaluate_entitlement_gate(
    'wu11-certified-request', v_entitlement_v2, 'local_research',
    '2026-07-15T00:00:00Z', v_lineage
  );
  SELECT * INTO v_use_receipt FROM record_entitled_use(
    'wu11-certified-use', v_certified_decision.decision_id,
    'market-research-consumer', v_lineage
  );
  PERFORM record_entitled_use(
    'wu11-certified-use-secondary', v_certified_decision.decision_id,
    'paper-validation-consumer', v_lineage
  );
  SELECT * INTO v_expired_decision FROM evaluate_entitlement_gate(
    'wu11-expired-request', v_expired_entitlement_v1, 'local_research',
    v_expired_at + interval '1 minute', v_lineage
  );
  SELECT * INTO v_expired_allowed_decision FROM evaluate_entitlement_gate(
    'wu11-expired-allowed-request', v_expired_entitlement_v1, 'local_research',
    v_expired_effective + interval '1 hour', v_lineage
  );

  v_results := jsonb_build_object(
    'uncertified_use_denied', v_uncertified_decision.decision = 'denied'
      AND v_uncertified_decision.denial_reason = 'not_certified',
    'uncertified_denial_recorded', (
      SELECT count(*) = 1
      FROM entitlement_gate_decision
      WHERE request_key = 'wu11-uncertified-request'
        AND decision = 'denied'
    ),
    'denied_request_retry_allowed', v_retry_decision.decision = 'allowed'
      AND v_retry_decision.request_key = v_uncertified_decision.request_key
      AND v_retry_decision.decision_attempt = 2,
    'certified_use_allowed', v_certified_decision.decision = 'allowed'
      AND v_certified_decision.denial_reason IS NULL,
    'expired_use_denied', v_expired_decision.decision = 'denied'
      AND v_expired_decision.denial_reason = 'expired',
    'certified_use_recorded', (
      SELECT count(*) = 2
      FROM entitled_use_receipt
      WHERE decision_id = v_certified_decision.decision_id
    ),
    'expired_allowed_use_denied', false,
    'entitlement_successor_closes_open_range', (
      SELECT expires_at = '2090-01-01T00:00:00Z'::timestamptz
      FROM data_entitlement_version
      WHERE entitlement_version_id = v_entitlement_v2
    ),
    'provenance_source_attached', v_use_receipt.source_registry_version_id = v_source_v2
      AND v_use_receipt.provenance ? 'source_registry_version',
    'provenance_entitlement_attached', v_use_receipt.entitlement_version_id = v_entitlement_v2
      AND v_use_receipt.provenance ? 'entitlement_version',
    'provenance_receipt_time_attached', v_use_receipt.receipt_time IS NOT NULL
      AND v_use_receipt.provenance ? 'receipt_time',
    'decision_log_append_only', false,
    'denied_use_blocked', false
  );

  BEGIN
    PERFORM record_entitled_use(
      'wu11-denied-use', v_uncertified_decision.decision_id,
      'market-research-consumer', v_lineage
    );
    RAISE EXCEPTION 'probe corrupted: denied entitlement produced a use receipt';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'entitlement gate denied%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object(
        'denied_use_blocked', (
          SELECT count(*) = 0
          FROM entitled_use_receipt
          WHERE use_key = 'wu11-denied-use'
        )
      );
  END;

  BEGIN
    PERFORM record_entitled_use(
      'wu11-expired-use-after-decision', v_expired_allowed_decision.decision_id,
      'market-research-consumer', v_lineage
    );
    RAISE EXCEPTION 'probe corrupted: an expired allowed decision produced a use receipt';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%no longer usable%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('expired_allowed_use_denied', true);
  END;

  BEGIN
    UPDATE entitlement_gate_decision
    SET decision = 'allowed'
    WHERE decision_id = v_uncertified_decision.decision_id;
    RAISE EXCEPTION 'probe corrupted: gate decision log was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('decision_log_append_only', true);
  END;

  INSERT INTO wu11_probe_result (result)
  VALUES (v_results);
END
$probe$;
