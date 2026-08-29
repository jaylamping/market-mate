-- WU-07 security-master fixture set. Applied inside a caller-managed
-- transaction; the acceptance script asserts on it and rolls it back.
--
-- Scenario:
--   * Acme Corp: NYSE listing 1990-2022, identity-continuous symbol change
--     ACME -> ACMX at 2020, represented strictly as two time-bounded aliases
--     on the same listing.
--   * Beta Inc: NYSE listing from 2023 reusing the symbol ACME — alias
--     history records the reuse while both listings keep distinct identities.

DO $$ BEGIN PERFORM set_config('market_mate.security_master_write', 'on', true); END $$;

INSERT INTO issuer (issuer_id, legal_name, source_lineage, receipt_time, record_environment)
VALUES ('11111111-1111-1111-1111-111111111111', 'Acme Corporation',
        '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
       ('22222222-2222-2222-2222-222222222222', 'Beta Incorporated',
        '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research');

INSERT INTO security (security_id, issuer_id, security_class, source_lineage, receipt_time, record_environment)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'common_stock',
        '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
       ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'common_stock',
        '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research');

INSERT INTO exchange_listing (
    listing_id, security_id, venue, currency, listing_status,
    valid_from, valid_to, source_lineage, receipt_time, record_environment
)
VALUES
    ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'NYSE', 'USD', 'delisted',
     '1990-01-02T00:00:00Z', '2022-12-30T00:00:00Z',
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
    ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'NYSE', 'USD', 'active',
     '2023-01-03T00:00:00Z', NULL,
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research');

INSERT INTO listing_symbol_alias (
    alias_id, listing_id, symbol, source,
    valid_from, valid_to, source_lineage, receipt_time, record_environment
)
VALUES
    ('eeeeeeee-0000-0000-0000-000000000001', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'ACME', 'wu07-fixture-source',
     '1990-01-02T00:00:00Z', '2020-01-02T00:00:00Z',
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
    ('eeeeeeee-0000-0000-0000-000000000002', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'ACMX', 'wu07-fixture-source',
     '2020-01-02T00:00:00Z', NULL,
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
    ('eeeeeeee-0000-0000-0000-000000000003', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'ACME', 'wu07-fixture-source',
     '2023-01-03T00:00:00Z', NULL,
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research');

INSERT INTO security_symbol_alias (
    alias_id, security_id, symbol, source,
    valid_from, valid_to, source_lineage, receipt_time, record_environment
)
VALUES
    ('eeeeeeee-0000-0000-0000-000000000011', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ACME', 'wu07-fixture-source',
     '1990-01-02T00:00:00Z', '2020-01-02T00:00:00Z',
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
    ('eeeeeeee-0000-0000-0000-000000000012', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ACMX', 'wu07-fixture-source',
     '2020-01-02T00:00:00Z', NULL,
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research'),
    ('eeeeeeee-0000-0000-0000-000000000013', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'ACME', 'wu07-fixture-source',
     '2023-01-03T00:00:00Z', NULL,
     '{"source":"wu07-fixture","entitlement_version":"local-v1"}', '2026-01-01T00:00:00Z', 'local_research');
