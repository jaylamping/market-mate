-- WU-10 Source Registry and Data Contract probe. Run inside a caller-managed
-- transaction; the fixture rows are rolled back by the acceptance script.

CREATE TEMP TABLE wu10_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '10000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '10000000-0000-0000-0000-000000000101';
  v_source_v2 uuid := '10000000-0000-0000-0000-000000000102';
  v_contract_id uuid := '10000000-0000-0000-0000-000000000201';
  v_contract_v1 uuid := '10000000-0000-0000-0000-000000000202';
  v_contract_v2 uuid := '10000000-0000-0000-0000-000000000203';
  v_other_contract_id uuid := '10000000-0000-0000-0000-000000000204';
  v_close_v1 uuid := '10000000-0000-0000-0000-000000000301';
  v_close_v2 uuid := '10000000-0000-0000-0000-000000000302';
  v_volume_v2 uuid := '10000000-0000-0000-0000-000000000303';
  v_connector_id uuid := '10000000-0000-0000-0000-000000000401';
  v_mismatched_source_connector_id uuid := '10000000-0000-0000-0000-000000000403';
  v_unknown_source uuid := '10000000-0000-0000-0000-000000000999';
  v_lineage jsonb := '{"source":"wu10-probe","entitlement_version":"local-v1"}';
  v_results jsonb;
