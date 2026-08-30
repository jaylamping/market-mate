-- Versioned Coverage Policy machinery from issue #14.
--
-- Policy definitions are append-only evidence.  The evaluator reads the
-- stored version; it cannot edit a version or create its own approval.  The
-- local-research role still owns the tables, so the write guards are paired
-- with explicit probes and the durable privilege split remains stage 2 work
-- per issue #97.

CREATE FUNCTION coverage_policy_number_at(value jsonb, path text[])
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN value #> path IS NULL OR jsonb_typeof(value #> path) <> 'number' THEN NULL
        ELSE (value #>> path)::numeric
    END;
$$;

CREATE FUNCTION coverage_policy_boolean_at(value jsonb, path text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN value #> path IS NULL OR jsonb_typeof(value #> path) <> 'boolean' THEN NULL
        ELSE (value #>> path)::boolean
    END;
$$;

CREATE FUNCTION coverage_policy_definition_is_valid(definition_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    numeric_value numeric;
BEGIN
    IF jsonb_typeof(definition_value) IS DISTINCT FROM 'object'
       OR definition_value->'capacity' IS NULL
       OR definition_value->'promotion' IS NULL
       OR definition_value->'demotion' IS NULL
       OR definition_value->'replacement' IS NULL
       OR definition_value->'enhanced_risk' IS NULL
       OR definition_value->'fitness_weights' IS NULL
       OR definition_value->'sector_limits' IS NULL
       OR definition_value->'stages' IS NULL
       OR definition_value->'capabilities' IS NULL THEN
        RETURN false;
    END IF;

    IF definition_value->'stages' <>
       '["discovery_pool","research_candidate","trade_eligible","mandatory_holding","exit_monitoring","archived"]'::jsonb
       OR definition_value->'capabilities' <>
       '["stock_eligible","options_eligible","both","none"]'::jsonb THEN
        RETURN false;
    END IF;

    IF coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_target']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_ceiling']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_trade_eligible']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_research_candidates']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'principal_pinned_overlay_max']) IS NULL
       OR coverage_policy_boolean_at(definition_value, ARRAY['capacity', 'mandatory_holdings_ignore_capacity']) IS NULL THEN
        RETURN false;
    END IF;
    IF coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_target']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_ceiling'])
            < coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_target'])
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_trade_eligible']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_research_candidates']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['capacity', 'principal_pinned_overlay_max']) < 0
       THEN
        RETURN false;
    END IF;

    IF coverage_policy_number_at(definition_value, ARRAY['promotion', 'forward_complete_sessions']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'research_candidate_archive_sessions']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'pin_review_days']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'pin_warning_days']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'exit_monitoring_min_days']) IS NULL
       OR jsonb_typeof(definition_value #> '{promotion,required_gates}') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    IF definition_value #> '{promotion,required_gates}' <>
       '["quality_floor","data","liquidity","diversification","no_unresolved_anomaly"]'::jsonb
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'forward_complete_sessions']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'research_candidate_archive_sessions']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'pin_review_days']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'pin_warning_days']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['promotion', 'exit_monitoring_min_days']) < 1 THEN
        RETURN false;
    END IF;

    IF coverage_policy_number_at(definition_value, ARRAY['demotion', 'eligibility_floor_failures']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_percentile']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_consecutive_sessions']) IS NULL
       OR coverage_policy_boolean_at(definition_value, ARRAY['demotion', 'hard_failure_immediate']) IS NULL THEN
        RETURN false;
    END IF;
    IF coverage_policy_number_at(definition_value, ARRAY['demotion', 'eligibility_floor_failures']) < 1
       OR coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_percentile']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_percentile']) >= 1
       OR coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_consecutive_sessions']) < 1 THEN
        RETURN false;
    END IF;

    IF coverage_policy_number_at(definition_value, ARRAY['replacement', 'minimum_fitness_delta']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['replacement', 'routine_churn_fraction']) IS NULL
       OR coverage_policy_boolean_at(definition_value, ARRAY['replacement', 'hard_failure_exempt']) IS NULL THEN
        RETURN false;
    END IF;
    IF coverage_policy_number_at(definition_value, ARRAY['replacement', 'minimum_fitness_delta']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['replacement', 'routine_churn_fraction']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['replacement', 'routine_churn_fraction']) > 1 THEN
        RETURN false;
    END IF;

    IF coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_risk']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_venue_min_utilization']) IS NULL
       OR coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_stock_only']) IS NULL
       OR coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_options_allowed']) IS NULL
       OR coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_margin_allowed']) IS NULL
       OR jsonb_typeof(definition_value #> '{enhanced_risk,required_research_gates}') IS DISTINCT FROM 'array' THEN
        RETURN false;
    END IF;
    IF definition_value #> '{enhanced_risk,required_research_gates}' <>
       '["identity","reporting","authorized_quote","liquidity_spread","settlement","manipulation","forward_paper"]'::jsonb
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']) > 1
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_risk']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization'])
            < coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization'])
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization']) > 0.02
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_venue_min_utilization']) > 0.02
       OR coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']) > 0.03
       OR coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_options_allowed'])
       OR coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_margin_allowed']) THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(definition_value->'fitness_weights') IS DISTINCT FROM 'object'
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'data_quality']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'stock_liquidity']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'observability']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'diversification']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'stability']) IS NULL THEN
        RETURN false;
    END IF;
    numeric_value := coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'data_quality'])
        + coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'stock_liquidity'])
        + coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'observability'])
        + coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'diversification'])
        + coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'stability']);
    IF numeric_value <> 100
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'data_quality']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'stock_liquidity']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'observability']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'diversification']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['fitness_weights', 'stability']) < 0 THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(definition_value->'sector_limits') IS DISTINCT FROM 'object'
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_min_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_max_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_absolute_max_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'energy_preference_min_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'energy_preference_max_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'ordinary_sector_max_fraction']) IS NULL
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'correlation_cluster_max_fraction']) IS NULL THEN
        RETURN false;
    END IF;
    IF coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_min_fraction']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_max_fraction']) > 1
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_absolute_max_fraction']) > 1
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_max_fraction'])
            > coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'technology_absolute_max_fraction'])
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'energy_preference_min_fraction']) < 0
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'energy_preference_min_fraction'])
            > coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'energy_preference_max_fraction'])
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'energy_preference_max_fraction']) > 1
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'ordinary_sector_max_fraction']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'ordinary_sector_max_fraction']) > 1
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'correlation_cluster_max_fraction']) <= 0
       OR coverage_policy_number_at(definition_value, ARRAY['sector_limits', 'correlation_cluster_max_fraction']) > 1 THEN
        RETURN false;
    END IF;

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE TABLE coverage_policy_version (
    policy_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_key text NOT NULL CHECK (btrim(policy_key) <> ''),
    version integer NOT NULL CHECK (version >= 1),
    definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    definition_digest text NOT NULL CHECK (definition_digest ~ '^[0-9a-f]{64}$'),
    effective_from timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (policy_key, version)
);

