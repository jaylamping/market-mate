-- EDGAR filing and XBRL actual ingestion for Local Research.
-- The connector records the exact registered source and entitlement version,
-- requires a Certified issuer mapping, and stores collected bytes as verbatim
-- untrusted content. No field is interpreted as executable instructions.

CREATE TABLE edgar_filing (
    filing_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    accession_number text NOT NULL UNIQUE CHECK (btrim(accession_number) <> ''),
    instrument_mapping_id uuid NOT NULL REFERENCES instrument_mapping(mapping_id),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    source_registry_version_id uuid NOT NULL REFERENCES source_registry_version(source_version_id),
    entitlement_version_id uuid NOT NULL REFERENCES data_entitlement_version(entitlement_version_id),
    gate_decision_id uuid NOT NULL REFERENCES entitlement_gate_decision(decision_id),
    form_type text NOT NULL CHECK (btrim(form_type) <> ''),
    filed_at timestamptz NOT NULL,
    source_url text NOT NULL CHECK (btrim(source_url) <> ''),
    content_media_type text NOT NULL CHECK (btrim(content_media_type) <> ''),
    raw_content text NOT NULL CHECK (octet_length(raw_content) > 0),
    content_digest text NOT NULL CHECK (content_digest ~ '^[0-9a-f]{64}$'),
    content_handling text NOT NULL CHECK (content_handling = 'verbatim_untrusted'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        content_digest = encode(digest(convert_to(raw_content, 'UTF8'), 'sha256'), 'hex')
    ),
    UNIQUE (filing_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (entitlement_version_id, source_registry_version_id)
        REFERENCES data_entitlement_version (
            entitlement_version_id, source_registry_version_id
        ),
    FOREIGN KEY (gate_decision_id, source_registry_version_id, entitlement_version_id)
        REFERENCES entitlement_gate_decision (
            decision_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('edgar_filing');

CREATE TABLE edgar_xbrl_actual (
    actual_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    filing_id uuid NOT NULL,
    source_registry_version_id uuid NOT NULL,
    entitlement_version_id uuid NOT NULL,
    concept text NOT NULL CHECK (btrim(concept) <> ''),
    fact_value text NOT NULL CHECK (btrim(fact_value) <> ''),
    unit text NOT NULL CHECK (btrim(unit) <> ''),
    period_start timestamptz,
    period_end timestamptz,
    raw_fact text NOT NULL CHECK (octet_length(raw_fact) > 0),
    fact_digest text NOT NULL CHECK (fact_digest ~ '^[0-9a-f]{64}$'),
    content_handling text NOT NULL CHECK (content_handling = 'verbatim_untrusted'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (period_start IS NULL AND period_end IS NULL)
        OR (period_start IS NOT NULL AND period_end IS NOT NULL AND period_end > period_start)
    ),
    CHECK (fact_digest = encode(digest(convert_to(raw_fact, 'UTF8'), 'sha256'), 'hex')),
    UNIQUE (actual_id, source_registry_version_id, entitlement_version_id),
    FOREIGN KEY (filing_id, source_registry_version_id, entitlement_version_id)
        REFERENCES edgar_filing (
            filing_id, source_registry_version_id, entitlement_version_id
        )
);

SELECT register_evidence_table('edgar_xbrl_actual');

CREATE FUNCTION guard_edgar_filing_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'edgar_filing is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.edgar_filing_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'edgar_filing writes must go through ingest_edgar_filing'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER edgar_filing_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON edgar_filing
FOR EACH ROW EXECUTE FUNCTION guard_edgar_filing_write();

CREATE TRIGGER edgar_filing_truncate_guard
BEFORE TRUNCATE ON edgar_filing
FOR EACH STATEMENT EXECUTE FUNCTION guard_edgar_filing_write();

CREATE FUNCTION guard_edgar_xbrl_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'edgar_xbrl_actual is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.edgar_xbrl_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'edgar_xbrl_actual writes must go through ingest_edgar_xbrl_actual'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER edgar_xbrl_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON edgar_xbrl_actual
FOR EACH ROW EXECUTE FUNCTION guard_edgar_xbrl_write();

CREATE TRIGGER edgar_xbrl_truncate_guard
BEFORE TRUNCATE ON edgar_xbrl_actual
FOR EACH STATEMENT EXECUTE FUNCTION guard_edgar_xbrl_write();

CREATE FUNCTION ingest_edgar_filing(
    accession_number_value text,
    instrument_mapping_id_value uuid,
    form_type_value text,
    source_registry_version_id_value uuid,
    entitlement_version_id_value uuid,
    filed_at_value timestamptz,
    source_url_value text,
    content_media_type_value text,
    raw_content_value text,
    source_lineage_value jsonb
) RETURNS edgar_filing
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    mapping_row instrument_mapping%ROWTYPE;
    entitlement_version_row data_entitlement_version%ROWTYPE;
    decision_row entitlement_gate_decision%ROWTYPE;
    created edgar_filing%ROWTYPE;
    filing_receipt_time timestamptz := clock_timestamp();
BEGIN
    IF coalesce(btrim(accession_number_value), '') = ''
       OR coalesce(btrim(form_type_value), '') = ''
       OR coalesce(btrim(source_url_value), '') = ''
       OR coalesce(btrim(content_media_type_value), '') = ''
       OR raw_content_value IS NULL
       OR octet_length(raw_content_value) = 0
       OR filed_at_value IS NULL THEN
        RAISE EXCEPTION 'EDGAR filing required fields are missing' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'EDGAR filing source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT m.*
    INTO mapping_row
    FROM instrument_mapping m
    WHERE m.mapping_id = instrument_mapping_id_value;
    IF NOT FOUND
       OR mapping_row.lifecycle <> 'certified'
       OR mapping_row.object_kind <> 'issuer' THEN
        RAISE EXCEPTION 'EDGAR filing identity mapping must be certified'
            USING ERRCODE = '55000';
    END IF;

    SELECT v.*
    INTO entitlement_version_row
    FROM data_entitlement_version v
    WHERE v.entitlement_version_id = entitlement_version_id_value
      AND v.source_registry_version_id = source_registry_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EDGAR filing source and entitlement versions do not match'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
    INTO decision_row
    FROM evaluate_entitlement_gate(
        'wu12-edgar:' || accession_number_value,
        entitlement_version_row.entitlement_version_id,
        'local_research',
        filing_receipt_time,
        source_lineage_value
    );
    IF decision_row.decision <> 'allowed' THEN
        RETURN NULL;
    END IF;

    PERFORM record_entitled_use(
        'wu12-edgar-use:' || accession_number_value,
        decision_row.decision_id,
        'edgar-filing-connector',
        source_lineage_value
    );

    PERFORM set_config('market_mate.edgar_filing_write', 'on', true);
    BEGIN
        INSERT INTO edgar_filing (
            accession_number, instrument_mapping_id, issuer_id,
            source_registry_version_id, entitlement_version_id, gate_decision_id,
            form_type, filed_at, source_url, content_media_type,
            raw_content, content_digest, content_handling,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            accession_number_value, mapping_row.mapping_id, mapping_row.issuer_id,
            source_registry_version_id_value, entitlement_version_row.entitlement_version_id,
            decision_row.decision_id, form_type_value, filed_at_value,
            source_url_value, content_media_type_value, raw_content_value,
            encode(digest(convert_to(raw_content_value, 'UTF8'), 'sha256'), 'hex'),
            'verbatim_untrusted', source_lineage_value, filing_receipt_time,
            'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.edgar_filing_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.edgar_filing_write', 'off', true);

    RETURN created;
END;
$$;

CREATE FUNCTION ingest_edgar_xbrl_actual(
    filing_id_value uuid,
    concept_value text,
    fact_value_value text,
    unit_value text,
    period_start_value timestamptz,
    period_end_value timestamptz,
    raw_fact_value text,
    source_lineage_value jsonb
) RETURNS edgar_xbrl_actual
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    filing_row edgar_filing%ROWTYPE;
    created edgar_xbrl_actual%ROWTYPE;
    actual_receipt_time timestamptz := clock_timestamp();
    xbrl_use_key_value text;
BEGIN
    IF coalesce(btrim(concept_value), '') = ''
       OR coalesce(btrim(fact_value_value), '') = ''
       OR coalesce(btrim(unit_value), '') = ''
       OR raw_fact_value IS NULL
       OR octet_length(raw_fact_value) = 0 THEN
        RAISE EXCEPTION 'EDGAR XBRL actual required fields are missing' USING ERRCODE = '22023';
    END IF;
    IF (period_start_value IS NULL) <> (period_end_value IS NULL)
       OR (period_start_value IS NOT NULL AND period_end_value <= period_start_value) THEN
        RAISE EXCEPTION 'EDGAR XBRL actual period is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'EDGAR XBRL actual source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT f.*
    INTO filing_row
    FROM edgar_filing f
    WHERE f.filing_id = filing_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EDGAR filing % is not registered', filing_id_value
            USING ERRCODE = '22023';
    END IF;

    xbrl_use_key_value := 'wu12-edgar-xbrl-use:' || filing_row.accession_number || ':'
        || encode(
            digest(
                'market-mate-edgar-xbrl-use-v1|' || jsonb_build_array(
                    concept_value,
                    unit_value,
                    period_start_value,
                    period_end_value,
                    fact_value_value,
                    raw_fact_value
                )::text,
                'sha256'
            ),
            'hex'
        );

    PERFORM record_entitled_use(
        xbrl_use_key_value,
        filing_row.gate_decision_id,
        'edgar-xbrl-consumer',
        source_lineage_value
    );

    PERFORM set_config('market_mate.edgar_xbrl_write', 'on', true);
    BEGIN
        INSERT INTO edgar_xbrl_actual (
            filing_id, source_registry_version_id, entitlement_version_id,
            concept, fact_value, unit, period_start, period_end,
            raw_fact, fact_digest, content_handling,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            filing_row.filing_id, filing_row.source_registry_version_id,
            filing_row.entitlement_version_id, concept_value, fact_value_value,
            unit_value, period_start_value, period_end_value, raw_fact_value,
            encode(digest(convert_to(raw_fact_value, 'UTF8'), 'sha256'), 'hex'),
            'verbatim_untrusted', source_lineage_value, actual_receipt_time,
            'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.edgar_xbrl_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.edgar_xbrl_write', 'off', true);

    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
