-- WU-36 Block-bootstrap LCB: a preregistered moving-block bootstrap of
-- paired strategy-vs-comparator excess returns yields a one-sided 95%
-- lower confidence bound. Method, block construction, and seed are
-- frozen with the Strategy Version. Seeded replays are byte-identical.

CREATE FUNCTION bootstrap_u32(seed_value bigint, counter_value bigint)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT get_byte(d, 0)::bigint * 16777216
        + get_byte(d, 1)::bigint * 65536
        + get_byte(d, 2)::bigint * 256
        + get_byte(d, 3)::bigint
    FROM (
        SELECT digest(convert_to(
            'market-mate-bootstrap-rng-v1|'
                || seed_value::text || '|' || counter_value::text,
            'UTF8'), 'sha256') AS d
    ) s;
$$;

CREATE FUNCTION bootstrap_construction_digest(construction_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-bootstrap-construction-v1|' || construction_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION bootstrap_pairs_digest(pairs_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-bootstrap-pairs-v1|' || pairs_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION bootstrap_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-bootstrap-lcb-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION bootstrap_assert_construction(construction_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n numeric;
    r numeric;
    seed_value bigint;
    conf numeric;
BEGIN
    IF jsonb_typeof(construction_value) IS DISTINCT FROM 'object'
       OR EXISTS (
            SELECT 1 FROM jsonb_object_keys(construction_value) k
            WHERE k NOT IN (
                'method', 'block_length', 'replications', 'seed',
                'confidence', 'side'
            )
       ) THEN
        RAISE EXCEPTION 'block bootstrap construction is not preregistered'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(construction_value->'method') IS DISTINCT FROM 'string'
       OR btrim(construction_value->>'method')
            IS DISTINCT FROM 'moving_block_bootstrap' THEN
        RAISE EXCEPTION 'block bootstrap construction is not preregistered'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(construction_value->'side') IS DISTINCT FROM 'string'
       OR btrim(construction_value->>'side')
            IS DISTINCT FROM 'one_sided_lower' THEN
        RAISE EXCEPTION 'block bootstrap construction is not preregistered'
            USING ERRCODE = '22023';
    END IF;
    n := (construction_value->'block_length')::numeric;
    r := (construction_value->'replications')::numeric;
    conf := (construction_value->'confidence')::numeric;
    seed_value := strategy_sandbox_integer(construction_value->'seed');
    IF jsonb_typeof(construction_value->'block_length') IS DISTINCT FROM 'number'
       OR n IS NULL OR n <> floor(n) OR n < 1 OR n > 256
       OR jsonb_typeof(construction_value->'replications') IS DISTINCT FROM 'number'
       OR r IS NULL OR r <> floor(r) OR r < 100 OR r > 1000
       OR seed_value IS NULL OR seed_value < 0
       OR jsonb_typeof(construction_value->'confidence') IS DISTINCT FROM 'number'
       OR conf IS DISTINCT FROM 95 THEN
        RAISE EXCEPTION 'block bootstrap construction is not preregistered'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION bootstrap_assert_pairs(pairs_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    pair jsonb;
    prev_session text;
    session_text text;
    allowed text[] := ARRAY['strategy_bps', 'comparator_bps', 'session'];
BEGIN
    IF jsonb_typeof(pairs_value) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'block bootstrap pairs are not admissible'
            USING ERRCODE = '22023';
    END IF;
    n := jsonb_array_length(pairs_value);
    IF n < 2 OR n > 256 THEN
        RAISE EXCEPTION 'block bootstrap pairs exceed the resource bound'
            USING ERRCODE = '22023';
    END IF;
    prev_session := NULL;
    FOR pair IN SELECT jsonb_array_elements(pairs_value) LOOP
        IF jsonb_typeof(pair) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(pair) k
                WHERE k <> ALL (allowed)
           ) THEN
            RAISE EXCEPTION 'block bootstrap pairs contain out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
        IF strategy_sandbox_integer(pair->'strategy_bps') IS NULL
           OR strategy_sandbox_integer(pair->'comparator_bps') IS NULL THEN
            RAISE EXCEPTION 'block bootstrap pairs are not admissible'
                USING ERRCODE = '22023';
        END IF;
        IF pair ? 'session' THEN
            session_text := btrim(pair->>'session');
            IF jsonb_typeof(pair->'session') IS DISTINCT FROM 'string'
               OR session_text IS NULL
               OR session_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
               OR (prev_session IS NOT NULL AND session_text <= prev_session) THEN
                RAISE EXCEPTION 'block bootstrap pairs are not admissible'
                    USING ERRCODE = '22023';
            END IF;
            prev_session := session_text;
        ELSIF prev_session IS NOT NULL THEN
            RAISE EXCEPTION 'block bootstrap pairs are not admissible'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION bootstrap_pairs_from_eis_result(result_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    pairs jsonb := '[]'::jsonb;
    cl jsonb;
BEGIN
    IF jsonb_typeof(result_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(result_value->'clusters') IS DISTINCT FROM 'array'
       OR jsonb_array_length(result_value->'clusters') < 2 THEN
        RAISE EXCEPTION 'block bootstrap EIS result is not admissible'
            USING ERRCODE = '22023';
    END IF;
    FOR cl IN
        SELECT c
        FROM jsonb_array_elements(result_value->'clusters') AS c
        ORDER BY (c->>'cluster_id')::integer
    LOOP
        IF strategy_sandbox_integer(cl->'return_bps') IS NULL THEN
            RAISE EXCEPTION 'block bootstrap EIS result is not admissible'
                USING ERRCODE = '22023';
        END IF;
        pairs := pairs || jsonb_build_array(
            jsonb_build_object(
                'strategy_bps', strategy_sandbox_integer(cl->'return_bps'),
                'comparator_bps', 0
            )
        );
    END LOOP;
    RETURN pairs;
END;
$$;

CREATE FUNCTION bootstrap_spec_requires_estimator(spec_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    node jsonb;
BEGIN
    node := experiment_preregistration_spec_node(
        spec_value, 'estimators', 'estimator');
    IF jsonb_typeof(node) = 'string' THEN
        RETURN btrim(node #>> '{}') = 'block_bootstrap_lcb';
    ELSIF jsonb_typeof(node) = 'array' THEN
        RETURN EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(node) e
            WHERE btrim(e) = 'block_bootstrap_lcb'
        );
    ELSIF jsonb_typeof(node) = 'object' THEN
        RETURN node ? 'block_bootstrap_lcb';
    END IF;
    RETURN false;
END;
$$;

CREATE FUNCTION compute_block_bootstrap_lcb(
    pairs_value jsonb,
    construction_value jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    block_length integer;
    replications integer;
    seed_value bigint;
    excess bigint[] := '{}';
    pair jsonb;
    n_starts integer;
    counter bigint := 0;
    rep integer;
    filled integer;
    start_at integer;
    j integer;
    acc bigint;
    mean_bps bigint;
    means bigint[] := '{}';
    sorted bigint[];
    quantile_index integer;
    lcb bigint;
    sample_sum bigint := 0;
    sample_mean bigint;
    means_digest text;
    result jsonb;
BEGIN
    PERFORM bootstrap_assert_construction(construction_value);
    PERFORM bootstrap_assert_pairs(pairs_value);

    n := jsonb_array_length(pairs_value);
    block_length := (construction_value->'block_length')::integer;
    replications := (construction_value->'replications')::integer;
    seed_value := strategy_sandbox_integer(construction_value->'seed');
    IF block_length > n THEN
        RAISE EXCEPTION 'block bootstrap construction is not preregistered'
            USING ERRCODE = '22023';
    END IF;

    FOR pair IN SELECT jsonb_array_elements(pairs_value) LOOP
        excess := excess || (
            strategy_sandbox_integer(pair->'strategy_bps')
            - strategy_sandbox_integer(pair->'comparator_bps')
        );
    END LOOP;

    n_starts := n - block_length + 1;
    FOR i IN 1 .. n LOOP
        sample_sum := sample_sum + excess[i];
    END LOOP;
    sample_mean := floor(sample_sum::numeric / n::numeric)::bigint;

    FOR rep IN 1 .. replications LOOP
        acc := 0;
        filled := 0;
        WHILE filled < n LOOP
            counter := counter + 1;
            start_at := (bootstrap_u32(seed_value, counter) % n_starts)::integer + 1;
            j := 0;
            WHILE j < block_length AND filled < n LOOP
                acc := acc + excess[start_at + j];
                filled := filled + 1;
                j := j + 1;
            END LOOP;
        END LOOP;
        mean_bps := floor(acc::numeric / n::numeric)::bigint;
        means := means || mean_bps;
    END LOOP;

    SELECT coalesce(array_agg(x ORDER BY x), '{}')
    INTO sorted
    FROM unnest(means) AS x;

    quantile_index := greatest(1, ceil(0.05 * replications)::integer);
    lcb := sorted[quantile_index];
    means_digest := encode(
        digest(convert_to(
            'market-mate-bootstrap-means-v1|' || to_jsonb(sorted)::text,
            'UTF8'), 'sha256'),
        'hex');

    result := jsonb_build_object(
        'engine', 'block_bootstrap_lcb_v1',
        'method', 'moving_block_bootstrap',
        'block_length', block_length,
        'replications', replications,
        'seed', seed_value,
        'confidence', 95,
        'side', 'one_sided_lower',
        'n', n,
        'mean_excess_bps', sample_mean,
        'lcb_excess_bps', lcb,
        'quantile_index', quantile_index,
        'means_digest', means_digest
    );
    RETURN result || jsonb_build_object(
        'result_digest', bootstrap_result_digest(result));
END;
$$;

CREATE TABLE block_bootstrap_run (
    run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_version_id uuid
        REFERENCES strategy_version(strategy_version_id),
    eis_estimate_id uuid
        REFERENCES eis_estimate(estimate_id),
    construction jsonb NOT NULL CHECK (jsonb_typeof(construction) = 'object'),
    construction_digest text NOT NULL CHECK (construction_digest ~ '^[0-9a-f]{64}$'),
    pairs jsonb NOT NULL CHECK (jsonb_typeof(pairs) = 'array'),
    pairs_digest text NOT NULL CHECK (pairs_digest ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (construction_digest = bootstrap_construction_digest(construction)),
    CHECK (pairs_digest = bootstrap_pairs_digest(pairs)),
    CHECK (result_digest = bootstrap_result_digest(result - 'result_digest')),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('block_bootstrap_run');

CREATE UNIQUE INDEX block_bootstrap_run_content_uq
    ON block_bootstrap_run (pairs_digest, construction_digest);
CREATE UNIQUE INDEX block_bootstrap_run_strategy_pairs_uq
    ON block_bootstrap_run (strategy_version_id, pairs_digest)
    WHERE strategy_version_id IS NOT NULL;

CREATE FUNCTION guard_block_bootstrap_run_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'block_bootstrap_run is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER block_bootstrap_run_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON block_bootstrap_run
    FOR EACH STATEMENT EXECUTE FUNCTION guard_block_bootstrap_run_write();

CREATE FUNCTION guard_block_bootstrap_run_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.bootstrap_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            'block_bootstrap_run writes must go through record_block_bootstrap_lcb'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER block_bootstrap_run_insert_guard
    BEFORE INSERT ON block_bootstrap_run
    FOR EACH ROW EXECUTE FUNCTION guard_block_bootstrap_run_insert();

CREATE FUNCTION record_block_bootstrap_lcb(
    pairs_value jsonb,
    construction_value jsonb,
    strategy_version_id_value uuid,
    eis_estimate_id_value uuid,
    source_lineage_value jsonb
) RETURNS block_bootstrap_run
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row strategy_version%ROWTYPE;
    registration_row experiment_preregistration%ROWTYPE;
    eis_row eis_estimate%ROWTYPE;
    derived jsonb;
    computed jsonb;
    stored_result jsonb;
    digest_value text;
    pairs_digest_value text;
    construction_digest_value text;
    existing block_bootstrap_run%ROWTYPE;
    created block_bootstrap_run%ROWTYPE;
BEGIN
    IF construction_value IS NULL
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'block bootstrap arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM bootstrap_assert_construction(construction_value);

    IF eis_estimate_id_value IS NOT NULL THEN
        SELECT * INTO eis_row
        FROM eis_estimate
        WHERE estimate_id = eis_estimate_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'eis estimate % is not registered',
                eis_estimate_id_value
                USING ERRCODE = '22023';
        END IF;
        IF eis_row.record_environment IS DISTINCT FROM 'local_research' THEN
            RAISE EXCEPTION 'block bootstrap can use only a Local Research EIS estimate'
                USING ERRCODE = '22023';
        END IF;
        derived := bootstrap_pairs_from_eis_result(eis_row.result);
        IF pairs_value IS NOT NULL AND pairs_value <> derived THEN
            RAISE EXCEPTION 'block bootstrap pairs do not match the EIS estimate'
                USING ERRCODE = '22023';
        END IF;
        pairs_value := derived;
    END IF;

    IF pairs_value IS NULL THEN
        RAISE EXCEPTION 'block bootstrap arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    IF strategy_version_id_value IS NOT NULL THEN
        SELECT * INTO version_row
        FROM strategy_version
        WHERE strategy_version_id = strategy_version_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'strategy version % is not registered',
                strategy_version_id_value
                USING ERRCODE = '22023';
        END IF;
        IF version_row.lifecycle_state IS DISTINCT FROM 'frozen'
           OR version_row.record_environment IS DISTINCT FROM 'local_research'
           OR lower(btrim(version_row.engine_binding->>'engine_kind'))
                IS DISTINCT FROM 'deterministic_dsl' THEN
            RAISE EXCEPTION
                'block bootstrap can bind only a frozen deterministic DSL Strategy Version'
                USING ERRCODE = '22023';
        END IF;
        SELECT * INTO registration_row
        FROM experiment_preregistration
        WHERE registration_id = version_row.registration_id;
        IF NOT FOUND
           OR NOT bootstrap_spec_requires_estimator(registration_row.spec) THEN
            RAISE EXCEPTION
                'block bootstrap construction is not preregistered'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    computed := compute_block_bootstrap_lcb(pairs_value, construction_value);
    stored_result := computed - 'result_digest';
    digest_value := bootstrap_result_digest(stored_result);
    pairs_digest_value := bootstrap_pairs_digest(pairs_value);
    construction_digest_value := bootstrap_construction_digest(construction_value);

    IF strategy_version_id_value IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(
            hashtextextended(strategy_version_id_value::text, 38024));
    END IF;
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            pairs_digest_value || ':' || construction_digest_value, 38023));

    SELECT * INTO existing
    FROM block_bootstrap_run
    WHERE pairs_digest = pairs_digest_value
      AND construction_digest = construction_digest_value;
    IF FOUND THEN
        IF existing.strategy_version_id IS DISTINCT FROM strategy_version_id_value
           OR existing.eis_estimate_id IS DISTINCT FROM eis_estimate_id_value THEN
            RAISE EXCEPTION
                'block bootstrap run is already recorded on a different lineage'
                USING ERRCODE = '23505';
        END IF;
        IF existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION 'block bootstrap run is not deterministic for this seed'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    IF strategy_version_id_value IS NOT NULL THEN
        SELECT * INTO existing
        FROM block_bootstrap_run
        WHERE strategy_version_id = strategy_version_id_value
        LIMIT 1;
        IF FOUND AND existing.construction_digest IS DISTINCT FROM construction_digest_value THEN
            RAISE EXCEPTION
                'block bootstrap construction cannot change after results exist'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.bootstrap_write', 'on', true);
    BEGIN
        INSERT INTO block_bootstrap_run (
            strategy_version_id, eis_estimate_id, construction, construction_digest,
            pairs, pairs_digest, result, result_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            strategy_version_id_value, eis_estimate_id_value,
            construction_value, construction_digest_value,
            pairs_value, pairs_digest_value, stored_result, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.bootstrap_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.bootstrap_write', 'off', true);

    PERFORM append_audit_event(
        'bootstrap:' || created.run_id::text,
        'research.block_bootstrap_lcb_recorded',
        now(),
        jsonb_build_object(
            'run_id', created.run_id,
            'strategy_version_id', strategy_version_id_value,
            'eis_estimate_id', eis_estimate_id_value,
            'construction_digest', construction_digest_value,
            'pairs_digest', pairs_digest_value,
            'result_digest', digest_value,
            'seed', stored_result->>'seed',
            'lcb_excess_bps', stored_result->>'lcb_excess_bps'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION record_block_bootstrap_lcb(jsonb, jsonb, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON block_bootstrap_run FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