SELECT register_evidence_table('coverage_policy_version');

CREATE TABLE coverage_policy_approval (
    approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_version_id uuid NOT NULL REFERENCES coverage_policy_version(policy_version_id),
    approver_kind text NOT NULL CHECK (approver_kind IN ('principal')),
    approver_key text NOT NULL CHECK (btrim(approver_key) <> ''),
    approved_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (policy_version_id, approver_kind)
);

SELECT register_evidence_table('coverage_policy_approval');

CREATE TABLE coverage_policy_evaluation (
    evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_version_id uuid NOT NULL REFERENCES coverage_policy_version(policy_version_id),
    subject_key text NOT NULL CHECK (btrim(subject_key) <> ''),
    as_of_at timestamptz NOT NULL,
    input jsonb NOT NULL CHECK (jsonb_typeof(input) = 'object'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    decision_state text NOT NULL CHECK (decision_state IN ('admit', 'retain', 'promote', 'demote', 'archive', 'replace', 'block')),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('coverage_policy_evaluation');

CREATE FUNCTION guard_coverage_policy_version_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_policy_version is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.coverage_policy_version_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'coverage policy versions must be appended through append_coverage_policy_version'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION validate_coverage_policy_version_content() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NOT coverage_policy_definition_is_valid(NEW.definition) THEN
        RAISE EXCEPTION 'coverage policy definition does not satisfy the versioned policy contract'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.definition_digest <> encode(digest(NEW.definition::text, 'sha256'), 'hex') THEN
        RAISE EXCEPTION 'coverage policy definition digest does not match its content'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER coverage_policy_version_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON coverage_policy_version
FOR EACH ROW EXECUTE FUNCTION guard_coverage_policy_version_write();

CREATE TRIGGER coverage_policy_version_content_guard
BEFORE INSERT ON coverage_policy_version
FOR EACH ROW EXECUTE FUNCTION validate_coverage_policy_version_content();

CREATE TRIGGER coverage_policy_version_truncate_guard
BEFORE TRUNCATE ON coverage_policy_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION guard_coverage_policy_approval_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_policy_approval is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.coverage_policy_approval_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'coverage policy approvals must be recorded through record_coverage_policy_approval'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER coverage_policy_approval_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON coverage_policy_approval
FOR EACH ROW EXECUTE FUNCTION guard_coverage_policy_approval_write();

CREATE TRIGGER coverage_policy_approval_truncate_guard
BEFORE TRUNCATE ON coverage_policy_approval
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION guard_coverage_policy_evaluation_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_policy_evaluation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.coverage_policy_evaluation_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'coverage policy evaluations must be recorded through evaluate_coverage_policy'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER coverage_policy_evaluation_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON coverage_policy_evaluation
FOR EACH ROW EXECUTE FUNCTION guard_coverage_policy_evaluation_write();

CREATE TRIGGER coverage_policy_evaluation_truncate_guard
BEFORE TRUNCATE ON coverage_policy_evaluation
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION coverage_policy_evaluation_input_is_valid(input_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    key_value text;
    boolean_keys constant text[] := ARRAY[
        'system_selected', 'is_new_system_member',
        'quality_floor_pass', 'data_gate_pass', 'liquidity_gate_pass',
        'diversification_gate_pass', 'unresolved_anomaly', 'pinned',
        'has_open_obligation', 'hard_failure', 'is_enhanced_risk',
        'is_replacement', 'replacement_resolves_deficiency',
        'requested_live', 'requested_stock', 'requested_options',
        'enhanced_live_authorized', 'enhanced_live_exception_authorized'
    ];
    numeric_keys constant text[] := ARRAY[
        'system_selected_count', 'options_eligible_count',
        'trade_eligible_count', 'research_candidate_count',
        'forward_complete_sessions', 'eligibility_floor_failures',
        'bottom_fitness_sessions', 'candidate_sessions', 'fitness_percentile', 'incumbent_fitness',
        'replacement_fitness', 'routine_replacements_this_month',
        'enhanced_position_utilization', 'enhanced_position_risk',
        'enhanced_aggregate_utilization', 'venue_min_utilization'
    ];
    integer_keys constant text[] := ARRAY[
        'system_selected_count', 'options_eligible_count',
        'trade_eligible_count', 'research_candidate_count',
        'forward_complete_sessions', 'eligibility_floor_failures',
        'bottom_fitness_sessions', 'candidate_sessions',
        'routine_replacements_this_month'
    ];
BEGIN
    IF jsonb_typeof(input_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    FOREACH key_value IN ARRAY ARRAY[
        'current_stage', 'requested_stage', 'requested_capability'
    ] LOOP
        IF jsonb_typeof(input_value->key_value) IS DISTINCT FROM 'string'
           OR btrim(input_value->>key_value) = '' THEN
            RETURN false;
        END IF;
    END LOOP;
    IF NOT (input_value->>'current_stage' = ANY(ARRAY[
        'discovery_pool', 'research_candidate', 'trade_eligible',
        'mandatory_holding', 'exit_monitoring', 'archived'
    ]))
       OR NOT (input_value->>'requested_stage' = ANY(ARRAY[
        'discovery_pool', 'research_candidate', 'trade_eligible',
        'mandatory_holding', 'exit_monitoring', 'archived'
    ]))
       OR NOT (input_value->>'requested_capability' = ANY(ARRAY[
        'stock_eligible', 'options_eligible', 'both', 'none'
    ])) THEN
        RETURN false;
    END IF;
    FOREACH key_value IN ARRAY boolean_keys LOOP
        IF jsonb_typeof(input_value->key_value) IS DISTINCT FROM 'boolean' THEN
            RETURN false;
        END IF;
    END LOOP;
    FOREACH key_value IN ARRAY numeric_keys LOOP
        IF jsonb_typeof(input_value->key_value) IS DISTINCT FROM 'number' THEN
            RETURN false;
        END IF;
        IF (input_value->>key_value)::numeric < 0 THEN
            RETURN false;
        END IF;
        IF key_value = ANY(integer_keys)
           AND ((input_value->>key_value)::numeric <> trunc((input_value->>key_value)::numeric)
                OR (input_value->>key_value)::numeric > 2147483647) THEN
            RETURN false;
        END IF;
    END LOOP;
    IF jsonb_typeof(input_value->'options_gates') IS DISTINCT FROM 'object'
       OR jsonb_typeof(input_value->'enhanced_risk_gates') IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    FOREACH key_value IN ARRAY ARRAY[
        'approved_expirations', 'nbbo_quality', 'spreads', 'open_interest_volume',
        'lifecycle_metadata', 'defined_risk_execution'
    ] LOOP
        IF jsonb_typeof(input_value->'options_gates'->key_value) IS DISTINCT FROM 'boolean' THEN
            RETURN false;
        END IF;
    END LOOP;
    FOREACH key_value IN ARRAY ARRAY[
        'identity', 'reporting', 'authorized_quote', 'liquidity_spread',
        'settlement', 'manipulation', 'forward_paper'
    ] LOOP
        IF jsonb_typeof(input_value->'enhanced_risk_gates'->key_value) IS DISTINCT FROM 'boolean' THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE FUNCTION append_coverage_policy_version(
    policy_key_value text,
    version_value integer,
    definition_value jsonb,
    effective_from_value timestamptz,
    source_lineage_value jsonb
) RETURNS coverage_policy_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    expected_version integer;
    created coverage_policy_version%ROWTYPE;
BEGIN
    IF coalesce(btrim(policy_key_value), '') = '' OR version_value IS NULL OR version_value < 1
       OR effective_from_value IS NULL THEN
        RAISE EXCEPTION 'coverage policy version identity is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT coverage_policy_definition_is_valid(definition_value) THEN
        RAISE EXCEPTION 'coverage policy definition does not satisfy the versioned policy contract'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'coverage policy source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(policy_key_value, 22023));
    SELECT coalesce(max(version), 0) + 1
    INTO expected_version
    FROM coverage_policy_version
    WHERE policy_key = policy_key_value;
    IF version_value <> expected_version THEN
        RAISE EXCEPTION
            'coverage policy versions must advance consecutively: expected %, received %',
            expected_version, version_value
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.coverage_policy_version_write', 'on', true);
    BEGIN
        INSERT INTO coverage_policy_version (
            policy_key, version, definition, definition_digest,
            effective_from, source_lineage, receipt_time, record_environment
        ) VALUES (
            policy_key_value, version_value, definition_value,
            encode(digest(definition_value::text, 'sha256'), 'hex'),
            effective_from_value, source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.coverage_policy_version_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.coverage_policy_version_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION record_coverage_policy_approval(
    policy_version_id_value uuid,
    approver_kind_value text,
    approver_key_value text,
    source_lineage_value jsonb
) RETURNS coverage_policy_approval
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    policy_row coverage_policy_version%ROWTYPE;
    created coverage_policy_approval%ROWTYPE;
BEGIN
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = policy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage policy version % is not registered', policy_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF approver_kind_value <> 'principal'
       OR coalesce(btrim(approver_key_value), '') = ''
       OR lower(btrim(approver_key_value)) = lower(policy_row.policy_key) THEN
        RAISE EXCEPTION
            'coverage policy version cannot modify or promote itself; an independent Principal approval is required'
            USING ERRCODE = '55000';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'coverage policy approval source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.coverage_policy_approval_write', 'on', true);
    BEGIN
        INSERT INTO coverage_policy_approval (
            policy_version_id, approver_kind, approver_key, approved_at,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            policy_version_id_value, approver_kind_value, approver_key_value,
            clock_timestamp(), source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.coverage_policy_approval_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.coverage_policy_approval_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION evaluate_coverage_policy(
    policy_version_id_value uuid,
    subject_key_value text,
    as_of_value timestamptz,
    input_value jsonb,
    source_lineage_value jsonb
) RETURNS coverage_policy_evaluation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    policy_row coverage_policy_version%ROWTYPE;
    created coverage_policy_evaluation%ROWTYPE;
    definition_value jsonb;
    current_stage_value text;
    requested_stage_value text;
    requested_capability_value text;
    system_selected_count_value integer;
    options_eligible_count_value integer;
    trade_eligible_count_value integer;
    research_candidate_count_value integer;
    forward_sessions_value integer;
    floor_failures_value integer;
    bottom_fitness_sessions_value integer;
    candidate_sessions_value integer;
    fitness_percentile_value numeric;
    routine_replacements_value integer;
    incumbent_fitness_value numeric;
    replacement_fitness_value numeric;
    target_value integer;
    ceiling_value integer;
    max_trade_eligible_value integer;
    max_research_candidates_value integer;
    routine_replacement_limit_value integer;
    promotion_allowed_value boolean;
    admission_allowed_value boolean;
    demotion_required_value boolean;
    archive_allowed_value boolean;
    replacement_allowed_value boolean;
    options_gates_pass_value boolean;
    enhanced_gates_pass_value boolean;
    capability_request_valid_value boolean;
    enhanced_research_allowed_value boolean;
    enhanced_live_gate_pass_value boolean;
    live_authority_granted_value boolean := false;
    approved_value boolean;
    decision_state_value text;
    next_stage_value text;
    result_value jsonb;
BEGIN
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = policy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage policy version % is not registered', policy_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF coalesce(btrim(subject_key_value), '') = '' OR as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR as_of_value < policy_row.effective_from THEN
        RAISE EXCEPTION 'coverage policy evaluation identity or as_of time is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT coverage_policy_evaluation_input_is_valid(input_value) THEN
        RAISE EXCEPTION
            'coverage policy evaluation input is incomplete or has an invalid type'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'coverage policy evaluation source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    definition_value := policy_row.definition;
    current_stage_value := input_value->>'current_stage';
    requested_stage_value := input_value->>'requested_stage';
    requested_capability_value := input_value->>'requested_capability';
    system_selected_count_value := (input_value->>'system_selected_count')::integer;
    options_eligible_count_value := (input_value->>'options_eligible_count')::integer;
    trade_eligible_count_value := (input_value->>'trade_eligible_count')::integer;
    research_candidate_count_value := (input_value->>'research_candidate_count')::integer;
    forward_sessions_value := (input_value->>'forward_complete_sessions')::integer;
    floor_failures_value := (input_value->>'eligibility_floor_failures')::integer;
    bottom_fitness_sessions_value := (input_value->>'bottom_fitness_sessions')::integer;
    candidate_sessions_value := (input_value->>'candidate_sessions')::integer;
    fitness_percentile_value := (input_value->>'fitness_percentile')::numeric;
    routine_replacements_value := (input_value->>'routine_replacements_this_month')::integer;
    incumbent_fitness_value := (input_value->>'incumbent_fitness')::numeric;
    replacement_fitness_value := (input_value->>'replacement_fitness')::numeric;
    target_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_target'])::integer;
    ceiling_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'system_selected_ceiling'])::integer;
    max_trade_eligible_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_trade_eligible'])::integer;
    max_research_candidates_value := coverage_policy_number_at(definition_value, ARRAY['capacity', 'max_research_candidates'])::integer;
    routine_replacement_limit_value := ceil(
        target_value * coverage_policy_number_at(definition_value, ARRAY['replacement', 'routine_churn_fraction'])
    )::integer;
    approved_value := EXISTS (
        SELECT 1 FROM coverage_policy_approval
        WHERE policy_version_id = policy_version_id_value
          AND approved_at <= as_of_value
    );

    options_gates_pass_value := (input_value->'options_gates'->>'approved_expirations')::boolean
        AND (input_value->'options_gates'->>'nbbo_quality')::boolean
        AND (input_value->'options_gates'->>'spreads')::boolean
        AND (input_value->'options_gates'->>'open_interest_volume')::boolean
        AND (input_value->'options_gates'->>'lifecycle_metadata')::boolean
        AND (input_value->'options_gates'->>'defined_risk_execution')::boolean;
    enhanced_gates_pass_value := (input_value->'enhanced_risk_gates'->>'identity')::boolean
        AND (input_value->'enhanced_risk_gates'->>'reporting')::boolean
        AND (input_value->'enhanced_risk_gates'->>'authorized_quote')::boolean
        AND (input_value->'enhanced_risk_gates'->>'liquidity_spread')::boolean
        AND (input_value->'enhanced_risk_gates'->>'settlement')::boolean
        AND (input_value->'enhanced_risk_gates'->>'manipulation')::boolean
        AND (input_value->'enhanced_risk_gates'->>'forward_paper')::boolean;
    capability_request_valid_value :=
        (requested_capability_value = 'stock_eligible'
            AND (input_value->>'requested_stock')::boolean
            AND NOT (input_value->>'requested_options')::boolean)
        OR (requested_capability_value = 'options_eligible'
            AND NOT (input_value->>'requested_stock')::boolean
            AND (input_value->>'requested_options')::boolean)
        OR (requested_capability_value = 'both'
            AND (input_value->>'requested_stock')::boolean
            AND (input_value->>'requested_options')::boolean)
        OR (requested_capability_value = 'none'
            AND NOT (input_value->>'requested_stock')::boolean
            AND NOT (input_value->>'requested_options')::boolean);

    demotion_required_value := ((input_value->>'hard_failure')::boolean
            AND coverage_policy_boolean_at(definition_value, ARRAY['demotion', 'hard_failure_immediate']))
        OR floor_failures_value >= coverage_policy_number_at(definition_value, ARRAY['demotion', 'eligibility_floor_failures'])
        OR (
            fitness_percentile_value <= coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_percentile'])
            AND bottom_fitness_sessions_value >= coverage_policy_number_at(definition_value, ARRAY['demotion', 'bottom_fitness_consecutive_sessions'])
        );

    admission_allowed_value := approved_value
        AND current_stage_value = 'discovery_pool'
        AND requested_stage_value = 'research_candidate'
        AND NOT demotion_required_value
        AND NOT (input_value->>'has_open_obligation')::boolean
        AND (NOT (input_value->>'is_new_system_member')::boolean
             OR NOT (input_value->>'system_selected')::boolean
             OR system_selected_count_value < target_value)
        AND system_selected_count_value < ceiling_value
        AND research_candidate_count_value < max_research_candidates_value
        AND (input_value->>'quality_floor_pass')::boolean
        AND (input_value->>'data_gate_pass')::boolean
        AND (input_value->>'liquidity_gate_pass')::boolean
        AND (input_value->>'diversification_gate_pass')::boolean
        AND NOT (input_value->>'unresolved_anomaly')::boolean
        AND capability_request_valid_value
        AND (NOT (input_value->>'is_enhanced_risk')::boolean OR enhanced_gates_pass_value);

    promotion_allowed_value := approved_value
        AND current_stage_value = 'research_candidate'
        AND requested_stage_value = 'trade_eligible'
        AND NOT (input_value->>'is_enhanced_risk')::boolean
        AND forward_sessions_value >= coverage_policy_number_at(definition_value, ARRAY['promotion', 'forward_complete_sessions'])
        AND (input_value->>'quality_floor_pass')::boolean
        AND (input_value->>'data_gate_pass')::boolean
        AND (input_value->>'liquidity_gate_pass')::boolean
        AND (input_value->>'diversification_gate_pass')::boolean
        AND NOT (input_value->>'unresolved_anomaly')::boolean
        AND system_selected_count_value <= ceiling_value
        AND trade_eligible_count_value < max_trade_eligible_value
        AND capability_request_valid_value
        AND (requested_capability_value <> 'options_eligible' OR options_gates_pass_value)
        AND (requested_capability_value <> 'both' OR options_gates_pass_value)
        AND NOT demotion_required_value;
    archive_allowed_value := approved_value
        AND current_stage_value = 'research_candidate'
        AND requested_stage_value = 'archived'
        AND NOT (input_value->>'pinned')::boolean
        AND NOT (input_value->>'has_open_obligation')::boolean
        AND candidate_sessions_value >= coverage_policy_number_at(definition_value, ARRAY['promotion', 'research_candidate_archive_sessions']);
    replacement_allowed_value := approved_value
        AND (input_value->>'is_replacement')::boolean
        AND (
            replacement_fitness_value >= incumbent_fitness_value
                + coverage_policy_number_at(definition_value, ARRAY['replacement', 'minimum_fitness_delta'])
            OR (input_value->>'replacement_resolves_deficiency')::boolean
        )
        AND (
            ((input_value->>'hard_failure')::boolean
                AND coverage_policy_boolean_at(definition_value, ARRAY['replacement', 'hard_failure_exempt']))
            OR routine_replacements_value < routine_replacement_limit_value
        );
    enhanced_research_allowed_value := approved_value
        AND (input_value->>'is_enhanced_risk')::boolean
        AND requested_stage_value = 'research_candidate'
        AND enhanced_gates_pass_value;
    enhanced_live_gate_pass_value := approved_value
        AND (input_value->>'is_enhanced_risk')::boolean
        AND (input_value->>'requested_live')::boolean
        AND (input_value->>'enhanced_live_authorized')::boolean
        AND enhanced_gates_pass_value
        AND (input_value->>'requested_stock')::boolean
        AND NOT (input_value->>'requested_options')::boolean
        AND (
            (
                (input_value->>'enhanced_position_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization'])
                AND (input_value->>'venue_min_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization'])
            )
            OR (
                (input_value->>'enhanced_live_exception_authorized')::boolean
                AND
                (input_value->>'enhanced_position_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization'])
                AND (input_value->>'venue_min_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_venue_min_utilization'])
            )
        )
        AND (input_value->>'enhanced_position_risk')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_risk'])
        AND (input_value->>'enhanced_aggregate_utilization')::numeric <= coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']);

    IF (input_value->>'has_open_obligation')::boolean THEN
        next_stage_value := 'mandatory_holding';
        decision_state_value := 'retain';
    ELSIF NOT approved_value THEN
        next_stage_value := current_stage_value;
        decision_state_value := 'block';
    ELSIF demotion_required_value AND current_stage_value = 'trade_eligible' THEN
        next_stage_value := 'research_candidate';
        decision_state_value := 'demote';
    ELSIF archive_allowed_value THEN
        next_stage_value := 'archived';
        decision_state_value := 'archive';
    ELSIF promotion_allowed_value THEN
        next_stage_value := 'trade_eligible';
        decision_state_value := 'promote';
    ELSIF admission_allowed_value THEN
        next_stage_value := 'research_candidate';
        decision_state_value := 'admit';
    ELSIF replacement_allowed_value THEN
        next_stage_value := current_stage_value;
        decision_state_value := 'replace';
    ELSE
        next_stage_value := current_stage_value;
        decision_state_value := 'block';
    END IF;

    result_value := jsonb_build_object(
        'policy_key', policy_row.policy_key,
        'policy_version', policy_row.version,
        'policy_approved', approved_value,
        'capacity', jsonb_build_object(
            'system_selected_target', target_value,
            'system_selected_ceiling', ceiling_value,
            'system_selected_count', system_selected_count_value,
            'max_trade_eligible', max_trade_eligible_value,
            'trade_eligible_count', trade_eligible_count_value,
            'max_research_candidates', max_research_candidates_value,
            'research_candidate_count', research_candidate_count_value,
            'target_reached', system_selected_count_value >= target_value,
            'ceiling_reached', system_selected_count_value >= ceiling_value,
            'automatic_net_new_frozen', system_selected_count_value >= target_value,
            'routine_replacement_limit', routine_replacement_limit_value,
            'options_target_fraction', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']),
            'options_target_met', options_eligible_count_value >= ceil(system_selected_count_value * coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'options_target_fraction']))
        ),
        'stage', jsonb_build_object(
            'current', current_stage_value,
            'requested', requested_stage_value,
            'next', next_stage_value,
            'admission_allowed', admission_allowed_value,
            'promotion_allowed', promotion_allowed_value,
            'demotion_required', demotion_required_value,
            'archive_allowed', archive_allowed_value,
            'mandatory_holding_preserved', (input_value->>'has_open_obligation')::boolean
        ),
        'capability', jsonb_build_object(
            'requested', requested_capability_value,
            'options_gates_pass', options_gates_pass_value,
            'request_shape_valid', capability_request_valid_value,
            'allowed', approved_value
                AND capability_request_valid_value
                AND (requested_capability_value IN ('stock_eligible', 'none')
                    OR (requested_capability_value IN ('options_eligible', 'both') AND options_gates_pass_value))
        ),
        'replacement', jsonb_build_object(
            'is_replacement', (input_value->>'is_replacement')::boolean,
            'minimum_fitness_delta', coverage_policy_number_at(definition_value, ARRAY['replacement', 'minimum_fitness_delta']),
            'replacement_allowed', replacement_allowed_value,
            'hard_failure_exempt_from_routine_churn', coverage_policy_boolean_at(definition_value, ARRAY['replacement', 'hard_failure_exempt'])
        ),
        'enhanced_risk', jsonb_build_object(
            'research_gates_pass', enhanced_gates_pass_value,
            'research_allowed', enhanced_research_allowed_value,
            'live_gate_pass', enhanced_live_gate_pass_value,
            'live_authority_granted', live_authority_granted_value,
            'live_requires_separate_authorization', true,
            'live_stock_only', coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_stock_only']),
            'live_options_allowed', coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_options_allowed']),
            'live_margin_allowed', coverage_policy_boolean_at(definition_value, ARRAY['enhanced_risk', 'live_margin_allowed']),
            'max_position_utilization', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_utilization']),
            'max_position_risk', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_position_risk']),
            'max_aggregate_utilization', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'live_max_aggregate_utilization']),
            'exception_max_position_utilization', coverage_policy_number_at(definition_value, ARRAY['enhanced_risk', 'exception_max_position_utilization'])
        ),
        'fitness_weights', definition_value->'fitness_weights',
        'sector_limits', definition_value->'sector_limits'
    );

    PERFORM set_config('market_mate.coverage_policy_evaluation_write', 'on', true);
    BEGIN
        INSERT INTO coverage_policy_evaluation (
            policy_version_id, subject_key, as_of_at, input, result,
            decision_state, source_lineage, receipt_time, record_environment
        ) VALUES (
            policy_version_id_value, subject_key_value, as_of_value, input_value, result_value,
            decision_state_value, source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.coverage_policy_evaluation_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.coverage_policy_evaluation_write', 'off', true);
    RETURN created;
END;
$$;

-- The baseline is the exact issue #14 policy resolution.  Future policy
-- versions are separate rows and require a fresh Principal approval.
SELECT append_coverage_policy_version(
    'coverage-policy',
    1,
    $$
    {
      "policy_name": "coverage-universe-v1",
      "stages": ["discovery_pool", "research_candidate", "trade_eligible", "mandatory_holding", "exit_monitoring", "archived"],
      "capabilities": ["stock_eligible", "options_eligible", "both", "none"],
      "capacity": {
        "system_selected_target": 40,
        "system_selected_ceiling": 50,
        "max_trade_eligible": 25,
        "max_research_candidates": 15,
        "principal_pinned_overlay_max": 5,
        "mandatory_holdings_ignore_capacity": true
      },
      "promotion": {
        "forward_complete_sessions": 20,
        "research_candidate_archive_sessions": 60,
        "pin_review_days": 30,
        "pin_warning_days": 7,
        "exit_monitoring_min_days": 20,
        "required_gates": ["quality_floor", "data", "liquidity", "diversification", "no_unresolved_anomaly"]
      },
      "demotion": {
        "hard_failure_immediate": true,
        "eligibility_floor_failures": 3,
        "bottom_fitness_percentile": 0.20,
        "bottom_fitness_consecutive_sessions": 10
      },
      "replacement": {
        "minimum_fitness_delta": 10,
        "routine_churn_fraction": 0.10,
        "hard_failure_exempt": true
      },
      "enhanced_risk": {
        "options_target_fraction": 0.60,
        "required_research_gates": ["identity", "reporting", "authorized_quote", "liquidity_spread", "settlement", "manipulation", "forward_paper"],
        "live_max_position_utilization": 0.01,
        "live_max_position_risk": 0.005,
        "live_max_aggregate_utilization": 0.03,
        "exception_max_position_utilization": 0.02,
        "exception_venue_min_utilization": 0.02,
        "live_stock_only": true,
        "live_options_allowed": false,
        "live_margin_allowed": false
      },
      "fitness_weights": {
        "data_quality": 30,
        "stock_liquidity": 30,
        "observability": 15,
        "diversification": 15,
        "stability": 10
      },
      "sector_limits": {
        "technology_min_fraction": 0.30,
        "technology_max_fraction": 0.50,
        "technology_absolute_max_fraction": 0.50,
        "energy_preference_min_fraction": 0.10,
        "energy_preference_max_fraction": 0.20,
        "ordinary_sector_max_fraction": 0.30,
        "correlation_cluster_max_fraction": 0.40
      }
    }
    $$::jsonb,
    '2026-01-01T00:00:00Z'::timestamptz,
    '{"source":"wu22-migration","entitlement_version":"coverage-policy-v1"}'::jsonb
);

REVOKE ALL ON FUNCTION append_coverage_policy_version(text, integer, jsonb, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION record_coverage_policy_approval(uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION evaluate_coverage_policy(uuid, text, timestamptz, jsonb, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON coverage_policy_version, coverage_policy_approval, coverage_policy_evaluation
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
