-- Force conventions that 0001 only documented: lineage CHECK, no invented
-- defaults, every public base table registered, vector types forbidden.
-- Tighten fingerprint to non-extension objects including constraints,
-- indexes, and function bodies. Record schema head as the checksum chain.

CREATE OR REPLACE FUNCTION assert_evidence_table_conventions(rel_schema text, rel_name text) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    missing text[];
    defaulted text[];
    rel regclass;
    has_lineage_check boolean;
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

    SELECT coalesce(array_agg(a.attname ORDER BY a.attname), '{}')
    INTO defaulted
    FROM pg_attribute a
    WHERE a.attrelid = rel
      AND a.attname IN ('source_lineage', 'receipt_time', 'record_environment')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.atthasdef;

    IF defaulted <> '{}' THEN
        RAISE EXCEPTION
            'evidence table %.% invents provenance via defaults on %',
            rel_schema, rel_name, defaulted;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM pg_constraint con
        WHERE con.conrelid = rel
          AND con.contype = 'c'
          AND pg_get_expr(con.conbin, con.conrelid) = 'source_lineage_is_valid(source_lineage)'
    ) INTO has_lineage_check;

    IF NOT has_lineage_check THEN
        RAISE EXCEPTION
            'evidence table %.% must include CHECK (source_lineage_is_valid(source_lineage))',
            rel_schema, rel_name;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION register_evidence_table(rel_name text, rel_schema text DEFAULT 'public') RETURNS void
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

CREATE OR REPLACE FUNCTION assert_all_evidence_table_conventions() RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
    unregistered text[];
    vector_cols text[];
BEGIN
    SELECT coalesce(array_agg(c.relname ORDER BY c.relname), '{}')
    INTO unregistered
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT EXISTS (
          SELECT 1
          FROM schema_object s
          WHERE s.table_schema = n.nspname
            AND s.table_name = c.relname
      );

    IF unregistered <> '{}' THEN
        RAISE EXCEPTION
            'public base tables are not registered in schema_object: %',
            unregistered;
    END IF;

    SELECT coalesce(array_agg(format('%s.%s', c.relname, a.attname) ORDER BY c.relname, a.attname), '{}')
    INTO vector_cols
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    JOIN pg_type t ON t.oid = a.atttypid
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND t.typname IN ('vector', 'halfvec', 'sparsevec');

    IF vector_cols <> '{}' THEN
        RAISE EXCEPTION 'vector usage is gated off; forbidden columns: %', vector_cols;
    END IF;

    FOR obj IN
        SELECT table_schema, table_name
        FROM schema_object
        WHERE kind = 'evidence'
    LOOP
        PERFORM assert_evidence_table_conventions(obj.table_schema, obj.table_name);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION schema_head() RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(
        string_agg(version::text || ':' || name || ':' || checksum, ',' ORDER BY version),
        ''
    )
    FROM schema_migration;
$$;

CREATE OR REPLACE FUNCTION schema_fingerprint() RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT md5(string_agg(part, E'\n' ORDER BY part))
    FROM (
        SELECT 'c:' || c.relname || ':' || a.attname || ':' || t.typname || ':'
            || a.attnotnull::text || ':' || a.atthasdef::text AS part
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e'
          )
        UNION ALL
        SELECT 'k:' || pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e'
          )
        UNION ALL
        SELECT 'i:' || pg_get_indexdef(idx.indexrelid)
        FROM pg_index idx
        JOIN pg_class c ON c.oid = idx.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e'
          )
        UNION ALL
        SELECT 't:' || t.typname || ':' || t.typtype::text
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typtype IN ('e', 'c')
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e'
          )
        UNION ALL
        SELECT 'e:' || t.typname || ':' || e.enumsortorder::text || ':' || e.enumlabel
        FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
        UNION ALL
        SELECT 'p:' || pg_get_functiondef(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e'
          )
    ) parts;
$$;

SELECT assert_all_evidence_table_conventions();
