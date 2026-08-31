-- WU-31 Evidence budgets and multiplicity: Experiment Family testing
-- budget and Holm correction by default (issue #42). A different
-- correction applies only when every family member preregistered it.
-- Exhausted budget refuses further trials and records the refusal.

CREATE FUNCTION experiment_family_key(spec_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN jsonb_typeof(spec_value->'experiment_family') IS DISTINCT FROM 'string'
             OR coalesce(btrim(spec_value->>'experiment_family'), '') = ''
        THEN NULL
        ELSE btrim(spec_value->>'experiment_family')
    END;
$$;

CREATE FUNCTION experiment_family_testing_budget(spec_value jsonb)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    node jsonb;
    n numeric;
BEGIN
    node := experiment_preregistration_spec_node(spec_value, 'budget', 'testing_budget');
    IF jsonb_typeof(node) = 'number' THEN
        n := node::numeric;
    ELSIF jsonb_typeof(node) = 'object' THEN
        IF jsonb_typeof(node->'family_trials') = 'number' THEN
            n := (node->'family_trials')::numeric;
        ELSIF jsonb_typeof(node->'trials') = 'number' THEN
            n := (node->'trials')::numeric;
        ELSE
            RETURN NULL;
        END IF;
    ELSE
        RETURN NULL;
    END IF;
    IF n IS NULL OR n <> floor(n) OR n < 1 OR n > 2147483647 THEN
        RETURN NULL;
    END IF;
    RETURN n::integer;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE FUNCTION experiment_family_correction_method(spec_value jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    node jsonb;
    method_text text;
BEGIN
    node := experiment_preregistration_spec_node(
        spec_value, 'multiplicity_plan', 'multiplicity');
    IF jsonb_typeof(node) = 'object' AND node ? 'method' THEN
        IF jsonb_typeof(node->'method') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'experiment family correction method is not preregistered'
                USING ERRCODE = '22023';
        END IF;
        method_text := lower(btrim(node->>'method'));
        IF method_text IN ('holm', 'holm-bonferroni', 'holm_bonferroni') THEN
            RETURN 'holm';
        END IF;
        IF method_text = 'bonferroni' THEN
            RETURN 'bonferroni';
        END IF;
        RAISE EXCEPTION
            'experiment family correction method % is not an allowed preregistered method',
            method_text
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(node) = 'string' THEN
        method_text := lower(btrim(node #>> '{}'));
        IF position('holm' in method_text) > 0 THEN
            RETURN 'holm';
        END IF;
        IF position('bonferroni' in method_text) > 0 THEN
            RETURN 'bonferroni';
        END IF;
    END IF;
    RETURN 'holm';
EXCEPTION
    WHEN SQLSTATE '22023' THEN
        RAISE;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'experiment family correction method is not preregistered'
            USING ERRCODE = '22023';
END;
$$;

CREATE FUNCTION experiment_family_alpha(spec_value jsonb)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    node jsonb;
    alpha_value numeric;
BEGIN
    node := experiment_preregistration_spec_node(
        spec_value, 'multiplicity_plan', 'multiplicity');
    IF jsonb_typeof(node) = 'object' AND node ? 'alpha' THEN
        IF jsonb_typeof(node->'alpha') IS DISTINCT FROM 'number' THEN
            RETURN NULL;
        END IF;
        alpha_value := (node->'alpha')::numeric;
        IF alpha_value <= 0 OR alpha_value > 1 THEN
            RETURN NULL;
        END IF;
        RETURN alpha_value;
    END IF;
    RETURN 0.05;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

CREATE FUNCTION holm_adjusted_p(p_values numeric[])
RETURNS numeric[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    m integer;
    i integer;
    j integer;
    order_idx integer[];
    result numeric[];
    running numeric := 0;
    tmp integer;
BEGIN
    m := cardinality(p_values);
    IF m IS NULL OR m < 1 THEN
        RAISE EXCEPTION 'Holm correction requires at least one p-value'
            USING ERRCODE = '22023';
    END IF;
    FOR i IN 1 .. m LOOP
        IF p_values[i] IS NULL OR p_values[i] < 0 OR p_values[i] > 1 THEN
            RAISE EXCEPTION 'Holm correction p-values must be in [0, 1]'
                USING ERRCODE = '22023';
        END IF;
        order_idx := coalesce(order_idx, '{}'::integer[]) || i;
    END LOOP;
    FOR i IN 1 .. m - 1 LOOP
        FOR j IN i + 1 .. m LOOP
            IF p_values[order_idx[j]] < p_values[order_idx[i]]
               OR (p_values[order_idx[j]] = p_values[order_idx[i]]
                   AND order_idx[j] < order_idx[i]) THEN
                tmp := order_idx[i];
                order_idx[i] := order_idx[j];
                order_idx[j] := tmp;
            END IF;
        END LOOP;
    END LOOP;
    result := array_fill(NULL::numeric, ARRAY[m]);
    FOR i IN 1 .. m LOOP
        running := greatest(running, least(1, p_values[order_idx[i]] * (m - i + 1)));
        result[order_idx[i]] := running;
    END LOOP;
    RETURN result;
END;
$$;

CREATE FUNCTION bonferroni_adjusted_p(p_values numeric[])
RETURNS numeric[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(array_agg(least(1::numeric, u.p * cardinality(p_values)) ORDER BY u.ord), '{}')
    FROM unnest(p_values) WITH ORDINALITY AS u(p, ord);
$$;

CREATE FUNCTION experiment_trial_digest(
    registration_id_value uuid,
    family_key_value text,
    outcome_value text,
    p_value_value numeric
) RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            jsonb_build_object(
                'registration_id', registration_id_value,
                'family_key', family_key_value,
                'outcome', outcome_value,
                'p_value', p_value_value
            )::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE TABLE experiment_trial (
    trial_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id uuid NOT NULL
        REFERENCES experiment_preregistration(registration_id),
    family_key text NOT NULL CHECK (btrim(family_key) <> ''),
    outcome text NOT NULL CHECK (outcome IN (
        'successful', 'null', 'failed', 'invalid', 'aborted', 'interrupted'
    )),
    p_value numeric CHECK (p_value IS NULL OR (p_value >= 0 AND p_value <= 1)),
    trial_digest text NOT NULL CHECK (trial_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        trial_digest
        = experiment_trial_digest(registration_id, family_key, outcome, p_value)
    )
);

SELECT register_evidence_table('experiment_trial');

CREATE TABLE experiment_trial_refusal (
    refusal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id uuid NOT NULL
        REFERENCES experiment_preregistration(registration_id),
    family_key text NOT NULL CHECK (btrim(family_key) <> ''),
    reserved_trials integer NOT NULL CHECK (reserved_trials >= 1),
    consumed_trials integer NOT NULL CHECK (consumed_trials >= 0),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('experiment_trial_refusal');

CREATE TABLE experiment_family_correction (
    correction_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    family_key text NOT NULL CHECK (btrim(family_key) <> ''),
    method text NOT NULL CHECK (method IN ('holm', 'bonferroni')),
    alpha numeric NOT NULL CHECK (alpha > 0 AND alpha <= 1),
    member_count integer NOT NULL CHECK (member_count >= 1),
    adjustments jsonb NOT NULL CHECK (jsonb_typeof(adjustments) = 'array'),
    correction_digest text NOT NULL CHECK (correction_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        correction_digest
        = encode(digest(convert_to(adjustments::text, 'UTF8'), 'sha256'), 'hex')
    )
);

SELECT register_evidence_table('experiment_family_correction');

CREATE INDEX experiment_trial_family_idx
    ON experiment_trial (family_key, receipt_time);
CREATE INDEX experiment_trial_registration_idx
    ON experiment_trial (registration_id, receipt_time);
CREATE INDEX experiment_trial_refusal_family_idx
    ON experiment_trial_refusal (family_key, receipt_time);
CREATE INDEX experiment_family_correction_family_idx
    ON experiment_family_correction (family_key, receipt_time);

CREATE FUNCTION guard_experiment_trial_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'experiment_trial is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_experiment_trial_refusal_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'experiment_trial_refusal is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_experiment_family_correction_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'experiment_family_correction is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER experiment_trial_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON experiment_trial
    FOR EACH STATEMENT EXECUTE FUNCTION guard_experiment_trial_write();
CREATE TRIGGER experiment_trial_refusal_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON experiment_trial_refusal
    FOR EACH STATEMENT EXECUTE FUNCTION guard_experiment_trial_refusal_write();
CREATE TRIGGER experiment_family_correction_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON experiment_family_correction
    FOR EACH STATEMENT EXECUTE FUNCTION guard_experiment_family_correction_write();

CREATE FUNCTION guard_experiment_trial_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.experiment_trial_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'experiment_trial writes must go through record_experiment_trial'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_experiment_trial_refusal_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.experiment_trial_refusal_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'experiment_trial_refusal writes must go through record_experiment_trial'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_experiment_family_correction_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.experiment_family_correction_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            'experiment_family_correction writes must go through compute_experiment_family_correction'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER experiment_trial_insert_guard
    BEFORE INSERT ON experiment_trial
    FOR EACH ROW EXECUTE FUNCTION guard_experiment_trial_insert();
CREATE TRIGGER experiment_trial_refusal_insert_guard
    BEFORE INSERT ON experiment_trial_refusal
    FOR EACH ROW EXECUTE FUNCTION guard_experiment_trial_refusal_insert();
CREATE TRIGGER experiment_family_correction_insert_guard
    BEFORE INSERT ON experiment_family_correction
    FOR EACH ROW EXECUTE FUNCTION guard_experiment_family_correction_insert();

CREATE FUNCTION experiment_family_consumed_trials(family_key_value text)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT count(*)::integer
    FROM experiment_trial t
    WHERE t.family_key = family_key_value;
$$;

CREATE FUNCTION record_experiment_trial(
    registration_id_value uuid,
    outcome_value text,
    p_value_value numeric,
    source_lineage_value jsonb
) RETURNS experiment_trial
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    registration_row experiment_preregistration%ROWTYPE;
    predecessor experiment_preregistration%ROWTYPE;
    member experiment_preregistration%ROWTYPE;
    family_key_value text;
    reserved integer;
    method_value text;
    alpha_value numeric;
    consumed integer;
    created experiment_trial%ROWTYPE;
    created_refusal experiment_trial_refusal%ROWTYPE;
BEGIN
    IF registration_id_value IS NULL
       OR outcome_value NOT IN (
            'successful', 'null', 'failed', 'invalid', 'aborted', 'interrupted'
       )
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'experiment trial arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF p_value_value IS NOT NULL AND (p_value_value < 0 OR p_value_value > 1) THEN
        RAISE EXCEPTION 'experiment trial p_value must be in [0, 1]'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO registration_row
    FROM experiment_preregistration
    WHERE registration_id = registration_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'experiment preregistration % is not registered',
            registration_id_value
            USING ERRCODE = '22023';
    END IF;

    family_key_value := experiment_family_key(registration_row.spec);
    IF family_key_value IS NULL THEN
        RAISE EXCEPTION
            'experiment trial requires a preregistered experiment_family'
            USING ERRCODE = '22023';
    END IF;
    reserved := experiment_family_testing_budget(registration_row.spec);
    IF reserved IS NULL THEN
        RAISE EXCEPTION
            'experiment trial requires a preregistered family testing budget'
            USING ERRCODE = '22023';
    END IF;
    method_value := experiment_family_correction_method(registration_row.spec);
    alpha_value := experiment_family_alpha(registration_row.spec);
    IF alpha_value IS NULL THEN
        RAISE EXCEPTION 'experiment family alpha is invalid'
            USING ERRCODE = '22023';
    END IF;

    predecessor := registration_row;
    LOOP
        EXIT WHEN predecessor.successor_of IS NULL;
        SELECT * INTO predecessor
        FROM experiment_preregistration
        WHERE registration_id = predecessor.successor_of;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'experiment preregistration successor is not registered'
                USING ERRCODE = '22023';
        END IF;
        IF experiment_family_key(predecessor.spec) IS DISTINCT FROM family_key_value THEN
            RAISE EXCEPTION
                'experiment family cannot change along a registration successor chain'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    PERFORM pg_advisory_xact_lock(hashtextextended(family_key_value, 32023));

    FOR member IN
        SELECT r.*
        FROM experiment_preregistration r
        WHERE experiment_family_key(r.spec) = family_key_value
    LOOP
        IF experiment_family_testing_budget(member.spec) IS DISTINCT FROM reserved THEN
            RAISE EXCEPTION
                'experiment family % members must reserve the same testing budget',
                family_key_value
                USING ERRCODE = '22023';
        END IF;
        IF experiment_family_correction_method(member.spec) IS DISTINCT FROM method_value THEN
            RAISE EXCEPTION
                'experiment family % members must preregister the same correction method',
                family_key_value
                USING ERRCODE = '22023';
        END IF;
        IF experiment_family_alpha(member.spec) IS DISTINCT FROM alpha_value THEN
            RAISE EXCEPTION
                'experiment family % members must preregister the same alpha',
                family_key_value
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    consumed := experiment_family_consumed_trials(family_key_value);
    IF consumed >= reserved THEN
        PERFORM set_config('market_mate.experiment_trial_refusal_write', 'on', true);
        BEGIN
            INSERT INTO experiment_trial_refusal (
                registration_id, family_key, reserved_trials, consumed_trials,
                reason, source_lineage, receipt_time, record_environment
            ) VALUES (
                registration_id_value, family_key_value, reserved, consumed,
                'testing budget exhausted',
                source_lineage_value, clock_timestamp(), 'local_research'
            )
            RETURNING * INTO created_refusal;
        EXCEPTION
            WHEN OTHERS THEN
                PERFORM set_config('market_mate.experiment_trial_refusal_write', 'off', true);
                RAISE;
        END;
        PERFORM set_config('market_mate.experiment_trial_refusal_write', 'off', true);
        PERFORM append_audit_event(
            'experiment-trial-refusal:' || created_refusal.refusal_id::text,
            'research.experiment_trial_refused',
            now(),
            jsonb_build_object(
                'refusal_id', created_refusal.refusal_id,
                'registration_id', registration_id_value,
                'family_key', family_key_value,
                'reserved_trials', reserved,
                'consumed_trials', consumed
            ),
            source_lineage_value,
            now(),
            'local_research'
        );
        RETURN NULL;
    END IF;

    PERFORM set_config('market_mate.experiment_trial_write', 'on', true);
    BEGIN
        INSERT INTO experiment_trial (
            registration_id, family_key, outcome, p_value, trial_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            registration_id_value, family_key_value, outcome_value, p_value_value,
            experiment_trial_digest(
                registration_id_value, family_key_value, outcome_value, p_value_value),
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.experiment_trial_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.experiment_trial_write', 'off', true);

    PERFORM append_audit_event(
        'experiment-trial:' || created.trial_id::text,
        'research.experiment_trial_recorded',
        now(),
        jsonb_build_object(
            'trial_id', created.trial_id,
            'registration_id', registration_id_value,
            'family_key', family_key_value,
            'outcome', outcome_value,
            'p_value', p_value_value,
            'consumed_trials', consumed + 1,
            'reserved_trials', reserved
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE FUNCTION compute_experiment_family_correction(
    family_key_value text,
    source_lineage_value jsonb
) RETURNS experiment_family_correction
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    member experiment_preregistration%ROWTYPE;
    method_value text;
    alpha_value numeric;
    reserved integer;
    ids uuid[] := '{}';
    p_values numeric[] := '{}';
    adjusted numeric[];
    n integer;
    i integer;
    adjustments jsonb := '[]'::jsonb;
    created experiment_family_correction%ROWTYPE;
    latest experiment_trial%ROWTYPE;
BEGIN
    IF coalesce(btrim(family_key_value), '') = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'experiment family correction arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(family_key_value, 32023));

    FOR member IN
        SELECT r.*
        FROM experiment_preregistration r
        WHERE experiment_family_key(r.spec) = family_key_value
        ORDER BY r.receipt_time, r.registration_id
    LOOP
        IF method_value IS NULL THEN
            method_value := experiment_family_correction_method(member.spec);
            alpha_value := experiment_family_alpha(member.spec);
            reserved := experiment_family_testing_budget(member.spec);
        ELSE
            IF experiment_family_correction_method(member.spec) IS DISTINCT FROM method_value
               OR experiment_family_alpha(member.spec) IS DISTINCT FROM alpha_value
               OR experiment_family_testing_budget(member.spec) IS DISTINCT FROM reserved THEN
                RAISE EXCEPTION
                    'experiment family % members must preregister the same correction, alpha, and budget',
                    family_key_value
                    USING ERRCODE = '22023';
            END IF;
        END IF;
        SELECT t.* INTO latest
        FROM experiment_trial t
        WHERE t.registration_id = member.registration_id
          AND t.p_value IS NOT NULL
        ORDER BY t.receipt_time DESC, t.trial_id DESC
        LIMIT 1;
        IF latest.trial_id IS NOT NULL THEN
            ids := ids || member.registration_id;
            p_values := p_values || latest.p_value;
        END IF;
    END LOOP;

    n := coalesce(cardinality(p_values), 0);
    IF n < 1 THEN
        RAISE EXCEPTION
            'experiment family % has no p-values to correct',
            family_key_value
            USING ERRCODE = '22023';
    END IF;
    IF method_value = 'bonferroni' THEN
        adjusted := bonferroni_adjusted_p(p_values);
    ELSE
        adjusted := holm_adjusted_p(p_values);
    END IF;

    FOR i IN 1 .. n LOOP
        adjustments := adjustments || jsonb_build_array(
            jsonb_build_object(
                'registration_id', ids[i],
                'p_value', p_values[i],
                'adjusted_p', adjusted[i],
                'rejected', adjusted[i] <= alpha_value
            )
        );
    END LOOP;

    PERFORM set_config('market_mate.experiment_family_correction_write', 'on', true);
    BEGIN
        INSERT INTO experiment_family_correction (
            family_key, method, alpha, member_count, adjustments,
            correction_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            family_key_value, method_value, alpha_value, n, adjustments,
            encode(digest(convert_to(adjustments::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.experiment_family_correction_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.experiment_family_correction_write', 'off', true);

    PERFORM append_audit_event(
        'experiment-family-correction:' || created.correction_id::text,
        'research.experiment_family_correction_computed',
        now(),
        jsonb_build_object(
            'correction_id', created.correction_id,
            'family_key', family_key_value,
            'method', method_value,
            'alpha', alpha_value,
            'member_count', n,
            'correction_digest', created.correction_digest
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION record_experiment_trial(uuid, text, numeric, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION compute_experiment_family_correction(text, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON experiment_trial, experiment_trial_refusal, experiment_family_correction
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
