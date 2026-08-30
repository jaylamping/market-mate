-- Licensed daily EOD and corporate-actions connector for Local Research.
-- Vendor selection is evidence, not configuration: ingestion must name the
-- selected record and use its exact registered source and entitlement version.
-- Every delivery is append-only, including missing and revised observations.

CREATE TABLE eod_vendor_selection (
    selection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_key text NOT NULL UNIQUE CHECK (btrim(vendor_key) <> ''),
    selection_state text NOT NULL CHECK (selection_state IN ('candidate', 'selected', 'retired')),
    comparison jsonb NOT NULL CHECK (
        jsonb_typeof(comparison) = 'object'
        AND comparison ? 'selected'
        AND comparison ? 'candidates'
        AND jsonb_typeof(comparison -> 'candidates') = 'array'
    ),
    license_criteria jsonb NOT NULL CHECK (
        jsonb_typeof(license_criteria) = 'object'
        AND license_criteria ? 'status'
    ),
    entitlement_criteria jsonb NOT NULL CHECK (
        jsonb_typeof(entitlement_criteria) = 'object'
        AND entitlement_criteria ? 'status'
    ),
    cost_criteria jsonb NOT NULL CHECK (
        jsonb_typeof(cost_criteria) = 'object'
        AND cost_criteria ? 'monthly_cost_usd'
        AND cost_criteria ? 'within_stage_cap'
    ),
    selection_rationale text NOT NULL CHECK (btrim(selection_rationale) <> ''),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    selected_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    UNIQUE (selection_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        )
);

SELECT register_evidence_table('eod_vendor_selection');

