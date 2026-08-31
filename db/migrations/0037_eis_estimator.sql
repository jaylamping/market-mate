-- WU-35 EIS estimator and cluster counting: economically dependent
-- observations collapse to one cluster; legs, partial fills, and retries
-- never inflate the count. EIS is autocorrelation- and cluster-adjusted.
-- Every floor is the lower of raw independent-cluster count and EIS.

CREATE FUNCTION eis_holdings_overlap(
    a_entry date,
    a_exit date,
    b_entry date,
    b_exit date
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT a_entry IS NOT NULL AND a_exit IS NOT NULL
       AND b_entry IS NOT NULL AND b_exit IS NOT NULL
       AND a_entry < a_exit AND b_entry < b_exit
       AND a_entry < b_exit AND b_entry < a_exit;
$$;

CREATE FUNCTION eis_observation_text(node jsonb, key_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN jsonb_typeof(node -> key_name) IS DISTINCT FROM 'string' THEN NULL
        WHEN coalesce(btrim(node ->> key_name), '') = '' THEN NULL
        ELSE btrim(node ->> key_name)
    END;
$$;

CREATE FUNCTION eis_result_digest(result_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-eis-v1|' || result_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION eis_observations_digest(observations_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-eis-observations-v1|' || observations_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION eis_assert_observations(observations_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    obs jsonb;
    n integer;
    allowed text[] := ARRAY[
        'observation_id', 'thesis_key', 'issuer', 'issuer_event_id',
        'entry_session', 'exit_session', 'shock_id',
        'parent_observation_id', 'attempt_group_id', 'dependent_exit_of',
        'return_bps'
    ];
    id_text text;
    thesis_text text;
    issuer_text text;
    entry_date date;
    exit_date date;
    ids text[] := '{}';
BEGIN
    IF jsonb_typeof(observations_value) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'eis observations are not admissible'
            USING ERRCODE = '22023';
    END IF;
    n := jsonb_array_length(observations_value);
    IF n < 1 OR n > 1024 THEN
        RAISE EXCEPTION 'eis observations exceed the resource bound'
            USING ERRCODE = '22023';
    END IF;

    FOR obs IN SELECT jsonb_array_elements(observations_value) LOOP
        IF jsonb_typeof(obs) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(obs) k
                WHERE k <> ALL (allowed)
           ) THEN
            RAISE EXCEPTION 'eis observations contain out-of-scope keys'
                USING ERRCODE = '22023';
        END IF;
        id_text := eis_observation_text(obs, 'observation_id');
        thesis_text := eis_observation_text(obs, 'thesis_key');
        issuer_text := eis_observation_text(obs, 'issuer');
        entry_date := walk_forward_parse_session_date(obs->'entry_session');
        exit_date := walk_forward_parse_session_date(obs->'exit_session');
        IF id_text IS NULL OR thesis_text IS NULL OR issuer_text IS NULL
           OR entry_date IS NULL OR exit_date IS NULL
           OR entry_date >= exit_date
           OR strategy_sandbox_integer(obs->'return_bps') IS NULL THEN
            RAISE EXCEPTION 'eis observations are not admissible'
                USING ERRCODE = '22023';
        END IF;
        IF id_text = ANY (ids) THEN
            RAISE EXCEPTION 'eis observations are not admissible'
                USING ERRCODE = '22023';
        END IF;
        ids := ids || id_text;
    END LOOP;
END;
$$;

CREATE FUNCTION eis_cluster_observations(observations_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    i integer;
    j integer;
    a integer;
    b integer;
    parent integer[] := '{}';
    obs jsonb[] := '{}';
    ids text[] := '{}';
    thesis text[] := '{}';
    issuer text[] := '{}';
    event_id text[] := '{}';
    shock text[] := '{}';
    attempt_group text[] := '{}';
    parent_id text[] := '{}';
    dep_exit text[] := '{}';
    entry_date date[] := '{}';
    exit_date date[] := '{}';
    ret bigint[] := '{}';
    cluster_obs text[];
    cluster_sum bigint;
    cluster_n integer;
    first_entry date;
    last_exit date;
    clusters jsonb := '[]'::jsonb;
    cluster_no integer := 0;
    seen boolean[] := '{}';
    ra integer;
    rb integer;
BEGIN
    PERFORM eis_assert_observations(observations_value);
    n := jsonb_array_length(observations_value);

    FOR i IN 1 .. n LOOP
        parent := parent || i;
        obs := obs || (observations_value -> (i - 1));
        ids := ids || eis_observation_text(obs[i], 'observation_id');
        thesis := thesis || eis_observation_text(obs[i], 'thesis_key');
        issuer := issuer || eis_observation_text(obs[i], 'issuer');
        event_id := event_id || eis_observation_text(obs[i], 'issuer_event_id');
        shock := shock || eis_observation_text(obs[i], 'shock_id');
        attempt_group := attempt_group || eis_observation_text(obs[i], 'attempt_group_id');
        parent_id := parent_id || eis_observation_text(obs[i], 'parent_observation_id');
        dep_exit := dep_exit || eis_observation_text(obs[i], 'dependent_exit_of');
        entry_date := entry_date || walk_forward_parse_session_date(obs[i]->'entry_session');
        exit_date := exit_date || walk_forward_parse_session_date(obs[i]->'exit_session');
        ret := ret || strategy_sandbox_integer(obs[i]->'return_bps');
        seen := seen || false;
    END LOOP;

    FOR i IN 1 .. n LOOP
        IF parent_id[i] IS NOT NULL AND parent_id[i] <> ALL (ids) THEN
            RAISE EXCEPTION 'eis observations are not admissible'
                USING ERRCODE = '22023';
        END IF;
        IF dep_exit[i] IS NOT NULL AND dep_exit[i] <> ALL (ids) THEN
            RAISE EXCEPTION 'eis observations are not admissible'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    FOR i IN 1 .. n LOOP
        FOR j IN i + 1 .. n LOOP
            IF (attempt_group[i] IS NOT NULL AND attempt_group[i] = attempt_group[j])
               OR (parent_id[i] IS NOT NULL AND parent_id[i] = ids[j])
               OR (parent_id[j] IS NOT NULL AND parent_id[j] = ids[i])
               OR (dep_exit[i] IS NOT NULL AND dep_exit[i] = ids[j])
               OR (dep_exit[j] IS NOT NULL AND dep_exit[j] = ids[i])
               OR (event_id[i] IS NOT NULL AND event_id[i] = event_id[j])
               OR (shock[i] IS NOT NULL AND shock[i] = shock[j])
               OR (
                    eis_holdings_overlap(
                        entry_date[i], exit_date[i], entry_date[j], exit_date[j])
                    AND (issuer[i] = issuer[j] OR thesis[i] = thesis[j])
               )
               OR (exit_date[i] = exit_date[j] AND thesis[i] = thesis[j])
            THEN
                a := i;
                WHILE parent[a] <> a LOOP
                    a := parent[a];
                END LOOP;
                b := j;
                WHILE parent[b] <> b LOOP
                    b := parent[b];
                END LOOP;
                IF a <> b THEN
                    parent[b] := a;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    FOR i IN 1 .. n LOOP
        a := i;
        WHILE parent[a] <> a LOOP
            a := parent[a];
        END LOOP;
        parent[i] := a;
    END LOOP;

    FOR i IN 1 .. n LOOP
        IF seen[i] THEN
            CONTINUE;
        END IF;
        ra := parent[i];
        cluster_obs := '{}';
        cluster_sum := 0;
        cluster_n := 0;
        first_entry := NULL;
        last_exit := NULL;
        FOR j IN 1 .. n LOOP
            IF parent[j] = ra THEN
                seen[j] := true;
                cluster_obs := cluster_obs || ids[j];
                cluster_sum := cluster_sum + ret[j];
                cluster_n := cluster_n + 1;
                IF first_entry IS NULL OR entry_date[j] < first_entry THEN
                    first_entry := entry_date[j];
                END IF;
                IF last_exit IS NULL OR exit_date[j] > last_exit THEN
                    last_exit := exit_date[j];
                END IF;
            END IF;
        END LOOP;
        SELECT coalesce(array_agg(x ORDER BY x), '{}')
        INTO cluster_obs
        FROM unnest(cluster_obs) AS x;
        cluster_no := cluster_no + 1;
        clusters := clusters || jsonb_build_array(
            jsonb_build_object(
                'cluster_id', cluster_no,
                'observation_ids', to_jsonb(cluster_obs),
                'observation_count', cluster_n,
                'return_bps', cluster_sum / cluster_n,
                'first_entry_session', to_char(first_entry, 'YYYY-MM-DD'),
                'last_exit_session', to_char(last_exit, 'YYYY-MM-DD')
            )
        );
    END LOOP;

    SELECT coalesce(jsonb_agg(c ORDER BY c->>'first_entry_session', c->'observation_ids'->>0), '[]'::jsonb)
    INTO clusters
    FROM jsonb_array_elements(clusters) AS c;

    SELECT jsonb_agg(
        jsonb_set(c, '{cluster_id}', to_jsonb(ord::integer))
        ORDER BY ord
    )
    INTO clusters
    FROM jsonb_array_elements(clusters) WITH ORDINALITY AS t(c, ord);

    RETURN jsonb_build_object(
        'observation_count', n,
        'cluster_count', jsonb_array_length(clusters),
        'clusters', clusters
    );
END;
$$;

CREATE FUNCTION eis_lag1_autocorr_e6(returns bigint[])
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    k integer;
    i integer;
    n_pairs numeric;
    sum_x numeric := 0;
    sum_y numeric := 0;
    sum_xx numeric := 0;
    sum_yy numeric := 0;
    sum_xy numeric := 0;
    x numeric;
    y numeric;
    num numeric;
    den numeric;
    rho numeric;
BEGIN
    k := coalesce(cardinality(returns), 0);
    IF k < 3 THEN
        RETURN NULL;
    END IF;
    n_pairs := (k - 1)::numeric;
    FOR i IN 1 .. k - 1 LOOP
        x := returns[i]::numeric;
        y := returns[i + 1]::numeric;
        sum_x := sum_x + x;
        sum_y := sum_y + y;
        sum_xx := sum_xx + x * x;
        sum_yy := sum_yy + y * y;
        sum_xy := sum_xy + x * y;
    END LOOP;
    num := n_pairs * sum_xy - sum_x * sum_y;
    den := sqrt(n_pairs * sum_xx - sum_x * sum_x)
        * sqrt(n_pairs * sum_yy - sum_y * sum_y);
    IF den IS NULL OR den = 0 THEN
        RETURN 1000000;
    END IF;
    rho := num / den;
    IF rho >= 0.999 THEN
        RETURN 1000000;
    END IF;
    IF rho <= -0.999 THEN
        RETURN -1000000;
    END IF;
    RETURN trunc(rho * 1000000)::bigint;
END;
$$;

CREATE FUNCTION compute_eis_estimate(observations_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    clustered jsonb;
    returns bigint[] := '{}';
    cl jsonb;
    k integer;
    rho_e6 bigint;
    eis_value bigint;
    floor_value bigint;
    result jsonb;
BEGIN
    clustered := eis_cluster_observations(observations_value);
    FOR cl IN
        SELECT c
        FROM jsonb_array_elements(clustered->'clusters') AS c
        ORDER BY (c->>'cluster_id')::integer
    LOOP
        returns := returns || (cl->>'return_bps')::bigint;
    END LOOP;
    k := (clustered->>'cluster_count')::integer;
    rho_e6 := eis_lag1_autocorr_e6(returns);
    IF k < 1 THEN
        RAISE EXCEPTION 'eis observations are not admissible'
            USING ERRCODE = '22023';
    END IF;
    IF k < 3 OR rho_e6 IS NULL THEN
        eis_value := k;
    ELSIF rho_e6 >= 1000000 THEN
        eis_value := 1;
    ELSIF rho_e6 <= 0 THEN
        eis_value := k;
    ELSE
        eis_value := floor(
            k::numeric * (1000000::numeric - rho_e6::numeric)
            / (1000000::numeric + rho_e6::numeric)
        )::bigint;
        IF eis_value < 1 THEN
            eis_value := 1;
        END IF;
    END IF;
    floor_value := LEAST(k, eis_value);
    result := jsonb_strip_nulls(
        jsonb_build_object(
            'engine', 'eis_v1',
            'observation_count', (clustered->>'observation_count')::integer,
            'cluster_count', k,
            'lag1_autocorr_e6', rho_e6,
            'eis', eis_value,
            'floor', floor_value,
            'clusters', clustered->'clusters'
        )
    );
    RETURN result || jsonb_build_object('result_digest', eis_result_digest(result));
END;
$$;

CREATE FUNCTION eis_observations_from_walk_forward_manifest(
    manifest_value jsonb,
    thesis_key_value text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    fold jsonb;
    trade jsonb;
    observations jsonb := '[]'::jsonb;
    obs_id text;
    entry_text text;
    exit_text text;
    symbol_text text;
BEGIN
    IF jsonb_typeof(manifest_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(manifest_value->'folds') IS DISTINCT FROM 'array'
       OR coalesce(btrim(thesis_key_value), '') = '' THEN
        RAISE EXCEPTION 'eis walk-forward manifest is not admissible'
            USING ERRCODE = '22023';
    END IF;
    FOR fold IN SELECT jsonb_array_elements(manifest_value->'folds') LOOP
        FOR trade IN SELECT jsonb_array_elements(
                coalesce(fold->'result'->'trades', '[]'::jsonb)
            ) LOOP
            symbol_text := btrim(trade->>'symbol');
            entry_text := btrim(trade->>'entry_session');
            exit_text := btrim(trade->>'exit_session');
            IF symbol_text IS NULL OR entry_text IS NULL OR exit_text IS NULL
               OR strategy_sandbox_integer(trade->'return_bps') IS NULL THEN
                RAISE EXCEPTION 'eis walk-forward manifest is not admissible'
                    USING ERRCODE = '22023';
            END IF;
            obs_id := (fold->>'window_index') || ':' || symbol_text
                || ':' || entry_text || ':' || exit_text;
            observations := observations || jsonb_build_array(
                jsonb_build_object(
                    'observation_id', obs_id,
                    'thesis_key', thesis_key_value,
                    'issuer', symbol_text,
                    'issuer_event_id', symbol_text || ':' || entry_text,
                    'entry_session', entry_text,
                    'exit_session', exit_text,
                    'attempt_group_id', obs_id,
                    'return_bps', strategy_sandbox_integer(trade->'return_bps')
                )
            );
        END LOOP;
    END LOOP;
    RETURN observations;
END;
$$;

CREATE TABLE eis_estimate (
    estimate_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    walk_forward_run_id uuid
        REFERENCES walk_forward_run(run_id),
    observations jsonb NOT NULL CHECK (jsonb_typeof(observations) = 'array'),
    observations_digest text NOT NULL CHECK (observations_digest ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (observations_digest = eis_observations_digest(observations)),
    CHECK (result_digest = eis_result_digest(result - 'result_digest')),
    CHECK ((result->>'floor')::bigint = LEAST(
        (result->>'cluster_count')::bigint,
        (result->>'eis')::bigint)),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('eis_estimate');

CREATE UNIQUE INDEX eis_estimate_observations_uq
    ON eis_estimate (observations_digest);
CREATE UNIQUE INDEX eis_estimate_run_uq
    ON eis_estimate (walk_forward_run_id)
    WHERE walk_forward_run_id IS NOT NULL;

CREATE FUNCTION guard_eis_estimate_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'eis_estimate is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER eis_estimate_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON eis_estimate
    FOR EACH STATEMENT EXECUTE FUNCTION guard_eis_estimate_write();

CREATE FUNCTION guard_eis_estimate_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.eis_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'eis_estimate writes must go through record_eis_estimate'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER eis_estimate_insert_guard
    BEFORE INSERT ON eis_estimate
    FOR EACH ROW EXECUTE FUNCTION guard_eis_estimate_insert();

CREATE FUNCTION record_eis_estimate(
    observations_value jsonb,
    walk_forward_run_id_value uuid,
    source_lineage_value jsonb
) RETURNS eis_estimate
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    run_row walk_forward_run%ROWTYPE;
    derived jsonb;
    computed jsonb;
    digest_value text;
    observations_digest_value text;
    stored_result jsonb;
    existing eis_estimate%ROWTYPE;
    created eis_estimate%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'eis estimate arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    IF walk_forward_run_id_value IS NOT NULL THEN
        SELECT * INTO run_row
        FROM walk_forward_run
        WHERE run_id = walk_forward_run_id_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'walk-forward run % is not registered',
                walk_forward_run_id_value
                USING ERRCODE = '22023';
        END IF;
        IF run_row.record_environment IS DISTINCT FROM 'local_research' THEN
            RAISE EXCEPTION 'eis can estimate only a Local Research walk-forward run'
                USING ERRCODE = '22023';
        END IF;
        derived := eis_observations_from_walk_forward_manifest(
            run_row.manifest, run_row.strategy_version_id::text);
        IF observations_value IS NOT NULL AND observations_value <> derived THEN
            RAISE EXCEPTION 'eis observations do not match the walk-forward run'
                USING ERRCODE = '22023';
        END IF;
        observations_value := derived;
    END IF;

    IF observations_value IS NULL THEN
        RAISE EXCEPTION 'eis estimate arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    computed := compute_eis_estimate(observations_value);
    stored_result := computed - 'result_digest';
    digest_value := eis_result_digest(stored_result);
    observations_digest_value := eis_observations_digest(observations_value);

    PERFORM pg_advisory_xact_lock(
        hashtextextended(observations_digest_value, 37023));

    SELECT * INTO existing
    FROM eis_estimate
    WHERE observations_digest = observations_digest_value;
    IF FOUND THEN
        IF existing.walk_forward_run_id IS DISTINCT FROM walk_forward_run_id_value THEN
            RAISE EXCEPTION
                'eis estimate observations are already recorded on a different walk-forward run'
                USING ERRCODE = '23505';
        END IF;
        IF existing.result_digest IS DISTINCT FROM digest_value THEN
            RAISE EXCEPTION 'eis estimate is not deterministic for these observations'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    IF walk_forward_run_id_value IS NOT NULL THEN
        SELECT * INTO existing
        FROM eis_estimate
        WHERE walk_forward_run_id = walk_forward_run_id_value;
        IF FOUND THEN
            RAISE EXCEPTION
                'eis estimate for this walk-forward run cannot change after results exist'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.eis_write', 'on', true);
    BEGIN
        INSERT INTO eis_estimate (
            walk_forward_run_id, observations, observations_digest,
            result, result_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            walk_forward_run_id_value, observations_value, observations_digest_value,
            stored_result, digest_value, source_lineage_value,
            clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.eis_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.eis_write', 'off', true);

    PERFORM append_audit_event(
        'eis:' || created.estimate_id::text,
        'research.eis_estimate_recorded',
        now(),
        jsonb_build_object(
            'estimate_id', created.estimate_id,
            'walk_forward_run_id', walk_forward_run_id_value,
            'observations_digest', observations_digest_value,
            'result_digest', digest_value,
            'cluster_count', stored_result->>'cluster_count',
            'eis', stored_result->>'eis',
            'floor', stored_result->>'floor'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION record_eis_estimate(jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON eis_estimate FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
