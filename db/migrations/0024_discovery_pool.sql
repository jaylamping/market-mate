-- WU-23 Discovery Pool screener: the versioned, point-in-time investable
-- universe and its inexpensive daily screen (issue #14, work unit WU-23).
--
-- The Discovery Pool receives cheap screening only -- no sentiment
-- collection, no trade consideration.  Every run stores its full decision
-- set (included and rejected, with reasons) so historical membership,
-- rejections, and enhanced-risk classifications survive as evidence for
-- point-in-time replay.  The screener reads only already-admitted evidence
-- (Certified identity mappings and entitlement-gated EOD observations) and
-- fails closed: missing data is a recorded rejection reason, never silence.
--
-- The run function and the read-only preview share one decision core, so
-- replay of stored evidence reproduces the stored run byte-for-byte.

CREATE FUNCTION discovery_screen_definition_is_valid(definition_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF jsonb_typeof(definition_value) IS DISTINCT FROM 'object'
       OR definition_value->'lookback_sessions' IS NULL
       OR definition_value->'min_close_price' IS NULL
       OR definition_value->'penny_price_ceiling' IS NULL
       OR definition_value->'min_median_dollar_volume' IS NULL
       OR definition_value->'allowed_security_classes' IS NULL
       OR definition_value->'ordinary_venues' IS NULL
       OR definition_value->'governing_policy_key' IS NULL THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(definition_value->'allowed_security_classes') IS DISTINCT FROM 'array'
       OR jsonb_typeof(definition_value->'ordinary_venues') IS DISTINCT FROM 'array'
       OR jsonb_typeof(definition_value->'governing_policy_key') IS DISTINCT FROM 'string' THEN
        RETURN false;
    END IF;

    IF (SELECT count(*) FROM jsonb_array_elements_text(definition_value->'allowed_security_classes') c)
           <> jsonb_array_length(definition_value->'allowed_security_classes')
       OR EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(definition_value->'allowed_security_classes') c
            WHERE c.value IS NULL OR btrim(c.value) = ''
       )
       OR (SELECT count(*) FROM jsonb_array_elements_text(definition_value->'allowed_security_classes') c) = 0 THEN
        RETURN false;
    END IF;
    IF (SELECT count(*) FROM jsonb_array_elements_text(definition_value->'ordinary_venues') c) = 0
       OR EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(definition_value->'ordinary_venues') c
            WHERE c.value IS NULL OR btrim(c.value) = ''
       ) THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(definition_value->'lookback_sessions') <> 'number'
       OR (definition_value->>'lookback_sessions') !~ '^[0-9]+$'
       OR (definition_value->'lookback_sessions')::numeric < 5
       OR (definition_value->'lookback_sessions')::numeric > 252 THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(definition_value->'min_close_price') <> 'number'
       OR jsonb_typeof(definition_value->'penny_price_ceiling') <> 'number'
       OR jsonb_typeof(definition_value->'min_median_dollar_volume') <> 'number' THEN
        RETURN false;
    END IF;
    IF (definition_value->'min_close_price')::numeric <= 0
       OR (definition_value->'penny_price_ceiling')::numeric < 0
       OR (definition_value->'min_median_dollar_volume')::numeric < 0 THEN
        RETURN false;
    END IF;
    -- A penny-priced security is tagged enhanced-risk, never rejected by
    -- price alone; the ordinary price floor must sit at or above the penny
    -- ceiling so tagging is the only effect of falling below it.
    IF (definition_value->'penny_price_ceiling')::numeric
         > (definition_value->'min_close_price')::numeric THEN
        RETURN false;
    END IF;
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

