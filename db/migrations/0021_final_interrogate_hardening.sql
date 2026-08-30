-- Final adversarial hardening for the Stage-1 evidence pipeline.
--
-- This migration closes the gaps found by the final interrogate pass:
-- version successors close open ranges through a controlled append workflow;
-- entitlement decisions support explicit retry attempts; connector identity
-- and contract bindings are persisted at every ingestion boundary; proof and
-- manifest inserts are workflow-gated; and publication/delta rows cannot
-- claim knowledge before the source was received or made available.

CREATE OR REPLACE FUNCTION guard_append_only_evidence() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND current_setting('market_mate.version_close_write', true) IS DISTINCT FROM 'on'
           THEN
        RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
            USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'UPDATE'
       AND current_setting('market_mate.version_close_write', true) = 'on'
       AND TG_TABLE_NAME IN ('source_registry_version', 'data_contract_version')
       AND (to_jsonb(OLD)->>'effective_to') IS NULL
       AND (to_jsonb(NEW)->>'effective_to') IS NOT NULL
       AND (to_jsonb(NEW) - 'effective_to') = (to_jsonb(OLD) - 'effective_to') THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND current_setting('market_mate.version_close_write', true) = 'on'
       AND TG_TABLE_NAME = 'data_entitlement_version'
       AND (to_jsonb(OLD)->>'expires_at') IS NULL
       AND (to_jsonb(NEW)->>'expires_at') IS NOT NULL
       AND (to_jsonb(NEW) - 'expires_at') = (to_jsonb(OLD) - 'expires_at') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
        USING ERRCODE = '55000';
END;
$$;

CREATE FUNCTION close_open_source_registry_version() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    prior source_registry_version%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(8710, hashtext(NEW.source_id::text));
    SELECT * INTO prior
    FROM source_registry_version
    WHERE source_id = NEW.source_id
    ORDER BY effective_from DESC
    LIMIT 1;

    IF prior.source_version_id IS NOT NULL THEN
        IF NEW.effective_from <= prior.effective_from THEN
            RAISE EXCEPTION 'source registry version effective_from must advance for source %', NEW.source_id
                USING ERRCODE = '23P01';
        END IF;
        IF prior.effective_to IS NULL THEN
            PERFORM set_config('market_mate.version_close_write', 'on', true);
            BEGIN
                UPDATE source_registry_version
                   SET effective_to = NEW.effective_from
                 WHERE source_version_id = prior.source_version_id;
            EXCEPTION
                WHEN OTHERS THEN
                    PERFORM set_config('market_mate.version_close_write', 'off', true);
                    RAISE;
            END;
            PERFORM set_config('market_mate.version_close_write', 'off', true);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER source_registry_version_successor_closure
BEFORE INSERT ON source_registry_version
FOR EACH ROW EXECUTE FUNCTION close_open_source_registry_version();

CREATE FUNCTION close_open_data_contract_version() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    prior data_contract_version%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(8710, hashtext(NEW.contract_id::text));
    SELECT * INTO prior
    FROM data_contract_version
    WHERE contract_id = NEW.contract_id
    ORDER BY effective_from DESC
    LIMIT 1;

    IF prior.contract_version_id IS NOT NULL THEN
        IF NEW.effective_from <= prior.effective_from THEN
            RAISE EXCEPTION 'data contract version effective_from must advance for contract %', NEW.contract_id
                USING ERRCODE = '23P01';
        END IF;
        IF prior.effective_to IS NULL THEN
            PERFORM set_config('market_mate.version_close_write', 'on', true);
            BEGIN
                UPDATE data_contract_version
                   SET effective_to = NEW.effective_from
                 WHERE contract_version_id = prior.contract_version_id;
            EXCEPTION
                WHEN OTHERS THEN
                    PERFORM set_config('market_mate.version_close_write', 'off', true);
                    RAISE;
            END;
            PERFORM set_config('market_mate.version_close_write', 'off', true);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER data_contract_version_successor_closure
BEFORE INSERT ON data_contract_version
FOR EACH ROW EXECUTE FUNCTION close_open_data_contract_version();

