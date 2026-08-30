-- WU-16 immutable Research Snapshot and cycle manifest probe. Run inside a
-- caller-managed transaction; the acceptance script rolls all fixture data back.

CREATE TEMP TABLE wu16_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_initial_snapshot research_snapshot%ROWTYPE;
  v_correction_snapshot research_snapshot%ROWTYPE;
  v_manifest research_cycle_manifest%ROWTYPE;
  v_successor_manifest research_cycle_manifest%ROWTYPE;
  v_initial_entry research_cycle_manifest_entry%ROWTYPE;
  v_successor_entry research_cycle_manifest_entry%ROWTYPE;
  v_lineage jsonb := '{"source":"wu16-probe","entitlement_version":"snapshot-v1"}';
  v_results jsonb;
BEGIN
  SELECT * INTO v_initial_snapshot FROM append_research_snapshot(
    'security_daily',
    '{"security":"WU16","close":100,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_correction_snapshot FROM append_research_snapshot(
    'security_daily',
    '{"security":"WU16","close":101,"observation_state":"corrected"}'::jsonb,
    v_lineage, v_initial_snapshot.snapshot_id, 'vendor correction received'
  );

  BEGIN
    INSERT INTO research_cycle_manifest (
      cycle_key, cycle_kind, cycle_as_of, expected_snapshot_count,
      completed_snapshot_count, completion_state, evidence_state,
      stale_from, stale_to, supersedes_manifest_id, superseding_delta,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'wu16-direct-insert-probe', 'post_close', clock_timestamp(), 0, 0,
      'complete', 'complete', NULL, NULL, NULL, '{}'::jsonb,
      v_lineage, clock_timestamp(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted a direct research cycle manifest insert';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%publication workflow%' THEN RAISE; END IF;
  END;

  SELECT * INTO v_manifest FROM record_research_cycle_manifest(
    'wu16-cycle-2026-08-28', 'post_close', '2026-08-28T22:00:00Z', 2, 1,
    'degraded_complete', 'degraded', '2026-08-28T23:30:00Z', NULL, NULL,
    '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object('snapshot_key','WU16-security','snapshot_id',v_correction_snapshot.snapshot_id::text,'completion_state','complete','evidence_state','complete'),
      jsonb_build_object('snapshot_key','WU16-portfolio','completion_state','stale','evidence_state','stale','stale_from','2026-08-28T23:30:00Z')
    ), v_lineage
  );
  SELECT * INTO v_initial_entry FROM research_cycle_manifest_entry
  WHERE manifest_id = v_manifest.manifest_id AND snapshot_key = 'WU16-security';

  SELECT * INTO v_successor_manifest FROM record_research_cycle_manifest(
    'wu16-cycle-2026-08-28-correction', 'post_close', '2026-08-28T23:45:00Z', 2, 2,
    'complete', 'complete', NULL, NULL, v_manifest.manifest_id,
    '{"corrected_snapshots":["WU16-security"],"restored_evidence":["WU16-portfolio"]}'::jsonb,
    jsonb_build_array(
      jsonb_build_object('snapshot_key','WU16-security','snapshot_id',v_correction_snapshot.snapshot_id::text,'completion_state','complete','evidence_state','complete','supersedes_entry_id',v_initial_entry.entry_id::text),
      jsonb_build_object('snapshot_key','WU16-portfolio','snapshot_id',v_correction_snapshot.snapshot_id::text,'completion_state','complete','evidence_state','complete')
    ), v_lineage
  );
  SELECT * INTO v_successor_entry FROM research_cycle_manifest_entry
  WHERE manifest_id = v_successor_manifest.manifest_id AND snapshot_key = 'WU16-security';

  v_results := jsonb_build_object(
    'snapshot_successor_linked', v_correction_snapshot.supersedes_snapshot_id = v_initial_snapshot.snapshot_id,
    'snapshot_correction_recorded', (
      SELECT count(*) = 1
      FROM research_snapshot_revision
      WHERE predecessor_snapshot_id = v_initial_snapshot.snapshot_id
        AND successor_snapshot_id = v_correction_snapshot.snapshot_id
    ),
    'snapshot_payload_digest_bound', v_initial_snapshot.payload_digest = encode(digest(v_initial_snapshot.payload::text, 'sha256'), 'hex')
      AND v_correction_snapshot.payload_digest = encode(digest(v_correction_snapshot.payload::text, 'sha256'), 'hex'),
    'manifest_indexes_expected_snapshots', v_manifest.expected_snapshot_count = 2
      AND (SELECT count(*) = 2 FROM research_cycle_manifest_entry WHERE manifest_id = v_manifest.manifest_id),
    'manifest_records_degraded_stale_state', v_manifest.completion_state = 'degraded_complete'
      AND v_manifest.evidence_state = 'degraded'
      AND v_manifest.stale_from IS NOT NULL
      AND (SELECT evidence_state = 'stale' AND snapshot_id IS NULL
           FROM research_cycle_manifest_entry
           WHERE manifest_id = v_manifest.manifest_id AND snapshot_key = 'WU16-portfolio'),
    'manifest_superseding_delta_linked', v_successor_manifest.supersedes_manifest_id = v_manifest.manifest_id
      AND v_successor_manifest.superseding_delta ? 'corrected_snapshots'
      AND v_successor_entry.supersedes_entry_id = v_initial_entry.entry_id,
    'snapshot_update_blocked', false,
    'snapshot_revision_update_blocked', false,
    'manifest_update_blocked', false,
    'manifest_insert_workflow_blocked', true,
    'manifest_entry_truncate_blocked', false
  );

  BEGIN
    UPDATE research_snapshot
       SET payload = '{"security":"WU16","close":999,"observation_state":"tampered"}'::jsonb,
           payload_digest = encode(digest('{"security":"WU16","close":999,"observation_state":"tampered"}'::jsonb::text, 'sha256'), 'hex')
     WHERE snapshot_id = v_initial_snapshot.snapshot_id;
    RAISE EXCEPTION 'probe corrupted: Research Snapshot was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('snapshot_update_blocked', true);
  END;

  BEGIN
    UPDATE research_snapshot_revision
       SET correction_reason = 'second vendor correction reason'
     WHERE predecessor_snapshot_id = v_initial_snapshot.snapshot_id
       AND successor_snapshot_id = v_correction_snapshot.snapshot_id;
    RAISE EXCEPTION 'probe corrupted: snapshot revision was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('snapshot_revision_update_blocked', true);
  END;

  BEGIN
    UPDATE research_cycle_manifest
       SET evidence_state = 'complete'
     WHERE manifest_id = v_manifest.manifest_id;
    RAISE EXCEPTION 'probe corrupted: Research Cycle Manifest was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('manifest_update_blocked', true);
  END;

  BEGIN
    TRUNCATE research_cycle_manifest_entry;
    RAISE EXCEPTION 'probe corrupted: manifest entries were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('manifest_entry_truncate_blocked', true);
  END;

  INSERT INTO wu16_probe_result (result) VALUES (v_results);
END
$probe$;
