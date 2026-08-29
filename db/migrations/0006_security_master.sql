-- Security Master: the versioned, provider-neutral authority relating Issuers,
-- Securities, Exchange Listings, and Symbol Aliases. No identifier (symbol,
-- vendor id) is ever a primary or unique key; identity lives in uuids and
-- symbol history is recorded as time-bounded alias rows per declared source.

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE issuer (
    issuer_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name text NOT NULL CHECK (btrim(legal_name) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('issuer');

CREATE TABLE security (
    security_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    security_class text NOT NULL CHECK (btrim(security_class) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage))
);

SELECT register_evidence_table('security');

CREATE TABLE exchange_listing (
    listing_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    security_id uuid NOT NULL REFERENCES security(security_id),
    venue text NOT NULL CHECK (btrim(venue) <> ''),
    currency text NOT NULL CHECK (btrim(currency) <> ''),
    listing_status text NOT NULL CHECK (listing_status IN ('active', 'suspended', 'delisted')),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    EXCLUDE USING gist (
        security_id WITH =,
        venue WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

SELECT register_evidence_table('exchange_listing');

CREATE TABLE issuer_symbol_alias (
    alias_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    symbol text NOT NULL CHECK (btrim(symbol) <> ''),
    source text NOT NULL CHECK (btrim(source) <> ''),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    EXCLUDE USING gist (
        issuer_id WITH =,
        source WITH =,
        (upper(symbol)) WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

SELECT register_evidence_table('issuer_symbol_alias');

CREATE TABLE security_symbol_alias (
    alias_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    security_id uuid NOT NULL REFERENCES security(security_id),
    symbol text NOT NULL CHECK (btrim(symbol) <> ''),
    source text NOT NULL CHECK (btrim(source) <> ''),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    EXCLUDE USING gist (
        security_id WITH =,
        source WITH =,
        (upper(symbol)) WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

SELECT register_evidence_table('security_symbol_alias');

CREATE TABLE listing_symbol_alias (
    alias_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    listing_id uuid NOT NULL REFERENCES exchange_listing(listing_id),
    symbol text NOT NULL CHECK (btrim(symbol) <> ''),
    source text NOT NULL CHECK (btrim(source) <> ''),
    valid_from timestamptz NOT NULL,
    valid_to timestamptz,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    EXCLUDE USING gist (
        listing_id WITH =,
        source WITH =,
        (upper(symbol)) WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

SELECT register_evidence_table('listing_symbol_alias');

SELECT assert_all_evidence_table_conventions();