CREATE FUNCTION close_open_data_entitlement_version() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    prior data_entitlement_version%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(8710, hashtext(NEW.entitlement_id::text));
    SELECT * INTO prior
    FROM data_entitlement_version
    WHERE entitlement_id = NEW.entitlement_id
    ORDER BY effective_from DESC
    LIMIT 1;

    IF prior.entitlement_version_id IS NOT NULL THEN
        IF NEW.effective_from <= prior.effective_from THEN
            RAISE EXCEPTION 'entitlement version effective_from must advance for entitlement %', NEW.entitlement_id
                USING ERRCODE = '23P01';
        END IF;
        IF prior.expires_at IS NULL THEN
            PERFORM set_config('market_mate.version_close_write', 'on', true);
            BEGIN
                UPDATE data_entitlement_version
                   SET expires_at = NEW.effective_from
                 WHERE entitlement_version_id = prior.entitlement_version_id;
            EXCEPTION
                WHEN OTHERS THEN
                    PERFORM set_config('market_mate.version_close_write', 'off', true);
                    RAISE;
            END;
            PERFORM set_config('market_mate.version_close_write', 'off', true);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER data_entitlement_version_successor_closure
BEFORE INSERT ON data_entitlement_version
FOR EACH ROW EXECUTE FUNCTION close_open_data_entitlement_version();

ALTER TABLE entitlement_gate_decision
    DROP CONSTRAINT IF EXISTS entitlement_gate_decision_request_key_key;
ALTER TABLE entitlement_gate_decision
    ADD COLUMN decision_attempt integer NOT NULL DEFAULT 1
        CHECK (decision_attempt >= 1);
ALTER TABLE entitlement_gate_decision
    ADD CONSTRAINT entitlement_gate_decision_request_attempt_unique
    UNIQUE (request_key, decision_attempt);

CREATE FUNCTION assign_entitlement_gate_attempt() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(8711, hashtext(NEW.request_key));
    SELECT coalesce(max(decision_attempt), 0) + 1
    INTO NEW.decision_attempt
    FROM entitlement_gate_decision
    WHERE request_key = NEW.request_key;
    RETURN NEW;
END;
$$;

CREATE TRIGGER entitlement_gate_decision_attempt
BEFORE INSERT ON entitlement_gate_decision
FOR EACH ROW EXECUTE FUNCTION assign_entitlement_gate_attempt();

CREATE FUNCTION require_bound_source_connector(
    source_registry_version_id_value uuid,
    expected_connector_kind_value text
) RETURNS source_connector
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    connector_row source_connector%ROWTYPE;
    required_field_key text;
    required_field_keys text[];
BEGIN
    IF source_registry_version_id_value IS NULL
       OR coalesce(btrim(expected_connector_kind_value), '') = '' THEN
        RAISE EXCEPTION 'connector provenance inputs are required' USING ERRCODE = '22023';
    END IF;

    SELECT c.* INTO connector_row
    FROM source_connector c
    WHERE c.source_registry_version_id = source_registry_version_id_value
      AND c.connector_kind = expected_connector_kind_value
      AND c.lifecycle = 'active';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'no active % connector is bound to source registry version %',
            expected_connector_kind_value, source_registry_version_id_value
            USING ERRCODE = '55000';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM source_connector c
        WHERE c.source_registry_version_id = source_registry_version_id_value
          AND c.connector_kind = expected_connector_kind_value
          AND c.lifecycle = 'active'
          AND c.connector_id <> connector_row.connector_id
    ) THEN
        RAISE EXCEPTION
            'multiple active % connectors are bound to source registry version %',
            expected_connector_kind_value, source_registry_version_id_value
            USING ERRCODE = '55000';
    END IF;

    SELECT array_agg(value ORDER BY value)
    INTO required_field_keys
    FROM jsonb_array_elements_text(
        (SELECT lineage_rules -> 'required_fields'
         FROM source_registry_version
         WHERE source_version_id = source_registry_version_id_value)
    ) fields(value);

    FOREACH required_field_key IN ARRAY coalesce(required_field_keys, ARRAY[]::text[]) LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM connector_field_binding b
            JOIN data_contract_field f
              ON f.field_id = b.field_id
             AND f.contract_version_id = b.contract_version_id
            WHERE b.connector_id = connector_row.connector_id
              AND b.contract_version_id = connector_row.contract_version_id
              AND f.field_key = required_field_key
        ) THEN
            RAISE EXCEPTION
                'connector % is missing required contract field %',
                connector_row.connector_key, required_field_key
                USING ERRCODE = '55000';
        END IF;
    END LOOP;

    IF expected_connector_kind_value = 'historical_options'
       AND (SELECT availability_time_rules ->> 'data_mode'
            FROM data_contract_version
            WHERE contract_version_id = connector_row.contract_version_id) <> 'historical' THEN
        RAISE EXCEPTION
            'historical options connector % does not declare historical data mode'
            , connector_row.connector_key USING ERRCODE = '55000';
    END IF;
    RETURN connector_row;
