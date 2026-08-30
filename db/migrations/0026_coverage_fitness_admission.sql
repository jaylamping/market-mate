-- WU-24 Coverage Fitness scoring and first Coverage Universe admission.
--
-- Fitness is a daily nonpredictive ranking of Discovery Pool members
-- (issue #14): data quality, stock-market execution feasibility, research
-- observability, diversification, and identity/operational stability.
-- Recent returns, sentiment, and strategy profit are not inputs.
--
-- The first admission run seeds up to the system-selected target (40) as
-- Research Candidates. The policy's 15-candidate / 25-eligible split is the
-- post-promotion steady state, not the seed. Enhanced-risk names stay in
-- the pool but are not admitted without the #14 research gates (fail
-- closed). Experimental Indicator definitions are excluded from Core
-- observability and from the bound definition set.

CREATE FUNCTION coverage_gics_sector_is_valid(sector_key_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT sector_key_value IN (
        'energy', 'materials', 'industrials', 'consumer_discretionary',
        'consumer_staples', 'health_care', 'financials',
        'information_technology', 'communication_services',
        'utilities', 'real_estate'
    );
$$;

CREATE FUNCTION coverage_gics_sector_name(sector_key_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE sector_key_value
        WHEN 'energy' THEN 'Energy'
        WHEN 'materials' THEN 'Materials'
        WHEN 'industrials' THEN 'Industrials'
        WHEN 'consumer_discretionary' THEN 'Consumer Discretionary'
        WHEN 'consumer_staples' THEN 'Consumer Staples'
        WHEN 'health_care' THEN 'Health Care'
        WHEN 'financials' THEN 'Financials'
        WHEN 'information_technology' THEN 'Information Technology'
        WHEN 'communication_services' THEN 'Communication Services'
        WHEN 'utilities' THEN 'Utilities'
        WHEN 'real_estate' THEN 'Real Estate'
        ELSE NULL
    END;
$$;

CREATE FUNCTION coverage_score_clip(value numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT round(greatest(0::numeric, least(100::numeric, coalesce(value, 0))), 4);
$$;

CREATE FUNCTION coverage_certified_mapping_ids_as_of(
    security_id_value uuid,
    as_of_value timestamptz
) RETURNS uuid[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(array_agg(m2.mapping_id ORDER BY m2.mapping_id), '{}')
    FROM (
        SELECT m.mapping_id
        FROM instrument_mapping m
        WHERE m.security_id = security_id_value
          AND m.object_kind = 'security'
          AND m.receipt_time <= as_of_value
          AND m.valid_from <= as_of_value
          AND (m.valid_to IS NULL OR m.valid_to > as_of_value)
          AND (
            SELECT t.to_lifecycle
            FROM instrument_mapping_transition t
            WHERE t.mapping_id = m.mapping_id
              AND t.receipt_time <= as_of_value
            ORDER BY t.receipt_time DESC,
                     (CASE t.to_lifecycle
                        WHEN 'retired' THEN 4
                        WHEN 'suspended' THEN 3
                        WHEN 'certified' THEN 2
                        WHEN 'corroborated' THEN 1
                        ELSE 0 END) DESC,
                     t.transition_id
            LIMIT 1
          ) = 'certified'
    ) m2;
$$;

CREATE FUNCTION coverage_core_indicator_ids_as_of(as_of_value timestamptz)
RETURNS uuid[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(array_agg(s.definition_version_id ORDER BY s.indicator_key), '{}')
    FROM (
        SELECT DISTINCT ON (v.indicator_key)
            v.indicator_key, v.definition_version_id
        FROM indicator_definition_version v
        WHERE v.indicator_kind = 'core'
          AND v.effective_from <= as_of_value
          AND v.receipt_time <= as_of_value
          AND coalesce(
                (SELECT l.to_state
                 FROM indicator_definition_lifecycle l
                 WHERE l.definition_version_id = v.definition_version_id
                   AND l.receipt_time <= as_of_value
                 ORDER BY l.receipt_time DESC, l.transition_id DESC
                 LIMIT 1),
                v.definition_state
              ) = 'declared'
        ORDER BY v.indicator_key, v.version DESC
    ) s;
$$;

CREATE TABLE issuer_gics_classification (
    classification_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    scheme text NOT NULL CHECK (scheme = 'gics'),
    sector_key text NOT NULL CHECK (coverage_gics_sector_is_valid(sector_key)),
    sector_name text NOT NULL CHECK (btrim(sector_name) <> ''),
    valid_from timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (sector_name = coverage_gics_sector_name(sector_key))
);

SELECT register_evidence_table('issuer_gics_classification');

CREATE INDEX issuer_gics_classification_issuer_idx
    ON issuer_gics_classification (issuer_id, receipt_time, valid_from);

CREATE TABLE coverage_fitness_run (
    run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_version_id uuid NOT NULL REFERENCES coverage_policy_version(policy_version_id),
    discovery_run_id uuid NOT NULL REFERENCES discovery_screen_run(run_id),
    trading_date date NOT NULL,
    as_of_at timestamptz NOT NULL,
    run_state text NOT NULL CHECK (run_state IN ('complete', 'failed')),
    scored_count integer NOT NULL CHECK (scored_count >= 0),
    below_floor_count integer NOT NULL CHECK (below_floor_count >= 0),
    failure_reason text,
    run_digest text NOT NULL CHECK (run_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (run_state <> 'failed' OR failure_reason IS NOT NULL),
    CHECK (below_floor_count <= scored_count),
    UNIQUE (policy_version_id, discovery_run_id, trading_date)
);

SELECT register_evidence_table('coverage_fitness_run');

CREATE TABLE coverage_fitness_score (
    score_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES coverage_fitness_run(run_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    data_quality numeric NOT NULL CHECK (data_quality >= 0 AND data_quality <= 100),
    stock_liquidity numeric NOT NULL CHECK (stock_liquidity >= 0 AND stock_liquidity <= 100),
    observability numeric NOT NULL CHECK (observability >= 0 AND observability <= 100),
    diversification numeric NOT NULL CHECK (diversification >= 0 AND diversification <= 100),
    stability numeric NOT NULL CHECK (stability >= 0 AND stability <= 100),
    fitness numeric NOT NULL CHECK (fitness >= 0 AND fitness <= 100),
    quality_floor_pass boolean NOT NULL,
    score_facts jsonb NOT NULL CHECK (jsonb_typeof(score_facts) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (run_id, security_id)
);

SELECT register_evidence_table('coverage_fitness_score');

CREATE TABLE coverage_universe_version (
    universe_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    universe_key text NOT NULL CHECK (btrim(universe_key) <> ''),
    version integer NOT NULL CHECK (version >= 1),
    policy_version_id uuid NOT NULL REFERENCES coverage_policy_version(policy_version_id),
    fitness_run_id uuid NOT NULL REFERENCES coverage_fitness_run(run_id),
    discovery_run_id uuid NOT NULL REFERENCES discovery_screen_run(run_id),
    profile_resolution_id uuid REFERENCES research_evidence_profile_resolution(resolution_id),
    core_indicator_definition_ids uuid[] NOT NULL DEFAULT '{}',
    admission_kind text NOT NULL CHECK (admission_kind = 'first_seed'),
    trading_date date NOT NULL,
    as_of_at timestamptz NOT NULL,
    admitted_count integer NOT NULL CHECK (admitted_count >= 0),
    target_count integer NOT NULL CHECK (target_count >= 1),
    admission_state text NOT NULL CHECK (admission_state IN ('complete', 'failed')),
    failure_reason text,
    universe_digest text NOT NULL CHECK (universe_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (admission_state <> 'failed' OR failure_reason IS NOT NULL),
    CHECK (admitted_count <= target_count),
    CHECK (
        (admission_state = 'complete' AND profile_resolution_id IS NOT NULL)
        OR (admission_state = 'failed')
    ),
    UNIQUE (universe_key, version),
    UNIQUE (policy_version_id, trading_date, admission_kind)
);

SELECT register_evidence_table('coverage_universe_version');

CREATE TABLE coverage_universe_membership (
    membership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    universe_version_id uuid NOT NULL REFERENCES coverage_universe_version(universe_version_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    score_id uuid NOT NULL REFERENCES coverage_fitness_score(score_id),
    coverage_stage text NOT NULL CHECK (coverage_stage IN ('discovery_pool', 'research_candidate')),
    coverage_capability text NOT NULL CHECK (coverage_capability IN ('stock_eligible', 'none')),
    system_selected boolean NOT NULL,
    enhanced_risk boolean NOT NULL,
    fitness numeric NOT NULL CHECK (fitness >= 0 AND fitness <= 100),
    admitted_rank integer CHECK (admitted_rank IS NULL OR admitted_rank >= 1),
    admission_decision text NOT NULL CHECK (admission_decision IN ('admitted', 'rejected')),
    rejection_reasons text[] NOT NULL DEFAULT '{}'
        CHECK (rejection_reasons <@ ARRAY[
            'below_quality_floor', 'enhanced_risk_gates_incomplete',
            'sector_ceiling', 'capacity_target_filled']),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (admission_decision = 'admitted'
            AND coverage_stage = 'research_candidate'
            AND coverage_capability = 'stock_eligible'
            AND system_selected
            AND admitted_rank IS NOT NULL
            AND cardinality(rejection_reasons) = 0)
        OR (admission_decision = 'rejected'
            AND coverage_stage = 'discovery_pool'
            AND NOT system_selected
            AND admitted_rank IS NULL
            AND cardinality(rejection_reasons) >= 1)
    ),
    UNIQUE (universe_version_id, security_id)
);

SELECT register_evidence_table('coverage_universe_membership');

CREATE INDEX coverage_fitness_score_run_idx
    ON coverage_fitness_score (run_id, security_id);
CREATE INDEX coverage_universe_membership_version_idx
    ON coverage_universe_membership (universe_version_id, admission_decision, security_id);

CREATE FUNCTION guard_issuer_gics_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'issuer_gics_classification is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_fitness_run_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_fitness_run is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_fitness_score_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_fitness_score is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_universe_version_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_universe_version is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_universe_membership_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'coverage_universe_membership is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER issuer_gics_classification_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON issuer_gics_classification
    FOR EACH STATEMENT EXECUTE FUNCTION guard_issuer_gics_write();
CREATE TRIGGER coverage_fitness_run_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON coverage_fitness_run
    FOR EACH STATEMENT EXECUTE FUNCTION guard_coverage_fitness_run_write();
CREATE TRIGGER coverage_fitness_score_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON coverage_fitness_score
    FOR EACH STATEMENT EXECUTE FUNCTION guard_coverage_fitness_score_write();
CREATE TRIGGER coverage_universe_version_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON coverage_universe_version
    FOR EACH STATEMENT EXECUTE FUNCTION guard_coverage_universe_version_write();
CREATE TRIGGER coverage_universe_membership_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON coverage_universe_membership
    FOR EACH STATEMENT EXECUTE FUNCTION guard_coverage_universe_membership_write();

CREATE FUNCTION guard_issuer_gics_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.issuer_gics_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'issuer_gics_classification writes must go through append_issuer_gics_classification'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_fitness_run_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.coverage_fitness_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'coverage_fitness_run writes must go through run_coverage_fitness_score'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_fitness_score_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.coverage_fitness_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'coverage_fitness_score writes must go through run_coverage_fitness_score'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_universe_version_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.coverage_universe_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'coverage_universe_version writes must go through run_coverage_universe_first_seed'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_coverage_universe_membership_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.coverage_universe_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'coverage_universe_membership writes must go through run_coverage_universe_first_seed'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER issuer_gics_classification_insert_guard
    BEFORE INSERT ON issuer_gics_classification
    FOR EACH ROW EXECUTE FUNCTION guard_issuer_gics_insert();
CREATE TRIGGER coverage_fitness_run_insert_guard
    BEFORE INSERT ON coverage_fitness_run
    FOR EACH ROW EXECUTE FUNCTION guard_coverage_fitness_run_insert();
CREATE TRIGGER coverage_fitness_score_insert_guard
    BEFORE INSERT ON coverage_fitness_score
    FOR EACH ROW EXECUTE FUNCTION guard_coverage_fitness_score_insert();
CREATE TRIGGER coverage_universe_version_insert_guard
    BEFORE INSERT ON coverage_universe_version
    FOR EACH ROW EXECUTE FUNCTION guard_coverage_universe_version_insert();
CREATE TRIGGER coverage_universe_membership_insert_guard
    BEFORE INSERT ON coverage_universe_membership
    FOR EACH ROW EXECUTE FUNCTION guard_coverage_universe_membership_insert();

CREATE FUNCTION append_issuer_gics_classification(
    issuer_id_value uuid,
    sector_key_value text,
    valid_from_value timestamptz,
    source_lineage_value jsonb
) RETURNS issuer_gics_classification
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created issuer_gics_classification%ROWTYPE;
    sector_name_value text;
BEGIN
    IF issuer_id_value IS NULL
       OR NOT coverage_gics_sector_is_valid(sector_key_value)
       OR valid_from_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'issuer GICS classification arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM issuer WHERE issuer_id = issuer_id_value) THEN
        RAISE EXCEPTION 'issuer % is not registered', issuer_id_value
            USING ERRCODE = '22023';
    END IF;
    sector_name_value := coverage_gics_sector_name(sector_key_value);

    PERFORM set_config('market_mate.issuer_gics_write', 'on', true);
    BEGIN
        INSERT INTO issuer_gics_classification (
            issuer_id, scheme, sector_key, sector_name, valid_from,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            issuer_id_value, 'gics', sector_key_value, sector_name_value, valid_from_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.issuer_gics_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.issuer_gics_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION issuer_gics_at(
    issuer_id_value uuid,
    as_of_value timestamptz
) RETURNS issuer_gics_classification
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT c
    FROM issuer_gics_classification c
    WHERE c.issuer_id = issuer_id_value
      AND c.receipt_time <= as_of_value
      AND c.valid_from <= as_of_value
    ORDER BY c.receipt_time DESC, c.classification_id DESC
    LIMIT 1;
$$;

CREATE FUNCTION coverage_fitness_score_preview(
    policy_version_id_value uuid,
    discovery_run_id_value uuid,
    as_of_value timestamptz
) RETURNS TABLE (
    security_id uuid,
    data_quality numeric,
    stock_liquidity numeric,
    observability numeric,
    diversification numeric,
    stability numeric,
    fitness numeric,
    quality_floor_pass boolean,
    score_facts jsonb
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    policy_row coverage_policy_version%ROWTYPE;
    run_row discovery_screen_run%ROWTYPE;
    config_row discovery_screen_config_version%ROWTYPE;
    lookback integer;
    min_median_dv numeric;
    w_dq numeric;
    w_liq numeric;
    w_obs numeric;
    w_div numeric;
    w_stab numeric;
    core_ids uuid[];
    core_count integer;
    experimental_count integer;
    pool_n integer;
    member_row discovery_pool_membership%ROWTYPE;
    issuer_id_value uuid;
    gics_row issuer_gics_classification%ROWTYPE;
    certified_ids uuid[];
    listing_row exchange_listing%ROWTYPE;
    listing_found boolean;
    session_dates date[];
    complete_sessions integer;
    dollar_volumes numeric[];
    last_bar eod_price_observation%ROWTYPE;
    last_bar_found boolean;
    bar eod_price_observation%ROWTYPE;
    median_dv numeric;
    mean_dv numeric;
    stdev_dv numeric;
    session_frac numeric;
    ratio numeric;
    liq numeric;
    consistency numeric;
    listing_days numeric;
    alias_present boolean;
    sector_n integer;
    sector_frac numeric;
    i integer;
BEGIN
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = policy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage policy version % is not registered', policy_version_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO run_row
    FROM discovery_screen_run
    WHERE run_id = discovery_run_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'discovery screen run % is not registered', discovery_run_id_value
            USING ERRCODE = '22023';
    END IF;
    IF as_of_value IS NULL THEN
        RAISE EXCEPTION 'coverage fitness preview as_of time is required'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO config_row
    FROM discovery_screen_config_version
    WHERE config_version_id = run_row.config_version_id;

    lookback := (config_row.definition->'lookback_sessions')::integer;
    min_median_dv := (config_row.definition->'min_median_dollar_volume')::numeric;
    w_dq := coverage_policy_number_at(policy_row.definition, ARRAY['fitness_weights', 'data_quality']);
    w_liq := coverage_policy_number_at(policy_row.definition, ARRAY['fitness_weights', 'stock_liquidity']);
    w_obs := coverage_policy_number_at(policy_row.definition, ARRAY['fitness_weights', 'observability']);
    w_div := coverage_policy_number_at(policy_row.definition, ARRAY['fitness_weights', 'diversification']);
    w_stab := coverage_policy_number_at(policy_row.definition, ARRAY['fitness_weights', 'stability']);

    core_ids := coverage_core_indicator_ids_as_of(as_of_value);
    core_count := coalesce(array_length(core_ids, 1), 0);
    SELECT count(*)::integer INTO experimental_count
    FROM (
        SELECT DISTINCT ON (v.indicator_key) v.indicator_key
        FROM indicator_definition_version v
        WHERE v.indicator_kind = 'experimental'
          AND v.effective_from <= as_of_value
          AND v.receipt_time <= as_of_value
        ORDER BY v.indicator_key, v.version DESC
    ) e;

    SELECT coalesce(array_agg(d ORDER BY d), '{}')
    INTO session_dates
    FROM (
        SELECT DISTINCT o.trading_date AS d
        FROM eod_price_observation o
        WHERE o.trading_date <= run_row.trading_date
          AND o.available_at <= as_of_value
          AND o.receipt_time <= as_of_value
        ORDER BY o.trading_date DESC
        LIMIT lookback
    ) sessions;

    SELECT count(*)::integer INTO pool_n
    FROM discovery_pool_membership m
    WHERE m.run_id = discovery_run_id_value
      AND m.decision = 'included';

    FOR member_row IN
        SELECT * FROM discovery_pool_membership m
        WHERE m.run_id = discovery_run_id_value
          AND m.decision = 'included'
        ORDER BY m.security_id
    LOOP
        SELECT s.issuer_id INTO issuer_id_value
        FROM security s
        WHERE s.security_id = member_row.security_id
          AND s.receipt_time <= as_of_value;

        gics_row := issuer_gics_at(issuer_id_value, as_of_value);
        certified_ids := coverage_certified_mapping_ids_as_of(member_row.security_id, as_of_value);

        listing_found := false;
        listing_row := NULL;
        SELECT * INTO listing_row
        FROM exchange_listing l
        WHERE l.security_id = member_row.security_id
          AND l.listing_status = 'active'
          AND l.receipt_time <= as_of_value
          AND l.valid_from <= as_of_value
          AND (l.valid_to IS NULL OR l.valid_to > as_of_value)
        ORDER BY l.listing_id
        LIMIT 1;
        listing_found := FOUND;

        complete_sessions := 0;
        dollar_volumes := NULL;
        last_bar := NULL;
        last_bar_found := false;
        IF coalesce(array_length(certified_ids, 1), 0) = 1
           AND coalesce(array_length(session_dates, 1), 0) = lookback THEN
            FOR i IN 1 .. lookback LOOP
                SELECT * INTO bar
                FROM eod_price_observation_at(certified_ids[1], session_dates[i], as_of_value);
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
        END IF;

        session_frac := CASE WHEN lookback > 0
            THEN complete_sessions::numeric / lookback ELSE 0 END;
        median_dv := CASE WHEN dollar_volumes IS NULL THEN NULL
            ELSE (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v)
                  FROM unnest(dollar_volumes) AS v) END;
        mean_dv := CASE WHEN dollar_volumes IS NULL THEN NULL
            ELSE (SELECT avg(v) FROM unnest(dollar_volumes) AS v) END;
        stdev_dv := CASE WHEN coalesce(array_length(dollar_volumes, 1), 0) > 1
            THEN (SELECT stddev_pop(v) FROM unnest(dollar_volumes) AS v)
            ELSE 0 END;

        -- Returns are intentionally absent: close paths never enter a score.
        data_quality := coverage_score_clip(
            session_frac * 50
            + CASE WHEN coalesce(array_length(certified_ids, 1), 0) = 1 THEN 25 ELSE 0 END
            + CASE WHEN last_bar_found
                    AND last_bar.available_at <= as_of_value
                    AND last_bar.trading_date >= run_row.trading_date - 7
                   THEN 15 ELSE 0 END
            + CASE WHEN complete_sessions = lookback THEN 10 ELSE 0 END
        );

        IF median_dv IS NULL OR min_median_dv <= 0 THEN
            stock_liquidity := 0;
        ELSE
            ratio := median_dv / min_median_dv;
            liq := least(100::numeric, 50 + 25 * log(greatest(ratio, 0.0001)));
            consistency := CASE WHEN mean_dv IS NULL OR mean_dv <= 0 THEN 0
                ELSE 1 - least(1::numeric, coalesce(stdev_dv, 0) / mean_dv) END;
            stock_liquidity := coverage_score_clip(0.85 * liq + 0.15 * (consistency * 100));
            IF member_row.enhanced_risk THEN
                stock_liquidity := coverage_score_clip(stock_liquidity * 0.8);
            END IF;
        END IF;

        observability := coverage_score_clip(
            least(50::numeric, core_count * 25)
            + session_frac * 50
        );

        IF gics_row.classification_id IS NULL OR pool_n IS NULL OR pool_n = 0 THEN
            diversification := 0;
            sector_n := 0;
            sector_frac := NULL;
        ELSE
            SELECT count(*)::integer INTO sector_n
            FROM discovery_pool_membership m
            JOIN security s ON s.security_id = m.security_id
            JOIN LATERAL issuer_gics_at(s.issuer_id, as_of_value) g ON true
            WHERE m.run_id = discovery_run_id_value
              AND m.decision = 'included'
              AND g.sector_key = gics_row.sector_key;
            sector_frac := sector_n::numeric / pool_n;
            IF gics_row.sector_key = 'information_technology' THEN
                diversification := coverage_score_clip(
                    CASE WHEN sector_frac >= 0.50 THEN 10
                         WHEN sector_frac < 0.30 THEN 100
                         ELSE 70 END
                );
            ELSIF gics_row.sector_key = 'energy' THEN
                diversification := coverage_score_clip(
                    CASE WHEN sector_frac < 0.10 THEN 95
                         WHEN sector_frac > 0.20 THEN 50
                         ELSE 80 END
                );
            ELSE
                diversification := coverage_score_clip(
                    CASE WHEN sector_frac >= 0.30 THEN 15
                         ELSE greatest(20::numeric, 70 - 100 * sector_frac) END
                );
            END IF;
        END IF;

        listing_days := CASE WHEN listing_found
            THEN greatest(0::numeric,
                extract(epoch FROM (as_of_value - listing_row.valid_from)) / 86400)
            ELSE 0 END;
        SELECT EXISTS (
            SELECT 1 FROM security_symbol_alias a
            WHERE a.security_id = member_row.security_id
              AND a.receipt_time <= as_of_value
              AND a.valid_from <= as_of_value
              AND (a.valid_to IS NULL OR a.valid_to > as_of_value)
        ) INTO alias_present;
        stability := coverage_score_clip(
            CASE WHEN coalesce(array_length(certified_ids, 1), 0) = 1 THEN 40 ELSE 0 END
            + CASE WHEN listing_found THEN 20 ELSE 0 END
            + least(20::numeric, 20 * listing_days / 252)
            + CASE WHEN alias_present THEN 10 ELSE 0 END
            + CASE WHEN coalesce(array_length(certified_ids, 1), 0) = 1 THEN 10 ELSE 0 END
        );

        fitness := coverage_score_clip(
            data_quality * w_dq / 100
            + stock_liquidity * w_liq / 100
            + observability * w_obs / 100
            + diversification * w_div / 100
            + stability * w_stab / 100
        );

        quality_floor_pass :=
            coalesce(array_length(certified_ids, 1), 0) = 1
            AND gics_row.classification_id IS NOT NULL
            AND data_quality >= 40
            AND stock_liquidity >= 40
            AND stability >= 40;

        score_facts := jsonb_build_object(
            'complete_sessions', complete_sessions,
            'lookback_sessions', lookback,
            'certified_identity_count', coalesce(array_length(certified_ids, 1), 0),
            'median_dollar_volume', median_dv,
            'last_close', CASE WHEN last_bar_found THEN last_bar.close_price ELSE NULL END,
            'enhanced_risk', member_row.enhanced_risk,
            'sector_key', gics_row.sector_key,
            'sector_pool_count', sector_n,
            'sector_pool_fraction', sector_frac,
            'core_definition_count', core_count,
            'experimental_definition_count', experimental_count,
            'experimental_excluded', true,
            'listing_age_days', round(listing_days, 4),
            'weights', jsonb_build_object(
                'data_quality', w_dq, 'stock_liquidity', w_liq,
                'observability', w_obs, 'diversification', w_div,
                'stability', w_stab)
        );

        security_id := member_row.security_id;
        RETURN NEXT;
    END LOOP;
END;
$$;

CREATE FUNCTION run_coverage_fitness_score(
    policy_version_id_value uuid,
    discovery_run_id_value uuid,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS coverage_fitness_run
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    policy_row coverage_policy_version%ROWTYPE;
    run_row discovery_screen_run%ROWTYPE;
    created coverage_fitness_run%ROWTYPE;
    score_row record;
    scored_count_value integer := 0;
    below_floor_count_value integer := 0;
    failure_reason_value text := NULL;
    scores_payload jsonb := '[]'::jsonb;
    run_digest_value text;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'coverage fitness run source_lineage is invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = policy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage policy version % is not registered', policy_version_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO run_row
    FROM discovery_screen_run
    WHERE run_id = discovery_run_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'discovery screen run % is not registered', discovery_run_id_value
            USING ERRCODE = '22023';
    END IF;
    IF as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR as_of_value < policy_row.effective_from
       OR as_of_value < run_row.as_of_at THEN
        RAISE EXCEPTION 'coverage fitness run as_of time is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF run_row.screen_state <> 'complete' THEN
        failure_reason_value := 'discovery_run_not_complete';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        policy_version_id_value::text || ':' || discovery_run_id_value::text, 26023));
    IF EXISTS (
        SELECT 1 FROM coverage_fitness_run
        WHERE policy_version_id = policy_version_id_value
          AND discovery_run_id = discovery_run_id_value
          AND trading_date = run_row.trading_date
    ) THEN
        RAISE EXCEPTION
            'coverage fitness run for policy % discovery % date % already exists',
            policy_version_id_value, discovery_run_id_value, run_row.trading_date
            USING ERRCODE = '23505';
    END IF;

    IF failure_reason_value IS NULL THEN
        DROP TABLE IF EXISTS coverage_fitness_preview_stage;
        CREATE TEMP TABLE coverage_fitness_preview_stage ON COMMIT DROP AS
            SELECT * FROM coverage_fitness_score_preview(
                policy_version_id_value, discovery_run_id_value, as_of_value);

        SELECT count(*),
               count(*) FILTER (WHERE NOT quality_floor_pass)
        INTO scored_count_value, below_floor_count_value
        FROM coverage_fitness_preview_stage;

        IF scored_count_value = 0 THEN
            failure_reason_value := 'empty_discovery_pool';
        END IF;
    END IF;

    IF failure_reason_value IS NULL THEN
        FOR score_row IN
            SELECT * FROM coverage_fitness_preview_stage ORDER BY security_id
        LOOP
            scores_payload := scores_payload || jsonb_build_array(jsonb_build_object(
                'security_id', score_row.security_id,
                'data_quality', score_row.data_quality,
                'stock_liquidity', score_row.stock_liquidity,
                'observability', score_row.observability,
                'diversification', score_row.diversification,
                'stability', score_row.stability,
                'fitness', score_row.fitness,
                'quality_floor_pass', score_row.quality_floor_pass
            ));
        END LOOP;
    END IF;

    run_digest_value := encode(
        digest(convert_to(
            scores_payload::text || '|' || coalesce(failure_reason_value, '') || '|'
                || run_row.trading_date::text || '|'
                || to_char(as_of_value AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'UTF8'), 'sha256'), 'hex');

    PERFORM set_config('market_mate.coverage_fitness_write', 'on', true);
    BEGIN
        INSERT INTO coverage_fitness_run (
            policy_version_id, discovery_run_id, trading_date, as_of_at,
            run_state, scored_count, below_floor_count, failure_reason, run_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            policy_version_id_value, discovery_run_id_value, run_row.trading_date, as_of_value,
            CASE WHEN failure_reason_value IS NULL THEN 'complete' ELSE 'failed' END,
            scored_count_value, below_floor_count_value, failure_reason_value, run_digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;

        IF failure_reason_value IS NULL THEN
            INSERT INTO coverage_fitness_score (
                run_id, security_id,
                data_quality, stock_liquidity, observability, diversification, stability,
                fitness, quality_floor_pass, score_facts,
                source_lineage, receipt_time, record_environment
            )
            SELECT created.run_id, p.security_id,
                   p.data_quality, p.stock_liquidity, p.observability, p.diversification, p.stability,
                   p.fitness, p.quality_floor_pass, p.score_facts,
                   source_lineage_value, clock_timestamp(), 'local_research'
            FROM coverage_fitness_preview_stage p
            ORDER BY p.security_id;
            DROP TABLE coverage_fitness_preview_stage;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.coverage_fitness_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.coverage_fitness_write', 'off', true);

    PERFORM append_audit_event(
        'coverage-fitness:' || created.run_id::text,
        'research.coverage_fitness_scored',
        clock_timestamp(),
        jsonb_build_object(
            'run_id', created.run_id,
            'policy_version_id', policy_version_id_value,
            'discovery_run_id', discovery_run_id_value,
            'trading_date', run_row.trading_date,
            'as_of_at', as_of_value,
            'run_state', created.run_state,
            'scored_count', scored_count_value,
            'below_floor_count', below_floor_count_value,
            'failure_reason', failure_reason_value,
            'run_digest', run_digest_value
        ),
        source_lineage_value,
        clock_timestamp(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE FUNCTION coverage_first_seed_preview(
    fitness_run_id_value uuid
) RETURNS TABLE (
    security_id uuid,
    score_id uuid,
    fitness numeric,
    enhanced_risk boolean,
    sector_key text,
    quality_floor_pass boolean,
    admission_decision text,
    rejection_reasons text[],
    admitted_rank integer
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    fitness_row coverage_fitness_run%ROWTYPE;
    policy_row coverage_policy_version%ROWTYPE;
    target_count_value integer;
    tech_limit integer;
    ordinary_limit integer;
    score_row coverage_fitness_score%ROWTYPE;
    member_row discovery_pool_membership%ROWTYPE;
    sector_key_value text;
    reasons text[];
    decision_value text;
    admitted_count_value integer := 0;
    sector_counts jsonb := '{}'::jsonb;
    sector_count_value integer;
    sector_limit integer;
    rank_value integer;
BEGIN
    SELECT * INTO fitness_row
    FROM coverage_fitness_run
    WHERE run_id = fitness_run_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage fitness run % is not registered', fitness_run_id_value
            USING ERRCODE = '22023';
    END IF;
    IF fitness_row.run_state <> 'complete' THEN
        RAISE EXCEPTION 'coverage first-seed preview requires a complete fitness run'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = fitness_row.policy_version_id;

    target_count_value := coverage_policy_number_at(
        policy_row.definition, ARRAY['capacity', 'system_selected_target'])::integer;
    tech_limit := floor(
        target_count_value * coverage_policy_number_at(
            policy_row.definition, ARRAY['sector_limits', 'technology_absolute_max_fraction'])
    )::integer;
    ordinary_limit := floor(
        target_count_value * coverage_policy_number_at(
            policy_row.definition, ARRAY['sector_limits', 'ordinary_sector_max_fraction'])
    )::integer;

    FOR score_row IN
        SELECT s.*
        FROM coverage_fitness_score s
        WHERE s.run_id = fitness_run_id_value
        ORDER BY s.quality_floor_pass DESC, s.fitness DESC, s.stability DESC, s.security_id
    LOOP
        SELECT * INTO member_row
        FROM discovery_pool_membership m
        WHERE m.run_id = fitness_row.discovery_run_id
          AND m.security_id = score_row.security_id;
        sector_key_value := score_row.score_facts->>'sector_key';
        reasons := '{}';
        rank_value := NULL;

        IF NOT score_row.quality_floor_pass THEN
            reasons := reasons || 'below_quality_floor'::text;
        ELSIF member_row.enhanced_risk THEN
            reasons := reasons || 'enhanced_risk_gates_incomplete'::text;
        ELSIF admitted_count_value >= target_count_value THEN
            reasons := reasons || 'capacity_target_filled'::text;
        ELSE
            sector_count_value := coalesce((sector_counts->>sector_key_value)::integer, 0);
            sector_limit := CASE WHEN sector_key_value = 'information_technology'
                THEN tech_limit ELSE ordinary_limit END;
            IF sector_count_value + 1 > sector_limit THEN
                reasons := reasons || 'sector_ceiling'::text;
            END IF;
        END IF;

        IF cardinality(reasons) = 0 THEN
            decision_value := 'admitted';
            admitted_count_value := admitted_count_value + 1;
            rank_value := admitted_count_value;
            sector_counts := jsonb_set(
                sector_counts,
                ARRAY[sector_key_value],
                to_jsonb(coalesce((sector_counts->>sector_key_value)::integer, 0) + 1),
                true);
        ELSE
            decision_value := 'rejected';
        END IF;

        security_id := score_row.security_id;
        score_id := score_row.score_id;
        fitness := score_row.fitness;
        enhanced_risk := member_row.enhanced_risk;
        sector_key := sector_key_value;
        quality_floor_pass := score_row.quality_floor_pass;
        admission_decision := decision_value;
        rejection_reasons := reasons;
        admitted_rank := rank_value;
        RETURN NEXT;
    END LOOP;
END;
$$;

CREATE FUNCTION run_coverage_universe_first_seed(
    fitness_run_id_value uuid,
    universe_key_value text,
    version_value integer,
    source_lineage_value jsonb
) RETURNS coverage_universe_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    fitness_row coverage_fitness_run%ROWTYPE;
    policy_row coverage_policy_version%ROWTYPE;
    created coverage_universe_version%ROWTYPE;
    decision_row record;
    expected_version integer;
    failure_reason_value text := NULL;
    admitted_count_value integer := 0;
    target_count_value integer;
    decisions_payload jsonb := '[]'::jsonb;
    universe_digest_value text;
    resolution_row research_evidence_profile_resolution%ROWTYPE;
    core_ids uuid[];
    approved_value boolean;
BEGIN
    IF coalesce(btrim(universe_key_value), '') = ''
       OR version_value IS NULL OR version_value < 1
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'coverage universe first-seed arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO fitness_row
    FROM coverage_fitness_run
    WHERE run_id = fitness_run_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'coverage fitness run % is not registered', fitness_run_id_value
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO policy_row
    FROM coverage_policy_version
    WHERE policy_version_id = fitness_row.policy_version_id;

    target_count_value := coverage_policy_number_at(
        policy_row.definition, ARRAY['capacity', 'system_selected_target'])::integer;
    approved_value := EXISTS (
        SELECT 1 FROM coverage_policy_approval
        WHERE policy_version_id = policy_row.policy_version_id
          AND approved_at <= fitness_row.as_of_at
    );
    core_ids := coverage_core_indicator_ids_as_of(fitness_row.as_of_at);

    IF fitness_row.run_state <> 'complete' THEN
        RAISE EXCEPTION 'coverage first-seed requires a complete fitness run'
            USING ERRCODE = '22023';
    END IF;
    IF NOT approved_value THEN
        RAISE EXCEPTION
            'coverage first-seed requires Principal approval of the governing policy version before any universe row is recorded'
            USING ERRCODE = '55000';
    END IF;

    -- Serialize the one-seed-per-(policy, date) slot, not the universe_key,
    -- so two keys cannot race the unique constraint.
    PERFORM pg_advisory_xact_lock(hashtextextended(
        policy_row.policy_version_id::text || ':' || fitness_row.trading_date::text || ':first_seed',
        26024));
    SELECT coalesce(max(version), 0) + 1 INTO expected_version
    FROM coverage_universe_version
    WHERE universe_key = universe_key_value;
    IF version_value <> expected_version THEN
        RAISE EXCEPTION
            'coverage universe versions must advance consecutively: expected %, received %',
            expected_version, version_value
            USING ERRCODE = '55000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM coverage_universe_version
        WHERE policy_version_id = policy_row.policy_version_id
          AND trading_date = fitness_row.trading_date
          AND admission_kind = 'first_seed'
    ) THEN
        RAISE EXCEPTION
            'first-seed coverage universe for policy % date % already exists',
            policy_row.policy_version_id, fitness_row.trading_date
            USING ERRCODE = '23505';
    END IF;

    IF failure_reason_value IS NULL THEN
        DROP TABLE IF EXISTS coverage_first_seed_stage;
        CREATE TEMP TABLE coverage_first_seed_stage ON COMMIT DROP AS
            SELECT * FROM coverage_first_seed_preview(fitness_run_id_value);

        SELECT count(*) FILTER (WHERE admission_decision = 'admitted')
        INTO admitted_count_value
        FROM coverage_first_seed_stage;

        IF admitted_count_value = 0 THEN
            failure_reason_value := 'no_qualifying_members';
        END IF;
    END IF;

    IF failure_reason_value IS NULL THEN
        FOR decision_row IN
            SELECT * FROM coverage_first_seed_stage ORDER BY security_id
        LOOP
            decisions_payload := decisions_payload || jsonb_build_array(jsonb_build_object(
                'security_id', decision_row.security_id,
                'decision', decision_row.admission_decision,
                'fitness', decision_row.fitness,
                'admitted_rank', decision_row.admitted_rank,
                'rejection_reasons', to_jsonb(decision_row.rejection_reasons)
            ));
        END LOOP;

        SELECT * INTO resolution_row
        FROM resolve_research_evidence_profile(
            'research_candidate', 'stock_eligible', 'research',
            fitness_row.as_of_at, source_lineage_value);
        IF resolution_row.obligation_count IS NULL OR resolution_row.obligation_count < 1 THEN
            RAISE EXCEPTION 'research candidate evidence obligations did not resolve'
                USING ERRCODE = '55000';
        END IF;
    END IF;

    universe_digest_value := encode(
        digest(convert_to(
            decisions_payload::text || '|' || coalesce(failure_reason_value, '') || '|'
                || fitness_row.trading_date::text || '|'
                || to_char(fitness_row.as_of_at AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'UTF8'), 'sha256'), 'hex');

    PERFORM set_config('market_mate.coverage_universe_write', 'on', true);
    BEGIN
        INSERT INTO coverage_universe_version (
            universe_key, version, policy_version_id, fitness_run_id, discovery_run_id,
            profile_resolution_id, core_indicator_definition_ids, admission_kind,
            trading_date, as_of_at, admitted_count, target_count,
            admission_state, failure_reason, universe_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            universe_key_value, version_value, policy_row.policy_version_id,
            fitness_run_id_value, fitness_row.discovery_run_id,
            resolution_row.resolution_id, core_ids, 'first_seed',
            fitness_row.trading_date, fitness_row.as_of_at,
            admitted_count_value, target_count_value,
            CASE WHEN failure_reason_value IS NULL THEN 'complete' ELSE 'failed' END,
            failure_reason_value, universe_digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;

        IF failure_reason_value IS NULL THEN
            INSERT INTO coverage_universe_membership (
                universe_version_id, security_id, score_id,
                coverage_stage, coverage_capability, system_selected, enhanced_risk,
                fitness, admitted_rank, admission_decision, rejection_reasons,
                source_lineage, receipt_time, record_environment
            )
            SELECT created.universe_version_id, p.security_id, p.score_id,
                   CASE WHEN p.admission_decision = 'admitted'
                        THEN 'research_candidate' ELSE 'discovery_pool' END,
                   CASE WHEN p.admission_decision = 'admitted'
                        THEN 'stock_eligible' ELSE 'none' END,
                   p.admission_decision = 'admitted',
                   p.enhanced_risk, p.fitness, p.admitted_rank,
                   p.admission_decision, p.rejection_reasons,
                   source_lineage_value, clock_timestamp(), 'local_research'
            FROM coverage_first_seed_stage p
            ORDER BY p.security_id;
            DROP TABLE coverage_first_seed_stage;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.coverage_universe_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.coverage_universe_write', 'off', true);

    PERFORM append_audit_event(
        'coverage-universe:' || created.universe_version_id::text,
        'research.coverage_universe_first_seeded',
        clock_timestamp(),
        jsonb_build_object(
            'universe_version_id', created.universe_version_id,
            'universe_key', universe_key_value,
            'version', version_value,
            'fitness_run_id', fitness_run_id_value,
            'policy_version_id', policy_row.policy_version_id,
            'trading_date', fitness_row.trading_date,
            'admission_state', created.admission_state,
            'admitted_count', admitted_count_value,
            'target_count', target_count_value,
            'profile_resolution_id', resolution_row.resolution_id,
            'core_indicator_definition_ids', core_ids,
            'failure_reason', failure_reason_value,
            'universe_digest', universe_digest_value
        ),
        source_lineage_value,
        clock_timestamp(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION append_issuer_gics_classification(uuid, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION run_coverage_fitness_score(uuid, uuid, timestamptz, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION run_coverage_universe_first_seed(uuid, text, integer, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON issuer_gics_classification, coverage_fitness_run, coverage_fitness_score,
       coverage_universe_version, coverage_universe_membership
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
