-- Structured Research Evidence Deltas between immutable snapshots. Every
-- category is authoritative JSON; generated prose is a separate, explicitly
-- non-authoritative projection.

CREATE TABLE research_evidence_delta (
    delta_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id uuid NOT NULL REFERENCES research_snapshot(snapshot_id),
    prior_snapshot_id uuid NOT NULL REFERENCES research_snapshot(snapshot_id),
    as_of_at timestamptz NOT NULL,
    delta jsonb NOT NULL CHECK (jsonb_typeof(delta) = 'object'),
    delta_digest text NOT NULL CHECK (delta_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (snapshot_id <> prior_snapshot_id),
    CHECK (
        delta ?& ARRAY[
            'additions', 'removals', 'corrections', 'expiries',
            'observation_state_changes', 'indicator_changes', 'dependency_changes'
        ]
    ),
    CHECK (
        delta_digest = encode(
            digest('market-mate-evidence-delta-v1|' || delta::text, 'sha256'),
            'hex'
        )
    ),
    UNIQUE (snapshot_id, prior_snapshot_id)
);

SELECT register_evidence_table('research_evidence_delta');

CREATE INDEX research_evidence_delta_lookup_idx
    ON research_evidence_delta (snapshot_id, prior_snapshot_id, as_of_at);

CREATE TABLE research_evidence_delta_prose (
    prose_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    delta_id uuid NOT NULL REFERENCES research_evidence_delta(delta_id),
    generated_text text NOT NULL CHECK (btrim(generated_text) <> ''),
    prose_digest text NOT NULL CHECK (prose_digest ~ '^[0-9a-f]{64}$'),
    authority_state text NOT NULL CHECK (authority_state = 'non_authoritative'),
    generated_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        prose_digest = encode(
            digest('market-mate-generated-prose-v1|' || generated_text, 'sha256'),
            'hex'
        )
    )
);

SELECT register_evidence_table('research_evidence_delta_prose');

CREATE INDEX research_evidence_delta_prose_delta_idx
    ON research_evidence_delta_prose (delta_id, generated_at);

CREATE FUNCTION guard_research_evidence_delta_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_evidence_delta is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.evidence_delta_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'Research Evidence Deltas must be computed through compute_research_evidence_delta'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_delta_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON research_evidence_delta
FOR EACH ROW EXECUTE FUNCTION guard_research_evidence_delta_write();

CREATE TRIGGER research_evidence_delta_truncate_guard
BEFORE TRUNCATE ON research_evidence_delta
FOR EACH STATEMENT EXECUTE FUNCTION guard_research_evidence_delta_write();

CREATE FUNCTION guard_research_evidence_delta_prose_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_evidence_delta_prose is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.evidence_delta_prose_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'Research Evidence Delta prose must be recorded through record_research_evidence_delta_prose'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_delta_prose_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON research_evidence_delta_prose
FOR EACH ROW EXECUTE FUNCTION guard_research_evidence_delta_prose_write();

CREATE TRIGGER research_evidence_delta_prose_truncate_guard
BEFORE TRUNCATE ON research_evidence_delta_prose
FOR EACH STATEMENT EXECUTE FUNCTION guard_research_evidence_delta_prose_write();

