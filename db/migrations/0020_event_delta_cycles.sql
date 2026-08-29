-- Event-driven research delta cycles. Earnings announcement-date events and
-- detected EDGAR 8-K events publish their own immutable event_driven manifest
-- while retaining an explicit link to the authoritative post-close parent.

CREATE TABLE research_event_delta_cycle (
    event_cycle_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_kind text NOT NULL CHECK (event_kind IN ('earnings_announcement', 'edgar_8k')),
    event_key text NOT NULL UNIQUE CHECK (btrim(event_key) <> ''),
    event_at timestamptz NOT NULL,
    detected_at timestamptz NOT NULL,
    parent_cycle_id uuid NOT NULL REFERENCES research_post_close_cycle(cycle_id),
    manifest_id uuid NOT NULL REFERENCES research_cycle_manifest(manifest_id),
    source_event_ref text NOT NULL CHECK (btrim(source_event_ref) <> ''),
    source_earnings_estimate_id uuid REFERENCES earnings_estimate_observation(estimate_id),
    source_edgar_filing_id uuid REFERENCES edgar_filing(filing_id),
    event_payload jsonb NOT NULL CHECK (jsonb_typeof(event_payload) = 'object'),
    publication_state text NOT NULL CHECK (
        publication_state IN ('complete', 'degraded_complete', 'failed')
    ),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (detected_at >= event_at),
    CHECK (event_payload->>'source_event_ref' = source_event_ref),
    CHECK (
        (event_kind = 'earnings_announcement'
         AND source_earnings_estimate_id IS NOT NULL
         AND source_edgar_filing_id IS NULL)
        OR
        (event_kind = 'edgar_8k'
         AND source_earnings_estimate_id IS NULL
         AND source_edgar_filing_id IS NOT NULL)
    ),
    CHECK (
        (
            event_kind = 'earnings_announcement'
            AND event_payload->>'trigger' = 'announced_date_reached'
            AND coalesce(btrim(event_payload->>'announcement_at'), '') <> ''
        )
        OR (
            event_kind = 'edgar_8k'
            AND event_payload->>'trigger' = '8k_detected'
            AND event_payload->>'form_type' = '8-K'
            AND coalesce(btrim(event_payload->>'filed_at'), '') <> ''
        )
    )
);

SELECT register_evidence_table('research_event_delta_cycle');

CREATE INDEX research_event_delta_cycle_parent_idx
    ON research_event_delta_cycle (parent_cycle_id, event_kind, event_at);

CREATE FUNCTION guard_research_event_delta_cycle_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_event_delta_cycle is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.event_delta_cycle_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'event delta cycles must be published through publish_event_delta_cycle'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_event_delta_cycle_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON research_event_delta_cycle
FOR EACH ROW EXECUTE FUNCTION guard_research_event_delta_cycle_write();

CREATE TRIGGER research_event_delta_cycle_truncate_guard
BEFORE TRUNCATE ON research_event_delta_cycle
FOR EACH STATEMENT EXECUTE FUNCTION guard_research_event_delta_cycle_write();

