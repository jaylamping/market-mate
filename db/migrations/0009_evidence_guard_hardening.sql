-- Evidence-guard hardening following adversarial review (PRs #91-#95):
--  1. The WU-07 security-master tables had no write guards at all; the
--     "append-only alias history" claim is now enforced (master corrections
--     append successors; closures land via future workflow functions).
--  2. TRUNCATE bypassed the 0005 and 0008 row-level guards; every evidence
--     table from those migrations now rejects TRUNCATE unconditionally.
--  3. The 0007/0008 history tables (instrument_mapping_transition,
--     corporate_action_terms_adjustment) were writable by anyone; they are
--     now gated behind their workflow functions like their parents.
--  4. The workflow functions leaked their write flag on error: a caught
--     exception left the GUC armed for the rest of the transaction. All
--     SECURITY DEFINER functions now reset the flag in an exception handler.
--
-- Threat-model note: the session GUC guards stop accidental and unprivileged
-- writes. The connecting role owns these tables in the local single-user
-- profile, so a determined session that explicitly arms the GUC can still
-- write; durable enforcement via a split app/owner role arrives with stage 2
-- identity work.

CREATE OR REPLACE FUNCTION guard_append_only_evidence() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
        USING ERRCODE = '55000';
END;
$$;

CREATE FUNCTION guard_security_master_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'security master rows are never deleted; append a successor instead'
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.security_master_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'security master writes must go through workflow functions'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_instrument_mapping_transition_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'instrument_mapping_transition is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.mapping_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'instrument_mapping_transition writes must go through the mapping workflow functions'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION guard_corporate_action_adjustment_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'corporate_action_terms_adjustment is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.ca_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'corporate_action_terms_adjustment writes must go through the workflow functions'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

-- Security master (0006): workflow-gated writes, no deletes, no truncates.
CREATE TRIGGER issuer_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON issuer
FOR EACH ROW EXECUTE FUNCTION guard_security_master_write();

CREATE TRIGGER security_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON security
FOR EACH ROW EXECUTE FUNCTION guard_security_master_write();

CREATE TRIGGER exchange_listing_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON exchange_listing
FOR EACH ROW EXECUTE FUNCTION guard_security_master_write();

CREATE TRIGGER issuer_symbol_alias_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON issuer_symbol_alias
FOR EACH ROW EXECUTE FUNCTION guard_security_master_write();

CREATE TRIGGER security_symbol_alias_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON security_symbol_alias
FOR EACH ROW EXECUTE FUNCTION guard_security_master_write();

CREATE TRIGGER listing_symbol_alias_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON listing_symbol_alias
FOR EACH ROW EXECUTE FUNCTION guard_security_master_write();

CREATE TRIGGER issuer_truncate_guard
BEFORE TRUNCATE ON issuer
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER security_truncate_guard
BEFORE TRUNCATE ON security
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER exchange_listing_truncate_guard
BEFORE TRUNCATE ON exchange_listing
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER issuer_symbol_alias_truncate_guard
BEFORE TRUNCATE ON issuer_symbol_alias
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER security_symbol_alias_truncate_guard
BEFORE TRUNCATE ON security_symbol_alias
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER listing_symbol_alias_truncate_guard
BEFORE TRUNCATE ON listing_symbol_alias
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

-- Tracer evidence (0005): close the TRUNCATE gap.
CREATE TRIGGER research_snapshot_truncate_guard
BEFORE TRUNCATE ON research_snapshot
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER experiment_preregistration_truncate_guard
BEFORE TRUNCATE ON experiment_preregistration
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER evaluation_result_truncate_guard
BEFORE TRUNCATE ON evaluation_result
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

-- Corporate actions (0008): close the TRUNCATE gap and guard the adjustment table.
CREATE TRIGGER corporate_action_case_truncate_guard
BEFORE TRUNCATE ON corporate_action_case
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER corporate_action_observation_truncate_guard
BEFORE TRUNCATE ON corporate_action_state_observation
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER corporate_action_terms_truncate_guard
BEFORE TRUNCATE ON corporate_action_terms_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER corporate_action_terms_adjustment_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON corporate_action_terms_adjustment
FOR EACH ROW EXECUTE FUNCTION guard_corporate_action_adjustment_write();

CREATE TRIGGER corporate_action_terms_adjustment_truncate_guard
BEFORE TRUNCATE ON corporate_action_terms_adjustment
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

-- Exception-safe GUC discipline: a failure inside a workflow function must
-- disarm the write flag so a caught exception cannot smuggle later direct
-- writes through the guards within the same transaction.

CREATE OR REPLACE FUNCTION propose_instrument_mapping(
    provider_value text,
    native_identifier_value text,
    object_kind_value text,
    issuer_id_value uuid,
    security_id_value uuid,
    listing_id_value uuid,
    valid_from_value timestamptz,
    source_lineage_value jsonb
) RETURNS instrument_mapping
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    created instrument_mapping%ROWTYPE;
BEGIN
    IF NOT (
        (object_kind_value = 'issuer' AND issuer_id_value IS NOT NULL
            AND security_id_value IS NULL AND listing_id_value IS NULL)
        OR (object_kind_value = 'security' AND security_id_value IS NOT NULL
            AND issuer_id_value IS NULL AND listing_id_value IS NULL)
        OR (object_kind_value = 'listing' AND listing_id_value IS NOT NULL
            AND issuer_id_value IS NULL AND security_id_value IS NULL)
    ) THEN
        RAISE EXCEPTION 'instrument_mapping object_kind does not match its target identifier'
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('market_mate.mapping_write', 'on', true);
    BEGIN
        INSERT INTO instrument_mapping (
            provider, native_identifier, object_kind,
            issuer_id, security_id, listing_id,
            lifecycle, valid_from, valid_to,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            provider_value, native_identifier_value, object_kind_value,
            issuer_id_value, security_id_value, listing_id_value,
            'proposed', valid_from_value, NULL,
            source_lineage_value, now(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.mapping_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.mapping_write', 'off', true);

    RETURN created;
END;
$function$;

CREATE OR REPLACE FUNCTION transition_instrument_mapping(
    mapping_id_value uuid,
    to_state_value text,
    reason_value text,
    source_lineage_value jsonb
) RETURNS instrument_mapping
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    current_mapping instrument_mapping%ROWTYPE;
    updated instrument_mapping%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(8704);

    SELECT * INTO current_mapping
    FROM instrument_mapping
    WHERE mapping_id = mapping_id_value
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'instrument_mapping % does not exist', mapping_id_value
            USING ERRCODE = '22023';
    END IF;

    IF NOT instrument_mapping_transition_is_legal(current_mapping.lifecycle, to_state_value) THEN
        RAISE EXCEPTION
            'instrument_mapping transition % -> % is not a legal lifecycle move',
            current_mapping.lifecycle, to_state_value
            USING ERRCODE = '55000';
    END IF;

    IF to_state_value = 'certified'
       AND certified_conflict_exists(
           current_mapping.mapping_id,
           current_mapping.provider,
           current_mapping.native_identifier,
           current_mapping.valid_from,
           current_mapping.valid_to
       ) THEN
        RAISE EXCEPTION
            'instrument_mapping certification refused: conflicting certified mapping exists for the same provider identifier; failing closed, no silent pick'
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.mapping_write', 'on', true);
    BEGIN
        UPDATE instrument_mapping
           SET lifecycle = to_state_value
         WHERE mapping_id = mapping_id_value
        RETURNING * INTO updated;

        INSERT INTO instrument_mapping_transition (
            mapping_id, from_lifecycle, to_lifecycle, reason,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            mapping_id_value, current_mapping.lifecycle, to_state_value, reason_value,
            source_lineage_value, now(), 'local_research'
        );
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.mapping_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.mapping_write', 'off', true);

    RETURN updated;
END;
$function$;

CREATE OR REPLACE FUNCTION record_corporate_action_observation(
    case_id_value uuid,
    observed_state_value text,
    observed_via_value text,
    observation_note_value text,
    source_lineage_value jsonb
) RETURNS corporate_action_state_observation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    current_state text;
    created corporate_action_state_observation%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(8705);

    SELECT corporate_action_case_state(case_id_value, now())
    INTO current_state;

    IF current_state IS NOT NULL
       AND NOT corporate_action_state_is_legal_progression(current_state, observed_state_value) THEN
        RAISE EXCEPTION
            'corporate action state progression % -> % is not legal', current_state, observed_state_value
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.ca_write', 'on', true);
    BEGIN
        INSERT INTO corporate_action_state_observation (
            case_id, observed_state, observed_via, observation_note,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            case_id_value, observed_state_value, observed_via_value, observation_note_value,
            source_lineage_value, now(), 'local_research'
        ) RETURNING * INTO created;

        UPDATE corporate_action_case
           SET case_state = observed_state_value,
               announced_at = CASE WHEN observed_state_value IN ('announced', 'terms_pending', 'authoritatively_confirmed', 'effective', 'broker_reconciled', 'final') AND announced_at IS NULL THEN now() ELSE announced_at END,
               effective_at = CASE WHEN observed_state_value IN ('effective', 'broker_reconciled', 'final') AND effective_at IS NULL THEN now() ELSE effective_at END,
               finalized_at = CASE WHEN observed_state_value = 'final' AND finalized_at IS NULL THEN now() ELSE finalized_at END
         WHERE case_id = case_id_value;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.ca_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.ca_write', 'off', true);

    RETURN created;
END;
$function$;

CREATE OR REPLACE FUNCTION open_corporate_action_case(
    security_id_value uuid,
    action_type_value text,
    initial_state_value text,
    source_lineage_value jsonb
) RETURNS corporate_action_case
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    created corporate_action_case%ROWTYPE;
BEGIN
    IF initial_state_value NOT IN ('rumored', 'announced', 'terms_pending') THEN
        RAISE EXCEPTION
            'corporate action state progression % -> % is not legal', NULL, initial_state_value
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.ca_write', 'on', true);
    BEGIN
        INSERT INTO corporate_action_case (
            security_id, action_type, case_state,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            security_id_value, action_type_value, initial_state_value,
            source_lineage_value, now(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.ca_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.ca_write', 'off', true);

    PERFORM record_corporate_action_observation(
        created.case_id, initial_state_value, 'case opened',
        NULL, source_lineage_value
    );

    RETURN created;
END;
$function$;

CREATE OR REPLACE FUNCTION add_corporate_action_terms(
    case_id_value uuid,
    terms_value jsonb,
    source_lineage_value jsonb
) RETURNS corporate_action_terms_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
    max_version integer;
    previous_terms corporate_action_terms_version%ROWTYPE;
    created corporate_action_terms_version%ROWTYPE;
    terms_version_time timestamptz := clock_timestamp();
BEGIN
    PERFORM pg_advisory_xact_lock(8706);

    SELECT coalesce(max(terms_version), 0) INTO max_version
    FROM corporate_action_terms_version
    WHERE case_id = case_id_value;

    IF max_version > 0 THEN
        SELECT * INTO previous_terms
        FROM corporate_action_terms_version
        WHERE case_id = case_id_value
          AND terms_version = max_version;
        IF previous_terms.known_to IS NOT NULL THEN
            RAISE EXCEPTION 'previous terms version for case % is already closed', case_id_value
                USING ERRCODE = '55000';
        END IF;
        PERFORM set_config('market_mate.ca_write', 'on', true);
        BEGIN
            UPDATE corporate_action_terms_version
               SET known_to = terms_version_time,
                   superseded_by_terms_id = NULL
             WHERE terms_id = previous_terms.terms_id;
        EXCEPTION
            WHEN OTHERS THEN
                PERFORM set_config('market_mate.ca_write', 'off', true);
                RAISE;
        END;
        PERFORM set_config('market_mate.ca_write', 'off', true);
    END IF;

    PERFORM set_config('market_mate.ca_write', 'on', true);
    BEGIN
        INSERT INTO corporate_action_terms_version (
            case_id, terms_version, known_from, known_to,
            terms, terms_digest, superseded_by_terms_id,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            case_id_value, max_version + 1, terms_version_time, NULL,
            terms_value, encode(digest(terms_value::text, 'sha256'), 'hex'), NULL,
            source_lineage_value, now(), 'local_research'
        ) RETURNING * INTO created;

        UPDATE corporate_action_terms_version
           SET superseded_by_terms_id = created.terms_id
         WHERE terms_id = previous_terms.terms_id
           AND max_version > 0;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.ca_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.ca_write', 'off', true);

    RETURN created;
END;
$function$;

SELECT assert_all_evidence_table_conventions();