END;
$$;

ALTER TABLE edgar_filing ADD COLUMN connector_id uuid;
ALTER TABLE edgar_filing ADD COLUMN contract_version_id uuid;
ALTER TABLE edgar_xbrl_actual ADD COLUMN connector_id uuid;
ALTER TABLE edgar_xbrl_actual ADD COLUMN contract_version_id uuid;
ALTER TABLE eod_vendor_selection ADD COLUMN connector_id uuid;
ALTER TABLE eod_vendor_selection ADD COLUMN contract_version_id uuid;
ALTER TABLE eod_price_observation ADD COLUMN connector_id uuid;
ALTER TABLE eod_price_observation ADD COLUMN contract_version_id uuid;
ALTER TABLE eod_corporate_action_observation ADD COLUMN connector_id uuid;
ALTER TABLE eod_corporate_action_observation ADD COLUMN contract_version_id uuid;
ALTER TABLE earnings_estimate_observation ADD COLUMN connector_id uuid;
ALTER TABLE earnings_estimate_observation ADD COLUMN contract_version_id uuid;
ALTER TABLE earnings_actual_reconciliation ADD COLUMN estimate_connector_id uuid;
ALTER TABLE earnings_actual_reconciliation ADD COLUMN estimate_contract_version_id uuid;
ALTER TABLE earnings_actual_reconciliation ADD COLUMN edgar_connector_id uuid;
ALTER TABLE earnings_actual_reconciliation ADD COLUMN edgar_contract_version_id uuid;
ALTER TABLE option_chain_snapshot ADD COLUMN connector_id uuid;
ALTER TABLE option_chain_snapshot ADD COLUMN contract_version_id uuid;
ALTER TABLE option_deliverable_version ADD COLUMN connector_id uuid;
ALTER TABLE option_deliverable_version ADD COLUMN contract_version_id uuid;
ALTER TABLE option_chain_contract ADD COLUMN connector_id uuid;
ALTER TABLE option_chain_contract ADD COLUMN contract_version_id uuid;

ALTER TABLE edgar_filing
    ADD CONSTRAINT edgar_filing_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE edgar_xbrl_actual
    ADD CONSTRAINT edgar_xbrl_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE eod_vendor_selection
    ADD CONSTRAINT eod_vendor_selection_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE eod_price_observation
    ADD CONSTRAINT eod_price_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE eod_corporate_action_observation
    ADD CONSTRAINT eod_corporate_action_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE earnings_estimate_observation
    ADD CONSTRAINT earnings_estimate_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE earnings_actual_reconciliation
    ADD CONSTRAINT earnings_reconciliation_estimate_connector_fk
    FOREIGN KEY (estimate_connector_id, estimate_contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id),
    ADD CONSTRAINT earnings_reconciliation_edgar_connector_fk
    FOREIGN KEY (edgar_connector_id, edgar_contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE option_chain_snapshot
    ADD CONSTRAINT option_snapshot_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE option_deliverable_version
    ADD CONSTRAINT option_deliverable_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);
ALTER TABLE option_chain_contract
    ADD CONSTRAINT option_contract_connector_fk
    FOREIGN KEY (connector_id, contract_version_id)
    REFERENCES source_connector (connector_id, contract_version_id);

