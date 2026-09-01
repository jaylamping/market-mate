-- WU-46 stage-1 dashboard projection probe. Run inside a caller-managed
-- transaction; fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu46_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu46-probe","entitlement_version":"stage1-surfaces-v1"}';
  v_snapshot research_snapshot%ROWTYPE;
  v_surface jsonb;
  v_unverified jsonb;
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT * INTO v_snapshot FROM append_research_snapshot(
    'stage1_dashboard',
    '{"security":"WU46","observation_state":"current","close_cents":10100}'::jsonb,
    v_lineage, NULL, NULL
  );

  PERFORM record_research_cycle_manifest(
    'wu46-dashboard-cycle', 'post_close', '2026-08-31T22:00:00Z',
    1, 1, 'complete', 'complete', NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'snapshot_key', 'WU46-security',
      'snapshot_id', v_snapshot.snapshot_id::text,
      'completion_state', 'complete',
      'evidence_state', 'complete'
    )), v_lineage
  );

  SELECT jsonb_build_object(
    'audit', (SELECT count(*) FROM audit_event),
    'qualification', (SELECT count(*) FROM research_qualification_report),
    'models', (SELECT count(*) FROM operating_cost_model),
    'snapshots', (SELECT count(*) FROM research_snapshot)
  ) INTO v_before;
  SELECT read_stage1_surfaces(), read_stage1_surfaces()
    INTO v_surface, v_unverified;
  SELECT jsonb_build_object(
    'audit', (SELECT count(*) FROM audit_event),
    'qualification', (SELECT count(*) FROM research_qualification_report),
    'models', (SELECT count(*) FROM operating_cost_model),
    'snapshots', (SELECT count(*) FROM research_snapshot)
  ) INTO v_after;

  INSERT INTO wu46_probe_result (result) VALUES (jsonb_build_object(
    'stage_badge_local_research',
      v_surface->>'environment' = 'local_research'
      AND (v_surface->>'order_authority')::boolean = false
      AND (v_surface->'stage'->>'stage')::integer = 1
      AND (v_surface->'stage'->>'display_only')::boolean,
    'qualification_progress_projected',
      (v_surface->'qualification'->>'recorded')::boolean
      AND v_surface->'qualification' ? 'window_count'
      AND v_surface->'qualification' ? 'eis'
      AND v_surface->'qualification' ? 'eis_floor'
      AND v_surface->'qualification' ? 'lcb_vs_cash_bps'
      AND v_surface->'qualification' ? 'lcb_vs_sp500_bps',
    'cost_vs_caps_projected',
      (v_surface->'cost'->>'recorded')::boolean
      AND (v_surface->'cost_model'->>'recorded')::boolean
      AND v_surface->'cost_model' ? 'within_caps'
      AND v_surface->'cost_model' ? 'monthly_projected_cents'
      AND v_surface->'cost_model' ? 'year_one_projected_cents',
    'snapshot_browsing_projected',
      (v_surface->'snapshots'->>'recorded')::boolean
      AND (v_surface->'snapshots'->>'manifest_count')::integer >= 1
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_surface->'snapshots'->'latest_manifests') item
        WHERE item->>'cycle_key' = 'wu46-dashboard-cycle'
          AND item->>'completion_state' = 'complete'
      ),
    'checkpoint_pack_projected',
      v_surface->'checkpoint_pack' ? 'mirrored_position'
      AND v_surface->'checkpoint_pack' ? 'head_position'
      AND v_surface->'checkpoint_pack' ? 'pending_events',
    'read_has_no_side_effects', v_before = v_after,
    'no_authority_grant',
      (v_surface->>'order_authority')::boolean = false
      AND v_surface->'stage'->>'order_authority' = 'none',
    'projection_does_not_claim_verification',
      NOT (v_surface ? 'checkpoints_verified')
      AND NOT (v_unverified->'checkpoint_pack' ? 'state')
  ));
END
$probe$;
