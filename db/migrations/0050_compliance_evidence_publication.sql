-- WU-48 Compliance evidence publication. Accepted compliance evidence
-- publishes to canonical docs/research/ with merge-commit provenance
-- (#55 pattern). Conclusions cannot change. Dashboard work stays
-- deferred; the five-part pack belongs to WU-49.

CREATE FUNCTION compliance_evidence_digest(content_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-compliance-evidence-v1|' || content_value,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION compliance_evidence_provenance_digest(provenance_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-compliance-publication-v1|' || provenance_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION compliance_evidence_assert_path(path_value text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF path_value IS DISTINCT FROM btrim(path_value)
       OR path_value IS NULL
       OR path_value !~ '^docs/research/[a-z0-9][a-z0-9._-]*\.md$' THEN
        RAISE EXCEPTION
            'compliance evidence path must be canonical docs/research/'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION compliance_evidence_assert_commit(commit_value text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF commit_value IS NULL
       OR commit_value !~ '^[0-9a-f]{40}$' THEN
        RAISE EXCEPTION 'compliance evidence git commit is invalid'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION compliance_evidence_assert_ticket(ticket_value text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF ticket_value IS NULL
       OR ticket_value !~ '^#[1-9][0-9]*$' THEN
        RAISE EXCEPTION 'compliance evidence ticket is invalid'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE TABLE compliance_evidence_acceptance (
    acceptance_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_key text NOT NULL CHECK (btrim(artifact_key) <> ''),
    canonical_path text NOT NULL,
    content text NOT NULL CHECK (content <> ''),
    content_digest text NOT NULL CHECK (content_digest ~ '^[0-9a-f]{64}$'),
    acceptance_state text NOT NULL CHECK (acceptance_state = 'accepted'),
    source_ticket text NOT NULL,
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (content_digest = compliance_evidence_digest(content)),
    CHECK (canonical_path ~ '^docs/research/[a-z0-9][a-z0-9._-]*\.md$'),
    CHECK (source_ticket ~ '^#[1-9][0-9]*$'),
    CHECK (record_environment = 'local_research'),
    UNIQUE (artifact_key)
);

SELECT register_evidence_table('compliance_evidence_acceptance');

CREATE TABLE compliance_evidence_publication (
    publication_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    acceptance_id uuid NOT NULL
        REFERENCES compliance_evidence_acceptance(acceptance_id),
    artifact_key text NOT NULL,
    canonical_path text NOT NULL,
    content_digest text NOT NULL CHECK (content_digest ~ '^[0-9a-f]{64}$'),
    evidence_commit text NOT NULL,
    publication_commit text NOT NULL,
    publication_method text NOT NULL CHECK (publication_method = 'merge'),
    publication_ticket text NOT NULL,
    conclusions_unchanged boolean NOT NULL CHECK (conclusions_unchanged),
    provenance jsonb NOT NULL CHECK (jsonb_typeof(provenance) = 'object'),
    provenance_digest text NOT NULL CHECK (provenance_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (canonical_path ~ '^docs/research/[a-z0-9][a-z0-9._-]*\.md$'),
    CHECK (evidence_commit ~ '^[0-9a-f]{40}$'),
    CHECK (publication_commit ~ '^[0-9a-f]{40}$'),
    CHECK (evidence_commit <> publication_commit),
    CHECK (publication_ticket ~ '^#[1-9][0-9]*$'),
    CHECK (provenance_digest = compliance_evidence_provenance_digest(provenance)),
    CHECK (provenance->>'artifact_key' = artifact_key),
    CHECK (provenance->>'canonical_path' = canonical_path),
    CHECK (provenance->>'content_digest' = content_digest),
    CHECK (provenance->>'evidence_commit' = evidence_commit),
    CHECK (provenance->>'publication_commit' = publication_commit),
    CHECK (provenance->>'publication_method' = publication_method),
    CHECK (provenance->>'publication_ticket' = publication_ticket),
    CHECK ((provenance->>'conclusions_unchanged')::boolean = conclusions_unchanged),
    CHECK (record_environment = 'local_research'),
    UNIQUE (acceptance_id),
    UNIQUE (artifact_key)
);

SELECT register_evidence_table('compliance_evidence_publication');

CREATE FUNCTION guard_compliance_publication_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER compliance_evidence_acceptance_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON compliance_evidence_acceptance
    FOR EACH STATEMENT EXECUTE FUNCTION guard_compliance_publication_write();
CREATE TRIGGER compliance_evidence_publication_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON compliance_evidence_publication
    FOR EACH STATEMENT EXECUTE FUNCTION guard_compliance_publication_write();

CREATE FUNCTION guard_compliance_publication_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting(
            'market_mate.compliance_publication_write', true), '') <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the compliance-publication workflow',
            TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER compliance_evidence_acceptance_insert_guard
    BEFORE INSERT ON compliance_evidence_acceptance
    FOR EACH ROW EXECUTE FUNCTION guard_compliance_publication_insert();
CREATE TRIGGER compliance_evidence_publication_insert_guard
    BEFORE INSERT ON compliance_evidence_publication
    FOR EACH ROW EXECUTE FUNCTION guard_compliance_publication_insert();

CREATE FUNCTION accept_compliance_evidence(
    artifact_key_value text,
    canonical_path_value text,
    content_value text,
    source_ticket_value text,
    source_lineage_value jsonb
) RETURNS compliance_evidence_acceptance
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    key_text text;
    path_text text;
    digest_value text;
    created compliance_evidence_acceptance%ROWTYPE;
    existing compliance_evidence_acceptance%ROWTYPE;
BEGIN
    key_text := btrim(artifact_key_value);
    path_text := btrim(canonical_path_value);
    IF key_text = ''
       OR content_value IS NULL
       OR content_value = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'compliance evidence acceptance arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM compliance_evidence_assert_path(path_text);
    PERFORM compliance_evidence_assert_ticket(source_ticket_value);
    digest_value := compliance_evidence_digest(content_value);

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'compliance-evidence-accept:' || key_text, 50023));

    SELECT * INTO existing
    FROM compliance_evidence_acceptance
    WHERE artifact_key = key_text;
    IF FOUND THEN
        IF existing.content_digest IS DISTINCT FROM digest_value
           OR existing.canonical_path IS DISTINCT FROM path_text
           OR existing.source_ticket IS DISTINCT FROM source_ticket_value THEN
            RAISE EXCEPTION
                'compliance evidence conclusions must remain unchanged'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.compliance_publication_write', 'on', true);
    BEGIN
        INSERT INTO compliance_evidence_acceptance (
            artifact_key, canonical_path, content, content_digest,
            acceptance_state, source_ticket,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            key_text, path_text, content_value, digest_value,
            'accepted', source_ticket_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config(
                'market_mate.compliance_publication_write', 'off', true);
            SELECT * INTO existing
            FROM compliance_evidence_acceptance
            WHERE artifact_key = key_text;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.content_digest IS DISTINCT FROM digest_value
               OR existing.canonical_path IS DISTINCT FROM path_text THEN
                RAISE EXCEPTION
                    'compliance evidence conclusions must remain unchanged'
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config(
                'market_mate.compliance_publication_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.compliance_publication_write', 'off', true);

    PERFORM append_audit_event(
        'compliance-evidence-accept:' || created.acceptance_id::text,
        'research.compliance_evidence_accepted',
        now(),
        jsonb_build_object(
            'acceptance_id', created.acceptance_id,
            'artifact_key', key_text,
            'canonical_path', path_text,
            'content_digest', digest_value,
            'source_ticket', source_ticket_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION publish_compliance_evidence(
    artifact_key_value text,
    content_digest_value text,
    evidence_commit_value text,
    publication_commit_value text,
    publication_method_value text,
    publication_ticket_value text,
    source_lineage_value jsonb
) RETURNS compliance_evidence_publication
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    key_text text;
    method_text text;
    accepted compliance_evidence_acceptance%ROWTYPE;
    provenance_value jsonb;
    digest_value text;
    created compliance_evidence_publication%ROWTYPE;
    existing compliance_evidence_publication%ROWTYPE;
BEGIN
    key_text := btrim(artifact_key_value);
    method_text := lower(btrim(publication_method_value));
    IF key_text = ''
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'compliance evidence publication arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM compliance_evidence_assert_commit(evidence_commit_value);
    PERFORM compliance_evidence_assert_commit(publication_commit_value);
    PERFORM compliance_evidence_assert_ticket(publication_ticket_value);

    IF method_text IS DISTINCT FROM 'merge' THEN
        RAISE EXCEPTION
            'compliance evidence publication must use merge provenance'
            USING ERRCODE = '22023';
    END IF;
    IF evidence_commit_value = publication_commit_value THEN
        RAISE EXCEPTION
            'compliance evidence publication must use merge provenance'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'compliance-evidence-publish:' || key_text, 50024));

    SELECT * INTO accepted
    FROM compliance_evidence_acceptance
    WHERE artifact_key = key_text
      AND acceptance_state = 'accepted';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'compliance evidence is not accepted; publication fails closed'
            USING ERRCODE = '22023';
    END IF;

    IF content_digest_value IS DISTINCT FROM accepted.content_digest THEN
        RAISE EXCEPTION
            'compliance evidence conclusions must remain unchanged'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO existing
    FROM compliance_evidence_publication
    WHERE artifact_key = key_text;
    IF FOUND THEN
        IF existing.content_digest IS DISTINCT FROM accepted.content_digest
           OR existing.evidence_commit IS DISTINCT FROM evidence_commit_value
           OR existing.publication_commit IS DISTINCT FROM publication_commit_value
           OR existing.publication_method IS DISTINCT FROM method_text THEN
            RAISE EXCEPTION
                'compliance evidence conclusions must remain unchanged'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    provenance_value := jsonb_build_object(
        'artifact_key', key_text,
        'canonical_path', accepted.canonical_path,
        'content_digest', accepted.content_digest,
        'evidence_commit', evidence_commit_value,
        'publication_commit', publication_commit_value,
        'publication_method', method_text,
        'publication_ticket', publication_ticket_value,
        'source_ticket', accepted.source_ticket,
        'conclusions_unchanged', true
    );
    digest_value := compliance_evidence_provenance_digest(provenance_value);

    PERFORM set_config('market_mate.compliance_publication_write', 'on', true);
    BEGIN
        INSERT INTO compliance_evidence_publication (
            acceptance_id, artifact_key, canonical_path, content_digest,
            evidence_commit, publication_commit, publication_method,
            publication_ticket, conclusions_unchanged,
            provenance, provenance_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            accepted.acceptance_id, key_text, accepted.canonical_path,
            accepted.content_digest,
            evidence_commit_value, publication_commit_value, method_text,
            publication_ticket_value, true,
            provenance_value, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN unique_violation THEN
            PERFORM set_config(
                'market_mate.compliance_publication_write', 'off', true);
            SELECT * INTO existing
            FROM compliance_evidence_publication
            WHERE artifact_key = key_text;
            IF NOT FOUND THEN
                RAISE;
            END IF;
            IF existing.content_digest IS DISTINCT FROM accepted.content_digest THEN
                RAISE EXCEPTION
                    'compliance evidence conclusions must remain unchanged'
                    USING ERRCODE = '22023';
            END IF;
            RETURN existing;
        WHEN OTHERS THEN
            PERFORM set_config(
                'market_mate.compliance_publication_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.compliance_publication_write', 'off', true);

    PERFORM append_audit_event(
        'compliance-evidence-publish:' || created.publication_id::text,
        'research.compliance_evidence_published',
        now(),
        jsonb_build_object(
            'publication_id', created.publication_id,
            'acceptance_id', accepted.acceptance_id,
            'artifact_key', key_text,
            'canonical_path', accepted.canonical_path,
            'content_digest', accepted.content_digest,
            'evidence_commit', evidence_commit_value,
            'publication_commit', publication_commit_value,
            'publication_method', method_text,
            'publication_ticket', publication_ticket_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );
    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION accept_compliance_evidence(text, text, text, text, jsonb)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION publish_compliance_evidence(
    text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON compliance_evidence_acceptance
    FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON compliance_evidence_publication
    FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