CREATE FUNCTION populate_ingestion_connector_provenance() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    connector_row source_connector%ROWTYPE;
    selection_row eod_vendor_selection%ROWTYPE;
    filing_row edgar_filing%ROWTYPE;
    snapshot_row option_chain_snapshot%ROWTYPE;
    estimate_row earnings_estimate_observation%ROWTYPE;
    actual_row edgar_xbrl_actual%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME = 'edgar_filing' THEN
        connector_row := require_bound_source_connector(NEW.source_registry_version_id, 'edgar');
        NEW.connector_id := connector_row.connector_id;
        NEW.contract_version_id := connector_row.contract_version_id;
    ELSIF TG_TABLE_NAME = 'edgar_xbrl_actual' THEN
        SELECT * INTO filing_row FROM edgar_filing WHERE filing_id = NEW.filing_id;
        IF filing_row.connector_id IS NULL
           OR NEW.source_registry_version_id <> filing_row.source_registry_version_id
           OR NEW.entitlement_version_id <> filing_row.entitlement_version_id THEN
            RAISE EXCEPTION 'EDGAR actual connector provenance does not match its filing'
                USING ERRCODE = '55000';
        END IF;
        NEW.connector_id := filing_row.connector_id;
        NEW.contract_version_id := filing_row.contract_version_id;
    ELSIF TG_TABLE_NAME = 'eod_vendor_selection' THEN
        connector_row := require_bound_source_connector(NEW.source_registry_version_id, 'daily_eod');
        NEW.connector_id := connector_row.connector_id;
        NEW.contract_version_id := connector_row.contract_version_id;
    ELSIF TG_TABLE_NAME IN ('eod_price_observation', 'eod_corporate_action_observation') THEN
        SELECT * INTO selection_row FROM eod_vendor_selection WHERE selection_id = NEW.selection_id;
        IF selection_row.connector_id IS NULL
           OR NEW.source_registry_version_id <> selection_row.source_registry_version_id
           OR NEW.entitlement_version_id <> selection_row.entitlement_version_id THEN
            RAISE EXCEPTION 'EOD observation connector provenance does not match its vendor selection'
                USING ERRCODE = '55000';
        END IF;
        NEW.connector_id := selection_row.connector_id;
        NEW.contract_version_id := selection_row.contract_version_id;
    ELSIF TG_TABLE_NAME = 'earnings_estimate_observation' THEN
        connector_row := require_bound_source_connector(NEW.source_registry_version_id, 'earnings_consensus');
        NEW.connector_id := connector_row.connector_id;
        NEW.contract_version_id := connector_row.contract_version_id;
    ELSIF TG_TABLE_NAME = 'earnings_actual_reconciliation' THEN
        SELECT * INTO estimate_row FROM earnings_estimate_observation WHERE estimate_id = NEW.estimate_id;
        SELECT * INTO actual_row FROM edgar_xbrl_actual WHERE actual_id = NEW.edgar_actual_id;
        SELECT * INTO filing_row FROM edgar_filing WHERE filing_id = actual_row.filing_id;
        IF estimate_row.connector_id IS NULL OR filing_row.connector_id IS NULL THEN
            RAISE EXCEPTION 'earnings reconciliation source connector provenance is incomplete'
                USING ERRCODE = '55000';
        END IF;
        NEW.estimate_connector_id := estimate_row.connector_id;
        NEW.estimate_contract_version_id := estimate_row.contract_version_id;
        NEW.edgar_connector_id := filing_row.connector_id;
        NEW.edgar_contract_version_id := filing_row.contract_version_id;
    ELSIF TG_TABLE_NAME IN ('option_chain_snapshot', 'option_deliverable_version', 'option_chain_contract') THEN
        IF TG_TABLE_NAME = 'option_chain_contract' THEN
            SELECT * INTO snapshot_row FROM option_chain_snapshot WHERE snapshot_id = NEW.snapshot_id;
            IF snapshot_row.connector_id IS NULL THEN
                RAISE EXCEPTION 'option contract snapshot connector provenance is incomplete'
                    USING ERRCODE = '55000';
            END IF;
            NEW.connector_id := snapshot_row.connector_id;
            NEW.contract_version_id := snapshot_row.contract_version_id;
        ELSE
            connector_row := require_bound_source_connector(NEW.source_registry_version_id, 'historical_options');
            NEW.connector_id := connector_row.connector_id;
            NEW.contract_version_id := connector_row.contract_version_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER edgar_filing_connector_provenance
