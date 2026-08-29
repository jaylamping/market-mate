-- Instrument mapping workflow: the versioned relationship between one
-- provider-native identifier and a canonical Security Master identity.
-- Lifecycle: proposed -> corroborated -> certified -> suspended/retired.
-- Only Certified mappings are consumable downstream; conflicting provider
-- mappings fail closed instead of being silently resolved.

CREATE TABLE instrument_mapping (
    mapping_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider text NOT NULL CHECK (btrim(provider) <> ''),
    native_identifier text NOT NULL CHECK (btrim(native_identifier) <> ''),
    object_kind text NOT NULL CHECK (object_kind IN ('issuer', 'security', 'listing')),
    issuer_id uuid REFERENCES issuer(issuer_id),
    security_id uuid REFERENCES security(security_id),
    listing_id uuid REFERENCES exchange_listing(listing_id),
    lifecycle text NOT NULL CHECK (lifecycle IN ('proposed', 'corroborated', 'certified', 'suspended', 'retired')),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    CHECK (
        (object_kind = 'issuer' AND issuer_id IS NOT NULL AND security_id IS NULL AND listing_id IS NULL)
        OR (object_kind = 'security' AND security_id IS NOT NULL AND issuer_id IS NULL AND listing_id IS NULL)
        OR (object_kind = 'listing' AND listing_id IS NOT NULL AND issuer_id IS NULL AND security_id IS NULL)
    )
);

SELECT register_evidence_table('instrument_mapping');

CREATE TABLE instrument_mapping_transition (
    transition_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    from_lifecycle text NOT NULL CHECK (from_lifecycle IN ('proposed', 'corroborated', 'certified', 'suspended', 'retired')),
    to_lifecycle text NOT NULL CHECK (to_lifecycle IN ('proposed', 'corroborated', 'certified', 'suspended', 'retired')),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('instrument_mapping_transition');

CREATE FUNCTION instrument_mapping_transition_is_legal(
    from_state text,
    to_state text
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT (from_state, to_state) IN (
        VALUES ('proposed', 'corroborated'),
               ('proposed', 'retired'),
               ('corroborated', 'certified'),
               ('corroborated', 'suspended'),
               ('corroborated', 'retired'),
               ('certified', 'suspended'),
               ('certified', 'retired'),
               ('suspended', 'certified'),
               ('suspended', 'retired')
    );
$$;

CREATE FUNCTION certified_conflict_exists(
    mapping_id_value uuid,
    provider_value text,
    native_value text,
    valid_from_value timestamptz,
    valid_to_value timestamptz
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM instrument_mapping other
        WHERE other.mapping_id <> mapping_id_value
          AND other.provider = provider_value
          AND upper(other.native_identifier) = upper(native_value)
          AND other.lifecycle = 'certified'
          AND tstzrange(other.valid_from, other.valid_to)
              && tstzrange(valid_from_value, valid_to_value)
    );
$$;

CREATE FUNCTION guard_instrument_mapping_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'instrument_mapping rows are never deleted; retire instead'
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.mapping_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'instrument_mapping writes must go through the mapping workflow functions'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER instrument_mapping_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON instrument_mapping
FOR EACH ROW EXECUTE FUNCTION guard_instrument_mapping_write();

CREATE TRIGGER instrument_mapping_truncate_guard
BEFORE TRUNCATE ON instrument_mapping
FOR EACH STATEMENT EXECUTE FUNCTION guard_instrument_mapping_write();

CREATE FUNCTION propose_instrument_mapping(
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
AS $$
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
    PERFORM set_config('market_mate.mapping_write', 'off', true);

    RETURN created;
END;
$$;

CREATE FUNCTION transition_instrument_mapping(
    mapping_id_value uuid,
    to_state_value text,
    reason_value text,
    source_lineage_value jsonb
) RETURNS instrument_mapping
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
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
    UPDATE instrument_mapping
       SET lifecycle = to_state_value
     WHERE mapping_id = mapping_id_value
    RETURNING * INTO updated;
    PERFORM set_config('market_mate.mapping_write', 'off', true);

    INSERT INTO instrument_mapping_transition (
        mapping_id, from_lifecycle, to_lifecycle, reason,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        mapping_id_value, current_mapping.lifecycle, to_state_value, reason_value,
        source_lineage_value, now(), 'local_research'
    );

    RETURN updated;
END;
$$;

CREATE VIEW certified_instrument_mapping AS
    SELECT *
    FROM instrument_mapping
    WHERE lifecycle = 'certified';

SELECT assert_all_evidence_table_conventions();
