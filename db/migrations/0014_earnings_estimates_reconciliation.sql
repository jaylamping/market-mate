-- As-of earnings estimates and reconciliation against EDGAR actuals.
-- Estimates cannot be ingested without an explicit as-of timestamp. Actuals
-- must come from a registered public filing for the same issuer, and every
-- reconciliation preserves both source/version pairs and any disagreement.

CREATE TABLE earnings_estimate_observation (
    estimate_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    vendor_observation_key text NOT NULL CHECK (btrim(vendor_observation_key) <> ''),
    fiscal_period_end date NOT NULL,
    metric text NOT NULL CHECK (btrim(metric) <> ''),
    estimate_value numeric NOT NULL,
    unit text NOT NULL CHECK (btrim(unit) <> ''),
    currency text NOT NULL CHECK (btrim(currency) <> ''),
    announcement_at timestamptz NOT NULL,
    as_of_at timestamptz NOT NULL,
    observation_status text NOT NULL CHECK (observation_status IN ('published', 'revised', 'withdrawn')),
    revision integer NOT NULL CHECK (revision >= 1),
    raw_payload jsonb NOT NULL CHECK (jsonb_typeof(raw_payload) = 'object'),
    payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        payload_digest = encode(digest(convert_to(raw_payload::text, 'UTF8'), 'sha256'), 'hex')
    ),
    UNIQUE (estimate_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        ),
    FOREIGN KEY (gate_decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('earnings_estimate_observation');

CREATE INDEX earnings_estimate_lookup_idx
    ON earnings_estimate_observation (instrument_mapping_id, fiscal_period_end, as_of_at, revision);

CREATE TABLE earnings_actual_reconciliation (
    reconciliation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    estimate_id uuid NOT NULL,
    edgar_actual_id uuid NOT NULL,
    estimate_source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    estimate_entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    edgar_source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    edgar_entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    reconciliation_revision integer NOT NULL CHECK (reconciliation_revision >= 1),
    announcement_at timestamptz NOT NULL,
    actual_filed_at timestamptz NOT NULL,
    estimate_as_of_at timestamptz NOT NULL,
    estimate_value numeric NOT NULL,
    actual_value numeric NOT NULL,
    variance numeric NOT NULL,
    tolerance numeric NOT NULL CHECK (tolerance >= 0),
    actual_concept text NOT NULL CHECK (btrim(actual_concept) <> ''),
    reconciliation_status text NOT NULL CHECK (reconciliation_status IN ('matched', 'disagreement')),
    announcement_linked boolean NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (variance = actual_value - estimate_value),
    CHECK (
        (reconciliation_status = 'matched' AND abs(variance) <= tolerance)
        OR (reconciliation_status = 'disagreement' AND abs(variance) > tolerance)
    ),
    UNIQUE (reconciliation_id, estimate_source_registry_version_id, estimate_entitlement_version_id),
    FOREIGN KEY (estimate_id, estimate_source_registry_version_id, estimate_entitlement_version_id)
        REFERENCES earnings_estimate_observation (
            estimate_id, source_registry_version_id, entitlement_version_id
        ),
    FOREIGN KEY (edgar_actual_id, edgar_source_registry_version_id, edgar_entitlement_version_id)
        REFERENCES edgar_xbrl_actual (
            actual_id, source_registry_version_id, entitlement_version_id
        ),
    FOREIGN KEY (gate_decision_id, estimate_source_registry_version_id, estimate_entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('earnings_actual_reconciliation');

CREATE INDEX earnings_reconciliation_lookup_idx
    ON earnings_actual_reconciliation (estimate_id, edgar_actual_id, receipt_time, reconciliation_revision);

CREATE FUNCTION guard_earnings_estimate_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'earnings_estimate_observation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.earnings_estimate_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'earnings estimate writes must go through ingest_earnings_estimate'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER earnings_estimate_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON earnings_estimate_observation
FOR EACH ROW EXECUTE FUNCTION guard_earnings_estimate_write();

CREATE TRIGGER earnings_estimate_truncate_guard
BEFORE TRUNCATE ON earnings_estimate_observation
FOR EACH STATEMENT EXECUTE FUNCTION guard_earnings_estimate_write();

CREATE FUNCTION guard_earnings_reconciliation_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'earnings_actual_reconciliation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.earnings_reconciliation_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'earnings reconciliation writes must go through reconcile_earnings_actual'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER earnings_reconciliation_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON earnings_actual_reconciliation
FOR EACH ROW EXECUTE FUNCTION guard_earnings_reconciliation_write();

CREATE TRIGGER earnings_reconciliation_truncate_guard
BEFORE TRUNCATE ON earnings_actual_reconciliation
FOR EACH STATEMENT EXECUTE FUNCTION guard_earnings_reconciliation_write();

CREATE FUNCTION ingest_earnings_estimate(
    instrument_mapping_id_value uuid,
    source_registry_version_id_value uuid,
    entitlement_version_id_value uuid,
    vendor_observation_key_value text,
    fiscal_period_end_value date,
    metric_value text,
    estimate_value_value numeric,
    unit_value text,
    currency_value text,
    announcement_at_value timestamptz,
    as_of_at_value timestamptz,
    raw_payload_value jsonb,
    source_lineage_value jsonb
) RETURNS earnings_estimate_observation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    mapping_row instrument_mapping%ROWTYPE;
    entitlement_version_row data_entitlement_version%ROWTYPE;
    decision_row entitlement_gate_decision%ROWTYPE;
    created earnings_estimate_observation%ROWTYPE;
    next_revision integer;
    estimate_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF as_of_at_value IS NULL THEN
        RAISE EXCEPTION 'earnings estimate as_of_at is required; no backfill is permitted'
            USING ERRCODE = '55000';
    END IF;
    IF as_of_at_value > estimate_receipt_time THEN
        RAISE EXCEPTION 'earnings estimate as_of_at cannot be in the future'
            USING ERRCODE = '22023';
    END IF;
    IF coalesce(btrim(vendor_observation_key_value), '') = ''
       OR fiscal_period_end_value IS NULL
       OR coalesce(btrim(metric_value), '') = ''
       OR coalesce(btrim(unit_value), '') = ''
       OR coalesce(btrim(currency_value), '') = ''
       OR announcement_at_value IS NULL
       OR estimate_value_value IS NULL THEN
        RAISE EXCEPTION 'earnings estimate required fields are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'earnings estimate source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT m.*
    INTO mapping_row
    FROM instrument_mapping m
    WHERE m.mapping_id = instrument_mapping_id_value;
    IF NOT FOUND
       OR mapping_row.lifecycle <> 'certified'
       OR mapping_row.object_kind <> 'security' THEN
        RAISE EXCEPTION 'earnings estimate identity mapping must be certified for a security'
            USING ERRCODE = '55000';
    END IF;

    SELECT v.*
    INTO entitlement_version_row
    FROM data_entitlement_version v
    WHERE v.entitlement_version_id = entitlement_version_id_value
      AND v.source_registry_version_id = source_registry_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'earnings estimate source and entitlement versions do not match'
            USING ERRCODE = '55000';
    END IF;

    PERFORM pg_advisory_xact_lock(8715);
    SELECT coalesce(max(e.revision), 0) + 1
    INTO next_revision
    FROM earnings_estimate_observation e
    WHERE e.instrument_mapping_id = instrument_mapping_id_value
      AND e.vendor_observation_key = vendor_observation_key_value;

    SELECT *
    INTO decision_row
    FROM evaluate_entitlement_gate(
        'wu14-earnings:' || vendor_observation_key_value || ':' || next_revision,
        entitlement_version_row.entitlement_version_id,
        'local_research', estimate_receipt_time, source_lineage_value
    );
    IF decision_row.decision <> 'allowed' THEN
        RETURN NULL;
    END IF;

    PERFORM record_entitled_use(
        'wu14-earnings-use:' || vendor_observation_key_value || ':' || next_revision,
        decision_row.decision_id, 'earnings-estimate-connector', source_lineage_value
    );

    PERFORM set_config('market_mate.earnings_estimate_write', 'on', true);
    BEGIN
        INSERT INTO earnings_estimate_observation (
            instrument_mapping_id, security_id,
            source_registry_version_id, entitlement_version_id, gate_decision_id,
            vendor_observation_key, fiscal_period_end, metric, estimate_value,
            unit, currency, announcement_at, as_of_at, observation_status, revision,
            raw_payload, payload_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            mapping_row.mapping_id, mapping_row.security_id,
            entitlement_version_row.source_registry_version_id,
            entitlement_version_row.entitlement_version_id, decision_row.decision_id,
            vendor_observation_key_value, fiscal_period_end_value, metric_value,
            estimate_value_value, unit_value, currency_value, announcement_at_value,
            as_of_at_value, CASE WHEN next_revision = 1 THEN 'published' ELSE 'revised' END,
            next_revision, raw_payload_value,
            encode(digest(convert_to(raw_payload_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, estimate_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.earnings_estimate_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.earnings_estimate_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION reconcile_earnings_actual(
    estimate_id_value uuid,
    edgar_actual_id_value uuid,
    tolerance_value numeric,
    source_lineage_value jsonb
) RETURNS earnings_actual_reconciliation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    estimate_row earnings_estimate_observation%ROWTYPE;
    actual_row edgar_xbrl_actual%ROWTYPE;
    filing_row edgar_filing%ROWTYPE;
    security_row security%ROWTYPE;
    created earnings_actual_reconciliation%ROWTYPE;
    actual_value_value numeric;
    variance_value numeric;
    next_revision integer;
    reconciliation_receipt_time timestamptz := clock_timestamp();
    announcement_linked_value boolean;
    status_value text;
BEGIN
    IF tolerance_value IS NULL OR tolerance_value < 0 THEN
        RAISE EXCEPTION 'earnings reconciliation tolerance is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'earnings reconciliation source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT e.*
    INTO estimate_row
    FROM earnings_estimate_observation e
    WHERE e.estimate_id = estimate_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'earnings estimate % is not registered', estimate_id_value
            USING ERRCODE = '22023';
    END IF;

    SELECT a.*
    INTO actual_row
    FROM edgar_xbrl_actual a
    WHERE a.actual_id = edgar_actual_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EDGAR actual % is not registered', edgar_actual_id_value
            USING ERRCODE = '22023';
    END IF;

    SELECT f.*
    INTO filing_row
    FROM edgar_filing f
    JOIN source_registry_version sv ON sv.source_version_id = f.source_registry_version_id
    JOIN source_registry s ON s.source_id = sv.source_id
    WHERE f.filing_id = actual_row.filing_id
      AND s.source_kind = 'public_filing';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'earnings actual must come from a registered public EDGAR filing'
            USING ERRCODE = '55000';
    END IF;

    SELECT s.*
    INTO security_row
    FROM security s
    WHERE s.security_id = estimate_row.security_id;
    IF filing_row.issuer_id <> security_row.issuer_id THEN
        RAISE EXCEPTION 'earnings actual issuer does not match estimate security'
            USING ERRCODE = '55000';
    END IF;
    IF lower(btrim(actual_row.concept)) <> lower(btrim(estimate_row.metric)) THEN
        RAISE EXCEPTION 'earnings actual concept does not match estimate metric'
            USING ERRCODE = '55000';
    END IF;
    IF actual_row.period_end IS NULL
       OR (actual_row.period_end AT TIME ZONE 'UTC')::date <> estimate_row.fiscal_period_end THEN
        RAISE EXCEPTION
            'earnings actual period end does not match estimate fiscal period end'
            USING ERRCODE = '55000';
    END IF;

    BEGIN
        actual_value_value := actual_row.fact_value::numeric;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'EDGAR actual fact value is not numeric' USING ERRCODE = '22023';
    END;
    variance_value := actual_value_value - estimate_row.estimate_value;
    status_value := CASE
        WHEN abs(variance_value) <= tolerance_value THEN 'matched'
        ELSE 'disagreement'
    END;
    announcement_linked_value := filing_row.filed_at >= estimate_row.announcement_at;

    PERFORM pg_advisory_xact_lock(8716);
    SELECT coalesce(max(r.reconciliation_revision), 0) + 1
    INTO next_revision
    FROM earnings_actual_reconciliation r
    WHERE r.estimate_id = estimate_id_value
      AND r.edgar_actual_id = edgar_actual_id_value;

    PERFORM record_entitled_use(
        'wu14-reconciliation-use:' || estimate_row.vendor_observation_key || ':' || next_revision,
        estimate_row.gate_decision_id, 'earnings-edgar-reconciler', source_lineage_value
    );

    PERFORM set_config('market_mate.earnings_reconciliation_write', 'on', true);
    BEGIN
        INSERT INTO earnings_actual_reconciliation (
            estimate_id, edgar_actual_id,
            estimate_source_registry_version_id, estimate_entitlement_version_id,
            edgar_source_registry_version_id, edgar_entitlement_version_id,
            gate_decision_id, reconciliation_revision,
            announcement_at, actual_filed_at, estimate_as_of_at,
            estimate_value, actual_value, variance, tolerance, actual_concept,
            reconciliation_status, announcement_linked,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            estimate_row.estimate_id, actual_row.actual_id,
            estimate_row.source_registry_version_id, estimate_row.entitlement_version_id,
            actual_row.source_registry_version_id, actual_row.entitlement_version_id,
            estimate_row.gate_decision_id, next_revision,
            estimate_row.announcement_at, filing_row.filed_at, estimate_row.as_of_at,
            estimate_row.estimate_value, actual_value_value, variance_value,
            tolerance_value, actual_row.concept, status_value, announcement_linked_value,
            source_lineage_value, reconciliation_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.earnings_reconciliation_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.earnings_reconciliation_write', 'off', true);
    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
