-- Cross-WU thermo-nuclear hardening for WU-28..WU-31:
--  1. Release holdout sealing fails closed when the EOD session calendar
--     is empty or shorter than the sealed segment (0031 skipped the suffix
--     check on an empty calendar).
--  2. Holm/Bonferroni m is the declared family size (current-tip
--     preregistrations in the family); members without a real p-value are
--     treated as 1. Result-bearing trials require a p_value.
--  3. experimental_indicator_lineage predecessor_stage_record_id is unique
--     when present, so a stage cannot fork.
--
-- The 0030 unique (experiment_key, spec_digest) index is left unchanged:
-- rewriting an applied migration fails closed on checksum, and append-only
-- preregistrations cannot be deleted to dedupe persisted volumes.

CREATE OR REPLACE FUNCTION register_experiment_preregistration(
    experiment_key_value text,
    spec_value jsonb,
    successor_of_value uuid,
    source_lineage_value jsonb
) RETURNS experiment_preregistration
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    spec_digest_value text;
    existing experiment_preregistration%ROWTYPE;
    tip_row experiment_preregistration%ROWTYPE;
    predecessor experiment_preregistration%ROWTYPE;
    created experiment_preregistration%ROWTYPE;
BEGIN
    IF coalesce(btrim(experiment_key_value), '') = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'experiment preregistration arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT experiment_preregistration_spec_is_complete(spec_value) THEN
        RAISE EXCEPTION
            'experiment preregistration spec is incomplete; hypothesis, windows, estimators, budget, stopping rule, and multiplicity plan are required'
            USING ERRCODE = '22023';
    END IF;
    IF spec_value ? 'experiment_key'
       AND spec_value->>'experiment_key' IS DISTINCT FROM experiment_key_value THEN
        RAISE EXCEPTION
            'experiment preregistration spec experiment_key does not match %',
            experiment_key_value
            USING ERRCODE = '22023';
    END IF;

    spec_digest_value := encode(
        digest('market-mate-preregistration-v1|' || spec_value::text, 'sha256'),
        'hex');

    PERFORM pg_advisory_xact_lock(hashtextextended(experiment_key_value, 30023));

    SELECT * INTO existing
    FROM experiment_preregistration
    WHERE experiment_key = experiment_key_value
      AND spec_digest = spec_digest_value;
    IF FOUND THEN
        IF existing.successor_of IS DISTINCT FROM successor_of_value THEN
            RAISE EXCEPTION
                'experiment % spec is already registered on a different successor lineage',
                experiment_key_value
            USING ERRCODE = '23505';
        END IF;
        RETURN existing;
    END IF;

    tip_row := experiment_preregistration_tip(experiment_key_value);
    IF successor_of_value IS NULL THEN
        IF tip_row.registration_id IS NOT NULL THEN
            RAISE EXCEPTION
                'experiment % already has a registration; post-hoc changes must set successor_of to the current registration',
                experiment_key_value
                USING ERRCODE = '22023';
        END IF;
    ELSE
        SELECT * INTO predecessor
        FROM experiment_preregistration
        WHERE registration_id = successor_of_value;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'experiment preregistration % is not registered',
                successor_of_value
                USING ERRCODE = '22023';
        END IF;
        IF predecessor.experiment_key IS DISTINCT FROM experiment_key_value THEN
            RAISE EXCEPTION
                'successor_of must belong to experiment %',
                experiment_key_value
                USING ERRCODE = '22023';
        END IF;
        IF tip_row.registration_id IS DISTINCT FROM successor_of_value THEN
            RAISE EXCEPTION
                'successor_of must be the current registration for %',
                experiment_key_value
                USING ERRCODE = '22023';
        END IF;
        IF experiment_family_key(spec_value)
              IS DISTINCT FROM experiment_family_key(predecessor.spec) THEN
            RAISE EXCEPTION
                'experiment family cannot change along a registration successor chain'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    PERFORM set_config('market_mate.experiment_preregistration_write', 'on', true);
    BEGIN
        INSERT INTO experiment_preregistration (
            experiment_key, spec, spec_digest, successor_of,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            experiment_key_value, spec_value, spec_digest_value, successor_of_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.experiment_preregistration_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.experiment_preregistration_write', 'off', true);

    PERFORM append_audit_event(
        'experiment-preregistration:' || created.registration_id::text,
        'research.experiment_preregistration_registered',
        now(),
        jsonb_build_object(
            'registration_id', created.registration_id,
            'experiment_key', experiment_key_value,
            'spec_digest', spec_digest_value,
            'successor_of', successor_of_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE OR REPLACE FUNCTION seal_release_holdout(
    session_dates_value date[],
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS release_holdout_seal
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    n integer;
    first_date date;
    last_date date;
    as_of_date date;
    digest_value text;
    existing release_holdout_seal%ROWTYPE;
    calendar_dates date[];
    suffix date[];
    created release_holdout_seal%ROWTYPE;
BEGIN
    IF as_of_value IS NULL
       OR as_of_value > clock_timestamp()
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'release holdout seal identity or as_of is invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT release_holdout_session_dates_are_valid(session_dates_value) THEN
        RAISE EXCEPTION
            'release holdout must be a strictly increasing sequence of at least 60 trading days'
            USING ERRCODE = '22023';
    END IF;

    n := cardinality(session_dates_value);
    first_date := session_dates_value[1];
    last_date := session_dates_value[n];
    as_of_date := (as_of_value AT TIME ZONE 'UTC')::date;
    IF last_date > as_of_date THEN
        RAISE EXCEPTION
            'release holdout last trading date must not be after as_of'
            USING ERRCODE = '22023';
    END IF;

    calendar_dates := core_indicator_session_calendar_as_of(as_of_value);
    IF coalesce(cardinality(calendar_dates), 0) < n THEN
        RAISE EXCEPTION
            'release holdout requires % sessions visible at as_of; the calendar has %',
            n, coalesce(cardinality(calendar_dates), 0)
            USING ERRCODE = '22023';
    END IF;
    suffix := calendar_dates[cardinality(calendar_dates) - n + 1
                             : cardinality(calendar_dates)];
    IF suffix IS DISTINCT FROM session_dates_value THEN
        RAISE EXCEPTION
            'release holdout must be the most recent % trading days visible at as_of',
            n
            USING ERRCODE = '22023';
    END IF;

    digest_value := release_holdout_seal_digest(session_dates_value);

    PERFORM pg_advisory_xact_lock(hashtextextended('release-holdout', 31023));

    SELECT * INTO existing
    FROM release_holdout_seal
    WHERE seal_digest = digest_value;
    IF FOUND THEN
        RETURN existing;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM release_holdout_seal s
        WHERE NOT release_holdout_is_consumed(s.holdout_id)
    ) THEN
        RAISE EXCEPTION
            'an unconsumed release holdout is already sealed'
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.release_holdout_seal_write', 'on', true);
    BEGIN
        INSERT INTO release_holdout_seal (
            first_trading_date, last_trading_date, session_count, session_dates,
            as_of_at, seal_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            first_date, last_date, n, session_dates_value,
            as_of_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.release_holdout_seal_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.release_holdout_seal_write', 'off', true);

    PERFORM append_audit_event(
        'release-holdout-seal:' || created.holdout_id::text,
        'research.release_holdout_sealed',
        now(),
        jsonb_build_object(
            'holdout_id', created.holdout_id,
            'first_trading_date', first_date,
            'last_trading_date', last_date,
            'session_count', n,
            'seal_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE OR REPLACE FUNCTION record_experiment_trial(
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
    IF outcome_value IN ('successful', 'null', 'failed', 'invalid')
       AND p_value_value IS NULL THEN
        RAISE EXCEPTION
            'experiment trial p_value is required for result-bearing outcomes'
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

CREATE OR REPLACE FUNCTION compute_experiment_family_correction(
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
    declared_m integer := 0;
    real_p_count integer := 0;
    i integer;
    adjustments jsonb := '[]'::jsonb;
    created experiment_family_correction%ROWTYPE;
    latest experiment_trial%ROWTYPE;
    is_current_tip boolean;
    family_leaving_successor boolean;
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

        -- A same-family successor replaces its predecessor. A successor that
        -- leaves the family is fail-closed so Holm m cannot shrink post-hoc.
        SELECT EXISTS (
            SELECT 1
            FROM experiment_preregistration later
            WHERE later.successor_of = member.registration_id
              AND experiment_family_key(later.spec) IS DISTINCT FROM family_key_value
        ) INTO family_leaving_successor;
        IF family_leaving_successor THEN
            RAISE EXCEPTION
                'experiment family cannot change along a registration successor chain'
                USING ERRCODE = '22023';
        END IF;
        SELECT NOT EXISTS (
            SELECT 1
            FROM experiment_preregistration later
            WHERE later.successor_of = member.registration_id
              AND experiment_family_key(later.spec) = family_key_value
        ) INTO is_current_tip;
        IF NOT is_current_tip THEN
            CONTINUE;
        END IF;

        declared_m := declared_m + 1;
        SELECT t.* INTO latest
        FROM experiment_trial t
        WHERE t.registration_id = member.registration_id
        ORDER BY t.receipt_time DESC, t.trial_id DESC
        LIMIT 1;
        IF FOUND AND latest.p_value IS NOT NULL THEN
            ids := ids || member.registration_id;
            p_values := p_values || latest.p_value;
            real_p_count := real_p_count + 1;
        ELSE
            ids := ids || member.registration_id;
            p_values := p_values || 1::numeric;
        END IF;
    END LOOP;

    IF declared_m < 1 OR real_p_count < 1 THEN
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

    FOR i IN 1 .. declared_m LOOP
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
            family_key_value, method_value, alpha_value, declared_m, adjustments,
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
            'member_count', declared_m,
            'correction_digest', created.correction_digest
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

CREATE UNIQUE INDEX experimental_indicator_lineage_predecessor_uq
    ON experimental_indicator_lineage (predecessor_stage_record_id)
    WHERE predecessor_stage_record_id IS NOT NULL;
