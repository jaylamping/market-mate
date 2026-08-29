-- WU-08 instrument-mapping workflow probe. Run inside a caller-managed
-- transaction; asserts the whole lifecycle and leaves one JSON result row in
-- the temp table wu08_probe_result for the caller to capture.

CREATE TEMP TABLE wu08_probe_result (result jsonb NOT NULL);

INSERT INTO issuer (issuer_id, legal_name, source_lineage, receipt_time, record_environment)
VALUES (
  '99999999-0000-0000-0000-000000000001', 'Probe Issuer',
  '{"source":"wu08-probe","entitlement_version":"local-v1"}',
  '2026-01-01T00:00:00Z', 'local_research'
);

INSERT INTO security (security_id, issuer_id, security_class, source_lineage, receipt_time, record_environment)
VALUES (
  '99999999-0000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000001', 'common_stock',
  '{"source":"wu08-probe","entitlement_version":"local-v1"}',
  '2026-01-01T00:00:00Z', 'local_research'
);

INSERT INTO exchange_listing (
  listing_id, security_id, venue, currency, listing_status,
  valid_from, valid_to, source_lineage, receipt_time, record_environment
)
VALUES
  (
    '99999999-0000-0000-0000-000000000003', '99999999-0000-0000-0000-000000000002',
    'NYSE', 'USD', 'active', '2020-01-01T00:00:00Z', NULL,
    '{"source":"wu08-probe","entitlement_version":"local-v1"}',
    '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    '99999999-0000-0000-0000-000000000004', '99999999-0000-0000-0000-000000000002',
    'NASDAQ', 'USD', 'active', '2020-01-01T00:00:00Z', NULL,
    '{"source":"wu08-probe","entitlement_version":"local-v1"}',
    '2026-01-01T00:00:00Z', 'local_research'
  );

DO $probe$
DECLARE
  m1 uuid;
  m2 uuid;
  m3 uuid;
  view_count int;
  certified_ids uuid[];
  suspended_absent bool;
  transition_count int;
  results jsonb := '{}'::jsonb;
  lineage jsonb := '{"source":"wu08-probe","entitlement_version":"local-v1"}';
BEGIN
  m1 := (propose_instrument_mapping(
    'vendor-wu08', 'WU08', 'listing',
    NULL, NULL, '99999999-0000-0000-0000-000000000003',
    '2020-01-01T00:00:00Z', lineage
  )).mapping_id;

  m2 := (propose_instrument_mapping(
    'vendor-wu08', 'wu08', 'listing',
    NULL, NULL, '99999999-0000-0000-0000-000000000004',
    '2020-01-01T00:00:00Z', lineage
  )).mapping_id;

  results := results || jsonb_build_object(
    'proposed_mappings_created',
    (SELECT count(*) = 2 FROM instrument_mapping WHERE mapping_id IN (m1, m2))
  );

  BEGIN
    PERFORM transition_instrument_mapping(m1, 'certified', 'skipping corroboration', lineage);
    RAISE EXCEPTION 'probe corrupted: proposed -> certified was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'instrument_mapping transition%' THEN
        RAISE;
      END IF;
      results := results || jsonb_build_object('proposed_to_certified_blocked', true);
  END;

  PERFORM transition_instrument_mapping(m1, 'corroborated', 'second source agrees', lineage);
  PERFORM transition_instrument_mapping(m1, 'certified', 'certification ceremony', lineage);
  results := results || jsonb_build_object('corroboration_path_to_certified', true);

  SELECT count(*) INTO view_count
  FROM certified_instrument_mapping
  WHERE mapping_id = m1;
  results := results || jsonb_build_object('certified_mapping_in_view', view_count = 1);

  BEGIN
    UPDATE instrument_mapping SET lifecycle = 'retired' WHERE mapping_id = m1;
    RAISE EXCEPTION 'probe corrupted: direct lifecycle UPDATE was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'instrument_mapping writes must go through%' THEN
        RAISE;
      END IF;
      results := results || jsonb_build_object('direct_update_blocked', true);
  END;

  PERFORM transition_instrument_mapping(m2, 'corroborated', 'second source agrees before conflict check', lineage);

  BEGIN
    PERFORM transition_instrument_mapping(m2, 'certified', 'conflicting certification', lineage);
    RAISE EXCEPTION 'probe corrupted: conflicting certification was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'instrument_mapping certification refused%' THEN
        RAISE;
      END IF;
      results := results || jsonb_build_object('conflicting_certification_blocked', true);
  END;

  PERFORM transition_instrument_mapping(m1, 'suspended', 'conflict resolution: suspend prior', lineage);
  PERFORM transition_instrument_mapping(m2, 'certified', 'certification after conflict resolved', lineage);

  SELECT array_agg(mapping_id) INTO certified_ids
  FROM certified_instrument_mapping
  WHERE mapping_id IN (m1, m2);
  results := results || jsonb_build_object(
    'resolution_via_suspend_then_certify',
    certified_ids = ARRAY[m2]
  );

  SELECT (SELECT count(*) FROM certified_instrument_mapping WHERE mapping_id = m1) = 0
  INTO suspended_absent;
  results := results || jsonb_build_object('suspended_mapping_not_consumable', suspended_absent);

  m3 := (propose_instrument_mapping(
    'vendor-wu08', 'RETIRED', 'listing',
    NULL, NULL, '99999999-0000-0000-0000-000000000003',
    '2020-01-01T00:00:00Z', lineage
  )).mapping_id;
  PERFORM transition_instrument_mapping(m3, 'retired', 'obsolete identifier', lineage);

  BEGIN
    PERFORM transition_instrument_mapping(m3, 'certified', 'revive a retired mapping', lineage);
    RAISE EXCEPTION 'probe corrupted: retired -> certified was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'instrument_mapping transition%' THEN
        RAISE;
      END IF;
      results := results || jsonb_build_object('retired_is_terminal', true);
  END;

  BEGIN
    DELETE FROM instrument_mapping WHERE mapping_id = m3;
    RAISE EXCEPTION 'probe corrupted: DELETE was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'instrument_mapping rows are never deleted%' THEN
        RAISE;
      END IF;
      results := results || jsonb_build_object('delete_blocked', true);
  END;

  BEGIN
    PERFORM propose_instrument_mapping(
      'vendor-wu08', 'MISMATCH', 'security',
      NULL, NULL, '99999999-0000-0000-0000-000000000003',
      '2020-01-01T00:00:00Z', lineage
    );
    RAISE EXCEPTION 'probe corrupted: mismatched object_kind was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE 'instrument_mapping object_kind%' THEN
        RAISE;
      END IF;
      results := results || jsonb_build_object('mismatched_object_kind_refused', true);
  END;

  SELECT count(*) INTO transition_count
  FROM instrument_mapping_transition
  WHERE mapping_id IN (m1, m2, m3);
  results := results || jsonb_build_object(
    'transitions_recorded', transition_count,
    'transition_history_count_matches_moves', transition_count = 6
  );

  INSERT INTO wu08_probe_result (result) VALUES (results);
END
$probe$;