BEFORE INSERT ON edgar_filing
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER edgar_xbrl_connector_provenance
BEFORE INSERT ON edgar_xbrl_actual
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER eod_vendor_connector_provenance
BEFORE INSERT ON eod_vendor_selection
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER eod_price_connector_provenance
BEFORE INSERT ON eod_price_observation
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER eod_corporate_action_connector_provenance
BEFORE INSERT ON eod_corporate_action_observation
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER earnings_estimate_connector_provenance
BEFORE INSERT ON earnings_estimate_observation
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER earnings_reconciliation_connector_provenance
BEFORE INSERT ON earnings_actual_reconciliation
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER option_snapshot_connector_provenance
BEFORE INSERT ON option_chain_snapshot
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER option_deliverable_connector_provenance
BEFORE INSERT ON option_deliverable_version
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();
CREATE TRIGGER option_contract_connector_provenance
BEFORE INSERT ON option_chain_contract
FOR EACH ROW EXECUTE FUNCTION populate_ingestion_connector_provenance();

ALTER TABLE edgar_filing ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE edgar_filing ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE edgar_xbrl_actual ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE edgar_xbrl_actual ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE eod_vendor_selection ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE eod_vendor_selection ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE eod_price_observation ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE eod_price_observation ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE eod_corporate_action_observation ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE eod_corporate_action_observation ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE earnings_estimate_observation ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE earnings_estimate_observation ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE earnings_actual_reconciliation ALTER COLUMN estimate_connector_id SET NOT NULL;
ALTER TABLE earnings_actual_reconciliation ALTER COLUMN estimate_contract_version_id SET NOT NULL;
ALTER TABLE earnings_actual_reconciliation ALTER COLUMN edgar_connector_id SET NOT NULL;
ALTER TABLE earnings_actual_reconciliation ALTER COLUMN edgar_contract_version_id SET NOT NULL;
ALTER TABLE option_chain_snapshot ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE option_chain_snapshot ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE option_deliverable_version ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE option_deliverable_version ALTER COLUMN contract_version_id SET NOT NULL;
ALTER TABLE option_chain_contract ALTER COLUMN connector_id SET NOT NULL;
ALTER TABLE option_chain_contract ALTER COLUMN contract_version_id SET NOT NULL;

