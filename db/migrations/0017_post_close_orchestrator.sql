-- Post-close cycle publication for Local Research. One authoritative cycle
-- is appended per trading day, with an explicit 90-minute deadline and a
-- dependency ledger for partial-source effects and late stale intervals.

CREATE TABLE research_post_close_cycle (
    cycle_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    trading_date date NOT NULL UNIQUE,
    authoritative boolean NOT NULL CHECK (authoritative),
    market_close_at timestamptz NOT NULL,
    deadline_at timestamptz NOT NULL,
    published_at timestamptz NOT NULL,
    publication_state text NOT NULL CHECK (
        publication_state IN ('complete', 'degraded_complete', 'failed')
    ),
    manifest_id uuid NOT NULL REFERENCES research_cycle_manifest(manifest_id),
    dependency_status jsonb NOT NULL CHECK (jsonb_typeof(dependency_status) = 'object'),
    stale_from timestamptz,
    stale_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (deadline_at = market_close_at + interval '90 minutes'),
    CHECK (published_at >= market_close_at),
    CHECK (stale_to IS NULL OR (stale_from IS NOT NULL AND stale_to > stale_from)),
    CHECK (
        (published_at <= deadline_at AND stale_from IS NULL AND stale_to IS NULL)
        OR (published_at > deadline_at AND stale_from = deadline_at AND stale_to = published_at)
    )
);

SELECT register_evidence_table('research_post_close_cycle');

CREATE INDEX research_post_close_cycle_publication_idx
    ON research_post_close_cycle (trading_date, publication_state, published_at);

CREATE TABLE research_post_close_cycle_dependency (
    dependency_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle_id uuid NOT NULL REFERENCES research_post_close_cycle(cycle_id),
    snapshot_key text NOT NULL CHECK (btrim(snapshot_key) <> ''),
    source_name text NOT NULL CHECK (btrim(source_name) <> ''),
    snapshot_id uuid REFERENCES research_snapshot(snapshot_id),
    dependency_scope jsonb NOT NULL CHECK (
        jsonb_typeof(dependency_scope) = 'array'
        AND jsonb_array_length(dependency_scope) > 0
    ),
    outcome_state text NOT NULL CHECK (outcome_state IN ('complete', 'failed')),
    effect_state text NOT NULL CHECK (effect_state IN ('available', 'blocked')),
    failure_reason text,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (outcome_state = 'complete' AND effect_state = 'available')
        OR (
            outcome_state = 'failed'
            AND effect_state = 'blocked'
            AND coalesce(btrim(failure_reason), '') <> ''
        )
    ),
    CHECK (outcome_state = 'complete' OR snapshot_id IS NULL),
    UNIQUE (cycle_id, snapshot_key)
);

SELECT register_evidence_table('research_post_close_cycle_dependency');

CREATE INDEX research_post_close_cycle_dependency_scope_idx
    ON research_post_close_cycle_dependency (cycle_id, effect_state, outcome_state);

CREATE FUNCTION guard_research_post_close_cycle_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_post_close_cycle is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.post_close_cycle_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'post-close cycles must be published through publish_post_close_cycle'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_post_close_cycle_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON research_post_close_cycle
FOR EACH ROW EXECUTE FUNCTION guard_research_post_close_cycle_write();

CREATE TRIGGER research_post_close_cycle_truncate_guard
BEFORE TRUNCATE ON research_post_close_cycle
FOR EACH STATEMENT EXECUTE FUNCTION guard_research_post_close_cycle_write();

CREATE FUNCTION guard_research_post_close_dependency_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_post_close_cycle_dependency is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.post_close_dependency_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'post-close dependency effects must be published through publish_post_close_cycle'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_post_close_dependency_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON research_post_close_cycle_dependency
FOR EACH ROW EXECUTE FUNCTION guard_research_post_close_dependency_write();