CREATE TABLE eod_price_observation (
    observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    selection_id uuid NOT NULL,
    instrument_mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    vendor_observation_key text NOT NULL CHECK (btrim(vendor_observation_key) <> ''),
    trading_date date NOT NULL,
    observation_status text NOT NULL CHECK (observation_status IN ('complete', 'missing', 'revised')),
    revision integer NOT NULL CHECK (revision >= 1),
    open_price numeric,
    high_price numeric,
    low_price numeric,
    close_price numeric,
    volume bigint,
    available_at timestamptz NOT NULL,
    raw_payload jsonb NOT NULL CHECK (jsonb_typeof(raw_payload) = 'object'),
    payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        payload_digest = encode(digest(convert_to(raw_payload::text, 'UTF8'), 'sha256'), 'hex')
    ),
    CHECK (
        (
            observation_status = 'missing'
            AND open_price IS NULL AND high_price IS NULL
            AND low_price IS NULL AND close_price IS NULL AND volume IS NULL
        )
        OR (
            observation_status IN ('complete', 'revised')
            AND open_price IS NOT NULL AND high_price IS NOT NULL
            AND low_price IS NOT NULL AND close_price IS NOT NULL
            AND volume IS NOT NULL AND open_price > 0 AND high_price > 0
            AND low_price > 0 AND close_price > 0 AND high_price >= low_price
            AND volume >= 0
        )
    ),
    UNIQUE (observation_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (selection_id, source_registry_version_id, entitlement_version_id)
        REFERENCES eod_vendor_selection (
            selection_id, source_registry_version_id, entitlement_version_id
        ),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        ),
    FOREIGN KEY (gate_decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('eod_price_observation');

CREATE INDEX eod_price_observation_lookup_idx
    ON eod_price_observation (instrument_mapping_id, trading_date, receipt_time, revision);

CREATE TABLE eod_corporate_action_observation (
    observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    selection_id uuid NOT NULL,
    instrument_mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    case_id uuid NOT NULL REFERENCES corporate_action_case(case_id),
    terms_id uuid NOT NULL REFERENCES corporate_action_terms_version(terms_id),
    vendor_observation_key text NOT NULL CHECK (btrim(vendor_observation_key) <> ''),
    action_type text NOT NULL CHECK (btrim(action_type) <> ''),
    observed_state text NOT NULL CHECK (observed_state IN (
        'rumored', 'announced', 'terms_pending',
        'authoritatively_confirmed', 'effective',
        'broker_reconciled', 'final'
    )),
    effective_at timestamptz,
    revision integer NOT NULL CHECK (revision >= 1),
    terms jsonb NOT NULL CHECK (jsonb_typeof(terms) = 'object'),
    raw_payload jsonb NOT NULL CHECK (jsonb_typeof(raw_payload) = 'object'),
    payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        payload_digest = encode(digest(convert_to(raw_payload::text, 'UTF8'), 'sha256'), 'hex')
    ),
    UNIQUE (observation_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (selection_id, source_registry_version_id, entitlement_version_id)
        REFERENCES eod_vendor_selection (
            selection_id, source_registry_version_id, entitlement_version_id
        ),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        ),
    FOREIGN KEY (gate_decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('eod_corporate_action_observation');

CREATE INDEX eod_corporate_action_observation_lookup_idx
    ON eod_corporate_action_observation (instrument_mapping_id, vendor_observation_key, receipt_time, revision);

CREATE FUNCTION guard_eod_vendor_selection_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'eod_vendor_selection is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.eod_vendor_selection_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'eod_vendor_selection writes must go through record_eod_vendor_selection'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER eod_vendor_selection_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON eod_vendor_selection
FOR EACH ROW EXECUTE FUNCTION guard_eod_vendor_selection_write();

CREATE TRIGGER eod_vendor_selection_truncate_guard
BEFORE TRUNCATE ON eod_vendor_selection
FOR EACH STATEMENT EXECUTE FUNCTION guard_eod_vendor_selection_write();

CREATE FUNCTION guard_eod_price_observation_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'eod_price_observation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.eod_price_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'eod_price_observation writes must go through ingest_eod_price_observation'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER eod_price_observation_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON eod_price_observation
FOR EACH ROW EXECUTE FUNCTION guard_eod_price_observation_write();

CREATE TRIGGER eod_price_observation_truncate_guard
BEFORE TRUNCATE ON eod_price_observation
FOR EACH STATEMENT EXECUTE FUNCTION guard_eod_price_observation_write();

CREATE FUNCTION guard_eod_corporate_action_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'eod_corporate_action_observation is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.eod_corporate_action_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'eod_corporate_action_observation writes must go through ingest_eod_corporate_action'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER eod_corporate_action_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON eod_corporate_action_observation
FOR EACH ROW EXECUTE FUNCTION guard_eod_corporate_action_write();

CREATE TRIGGER eod_corporate_action_truncate_guard
BEFORE TRUNCATE ON eod_corporate_action_observation
FOR EACH STATEMENT EXECUTE FUNCTION guard_eod_corporate_action_write();

CREATE FUNCTION record_eod_vendor_selection(
    vendor_key_value text,
    source_registry_version_id_value uuid,
    entitlement_version_id_value uuid,
    comparison_value jsonb,
    license_criteria_value jsonb,
    entitlement_criteria_value jsonb,
    cost_criteria_value jsonb,
    selection_rationale_value text,
    source_lineage_value jsonb
) RETURNS eod_vendor_selection
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created eod_vendor_selection%ROWTYPE;
BEGIN
    IF coalesce(btrim(vendor_key_value), '') = ''
       OR coalesce(btrim(selection_rationale_value), '') = '' THEN
        RAISE EXCEPTION 'EOD vendor selection required fields are missing' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'EOD vendor selection source_lineage is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM data_entitlement_version v
        WHERE v.entitlement_version_id = entitlement_version_id_value
          AND v.source_registry_version_id = source_registry_version_id_value
    ) THEN
        RAISE EXCEPTION 'EOD vendor selection source and entitlement versions do not match'
            USING ERRCODE = '55000';
    END IF;

    PERFORM set_config('market_mate.eod_vendor_selection_write', 'on', true);
    BEGIN
        INSERT INTO eod_vendor_selection (
            vendor_key, selection_state, comparison,
            license_criteria, entitlement_criteria, cost_criteria,
            selection_rationale, source_registry_version_id,
            entitlement_version_id, selected_at,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            vendor_key_value, 'selected', comparison_value,
            license_criteria_value, entitlement_criteria_value, cost_criteria_value,
            selection_rationale_value, source_registry_version_id_value,
            entitlement_version_id_value, clock_timestamp(),
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.eod_vendor_selection_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.eod_vendor_selection_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION ingest_eod_price_observation(
    selection_id_value uuid,
    instrument_mapping_id_value uuid,
    vendor_observation_key_value text,
    trading_date_value date,
    observation_status_value text,
    open_price_value numeric,
    high_price_value numeric,
    low_price_value numeric,
    close_price_value numeric,
    volume_value bigint,
    available_at_value timestamptz,
    raw_payload_value jsonb,
    source_lineage_value jsonb
) RETURNS eod_price_observation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    selection_row eod_vendor_selection%ROWTYPE;
    mapping_row instrument_mapping%ROWTYPE;
    decision_row entitlement_gate_decision%ROWTYPE;
    created eod_price_observation%ROWTYPE;
    next_revision integer;
    observation_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF coalesce(btrim(vendor_observation_key_value), '') = ''
       OR trading_date_value IS NULL
       OR available_at_value IS NULL
       OR observation_status_value NOT IN ('complete', 'missing', 'revised') THEN
        RAISE EXCEPTION 'EOD price observation required fields are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'EOD price observation source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT s.*
    INTO selection_row
    FROM eod_vendor_selection s
    WHERE s.selection_id = selection_id_value;
    IF NOT FOUND OR selection_row.selection_state <> 'selected' THEN
        RAISE EXCEPTION 'EOD vendor selection is not active and selected'
            USING ERRCODE = '55000';
    END IF;

    SELECT m.*
    INTO mapping_row
    FROM instrument_mapping m
    WHERE m.mapping_id = instrument_mapping_id_value;
    IF NOT FOUND
       OR mapping_row.lifecycle <> 'certified'
       OR mapping_row.object_kind <> 'security' THEN
        RAISE EXCEPTION 'EOD identity mapping must be certified for a security'
            USING ERRCODE = '55000';
    END IF;

    PERFORM pg_advisory_xact_lock(8713);
    SELECT coalesce(max(o.revision), 0) + 1
    INTO next_revision
    FROM eod_price_observation o
    WHERE o.selection_id = selection_id_value
      AND o.instrument_mapping_id = instrument_mapping_id_value
      AND o.vendor_observation_key = vendor_observation_key_value;

    SELECT *
    INTO decision_row
    FROM evaluate_entitlement_gate(
        'wu13-eod:' || selection_row.vendor_key || ':'
            || vendor_observation_key_value || ':' || next_revision,
        selection_row.entitlement_version_id,
        'local_research', observation_receipt_time, source_lineage_value
    );
    IF decision_row.decision <> 'allowed' THEN
        RETURN NULL;
    END IF;

    PERFORM record_entitled_use(
        'wu13-eod-use:' || selection_row.vendor_key || ':'
            || vendor_observation_key_value || ':' || next_revision,
        decision_row.decision_id, 'eod-price-connector', source_lineage_value
    );

    PERFORM set_config('market_mate.eod_price_write', 'on', true);
    BEGIN
        INSERT INTO eod_price_observation (
            selection_id, instrument_mapping_id, security_id,
            source_registry_version_id, entitlement_version_id, gate_decision_id,
            vendor_observation_key, trading_date, observation_status, revision,
            open_price, high_price, low_price, close_price, volume, available_at,
            raw_payload, payload_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            selection_row.selection_id, mapping_row.mapping_id, mapping_row.security_id,
            selection_row.source_registry_version_id, selection_row.entitlement_version_id,
            decision_row.decision_id, vendor_observation_key_value, trading_date_value,
            observation_status_value, next_revision, open_price_value, high_price_value,
            low_price_value, close_price_value, volume_value, available_at_value,
            raw_payload_value,
            encode(digest(convert_to(raw_payload_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, observation_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.eod_price_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.eod_price_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION eod_price_observation_at(
    instrument_mapping_id_value uuid,
    trading_date_value date,
    as_of_value timestamptz
) RETURNS eod_price_observation
LANGUAGE sql
STABLE
AS $$
    SELECT o
    FROM eod_price_observation o
    WHERE o.instrument_mapping_id = instrument_mapping_id_value
      AND o.trading_date = trading_date_value
      AND o.available_at <= as_of_value
      AND o.receipt_time <= as_of_value
    ORDER BY o.receipt_time DESC, o.revision DESC
    LIMIT 1;
$$;

CREATE FUNCTION ingest_eod_corporate_action(
    selection_id_value uuid,
    instrument_mapping_id_value uuid,
    vendor_observation_key_value text,
    action_type_value text,
    observed_state_value text,
    effective_at_value timestamptz,
    terms_value jsonb,
    raw_payload_value jsonb,
    source_lineage_value jsonb
) RETURNS eod_corporate_action_observation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    selection_row eod_vendor_selection%ROWTYPE;
    mapping_row instrument_mapping%ROWTYPE;
    previous_observation eod_corporate_action_observation%ROWTYPE;
    decision_row entitlement_gate_decision%ROWTYPE;
    case_row corporate_action_case%ROWTYPE;
    terms_row corporate_action_terms_version%ROWTYPE;
    created eod_corporate_action_observation%ROWTYPE;
    current_state text;
    next_revision integer;
    action_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF coalesce(btrim(vendor_observation_key_value), '') = ''
       OR coalesce(btrim(action_type_value), '') = ''
       OR observed_state_value NOT IN (
           'rumored', 'announced', 'terms_pending',
           'authoritatively_confirmed', 'effective', 'broker_reconciled', 'final'
       )
       OR jsonb_typeof(terms_value) <> 'object'
       OR jsonb_typeof(raw_payload_value) <> 'object' THEN
        RAISE EXCEPTION 'corporate-action observation required fields are invalid'
            USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'corporate-action observation source_lineage is invalid'
            USING ERRCODE = '22023';
    END IF;

    SELECT s.*
    INTO selection_row
    FROM eod_vendor_selection s
    WHERE s.selection_id = selection_id_value;
    IF NOT FOUND OR selection_row.selection_state <> 'selected' THEN
        RAISE EXCEPTION 'EOD vendor selection is not active and selected'
            USING ERRCODE = '55000';
    END IF;

    SELECT m.*
    INTO mapping_row
    FROM instrument_mapping m
    WHERE m.mapping_id = instrument_mapping_id_value;
    IF NOT FOUND
       OR mapping_row.lifecycle <> 'certified'
       OR mapping_row.object_kind <> 'security' THEN
        RAISE EXCEPTION 'corporate-action identity mapping must be certified for a security'
            USING ERRCODE = '55000';
    END IF;

    PERFORM pg_advisory_xact_lock(8714);
    SELECT o.*
    INTO previous_observation
    FROM eod_corporate_action_observation o
    WHERE o.selection_id = selection_id_value
      AND o.instrument_mapping_id = instrument_mapping_id_value
      AND o.vendor_observation_key = vendor_observation_key_value
    ORDER BY o.revision DESC
    LIMIT 1;
    next_revision := coalesce(previous_observation.revision, 0) + 1;

    SELECT *
    INTO decision_row
    FROM evaluate_entitlement_gate(
        'wu13-ca:' || selection_row.vendor_key || ':'
            || vendor_observation_key_value || ':' || next_revision,
        selection_row.entitlement_version_id,
        'local_research', action_receipt_time, source_lineage_value
    );
    IF decision_row.decision <> 'allowed' THEN
        RETURN NULL;
    END IF;

    PERFORM record_entitled_use(
        'wu13-ca-use:' || selection_row.vendor_key || ':'
            || vendor_observation_key_value || ':' || next_revision,
        decision_row.decision_id, 'eod-corporate-actions-connector', source_lineage_value
    );

    IF previous_observation.observation_id IS NULL THEN
        SELECT *
        INTO case_row
        FROM open_corporate_action_case(
            mapping_row.security_id, action_type_value,
            observed_state_value, source_lineage_value
        );
    ELSE
        case_row.case_id := previous_observation.case_id;
        IF previous_observation.action_type <> action_type_value THEN
            RAISE EXCEPTION
                'corporate-action action type cannot change within case %', case_row.case_id
                USING ERRCODE = '55000';
        END IF;
        current_state := corporate_action_case_state(case_row.case_id, action_receipt_time);
        IF current_state IS NULL THEN
            RAISE EXCEPTION 'corporate-action case % has no observable state', case_row.case_id
                USING ERRCODE = '55000';
        END IF;
        IF current_state = 'final' THEN
            RAISE EXCEPTION
                'corporate-action terms cannot change after case % is final', case_row.case_id
                USING ERRCODE = '55000';
        END IF;
        IF current_state <> observed_state_value THEN
            PERFORM record_corporate_action_observation(
                case_row.case_id, observed_state_value, selection_row.vendor_key,
                'vendor revision ' || next_revision, source_lineage_value
            );
        END IF;
    END IF;

    SELECT *
    INTO terms_row
    FROM add_corporate_action_terms(
        case_row.case_id, terms_value, source_lineage_value
    );

    PERFORM set_config('market_mate.eod_corporate_action_write', 'on', true);
    BEGIN
        INSERT INTO eod_corporate_action_observation (
            selection_id, instrument_mapping_id, security_id,
            source_registry_version_id, entitlement_version_id, gate_decision_id,
            case_id, terms_id, vendor_observation_key, action_type, observed_state,
            effective_at, revision, terms, raw_payload, payload_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            selection_row.selection_id, mapping_row.mapping_id, mapping_row.security_id,
            selection_row.source_registry_version_id, selection_row.entitlement_version_id,
            decision_row.decision_id, case_row.case_id, terms_row.terms_id,
            vendor_observation_key_value, action_type_value, observed_state_value,
            effective_at_value, next_revision, terms_value, raw_payload_value,
            encode(digest(convert_to(raw_payload_value::text, 'UTF8'), 'sha256'), 'hex'),
            source_lineage_value, action_receipt_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.eod_corporate_action_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.eod_corporate_action_write', 'off', true);
    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