CREATE FUNCTION compute_research_evidence_delta(
    snapshot_id_value uuid,
    prior_snapshot_id_value uuid,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS research_evidence_delta
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    current_snapshot research_snapshot%ROWTYPE;
    prior_snapshot research_snapshot%ROWTYPE;
    current_facts jsonb;
    prior_facts jsonb;
    current_indicators jsonb;
    prior_indicators jsonb;
    current_dependencies jsonb;
    prior_dependencies jsonb;
    additions_value jsonb;
    removals_value jsonb;
    corrections_value jsonb;
    expiries_value jsonb;
    observation_state_changes_value jsonb;
    indicator_changes_value jsonb;
    dependency_changes_value jsonb;
    delta_value jsonb;
    created research_evidence_delta%ROWTYPE;
    delta_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF snapshot_id_value IS NULL OR prior_snapshot_id_value IS NULL OR as_of_value IS NULL THEN
        RAISE EXCEPTION 'Research Evidence Delta snapshot ids and as_of_at are required'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'Research Evidence Delta source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO current_snapshot
    FROM research_snapshot
    WHERE snapshot_id = snapshot_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'current research snapshot % is not registered', snapshot_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO prior_snapshot
    FROM research_snapshot
    WHERE snapshot_id = prior_snapshot_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'prior research snapshot % is not registered', prior_snapshot_id_value
            USING ERRCODE = '22023';
    END IF;
    IF current_snapshot.snapshot_kind <> prior_snapshot.snapshot_kind THEN
        RAISE EXCEPTION 'Research Evidence Delta snapshots must have the same kind'
            USING ERRCODE = '55000';
    END IF;
    IF current_snapshot.supersedes_snapshot_id IS DISTINCT FROM prior_snapshot.snapshot_id THEN
        RAISE EXCEPTION 'current research snapshot is not the linked successor of the prior snapshot'
            USING ERRCODE = '55000';
    END IF;

    current_facts := current_snapshot.payload->'facts';
    prior_facts := prior_snapshot.payload->'facts';
    current_indicators := current_snapshot.payload->'indicators';
    prior_indicators := prior_snapshot.payload->'indicators';
    current_dependencies := current_snapshot.payload->'dependencies';
    prior_dependencies := prior_snapshot.payload->'dependencies';
    IF jsonb_typeof(current_facts) IS DISTINCT FROM 'object'
       OR jsonb_typeof(prior_facts) IS DISTINCT FROM 'object'
       OR jsonb_typeof(current_indicators) IS DISTINCT FROM 'object'
       OR jsonb_typeof(prior_indicators) IS DISTINCT FROM 'object'
       OR jsonb_typeof(current_dependencies) IS DISTINCT FROM 'object'
       OR jsonb_typeof(prior_dependencies) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION
            'Research Evidence Delta payloads require object facts, indicators, and dependencies'
            USING ERRCODE = '22023';
    END IF;

    SELECT coalesce(jsonb_agg(
        jsonb_build_object('key', current_item.key, 'current', current_item.value)
        ORDER BY current_item.key
    ), '[]'::jsonb)
    INTO additions_value
    FROM jsonb_each(current_facts) current_item
    WHERE NOT (prior_facts ? current_item.key);

    SELECT coalesce(jsonb_agg(
        jsonb_build_object('key', prior_item.key, 'prior', prior_item.value)
        ORDER BY prior_item.key
    ), '[]'::jsonb)
    INTO removals_value
    FROM jsonb_each(prior_facts) prior_item
    WHERE NOT (current_facts ? prior_item.key);

    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'key', current_item.key,
            'prior', prior_facts->current_item.key,
            'current', current_item.value
        ) ORDER BY current_item.key
    ), '[]'::jsonb)
    INTO corrections_value
    FROM jsonb_each(current_facts) current_item
    WHERE prior_facts ? current_item.key
      AND (current_item.value - 'observation_state' - 'expires_at') IS DISTINCT FROM
          ((prior_facts->current_item.key) - 'observation_state' - 'expires_at');

    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'key', current_item.key,
            'prior', prior_facts->current_item.key,
            'current', current_item.value
        ) ORDER BY current_item.key
    ), '[]'::jsonb)
    INTO expiries_value
    FROM jsonb_each(current_facts) current_item
    WHERE prior_facts ? current_item.key
      AND (prior_facts->current_item.key)->>'observation_state' IS DISTINCT FROM 'expired'
      AND (
          current_item.value->>'observation_state' = 'expired'
          OR (
              coalesce(current_item.value->>'expires_at', '') <> ''
              AND (current_item.value->>'expires_at')::timestamptz <= as_of_value
          )
      );

    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'key', current_item.key,
            'prior_state', (prior_facts->current_item.key)->>'observation_state',
            'current_state', current_item.value->>'observation_state'
        ) ORDER BY current_item.key
    ), '[]'::jsonb)
    INTO observation_state_changes_value
    FROM jsonb_each(current_facts) current_item
    WHERE prior_facts ? current_item.key
      AND (prior_facts->current_item.key)->>'observation_state' IS DISTINCT FROM
          current_item.value->>'observation_state';

    SELECT coalesce(jsonb_agg(changes.change ORDER BY changes.change_key), '[]'::jsonb)
    INTO indicator_changes_value
    FROM (
        SELECT current_item.key AS change_key,
               jsonb_build_object(
                   'indicator_key', current_item.key,
                   'change_type', CASE
                       WHEN NOT (prior_indicators ? current_item.key) THEN 'added'
                       ELSE 'changed'
                   END,
                   'prior', prior_indicators->current_item.key,
                   'current', current_item.value
               ) AS change
        FROM jsonb_each(current_indicators) current_item
        WHERE NOT (prior_indicators ? current_item.key)
           OR prior_indicators->current_item.key IS DISTINCT FROM current_item.value
        UNION ALL
        SELECT prior_item.key AS change_key,
               jsonb_build_object(
                   'indicator_key', prior_item.key,
                   'change_type', 'removed',
                   'prior', prior_item.value,
                   'current', NULL
               ) AS change
        FROM jsonb_each(prior_indicators) prior_item
        WHERE NOT (current_indicators ? prior_item.key)
    ) changes;

    SELECT coalesce(jsonb_agg(changes.change ORDER BY changes.change_key), '[]'::jsonb)
    INTO dependency_changes_value
    FROM (
        SELECT current_item.key AS change_key,
               jsonb_build_object(
                   'dependency_key', current_item.key,
                   'change_type', CASE
                       WHEN NOT (prior_dependencies ? current_item.key) THEN 'added'
                       WHEN current_item.value->>'effect_state' = 'blocked'
                            AND (prior_dependencies->current_item.key)->>'effect_state' IS DISTINCT FROM 'blocked'
                           THEN 'newly_blocked'
                       WHEN current_item.value->>'effect_state' = 'available'
                            AND (prior_dependencies->current_item.key)->>'effect_state' = 'blocked'
                           THEN 'restored'
                       ELSE 'changed'
                   END,
                   'prior', prior_dependencies->current_item.key,
                   'current', current_item.value
               ) AS change
        FROM jsonb_each(current_dependencies) current_item
        WHERE NOT (prior_dependencies ? current_item.key)
           OR prior_dependencies->current_item.key IS DISTINCT FROM current_item.value
        UNION ALL
        SELECT prior_item.key AS change_key,
               jsonb_build_object(
                   'dependency_key', prior_item.key,
                   'change_type', 'removed',
                   'prior', prior_item.value,
                   'current', NULL
               ) AS change
        FROM jsonb_each(prior_dependencies) prior_item
        WHERE NOT (current_dependencies ? prior_item.key)
    ) changes;

    delta_value := jsonb_build_object(
        'additions', additions_value,
        'removals', removals_value,
        'corrections', corrections_value,
        'expiries', expiries_value,
        'observation_state_changes', observation_state_changes_value,
        'indicator_changes', indicator_changes_value,
        'dependency_changes', dependency_changes_value
    );

    PERFORM set_config('market_mate.evidence_delta_write', 'on', true);
    BEGIN
        INSERT INTO research_evidence_delta (
            snapshot_id, prior_snapshot_id, as_of_at, delta, delta_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            current_snapshot.snapshot_id, prior_snapshot.snapshot_id, as_of_value,
            delta_value,
            encode(digest('market-mate-evidence-delta-v1|' || delta_value::text, 'sha256'), 'hex'),
            source_lineage_value, delta_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.evidence_delta_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.evidence_delta_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION record_research_evidence_delta_prose(
    delta_id_value uuid,
    generated_text_value text,
    source_lineage_value jsonb
) RETURNS research_evidence_delta_prose
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created research_evidence_delta_prose%ROWTYPE;
    prose_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF delta_id_value IS NULL OR coalesce(btrim(generated_text_value), '') = '' THEN
        RAISE EXCEPTION 'Research Evidence Delta prose requires a delta and non-empty text'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'Research Evidence Delta prose source_lineage is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM research_evidence_delta WHERE delta_id = delta_id_value
    ) THEN
        RAISE EXCEPTION 'Research Evidence Delta % is not registered', delta_id_value
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.evidence_delta_prose_write', 'on', true);
    BEGIN
        INSERT INTO research_evidence_delta_prose (
            delta_id, generated_text, prose_digest, authority_state,
            generated_at, source_lineage, receipt_time, record_environment
        ) VALUES (
            delta_id_value, generated_text_value,
            encode(digest('market-mate-generated-prose-v1|' || generated_text_value, 'sha256'), 'hex'),
            'non_authoritative', prose_receipt_time,
            source_lineage_value, prose_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.evidence_delta_prose_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.evidence_delta_prose_write', 'off', true);
    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