CREATE TRIGGER research_post_close_dependency_truncate_guard
BEFORE TRUNCATE ON research_post_close_cycle_dependency
FOR EACH STATEMENT EXECUTE FUNCTION guard_research_post_close_dependency_write();

CREATE FUNCTION publish_post_close_cycle(
    trading_date_value date,
    market_close_at_value timestamptz,
    published_at_value timestamptz,
    expected_snapshots_value jsonb,
    source_lineage_value jsonb
) RETURNS research_post_close_cycle
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    item jsonb;
    snapshot_key_value text;
    source_name_value text;
    outcome_state_value text;
    failure_reason_value text;
    dependency_scope_value jsonb;
    snapshot_id_value uuid;
    cycle_manifest research_cycle_manifest%ROWTYPE;
    created research_post_close_cycle%ROWTYPE;
    expected_count integer;
    completed_count integer := 0;
    deadline_value timestamptz;
    cycle_state text;
    manifest_evidence_state text;
    late boolean;
    stale_from_value timestamptz;
    stale_to_value timestamptz;
    cycle_receipt_time timestamptz := clock_timestamp();
    dependency_status_value jsonb := '{}'::jsonb;
BEGIN
    IF trading_date_value IS NULL
       OR market_close_at_value IS NULL
       OR published_at_value IS NULL THEN
        RAISE EXCEPTION 'post-close cycle date and timestamps are required' USING ERRCODE = '22023';
    END IF;
    IF published_at_value < market_close_at_value THEN
        RAISE EXCEPTION 'post-close publication cannot precede market close' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(expected_snapshots_value) IS DISTINCT FROM 'array'
       OR jsonb_array_length(expected_snapshots_value) = 0 THEN
        RAISE EXCEPTION 'post-close cycle must declare expected snapshots' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'post-close cycle source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(8717);
    IF EXISTS (
        SELECT 1
        FROM research_post_close_cycle
        WHERE trading_date = trading_date_value
          AND authoritative
    ) THEN
        RAISE EXCEPTION
            'trading date % already has an authoritative post-close cycle', trading_date_value
            USING ERRCODE = '55000';
    END IF;

    expected_count := jsonb_array_length(expected_snapshots_value);
    FOR item IN SELECT value FROM jsonb_array_elements(expected_snapshots_value) LOOP
        IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'post-close expected snapshot entries must be JSON objects'
                USING ERRCODE = '22023';
        END IF;
        snapshot_key_value := item->>'snapshot_key';
        source_name_value := item->>'source';
        outcome_state_value := item->>'state';
        dependency_scope_value := item->'dependency_scope';
        IF coalesce(btrim(snapshot_key_value), '') = ''
           OR coalesce(btrim(source_name_value), '') = ''
           OR outcome_state_value NOT IN ('complete', 'failed')
           OR jsonb_typeof(dependency_scope_value) IS DISTINCT FROM 'array'
           OR jsonb_array_length(dependency_scope_value) = 0 THEN
            RAISE EXCEPTION 'post-close expected snapshot entry is invalid: %', item
                USING ERRCODE = '22023';
        END IF;
        IF (
            SELECT count(*)
            FROM jsonb_array_elements(expected_snapshots_value) prior
            WHERE prior->>'snapshot_key' = snapshot_key_value
        ) <> 1 THEN
            RAISE EXCEPTION 'post-close snapshot key % is duplicated', snapshot_key_value
                USING ERRCODE = '22023';
        END IF;

        snapshot_id_value := NULL;
        IF outcome_state_value = 'complete' THEN
            IF coalesce(btrim(item->>'snapshot_id'), '') = '' THEN
                RAISE EXCEPTION 'complete post-close snapshot % requires a snapshot id', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
            BEGIN
                snapshot_id_value := (item->>'snapshot_id')::uuid;
            EXCEPTION
                WHEN invalid_text_representation THEN
                    RAISE EXCEPTION 'post-close snapshot % has an invalid snapshot id', snapshot_key_value
                        USING ERRCODE = '22023';
            END;
            IF NOT EXISTS (
                SELECT 1 FROM research_snapshot WHERE snapshot_id = snapshot_id_value
            ) THEN
                RAISE EXCEPTION 'post-close snapshot % is not registered', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
            completed_count := completed_count + 1;
            failure_reason_value := NULL;
        ELSE
            IF item->>'snapshot_id' IS NOT NULL THEN
                RAISE EXCEPTION 'failed post-close snapshot % cannot carry a snapshot id', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
            failure_reason_value := item->>'failure_reason';
            IF coalesce(btrim(failure_reason_value), '') = '' THEN
                RAISE EXCEPTION 'failed post-close snapshot % requires a failure reason', snapshot_key_value
                    USING ERRCODE = '22023';
            END IF;
        END IF;

        dependency_status_value := dependency_status_value || jsonb_build_object(
            snapshot_key_value,
            jsonb_build_object(
                'source', source_name_value,
                'state', outcome_state_value,
                'dependency_scope', dependency_scope_value,
                'failure_reason', failure_reason_value
            )
        );
    END LOOP;

    deadline_value := market_close_at_value + interval '90 minutes';
    late := published_at_value > deadline_value;
    IF late THEN
        stale_from_value := deadline_value;
        stale_to_value := published_at_value;
    END IF;

    IF completed_count = expected_count AND NOT late THEN
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
        'post-close:' || trading_date_value::text,
        'post_close', published_at_value, expected_count, completed_count,
        cycle_state, manifest_evidence_state, stale_from_value, stale_to_value,
        NULL, '{}'::jsonb, source_lineage_value, cycle_receipt_time, 'local_research'
    ) RETURNING * INTO cycle_manifest;

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
            cycle_manifest.manifest_id, item->>'snapshot_key', true, snapshot_id_value,
            outcome_state_value, outcome_state_value,
            CASE WHEN late AND outcome_state_value = 'failed' THEN stale_from_value END,
            CASE WHEN late AND outcome_state_value = 'failed' THEN stale_to_value END,
            NULL, source_lineage_value, cycle_receipt_time, 'local_research'
        );
    END LOOP;

    PERFORM set_config('market_mate.post_close_cycle_write', 'on', true);
    BEGIN
        INSERT INTO research_post_close_cycle (
            trading_date, authoritative, market_close_at, deadline_at, published_at,
            publication_state, manifest_id, dependency_status, stale_from, stale_to,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            trading_date_value, true, market_close_at_value, deadline_value, published_at_value,
            cycle_state, cycle_manifest.manifest_id, dependency_status_value,
            stale_from_value, stale_to_value, source_lineage_value,
            cycle_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.post_close_cycle_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.post_close_cycle_write', 'off', true);

    PERFORM set_config('market_mate.post_close_dependency_write', 'on', true);
    BEGIN
        FOR item IN SELECT value FROM jsonb_array_elements(expected_snapshots_value) LOOP
            outcome_state_value := item->>'state';
            snapshot_id_value := CASE
                WHEN outcome_state_value = 'complete' THEN (item->>'snapshot_id')::uuid
                ELSE NULL
            END;
            INSERT INTO research_post_close_cycle_dependency (
                cycle_id, snapshot_key, source_name, snapshot_id, dependency_scope,
                outcome_state, effect_state, failure_reason,
                source_lineage, receipt_time, record_environment
            ) VALUES (
                created.cycle_id, item->>'snapshot_key', item->>'source', snapshot_id_value,
                item->'dependency_scope', outcome_state_value,
                CASE WHEN outcome_state_value = 'complete' THEN 'available' ELSE 'blocked' END,
                CASE WHEN outcome_state_value = 'failed' THEN item->>'failure_reason' END,
                source_lineage_value, cycle_receipt_time, 'local_research'
            );
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.post_close_dependency_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.post_close_dependency_write', 'off', true);

    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
