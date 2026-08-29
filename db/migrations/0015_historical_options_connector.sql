-- Historical options-chain connector for Local Research.
-- Real-time options data is explicitly outside the stage-1 entitlement. A
-- historical snapshot is gate-checked, mapped to a Certified underlying, and
-- its contract terms point to an immutable Option Deliverable Version.

CREATE TABLE option_chain_snapshot (
    snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    underlying_security_id uuid NOT NULL REFERENCES security(security_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    data_mode text NOT NULL CHECK (data_mode = 'historical'),
    snapshot_at timestamptz NOT NULL,
    available_at timestamptz NOT NULL,
    raw_payload jsonb NOT NULL CHECK (jsonb_typeof(raw_payload) = 'object'),
    payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (payload_digest = encode(digest(convert_to(raw_payload::text, 'UTF8'), 'sha256'), 'hex')),
    UNIQUE (snapshot_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        ),
    FOREIGN KEY (gate_decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('option_chain_snapshot');

CREATE TABLE option_deliverable_version (
    deliverable_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_contract_key text NOT NULL CHECK (btrim(vendor_contract_key) <> ''),
    underlying_security_id uuid NOT NULL REFERENCES security(security_id),
    deliverable_kind text NOT NULL CHECK (deliverable_kind IN ('underlying', 'cash', 'mixed')),
    underlying_quantity numeric NOT NULL CHECK (underlying_quantity > 0),
    multiplier numeric NOT NULL CHECK (multiplier > 0),
    settlement_method text NOT NULL CHECK (settlement_method IN ('physical', 'cash')),
    effective_from timestamptz NOT NULL,
    effective_to timestamptz,
    terms jsonb NOT NULL CHECK (
        jsonb_typeof(terms) = 'object'
        AND terms ? 'quantity'
        AND terms ? 'multiplier'
        AND terms ? 'settlement'
    ),
    terms_digest text NOT NULL CHECK (terms_digest ~ '^[0-9a-f]{64}$'),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    CHECK (terms_digest = encode(digest(terms::text, 'sha256'), 'hex')),
    UNIQUE (deliverable_version_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        )
);

SELECT register_evidence_table('option_deliverable_version');

CREATE TABLE option_chain_contract (
    contract_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id uuid NOT NULL,
    deliverable_version_id uuid NOT NULL,
    instrument_mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    underlying_security_id uuid NOT NULL REFERENCES security(security_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    vendor_contract_key text NOT NULL CHECK (btrim(vendor_contract_key) <> ''),
    expiration_date date NOT NULL,
    option_right text NOT NULL CHECK (option_right IN ('call', 'put')),
    strike_price numeric NOT NULL CHECK (strike_price > 0),
    raw_payload jsonb NOT NULL CHECK (jsonb_typeof(raw_payload) = 'object'),
    payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (payload_digest = encode(digest(convert_to(raw_payload::text, 'UTF8'), 'sha256'), 'hex')),
    UNIQUE (contract_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (snapshot_id, source_registry_version_id, entitlement_version_id)
        REFERENCES option_chain_snapshot (
            snapshot_id, source_registry_version_id, entitlement_version_id
        ),
    FOREIGN KEY (deliverable_version_id, source_registry_version_id, entitlement_version_id)
        REFERENCES option_deliverable_version (
            deliverable_version_id, source_registry_version_id, entitlement_version_id
        ),
    FOREIGN KEY (gate_decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('option_chain_contract');

CREATE INDEX option_chain_snapshot_lookup_idx
    ON option_chain_snapshot (instrument_mapping_id, snapshot_at, available_at);

CREATE INDEX option_chain_contract_lookup_idx
    ON option_chain_contract (snapshot_id, expiration_date, strike_price, option_right);

CREATE FUNCTION guard_option_snapshot_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'option_chain_snapshot is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.option_snapshot_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'option snapshot writes must go through record_historical_option_chain_snapshot'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER option_snapshot_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON option_chain_snapshot
FOR EACH ROW EXECUTE FUNCTION guard_option_snapshot_write();

CREATE TRIGGER option_snapshot_truncate_guard
BEFORE TRUNCATE ON option_chain_snapshot
FOR EACH STATEMENT EXECUTE FUNCTION guard_option_snapshot_write();

CREATE FUNCTION guard_option_deliverable_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'option_deliverable_version is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.option_deliverable_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'option deliverable writes must go through append_option_chain_contract'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER option_deliverable_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON option_deliverable_version
FOR EACH ROW EXECUTE FUNCTION guard_option_deliverable_write();

CREATE TRIGGER option_deliverable_truncate_guard
BEFORE TRUNCATE ON option_deliverable_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_option_deliverable_write();

CREATE FUNCTION guard_option_contract_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'option_chain_contract is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.option_contract_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'option contract writes must go through append_option_chain_contract'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER option_contract_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON option_chain_contract
FOR EACH ROW EXECUTE FUNCTION guard_option_contract_write();

CREATE TRIGGER option_contract_truncate_guard
BEFORE TRUNCATE ON option_chain_contract
FOR EACH STATEMENT EXECUTE FUNCTION guard_option_contract_write();

CREATE FUNCTION record_historical_option_chain_snapshot(
    instrument_mapping_id_value uuid,
    source_registry_version_id_value uuid,
    entitlement_version_id_value uuid,
    data_mode_value text,
    snapshot_at_value timestamptz,
    available_at_value timestamptz,
    raw_payload_value jsonb,
    source_lineage_value jsonb
) RETURNS option_chain_snapshot
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    mapping_row instrument_mapping%ROWTYPE;
    entitlement_version_row data_entitlement_version%ROWTYPE;
    decision_row entitlement_gate_decision%ROWTYPE;
    created option_chain_snapshot%ROWTYPE;
    snapshot_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF data_mode_value = 'real_time' THEN
        RAISE EXCEPTION 'real-time options entitlements are deferred to stage 2'
            USING ERRCODE = '55000';
    END IF;
    IF data_mode_value <> 'historical'
       OR snapshot_at_value IS NULL
       OR available_at_value IS NULL
       OR jsonb_typeof(raw_payload_value) <> 'object' THEN
        RAISE EXCEPTION 'historical option snapshot required fields are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'historical option snapshot source_lineage is invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT m.*
    INTO mapping_row
    FROM instrument_mapping m
    WHERE m.mapping_id = instrument_mapping_id_value;
    IF NOT FOUND
       OR mapping_row.lifecycle <> 'certified'
       OR mapping_row.object_kind <> 'security' THEN
        RAISE EXCEPTION 'historical option identity mapping must be certified for a security'
            USING ERRCODE = '55000';
    END IF;
    SELECT v.*
    INTO entitlement_version_row
    FROM data_entitlement_version v
    WHERE v.entitlement_version_id = entitlement_version_id_value
      AND v.source_registry_version_id = source_registry_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'historical option source and entitlement versions do not match'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
    INTO decision_row
    FROM evaluate_entitlement_gate(
        'wu15-options:' || instrument_mapping_id_value || ':' || snapshot_at_value,
        entitlement_version_row.entitlement_version_id,
        'local_research', snapshot_receipt_time, source_lineage_value
    );
    IF decision_row.decision <> 'allowed' THEN
        RETURN NULL;
    END IF;
    PERFORM record_entitled_use(
        'wu15-options-use:snapshot:' || instrument_mapping_id_value || ':' || snapshot_at_value,
        decision_row.decision_id, 'historical-options-connector', source_lineage_value
    );

    PERFORM set_config('market_mate.option_snapshot_write', 'on', true);
    BEGIN
        INSERT INTO option_chain_snapshot (
            instrument_mapping_id, underlying_security_id,
            source_registry_version_id, entitlement_version_id, gate_decision_id,
            data_mode, snapshot_at, available_at, raw_payload, payload_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            mapping_row.mapping_id, mapping_row.security_id,
            entitlement_version_row.source_registry_version_id,
            entitlement_version_row.entitlement_version_id, decision_row.decision_id,
            'historical', snapshot_at_value, available_at_value, raw_payload_value,
            encode(digest(convert_to(raw_payload_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, snapshot_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.option_snapshot_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.option_snapshot_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION append_option_chain_contract(
    snapshot_id_value uuid,
    vendor_contract_key_value text,
    expiration_date_value date,
    option_right_value text,
    strike_price_value numeric,
    deliverable_terms_value jsonb,
    raw_payload_value jsonb,
    source_lineage_value jsonb
) RETURNS option_chain_contract
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    snapshot_row option_chain_snapshot%ROWTYPE;
    deliverable_created option_deliverable_version%ROWTYPE;
    created option_chain_contract%ROWTYPE;
    quantity_value numeric;
    multiplier_value numeric;
    settlement_value text;
    deliverable_kind_value text;
    contract_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF coalesce(btrim(vendor_contract_key_value), '') = ''
       OR expiration_date_value IS NULL
       OR option_right_value NOT IN ('call', 'put')
       OR strike_price_value IS NULL
       OR strike_price_value <= 0
       OR jsonb_typeof(deliverable_terms_value) <> 'object'
       OR jsonb_typeof(raw_payload_value) <> 'object' THEN
        RAISE EXCEPTION 'option contract required fields are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'option contract source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT s.*
    INTO snapshot_row
    FROM option_chain_snapshot s
    WHERE s.snapshot_id = snapshot_id_value;
    IF NOT FOUND OR snapshot_row.data_mode <> 'historical' THEN
        RAISE EXCEPTION 'option contract requires a historical snapshot'
            USING ERRCODE = '55000';
    END IF;
    IF NOT (deliverable_terms_value ? 'quantity')
       OR NOT (deliverable_terms_value ? 'multiplier')
       OR NOT (deliverable_terms_value ? 'settlement') THEN
        RAISE EXCEPTION 'option contract deliverable terms are incomplete'
            USING ERRCODE = '22023';
    END IF;
    BEGIN
        quantity_value := (deliverable_terms_value ->> 'quantity')::numeric;
        multiplier_value := (deliverable_terms_value ->> 'multiplier')::numeric;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'option contract deliverable quantities are invalid'
                USING ERRCODE = '22023';
    END;
    settlement_value := deliverable_terms_value ->> 'settlement';
    IF quantity_value <= 0 OR multiplier_value <= 0
       OR settlement_value NOT IN ('physical', 'cash') THEN
        RAISE EXCEPTION 'option contract deliverable terms are invalid'
            USING ERRCODE = '22023';
    END IF;
    deliverable_kind_value := CASE WHEN settlement_value = 'physical' THEN 'underlying' ELSE 'cash' END;

    PERFORM record_entitled_use(
        'wu15-options-use:contract:' || snapshot_row.snapshot_id || ':' || vendor_contract_key_value,
        snapshot_row.gate_decision_id, 'historical-options-contract-consumer', source_lineage_value
    );

    PERFORM set_config('market_mate.option_deliverable_write', 'on', true);
    BEGIN
        INSERT INTO option_deliverable_version (
            vendor_contract_key, underlying_security_id, deliverable_kind,
            underlying_quantity, multiplier, settlement_method,
            effective_from, effective_to, terms, terms_digest,
            source_registry_version_id, entitlement_version_id,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            vendor_contract_key_value, snapshot_row.underlying_security_id,
            deliverable_kind_value, quantity_value, multiplier_value,
            settlement_value, snapshot_row.snapshot_at, NULL, deliverable_terms_value,
            encode(digest(deliverable_terms_value::text, 'sha256'), 'hex'),
            snapshot_row.source_registry_version_id, snapshot_row.entitlement_version_id,
            source_lineage_value, contract_receipt_time, 'local_research'
        ) RETURNING * INTO deliverable_created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.option_deliverable_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.option_deliverable_write', 'off', true);

    PERFORM set_config('market_mate.option_contract_write', 'on', true);
    BEGIN
        INSERT INTO option_chain_contract (
            snapshot_id, deliverable_version_id, instrument_mapping_id,
            underlying_security_id, source_registry_version_id, entitlement_version_id,
            gate_decision_id, vendor_contract_key, expiration_date, option_right,
            strike_price, raw_payload, payload_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            snapshot_row.snapshot_id, deliverable_created.deliverable_version_id,
            snapshot_row.instrument_mapping_id, snapshot_row.underlying_security_id,
            snapshot_row.source_registry_version_id, snapshot_row.entitlement_version_id,
            snapshot_row.gate_decision_id, vendor_contract_key_value,
            expiration_date_value, option_right_value, strike_price_value,
            raw_payload_value,
            encode(digest(convert_to(raw_payload_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, contract_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.option_contract_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.option_contract_write', 'off', true);
    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
