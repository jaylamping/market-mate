-- Signed checkpoint receipts for the Local Research audit-event chain.
-- A receipt binds the chain head (position + digest) to a custody-signed
-- time. The signature lives with the custody service and its volume; this
-- table mirrors receipts inside the database so they can be replayed
-- against a restored chain during restore verification.

CREATE TABLE audit_checkpoint (
    checkpoint_index bigint PRIMARY KEY CHECK (checkpoint_index > 0),
    chain_position bigint NOT NULL CHECK (chain_position > 0),
    chain_digest text NOT NULL CHECK (chain_digest ~ '^[0-9a-f]{64}$'),
    checkpoint_time timestamptz NOT NULL,
    signature text NOT NULL CHECK (signature ~ '^[0-9a-f]{128}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('audit_checkpoint');

CREATE FUNCTION current_chain_digest() RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM audit_event) THEN NULL
        ELSE encode(
            digest(
                convert_to(
                    concat_ws(
                        '|',
                        'market-mate-checkpoint-digest-v1',
                        (
                            SELECT chain_position::text
                            FROM audit_event
                            ORDER BY chain_position DESC
                            LIMIT 1
                        ),
                        (
                            SELECT event_hash
                            FROM audit_event
                            ORDER BY chain_position DESC
                            LIMIT 1
                        )
                    ),
                    'UTF8'
                ),
                'sha256'
            ),
            'hex'
        )
    END;
$$;

CREATE FUNCTION chain_digest_at(position_value bigint) RETURNS text
LANGUAGE sql
STABLE
STRICT
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(
            convert_to(
                concat_ws(
                    '|',
                    'market-mate-checkpoint-digest-v1',
                    position_value::text,
                    (
                        SELECT event_hash
                        FROM audit_event
                        WHERE chain_position = position_value
                    )
                ),
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    );
$$;

SELECT assert_all_evidence_table_conventions();
