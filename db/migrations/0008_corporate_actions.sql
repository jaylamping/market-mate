-- Corporate-action case storage: the immutable evidence and lifecycle record
-- for an event that may alter a Security, Exchange Listing, entitlement,
-- quantity, cash flow, basis, or option deliverable. The case progresses
-- Rumored -> Announced -> Terms Pending -> Authoritatively Confirmed ->
-- Effective -> Broker Reconciled -> Final without erasing earlier states.

CREATE TABLE corporate_action_case (
    case_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    security_id uuid NOT NULL REFERENCES security(security_id),
    action_type text NOT NULL CHECK (btrim(action_type) <> ''),
    case_state text NOT NULL CHECK (case_state IN (
        'rumored', 'announced', 'terms_pending',
        'authoritatively_confirmed', 'effective',
        'broker_reconciled', 'final'
    )),
    announced_at timestamptz,
    effective_at timestamptz,
    finalized_at timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (effective_at IS NULL OR announced_at IS NOT NULL),
    CHECK (effective_at IS NULL OR effective_at >= announced_at),
    CHECK (finalized_at IS NULL OR (effective_at IS NOT NULL AND finalized_at >= effective_at))
);

SELECT register_evidence_table('corporate_action_case');

CREATE SEQUENCE corporate_action_observation_seq;