CREATE OR REPLACE FUNCTION eod_price_observation_at(
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

CREATE FUNCTION validate_earnings_reconciliation_units() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    estimate_row earnings_estimate_observation%ROWTYPE;
    actual_row edgar_xbrl_actual%ROWTYPE;
BEGIN
    SELECT * INTO estimate_row FROM earnings_estimate_observation WHERE estimate_id = NEW.estimate_id;
    SELECT * INTO actual_row FROM edgar_xbrl_actual WHERE actual_id = NEW.edgar_actual_id;
    IF estimate_row.currency IS NULL OR btrim(estimate_row.currency) = ''
       OR upper(btrim(actual_row.unit)) <> upper(btrim(estimate_row.unit))
       OR upper(split_part(btrim(estimate_row.unit), '_', 1)) <> upper(btrim(estimate_row.currency)) THEN
        RAISE EXCEPTION
            'earnings reconciliation unit/currency is incompatible with the estimate'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER earnings_reconciliation_units_guard
BEFORE INSERT ON earnings_actual_reconciliation
FOR EACH ROW EXECUTE FUNCTION validate_earnings_reconciliation_units();

CREATE FUNCTION guard_research_evidence_proof_artifact_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' OR current_setting('market_mate.proof_artifact_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'proof artifacts must be recorded through record_research_evidence_proof_artifact'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.verification_state = 'verified'
       AND current_setting('market_mate.proof_artifact_verify_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'verified proof artifacts require the verifier workflow'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_proof_artifact_insert_guard
BEFORE INSERT ON research_evidence_proof_artifact
FOR EACH ROW EXECUTE FUNCTION guard_research_evidence_proof_artifact_insert();

CREATE FUNCTION record_research_evidence_proof_artifact(
    artifact_ref_value text,
    artifact_body_value jsonb,
    verification_state_value text,
    verification_result_value jsonb,
    source_lineage_value jsonb
) RETURNS research_evidence_proof_artifact
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created research_evidence_proof_artifact%ROWTYPE;
BEGIN
    IF verification_state_value NOT IN ('verified', 'pending', 'invalidated') THEN
        RAISE EXCEPTION 'proof artifact verification state is invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'proof artifact source_lineage is invalid' USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('market_mate.proof_artifact_write', 'on', true);
    IF verification_state_value = 'verified' THEN
        PERFORM set_config('market_mate.proof_artifact_verify_write', 'on', true);
    END IF;
    BEGIN
        INSERT INTO research_evidence_proof_artifact (
            artifact_ref, artifact_body, artifact_digest, verification_state,
            verification_result, source_lineage, receipt_time, record_environment
        ) VALUES (
            artifact_ref_value, artifact_body_value,
            encode(digest(artifact_body_value::text, 'sha256'), 'hex'),
            verification_state_value, verification_result_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.proof_artifact_verify_write', 'off', true);
            PERFORM set_config('market_mate.proof_artifact_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.proof_artifact_verify_write', 'off', true);
    PERFORM set_config('market_mate.proof_artifact_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION guard_research_evidence_contract_rule_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' OR current_setting('market_mate.evidence_contract_rule_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'evidence contract rules must be recorded through record_research_evidence_contract_rule'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_contract_rule_insert_guard
BEFORE INSERT ON research_evidence_contract_rule
FOR EACH ROW EXECUTE FUNCTION guard_research_evidence_contract_rule_insert();

CREATE FUNCTION record_research_evidence_contract_rule(
    rule_key_value text,
    description_value text,
    proof_expression_value jsonb,
    proof_status_value text,
    proof_artifact_ref_value text,
    proof_artifact_digest_value text,
    source_lineage_value jsonb
) RETURNS research_evidence_contract_rule
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created research_evidence_contract_rule%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'evidence contract rule source_lineage is invalid' USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('market_mate.evidence_contract_rule_write', 'on', true);
    BEGIN
        INSERT INTO research_evidence_contract_rule (
            rule_key, description, proof_expression, proof_status,
            proof_artifact_ref, proof_artifact_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            rule_key_value, description_value, proof_expression_value, proof_status_value,
            proof_artifact_ref_value, proof_artifact_digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.evidence_contract_rule_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.evidence_contract_rule_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION guard_research_cycle_manifest_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT'
       OR current_setting('market_mate.research_cycle_manifest_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'research cycle manifests must be recorded through a publication workflow'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cycle_manifest_insert_guard
BEFORE INSERT ON research_cycle_manifest
FOR EACH ROW EXECUTE FUNCTION guard_research_cycle_manifest_insert();

CREATE FUNCTION guard_research_cycle_manifest_entry_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT'
       OR current_setting('market_mate.research_cycle_manifest_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'research cycle manifest entries must be recorded through a publication workflow'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_cycle_manifest_entry_insert_guard
BEFORE INSERT ON research_cycle_manifest_entry
FOR EACH ROW EXECUTE FUNCTION guard_research_cycle_manifest_entry_insert();

CREATE FUNCTION record_research_cycle_manifest(
    cycle_key_value text,
    cycle_kind_value text,
    cycle_as_of_value timestamptz,
    expected_snapshot_count_value integer,
    completed_snapshot_count_value integer,
    completion_state_value text,
    evidence_state_value text,
    stale_from_value timestamptz,
    stale_to_value timestamptz,
    supersedes_manifest_id_value uuid,
    superseding_delta_value jsonb,
    entries_value jsonb,
    source_lineage_value jsonb
) RETURNS research_cycle_manifest
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    created research_cycle_manifest%ROWTYPE;
    item jsonb;
BEGIN
    IF jsonb_typeof(entries_value) IS DISTINCT FROM 'array'
       OR jsonb_array_length(entries_value) <> expected_snapshot_count_value
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'research cycle manifest entries or lineage are invalid' USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('market_mate.research_cycle_manifest_write', 'on', true);
    BEGIN
        INSERT INTO research_cycle_manifest (
            cycle_key, cycle_kind, cycle_as_of, expected_snapshot_count,
            completed_snapshot_count, completion_state, evidence_state,
            stale_from, stale_to, supersedes_manifest_id, superseding_delta,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            cycle_key_value, cycle_kind_value, cycle_as_of_value,
            expected_snapshot_count_value, completed_snapshot_count_value,
            completion_state_value, evidence_state_value, stale_from_value,
            stale_to_value, supersedes_manifest_id_value, superseding_delta_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        ) RETURNING * INTO created;

        FOR item IN SELECT value FROM jsonb_array_elements(entries_value) LOOP
            INSERT INTO research_cycle_manifest_entry (
                manifest_id, snapshot_key, expected, snapshot_id,
                completion_state, evidence_state, stale_from, stale_to,
                supersedes_entry_id, source_lineage, receipt_time, record_environment
            ) VALUES (
                created.manifest_id, item->>'snapshot_key', coalesce((item->>'expected')::boolean, true),
                NULLIF(item->>'snapshot_id', '')::uuid,
                item->>'completion_state', item->>'evidence_state',
                NULLIF(item->>'stale_from', '')::timestamptz,
                NULLIF(item->>'stale_to', '')::timestamptz,
                NULLIF(item->>'supersedes_entry_id', '')::uuid,
                source_lineage_value, clock_timestamp(), 'local_research'
            );
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.research_cycle_manifest_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.research_cycle_manifest_write', 'off', true);
    RETURN created;
END;
$$;

CREATE FUNCTION validate_post_close_snapshot_timing() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM research_cycle_manifest_entry e
        JOIN research_snapshot s ON s.snapshot_id = e.snapshot_id
        WHERE e.manifest_id = NEW.manifest_id
          AND e.completion_state = 'complete'
          AND s.receipt_time > NEW.published_at
    ) THEN
        RAISE EXCEPTION 'post-close cycle cannot publish before its snapshot evidence was received'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER post_close_snapshot_timing_guard
BEFORE INSERT ON research_post_close_cycle
FOR EACH ROW EXECUTE FUNCTION validate_post_close_snapshot_timing();

CREATE UNIQUE INDEX research_event_delta_cycle_earnings_source_unique
    ON research_event_delta_cycle (source_earnings_estimate_id)
    WHERE source_earnings_estimate_id IS NOT NULL;
CREATE UNIQUE INDEX research_event_delta_cycle_edgar_source_unique
    ON research_event_delta_cycle (source_edgar_filing_id)
    WHERE source_edgar_filing_id IS NOT NULL;

CREATE FUNCTION validate_event_delta_cycle_lineage() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    parent_cycle research_post_close_cycle%ROWTYPE;
    source_receipt_time timestamptz;
BEGIN
    SELECT * INTO parent_cycle
    FROM research_post_close_cycle
    WHERE cycle_id = NEW.parent_cycle_id;
    IF parent_cycle.publication_state <> 'complete' OR NOT parent_cycle.authoritative THEN
        RAISE EXCEPTION 'event delta cycle requires an authoritative complete post-close parent'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.event_kind = 'earnings_announcement' THEN
        SELECT receipt_time INTO source_receipt_time
        FROM earnings_estimate_observation
        WHERE estimate_id = NEW.source_earnings_estimate_id;
    ELSE
        SELECT receipt_time INTO source_receipt_time
        FROM edgar_filing
        WHERE filing_id = NEW.source_edgar_filing_id;
    END IF;
    IF source_receipt_time IS NULL OR source_receipt_time > NEW.detected_at THEN
        RAISE EXCEPTION 'event delta cycle cannot publish before its source was received'
            USING ERRCODE = '55000';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM research_cycle_manifest_entry e
        JOIN research_snapshot s ON s.snapshot_id = e.snapshot_id
        WHERE e.manifest_id = NEW.manifest_id
          AND e.completion_state = 'complete'
          AND s.receipt_time > NEW.detected_at
    ) THEN
        RAISE EXCEPTION 'event delta cycle cannot publish before its snapshot evidence was received'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER event_delta_cycle_lineage_guard
BEFORE INSERT ON research_event_delta_cycle
FOR EACH ROW EXECUTE FUNCTION validate_event_delta_cycle_lineage();

CREATE FUNCTION validate_research_evidence_delta_timing() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NEW.as_of_at > NEW.receipt_time OR NEW.as_of_at > clock_timestamp() THEN
        RAISE EXCEPTION 'Research Evidence Delta as_of_at cannot be in the future'
            USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_delta_timing_guard
BEFORE INSERT ON research_evidence_delta
FOR EACH ROW EXECUTE FUNCTION validate_research_evidence_delta_timing();

SELECT assert_all_evidence_table_conventions();
