-- WU-17 post-close cycle orchestrator probe. Run inside a caller-managed
-- transaction; the acceptance script rolls all fixture data back.

CREATE TEMP TABLE wu17_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu17-probe","entitlement_version":"post-close-v1"}';
  v_now timestamptz := clock_timestamp();
  v_day_one_security research_snapshot%ROWTYPE;
  v_day_one_actions research_snapshot%ROWTYPE;
  v_day_two_security research_snapshot%ROWTYPE;
  v_day_one research_post_close_cycle%ROWTYPE;
  v_day_two research_post_close_cycle%ROWTYPE;
  v_day_one_expected jsonb;
  v_day_two_expected jsonb;
  v_results jsonb;
BEGIN
  SELECT * INTO v_day_one_security FROM append_research_snapshot(
    'eod_price',
    '{"security":"WU17-A","close":100,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_day_one_actions FROM append_research_snapshot(
    'corporate_action',
    '{"security":"WU17-A","action_state":"none"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_day_two_security FROM append_research_snapshot(
    'eod_price',
    '{"security":"WU17-B","close":101,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );

  v_day_one_expected := jsonb_build_array(
    jsonb_build_object(
      'snapshot_key', 'WU17-A-security',
      'snapshot_id', v_day_one_security.snapshot_id::text,
      'source', 'eod_prices',
      'state', 'complete',
      'dependency_scope', jsonb_build_array('security_daily')
    ),
    jsonb_build_object(
      'snapshot_key', 'WU17-A-corporate-actions',
      'snapshot_id', v_day_one_actions.snapshot_id::text,
      'source', 'eod_corporate_actions',
      'state', 'complete',
      'dependency_scope', jsonb_build_array('corporate_actions')
    )
  );
  SELECT * INTO v_day_one FROM publish_post_close_cycle(
    '2026-08-27', v_now - interval '30 minutes', v_now + interval '5 minutes',
    v_day_one_expected, v_lineage
  );

  v_day_two_expected := jsonb_build_array(
    jsonb_build_object(
      'snapshot_key', 'WU17-B-security',
      'snapshot_id', v_day_two_security.snapshot_id::text,
      'source', 'eod_prices',
      'state', 'complete',
      'dependency_scope', jsonb_build_array('security_daily')
    ),
    jsonb_build_object(
      'snapshot_key', 'WU17-B-options',
      'source', 'historical_options',
      'state', 'failed',
      'failure_reason', 'licensed source unavailable',
      'dependency_scope', jsonb_build_array('options')
    )
  );
  SELECT * INTO v_day_two FROM publish_post_close_cycle(
    '2026-08-28', v_now - interval '3 hours', v_now + interval '10 minutes',
    v_day_two_expected, v_lineage
  );

  v_results := jsonb_build_object(
    'sample_days_recorded', (
      SELECT count(*) = 2
      FROM research_post_close_cycle
      WHERE trading_date IN ('2026-08-27', '2026-08-28')
    ),
    'exactly_one_authoritative_cycle', (
      SELECT count(*) = 1
      FROM research_post_close_cycle
      WHERE trading_date = '2026-08-27'
    ) AND (
      SELECT count(*) = 1
      FROM research_post_close_cycle
      WHERE trading_date = '2026-08-28'
    ),
    'deadline_targeted', v_day_one.deadline_at = v_day_one.market_close_at + interval '90 minutes'
      AND v_day_two.deadline_at = v_day_two.market_close_at + interval '90 minutes',
    'on_time_cycle_published', v_day_one.publication_state = 'complete'
      AND v_day_one.published_at <= v_day_one.deadline_at
      AND (SELECT completion_state = 'complete' AND evidence_state = 'complete'
           FROM research_cycle_manifest WHERE manifest_id = v_day_one.manifest_id),
    'late_interval_visible', v_day_two.published_at > v_day_two.deadline_at
      AND v_day_two.stale_from = v_day_two.deadline_at
      AND v_day_two.stale_to = v_day_two.published_at
      AND (SELECT stale_from = v_day_two.deadline_at AND stale_to = v_day_two.published_at
           FROM research_cycle_manifest WHERE manifest_id = v_day_two.manifest_id),
    'partial_failure_degraded', v_day_two.publication_state = 'degraded_complete'
      AND (SELECT completion_state = 'degraded_complete'
           AND evidence_state = 'degraded'
           AND completed_snapshot_count = 1
           AND expected_snapshot_count = 2
           FROM research_cycle_manifest WHERE manifest_id = v_day_two.manifest_id),
    'dependency_scope_restricted', (
      SELECT d.outcome_state = 'failed'
         AND d.effect_state = 'blocked'
         AND d.dependency_scope @> '["options"]'::jsonb
         AND d.failure_reason = 'licensed source unavailable'
      FROM research_post_close_cycle_dependency d
      WHERE d.cycle_id = v_day_two.cycle_id
        AND d.snapshot_key = 'WU17-B-options'
    ),
    'duplicate_publish_blocked', false,
    'cycle_update_blocked', false,
    'manifest_update_blocked', false,
    'dependency_truncate_blocked', false
  );

  BEGIN
    PERFORM publish_post_close_cycle(
      '2026-08-27', v_now - interval '30 minutes', v_now + interval '5 minutes',
      v_day_one_expected, v_lineage
    );
    RAISE EXCEPTION 'probe duplicate publish unexpectedly succeeded';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%already has an authoritative post-close cycle%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('duplicate_publish_blocked', true);
  END;

  BEGIN
    UPDATE research_post_close_cycle
       SET publication_state = 'failed'
     WHERE cycle_id = v_day_two.cycle_id;
    RAISE EXCEPTION 'probe corrupted: post-close cycle was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('cycle_update_blocked', true);
  END;

  BEGIN
    UPDATE research_cycle_manifest
       SET evidence_state = 'complete'
     WHERE manifest_id = v_day_two.manifest_id;
    RAISE EXCEPTION 'probe corrupted: post-close manifest was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('manifest_update_blocked', true);
  END;

  BEGIN
    TRUNCATE research_post_close_cycle_dependency;
    RAISE EXCEPTION 'probe corrupted: dependency effects were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('dependency_truncate_blocked', true);
  END;

  INSERT INTO wu17_probe_result (result) VALUES (v_results);
END
$probe$;