CREATE TABLE corporate_action_state_observation (
    observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    observation_seq bigint NOT NULL DEFAULT nextval('corporate_action_observation_seq'),
    case_id uuid NOT NULL REFERENCES corporate_action_case(case_id),
    observed_state text NOT NULL CHECK (observed_state IN (
        'rumored', 'announced', 'terms_pending',
        'authoritatively_confirmed', 'effective',
        'broker_reconciled', 'final'
    )),
    observation_note text,
    observed_via text NOT NULL CHECK (btrim(observed_via) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('corporate_action_state_observation');


CREATE TABLE corporate_action_terms_version (
    terms_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id uuid NOT NULL REFERENCES corporate_action_case(case_id),
    terms_version integer NOT NULL CHECK (terms_version >= 1),
    known_from timestamptz NOT NULL,
    known_to timestamptz,
    terms jsonb NOT NULL CHECK (jsonb_typeof(terms) = 'object'),
    terms_digest text NOT NULL CHECK (terms_digest ~ '^[0-9a-f]{64}$'),
    superseded_by_terms_id uuid REFERENCES corporate_action_terms_version(terms_id),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (known_to IS NULL OR known_to > known_from),
    CHECK (terms_digest = encode(digest(terms::text, 'sha256'), 'hex'))
);

SELECT register_evidence_table('corporate_action_terms_version');

CREATE INDEX corporate_action_terms_version_case_idx
    ON corporate_action_terms_version (case_id, known_from);

CREATE FUNCTION corporate_action_state_is_legal_progression(
    from_state text,
    to_state text
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT (from_state, to_state) IN (
        VALUES ('rumored', 'announced'),
               ('rumored', 'final'),
               ('announced', 'terms_pending'),
               ('announced', 'final'),
               ('terms_pending', 'authoritatively_confirmed'),
               ('terms_pending', 'final'),
               ('authoritatively_confirmed', 'effective'),
               ('authoritatively_confirmed', 'final'),
               ('effective', 'broker_reconciled'),
               ('broker_reconciled', 'final')
    );
$$;

CREATE TABLE corporate_action_terms_adjustment (
    adjustment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    terms_id uuid NOT NULL REFERENCES corporate_action_terms_version(terms_id),
    instrument_id uuid,
    adjustment_kind text NOT NULL CHECK (btrim(adjustment_kind) <> ''),
    multiplier numeric NOT NULL CHECK (multiplier > 0),
    deliverable text NOT NULL CHECK (btrim(deliverable) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('corporate_action_terms_adjustment');

CREATE FUNCTION corporate_action_case_state(
    case_id_value uuid,
    as_of timestamptz
) RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT observed_state
    FROM corporate_action_state_observation o
    WHERE o.case_id = case_id_value
      AND o.receipt_time <= as_of
    ORDER BY o.observation_seq DESC
    LIMIT 1;
$$;

CREATE FUNCTION corporate_action_terms_at(
    case_id_value uuid,
    as_of timestamptz
) RETURNS corporate_action_terms_version
LANGUAGE sql
STABLE
AS $$
    SELECT v
    FROM corporate_action_terms_version v
    WHERE v.case_id = case_id_value
      AND v.known_from <= as_of
      AND (v.known_to IS NULL OR v.known_to > as_of)
    ORDER BY v.terms_version DESC
    LIMIT 1;
$$;

CREATE FUNCTION record_corporate_action_observation(
    case_id_value uuid,
    observed_state_value text,
    observed_via_value text,
    observation_note_value text,
    source_lineage_value jsonb
) RETURNS corporate_action_state_observation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
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
    PERFORM set_config('market_mate.ca_write', 'off', true);

    RETURN created;
END;
$$;

CREATE FUNCTION open_corporate_action_case(
    security_id_value uuid,
    action_type_value text,
    initial_state_value text,
    source_lineage_value jsonb
) RETURNS corporate_action_case
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created corporate_action_case%ROWTYPE;
BEGIN
    IF initial_state_value NOT IN ('rumored', 'announced', 'terms_pending') THEN
        RAISE EXCEPTION
            'corporate action state progression % -> % is not legal', NULL, initial_state_value
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.ca_write', 'on', true);
    INSERT INTO corporate_action_case (
        security_id, action_type, case_state,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        security_id_value, action_type_value, initial_state_value,
        source_lineage_value, now(), 'local_research'
    ) RETURNING * INTO created;
    PERFORM set_config('market_mate.ca_write', 'off', true);

    PERFORM record_corporate_action_observation(
        created.case_id, initial_state_value, 'case opened',
        NULL, source_lineage_value
    );

    RETURN created;
END;
$$;

CREATE FUNCTION add_corporate_action_terms(
    case_id_value uuid,
    terms_value jsonb,
    source_lineage_value jsonb
) RETURNS corporate_action_terms_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    max_version integer;
    previous_terms corporate_action_terms_version%ROWTYPE;
    created corporate_action_terms_version%ROWTYPE;
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
        UPDATE corporate_action_terms_version
           SET known_to = clock_timestamp(),
               superseded_by_terms_id = NULL
         WHERE terms_id = previous_terms.terms_id;
        PERFORM set_config('market_mate.ca_write', 'off', true);
    END IF;

    PERFORM set_config('market_mate.ca_write', 'on', true);
    INSERT INTO corporate_action_terms_version (
        case_id, terms_version, known_from, known_to,
        terms, terms_digest, superseded_by_terms_id,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        case_id_value, max_version + 1, clock_timestamp(), NULL,
        terms_value, encode(digest(terms_value::text, 'sha256'), 'hex'), NULL,
        source_lineage_value, now(), 'local_research'
    ) RETURNING * INTO created;
    PERFORM set_config('market_mate.ca_write', 'off', true);

    PERFORM set_config('market_mate.ca_write', 'on', true);
    UPDATE corporate_action_terms_version
       SET superseded_by_terms_id = created.terms_id
     WHERE terms_id = previous_terms.terms_id
       AND max_version > 0;
    PERFORM set_config('market_mate.ca_write', 'off', true);

    RETURN created;
END;
$$;

CREATE FUNCTION guard_corporate_action_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'corporate action records are never deleted'
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.ca_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'corporate action writes must go through the workflow functions'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER corporate_action_case_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON corporate_action_case
FOR EACH ROW EXECUTE FUNCTION guard_corporate_action_write();

CREATE TRIGGER corporate_action_observation_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON corporate_action_state_observation
FOR EACH ROW EXECUTE FUNCTION guard_corporate_action_write();

CREATE TRIGGER corporate_action_terms_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON corporate_action_terms_version
FOR EACH ROW EXECUTE FUNCTION guard_corporate_action_write();

SELECT assert_all_evidence_table_conventions();
