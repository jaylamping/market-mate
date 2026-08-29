-- Tracer contracts: the real immutable snapshot store, preregistration, and
-- evaluation-result tables the WU-06 tracer slice exercises. The tracer's
-- fetch/evaluation internals are throwaway; these contracts are not.

CREATE TABLE research_snapshot (
    snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_kind text NOT NULL CHECK (btrim(snapshot_kind) <> ''),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    payload_digest text NOT NULL CHECK (payload_digest ~ '^[0-9a-f]{64}$'),
    supersedes_snapshot_id uuid REFERENCES research_snapshot(snapshot_id),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (payload_digest = encode(digest(payload::text, 'sha256'), 'hex'))
);

SELECT register_evidence_table('research_snapshot');

CREATE TABLE experiment_preregistration (
    registration_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_key text NOT NULL CHECK (btrim(experiment_key) <> ''),
    spec jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),
    spec_digest text NOT NULL CHECK (spec_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        spec_digest = encode(
            digest('market-mate-preregistration-v1|' || spec::text, 'sha256'),
            'hex'
        )
    )
);

SELECT register_evidence_table('experiment_preregistration');

CREATE TABLE evaluation_result (
    result_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id uuid NOT NULL REFERENCES experiment_preregistration(registration_id),
    snapshot_id uuid NOT NULL REFERENCES research_snapshot(snapshot_id),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (result_digest = encode(digest(result::text, 'sha256'), 'hex'))
);

SELECT register_evidence_table('evaluation_result');

CREATE FUNCTION guard_append_only_evidence() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER research_snapshot_mutation_guard
BEFORE UPDATE OR DELETE ON research_snapshot
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER experiment_preregistration_mutation_guard
BEFORE UPDATE OR DELETE ON experiment_preregistration
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

CREATE TRIGGER evaluation_result_mutation_guard
BEFORE UPDATE OR DELETE ON evaluation_result
FOR EACH ROW EXECUTE FUNCTION guard_append_only_evidence();

SELECT assert_all_evidence_table_conventions();
