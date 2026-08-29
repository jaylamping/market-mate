-- Canonical append-only audit-event chain for Local Research evidence.
-- Hashes are computed inside PostgreSQL so every consumer shares one encoding.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE audit_event (
    chain_position bigint PRIMARY KEY CHECK (chain_position > 0),
    event_id text NOT NULL UNIQUE CHECK (btrim(event_id) <> ''),
    event_type text NOT NULL CHECK (btrim(event_type) <> ''),
    event_time timestamptz NOT NULL,
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    previous_hash text NOT NULL CHECK (previous_hash ~ '^[0-9a-f]{64}$'),
    event_hash text NOT NULL UNIQUE CHECK (event_hash ~ '^[0-9a-f]{64}$'),
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('audit_event');

CREATE FUNCTION canonical_audit_event_hash(
    position_value bigint,
    previous_hash_value text,
    event_id_value text,
    event_type_value text,
    event_time_value timestamptz,
    payload_value jsonb,
    source_lineage_value jsonb,
    receipt_time_value timestamptz,
    environment_value record_environment
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(
            convert_to(
                concat_ws(
                    chr(31),
                    'market-mate-audit-event-v1',
                    position_value::text,
                    previous_hash_value,
                    event_id_value,
                    event_type_value,
                    to_char(
                        event_time_value AT TIME ZONE 'UTC',
                        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                    ),
                    payload_value::text,
                    source_lineage_value::text,
                    to_char(
                        receipt_time_value AT TIME ZONE 'UTC',
                        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                    ),
                    environment_value::text
                ),
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    );
$$;

CREATE FUNCTION guard_audit_event_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    expected_position bigint;
    expected_previous_hash text;
    expected_event_hash text;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'audit_event is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;

    IF current_setting('market_mate.audit_append', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'audit_event is append-only; inserts must use append_audit_event'
            USING ERRCODE = '55000';
    END IF;

    SELECT chain_position + 1, event_hash
    INTO expected_position, expected_previous_hash
    FROM audit_event
    ORDER BY chain_position DESC
    LIMIT 1;
    IF NOT FOUND THEN
        expected_position := 1;
        expected_previous_hash := repeat('0', 64);
    END IF;

    IF NEW.chain_position <> expected_position THEN
        RAISE EXCEPTION
            'audit_event append position mismatch: expected %, received %',
            expected_position,
            NEW.chain_position
            USING ERRCODE = '55000';
    END IF;

    IF NEW.previous_hash <> expected_previous_hash THEN
        RAISE EXCEPTION
            'audit_event predecessor mismatch at position %', NEW.chain_position
            USING ERRCODE = '55000';
    END IF;

    expected_event_hash := canonical_audit_event_hash(
        NEW.chain_position,
        NEW.previous_hash,
        NEW.event_id,
        NEW.event_type,
        NEW.event_time,
        NEW.payload,
        NEW.source_lineage,
        NEW.receipt_time,
        NEW.record_environment
    );
    IF NEW.event_hash <> expected_event_hash THEN
        RAISE EXCEPTION
            'audit_event hash mismatch at position %', NEW.chain_position
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER audit_event_insert_guard
BEFORE INSERT ON audit_event
FOR EACH ROW EXECUTE FUNCTION guard_audit_event_write();

CREATE TRIGGER audit_event_mutation_guard
BEFORE UPDATE OR DELETE ON audit_event
FOR EACH ROW EXECUTE FUNCTION guard_audit_event_write();

CREATE TRIGGER audit_event_truncate_guard
BEFORE TRUNCATE ON audit_event
FOR EACH STATEMENT EXECUTE FUNCTION guard_audit_event_write();

CREATE FUNCTION append_audit_event(
    event_id_value text,
    event_type_value text,
    event_time_value timestamptz,
    payload_value jsonb,
    source_lineage_value jsonb,
    receipt_time_value timestamptz,
    environment_value record_environment
) RETURNS audit_event
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    next_position bigint;
    predecessor_hash text;
    calculated_hash text;
    appended audit_event%ROWTYPE;
BEGIN
    IF coalesce(btrim(event_id_value), '') = '' THEN
        RAISE EXCEPTION 'audit event_id must not be empty' USING ERRCODE = '22023';
    END IF;
    IF coalesce(btrim(event_type_value), '') = '' THEN
        RAISE EXCEPTION 'audit event_type must not be empty' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(payload_value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'audit payload must be a JSON object' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'audit source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    -- Serialize chain-head selection and append without locking unrelated tables.
    PERFORM pg_advisory_xact_lock(8703);

    SELECT chain_position + 1, event_hash
    INTO next_position, predecessor_hash
    FROM audit_event
    ORDER BY chain_position DESC
    LIMIT 1;
    IF NOT FOUND THEN
        next_position := 1;
        predecessor_hash := repeat('0', 64);
    END IF;

    calculated_hash := canonical_audit_event_hash(
        next_position,
        predecessor_hash,
        event_id_value,
        event_type_value,
        event_time_value,
        payload_value,
        source_lineage_value,
        receipt_time_value,
        environment_value
    );

    PERFORM set_config('market_mate.audit_append', 'on', true);
    INSERT INTO audit_event (
        chain_position,
        event_id,
        event_type,
        event_time,
        payload,
        source_lineage,
        receipt_time,
        record_environment,
        previous_hash,
        event_hash
    ) VALUES (
        next_position,
        event_id_value,
        event_type_value,
        event_time_value,
        payload_value,
        source_lineage_value,
        receipt_time_value,
        environment_value,
        predecessor_hash,
        calculated_hash
    ) RETURNING * INTO appended;
    PERFORM set_config('market_mate.audit_append', 'off', true);

    RETURN appended;
END;
$$;

REVOKE ALL ON FUNCTION append_audit_event(
    text,
    text,
    timestamptz,
    jsonb,
    jsonb,
    timestamptz,
    record_environment
) FROM PUBLIC;

CREATE FUNCTION verify_audit_event_chain()
RETURNS TABLE (
    valid boolean,
    checked_events bigint,
    break_position bigint,
    reason text,
    expected_previous_hash text,
    actual_previous_hash text,
    expected_event_hash text,
    actual_event_hash text
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    current_event audit_event%ROWTYPE;
    next_position bigint := 1;
    predecessor_hash text := repeat('0', 64);
    calculated_hash text;
BEGIN
    valid := true;
    checked_events := 0;
    break_position := NULL;
    reason := NULL;
    expected_previous_hash := NULL;
    actual_previous_hash := NULL;
    expected_event_hash := NULL;
    actual_event_hash := NULL;

    FOR current_event IN
        SELECT * FROM audit_event ORDER BY chain_position
    LOOP
        IF current_event.chain_position <> next_position THEN
            valid := false;
            break_position := current_event.chain_position;
            reason := 'position_gap';
            expected_previous_hash := predecessor_hash;
            actual_previous_hash := current_event.previous_hash;
            actual_event_hash := current_event.event_hash;
            RETURN NEXT;
            RETURN;
        END IF;

        IF current_event.previous_hash <> predecessor_hash THEN
            valid := false;
            break_position := current_event.chain_position;
            reason := 'previous_hash_mismatch';
            expected_previous_hash := predecessor_hash;
            actual_previous_hash := current_event.previous_hash;
            actual_event_hash := current_event.event_hash;
            RETURN NEXT;
            RETURN;
        END IF;

        calculated_hash := canonical_audit_event_hash(
            current_event.chain_position,
            current_event.previous_hash,
            current_event.event_id,
            current_event.event_type,
            current_event.event_time,
            current_event.payload,
            current_event.source_lineage,
            current_event.receipt_time,
            current_event.record_environment
        );
        IF current_event.event_hash <> calculated_hash THEN
            valid := false;
            break_position := current_event.chain_position;
            reason := 'event_hash_mismatch';
            expected_previous_hash := predecessor_hash;
            actual_previous_hash := current_event.previous_hash;
            expected_event_hash := calculated_hash;
            actual_event_hash := current_event.event_hash;
            RETURN NEXT;
            RETURN;
        END IF;

        checked_events := checked_events + 1;
        next_position := next_position + 1;
        predecessor_hash := current_event.event_hash;
    END LOOP;

    RETURN NEXT;
END;
$$;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON audit_event FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
