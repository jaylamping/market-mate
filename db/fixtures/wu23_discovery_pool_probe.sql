-- WU-23 Discovery Pool screener probe. Run inside a caller-managed
-- transaction; all fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu23_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_source_id uuid := '41000000-0000-0000-0000-000000000001';
  v_source_v1 uuid := '41000000-0000-0000-0000-000000000101';
  v_entitlement_id uuid := '41000000-0000-0000-0000-000000000201';
  v_entitlement_v1 uuid := '41000000-0000-0000-0000-000000000301';
  v_contract_id uuid := '41000000-0000-0000-0000-000000000501';
  v_contract_v1 uuid := '41000000-0000-0000-0000-000000000502';
  v_field_1 uuid := '41000000-0000-0000-0000-000000000601';
  v_field_2 uuid := '41000000-0000-0000-0000-000000000602';
  v_field_3 uuid := '41000000-0000-0000-0000-000000000603';
  v_connector_id uuid := '41000000-0000-0000-0000-000000000701';
  v_issuer_id uuid;
  v_security_id uuid;
  v_selection eod_vendor_selection%ROWTYPE;
  v_config discovery_screen_config_version%ROWTYPE;
  v_policy coverage_policy_version%ROWTYPE;
  v_run discovery_screen_run%ROWTYPE;
  v_failed_run discovery_screen_run%ROWTYPE;
  v_mapping instrument_mapping%ROWTYPE;
  v_lineage jsonb := '{"source":"wu23-probe","entitlement_version":"licensed-eod-v1"}';
  v_sessions date[] := ARRAY[
    DATE '2026-08-17', DATE '2026-08-18', DATE '2026-08-19',
    DATE '2026-08-20', DATE '2026-08-21'];
  v_run_date date := DATE '2026-08-21';
  v_as_of timestamptz;
  v_type text[] := ARRAY[
    'clean', 'preferred', 'sparse', 'otc', 'uncertified',
    'conflict', 'penny', 'lowprice', 'thin', 'late', 'pricefail'];
  v_class text[] := ARRAY[
    'common_stock', 'preferred_stock', 'common_stock', 'common_stock', 'common_stock',
    'common_stock', 'common_stock', 'common_stock', 'common_stock', 'common_stock',
    'common_stock'];
  v_venue text[] := ARRAY[
    'NASDAQ', 'NASDAQ', 'NASDAQ', 'OTCMKTS', 'NASDAQ',
    'NASDAQ', 'NASDAQ', 'NYSE', 'NASDAQ', 'NASDAQ', 'NYSE'];
  v_close numeric[] := ARRAY[
    120.00, 60.00, 80.00, 20.00, 90.00,
    70.00, 0.80, 50.00, 50.00, 110.00, 3.00];
  v_volume bigint[] := ARRAY[
    2000000, 3000000, 1000000, 500000, 4000000,
    2000000, 8000000, 2000000, 10000, 2500000, 2000000];
  v_security_ids uuid[];
  v_mapping_ids uuid[];
  v_type_index integer;
  v_session_index integer;
  v_bar_count integer;
  v_late_preview record;
  v_hidden_preview record;
  v_replay_row record;
  v_replay_matches boolean := true;
  v_results jsonb;
