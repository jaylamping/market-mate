-- Versioned Research Evidence Profiles and typed obligations. Profiles remain
-- distinct for universal, options, holding, and portfolio evidence. A Not
-- Applicable obligation must name a proved contract rule; no default value
-- can stand in for absent evidence.

CREATE TABLE research_evidence_proof_artifact (
    proof_artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_ref text NOT NULL UNIQUE CHECK (btrim(artifact_ref) <> ''),
    artifact_body jsonb NOT NULL CHECK (
        jsonb_typeof(artifact_body) = 'object'
        AND jsonb_typeof(artifact_body -> 'proof_expression') = 'object'
    ),
    artifact_digest text NOT NULL CHECK (artifact_digest ~ '^[0-9a-f]{64}$'),
    verification_state text NOT NULL CHECK (verification_state IN ('verified', 'pending', 'invalidated')),
    verification_result jsonb NOT NULL CHECK (jsonb_typeof(verification_result) = 'object'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (artifact_digest = encode(digest(artifact_body::text, 'sha256'), 'hex')),
    UNIQUE (artifact_ref, artifact_digest)
);

SELECT register_evidence_table('research_evidence_proof_artifact');

CREATE TABLE research_evidence_contract_rule (
    rule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    rule_key text NOT NULL UNIQUE CHECK (btrim(rule_key) <> ''),
    description text NOT NULL CHECK (btrim(description) <> ''),
    proof_expression jsonb NOT NULL CHECK (jsonb_typeof(proof_expression) = 'object'),
    proof_status text NOT NULL CHECK (proof_status IN ('proved', 'pending', 'invalidated')),
    proof_artifact_ref text NOT NULL CHECK (btrim(proof_artifact_ref) <> ''),
    proof_artifact_digest text NOT NULL CHECK (proof_artifact_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    FOREIGN KEY (proof_artifact_ref, proof_artifact_digest)
        REFERENCES research_evidence_proof_artifact (artifact_ref, artifact_digest)
);

SELECT register_evidence_table('research_evidence_contract_rule');

CREATE FUNCTION validate_research_evidence_contract_rule_artifact() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    artifact_body_value jsonb;
BEGIN
    SELECT artifact_body
    INTO artifact_body_value
    FROM research_evidence_proof_artifact
    WHERE artifact_ref = NEW.proof_artifact_ref
      AND artifact_digest = NEW.proof_artifact_digest;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'research evidence contract rule proof artifact is not registered'
            USING ERRCODE = '23503';
    END IF;
    IF artifact_body_value -> 'proof_expression' IS DISTINCT FROM NEW.proof_expression THEN
        RAISE EXCEPTION
            'research evidence contract rule proof expression does not match its proof artifact'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_contract_rule_artifact_guard
BEFORE INSERT OR UPDATE ON research_evidence_contract_rule
FOR EACH ROW EXECUTE FUNCTION validate_research_evidence_contract_rule_artifact();

CREATE TRIGGER research_evidence_proof_artifact_mutation_guard
BEFORE UPDATE OR DELETE ON research_evidence_proof_artifact
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_proof_artifact_truncate_guard
BEFORE TRUNCATE ON research_evidence_proof_artifact
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TABLE research_evidence_profile_version (
    profile_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_key text NOT NULL UNIQUE CHECK (btrim(profile_key) <> ''),
    profile_kind text NOT NULL CHECK (profile_kind IN ('universal', 'options', 'holding', 'portfolio')),
    version integer NOT NULL CHECK (version >= 1),
    definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    effective_from timestamptz NOT NULL,
    effective_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    UNIQUE (profile_kind, version)
);

SELECT register_evidence_table('research_evidence_profile_version');

CREATE TABLE research_evidence_obligation (
    obligation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_version_id uuid NOT NULL REFERENCES research_evidence_profile_version(profile_version_id),
    obligation_key text NOT NULL CHECK (btrim(obligation_key) <> ''),
    evidence_family text NOT NULL CHECK (btrim(evidence_family) <> ''),
    description text NOT NULL CHECK (btrim(description) <> ''),
    applicability text NOT NULL CHECK (applicability IN ('mandatory', 'conditional', 'not_applicable')),
    required_observation_states jsonb NOT NULL CHECK (jsonb_typeof(required_observation_states) = 'array'),
    not_applicable_rule_id uuid REFERENCES research_evidence_contract_rule(rule_id),
    default_substitute jsonb,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CONSTRAINT not_applicable_requires_proof CHECK (
        applicability <> 'not_applicable' OR not_applicable_rule_id IS NOT NULL
    ),
    CONSTRAINT non_na_obligation_has_states CHECK (
        applicability = 'not_applicable' OR jsonb_array_length(required_observation_states) > 0
    ),
    CONSTRAINT evidence_obligation_no_default_substitution CHECK (default_substitute IS NULL),
    UNIQUE (profile_version_id, obligation_key)
);

SELECT register_evidence_table('research_evidence_obligation');

CREATE INDEX research_evidence_obligation_profile_idx
    ON research_evidence_obligation (profile_version_id, applicability, evidence_family);

CREATE TABLE research_evidence_profile_route (
    route_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    coverage_stage text NOT NULL CHECK (
        coverage_stage IN ('research_candidate', 'trade_eligible', 'mandatory_holding', 'exit_monitoring')
    ),
    coverage_capability text NOT NULL CHECK (
        coverage_capability IN ('stock_eligible', 'options_eligible', 'both', 'none')
    ),
    decision_purpose text NOT NULL CHECK (
        decision_purpose IN ('research', 'new_exposure', 'holding_management', 'portfolio_review', 'risk_reduction', 'reconciliation')
    ),
    profile_version_id uuid NOT NULL REFERENCES research_evidence_profile_version(profile_version_id),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    UNIQUE (coverage_stage, coverage_capability, decision_purpose, valid_from)
);

SELECT register_evidence_table('research_evidence_profile_route');

CREATE INDEX research_evidence_profile_route_lookup_idx
    ON research_evidence_profile_route (coverage_stage, coverage_capability, decision_purpose, valid_from);

CREATE TABLE research_evidence_profile_resolution (
    resolution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    coverage_stage text NOT NULL CHECK (
        coverage_stage IN ('research_candidate', 'trade_eligible', 'mandatory_holding', 'exit_monitoring')
    ),
    coverage_capability text NOT NULL CHECK (
        coverage_capability IN ('stock_eligible', 'options_eligible', 'both', 'none')
    ),
    decision_purpose text NOT NULL CHECK (
        decision_purpose IN ('research', 'new_exposure', 'holding_management', 'portfolio_review', 'risk_reduction', 'reconciliation')
    ),
    as_of_at timestamptz NOT NULL,
    profile_version_id uuid NOT NULL REFERENCES research_evidence_profile_version(profile_version_id),
    profile_kind text NOT NULL CHECK (profile_kind IN ('universal', 'options', 'holding', 'portfolio')),
    obligation_count integer NOT NULL CHECK (obligation_count > 0),
    obligations jsonb NOT NULL CHECK (jsonb_typeof(obligations) = 'array'),
    resolved_at timestamptz NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('research_evidence_profile_resolution');

CREATE INDEX research_evidence_profile_resolution_lookup_idx
    ON research_evidence_profile_resolution (coverage_stage, coverage_capability, decision_purpose, as_of_at);

CREATE TRIGGER research_evidence_contract_rule_mutation_guard
BEFORE UPDATE OR DELETE ON research_evidence_contract_rule
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_contract_rule_truncate_guard
BEFORE TRUNCATE ON research_evidence_contract_rule
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_profile_version_mutation_guard
BEFORE UPDATE OR DELETE ON research_evidence_profile_version
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_profile_version_truncate_guard
BEFORE TRUNCATE ON research_evidence_profile_version
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_obligation_mutation_guard
BEFORE UPDATE OR DELETE ON research_evidence_obligation
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_obligation_truncate_guard
BEFORE TRUNCATE ON research_evidence_obligation
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_profile_route_mutation_guard
BEFORE UPDATE OR DELETE ON research_evidence_profile_route
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER research_evidence_profile_route_truncate_guard
BEFORE TRUNCATE ON research_evidence_profile_route
FOR EACH STATEMENT EXECUTE FUNCTION guard_append_only_evidence();

CREATE FUNCTION guard_research_evidence_profile_resolution_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_evidence_profile_resolution is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    IF current_setting('market_mate.evidence_profile_resolution_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION
            'evidence profile resolutions must be recorded through resolve_research_evidence_profile'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_evidence_profile_resolution_write_guard
BEFORE INSERT OR UPDATE OR DELETE ON research_evidence_profile_resolution
FOR EACH ROW EXECUTE FUNCTION guard_research_evidence_profile_resolution_write();

CREATE TRIGGER research_evidence_profile_resolution_truncate_guard
BEFORE TRUNCATE ON research_evidence_profile_resolution
FOR EACH STATEMENT EXECUTE FUNCTION guard_research_evidence_profile_resolution_write();

-- The first proved rule is deliberately narrow: stock-only coverage does not
-- require options structure evidence, but this exemption cannot be inferred
-- from a missing row or a default state.
INSERT INTO research_evidence_proof_artifact (
    artifact_ref, artifact_body, artifact_digest, verification_state,
    verification_result, source_lineage, receipt_time, record_environment
) VALUES (
    'migration:0018:wu18_stock_options_contract_v1',
    '{"assertions":{"stock_only_options_not_applicable":true,"no_default_substitute":true},"proof_expression":{"when":{"coverage_capability":"stock_eligible"},"then":{"options_structure":"not_applicable"},"test":"wu18_stock_options_contract_v1"}}'::jsonb,
    encode(digest(
        '{"assertions":{"stock_only_options_not_applicable":true,"no_default_substitute":true},"proof_expression":{"when":{"coverage_capability":"stock_eligible"},"then":{"options_structure":"not_applicable"},"test":"wu18_stock_options_contract_v1"}}'::jsonb::text,
        'sha256'
    ), 'hex'),
    'verified',
    '{"status":"verified","method":"migration_fixture_contract_probe"}'::jsonb,
    '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
    clock_timestamp(), 'local_research'
);

INSERT INTO research_evidence_contract_rule (
    rule_key, description, proof_expression, proof_status,
    proof_artifact_ref, proof_artifact_digest,
    source_lineage, receipt_time, record_environment
) VALUES (
    'stock-coverage-options-not-applicable-v1',
    'Options structure is Not Applicable only for stock-only coverage.',
    '{"when":{"coverage_capability":"stock_eligible"},"then":{"options_structure":"not_applicable"},"test":"wu18_stock_options_contract_v1"}'::jsonb,
    'proved',
    'migration:0018:wu18_stock_options_contract_v1',
    (SELECT artifact_digest
     FROM research_evidence_proof_artifact
     WHERE artifact_ref = 'migration:0018:wu18_stock_options_contract_v1'),
    '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
    clock_timestamp(), 'local_research'
);

INSERT INTO research_evidence_profile_version (
    profile_key, profile_kind, version, definition,
    effective_from, effective_to, source_lineage, receipt_time, record_environment
) VALUES
    (
        'universal-v1', 'universal', 1,
        '{"scope":"security","families":["identity","price_volume","fundamentals","options_structure"]}'::jsonb,
        '2026-01-01T00:00:00Z', NULL,
        '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
        clock_timestamp(), 'local_research'
    ),
    (
        'options-v1', 'options', 1,
        '{"scope":"options","families":["options_structure","deliverable_terms"]}'::jsonb,
        '2026-01-01T00:00:00Z', NULL,
        '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
        clock_timestamp(), 'local_research'
    ),
    (
        'holding-v1', 'holding', 1,
        '{"scope":"holding","families":["custody_state","lifecycle"]}'::jsonb,
        '2026-01-01T00:00:00Z', NULL,
        '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
        clock_timestamp(), 'local_research'
    ),
    (
        'portfolio-v1', 'portfolio', 1,
        '{"scope":"portfolio","families":["portfolio_exposure","regime"]}'::jsonb,
        '2026-01-01T00:00:00Z', NULL,
        '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
        clock_timestamp(), 'local_research'
    );

INSERT INTO research_evidence_obligation (
    profile_version_id, obligation_key, evidence_family, description,
    applicability, required_observation_states, not_applicable_rule_id,
    default_substitute, source_lineage, receipt_time, record_environment
)
SELECT p.profile_version_id, o.obligation_key, o.evidence_family, o.description,
       o.applicability, o.required_observation_states,
       CASE WHEN o.obligation_key = 'options_structure' THEN r.rule_id END,
       NULL,
       '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
       clock_timestamp(), 'local_research'
FROM (
    VALUES
        ('universal-v1', 'security_identity', 'identity', 'Certified security identity and corporate-action state.', 'mandatory', '["current"]'::jsonb),
        ('universal-v1', 'price_volume', 'price_volume', 'Point-in-time price and volume evidence.', 'mandatory', '["current"]'::jsonb),
        ('universal-v1', 'fundamental_quality', 'fundamentals', 'Fundamental evidence with explicit observation quality.', 'conditional', '["current"]'::jsonb),
        ('universal-v1', 'options_structure', 'options_structure', 'Options structure evidence is not applicable to stock-only coverage.', 'not_applicable', '[]'::jsonb),
        ('options-v1', 'options_chain', 'options_structure', 'Historical options chain and contract evidence.', 'mandatory', '["current"]'::jsonb),
        ('options-v1', 'deliverable_terms', 'deliverable_terms', 'Immutable option deliverable and settlement terms.', 'mandatory', '["current"]'::jsonb),
        ('holding-v1', 'custody_state', 'custody_state', 'Broker-reconciled custody and settlement evidence.', 'mandatory', '["current"]'::jsonb),
        ('holding-v1', 'lifecycle_obligations', 'lifecycle', 'Exercise, assignment, expiry, and corporate-action lifecycle evidence.', 'mandatory', '["current"]'::jsonb),
        ('portfolio-v1', 'portfolio_exposure', 'portfolio_exposure', 'Current portfolio exposure and dependency evidence.', 'mandatory', '["current"]'::jsonb),
        ('portfolio-v1', 'regime_distribution', 'regime', 'Portfolio-level regime distribution and uncertainty.', 'conditional', '["current"]'::jsonb)
) AS o(profile_key, obligation_key, evidence_family, description, applicability, required_observation_states)
JOIN research_evidence_profile_version p ON p.profile_key = o.profile_key
LEFT JOIN research_evidence_contract_rule r
  ON r.rule_key = 'stock-coverage-options-not-applicable-v1';

INSERT INTO research_evidence_profile_route (
    coverage_stage, coverage_capability, decision_purpose,
    profile_version_id, valid_from, valid_to,
    source_lineage, receipt_time, record_environment
)
SELECT r.coverage_stage, r.coverage_capability, r.decision_purpose,
       p.profile_version_id, '2026-01-01T00:00:00Z', NULL,
       '{"source":"wu18-migration","entitlement_version":"evidence-profile-v1"}'::jsonb,
       clock_timestamp(), 'local_research'
FROM (
    VALUES
        ('research_candidate', 'stock_eligible', 'research', 'universal-v1'),
        ('trade_eligible', 'options_eligible', 'new_exposure', 'options-v1'),
        ('mandatory_holding', 'options_eligible', 'holding_management', 'holding-v1'),
        ('trade_eligible', 'both', 'portfolio_review', 'portfolio-v1')
) AS r(coverage_stage, coverage_capability, decision_purpose, profile_key)
JOIN research_evidence_profile_version p ON p.profile_key = r.profile_key;

CREATE FUNCTION resolve_research_evidence_profile(
    coverage_stage_value text,
    coverage_capability_value text,
    decision_purpose_value text,
    as_of_value timestamptz,
    source_lineage_value jsonb
) RETURNS research_evidence_profile_resolution
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    route_row research_evidence_profile_route%ROWTYPE;
    profile_row research_evidence_profile_version%ROWTYPE;
    created research_evidence_profile_resolution%ROWTYPE;
    obligation_count_value integer;
    obligations_value jsonb;
    resolution_time timestamptz := clock_timestamp();
BEGIN
    IF coverage_stage_value NOT IN ('research_candidate', 'trade_eligible', 'mandatory_holding', 'exit_monitoring')
       OR coverage_capability_value NOT IN ('stock_eligible', 'options_eligible', 'both', 'none')
       OR decision_purpose_value NOT IN ('research', 'new_exposure', 'holding_management', 'portfolio_review', 'risk_reduction', 'reconciliation')
       OR as_of_value IS NULL THEN
        RAISE EXCEPTION 'evidence profile resolution inputs are invalid' USING ERRCODE = '22023';
    END IF;
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'evidence profile resolution source_lineage is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT r.*
    INTO route_row
    FROM research_evidence_profile_route r
    WHERE r.coverage_stage = coverage_stage_value
      AND r.coverage_capability = coverage_capability_value
      AND r.decision_purpose = decision_purpose_value
      AND r.valid_from <= as_of_value
      AND (r.valid_to IS NULL OR as_of_value < r.valid_to)
    ORDER BY r.valid_from DESC
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'no typed research evidence profile route exists for %, %, %',
            coverage_stage_value, coverage_capability_value, decision_purpose_value
            USING ERRCODE = '55000';
    END IF;

    SELECT p.*
    INTO profile_row
    FROM research_evidence_profile_version p
    WHERE p.profile_version_id = route_row.profile_version_id
      AND p.effective_from <= as_of_value
      AND (p.effective_to IS NULL OR as_of_value < p.effective_to);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'resolved evidence profile version is not effective at the requested time'
            USING ERRCODE = '55000';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM research_evidence_obligation o
        LEFT JOIN research_evidence_contract_rule r ON r.rule_id = o.not_applicable_rule_id
        LEFT JOIN research_evidence_proof_artifact a
          ON a.artifact_ref = r.proof_artifact_ref
         AND a.artifact_digest = r.proof_artifact_digest
        WHERE o.profile_version_id = profile_row.profile_version_id
          AND o.applicability = 'not_applicable'
          AND (
              r.rule_id IS NULL
              OR r.proof_status <> 'proved'
              OR a.proof_artifact_id IS NULL
              OR a.verification_state <> 'verified'
              OR a.artifact_body -> 'proof_expression' IS DISTINCT FROM r.proof_expression
          )
    ) THEN
        RAISE EXCEPTION 'Not Applicable evidence obligation lacks a proved contract rule'
            USING ERRCODE = '55000';
    END IF;

    SELECT count(*)::integer,
           jsonb_agg(
               jsonb_build_object(
                   'obligation_key', o.obligation_key,
                   'evidence_family', o.evidence_family,
                   'description', o.description,
                   'applicability', o.applicability,
                   'required_observation_states', o.required_observation_states,
                   'not_applicable_rule', CASE
                       WHEN r.rule_id IS NULL THEN NULL
                       ELSE jsonb_build_object(
                           'rule_key', r.rule_key,
                           'proof_status', r.proof_status,
                           'proof_artifact_ref', r.proof_artifact_ref,
                           'verification_state', a.verification_state,
                           'proof_artifact_digest', r.proof_artifact_digest
                       )
                   END
               ) ORDER BY o.obligation_key
           )
    INTO obligation_count_value, obligations_value
    FROM research_evidence_obligation o
    LEFT JOIN research_evidence_contract_rule r ON r.rule_id = o.not_applicable_rule_id
    LEFT JOIN research_evidence_proof_artifact a
      ON a.artifact_ref = r.proof_artifact_ref
     AND a.artifact_digest = r.proof_artifact_digest
    WHERE o.profile_version_id = profile_row.profile_version_id;

    PERFORM set_config('market_mate.evidence_profile_resolution_write', 'on', true);
    BEGIN
        INSERT INTO research_evidence_profile_resolution (
            coverage_stage, coverage_capability, decision_purpose, as_of_at,
            profile_version_id, profile_kind, obligation_count, obligations,
            resolved_at, source_lineage, receipt_time, record_environment
        ) VALUES (
            coverage_stage_value, coverage_capability_value, decision_purpose_value, as_of_value,
            profile_row.profile_version_id, profile_row.profile_kind, obligation_count_value,
            coalesce(obligations_value, '[]'::jsonb), resolution_time,
            source_lineage_value, resolution_time, 'local_research'
        ) RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.evidence_profile_resolution_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.evidence_profile_resolution_write', 'off', true);
    RETURN created;
END;
$$;

SELECT assert_all_evidence_table_conventions();
