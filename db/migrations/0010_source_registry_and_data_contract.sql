-- Source Registry and Data Contract schema for point-in-time research input.
-- A source identity is stable; its permitted access, use, lineage, observation
-- and correction rules are effective-dated registry versions. Connectors must
-- reference one of those registered versions, and every connector field must
-- reference the connector's exact Data Contract version.

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE source_registry (
    source_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_key text NOT NULL UNIQUE CHECK (btrim(source_key) <> ''),
    source_name text NOT NULL CHECK (btrim(source_name) <> ''),
    source_kind text NOT NULL CHECK (source_kind IN (
        'market_data', 'event_data', 'fundamental_data', 'public_filing', 'execution_data'
    )),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('source_registry');

CREATE TRIGGER source_registry_mutation_guard
BEFORE UPDATE OR DELETE ON source_registry
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER source_registry_truncate_guard
BEFORE TRUNCATE ON source_registry
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE source_registry_version (
    source_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid NOT NULL REFERENCES source_registry(source_id),
    registry_version integer NOT NULL CHECK (registry_version >= 1),
    lifecycle text NOT NULL CHECK (lifecycle IN ('draft', 'active', 'suspended', 'retired')),
    license_terms jsonb NOT NULL CHECK (
        jsonb_typeof(license_terms) = 'object'
        AND coalesce(btrim(license_terms ->> 'name'), '') <> ''
    ),
    permitted_use jsonb NOT NULL CHECK (
        jsonb_typeof(permitted_use) = 'object'
        AND jsonb_typeof(permitted_use -> 'purposes') = 'array'
    ),
    lineage_rules jsonb NOT NULL CHECK (
        jsonb_typeof(lineage_rules) = 'object'
        AND jsonb_typeof(lineage_rules -> 'required_fields') = 'array'
    ),
    observation_states text[] NOT NULL CHECK (
        cardinality(observation_states) > 0
        AND observation_states <@ ARRAY[
            'current', 'stale', 'expired', 'missing', 'incomplete',
            'source_disputed', 'invalidated', 'not_applicable'
        ]::text[]
    ),
    correction_semantics text[] NOT NULL CHECK (
        cardinality(correction_semantics) > 0
        AND correction_semantics <@ ARRAY[
            'factual_correction', 'retraction', 'rights_restriction',
            'required_deletion', 'source_unavailability', 'provenance_dispute'
        ]::text[]
    ),
    effective_from timestamptz NOT NULL,
    effective_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    UNIQUE (source_id, registry_version),
    UNIQUE (source_version_id, source_id),
    EXCLUDE USING gist (
        source_id WITH =,
        tstzrange(effective_from, effective_to, '[)') WITH &&
    )
);

SELECT register_evidence_table('source_registry_version');

CREATE TRIGGER source_registry_version_mutation_guard
BEFORE UPDATE OR DELETE ON source_registry_version
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER source_registry_version_truncate_guard
BEFORE TRUNCATE ON source_registry_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE data_contract (
    contract_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_key text NOT NULL UNIQUE CHECK (btrim(contract_key) <> ''),
    contract_kind text NOT NULL CHECK (contract_kind IN ('market', 'event', 'execution')),
    description text NOT NULL CHECK (btrim(description) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('data_contract');

CREATE TRIGGER data_contract_mutation_guard
BEFORE UPDATE OR DELETE ON data_contract
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER data_contract_truncate_guard
BEFORE TRUNCATE ON data_contract
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE data_contract_version (
    contract_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id uuid NOT NULL REFERENCES data_contract(contract_id),
    contract_version integer NOT NULL CHECK (contract_version >= 1),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    effective_from timestamptz NOT NULL,
    effective_to timestamptz,
    availability_time_rules jsonb NOT NULL CHECK (
        jsonb_typeof(availability_time_rules) = 'object'
        AND availability_time_rules ? 'as_of_required'
    ),
    instrument_identity_rules jsonb NOT NULL CHECK (
        jsonb_typeof(instrument_identity_rules) = 'object'
        AND instrument_identity_rules ? 'security_id_required'
    ),
    provenance_requirements jsonb NOT NULL CHECK (
        jsonb_typeof(provenance_requirements) = 'object'
        AND provenance_requirements ? 'source_registry_version'
        AND provenance_requirements ? 'entitlement_version'
        AND provenance_requirements ? 'receipt_time'
    ),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    UNIQUE (contract_id, contract_version),
    UNIQUE (contract_version_id, source_registry_version_id),
    EXCLUDE USING gist (
        contract_id WITH =,
        tstzrange(effective_from, effective_to, '[)') WITH &&
    )
);

SELECT register_evidence_table('data_contract_version');

CREATE FUNCTION guard_data_contract_source_effective_range() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    source_range tstzrange;
    contract_range tstzrange := tstzrange(NEW.effective_from, NEW.effective_to, '[)');
BEGIN
    SELECT tstzrange(effective_from, effective_to, '[)')
    INTO source_range
    FROM source_registry_version
    WHERE source_version_id = NEW.source_registry_version_id;

    IF source_range IS NULL OR NOT (contract_range <@ source_range) THEN
        RAISE EXCEPTION
            'data contract version % effective range must be contained by its source registry version range',
            NEW.contract_version_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER data_contract_version_source_range_guard
AFTER INSERT OR UPDATE ON data_contract_version
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW EXECUTE FUNCTION guard_data_contract_source_effective_range();

CREATE TRIGGER data_contract_version_mutation_guard
BEFORE UPDATE OR DELETE ON data_contract_version
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER data_contract_version_truncate_guard
BEFORE TRUNCATE ON data_contract_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE data_contract_field (
    field_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_version_id uuid NOT NULL REFERENCES data_contract_version(contract_version_id),
    field_key text NOT NULL CHECK (btrim(field_key) <> ''),
    value_type text NOT NULL CHECK (value_type IN ('boolean', 'integer', 'numeric', 'text', 'timestamp', 'json')),
    observation_states text[] NOT NULL CHECK (
        cardinality(observation_states) > 0
        AND observation_states <@ ARRAY[
            'current', 'stale', 'expired', 'missing', 'incomplete',
            'source_disputed', 'invalidated', 'not_applicable'
        ]::text[]
    ),
    field_semantics jsonb NOT NULL CHECK (jsonb_typeof(field_semantics) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (contract_version_id, field_key),
    UNIQUE (field_id, contract_version_id)
);

SELECT register_evidence_table('data_contract_field');

CREATE TRIGGER data_contract_field_mutation_guard
BEFORE UPDATE OR DELETE ON data_contract_field
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER data_contract_field_truncate_guard
BEFORE TRUNCATE ON data_contract_field
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE source_connector (
    connector_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connector_key text NOT NULL UNIQUE CHECK (btrim(connector_key) <> ''),
    connector_kind text NOT NULL CHECK (btrim(connector_kind) <> ''),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    contract_version_id uuid NOT NULL REFERENCES data_contract_version(contract_version_id),
    lifecycle text NOT NULL CHECK (lifecycle IN ('draft', 'active', 'suspended', 'retired')),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (connector_id, contract_version_id),
    FOREIGN KEY (contract_version_id, source_registry_version_id)
        REFERENCES data_contract_version (contract_version_id, source_registry_version_id)
);

SELECT register_evidence_table('source_connector');

CREATE TABLE connector_field_binding (
    connector_id uuid NOT NULL,
    contract_version_id uuid NOT NULL,
    field_id uuid NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    PRIMARY KEY (connector_id, field_id),
    FOREIGN KEY (connector_id, contract_version_id)
        REFERENCES source_connector (connector_id, contract_version_id),
    FOREIGN KEY (field_id, contract_version_id)
        REFERENCES data_contract_field (field_id, contract_version_id)
);

SELECT register_evidence_table('connector_field_binding');

CREATE TRIGGER connector_field_binding_mutation_guard
BEFORE UPDATE OR DELETE ON connector_field_binding
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER connector_field_binding_truncate_guard
BEFORE TRUNCATE ON connector_field_binding
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE VIEW active_source_registry AS
    SELECT r.source_id,
           r.source_key,
           r.source_name,
           r.source_kind,
           v.source_version_id,
           v.registry_version,
           v.license_terms,
           v.permitted_use,
           v.lineage_rules,
           v.observation_states,
           v.correction_semantics,
           v.effective_from,
           v.effective_to
    FROM source_registry r
    JOIN source_registry_version v ON v.source_id = r.source_id
    WHERE v.lifecycle = 'active'
      AND v.effective_from <= CURRENT_TIMESTAMP
      AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP);

SELECT assert_all_evidence_table_conventions();