BEGIN
  PERFORM set_config('market_mate.security_master_write', 'on', true);

  INSERT INTO source_registry (
    source_id, source_key, source_name, source_kind,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_id, 'licensed-eod-wu23', 'Licensed EOD WU-23 Provider', 'market_data',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO source_registry_version (
    source_version_id, source_id, registry_version, lifecycle,
    license_terms, permitted_use, lineage_rules, observation_states,
    correction_semantics, effective_from, effective_to,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_source_v1, v_source_id, 1, 'active',
    '{"name":"Licensed EOD WU-23 Terms","version":"2026.1"}',
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
  ) VALUES (
    v_entitlement_id, 'licensed-eod-wu23-entitlement', 'local-research-account',
    'Licensed daily EOD access for the WU-23 screener', v_lineage,
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
    '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z',
    '{"authority":"principal-approved-paper-plan","certificate":"licensed-eod-wu23-2026.1"}',
    v_lineage, '2026-01-01T00:00:00Z', 'local_research'
  );
  INSERT INTO data_contract (
    contract_id, contract_key, contract_kind, description,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_id, 'daily-eod-contract-wu23', 'market',
    'Point-in-time licensed daily market delivery contract for WU-23',
    v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_version (
    contract_version_id, contract_id, contract_version, source_registry_version_id,
    effective_from, effective_to, availability_time_rules,
    instrument_identity_rules, provenance_requirements,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_contract_v1, v_contract_id, 1, v_source_v1,
    '2026-01-01T00:00:00Z', NULL,
    '{"as_of_required":true,"receipt_time_required":true,"availability_time_required":true}',
    '{"security_id_required":true,"mapping_must_be_certified":true}',
    '{"source_registry_version":true,"entitlement_version":true,"receipt_time":true}',
    v_lineage, now(), 'local_research'
  );
  INSERT INTO data_contract_field (
    field_id, contract_version_id, field_key, value_type,
    observation_states, field_semantics, source_lineage, receipt_time, record_environment
  ) VALUES
    (v_field_1, v_contract_v1, 'vendor_observation_key', 'text', ARRAY['current','stale','missing'], '{"required":true}'::jsonb, v_lineage, now(), 'local_research'),
    (v_field_2, v_contract_v1, 'available_at', 'timestamp', ARRAY['current','stale','missing'], '{"required":true,"as_of":"point_in_time"}'::jsonb, v_lineage, now(), 'local_research'),
    (v_field_3, v_contract_v1, 'received_at', 'timestamp', ARRAY['current'], '{"required":true}'::jsonb, v_lineage, now(), 'local_research');
  INSERT INTO source_connector (
    connector_id, connector_key, connector_kind,
    source_registry_version_id, contract_version_id, lifecycle,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_connector_id, 'licensed-eod-connector-wu23', 'daily_eod', v_source_v1, v_contract_v1,
    'active', v_lineage, now(), 'local_research'
  );
  INSERT INTO connector_field_binding (
    connector_id, contract_version_id, field_id,
    source_lineage, receipt_time, record_environment
  ) VALUES
    (v_connector_id, v_contract_v1, v_field_1, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_2, v_lineage, now(), 'local_research'),
    (v_connector_id, v_contract_v1, v_field_3, v_lineage, now(), 'local_research');

  SELECT * INTO v_selection FROM record_eod_vendor_selection(
    'licensed-eod-provider-wu23', v_source_v1, v_entitlement_v1,
    '{"selected":"licensed-eod-provider-wu23","candidates":[{"vendor":"licensed-eod-provider-wu23","license":"written research license","entitlement":"daily historical OHLCV","monthly_cost_usd":0}]}'::jsonb,
    '{"status":"written_license","raw_retention":"permitted","derived_use":"permitted"}'::jsonb,
    '{"status":"certified","history_years":10,"purposes":["local_research","paper_validation"]}'::jsonb,
    '{"monthly_cost_usd":0,"annual_budget_usd":0,"within_stage_cap":true}'::jsonb,
    'selected after license, entitlement, coverage, and cost comparison', v_lineage
  );

  FOR v_type_index IN 1 .. array_length(v_type, 1) LOOP
    INSERT INTO issuer (
      legal_name, source_lineage, receipt_time, record_environment
    ) VALUES (
      'WU-23 ' || upper(v_type[v_type_index]) || ' Issuer, Inc.', v_lineage,
      '2026-01-01T00:00:00Z', 'local_research'
    ) RETURNING issuer_id INTO v_issuer_id;
    INSERT INTO security (
      issuer_id, security_class,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_issuer_id, v_class[v_type_index], v_lineage,
      '2026-01-01T00:00:00Z', 'local_research'
    ) RETURNING security_id INTO v_security_id;
    v_security_ids := coalesce(v_security_ids, '{}') || v_security_id;
  END LOOP;

  FOR v_type_index IN 1 .. array_length(v_type, 1) LOOP
    INSERT INTO exchange_listing (
      listing_id, security_id, venue, currency, listing_status,
      valid_from, valid_to, source_lineage, receipt_time, record_environment
    ) VALUES (
      gen_random_uuid(), v_security_ids[v_type_index], v_venue[v_type_index],
      'USD', 'active',
      '2026-01-01T00:00:00Z', NULL, v_lineage,
      '2026-01-01T00:00:00Z', 'local_research'
    );
  END LOOP;
  PERFORM set_config('market_mate.security_master_write', 'off', true);

  -- Identity mappings.  uncertified stays proposed; conflict is certified
  -- under two independent providers; everything else certifies once.
  FOR v_type_index IN 1 .. array_length(v_type, 1) LOOP
    IF v_type[v_type_index] = 'uncertified' THEN
      v_mapping := propose_instrument_mapping(
        'licensed-eod-wu23', 'WU23-UNCERTIFIED', 'security',
        NULL, v_security_ids[v_type_index], NULL,
        '2026-01-01T00:00:00Z', v_lineage);
      v_mapping_ids := coalesce(v_mapping_ids, '{}') || v_mapping.mapping_id;
    ELSIF v_type[v_type_index] = 'conflict' THEN
      v_mapping := propose_instrument_mapping(
        'wu23-provider-a', 'WU23-CONFLICT-A', 'security',
        NULL, v_security_ids[v_type_index], NULL,
        '2026-01-01T00:00:00Z', v_lineage);
      v_mapping := transition_instrument_mapping(
        v_mapping.mapping_id, 'corroborated', 'provider A identity check', v_lineage);
      v_mapping := transition_instrument_mapping(
        v_mapping.mapping_id, 'certified', 'WU-23 provider A certification', v_lineage);
      v_mapping_ids := coalesce(v_mapping_ids, '{}') || v_mapping.mapping_id;
      v_mapping := propose_instrument_mapping(
        'wu23-provider-b', 'WU23-CONFLICT-B', 'security',
        NULL, v_security_ids[v_type_index], NULL,
        '2026-01-01T00:00:00Z', v_lineage);
      v_mapping := transition_instrument_mapping(
        v_mapping.mapping_id, 'corroborated', 'provider B identity check', v_lineage);
      v_mapping := transition_instrument_mapping(
        v_mapping.mapping_id, 'certified', 'WU-23 provider B certification', v_lineage);
    ELSE
      v_mapping := propose_instrument_mapping(
        'licensed-eod-wu23', 'WU23-' || upper(v_type[v_type_index]), 'security',
        NULL, v_security_ids[v_type_index], NULL,
        '2026-01-01T00:00:00Z', v_lineage);
      v_mapping := transition_instrument_mapping(
        v_mapping.mapping_id, 'corroborated', 'independent provider identity check', v_lineage);
      v_mapping := transition_instrument_mapping(
        v_mapping.mapping_id, 'certified', 'WU-23 connector certification fixture', v_lineage);
      v_mapping_ids := coalesce(v_mapping_ids, '{}') || v_mapping.mapping_id;
    END IF;
  END LOOP;

  -- EOD bars.  clean/preferred/otc/penny/lowprice/thin/late/pricefail get
  -- all five sessions; sparse gets three; conflict/uncertified get none.
  v_bar_count := 0;
  FOR v_type_index IN 1 .. array_length(v_type, 1) LOOP
    IF v_type[v_type_index] IN ('conflict', 'uncertified') THEN
      CONTINUE;
    END IF;
    FOR v_session_index IN 1 .. (
      CASE WHEN v_type[v_type_index] = 'sparse' THEN 3 ELSE 5 END
    ) LOOP
      PERFORM ingest_eod_price_observation(
        v_selection.selection_id, v_mapping_ids[v_type_index],
        'WU23-' || v_type[v_type_index] || '-' || v_sessions[v_session_index]::text,
        v_sessions[v_session_index], 'complete',
        v_close[v_type_index] * 0.98, v_close[v_type_index] * 1.05,
        v_close[v_type_index] * 0.95, v_close[v_type_index],
        v_volume[v_type_index],
        v_sessions[v_session_index]::timestamptz + interval '21 hours',
        jsonb_build_object(
          'open', v_close[v_type_index] * 0.98,
          'high', v_close[v_type_index] * 1.05,
          'low', v_close[v_type_index] * 0.95,
          'close', v_close[v_type_index],
          'volume', v_volume[v_type_index]),
        v_lineage);
      v_bar_count := v_bar_count + 1;
    END LOOP;
  END LOOP;

  -- Universe entries.  Every security joins the S&P-500-style seed except
  -- lowprice, whose only membership is retired before the run date; late's
  -- membership evidence arrives after the run's as_of.
  FOR v_type_index IN 1 .. array_length(v_type, 1) LOOP
    CONTINUE WHEN v_type[v_type_index] = 'lowprice';
    INSERT INTO discovery_universe_entry (
      universe_key, membership_kind, security_id,
      known_from, known_to, universe_evidence_key,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'sp500-wu23', 'index_constituent', v_security_ids[v_type_index],
      DATE '2026-01-01', NULL,
      'sp500-wu23:' || v_type[v_type_index], v_lineage,
      CASE WHEN v_type[v_type_index] = 'late'
        THEN now() + interval '2 hours' ELSE now() - interval '1 minute' END,
      'local_research'
    );
  END LOOP;
  INSERT INTO discovery_universe_entry (
    universe_key, membership_kind, security_id,
    known_from, known_to, universe_evidence_key,
    source_lineage, receipt_time, record_environment
  ) VALUES
    ('nasdaq100-wu23', 'index_constituent', v_security_ids[1],
      DATE '2026-01-01', NULL, 'ndx100-wu23:clean', v_lineage,
      now() - interval '1 minute', 'local_research'),
    ('principal-holdings-wu23', 'principal_holding', v_security_ids[11],
      DATE '2026-06-01', NULL, 'holdings-wu23:pricefail', v_lineage,
      now() - interval '1 minute', 'local_research'),
    ('sp500-wu23', 'index_constituent', v_security_ids[8],
      DATE '2025-01-01', DATE '2026-07-01', 'sp500-wu23:lowprice-retired', v_lineage,
      now() - interval '1 minute', 'local_research');

  SELECT * INTO v_policy
  FROM coverage_policy_version
  WHERE policy_key = 'coverage-policy' AND version = 1;

  SELECT * INTO v_config FROM append_discovery_screen_config_version(
    'discovery-screen', 1, v_policy.policy_version_id,
    '{
      "governing_policy_key": "coverage-policy",
      "lookback_sessions": 5,
      "min_close_price": 5.00,
      "penny_price_ceiling": 1.00,
      "min_median_dollar_volume": 5000000,
      "allowed_security_classes": ["common_stock", "etf_broad_market", "etf_sector"],
      "ordinary_venues": ["NASDAQ", "NYSE", "NYSE_ARCA"]
    }'::jsonb,
    '2026-01-01T00:00:00Z'::timestamptz,
    v_lineage
  );

  v_as_of := clock_timestamp();
  SELECT * INTO v_run FROM run_discovery_screen(
    v_config.config_version_id, v_run_date, v_as_of, v_lineage
  );

  v_results := jsonb_build_object(
    'config_digest_valid', (
      SELECT definition_digest
             = encode(digest(convert_to(definition::text, 'UTF8'), 'sha256'), 'hex')
      FROM discovery_screen_config_version
      WHERE config_version_id = v_config.config_version_id
    ),
    'config_binds_governing_policy',
      v_config.governing_policy_version_id = v_policy.policy_version_id,
    'run_complete', v_run.screen_state = 'complete',
    'run_counts_consistent',
      v_run.universe_count = v_run.included_count + v_run.rejected_count
      AND v_run.universe_count = (
        SELECT count(*) FROM discovery_pool_membership WHERE run_id = v_run.run_id),
    'run_digest_valid', v_run.run_digest ~ '^[0-9a-f]{64}$',
    'clean_common_stock_included', (
      SELECT decision = 'included' AND NOT enhanced_risk
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[1]
    ),
    'preferred_rejected_for_class', (
      SELECT decision = 'rejected'
        AND 'instrument_class_excluded' = ANY (rejection_reasons)
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[2]
    ),
    'sparse_rejected_for_data', (
      SELECT decision = 'rejected'
        AND 'insufficient_data' = ANY (rejection_reasons)
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[3]
    ),
    'otc_tagged_enhanced_risk_not_rejected_by_label', (
      SELECT decision = 'included' AND enhanced_risk
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[4]
    ),
    'uncertified_identity_rejected', (
      SELECT decision = 'rejected'
        AND 'identity_not_certified' = ANY (rejection_reasons)
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[5]
    ),
    'conflicting_identity_rejected', (
      SELECT decision = 'rejected'
        AND 'identity_conflict' = ANY (rejection_reasons)
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[6]
    ),
    'penny_tagged_enhanced_risk_not_rejected_by_price', (
      SELECT decision = 'included' AND enhanced_risk
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[7]
    ),
    'retired_membership_excluded_from_universe', (
      NOT EXISTS (
        SELECT 1 FROM discovery_pool_membership
        WHERE run_id = v_run.run_id AND security_id = v_security_ids[8]
      )
      AND v_run.universe_count = 9
    ),
    'thin_rejected_for_liquidity', (
      SELECT decision = 'rejected'
        AND 'liquidity_below_floor' = ANY (rejection_reasons)
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[9]
    ),
    'late_membership_invisible_at_run_as_of', NOT EXISTS (
      SELECT 1 FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[10]
    ),
    'pricefail_rejected_for_price', (
      SELECT decision = 'rejected'
        AND 'price_below_minimum' = ANY (rejection_reasons)
        AND NOT enhanced_risk
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id AND security_id = v_security_ids[11]
    ),
    'membership_facts_recorded', (
      SELECT count(*) = v_run.universe_count
        AND count(*) FILTER (WHERE screen_facts ? 'security_class') = v_run.universe_count
        AND count(*) FILTER (WHERE screen_facts ? 'listing_status') = v_run.universe_count
      FROM discovery_pool_membership
      WHERE run_id = v_run.run_id
    )
  );

  -- Point-in-time replay: the late member is hidden before its evidence
  -- receipt time and included after it, without touching stored rows.
  SELECT * INTO v_hidden_preview
  FROM discovery_screen_decision_preview(
    v_config.config_version_id, v_run_date, v_as_of + interval '1 hour')
  WHERE security_id = v_security_ids[10];
  v_results := v_results || jsonb_build_object(
    'late_member_hidden_before_receipt', v_hidden_preview.security_id IS NULL);

  SELECT * INTO v_late_preview
  FROM discovery_screen_decision_preview(
    v_config.config_version_id, v_run_date, v_as_of + interval '3 hours')
  WHERE security_id = v_security_ids[10];
  v_results := v_results || jsonb_build_object(
    'late_member_visible_after_receipt',
      v_late_preview.security_id IS NOT NULL
      AND v_late_preview.decision = 'included');

  -- Deterministic replay: the read-only preview reproduces every stored
  -- decision (same evidence, same as_of).
  FOR v_replay_row IN
    SELECT p.security_id, p.decision, p.enhanced_risk,
           p.screen_facts, p.rejection_reasons,
           m.screen_facts AS stored_facts, m.rejection_reasons AS stored_reasons,
           m.decision AS stored_decision, m.enhanced_risk AS stored_enhanced_risk
    FROM discovery_screen_decision_preview(
           v_config.config_version_id, v_run_date, v_run.as_of_at) p
    JOIN discovery_pool_membership m
      ON m.run_id = v_run.run_id AND m.security_id = p.security_id
  LOOP
    IF v_replay_row.decision <> v_replay_row.stored_decision
       OR v_replay_row.enhanced_risk <> v_replay_row.stored_enhanced_risk
       OR v_replay_row.screen_facts <> v_replay_row.stored_facts
       OR v_replay_row.rejection_reasons <> v_replay_row.stored_reasons THEN
      v_replay_matches := false;
    END IF;
  END LOOP;
  v_results := v_results || jsonb_build_object(
    'deterministic_replay_matches', v_replay_matches);

  -- One authoritative run per config and trading date.
  BEGIN
    PERFORM run_discovery_screen(
      v_config.config_version_id, v_run_date, v_as_of, v_lineage);
    RAISE EXCEPTION 'probe corrupted: duplicate screen run was accepted';
  EXCEPTION
    WHEN unique_violation THEN
      v_results := v_results || jsonb_build_object('duplicate_run_blocked', true);
  END;

  -- A calendar too short to meet the lookback fails closed with no members.
  v_failed_run := run_discovery_screen(
    v_config.config_version_id, DATE '2026-07-01', v_as_of, v_lineage);
  v_results := v_results || jsonb_build_object(
    'insufficient_calendar_fails_closed',
      v_failed_run.screen_state = 'failed'
      AND v_failed_run.failure_reason = 'insufficient_sessions'
      AND NOT EXISTS (
        SELECT 1 FROM discovery_pool_membership
        WHERE run_id = v_failed_run.run_id));

  -- A future as_of is refused on the write path.
  BEGIN
    PERFORM run_discovery_screen(
      v_config.config_version_id, DATE '2026-07-02',
      v_as_of + interval '10 years', v_lineage);
    RAISE EXCEPTION 'probe corrupted: future as_of was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%as_of time is invalid%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('future_as_of_blocked', true);
  END;

  -- Invalid config definitions fail closed.
  BEGIN
    PERFORM append_discovery_screen_config_version(
      'discovery-screen-invalid', 1, v_policy.policy_version_id,
      '{"governing_policy_key":"coverage-policy","lookback_sessions":2,"min_close_price":5,"penny_price_ceiling":6,"min_median_dollar_volume":0,"allowed_security_classes":["common_stock"],"ordinary_venues":["NASDAQ"]}'::jsonb,
      '2026-01-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: invalid screen config was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%definition is incomplete%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('invalid_definition_blocked', true);
  END;

  BEGIN
    PERFORM append_discovery_screen_config_version(
      'discovery-screen-wrong-policy', 1,
      '00000000-0000-0000-0000-000000000000'::uuid,
      '{"governing_policy_key":"coverage-policy","lookback_sessions":5,"min_close_price":5,"penny_price_ceiling":1,"min_median_dollar_volume":0,"allowed_security_classes":["common_stock"],"ordinary_venues":["NASDAQ"]}'::jsonb,
      '2026-01-01T00:00:00Z', v_lineage);
    RAISE EXCEPTION 'probe corrupted: unknown governing policy was accepted';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unknown_policy_blocked', true);
  END;

  -- Append-only guards.
  BEGIN
    UPDATE discovery_screen_config_version
       SET definition = definition || '{"tamper":true}'::jsonb
     WHERE config_version_id = v_config.config_version_id;
    RAISE EXCEPTION 'probe corrupted: screen config was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('config_update_blocked', true);
  END;

  BEGIN
    UPDATE discovery_screen_run
       SET included_count = 999
     WHERE run_id = v_run.run_id;
    RAISE EXCEPTION 'probe corrupted: screen run was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('run_update_blocked', true);
  END;

  BEGIN
    DELETE FROM discovery_pool_membership
     WHERE run_id = v_run.run_id;
    RAISE EXCEPTION 'probe corrupted: pool membership was deletable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('membership_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE discovery_universe_entry;
    RAISE EXCEPTION 'probe corrupted: universe entries were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('universe_truncate_blocked', true);
  END;

  -- The run is on the audit chain.
  v_results := v_results || jsonb_build_object('run_audited', (
    SELECT count(*) = 1
    FROM audit_event
    WHERE event_type = 'research.discovery_pool_screened'
      AND payload->>'run_id' = v_run.run_id::text
  ));

  INSERT INTO wu23_probe_result (result) VALUES (v_results);
END
$probe$;