CREATE TABLE discovery_universe_entry (
    entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    universe_key text NOT NULL CHECK (btrim(universe_key) <> ''),
    membership_kind text NOT NULL CHECK (membership_kind IN ('index_constituent', 'principal_holding', 'obligation')),
    security_id uuid NOT NULL REFERENCES security(security_id),
    known_from date NOT NULL,
    known_to date,
    universe_evidence_key text NOT NULL CHECK (btrim(universe_evidence_key) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (known_to IS NULL OR known_to > known_from),
    UNIQUE (universe_key, security_id, known_from)
);

SELECT register_evidence_table('discovery_universe_entry');

CREATE TABLE discovery_screen_config_version (
    config_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    config_key text NOT NULL CHECK (btrim(config_key) <> ''),
    version integer NOT NULL CHECK (version >= 1),
    governing_policy_version_id uuid NOT NULL
        REFERENCES coverage_policy_version(policy_version_id),
    definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    definition_digest text NOT NULL CHECK (definition_digest ~ '^[0-9a-f]{64}$'),
    effective_from timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (definition_digest = encode(digest(convert_to(definition::text, 'UTF8'), 'sha256'), 'hex')),
    UNIQUE (config_key, version)
);

SELECT register_evidence_table('discovery_screen_config_version');

CREATE TABLE discovery_screen_run (
    run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    config_version_id uuid NOT NULL REFERENCES discovery_screen_config_version(config_version_id),
    trading_date date NOT NULL,
    as_of_at timestamptz NOT NULL,
    screen_state text NOT NULL CHECK (screen_state IN ('complete', 'failed')),
    universe_count integer NOT NULL CHECK (universe_count >= 0),
    included_count integer NOT NULL CHECK (included_count >= 0),
    rejected_count integer NOT NULL CHECK (rejected_count >= 0),
    enhanced_risk_count integer NOT NULL CHECK (enhanced_risk_count >= 0),
    failure_reason text,
    run_digest text NOT NULL CHECK (run_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (screen_state <> 'failed' OR failure_reason IS NOT NULL),
    CHECK (universe_count = included_count + rejected_count),
    UNIQUE (config_version_id, trading_date)
);

SELECT register_evidence_table('discovery_screen_run');

CREATE TABLE discovery_pool_membership (
    membership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES discovery_screen_run(run_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    decision text NOT NULL CHECK (decision IN ('included', 'rejected')),
    enhanced_risk boolean NOT NULL DEFAULT false,
    screen_facts jsonb NOT NULL CHECK (jsonb_typeof(screen_facts) = 'object'),
    rejection_reasons text[] NOT NULL DEFAULT '{}'
        CHECK (rejection_reasons <@ ARRAY[
            'identity_not_certified', 'identity_conflict', 'listing_not_active',
            'instrument_class_excluded', 'insufficient_data',
            'price_below_minimum', 'liquidity_below_floor']),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (decision = 'included' AND cardinality(rejection_reasons) = 0)
        OR (decision = 'rejected' AND cardinality(rejection_reasons) >= 1)
    ),
    CHECK (enhanced_risk = false OR decision = 'included'),
    UNIQUE (run_id, security_id)
);

SELECT register_evidence_table('discovery_pool_membership');

CREATE INDEX discovery_universe_entry_security_idx
    ON discovery_universe_entry (security_id, known_from, known_to);
CREATE INDEX discovery_pool_membership_run_idx
    ON discovery_pool_membership (run_id, decision, security_id);

CREATE FUNCTION guard_discovery_universe_entry_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'discovery_universe_entry is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_discovery_screen_config_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'discovery_screen_config_version is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_discovery_screen_run_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'discovery_screen_run is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_discovery_pool_membership_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'discovery_pool_membership is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER discovery_universe_entry_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON discovery_universe_entry
    FOR EACH STATEMENT EXECUTE FUNCTION guard_discovery_universe_entry_write();
CREATE TRIGGER discovery_screen_config_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON discovery_screen_config_version
    FOR EACH STATEMENT EXECUTE FUNCTION guard_discovery_screen_config_write();
CREATE TRIGGER discovery_screen_run_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON discovery_screen_run
    FOR EACH STATEMENT EXECUTE FUNCTION guard_discovery_screen_run_write();
CREATE TRIGGER discovery_pool_membership_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON discovery_pool_membership
    FOR EACH STATEMENT EXECUTE FUNCTION guard_discovery_pool_membership_write();

CREATE FUNCTION append_discovery_universe_entry(
    universe_key_value text,
    membership_kind_value text,
    security_id_value uuid,
    known_from_value date,
    known_to_value date,
    universe_evidence_key_value text,
    source_lineage_value jsonb
) RETURNS discovery_universe_entry
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created discovery_universe_entry%ROWTYPE;
BEGIN
    IF coalesce(btrim(universe_key_value), '') = '' OR coalesce(btrim(universe_evidence_key_value), '') = ''
       OR membership_kind_value NOT IN ('index_constituent', 'principal_holding', 'obligation')
       OR security_id_value IS NULL
       OR known_from_value IS NULL
       OR (known_to_value IS NOT NULL AND known_to_value <= known_from_value)
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'discovery universe entry arguments are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM security WHERE security_id = security_id_value) THEN
        RAISE EXCEPTION 'discovery universe entry security % is not registered', security_id_value
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO discovery_universe_entry (
        universe_key, membership_kind, security_id,
        known_from, known_to, universe_evidence_key,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        universe_key_value, membership_kind_value, security_id_value,
        known_from_value, known_to_value, universe_evidence_key_value,
        source_lineage_value, now(), 'local_research'
    )
    ON CONFLICT (universe_key, security_id, known_from) DO NOTHING
    RETURNING * INTO created;

    IF NOT FOUND THEN
        SELECT * INTO created
        FROM discovery_universe_entry
        WHERE universe_key = universe_key_value
          AND security_id = security_id_value
          AND known_from = known_from_value;
    END IF;
    RETURN created;
END;
$$;

CREATE FUNCTION append_discovery_screen_config_version(
    config_key_value text,
    version_value integer,
    governing_policy_version_id_value uuid,
    definition_value jsonb,
    effective_from_value timestamptz,
    source_lineage_value jsonb
) RETURNS discovery_screen_config_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created discovery_screen_config_version%ROWTYPE;
BEGIN
    IF coalesce(btrim(config_key_value), '') = ''
       OR version_value IS NULL OR version_value < 1
       OR governing_policy_version_id_value IS NULL
       OR effective_from_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'discovery screen config arguments are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT discovery_screen_definition_is_valid(definition_value) THEN
        RAISE EXCEPTION 'discovery screen config definition is incomplete or out of bounds'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM coverage_policy_version
        WHERE policy_version_id = governing_policy_version_id_value
    ) THEN
        RAISE EXCEPTION 'governing coverage policy version % is not registered',
            governing_policy_version_id_value USING ERRCODE = '22023';
    END IF;
    IF definition_value->>'governing_policy_key' IS DISTINCT FROM (
        SELECT policy_key FROM coverage_policy_version
        WHERE policy_version_id = governing_policy_version_id_value
    ) THEN
        RAISE EXCEPTION 'discovery screen config must bind the definition to its governing policy key'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO discovery_screen_config_version (
        config_key, version, governing_policy_version_id,
        definition, definition_digest, effective_from,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        config_key_value, version_value, governing_policy_version_id_value,
        definition_value,
        encode(digest(convert_to(definition_value::text, 'UTF8'), 'sha256'), 'hex'),
        effective_from_value,
        source_lineage_value, now(), 'local_research'
    )
    RETURNING * INTO created;
    RETURN created;
END;
$$;

CREATE FUNCTION discovery_screen_decision_preview(
    config_version_id_value uuid,
    trading_date_value date,
    as_of_value timestamptz
) RETURNS TABLE (
    security_id uuid,
    decision text,
    enhanced_risk boolean,
    screen_facts jsonb,
    rejection_reasons text[]
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    config_row discovery_screen_config_version%ROWTYPE;
    definition_value jsonb;
    session_dates date[];
    session_count integer;
    universe_security_ids uuid[];
    security_id_value uuid;
    class_value text;
    certified_mapping_ids uuid[];
    listing_row exchange_listing%ROWTYPE;
    mapping_id_value uuid;
    bar eod_price_observation%ROWTYPE;
    complete_sessions integer;
    observed_sessions integer;
    last_bar eod_price_observation%ROWTYPE;
    median_dollar_volume numeric;
    dollar_volumes numeric[];
    identity_reason text;
    venue_value text;
    enhanced_risk_value boolean;
    reasons text[];
    facts jsonb;
    listing_found boolean;
    last_bar_found boolean;
    i integer;
BEGIN
    SELECT * INTO config_row
    FROM discovery_screen_config_version
    WHERE config_version_id = config_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'discovery screen config % is not registered', config_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF as_of_value IS NULL OR trading_date_value IS NULL THEN
        RAISE EXCEPTION 'discovery screen preview times are required' USING ERRCODE = '22023';
    END IF;
    definition_value := config_row.definition;
    session_count := (definition_value->'lookback_sessions')::integer;

    SELECT coalesce(array_agg(d ORDER BY d), '{}')
    INTO session_dates
    FROM (
        SELECT DISTINCT o.trading_date AS d
        FROM eod_price_observation o
        WHERE o.trading_date <= trading_date_value
          AND o.available_at <= as_of_value
          AND o.receipt_time <= as_of_value
        ORDER BY o.trading_date DESC
        LIMIT session_count
    ) sessions;

    IF coalesce(array_length(session_dates, 1), 0) < session_count THEN
        RAISE EXCEPTION
            'discovery screen calendar has only % complete sessions; % required (fail closed)',
            coalesce(array_length(session_dates, 1), 0), session_count
            USING ERRCODE = '22023';
    END IF;

    FOR security_id_value IN
        SELECT DISTINCT e.security_id
        FROM discovery_universe_entry e
        WHERE e.known_from <= trading_date_value
          AND (e.known_to IS NULL OR e.known_to >= trading_date_value)
          AND e.receipt_time <= as_of_value
        ORDER BY e.security_id
    LOOP
        reasons := '{}';
        enhanced_risk_value := false;
        facts := '{}'::jsonb;
        class_value := NULL;
        venue_value := NULL;
        certified_mapping_ids := '{}';
        complete_sessions := 0;
        dollar_volumes := NULL;
        last_bar := NULL;
        listing_row := NULL;
        listing_found := false;
        last_bar_found := false;

        SELECT s.security_class INTO class_value
        FROM security s
        WHERE s.security_id = security_id_value;

        SELECT array_agg(m.mapping_id ORDER BY m.mapping_id)
        INTO certified_mapping_ids
        FROM certified_instrument_mapping m
        WHERE m.security_id = security_id_value
          AND m.object_kind = 'security'
          AND m.valid_from <= as_of_value
          AND (m.valid_to IS NULL OR m.valid_to > as_of_value);

        facts := facts
            || jsonb_build_object('security_class', class_value)
            || jsonb_build_object('certified_identity_count',
                coalesce(array_length(certified_mapping_ids, 1), 0));

        SELECT * INTO listing_row
        FROM exchange_listing l
        WHERE l.security_id = security_id_value
          AND l.listing_status = 'active'
          AND l.valid_from <= as_of_value
          AND (l.valid_to IS NULL OR l.valid_to > as_of_value)
        ORDER BY l.listing_id
        LIMIT 1;
        listing_found := FOUND;

        IF certified_mapping_ids IS NULL OR array_length(certified_mapping_ids, 1) = 0 THEN
            reasons := reasons || 'identity_not_certified'::text;
        ELSIF array_length(certified_mapping_ids, 1) > 1 THEN
            reasons := reasons || 'identity_conflict'::text;
        ELSE
            FOR i IN 1 .. session_count LOOP
                SELECT * INTO bar
                FROM eod_price_observation_at(certified_mapping_ids[1], session_dates[i], as_of_value);
                CONTINUE WHEN NOT FOUND;
                IF bar.observation_status IN ('complete', 'revised')
                   AND bar.close_price IS NOT NULL AND bar.volume IS NOT NULL THEN
                    complete_sessions := complete_sessions + 1;
                    dollar_volumes := coalesce(dollar_volumes, '{}')
                        || (bar.close_price * bar.volume);
                    last_bar := bar;
                    last_bar_found := true;
                END IF;
            END LOOP;
            facts := facts
                || jsonb_build_object(
                    'observed_sessions', coalesce(array_length(coalesce(dollar_volumes, '{}'), 1), 0),
                    'complete_sessions', complete_sessions,
                    'lookback_last_session', CASE WHEN last_bar_found
                        THEN last_bar.trading_date ELSE NULL END,
                    'last_close', CASE WHEN last_bar_found
                        THEN last_bar.close_price ELSE NULL END);
        END IF;

        IF listing_found THEN
            venue_value := listing_row.venue;
            facts := facts || jsonb_build_object('venue', venue_value, 'listing_status', 'active');
            IF NOT (venue_value = ANY (
                    SELECT jsonb_array_elements_text(definition_value->'ordinary_venues'))) THEN
                enhanced_risk_value := true;
            END IF;
        ELSE
            facts := facts || jsonb_build_object('listing_status', 'none_active');
            reasons := reasons || 'listing_not_active'::text;
        END IF;

        IF class_value IS NULL
           OR NOT (class_value = ANY (
                SELECT jsonb_array_elements_text(definition_value->'allowed_security_classes'))) THEN
            facts := facts || jsonb_build_object('security_class_observed', class_value);
            reasons := reasons || 'instrument_class_excluded'::text;
        END IF;

        IF complete_sessions < session_count THEN
            facts := facts || jsonb_build_object('complete_sessions', complete_sessions);
            reasons := reasons || 'insufficient_data'::text;
        ELSE
            IF last_bar.close_price < (definition_value->'penny_price_ceiling')::numeric THEN
                enhanced_risk_value := true;
            ELSIF last_bar.close_price < (definition_value->'min_close_price')::numeric THEN
                reasons := reasons || 'price_below_minimum'::text;
            END IF;
            IF (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
                FROM unnest(dollar_volumes) AS v)
                   < (definition_value->'min_median_dollar_volume')::numeric THEN
                reasons := reasons || 'liquidity_below_floor'::text;
            END IF;
            facts := facts
                || jsonb_build_object('median_dollar_volume',
                    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
                     FROM unnest(dollar_volumes) AS v))
                || jsonb_build_object('last_close', last_bar.close_price);
        END IF;

        security_id := security_id_value;
        decision := CASE WHEN cardinality(reasons) = 0 THEN 'included' ELSE 'rejected' END;
        enhanced_risk := enhanced_risk_value;
        screen_facts := facts;
        rejection_reasons := reasons;
        RETURN NEXT;
    END LOOP;
END;
$$;

CREATE FUNCTION run_discovery_screen(
    config_version_id_value uuid,
    trading_date_value date,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS discovery_screen_run
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    config_row discovery_screen_config_version%ROWTYPE;
    created_run discovery_screen_run%ROWTYPE;
    decision_row record;
    universe_count_value integer := 0;
    included_count_value integer := 0;
    enhanced_risk_count_value integer := 0;
    rejected_count_value integer := 0;
    failure_reason_value text := NULL;
    session_count_value integer;
    decisions_payload jsonb := '[]'::jsonb;
    run_digest_value text;
    policy_row coverage_policy_version%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'discovery screen run source_lineage is invalid' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO config_row
    FROM discovery_screen_config_version
    WHERE config_version_id = config_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'discovery screen config % is not registered', config_version_id_value
            USING ERRCODE = '22023';
    END IF;
    IF trading_date_value IS NULL OR as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR as_of_value < config_row.effective_from THEN
        RAISE EXCEPTION 'discovery screen run trading date or as_of time is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM discovery_screen_run
        WHERE config_version_id = config_version_id_value
          AND trading_date = trading_date_value
    ) THEN
        RAISE EXCEPTION
            'discovery screen run for config % and trading date % already exists (one authoritative run)',
            config_version_id_value, trading_date_value
            USING ERRCODE = '23505';
    END IF;
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = config_row.governing_policy_version_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'governing coverage policy version is missing' USING ERRCODE = '22023';
    END IF;
    session_count_value := (config_row.definition->'lookback_sessions')::integer;
    IF (SELECT count(DISTINCT o.trading_date)
        FROM eod_price_observation o
        WHERE o.trading_date <= trading_date_value
          AND o.available_at <= as_of_value
          AND o.receipt_time <= as_of_value) < session_count_value THEN
        failure_reason_value := 'insufficient_sessions';
    END IF;

    IF failure_reason_value IS NULL THEN
        FOR decision_row IN
            SELECT * FROM discovery_screen_decision_preview(
                config_version_id_value, trading_date_value, as_of_value)
        LOOP
            universe_count_value := universe_count_value + 1;
            IF decision_row.decision = 'included' THEN
                included_count_value := included_count_value + 1;
                IF decision_row.enhanced_risk THEN
                    enhanced_risk_count_value := enhanced_risk_count_value + 1;
                END IF;
            ELSE
                rejected_count_value := rejected_count_value + 1;
            END IF;
            decisions_payload := decisions_payload || jsonb_build_array(jsonb_build_object(
                'security_id', decision_row.security_id,
                'decision', decision_row.decision,
                'enhanced_risk', decision_row.enhanced_risk,
                'rejection_reasons', to_jsonb(decision_row.rejection_reasons)
            ));
        END LOOP;
    END IF;

    run_digest_value := encode(
        digest(convert_to(
            decisions_payload::text || '|' || coalesce(failure_reason_value, '') || '|'
                || trading_date_value::text || '|' || as_of_value::text,
            'UTF8'), 'sha256'), 'hex');

    INSERT INTO discovery_screen_run (
        config_version_id, trading_date, as_of_at, screen_state,
        universe_count, included_count, rejected_count, enhanced_risk_count,
        failure_reason, run_digest,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        config_version_id_value, trading_date_value, as_of_value,
        CASE WHEN failure_reason_value IS NULL THEN 'complete' ELSE 'failed' END,
        universe_count_value, included_count_value, rejected_count_value, enhanced_risk_count_value,
        failure_reason_value, run_digest_value,
        source_lineage_value, now(), 'local_research'
    )
    RETURNING * INTO created_run;

    IF failure_reason_value IS NULL THEN
        FOR decision_row IN
            SELECT * FROM discovery_screen_decision_preview(
                config_version_id_value, trading_date_value, as_of_value)
        LOOP
            INSERT INTO discovery_pool_membership (
                run_id, security_id, decision, enhanced_risk,
                screen_facts, rejection_reasons,
                source_lineage, receipt_time, record_environment
            ) VALUES (
                created_run.run_id, decision_row.security_id, decision_row.decision,
                decision_row.enhanced_risk, decision_row.screen_facts, decision_row.rejection_reasons,
                source_lineage_value, now(), 'local_research'
            );
        END LOOP;
    END IF;

    PERFORM append_audit_event(
        'discovery-screen:' || config_row.config_key || ':' || trading_date_value::text,
        'research.discovery_pool_screened',
        now(),
        jsonb_build_object(
            'run_id', created_run.run_id,
            'config_version_id', config_version_id_value,
            'config_version', config_row.version,
            'governing_policy_version_id', config_row.governing_policy_version_id,
            'trading_date', trading_date_value,
            'as_of_at', as_of_value,
            'screen_state', created_run.screen_state,
            'universe_count', universe_count_value,
            'included_count', included_count_value,
            'rejected_count', rejected_count_value,
            'enhanced_risk_count', enhanced_risk_count_value,
            'failure_reason', failure_reason_value,
            'run_digest', run_digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created_run;
END;
$$;

REVOKE ALL ON FUNCTION append_discovery_universe_entry(text, text, uuid, date, date, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION append_discovery_screen_config_version(text, integer, uuid, jsonb, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION run_discovery_screen(uuid, date, timestamptz, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON discovery_universe_entry, discovery_screen_config_version,
       discovery_screen_run, discovery_pool_membership
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
