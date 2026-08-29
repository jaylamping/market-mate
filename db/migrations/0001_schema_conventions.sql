-- Baseline schema conventions for evidence isolation. No domain evidence tables yet.
CREATE TYPE record_environment AS ENUM ('local_research', 'paper', 'live');

CREATE TABLE schema_object (
    table_schema text NOT NULL DEFAULT 'public',
    table_name text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('evidence', 'control')),
    registered_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (table_schema, table_name)
);

CREATE FUNCTION source_lineage_is_valid(lineage jsonb) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_typeof(lineage) = 'object'
       AND coalesce(btrim(lineage->>'source'), '') <> ''
       AND coalesce(btrim(lineage->>'entitlement_version'), '') <> '';
$$;

CREATE FUNCTION assert_evidence_table_conventions(rel_schema text, rel_name text) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    missing text[];
    rel regclass;
BEGIN
    rel := to_regclass(format('%I.%I', rel_schema, rel_name));
    IF rel IS NULL THEN
        RAISE EXCEPTION 'evidence table %.% does not exist', rel_schema, rel_name;
    END IF;

    SELECT coalesce(array_agg(required.col ORDER BY required.col), '{}')
    INTO missing
    FROM (
        VALUES
            ('source_lineage', 'jsonb'),
            ('receipt_time', 'timestamptz'),
            ('record_environment', 'record_environment')
    ) AS required(col, typ)
    LEFT JOIN pg_attribute a
      ON a.attrelid = rel
     AND a.attname = required.col
     AND a.attnum > 0
     AND NOT a.attisdropped
    LEFT JOIN pg_type t ON t.oid = a.atttypid
    WHERE a.attname IS NULL OR t.typname <> required.typ OR NOT a.attnotnull;

    IF missing <> '{}' THEN
        RAISE EXCEPTION
            'evidence table %.% does not satisfy schema conventions (missing or nullable/wrong-type columns: %)',
            rel_schema, rel_name, missing;
    END IF;
END;
$$;

CREATE FUNCTION register_evidence_table(rel_name text, rel_schema text DEFAULT 'public') RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM assert_evidence_table_conventions(rel_schema, rel_name);
    INSERT INTO schema_object (table_schema, table_name, kind)
    VALUES (rel_schema, rel_name, 'evidence')
    ON CONFLICT (table_schema, table_name)
    DO UPDATE SET kind = EXCLUDED.kind;
END;
$$;

CREATE FUNCTION assert_all_evidence_table_conventions() RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT table_schema, table_name
        FROM schema_object
        WHERE kind = 'evidence'
    LOOP
        PERFORM assert_evidence_table_conventions(obj.table_schema, obj.table_name);
    END LOOP;
END;
$$;

CREATE FUNCTION schema_fingerprint() RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT md5(string_agg(part, E'\n' ORDER BY part))
    FROM (
        SELECT 'c:' || c.relname || ':' || a.attname || ':' || t.typname || ':' || a.attnotnull::text AS part
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
        UNION ALL
        SELECT 't:' || t.typname || ':' || t.typtype::text
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typtype IN ('e', 'c')
        UNION ALL
        SELECT 'e:' || t.typname || ':' || e.enumsortorder::text || ':' || e.enumlabel
        FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
        UNION ALL
        SELECT 'p:' || p.proname || ':' || pg_get_function_identity_arguments(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    ) parts;
$$;

INSERT INTO schema_object (table_name, kind) VALUES
    ('schema_migration', 'control'),
    ('schema_object', 'control');

SELECT assert_all_evidence_table_conventions();
