-- Stale-interval and Degraded Complete containment for Local Research.
-- Downstream consumers use immutable contracts that bind a typed WU-18
-- evidence profile to the dependency scopes they require. Scope effects are
-- accepted only when the underlying manifest evidence proves their state;
-- decisions are append-only records computed from those effects.

CREATE TABLE research_cycle_consumer_contract (
    consumer_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    consumer_key text NOT NULL UNIQUE CHECK (btrim(consumer_key) <> ''),
    coverage_stage text NOT NULL CHECK (
        coverage_stage IN ('research_candidate', 'trade_eligible', 'mandatory_holding', 'exit_monitoring')
    ),
    coverage_capability text NOT NULL CHECK (
        coverage_capability IN ('stock_eligible', 'options_eligible', 'both', 'none')
    ),
    decision_purpose text NOT NULL CHECK (
        decision_purpose IN ('research', 'new_exposure', 'holding_management', 'portfolio_review', 'risk_reduction', 'reconciliation')
    ),
    required_dependency_scopes jsonb NOT NULL CHECK (
        jsonb_typeof(required_dependency_scopes) = 'array'
        AND jsonb_array_length(required_dependency_scopes) > 0
    ),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('research_cycle_consumer_contract');

CREATE INDEX research_cycle_consumer_contract_profile_idx
    ON research_cycle_consumer_contract (coverage_stage, coverage_capability, decision_purpose);

CREATE TABLE research_cycle_scope_effect (
    effect_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manifest_id uuid NOT NULL REFERENCES research_cycle_manifest(manifest_id),
    snapshot_key text NOT NULL CHECK (btrim(snapshot_key) <> ''),
    scope_key text NOT NULL CHECK (btrim(scope_key) <> ''),
    effect_state text NOT NULL CHECK (effect_state IN ('available', 'blocked')),
    effect_reason text,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (effect_state = 'available' OR coalesce(btrim(effect_reason), '') <> ''),
    UNIQUE (manifest_id, snapshot_key, scope_key)
);

SELECT register_evidence_table('research_cycle_scope_effect');

CREATE INDEX research_cycle_scope_effect_lookup_idx
    ON research_cycle_scope_effect (manifest_id, scope_key, effect_state);

CREATE INDEX research_post_close_cycle_manifest_idx
    ON research_post_close_cycle (manifest_id);

CREATE FUNCTION research_cycle_scope_matches_snapshot(
    scope_key_value text,
    snapshot_id_value uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE scope_key_value
        WHEN 'security_daily' THEN EXISTS (
            SELECT 1 FROM research_snapshot
            WHERE snapshot_id = snapshot_id_value AND snapshot_kind = 'eod_price'
        )
        WHEN 'options' THEN EXISTS (
            SELECT 1 FROM research_snapshot
            WHERE snapshot_id = snapshot_id_value AND snapshot_kind = 'options_chain'
        )
        ELSE false
    END;
$$;

CREATE FUNCTION research_cycle_scope_matches_post_close_source(
    scope_key_value text,
    source_name_value text,
    snapshot_id_value uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE scope_key_value
        WHEN 'security_daily' THEN source_name_value = 'eod_prices'
            AND research_cycle_scope_matches_snapshot(scope_key_value, snapshot_id_value)
        WHEN 'options' THEN source_name_value = 'historical_options'
            AND research_cycle_scope_matches_snapshot(scope_key_value, snapshot_id_value)
        WHEN 'corporate_actions' THEN source_name_value = 'eod_corporate_actions'
            AND EXISTS (
                SELECT 1 FROM research_snapshot
                WHERE snapshot_id = snapshot_id_value AND snapshot_kind = 'corporate_action'
            )
        ELSE false
    END;
$$;

CREATE VIEW research_cycle_scope_effect_projection AS
    SELECT e.manifest_id, e.snapshot_key, e.scope_key, e.effect_state, e.receipt_time AS effect_receipt_time
    FROM research_cycle_scope_effect e
    JOIN research_cycle_manifest c ON c.manifest_id = e.manifest_id
    JOIN research_cycle_manifest_entry m
      ON m.manifest_id = e.manifest_id AND m.snapshot_key = e.snapshot_key
    LEFT JOIN research_snapshot s ON s.snapshot_id = m.snapshot_id
    WHERE e.effect_state = 'blocked'
       OR (s.receipt_time <= c.cycle_as_of
           AND research_cycle_scope_matches_snapshot(e.scope_key, m.snapshot_id))
    UNION ALL
    SELECT c.manifest_id, d.snapshot_key, scope.value, d.effect_state, d.receipt_time
    FROM research_post_close_cycle c
    JOIN research_post_close_cycle_dependency d ON d.cycle_id = c.cycle_id
    LEFT JOIN research_snapshot s ON s.snapshot_id = d.snapshot_id
    CROSS JOIN LATERAL jsonb_array_elements_text(d.dependency_scope) scope(value)
    WHERE d.effect_state = 'blocked'
       OR (s.receipt_time <= c.published_at
           AND research_cycle_scope_matches_post_close_source(
               scope.value, d.source_name, d.snapshot_id
           ));

CREATE TABLE research_cycle_scope_decision (
    decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manifest_id uuid NOT NULL REFERENCES research_cycle_manifest(manifest_id),
    consumer_contract_id uuid NOT NULL REFERENCES research_cycle_consumer_contract(consumer_id),
    profile_resolution_id uuid NOT NULL REFERENCES research_evidence_profile_resolution(resolution_id),
    as_of_at timestamptz NOT NULL,
    decision_state text NOT NULL CHECK (decision_state IN ('available', 'restricted', 'blocked')),
    required_scopes jsonb NOT NULL CHECK (
        jsonb_typeof(required_scopes) = 'array'
        AND jsonb_array_length(required_scopes) > 0
    ),
    available_scopes jsonb NOT NULL CHECK (jsonb_typeof(available_scopes) = 'array'),
    blocked_scopes jsonb NOT NULL CHECK (jsonb_typeof(blocked_scopes) = 'array'),
    decision_reason jsonb NOT NULL CHECK (jsonb_typeof(decision_reason) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('research_cycle_scope_decision');

CREATE INDEX research_cycle_scope_decision_lookup_idx
    ON research_cycle_scope_decision (manifest_id, consumer_contract_id, as_of_at);

CREATE FUNCTION research_cycle_profile_required_scopes(
    coverage_stage_value text,
    coverage_capability_value text,
    decision_purpose_value text
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN coverage_stage_value = 'research_candidate'
         AND coverage_capability_value = 'stock_eligible'
         AND decision_purpose_value = 'research'
            THEN '["security_daily"]'::jsonb
        WHEN coverage_stage_value = 'trade_eligible'
         AND coverage_capability_value = 'options_eligible'
         AND decision_purpose_value = 'new_exposure'
            THEN '["options"]'::jsonb
        WHEN coverage_stage_value = 'mandatory_holding'
         AND coverage_capability_value = 'options_eligible'
         AND decision_purpose_value = 'holding_management'
            THEN '["options"]'::jsonb
        WHEN coverage_stage_value = 'trade_eligible'
         AND coverage_capability_value = 'both'
         AND decision_purpose_value = 'portfolio_review'
            THEN '["security_daily", "options"]'::jsonb
        ELSE '[]'::jsonb
    END;
$$;

CREATE FUNCTION guard_research_post_close_scope_provenance() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    scope_value text;
BEGIN
    FOR scope_value IN SELECT value FROM jsonb_array_elements_text(NEW.dependency_scope) LOOP
        IF scope_value NOT IN ('security_daily', 'options', 'corporate_actions') THEN
            RAISE EXCEPTION 'post-close dependency scope % is not a registered evidence scope', scope_value
                USING ERRCODE = '55000';
        END IF;
        IF NEW.effect_state = 'available'
           AND NOT research_cycle_scope_matches_post_close_source(
               scope_value, NEW.source_name, NEW.snapshot_id
           ) THEN
            RAISE EXCEPTION
                'post-close dependency scope % is not proven by snapshot kind or source', scope_value
                USING ERRCODE = '55000';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_post_close_dependency_scope_guard
BEFORE INSERT ON research_post_close_cycle_dependency
FOR EACH ROW EXECUTE FUNCTION guard_research_post_close_scope_provenance();

CREATE FUNCTION guard_research_cycle_consumer_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT'
       OR current_setting('market_mate.cycle_consumer_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'cycle consumers must be registered through register_research_cycle_consumer'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cycle_consumer_insert_guard
BEFORE INSERT ON research_cycle_consumer_contract
FOR EACH ROW EXECUTE FUNCTION guard_research_cycle_consumer_insert();

CREATE TRIGGER research_cycle_consumer_mutation_guard
BEFORE UPDATE OR DELETE ON research_cycle_consumer_contract
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_consumer_truncate_guard
BEFORE TRUNCATE ON research_cycle_consumer_contract
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION guard_research_cycle_scope_effect_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT'
       OR current_setting('market_mate.cycle_scope_effect_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'cycle scope effects must be recorded through record_research_cycle_scope_effect'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cycle_scope_effect_insert_guard
BEFORE INSERT ON research_cycle_scope_effect
FOR EACH ROW EXECUTE FUNCTION guard_research_cycle_scope_effect_insert();

CREATE TRIGGER research_cycle_scope_effect_mutation_guard
BEFORE UPDATE OR DELETE ON research_cycle_scope_effect
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_scope_effect_truncate_guard
BEFORE TRUNCATE ON research_cycle_scope_effect
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION guard_research_cycle_scope_decision_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT'
       OR current_setting('market_mate.cycle_scope_decision_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'cycle scope decisions must be recorded through assess_research_cycle_consumer'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cycle_scope_decision_insert_guard
BEFORE INSERT ON research_cycle_scope_decision
FOR EACH ROW EXECUTE FUNCTION guard_research_cycle_scope_decision_insert();

CREATE TRIGGER research_cycle_scope_decision_mutation_guard
BEFORE UPDATE OR DELETE ON research_cycle_scope_decision
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_cycle_scope_decision_truncate_guard
BEFORE TRUNCATE ON research_cycle_scope_decision
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION register_research_cycle_consumer(
    consumer_key_value text,
    coverage_stage_value text,
    coverage_capability_value text,
    decision_purpose_value text,
    required_dependency_scopes_value jsonb,
    source_lineage_value jsonb
) RETURNS research_cycle_consumer_contract
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created research_cycle_consumer_contract%ROWTYPE;
    scope_count integer;
    valid_scope_count integer;
    distinct_scope_count integer;
    registered_scope_count integer;
    minimum_scope_value jsonb;
BEGIN
    IF coalesce(btrim(consumer_key_value), '') = ''
       OR coverage_stage_value IS NULL
       OR coverage_stage_value NOT IN ('research_candidate', 'trade_eligible', 'mandatory_holding', 'exit_monitoring')
       OR coverage_capability_value IS NULL
       OR coverage_capability_value NOT IN ('stock_eligible', 'options_eligible', 'both', 'none')
       OR decision_purpose_value IS NULL
       OR decision_purpose_value NOT IN ('research', 'new_exposure', 'holding_management', 'portfolio_review', 'risk_reduction', 'reconciliation')
       OR jsonb_typeof(required_dependency_scopes_value) IS DISTINCT FROM 'array'
       OR jsonb_array_length(required_dependency_scopes_value) = 0 THEN
        RAISE EXCEPTION 'cycle consumer contract inputs are invalid' USING ERRCODE = '22023';
    END IF;
    SELECT count(*),
           count(*) FILTER (
               WHERE jsonb_typeof(value) = 'string'
                 AND coalesce(btrim(value #>> '{}'), '') <> ''
           ),
           count(DISTINCT CASE
               WHEN jsonb_typeof(value) = 'string'
                AND coalesce(btrim(value #>> '{}'), '') <> ''
               THEN value #>> '{}'
           END)
    INTO scope_count, valid_scope_count, distinct_scope_count
    FROM jsonb_array_elements(required_dependency_scopes_value) scopes(value);
    IF scope_count <> valid_scope_count THEN
        RAISE EXCEPTION 'cycle consumer dependency scopes must be non-empty strings'
            USING ERRCODE = '22023';
    END IF;
    IF scope_count <> distinct_scope_count THEN
        RAISE EXCEPTION 'cycle consumer dependency scopes must be distinct' USING ERRCODE = '22023';
    END IF;
    SELECT count(*) FILTER (
               WHERE value #>> '{}' IN ('security_daily', 'options')
           )
    INTO registered_scope_count
    FROM jsonb_array_elements(required_dependency_scopes_value) scopes(value);
    IF scope_count <> registered_scope_count THEN
        RAISE EXCEPTION 'cycle consumer dependency scopes contain an unregistered scope'
            USING ERRCODE = '55000';
    END IF;
    minimum_scope_value := research_cycle_profile_required_scopes(
        coverage_stage_value, coverage_capability_value, decision_purpose_value
    );
    IF jsonb_array_length(minimum_scope_value) > 0
       AND NOT required_dependency_scopes_value @> minimum_scope_value THEN
        RAISE EXCEPTION
            'cycle consumer dependency scopes omit the profile-required scope set: %', minimum_scope_value
            USING ERRCODE = '55000';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'cycle consumer source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.cycle_consumer_write', 'on', true);
    BEGIN
        INSERT INTO research_cycle_consumer_contract (
            consumer_key, coverage_stage, coverage_capability, decision_purpose,
            required_dependency_scopes, source_lineage, receipt_time, record_environment
        ) VALUES (
            consumer_key_value, coverage_stage_value, coverage_capability_value, decision_purpose_value,
            required_dependency_scopes_value, source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.cycle_consumer_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.cycle_consumer_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION record_research_cycle_scope_effect(
    manifest_id_value uuid,
    snapshot_key_value text,
    scope_key_value text,
    effect_state_value text,
    effect_reason_value text,
    source_lineage_value jsonb
) RETURNS research_cycle_scope_effect
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    manifest_row research_cycle_manifest%ROWTYPE;
    entry_row research_cycle_manifest_entry%ROWTYPE;
    snapshot_receipt_time timestamptz;
    created research_cycle_scope_effect%ROWTYPE;
BEGIN
    IF manifest_id_value IS NULL
       OR coalesce(btrim(snapshot_key_value), '') = ''
       OR coalesce(btrim(scope_key_value), '') = ''
       OR effect_state_value NOT IN ('available', 'blocked') THEN
        RAISE EXCEPTION 'cycle scope effect inputs are invalid' USING ERRCODE = '22023';
    END IF;
    IF effect_state_value = 'blocked' AND coalesce(btrim(effect_reason_value), '') = '' THEN
        RAISE EXCEPTION 'blocked cycle scope effects require a reason' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'cycle scope effect source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(manifest_id_value::text, 22021));

    SELECT * INTO manifest_row
    FROM research_cycle_manifest
    WHERE manifest_id = manifest_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cycle manifest % is not registered', manifest_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO entry_row
    FROM research_cycle_manifest_entry
    WHERE manifest_id = manifest_id_value
      AND snapshot_key = snapshot_key_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cycle scope effect snapshot % is not in the manifest', snapshot_key_value
            USING ERRCODE = '22023';
    END IF;
    IF NOT entry_row.expected THEN
        RAISE EXCEPTION 'cycle scope effect snapshot % is not expected by the manifest', snapshot_key_value
            USING ERRCODE = '55000';
    END IF;
    IF effect_state_value = 'available'
       AND (
           entry_row.completion_state <> 'complete'
           OR entry_row.evidence_state <> 'complete'
           OR entry_row.snapshot_id IS NULL
       ) THEN
        RAISE EXCEPTION
            'cycle scope effect % cannot be marked available without complete manifest evidence', scope_key_value
            USING ERRCODE = '55000';
    END IF;
    IF effect_state_value = 'blocked'
       AND entry_row.completion_state = 'complete'
       AND entry_row.evidence_state = 'complete' THEN
        RAISE EXCEPTION
            'cycle scope effect % cannot be marked blocked for complete manifest evidence', scope_key_value
            USING ERRCODE = '55000';
    END IF;
    IF scope_key_value NOT IN ('security_daily', 'options') THEN
        RAISE EXCEPTION 'cycle scope % is not a registered evidence scope', scope_key_value
            USING ERRCODE = '55000';
    END IF;
    IF effect_state_value = 'available'
       AND NOT research_cycle_scope_matches_snapshot(scope_key_value, entry_row.snapshot_id) THEN
        RAISE EXCEPTION
            'cycle scope % is not proven by snapshot kind', scope_key_value
            USING ERRCODE = '55000';
    END IF;
    IF effect_state_value = 'available' THEN
        SELECT receipt_time INTO snapshot_receipt_time
        FROM research_snapshot
        WHERE snapshot_id = entry_row.snapshot_id;
        IF snapshot_receipt_time IS NULL
           OR snapshot_receipt_time > manifest_row.cycle_as_of THEN
            RAISE EXCEPTION
                'cycle scope effect % cannot use snapshot evidence received after the cycle as-of',
                scope_key_value
                USING ERRCODE = '55000';
        END IF;
    END IF;

    IF manifest_row.cycle_kind = 'post_close' AND NOT EXISTS (
        SELECT 1 FROM research_post_close_cycle
        WHERE manifest_id = manifest_id_value AND authoritative
    ) THEN
        RAISE EXCEPTION
            'post-close cycle manifest % requires an authoritative post-close cycle',
            manifest_id_value
            USING ERRCODE = '55000';
    ELSIF manifest_row.cycle_kind = 'post_close' THEN
        RAISE EXCEPTION
            'post-close cycle scope effects are sourced from the dependency ledger'
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.cycle_scope_effect_write', 'on', true);
    BEGIN
        INSERT INTO research_cycle_scope_effect (
            manifest_id, snapshot_key, scope_key, effect_state, effect_reason,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            manifest_id_value, snapshot_key_value, scope_key_value, effect_state_value, effect_reason_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.cycle_scope_effect_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.cycle_scope_effect_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION assess_research_cycle_consumer(
    manifest_id_value uuid,
    consumer_key_value text,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS research_cycle_scope_decision
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    manifest_row research_cycle_manifest%ROWTYPE;
    consumer_row research_cycle_consumer_contract%ROWTYPE;
    post_close_row research_post_close_cycle%ROWTYPE;
    profile_resolution research_evidence_profile_resolution%ROWTYPE;
    created research_cycle_scope_decision%ROWTYPE;
    effect_count integer;
    conflicting_scope_count integer;
    available_scopes_value jsonb;
    blocked_scopes_value jsonb;
    decision_state_value text;
    decision_reason_value jsonb;
    cycle_state_value text;
    stale_from_value timestamptz;
    stale_to_value timestamptz;
    stale_active boolean := false;
    available_required_count integer;
    manifest_entry_count integer;
    manifest_complete_count integer;
BEGIN
    IF manifest_id_value IS NULL
       OR coalesce(btrim(consumer_key_value), '') = ''
       OR as_of_value IS NULL
       OR as_of_value > clock_timestamp() THEN
        RAISE EXCEPTION 'cycle consumer assessment inputs are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'cycle consumer assessment source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(manifest_id_value::text, 22021));

    SELECT * INTO manifest_row
    FROM research_cycle_manifest
    WHERE manifest_id = manifest_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cycle manifest % is not registered', manifest_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO consumer_row
    FROM research_cycle_consumer_contract
    WHERE consumer_key = consumer_key_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cycle consumer % is not registered', consumer_key_value
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*), count(*) FILTER (WHERE completion_state = 'complete')
    INTO manifest_entry_count, manifest_complete_count
    FROM research_cycle_manifest_entry
    WHERE manifest_id = manifest_id_value;
    IF manifest_entry_count <> manifest_row.expected_snapshot_count
       OR manifest_complete_count <> manifest_row.completed_snapshot_count
       OR (manifest_row.completion_state = 'complete' AND (
           manifest_row.evidence_state <> 'complete'
           OR manifest_row.completed_snapshot_count <> manifest_row.expected_snapshot_count
           OR EXISTS (
               SELECT 1 FROM research_cycle_manifest_entry
               WHERE manifest_id = manifest_id_value
                 AND (completion_state <> 'complete' OR evidence_state <> 'complete')
           )
       ))
       OR (manifest_row.completion_state = 'degraded_complete' AND (
           manifest_row.evidence_state <> 'degraded'
           OR manifest_row.completed_snapshot_count <= 0
           OR manifest_row.completed_snapshot_count >= manifest_row.expected_snapshot_count
       ))
       OR (manifest_row.completion_state = 'incomplete' AND (
           manifest_row.evidence_state <> 'incomplete'
           OR manifest_row.completed_snapshot_count >= manifest_row.expected_snapshot_count
       ))
       OR (manifest_row.completion_state = 'failed' AND (
           manifest_row.evidence_state <> 'failed'
           OR manifest_row.completed_snapshot_count >= manifest_row.expected_snapshot_count
       )) THEN
        RAISE EXCEPTION 'cycle manifest % metadata is inconsistent', manifest_id_value
            USING ERRCODE = '55000';
    END IF;
    IF manifest_row.cycle_as_of > as_of_value
       AND NOT (
           manifest_row.stale_from IS NOT NULL
           AND as_of_value >= manifest_row.stale_from
           AND (manifest_row.stale_to IS NULL OR as_of_value < manifest_row.stale_to)
       ) THEN
        RAISE EXCEPTION
            'cycle manifest % is not available at the requested assessment as-of', manifest_id_value
            USING ERRCODE = '55000';
    END IF;
    IF manifest_row.cycle_kind = 'post_close' AND NOT EXISTS (
        SELECT 1 FROM research_post_close_cycle
        WHERE manifest_id = manifest_id_value AND authoritative
    ) THEN
        RAISE EXCEPTION
            'post-close cycle manifest % has no authoritative post-close cycle', manifest_id_value
            USING ERRCODE = '55000';
    END IF;

    SELECT * INTO profile_resolution FROM resolve_research_evidence_profile(
        consumer_row.coverage_stage,
        consumer_row.coverage_capability,
        consumer_row.decision_purpose,
        as_of_value,
        source_lineage_value
    );

    SELECT count(*) INTO effect_count
    FROM research_cycle_scope_effect_projection
    WHERE manifest_id = manifest_id_value
      AND effect_receipt_time <= as_of_value;
    IF effect_count = 0 THEN
        RAISE EXCEPTION 'cycle manifest % has no proven scope effects', manifest_id_value
            USING ERRCODE = '55000';
    END IF;

    SELECT count(*) INTO conflicting_scope_count
    FROM (
        SELECT scope_key
        FROM research_cycle_scope_effect_projection
        WHERE manifest_id = manifest_id_value
          AND effect_receipt_time <= as_of_value
        GROUP BY scope_key
        HAVING count(DISTINCT effect_state) > 1
    ) conflicts;
    IF conflicting_scope_count > 0 THEN
        RAISE EXCEPTION 'cycle manifest % has conflicting scope effects', manifest_id_value
            USING ERRCODE = '55000';
    END IF;

    SELECT count(*) FILTER (WHERE available),
           coalesce(jsonb_agg(scope_key ORDER BY scope_key) FILTER (WHERE available), '[]'::jsonb),
           coalesce(jsonb_agg(scope_key ORDER BY scope_key) FILTER (WHERE NOT available), '[]'::jsonb)
    INTO available_required_count, available_scopes_value, blocked_scopes_value
    FROM (
        SELECT required.value AS scope_key,
               EXISTS (
                   SELECT 1
                   FROM research_cycle_scope_effect_projection effects
                   WHERE effects.manifest_id = manifest_id_value
                     AND effects.effect_receipt_time <= as_of_value
                     AND effects.scope_key = required.value
                     AND effects.effect_state = 'available'
               ) AS available
        FROM jsonb_array_elements_text(consumer_row.required_dependency_scopes) required(value)
    ) required_scopes;

    SELECT * INTO post_close_row
    FROM research_post_close_cycle
    WHERE manifest_id = manifest_id_value;
    cycle_state_value := manifest_row.completion_state;
    IF FOUND THEN
        IF post_close_row.published_at > as_of_value
           AND NOT (
               post_close_row.stale_from IS NOT NULL
               AND as_of_value >= post_close_row.stale_from
               AND (post_close_row.stale_to IS NULL OR as_of_value < post_close_row.stale_to)
           ) THEN
            RAISE EXCEPTION
                'post-close cycle % is not available at the requested assessment as-of',
                post_close_row.cycle_id
                USING ERRCODE = '55000';
        END IF;
        IF post_close_row.publication_state IS DISTINCT FROM manifest_row.completion_state THEN
            RAISE EXCEPTION 'post-close cycle and manifest states do not agree'
                USING ERRCODE = '55000';
        END IF;
        stale_from_value := post_close_row.stale_from;
        stale_to_value := post_close_row.stale_to;
    ELSE
        stale_from_value := manifest_row.stale_from;
        stale_to_value := manifest_row.stale_to;
    END IF;
    IF cycle_state_value NOT IN ('complete', 'degraded_complete', 'incomplete', 'failed') THEN
        RAISE EXCEPTION 'cycle manifest % has an unsupported terminal state', manifest_id_value
            USING ERRCODE = '55000';
    END IF;
    stale_active := stale_from_value IS NOT NULL
        AND as_of_value >= stale_from_value
        AND (stale_to_value IS NULL OR as_of_value < stale_to_value);

    IF available_required_count < jsonb_array_length(consumer_row.required_dependency_scopes) THEN
        decision_state_value := 'blocked';
    ELSIF stale_active AND consumer_row.decision_purpose = 'new_exposure' THEN
        decision_state_value := 'blocked';
    ELSIF cycle_state_value = 'degraded_complete' OR stale_active THEN
        decision_state_value := 'restricted';
    ELSE
        decision_state_value := 'available';
    END IF;

    decision_reason_value := jsonb_build_object(
        'cycle_state', cycle_state_value,
        'stale_interval', CASE WHEN stale_active THEN 'active' ELSE 'inactive' END,
        'required_scopes', consumer_row.required_dependency_scopes,
        'available_scopes', available_scopes_value,
        'blocked_scopes', blocked_scopes_value,
        'profile_kind', profile_resolution.profile_kind,
        'profile_resolution_id', profile_resolution.resolution_id::text
    );

    PERFORM set_config('market_mate.cycle_scope_decision_write', 'on', true);
    BEGIN
        INSERT INTO research_cycle_scope_decision (
            manifest_id, consumer_contract_id, profile_resolution_id, as_of_at,
            decision_state, required_scopes, available_scopes, blocked_scopes,
            decision_reason, source_lineage, receipt_time, record_environment
        ) VALUES (
            manifest_id_value, consumer_row.consumer_id, profile_resolution.resolution_id, as_of_value,
            decision_state_value, consumer_row.required_dependency_scopes,
            available_scopes_value, blocked_scopes_value, decision_reason_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.cycle_scope_decision_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.cycle_scope_decision_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION require_research_cycle_consumer_access(
    manifest_id_value uuid,
    consumer_key_value text,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS research_cycle_scope_decision
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    decision_row research_cycle_scope_decision%ROWTYPE;
BEGIN
    SELECT * INTO decision_row FROM assess_research_cycle_consumer(
        manifest_id_value, consumer_key_value, as_of_value, source_lineage_value
    );
    IF decision_row.decision_state = 'blocked' THEN
        RAISE EXCEPTION
            'cycle consumer % is blocked for downstream use', consumer_key_value
            USING ERRCODE = '55000';
    END IF;
    RETURN decision_row;
END;
$$;

REVOKE ALL ON FUNCTION register_research_cycle_consumer(
    text, text, text, text, jsonb, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_research_cycle_scope_effect(
    uuid, text, text, text, text, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION assess_research_cycle_consumer(
    uuid, text, timestamptz, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION require_research_cycle_consumer_access(
    uuid, text, timestamptz, jsonb
) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON research_cycle_consumer_contract,
       research_cycle_scope_effect,
       research_cycle_scope_decision
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