CREATE FUNCTION publish_event_delta_cycle(
    event_kind_value text,
    event_key_value text,
    event_at_value timestamptz,
    detected_at_value timestamptz,
    parent_cycle_id_value uuid,
    source_earnings_estimate_id_value uuid,
    source_edgar_filing_id_value uuid,
    expected_snapshots_value jsonb,
    event_payload_value jsonb,
    source_lineage_value jsonb
) RETURNS research_event_delta_cycle
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    item jsonb;
    snapshot_key_value text;
    snapshot_id_value uuid;
    source_event_ref_value text;
    outcome_state_value text;
    parent_cycle research_post_close_cycle%ROWTYPE;
    earnings_estimate_row earnings_estimate_observation%ROWTYPE;
    edgar_filing_row edgar_filing%ROWTYPE;
    event_manifest research_cycle_manifest%ROWTYPE;
    created research_event_delta_cycle%ROWTYPE;
    expected_count integer;
    completed_count integer := 0;
    cycle_state text;
    manifest_evidence_state text;
    cycle_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF event_kind_value NOT IN ('earnings_announcement', 'edgar_8k')
       OR coalesce(btrim(event_key_value), '') = ''
       OR event_at_value IS NULL
       OR detected_at_value IS NULL
       OR detected_at_value < event_at_value
       OR jsonb_typeof(expected_snapshots_value) IS DISTINCT FROM 'array'
       OR jsonb_array_length(expected_snapshots_value) = 0
       OR jsonb_typeof(event_payload_value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'event delta cycle inputs are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'event delta cycle source_lineage is invalid' USING ERRCODE = '22023';
    END IF;
    IF event_kind_value = 'earnings_announcement'
       AND (event_payload_value->>'trigger' <> 'announced_date_reached'
            OR coalesce(btrim(event_payload_value->>'announcement_at'), '') = '') THEN
        RAISE EXCEPTION 'earnings event requires an announced_date_reached trigger and announcement_at'
            USING ERRCODE = '55000';
    END IF;
    IF event_kind_value = 'edgar_8k'
       AND (event_payload_value->>'trigger' <> '8k_detected'
            OR event_payload_value->>'form_type' <> '8-K'
            OR coalesce(btrim(event_payload_value->>'filed_at'), '') = '') THEN
        RAISE EXCEPTION 'EDGAR event requires an 8k_detected trigger, 8-K form, and filed_at'
            USING ERRCODE = '55000';
    END IF;
    IF coalesce(btrim(event_payload_value->>'source_event_ref'), '') = '' THEN
        RAISE EXCEPTION 'event delta cycle requires a source event reference' USING ERRCODE = '22023';
    END IF;
    source_event_ref_value := event_payload_value->>'source_event_ref';

    IF event_kind_value = 'earnings_announcement' THEN
        IF source_earnings_estimate_id_value IS NULL OR source_edgar_filing_id_value IS NOT NULL THEN
            RAISE EXCEPTION
                'earnings event must identify exactly one registered earnings estimate'
                USING ERRCODE = '55000';
        END IF;
        SELECT e.*
        INTO earnings_estimate_row
        FROM earnings_estimate_observation e
        WHERE e.estimate_id = source_earnings_estimate_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'earnings event source estimate % is not registered', source_earnings_estimate_id_value
                USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (
            SELECT 1
            FROM source_registry_version sv
            JOIN source_registry s ON s.source_id = sv.source_id
            WHERE sv.source_version_id = earnings_estimate_row.source_registry_version_id
              AND s.source_kind = 'fundamental_data'
        ) THEN
            RAISE EXCEPTION 'earnings event source estimate is not registered as fundamental data'
                USING ERRCODE = '55000';
        END IF;
        IF source_event_ref_value <> earnings_estimate_row.vendor_observation_key THEN
            RAISE EXCEPTION 'earnings event source reference does not match its estimate'
                USING ERRCODE = '55000';
        END IF;
        IF earnings_estimate_row.announcement_at <> event_at_value THEN
            RAISE EXCEPTION 'earnings event time does not match its estimate announcement time'
                USING ERRCODE = '55000';
        END IF;
        BEGIN
            IF (event_payload_value->>'announcement_at')::timestamptz <> event_at_value THEN
                RAISE EXCEPTION 'earnings event payload time does not match event time'
                    USING ERRCODE = '55000';
            END IF;
        EXCEPTION
            WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
                RAISE EXCEPTION 'earnings event announcement_at must be a valid timestamp'
                    USING ERRCODE = '22023';
        END;
    ELSE
        IF source_edgar_filing_id_value IS NULL OR source_earnings_estimate_id_value IS NOT NULL THEN
            RAISE EXCEPTION
                'EDGAR event must identify exactly one registered EDGAR filing'
                USING ERRCODE = '55000';
        END IF;
        SELECT f.*
        INTO edgar_filing_row
        FROM edgar_filing f
        WHERE f.filing_id = source_edgar_filing_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EDGAR event source filing % is not registered', source_edgar_filing_id_value
                USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (
            SELECT 1
            FROM source_registry_version sv
            JOIN source_registry s ON s.source_id = sv.source_id
            WHERE sv.source_version_id = edgar_filing_row.source_registry_version_id
              AND s.source_kind = 'public_filing'
        ) THEN
            RAISE EXCEPTION 'EDGAR event source filing is not registered as a public filing'
                USING ERRCODE = '55000';
        END IF;
        IF upper(btrim(edgar_filing_row.form_type)) <> '8-K' THEN
            RAISE EXCEPTION 'EDGAR event source filing is not an 8-K'
                USING ERRCODE = '55000';
        END IF;
        IF source_event_ref_value <> edgar_filing_row.accession_number THEN
            RAISE EXCEPTION 'EDGAR event source reference does not match its filing accession'
                USING ERRCODE = '55000';
        END IF;
        IF edgar_filing_row.filed_at <> event_at_value THEN
            RAISE EXCEPTION 'EDGAR event time does not match its filing time'
                USING ERRCODE = '55000';
        END IF;
        BEGIN
            IF (event_payload_value->>'filed_at')::timestamptz <> event_at_value THEN
                RAISE EXCEPTION 'EDGAR event payload time does not match event time'
                    USING ERRCODE = '55000';
            END IF;
        EXCEPTION
            WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
                RAISE EXCEPTION 'EDGAR event filed_at must be a valid timestamp'
                    USING ERRCODE = '22023';
        END;
    END IF;

    PERFORM pg_advisory_xact_lock(8720);
    IF EXISTS (SELECT 1 FROM research_event_delta_cycle WHERE event_key = event_key_value) THEN
        RAISE EXCEPTION
            'event key % already has an event-driven delta cycle', event_key_value
            USING ERRCODE = '55000';
    END IF;

    SELECT * INTO parent_cycle
    FROM research_post_close_cycle
    WHERE cycle_id = parent_cycle_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'parent post-close cycle % is not registered', parent_cycle_id_value
            USING ERRCODE = '22023';
    END IF;
    IF parent_cycle.published_at > detected_at_value THEN
        RAISE EXCEPTION 'event delta cycle cannot precede its parent cycle publication'
            USING ERRCODE = '55000';
    END IF;

    expected_count := jsonb_array_length(expected_snapshots_value);
    FOR item IN SELECT value FROM jsonb_array_elements(expected_snapshots_value) LOOP
        snapshot_key_value := item->>'snapshot_key';
        outcome_state_value := item->>'state';
        IF jsonb_typeof(item) IS DISTINCT FROM 'object'
           OR coalesce(btrim(snapshot_key_value), '') = ''
           OR outcome_state_value NOT IN ('complete', 'failed') THEN
            RAISE EXCEPTION 'event delta expected snapshot entry is invalid: %', item
                USING ERRCODE = '22023';
        END IF;
        IF (
            SELECT count(*)
            FROM jsonb_array_elements(expected_snapshots_value) prior
            WHERE prior->>'snapshot_key' = snapshot_key_value
        ) <> 1 THEN
            RAISE EXCEPTION 'event delta snapshot key % is duplicated', snapshot_key_value
                USING ERRCODE = '22023';
        END IF;
        IF outcome_state_value = 'complete' THEN
            IF coalesce(btrim(item->>'snapshot_id'), '') = '' THEN
                RAISE EXCEPTION 'complete event snapshot % requires a snapshot id', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
            BEGIN
                snapshot_id_value := (item->>'snapshot_id')::uuid;
            EXCEPTION
                WHEN invalid_text_representation THEN
                    RAISE EXCEPTION 'event snapshot % has an invalid snapshot id', snapshot_key_value
                        USING ERRCODE = '22023';
            END;
            IF NOT EXISTS (SELECT 1 FROM research_snapshot WHERE snapshot_id = snapshot_id_value) THEN
                RAISE EXCEPTION 'event snapshot % is not registered', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
            completed_count := completed_count + 1;
        ELSE
            IF item->>'snapshot_id' IS NOT NULL
               OR coalesce(btrim(item->>'failure_reason'), '') = '' THEN
                RAISE EXCEPTION 'failed event snapshot % requires no id and a failure reason', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
        END IF;
    END LOOP;

    IF completed_count = expected_count THEN
        cycle_state := 'complete';
        manifest_evidence_state := 'complete';
    ELSIF completed_count > 0 THEN
        cycle_state := 'degraded_complete';
        manifest_evidence_state := 'degraded';
    ELSE
        cycle_state := 'failed';
        manifest_evidence_state := 'failed';
    END IF;

    INSERT INTO research_cycle_manifest (
        cycle_key, cycle_kind, cycle_as_of, expected_snapshot_count,
        completed_snapshot_count, completion_state, evidence_state,
        stale_from, stale_to, supersedes_manifest_id, superseding_delta,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        'event:' || event_key_value, 'event_driven', detected_at_value,
        expected_count, completed_count, cycle_state, manifest_evidence_state,
        NULL, NULL, NULL, '{}'::jsonb,
        source_lineage_value, cycle_receipt_time, 'local_research'
    ) RETURNING * INTO event_manifest;

    FOR item IN SELECT value FROM jsonb_array_elements(expected_snapshots_value) LOOP
        outcome_state_value := item->>'state';
        snapshot_id_value := CASE
            WHEN outcome_state_value = 'complete' THEN (item->>'snapshot_id')::uuid
            ELSE NULL
        END;
        INSERT INTO research_cycle_manifest_entry (
            manifest_id, snapshot_key, expected, snapshot_id,
            completion_state, evidence_state, stale_from, stale_to,
            supersedes_entry_id, source_lineage, receipt_time, record_environment
        ) VALUES (
            event_manifest.manifest_id, item->>'snapshot_key', true, snapshot_id_value,
            outcome_state_value, outcome_state_value, NULL, NULL, NULL,
            source_lineage_value, cycle_receipt_time, 'local_research'
        );
    END LOOP;

    PERFORM set_config('market_mate.event_delta_cycle_write', 'on', true);
    BEGIN
        INSERT INTO research_event_delta_cycle (
            event_kind, event_key, event_at, detected_at, parent_cycle_id,
            manifest_id, source_event_ref, source_earnings_estimate_id,
            source_edgar_filing_id, event_payload, publication_state,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            event_kind_value, event_key_value, event_at_value, detected_at_value,
            parent_cycle_id_value, event_manifest.manifest_id,
            source_event_ref_value, source_earnings_estimate_id_value,
            source_edgar_filing_id_value, event_payload_value,
            cycle_state, source_lineage_value, cycle_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.event_delta_cycle_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.event_delta_cycle_write', 'off', true);
    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