BEGIN
  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-primary', 'Licensed EOD Primary', 'market_data',
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
    '{"name":"Licensed EOD Terms","version":"2026.1"}',
    '{"purposes":["local_research","paper_validation"],"retention":"contractual"}',
    '{"required_fields":["source_observation_id","published_at","received_at"]}',
    ARRAY['current','stale','missing','incomplete','source_disputed'],
    ARRAY['factual_correction','retraction','source_unavailability','provenance_dispute'],
    '2026-01-01T00:00:00Z', '2026-07-01T00:00:00Z',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_source_v2, v_source_id, 2, 'active',
    '{"name":"Licensed EOD Terms","version":"2026.2"}',
    '{"purposes":["local_research","paper_validation","dashboard_display"],"retention":"contractual"}',
    '{"required_fields":["source_observation_id","published_at","received_at","correction_id"]}',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed','invalidated'],
    ARRAY['factual_correction','retraction','rights_restriction','required_deletion','source_unavailability','provenance_dispute'],
    '2026-07-01T00:00:00Z', NULL,
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'daily-eod-market-data', 'market',
    'Point-in-time daily market observations for research consumers',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_contract_version (
    contract_version_id, contract_id, contract_version, source_registry_version_id,
    effective_from, effective_to, availability_time_rules,
    instrument_identity_rules, provenance_requirements,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_contract_v1, v_contract_id, 1, v_source_v1,
    '2026-01-01T00:00:00Z', '2026-07-01T00:00:00Z',
    '{"as_of_required":true,"receipt_time_required":true}',
    '{"security_id_required":true}',
    '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_contract_v2, v_contract_id, 2, v_source_v2,
    '2026-07-01T00:00:00Z', NULL,
    '{"as_of_required":true,"receipt_time_required":true,"availability_time_required":true}',
    '{"security_id_required":true,"mapping_must_be_certified":true}',
    '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true,"correction_semantics":true}',
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  );

  INSERT INTO data_contract_field (
    field_id, contract_version_id, field_key, value_type,
    observation_states, field_semantics,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (
    v_close_v1, v_contract_v1, 'close_price', 'numeric',
    ARRAY['current','stale','missing','incomplete'],
    '{"unit":"USD","as_of":"point_in_time"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  ),
  (
    v_close_v2, v_contract_v2, 'close_price', 'numeric',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    '{"unit":"USD","as_of":"point_in_time","revisions":"append_new_observation"}',
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  ),
  (
    v_volume_v2, v_contract_v2, 'volume', 'integer',
    ARRAY['current','stale','expired','missing','incomplete','source_disputed'],
    '{"unit":"shares","as_of":"point_in_time"}',
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  );

  INSERT INTO source_connector (
    connector_id, connector_key, connector_kind,
    source_registry_version_id, contract_version_id, lifecycle,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_connector_id, 'licensed-eod-connector', 'daily_eod',
    v_source_v2, v_contract_v2, 'active',
    v_lineage, '2026-07-01T00:00:00Z', 'local_research'
  );

  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id,
    source_lineage, receipt_time, record_environment
  ) VALUES
  (v_connector_id, v_contract_v2, v_close_v2, v_lineage, now(), 'local_research'),
  (v_connector_id, v_contract_v2, v_volume_v2, v_lineage, now(), 'local_research');

  v_results := jsonb_build_object(
    'source_key', (SELECT source_key FROM source_registry WHERE source_id = v_source_id),
    'source_versions', (SELECT jsonb_agg(registry_version ORDER BY registry_version)
                        FROM source_registry_version WHERE source_id = v_source_id),
    'source_registered', EXISTS (
      SELECT 1 FROM source_registry WHERE source_id = v_source_id
    ),
    'required_registry_terms', (
      SELECT license_terms ? 'name'
         AND permitted_use ? 'purposes'
         AND lineage_rules ? 'required_fields'
         AND cardinality(observation_states) > 0
         AND cardinality(correction_semantics) > 0
      FROM source_registry_version WHERE source_version_id = v_source_v2
    ),
    'source_versions_point_in_time', (
      (SELECT registry_version FROM source_registry_version
       WHERE source_id = v_source_id
         AND effective_from <= '2026-03-01T00:00:00Z'
         AND (effective_to IS NULL OR effective_to > '2026-03-01T00:00:00Z')) = 1
      AND
      (SELECT registry_version FROM source_registry_version
       WHERE source_id = v_source_id
         AND effective_from <= '2026-08-01T00:00:00Z'
         AND (effective_to IS NULL OR effective_to > '2026-08-01T00:00:00Z')) = 2
    ),
    'contract_registered', EXISTS (
      SELECT 1 FROM data_contract WHERE contract_id = v_contract_id
    ),
    'contract_versions_effectively_dated', (
      SELECT count(*) = 2
         AND bool_and(effective_from IS NOT NULL)
         AND bool_and(effective_to IS NULL OR effective_to > effective_from)
         AND min(effective_from) = '2026-01-01T00:00:00Z'::timestamptz
         AND max(effective_from) = '2026-07-01T00:00:00Z'::timestamptz
      FROM data_contract_version WHERE contract_id = v_contract_id
    ),
    'consumed_fields_bound_to_version', (
      SELECT count(*) = 2
         AND bool_and(b.contract_version_id = v_contract_v2)
         AND bool_and(f.contract_version_id = v_contract_v2)
      FROM connector_field_binding b
      JOIN data_contract_field f ON f.field_id = b.field_id
      WHERE b.connector_id = v_connector_id
    ),
    'connector_fields_match_contract_version', (
      SELECT count(*) = 2
         AND bool_and(b.contract_version_id = c.contract_version_id)
         AND bool_and(f.contract_version_id = b.contract_version_id)
      FROM connector_field_binding b
      JOIN source_connector c ON c.connector_id = b.connector_id
      JOIN data_contract_field f ON f.field_id = b.field_id
      WHERE b.connector_id = v_connector_id
    ),
    'source_connector_update_blocked', false,
    'source_connector_delete_blocked', false,
    'versioned_records_append_only', false,
    'contract_source_range_rejected', false,
    'overlapping_contract_version_rejected', false,
    'source_version_mismatch_rejected', false,
    'connector_binding_version_mismatch_rejected', false,
    'bound_field_keys', (
      SELECT jsonb_agg(f.field_key ORDER BY f.field_key)
      FROM connector_field_binding b
      JOIN data_contract_field f ON f.field_id = b.field_id
      WHERE b.connector_id = v_connector_id
    )
  );

  BEGIN
    INSERT INTO connector_field_binding (
      connector_id, contract_version_id, field_id,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_connector_id, v_contract_v2, v_close_v1,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: connector accepted a field from another contract version';
  EXCEPTION
    WHEN foreign_key_violation THEN
      v_results := v_results || jsonb_build_object('mismatched_field_version_rejected', true);
  END;

  BEGIN
    INSERT INTO connector_field_binding (
      connector_id, contract_version_id, field_id,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_connector_id, v_contract_v1, v_close_v1,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: connector accepted a field binding from another contract version';
  EXCEPTION
    WHEN foreign_key_violation THEN
      v_results := v_results || jsonb_build_object('connector_binding_version_mismatch_rejected', true);
  END;

  BEGIN
    INSERT INTO data_contract_version (
      contract_version_id, contract_id, contract_version, source_registry_version_id,
      effective_from, effective_to, availability_time_rules,
      instrument_identity_rules, provenance_requirements,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      '10000000-0000-0000-0000-000000000205', v_contract_id, 3, v_source_v2,
      '2026-08-01T00:00:00Z', '2026-09-01T00:00:00Z',
      '{"as_of_required":true}', '{"security_id_required":true}',
      '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: overlapping data contract version was accepted';
  EXCEPTION
    WHEN exclusion_violation THEN
      v_results := v_results || jsonb_build_object('overlapping_contract_version_rejected', true);
  END;

  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_other_contract_id, 'out-of-range-contract', 'market',
    'Negative probe contract for source range containment',
    v_lineage, now(), 'local_research'
  );

  BEGIN
    INSERT INTO data_contract_version (
      contract_version_id, contract_id, contract_version, source_registry_version_id,
      effective_from, effective_to, availability_time_rules,
      instrument_identity_rules, provenance_requirements,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      '10000000-0000-0000-0000-000000000206', v_other_contract_id, 1, v_source_v2,
      '2026-06-01T00:00:00Z', '2026-08-01T00:00:00Z',
      '{"as_of_required":true}', '{"security_id_required":true}',
      '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: contract range escaped its source registry version';
  EXCEPTION
    WHEN check_violation THEN
      v_results := v_results || jsonb_build_object('contract_source_range_rejected', true);
  END;

  BEGIN
    INSERT INTO source_connector (
      connector_id, connector_key, connector_kind,
      source_registry_version_id, contract_version_id, lifecycle,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_mismatched_source_connector_id, 'registered-but-mismatched-source-connector', 'daily_eod',
      v_source_v1, v_contract_v2, 'active',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: connector accepted a registered source version that did not match its contract';
  EXCEPTION
    WHEN foreign_key_violation THEN
      v_results := v_results || jsonb_build_object('source_version_mismatch_rejected', true);
  END;

  BEGIN
    UPDATE source_registry_version
    SET lifecycle = 'active'
    WHERE source_version_id = v_source_v2;
    RAISE EXCEPTION 'probe corrupted: source registry version was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('versioned_records_append_only', true);
  END;

  BEGIN
    UPDATE source_connector
    SET lifecycle = 'retired'
    WHERE connector_id = v_connector_id;
    RAISE EXCEPTION 'probe corrupted: source connector was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('source_connector_update_blocked', true);
  END;

  BEGIN
    DELETE FROM source_connector
    WHERE connector_id = v_connector_id;
    RAISE EXCEPTION 'probe corrupted: source connector was deletable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('source_connector_delete_blocked', true);
  END;

  BEGIN
    DELETE FROM data_contract_field WHERE field_id = v_close_v2;
    RAISE EXCEPTION 'probe corrupted: data contract field was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('versioned_records_append_only', true);
  END;

  BEGIN
    TRUNCATE connector_field_binding;
    RAISE EXCEPTION 'probe corrupted: connector field bindings could be truncated';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('versioned_records_append_only', true);
  END;

  BEGIN
    INSERT INTO source_registry_version (
      source_version_id, source_id, registry_version, lifecycle,
      license_terms, permitted_use, lineage_rules, observation_states,
      correction_semantics, effective_from, effective_to,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      '10000000-0000-0000-0000-000000000103', v_source_id, 3, 'active',
      '{"name":"overlap"}', '{"purposes":["local_research"]}',
      '{"required_fields":["source_observation_id"]}', ARRAY['current'],
      ARRAY['factual_correction'], '2026-06-01T00:00:00Z', '2026-08-01T00:00:00Z',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: overlapping source registry version was accepted';
  EXCEPTION
    WHEN exclusion_violation THEN
      v_results := v_results || jsonb_build_object('overlapping_source_version_rejected', true);
  END;

  BEGIN
    INSERT INTO source_connector (
      connector_id, connector_key, connector_kind,
      source_registry_version_id, contract_version_id, lifecycle,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      '10000000-0000-0000-0000-000000000402', 'unregistered-source-connector', 'daily_eod',
      v_unknown_source, v_contract_v2, 'active',
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: connector accepted an unregistered source';
  EXCEPTION
    WHEN foreign_key_violation THEN
      v_results := v_results || jsonb_build_object('unregistered_source_rejected', true);
  END;

  INSERT INTO wu10_probe_result (result)
  VALUES (v_results || jsonb_build_object(
    'mismatched_field_version_rejected', coalesce(v_results->>'mismatched_field_version_rejected', 'false')::boolean,
    'overlapping_source_version_rejected', coalesce(v_results->>'overlapping_source_version_rejected', 'false')::boolean,
    'unregistered_source_rejected', coalesce(v_results->>'unregistered_source_rejected', 'false')::boolean,
    'versioned_records_append_only', coalesce(v_results->>'versioned_records_append_only', 'false')::boolean,
    'contract_source_range_rejected', coalesce(v_results->>'contract_source_range_rejected', 'false')::boolean,
    'overlapping_contract_version_rejected', coalesce(v_results->>'overlapping_contract_version_rejected', 'false')::boolean,
    'source_version_mismatch_rejected', coalesce(v_results->>'source_version_mismatch_rejected', 'false')::boolean,
    'connector_binding_version_mismatch_rejected', coalesce(v_results->>'connector_binding_version_mismatch_rejected', 'false')::boolean,
    'source_connector_update_blocked', coalesce(v_results->>'source_connector_update_blocked', 'false')::boolean,
    'source_connector_delete_blocked', coalesce(v_results->>'source_connector_delete_blocked', 'false')::boolean
  ));
END
$probe$;
