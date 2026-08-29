-- WU-20 event-driven delta cycle probe. Run inside a caller-managed
-- transaction; the acceptance script rolls all fixture data back.

CREATE TEMP TABLE wu20_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu20-probe","entitlement_version":"event-delta-v1"}';
  v_parent_snapshot research_snapshot%ROWTYPE;
  v_earnings_snapshot research_snapshot%ROWTYPE;
  v_filing_snapshot research_snapshot%ROWTYPE;
  v_parent research_post_close_cycle%ROWTYPE;
  v_earnings research_event_delta_cycle%ROWTYPE;
  v_filing research_event_delta_cycle%ROWTYPE;
  v_parent_expected jsonb;
  v_earnings_expected jsonb;
  v_filing_expected jsonb;
  v_results jsonb;
BEGIN
  SELECT * INTO v_parent_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU20","close":100,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  v_parent_expected := jsonb_build_array(jsonb_build_object(
    'snapshot_key', 'WU20-parent-security', 'snapshot_id', v_parent_snapshot.snapshot_id::text,
    'source', 'eod_prices', 'state', 'complete',
    'dependency_scope', jsonb_build_array('security_daily')
  ));
  SELECT * INTO v_parent FROM publish_post_close_cycle(
    '2026-08-29', '2026-08-29T20:00:00Z', '2026-08-29T21:15:00Z',
    v_parent_expected, v_lineage
  );

  SELECT * INTO v_earnings_snapshot FROM append_research_snapshot(
    'earnings_event', '{"security":"WU20","event":"earnings_announced","eps":2.35}'::jsonb,
    v_lineage, NULL, NULL
  );
  v_earnings_expected := jsonb_build_array(jsonb_build_object(
    'snapshot_key', 'WU20-earnings-delta', 'snapshot_id', v_earnings_snapshot.snapshot_id::text,
    'state', 'complete'
  ));
  SELECT * INTO v_earnings FROM publish_event_delta_cycle(
    'earnings_announcement', 'WU20-earnings-date-reached',
    '2026-08-29T22:00:00Z', '2026-08-29T22:01:00Z', v_parent.cycle_id,
    v_earnings_expected,
    '{"trigger":"announced_date_reached","source_event_ref":"WU14-EPS-2026Q2","announcement_at":"2026-08-29T22:00:00Z"}'::jsonb,
    v_lineage
  );

  SELECT * INTO v_filing_snapshot FROM append_research_snapshot(
    'edgar_8k_event', '{"security":"WU20","event":"8-K detected","filed_at":"2026-08-29T23:00:00Z"}'::jsonb,
    v_lineage, NULL, NULL
  );
  v_filing_expected := jsonb_build_array(jsonb_build_object(
    'snapshot_key', 'WU20-8k-delta', 'snapshot_id', v_filing_snapshot.snapshot_id::text,
    'state', 'complete'
  ));
  SELECT * INTO v_filing FROM publish_event_delta_cycle(
    'edgar_8k', 'WU20-8K-detected',
    '2026-08-29T23:00:00Z', '2026-08-29T23:02:00Z', v_parent.cycle_id,
    v_filing_expected,
    '{"trigger":"8k_detected","form_type":"8-K","source_event_ref":"0000140000-26-000001","filed_at":"2026-08-29T23:00:00Z"}'::jsonb,
    v_lineage
  );

  v_results := jsonb_build_object(
    'earnings_date_triggered', v_earnings.event_kind = 'earnings_announcement'
      AND v_earnings.event_payload->>'trigger' = 'announced_date_reached',
    'eight_k_triggered', v_filing.event_kind = 'edgar_8k'
      AND v_filing.event_payload->>'form_type' = '8-K'
      AND v_filing.event_payload->>'trigger' = '8k_detected',
    'event_manifests_are_own', (
      SELECT count(*) = 2 AND bool_and(m.cycle_kind = 'event_driven')
      FROM research_cycle_manifest m
      WHERE m.manifest_id IN (v_earnings.manifest_id, v_filing.manifest_id)
    ) AND v_earnings.manifest_id <> v_parent.manifest_id
      AND v_filing.manifest_id <> v_parent.manifest_id,
    'event_cycles_link_parent', v_earnings.parent_cycle_id = v_parent.cycle_id
      AND v_filing.parent_cycle_id = v_parent.cycle_id
      AND (SELECT count(*) = 2 FROM research_event_delta_cycle
           WHERE parent_cycle_id = v_parent.cycle_id),
    'event_manifests_recorded', (
      SELECT count(*) = 2
      FROM research_event_delta_cycle
      WHERE event_key IN ('WU20-earnings-date-reached', 'WU20-8K-detected')
    ),
    'duplicate_event_blocked', false,
    'event_cycle_update_blocked', false,
    'event_manifest_update_blocked', false
  );

  BEGIN
    PERFORM publish_event_delta_cycle(
      'earnings_announcement', 'WU20-earnings-date-reached',
      '2026-08-29T22:00:00Z', '2026-08-29T22:01:00Z', v_parent.cycle_id,
      v_earnings_expected,
      '{"trigger":"announced_date_reached","source_event_ref":"WU14-EPS-2026Q2","announcement_at":"2026-08-29T22:00:00Z"}'::jsonb,
      v_lineage
    );
    RAISE EXCEPTION 'probe duplicate event unexpectedly succeeded';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%already has an event-driven delta cycle%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('duplicate_event_blocked', true);
  END;

  BEGIN
    UPDATE research_event_delta_cycle
       SET publication_state = 'complete'
     WHERE event_cycle_id = v_filing.event_cycle_id;
    RAISE EXCEPTION 'probe corrupted: event delta cycle was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('event_cycle_update_blocked', true);
  END;

  BEGIN
    UPDATE research_cycle_manifest
       SET evidence_state = 'complete'
     WHERE manifest_id = v_filing.manifest_id;
    RAISE EXCEPTION 'probe corrupted: event manifest was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('event_manifest_update_blocked', true);
  END;

  INSERT INTO wu20_probe_result (result) VALUES (v_results);
END
$probe$;
