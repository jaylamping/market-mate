-- Entitlement certification gate for source use in Local Research and Paper.
-- Certification is versioned and effective-dated; gate decisions are durable
-- evidence, while downstream use receipts can only be created from an allowed
-- decision and always carry source, entitlement-version, and receipt-time
-- provenance.

CREATE TABLE data_entitlement (
    entitlement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entitlement_key text NOT NULL UNIQUE CHECK (btrim(entitlement_key) <> ''),
    account_scope text NOT NULL CHECK (btrim(account_scope) <> ''),
    plan_name text NOT NULL CHECK (btrim(plan_name) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('data_entitlement');

CREATE TRIGGER data_entitlement_mutation_guard
BEFORE UPDATE OR DELETE ON data_entitlement
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER data_entitlement_truncate_guard
BEFORE TRUNCATE ON data_entitlement
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE data_entitlement_version (
    entitlement_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entitlement_id uuid NOT NULL REFERENCES data_entitlement(entitlement_id),
    entitlement_version integer NOT NULL CHECK (entitlement_version >= 1),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    certification_state text NOT NULL CHECK (certification_state IN (
        'uncertified', 'certified', 'suspended', 'revoked'
    )),
    authorized_purposes text[] NOT NULL CHECK (
        cardinality(authorized_purposes) > 0
        AND authorized_purposes <@ ARRAY[
            'local_research', 'paper_validation', 'paper_execution',
            'strategy_evidence', 'dashboard_display'
        ]::text[]
    ),
    effective_from timestamptz NOT NULL,
    expires_at timestamptz,
    certification_basis jsonb NOT NULL CHECK (
        jsonb_typeof(certification_basis) = 'object'
        AND certification_basis ? 'authority'
    ),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (expires_at IS NULL OR expires_at > effective_from),
    UNIQUE (entitlement_id, entitlement_version),
    UNIQUE (entitlement_version_id, source_registry_version_id),
    EXCLUDE USING gist (
        entitlement_id WITH =,
        tstzrange(effective_from, expires_at, '[)') WITH &&
    )
);

SELECT register_evidence_table('data_entitlement_version');

CREATE FUNCTION guard_data_entitlement_source_effective_range() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    source_range tstzrange;
    entitlement_range tstzrange := tstzrange(NEW.effective_from, NEW.expires_at, '[)');
BEGIN
    SELECT tstzrange(effective_from, effective_to, '[)')
    INTO source_range
    FROM source_registry_version
    WHERE source_version_id = NEW.source_registry_version_id;

    IF source_range IS NULL OR NOT (entitlement_range <@ source_range) THEN
        RAISE EXCEPTION
            'entitlement version % effective range must be contained by its source registry version range',
            NEW.entitlement_version_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER data_entitlement_version_source_range_guard
AFTER INSERT OR UPDATE ON data_entitlement_version
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW EXECUTE FUNCTION guard_data_entitlement_source_effective_range();

CREATE TRIGGER data_entitlement_version_mutation_guard
BEFORE UPDATE OR DELETE ON data_entitlement_version
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER data_entitlement_version_truncate_guard
BEFORE TRUNCATE ON data_entitlement_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE entitlement_gate_decision (
    decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_key text NOT NULL UNIQUE CHECK (btrim(request_key) <> ''),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    requested_purpose text NOT NULL CHECK (btrim(requested_purpose) <> ''),
    requested_at timestamptz NOT NULL,
    decision text NOT NULL CHECK (decision IN ('allowed', 'denied')),
    denial_reason text,
    provenance jsonb NOT NULL CHECK (
        jsonb_typeof(provenance) = 'object'
        AND provenance ? 'source_registry_version'
        AND provenance ? 'entitlement_version'
        AND provenance ? 'receipt_time'
    ),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (decision = 'allowed' AND denial_reason IS NULL)
        OR (decision = 'denied' AND coalesce(btrim(denial_reason), '') <> '')
    ),
    UNIQUE (decision_id, source_registry_version_id, entitlement_version_id)
);

SELECT register_evidence_table('entitlement_gate_decision');

CREATE FUNCTION guard_entitlement_gate_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'entitlement gate decisions are append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.entitlement_gate_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'entitlement gate decisions must be recorded by evaluate_entitlement_gate'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER entitlement_gate_decision_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON entitlement_gate_decision
FOR EACH ROW EXECUTE FUNCTION guard_entitlement_gate_write();

CREATE TRIGGER entitlement_gate_decision_truncate_guard
BEFORE TRUNCATE ON entitlement_gate_decision
FOR EACH STATEMENT EXECUTE FUNCTION guard_entitlement_gate_write();

CREATE TABLE entitled_use_receipt (
    use_receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    use_key text NOT NULL UNIQUE CHECK (btrim(use_key) <> ''),
    decision_id uuid NOT NULL,
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    consumer_key text NOT NULL CHECK (btrim(consumer_key) <> ''),
    provenance jsonb NOT NULL CHECK (
        jsonb_typeof(provenance) = 'object'
        AND provenance ? 'source_registry_version'
        AND provenance ? 'entitlement_version'
        AND provenance ? 'receipt_time'
    ),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    FOREIGN KEY (decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('entitled_use_receipt');

CREATE FUNCTION guard_entitled_use_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'entitled use receipts are append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.entitled_use_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'entitled use receipts must be recorded by record_entitled_use'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER entitled_use_receipt_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON entitled_use_receipt
FOR EACH ROW EXECUTE FUNCTION guard_entitled_use_write();

CREATE TRIGGER entitled_use_receipt_truncate_guard
BEFORE TRUNCATE ON entitled_use_receipt
FOR EACH STATEMENT EXECUTE FUNCTION guard_entitled_use_write();

CREATE FUNCTION evaluate_entitlement_gate(
    request_key_value text,
    entitlement_version_id_value uuid,
    requested_purpose_value text,
    requested_at_value timestamptz,
    source_lineage_value jsonb
) RETURNS entitlement_gate_decision
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    entitlement_version_row data_entitlement_version%ROWTYPE;
    entitlement_row data_entitlement%ROWTYPE;
    source_version_row source_registry_version%ROWTYPE;
    decision_value text := 'allowed';
    denial_reason_value text;
    decision_receipt_time timestamptz := clock_timestamp();
    provenance_value jsonb;
    created entitlement_gate_decision%ROWTYPE;
BEGIN
    IF coalesce(btrim(request_key_value), '') = '' THEN
        RAISE EXCEPTION 'entitlement gate request_key must not be empty' USING ERRCODE = '22023';
    END IF;
    IF coalesce(btrim(requested_purpose_value), '') = '' THEN
        RAISE EXCEPTION 'entitlement gate requested purpose must not be empty' USING ERRCODE = '22023';
    END IF;
    IF requested_at_value IS NULL THEN
        RAISE EXCEPTION 'entitlement gate requested_at must not be null' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'entitlement gate source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT v.*
    INTO entitlement_version_row
    FROM data_entitlement_version v
    WHERE v.entitlement_version_id = entitlement_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'entitlement version % is not registered', entitlement_version_id_value
            USING ERRCODE = '22023';
    END IF;

    SELECT e.*
    INTO entitlement_row
    FROM data_entitlement e
    WHERE e.entitlement_id = entitlement_version_row.entitlement_id;

    SELECT s.*
    INTO source_version_row
    FROM source_registry_version s
    WHERE s.source_version_id = entitlement_version_row.source_registry_version_id;

    IF entitlement_version_row.certification_state <> 'certified' THEN
        decision_value := 'denied';
        denial_reason_value := 'not_certified';
    ELSIF requested_at_value < entitlement_version_row.effective_from THEN
        decision_value := 'denied';
        denial_reason_value := 'not_effective';
    ELSIF entitlement_version_row.expires_at IS NOT NULL
          AND requested_at_value >= entitlement_version_row.expires_at THEN
        decision_value := 'denied';
        denial_reason_value := 'expired';
    ELSIF NOT (requested_purpose_value = ANY (entitlement_version_row.authorized_purposes)) THEN
        decision_value := 'denied';
        denial_reason_value := 'purpose_not_authorized';
    ELSIF source_version_row.lifecycle <> 'active' THEN
        decision_value := 'denied';
        denial_reason_value := 'source_not_active';
    ELSIF requested_at_value < source_version_row.effective_from
          OR (source_version_row.effective_to IS NOT NULL
              AND requested_at_value >= source_version_row.effective_to) THEN
        decision_value := 'denied';
        denial_reason_value := 'source_not_effective';
    END IF;

    provenance_value := jsonb_build_object(
        'source_id', source_version_row.source_id,
        'source_registry_version_id', source_version_row.source_version_id,
        'source_registry_version', source_version_row.registry_version,
        'entitlement_id', entitlement_row.entitlement_id,
        'entitlement_version_id', entitlement_version_row.entitlement_version_id,
        'entitlement_version', entitlement_version_row.entitlement_version,
        'receipt_time', decision_receipt_time
    );

    PERFORM set_config('market_mate.entitlement_gate_write', 'on', true);
    INSERT INTO entitlement_gate_decision (
        request_key, entitlement_version_id, source_registry_version_id,
        requested_purpose, requested_at, decision, denial_reason,
        provenance, source_lineage, receipt_time, record_environment
    ) VALUES (
        request_key_value, entitlement_version_row.entitlement_version_id,
        source_version_row.source_version_id, requested_purpose_value,
        requested_at_value, decision_value, denial_reason_value,
        provenance_value, source_lineage_value, decision_receipt_time, 'local_research'
    ) RETURNING * INTO created;
    PERFORM set_config('market_mate.entitlement_gate_write', 'off', true);

    RETURN created;
END;
$$;

CREATE FUNCTION record_entitled_use(
    use_key_value text,
    decision_id_value uuid,
    consumer_key_value text,
    source_lineage_value jsonb
) RETURNS entitled_use_receipt
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    decision_row entitlement_gate_decision%ROWTYPE;
    entitlement_version_row data_entitlement_version%ROWTYPE;
    source_version_row source_registry_version%ROWTYPE;
    use_receipt_time timestamptz := clock_timestamp();
    provenance_value jsonb;
    created entitled_use_receipt%ROWTYPE;
BEGIN
    IF coalesce(btrim(use_key_value), '') = '' THEN
        RAISE EXCEPTION 'entitled use use_key must not be empty' USING ERRCODE = '22023';
    END IF;
    IF coalesce(btrim(consumer_key_value), '') = '' THEN
        RAISE EXCEPTION 'entitled use consumer_key must not be empty' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'entitled use source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT d.* INTO decision_row
    FROM entitlement_gate_decision d
    WHERE d.decision_id = decision_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'entitlement gate decision % is not registered', decision_id_value
            USING ERRCODE = '22023';
    END IF;
    IF decision_row.decision <> 'allowed' THEN
        RAISE EXCEPTION
            'entitlement gate denied request %; no use receipt may be recorded',
            decision_row.request_key
            USING ERRCODE = '55000';
    END IF;

    SELECT v.*
    INTO entitlement_version_row
    FROM data_entitlement_version v
    WHERE v.entitlement_version_id = decision_row.entitlement_version_id
      AND v.source_registry_version_id = decision_row.source_registry_version_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'entitlement gate decision % references an unavailable entitlement version',
            decision_row.decision_id
            USING ERRCODE = '55000';
    END IF;
    IF entitlement_version_row.certification_state <> 'certified' THEN
        RAISE EXCEPTION
            'entitlement gate decision % is no longer usable: entitlement is not certified',
            decision_row.decision_id
            USING ERRCODE = '55000';
    END IF;
    IF use_receipt_time < entitlement_version_row.effective_from
       OR (entitlement_version_row.expires_at IS NOT NULL
           AND use_receipt_time >= entitlement_version_row.expires_at) THEN
        RAISE EXCEPTION
            'entitlement gate decision % is no longer usable: entitlement is outside its effective range',
            decision_row.decision_id
            USING ERRCODE = '55000';
    END IF;

    SELECT s.*
    INTO source_version_row
    FROM source_registry_version s
    WHERE s.source_version_id = decision_row.source_registry_version_id;
    IF NOT FOUND OR source_version_row.lifecycle <> 'active' THEN
        RAISE EXCEPTION
            'entitlement gate decision % is no longer usable: source is not active',
            decision_row.decision_id
            USING ERRCODE = '55000';
    END IF;
    IF use_receipt_time < source_version_row.effective_from
       OR (source_version_row.effective_to IS NOT NULL
           AND use_receipt_time >= source_version_row.effective_to) THEN
        RAISE EXCEPTION
            'entitlement gate decision % is no longer usable: source is outside its effective range',
            decision_row.decision_id
            USING ERRCODE = '55000';
    END IF;

    provenance_value := decision_row.provenance || jsonb_build_object(
        'use_receipt_time', use_receipt_time
    );

    PERFORM set_config('market_mate.entitled_use_write', 'on', true);
    INSERT INTO entitled_use_receipt (
        use_key, decision_id, source_registry_version_id,
        entitlement_version_id, consumer_key, provenance,
        source_lineage, receipt_time, record_environment
    ) VALUES (
        use_key_value, decision_row.decision_id, decision_row.source_registry_version_id,
        decision_row.entitlement_version_id, consumer_key_value, provenance_value,
        source_lineage_value, use_receipt_time, 'local_research'
    ) RETURNING * INTO created;
    PERFORM set_config('market_mate.entitled_use_write', 'off', true);

    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
