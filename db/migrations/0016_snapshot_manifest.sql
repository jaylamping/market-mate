-- Immutable Research Snapshot successors and Research Cycle Manifests.
-- A correction appends a new snapshot plus explicit predecessor lineage; a
-- cycle manifest records what was expected, what completed, and which stale
-- or superseding evidence state was observed at the cycle boundary.

CREATE TABLE research_snapshot_revision (
    revision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    predecessor_snapshot_id uuid NOT NULL REFERENCES research_snapshot(snapshot_id),
    successor_snapshot_id uuid NOT NULL REFERENCES research_snapshot(snapshot_id),
    correction_reason text NOT NULL CHECK (btrim(correction_reason) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (predecessor_snapshot_id <> successor_snapshot_id),
    UNIQUE (predecessor_snapshot_id, successor_snapshot_id)
);

SELECT register_evidence_table('research_snapshot_revision');

CREATE INDEX research_snapshot_revision_successor_idx
    ON research_snapshot_revision (successor_snapshot_id, receipt_time);

CREATE TABLE research_cycle_manifest (
    manifest_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle_key text NOT NULL UNIQUE CHECK (btrim(cycle_key) <> ''),
    cycle_kind text NOT NULL CHECK (cycle_kind IN ('post_close', 'pre_open', 'event_driven', 'correction')),
    cycle_as_of timestamptz NOT NULL,
    expected_snapshot_count integer NOT NULL CHECK (expected_snapshot_count >= 0),
    completed_snapshot_count integer NOT NULL CHECK (
        completed_snapshot_count >= 0
        AND completed_snapshot_count <= expected_snapshot_count
    ),
    completion_state text NOT NULL CHECK (
        completion_state IN ('pending', 'complete', 'degraded_complete', 'incomplete', 'failed')
    ),
    evidence_state text NOT NULL CHECK (
        evidence_state IN ('complete', 'degraded', 'incomplete', 'failed')
    ),
    stale_from timestamptz,
    stale_to timestamptz,
    supersedes_manifest_id uuid REFERENCES research_cycle_manifest(manifest_id),
    superseding_delta jsonb NOT NULL CHECK (jsonb_typeof(superseding_delta) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (stale_to IS NULL OR (stale_from IS NOT NULL AND stale_to > stale_from)),
    CHECK (supersedes_manifest_id IS NULL OR superseding_delta <> '{}'::jsonb)
);

SELECT register_evidence_table('research_cycle_manifest');

CREATE INDEX research_cycle_manifest_as_of_idx
    ON research_cycle_manifest (cycle_kind, cycle_as_of, receipt_time);

CREATE TABLE research_cycle_manifest_entry (
    entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manifest_id uuid NOT NULL REFERENCES research_cycle_manifest(manifest_id),
    snapshot_key text NOT NULL CHECK (btrim(snapshot_key) <> ''),
    expected boolean NOT NULL,
    snapshot_id uuid REFERENCES research_snapshot(snapshot_id),
    completion_state text NOT NULL CHECK (
        completion_state IN ('pending', 'complete', 'stale', 'failed')
    ),
    evidence_state text NOT NULL CHECK (
        evidence_state IN ('complete', 'degraded', 'stale', 'incomplete', 'failed')
    ),
    stale_from timestamptz,
    stale_to timestamptz,
    supersedes_entry_id uuid REFERENCES research_cycle_manifest_entry(entry_id),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (snapshot_id IS NOT NULL OR completion_state IN ('pending', 'stale', 'failed')),
    CHECK (completion_state <> 'complete' OR snapshot_id IS NOT NULL),
    CHECK (completion_state <> 'stale' OR stale_from IS NOT NULL),
    CHECK (evidence_state <> 'stale' OR stale_from IS NOT NULL),
    CHECK (stale_to IS NULL OR (stale_from IS NOT NULL AND stale_to > stale_from)),
    UNIQUE (manifest_id, snapshot_key)
);

SELECT register_evidence_table('research_cycle_manifest_entry');

CREATE INDEX research_cycle_manifest_entry_lookup_idx
    ON research_cycle_manifest_entry (manifest_id, expected, completion_state, evidence_state);

CREATE FUNCTION guard_research_snapshot_successor_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NEW.supersedes_snapshot_id IS NOT NULL
       AND current_setting('market_mate.snapshot_successor_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'research snapshot successors must be appended through append_research_snapshot'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_snapshot_successor_write_guard
BEFORE INSERT ON research_snapshot
FOR EACH ROW EXECUTE FUNCTION guard_research_snapshot_successor_write();

CREATE TRIGGER research_snapshot_revision_mutation_guard
BEFORE UPDATE OR DELETE ON research_snapshot_revision
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_snapshot_revision_truncate_guard
BEFORE TRUNCATE ON research_snapshot_revision
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_manifest_mutation_guard
BEFORE UPDATE OR DELETE ON research_cycle_manifest
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_manifest_truncate_guard
BEFORE TRUNCATE ON research_cycle_manifest
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_manifest_entry_mutation_guard
BEFORE UPDATE OR DELETE ON research_cycle_manifest_entry
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_manifest_entry_truncate_guard
BEFORE TRUNCATE ON research_cycle_manifest_entry
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION append_research_snapshot(
    snapshot_kind_value text,
    payload_value jsonb,
    source_lineage_value jsonb,
    supersedes_snapshot_id_value uuid,
    correction_reason_value text
) RETURNS research_snapshot
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    predecessor research_snapshot%ROWTYPE;
    created research_snapshot%ROWTYPE;
    snapshot_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF coalesce(btrim(snapshot_kind_value), '') = '' THEN
        RAISE EXCEPTION 'research snapshot kind must not be empty' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(payload_value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'research snapshot payload must be a JSON object' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research snapshot source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    IF supersedes_snapshot_id_value IS NULL THEN
        IF coalesce(btrim(correction_reason_value), '') <> '' THEN
            RAISE EXCEPTION 'correction reason requires a superseded research snapshot'
                USING ERRCODE = '22023';
        END IF;
    ELSE
        SELECT *
        INTO predecessor
        FROM research_snapshot
        WHERE snapshot_id = supersedes_snapshot_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'superseded research snapshot % is not registered', supersedes_snapshot_id_value
                USING ERRCODE = '22023';
        END IF;
        IF predecessor.snapshot_kind <> snapshot_kind_value THEN
            RAISE EXCEPTION 'research snapshot successor kind must match its predecessor'
                USING ERRCODE = '55000';
        END IF;
        IF coalesce(btrim(correction_reason_value), '') = '' THEN
            RAISE EXCEPTION 'research snapshot successor requires a correction reason'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.snapshot_successor_write', 'on', true);
    BEGIN
        INSERT INTO research_snapshot (
            snapshot_kind, payload, payload_digest, supersedes_snapshot_id,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            snapshot_kind_value, payload_value,
            encode(digest(payload_value::text, 'sha256'), 'hex'),
            supersedes_snapshot_id_value, source_lineage_value,
            snapshot_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.snapshot_successor_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.snapshot_successor_write', 'off', true);

    IF supersedes_snapshot_id_value IS NOT NULL THEN
        INSERT INTO research_snapshot_revision (
            predecessor_snapshot_id, successor_snapshot_id, correction_reason,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            predecessor.snapshot_id, created.snapshot_id, correction_reason_value,
            source_lineage_value, snapshot_receipt_time, 'local_research'
        );
    END IF;

    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
