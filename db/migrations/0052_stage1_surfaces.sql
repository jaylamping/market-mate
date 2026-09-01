-- WU-46 Dashboard stage-1 surfaces. Projects the stage badge,
-- research qualification progress, operating cost versus caps,
-- research snapshot browsing, and checkpoint-pack status as one
-- read-only jsonb surface. The backend attaches custody-verified
-- checkpoint trust after reading this projection. Every
-- section reports an explicit not_recorded state instead of being
-- silently omitted, and the surface grants no authority.

CREATE FUNCTION read_stage1_surfaces()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    head bigint;
    mirrored_position bigint;
    checkpoint_count integer;
    report record;
    envelope record;
    model record;
    cap jsonb;
    entry_totals record;
    manifests jsonb := '[]'::jsonb;
    snapshots jsonb := '[]'::jsonb;
    manifest record;
    snapshot record;
    surfaces jsonb;
BEGIN
    SELECT max(chain_position) INTO head FROM audit_event;
    SELECT count(*), max(chain_position)
      INTO checkpoint_count, mirrored_position
      FROM audit_checkpoint;

    surfaces := jsonb_build_object(
        'environment', 'local_research',
        'order_authority', false,
        'stage', jsonb_build_object(
            'badge', 'STAGE 1 / LOCAL RESEARCH',
            'stage', 1,
            'name', 'Local Research',
            'display_only', true,
            'order_authority', 'none'
        )
    );

    SELECT q.*, qualification_sp500_is_hard(s.spec) AS sp500_hard
      INTO report
      FROM research_qualification_report q
      JOIN strategy_version s USING (strategy_version_id)
    ORDER BY q.receipt_time DESC, q.report_id
    LIMIT 1;
    IF FOUND THEN
        surfaces := surfaces || jsonb_build_object('qualification', jsonb_build_object(
            'recorded', true,
            'status', report.report->>'status',
            'strategy_version_digest', report.report->>'strategy_version_digest',
            'window_plan', report.report->'windows',
            'window_count', (
                SELECT count(*)
                FROM jsonb_array_elements(report.report->'windows'->'folds') fold
            ),
            'cluster_count', to_jsonb((report.report->>'cluster_count')::bigint),
            'eis', to_jsonb((report.report->>'eis')::bigint),
            'eis_floor', to_jsonb((report.report->>'eis_floor')::bigint),
            'meets_eis_floor',
                (report.report->>'eis')::bigint >= (report.report->>'eis_floor')::bigint,
            'lcb_vs_cash_bps', to_jsonb((report.report->>'lcb_vs_cash_bps')::bigint),
            'lcb_vs_sp500_bps', to_jsonb((report.report->>'lcb_vs_sp500_bps')::bigint),
            'sp500_comparator_required', report.sp500_hard,
            'meets_cash_floor', (report.report->>'lcb_vs_cash_bps')::bigint >= 0,
            'meets_sp500_floor',
                (report.report->>'lcb_vs_sp500_bps')::bigint >= 0,
            'net_mean_return_bps',
                to_jsonb((report.report->>'net_mean_return_bps')::bigint),
            'failure_reasons', report.report->'failure_reasons',
            'result_digest', report.result_digest,
            'as_of', to_char(
                report.receipt_time AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'receipt_time', to_char(
                report.receipt_time AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ));
    ELSE
        surfaces := surfaces || jsonb_build_object('qualification', jsonb_build_object(
            'recorded', false,
            'state', 'not_recorded',
            'detail', 'No frozen research qualification report has been recorded yet.'
        ));
    END IF;

    SELECT * INTO model
    FROM operating_cost_model
    ORDER BY receipt_time DESC, model_id
    LIMIT 1;

    IF FOUND THEN
        SELECT * INTO envelope
        FROM operating_cost_envelope
        WHERE envelope_id = model.envelope_id;
    ELSE
        SELECT * INTO envelope
        FROM operating_cost_envelope
        ORDER BY receipt_time DESC, envelope_id
        LIMIT 1;
    END IF;
    IF FOUND THEN
        cap := compute_operating_cost_cap_status(envelope.envelope_id, now(), 0);
        SELECT count(*),
               coalesce(sum(amount_cents), 0),
               max(occurred_at)
          INTO entry_totals
        FROM operating_cost_entry
        WHERE envelope_id = envelope.envelope_id;
        surfaces := surfaces || jsonb_build_object('cost', jsonb_build_object(
            'recorded', true,
            'envelope_key', envelope.envelope_key,
            'register', jsonb_build_object(
                'entries', entry_totals.count,
                'monthly_spent_cents', cap->>'monthly_spent_cents',
                'year_one_spent_cents', cap->>'year_one_spent_cents',
                'monthly_state', cap->>'monthly_state',
                'year_one_state', cap->>'year_one_state',
                'monthly_hard_ceiling_cents', cap->>'monthly_hard_ceiling_cents',
                'year_one_hard_ceiling_cents', cap->>'year_one_hard_ceiling_cents',
                'monthly_warn_threshold_cents', cap->>'monthly_warn_threshold_cents',
                'year_one_warn_threshold_cents', cap->>'year_one_warn_threshold_cents'
            ),
            'as_of', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ));
    ELSE
        surfaces := surfaces || jsonb_build_object('cost', jsonb_build_object(
            'recorded', false,
            'state', 'not_recorded',
            'detail', 'No operating cost envelope has been registered yet.'
        ));
    END IF;

    IF model.model_id IS NOT NULL THEN
        surfaces := surfaces || jsonb_build_object('cost_model', jsonb_build_object(
            'recorded', true,
            'model_key', model.model_key,
            'vendor_set_key', model.assumptions->>'vendor_set_key',
            'within_caps', model.within_caps,
            'required_decision', to_jsonb(model.required_decision),
            'monthly_projected_cents',
                to_jsonb((model.result->>'monthly_projected_cents')::bigint),
            'year_one_projected_cents',
                to_jsonb((model.result->>'year_one_projected_cents')::bigint),
            'monthly_escalation', model.result->>'monthly_escalation',
            'year_one_escalation', model.result->>'year_one_escalation',
            'monthly_hard_ceiling_cents',
                to_jsonb((model.result->>'absolute_monthly_hard_ceiling_cents')::bigint),
            'year_one_hard_ceiling_cents',
                to_jsonb((model.result->>'absolute_year_one_hard_ceiling_cents')::bigint),
            'as_of', to_char(
                model.receipt_time AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ));
    ELSE
        surfaces := surfaces || jsonb_build_object('cost_model', jsonb_build_object(
            'recorded', false,
            'state', 'not_recorded',
            'detail', 'No operating cost model has been recorded yet.'
        ));
    END IF;

    FOR manifest IN
        SELECT cycle_key, cycle_kind, cycle_as_of, expected_snapshot_count,
               completed_snapshot_count, completion_state, evidence_state,
               stale_from, stale_to
        FROM research_cycle_manifest
        ORDER BY cycle_as_of DESC, receipt_time DESC, manifest_id DESC
        LIMIT 10
    LOOP
        manifests := manifests || jsonb_build_array(jsonb_build_object(
            'cycle_key', manifest.cycle_key,
            'cycle_kind', manifest.cycle_kind,
            'cycle_as_of', to_char(
                manifest.cycle_as_of AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'expected_snapshot_count', manifest.expected_snapshot_count,
            'completed_snapshot_count', manifest.completed_snapshot_count,
            'completion_state', manifest.completion_state,
            'evidence_state', manifest.evidence_state,
            'stale_from', to_jsonb(manifest.stale_from),
            'stale_to', to_jsonb(manifest.stale_to)
        ));
    END LOOP;

    FOR snapshot IN
        SELECT s.snapshot_id, s.snapshot_kind, s.payload_digest, s.receipt_time
        FROM research_snapshot s
        WHERE NOT EXISTS (
            SELECT 1 FROM research_snapshot_revision r
            WHERE r.predecessor_snapshot_id = s.snapshot_id
        )
        ORDER BY s.receipt_time DESC, s.snapshot_id
        LIMIT 10
    LOOP
        snapshots := snapshots || jsonb_build_array(jsonb_build_object(
            'snapshot_id', snapshot.snapshot_id,
            'snapshot_kind', snapshot.snapshot_kind,
            'payload_digest', snapshot.payload_digest,
            'receipt_time', to_char(
                snapshot.receipt_time AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ));
    END LOOP;

    surfaces := surfaces || jsonb_build_object('snapshots', jsonb_build_object(
        'recorded', manifests <> '[]'::jsonb OR snapshots <> '[]'::jsonb,
        'manifest_count', (SELECT count(*) FROM research_cycle_manifest),
        'snapshot_count', (SELECT count(*) FROM research_snapshot),
        'latest_manifests', manifests,
        'latest_snapshots', snapshots
    ));

    surfaces := surfaces || jsonb_build_object('checkpoint_pack', jsonb_build_object(
        'recorded', checkpoint_count > 0,
        'checkpoint_count', checkpoint_count,
        'mirrored_position', to_jsonb(mirrored_position),
        'head_position', to_jsonb(head),
        'pending_events', CASE
            WHEN mirrored_position IS NOT NULL AND head IS NOT NULL
                THEN head - mirrored_position
            ELSE NULL END,
        'pending_material_events', CASE
            WHEN mirrored_position IS NULL THEN NULL
            ELSE (
                SELECT count(*) FROM audit_event
                WHERE chain_position > mirrored_position
                  AND event_type <> 'audit.checkpoint_created'
            )
        END
    ));

    RETURN surfaces;
END;
$$;

REVOKE ALL ON FUNCTION read_stage1_surfaces() FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
