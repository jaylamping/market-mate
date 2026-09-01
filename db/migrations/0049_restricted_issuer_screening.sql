-- WU-47 Restricted-Issuer screening gate. Universe admission and
-- research-targeting decisions screen the versioned Restricted-Issuer
-- List first; matches block with a recorded compliance decision. A list
-- change is tighten-only and freezes affected instruments for research
-- promotion. Compliance publication belongs to WU-48.

CREATE FUNCTION restricted_issuer_list_digest(members jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-restricted-issuer-list-v1|' || members::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION restricted_issuer_assert_members(members_value jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    allowed text[] := ARRAY['issuer_id', 'restriction_class', 'reason'];
    member jsonb;
    n integer;
    n_distinct integer;
BEGIN
    IF jsonb_typeof(members_value) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'restricted-issuer list members are invalid'
            USING ERRCODE = '22023';
    END IF;
    n := jsonb_array_length(members_value);
    FOR member IN SELECT jsonb_array_elements(members_value) LOOP
        IF jsonb_typeof(member) IS DISTINCT FROM 'object'
           OR EXISTS (
                SELECT 1 FROM jsonb_object_keys(member) k
                WHERE k <> ALL (allowed)
           )
           OR jsonb_typeof(member->'issuer_id') IS DISTINCT FROM 'string'
           OR coalesce(btrim(member->>'issuer_id'), '') = ''
           OR jsonb_typeof(member->'restriction_class') IS DISTINCT FROM 'string'
           OR lower(btrim(member->>'restriction_class')) NOT IN (
                'employer', 'board', 'consulting', 'household',
                'tender', 'principal_identified')
           OR jsonb_typeof(member->'reason') IS DISTINCT FROM 'string'
           OR coalesce(btrim(member->>'reason'), '') = '' THEN
            RAISE EXCEPTION 'restricted-issuer list members are invalid'
                USING ERRCODE = '22023';
        END IF;
        BEGIN
            PERFORM (btrim(member->>'issuer_id'))::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'restricted-issuer list members are invalid'
                    USING ERRCODE = '22023';
        END;
    END LOOP;
    SELECT count(DISTINCT (value->>'issuer_id')) INTO n_distinct
    FROM jsonb_array_elements(members_value);
    IF n IS DISTINCT FROM n_distinct THEN
        RAISE EXCEPTION 'restricted-issuer list members are invalid'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE TABLE restricted_issuer_list_version (
    list_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    list_version integer NOT NULL CHECK (list_version >= 1),
    predecessor_id uuid
        REFERENCES restricted_issuer_list_version(list_version_id),
    members jsonb NOT NULL CHECK (jsonb_typeof(members) = 'array'),
    list_digest text NOT NULL CHECK (list_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (list_digest = restricted_issuer_list_digest(members)),
    CHECK (
        (list_version = 1 AND predecessor_id IS NULL)
        OR (list_version > 1 AND predecessor_id IS NOT NULL)
    ),
    CHECK (record_environment = 'local_research'),
    UNIQUE (list_version)
);

SELECT register_evidence_table('restricted_issuer_list_version');

CREATE TABLE restricted_issuer_membership (
    membership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    list_version_id uuid NOT NULL
        REFERENCES restricted_issuer_list_version(list_version_id),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    restriction_class text NOT NULL,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (record_environment = 'local_research'),
    UNIQUE (list_version_id, issuer_id)
);

SELECT register_evidence_table('restricted_issuer_membership');

CREATE TABLE restricted_issuer_instrument_freeze (
    freeze_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    list_version_id uuid NOT NULL
        REFERENCES restricted_issuer_list_version(list_version_id),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    freeze_kind text NOT NULL CHECK (freeze_kind = 'research_promotion'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (record_environment = 'local_research'),
    UNIQUE (list_version_id, security_id)
);

SELECT register_evidence_table('restricted_issuer_instrument_freeze');

CREATE TABLE restricted_issuer_screening_decision (
    decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    list_version_id uuid NOT NULL
        REFERENCES restricted_issuer_list_version(list_version_id),
    security_id uuid NOT NULL REFERENCES security(security_id),
    issuer_id uuid NOT NULL REFERENCES issuer(issuer_id),
    purpose text NOT NULL CHECK (purpose IN (
        'universe_admission', 'research_targeting')),
    decision text NOT NULL CHECK (decision IN ('allowed', 'blocked')),
    compliance_decision text NOT NULL CHECK (btrim(compliance_decision) <> ''),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (
        (decision = 'blocked'
         AND compliance_decision = 'restricted_issuer_match')
        OR (decision = 'allowed'
            AND compliance_decision = 'not_restricted')
    ),
    CHECK (record_environment = 'local_research')
);

SELECT register_evidence_table('restricted_issuer_screening_decision');

CREATE FUNCTION guard_restricted_issuer_write() RETURNS trigger
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

CREATE TRIGGER restricted_issuer_list_version_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON restricted_issuer_list_version
    FOR EACH STATEMENT EXECUTE FUNCTION guard_restricted_issuer_write();
CREATE TRIGGER restricted_issuer_membership_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON restricted_issuer_membership
    FOR EACH STATEMENT EXECUTE FUNCTION guard_restricted_issuer_write();
CREATE TRIGGER restricted_issuer_instrument_freeze_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON restricted_issuer_instrument_freeze
    FOR EACH STATEMENT EXECUTE FUNCTION guard_restricted_issuer_write();
CREATE TRIGGER restricted_issuer_screening_decision_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON restricted_issuer_screening_decision
    FOR EACH STATEMENT EXECUTE FUNCTION guard_restricted_issuer_write();

CREATE FUNCTION guard_restricted_issuer_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.restricted_issuer_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            '% writes must go through the restricted-issuer workflow',
            TG_TABLE_NAME
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER restricted_issuer_list_version_insert_guard
    BEFORE INSERT ON restricted_issuer_list_version
    FOR EACH ROW EXECUTE FUNCTION guard_restricted_issuer_insert();
CREATE TRIGGER restricted_issuer_membership_insert_guard
    BEFORE INSERT ON restricted_issuer_membership
    FOR EACH ROW EXECUTE FUNCTION guard_restricted_issuer_insert();
CREATE TRIGGER restricted_issuer_instrument_freeze_insert_guard
    BEFORE INSERT ON restricted_issuer_instrument_freeze
    FOR EACH ROW EXECUTE FUNCTION guard_restricted_issuer_insert();
CREATE TRIGGER restricted_issuer_screening_decision_insert_guard
    BEFORE INSERT ON restricted_issuer_screening_decision
    FOR EACH ROW EXECUTE FUNCTION guard_restricted_issuer_insert();

CREATE FUNCTION restricted_issuer_list_tip()
RETURNS restricted_issuer_list_version
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT *
    FROM restricted_issuer_list_version
    ORDER BY list_version DESC
    LIMIT 1;
$$;

CREATE FUNCTION register_restricted_issuer_list(
    members_value jsonb,
    predecessor_id_value uuid,
    source_lineage_value jsonb
) RETURNS restricted_issuer_list_version
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    stored jsonb;
    digest_value text;
    tip restricted_issuer_list_version%ROWTYPE;
    predecessor restricted_issuer_list_version%ROWTYPE;
    created restricted_issuer_list_version%ROWTYPE;
    next_version integer;
    member jsonb;
    issuer_id_value uuid;
    new_issuer boolean;
    sec record;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'restricted-issuer list arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM restricted_issuer_assert_members(members_value);
    stored := coalesce((
        SELECT jsonb_agg(jsonb_build_object(
            'issuer_id', btrim(m->>'issuer_id'),
            'restriction_class', lower(btrim(m->>'restriction_class')),
            'reason', btrim(m->>'reason')
        ) ORDER BY btrim(m->>'issuer_id'))
        FROM jsonb_array_elements(members_value) m
    ), '[]'::jsonb);
    digest_value := restricted_issuer_list_digest(stored);

    PERFORM pg_advisory_xact_lock(hashtextextended('restricted-issuer-list', 49023));
    tip := restricted_issuer_list_tip();

    IF predecessor_id_value IS NULL THEN
        IF tip.list_version_id IS NOT NULL THEN
            RAISE EXCEPTION
                'restricted-issuer list already has a version; successors must set predecessor_id'
                USING ERRCODE = '22023';
        END IF;
        next_version := 1;
    ELSE
        IF tip.list_version_id IS DISTINCT FROM predecessor_id_value THEN
            RAISE EXCEPTION
                'restricted-issuer predecessor_id must be the current list tip'
                USING ERRCODE = '22023';
        END IF;
        SELECT * INTO predecessor
        FROM restricted_issuer_list_version
        WHERE list_version_id = predecessor_id_value;
        IF EXISTS (
            SELECT 1
            FROM restricted_issuer_membership prior
            WHERE prior.list_version_id = predecessor.list_version_id
              AND NOT EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(stored) m
                    WHERE (m->>'issuer_id')::uuid = prior.issuer_id
              )
        ) THEN
            RAISE EXCEPTION
                'restricted-issuer list change is tighten-only; issuers cannot be removed'
                USING ERRCODE = '22023';
        END IF;
        next_version := predecessor.list_version + 1;
    END IF;

    FOR member IN SELECT jsonb_array_elements(stored) LOOP
        issuer_id_value := (member->>'issuer_id')::uuid;
        IF NOT EXISTS (SELECT 1 FROM issuer WHERE issuer_id = issuer_id_value) THEN
            RAISE EXCEPTION 'issuer % is not registered', issuer_id_value
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    PERFORM set_config('market_mate.restricted_issuer_write', 'on', true);
    BEGIN
        INSERT INTO restricted_issuer_list_version (
            list_version, predecessor_id, members, list_digest,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            next_version, predecessor_id_value, stored, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;

        FOR member IN SELECT jsonb_array_elements(stored) LOOP
            issuer_id_value := (member->>'issuer_id')::uuid;
            INSERT INTO restricted_issuer_membership (
                list_version_id, issuer_id, restriction_class, reason,
                source_lineage, receipt_time, record_environment
            ) VALUES (
                created.list_version_id, issuer_id_value,
                member->>'restriction_class', member->>'reason',
                source_lineage_value, clock_timestamp(), 'local_research'
            );
            new_issuer := predecessor_id_value IS NULL
                OR NOT EXISTS (
                    SELECT 1 FROM restricted_issuer_membership prior
                    WHERE prior.list_version_id = predecessor_id_value
                      AND prior.issuer_id = issuer_id_value
                );
            IF new_issuer THEN
                FOR sec IN
                    SELECT security_id
                    FROM security
                    WHERE issuer_id = issuer_id_value
                LOOP
                    INSERT INTO restricted_issuer_instrument_freeze (
                        list_version_id, issuer_id, security_id, freeze_kind,
                        source_lineage, receipt_time, record_environment
                    ) VALUES (
                        created.list_version_id, issuer_id_value, sec.security_id,
                        'research_promotion',
                        source_lineage_value, clock_timestamp(), 'local_research'
                    );
                END LOOP;
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.restricted_issuer_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.restricted_issuer_write', 'off', true);

    PERFORM append_audit_event(
        'restricted-issuer-list:' || created.list_version_id::text,
        'research.restricted_issuer_list_recorded',
        now(),
        jsonb_build_object(
            'list_version_id', created.list_version_id,
            'list_version', created.list_version,
            'member_count', jsonb_array_length(stored),
            'list_digest', digest_value
        ),
        source_lineage_value,
        now(),
        'local_research'
    );
    RETURN created;
END;
$$;

CREATE FUNCTION screen_restricted_issuer(
    security_id_value uuid,
    purpose_value text,
    source_lineage_value jsonb
) RETURNS restricted_issuer_screening_decision
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    security_row security%ROWTYPE;
    tip restricted_issuer_list_version%ROWTYPE;
    matched boolean;
    decision_text text;
    compliance_text text;
    created restricted_issuer_screening_decision%ROWTYPE;
BEGIN
    IF security_id_value IS NULL
       OR purpose_value NOT IN ('universe_admission', 'research_targeting')
       OR NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'restricted-issuer screening arguments are invalid'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO security_row
    FROM security
    WHERE security_id = security_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'security % is not registered', security_id_value
            USING ERRCODE = '22023';
    END IF;
    tip := restricted_issuer_list_tip();
    IF tip.list_version_id IS NULL THEN
        RAISE EXCEPTION
            'restricted-issuer list is not registered; screening fails closed'
            USING ERRCODE = '22023';
    END IF;

    matched := EXISTS (
        SELECT 1 FROM restricted_issuer_membership
        WHERE list_version_id = tip.list_version_id
          AND issuer_id = security_row.issuer_id
    );
    IF matched THEN
        decision_text := 'blocked';
        compliance_text := 'restricted_issuer_match';
    ELSE
        decision_text := 'allowed';
        compliance_text := 'not_restricted';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        security_id_value::text || ':' || purpose_value || ':' || tip.list_version_id::text,
        49024));

    PERFORM set_config('market_mate.restricted_issuer_write', 'on', true);
    BEGIN
        INSERT INTO restricted_issuer_screening_decision (
            list_version_id, security_id, issuer_id, purpose,
            decision, compliance_decision,
            source_lineage, receipt_time, record_environment
        ) VALUES (
            tip.list_version_id, security_id_value, security_row.issuer_id,
            purpose_value, decision_text, compliance_text,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.restricted_issuer_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.restricted_issuer_write', 'off', true);

    PERFORM append_audit_event(
        'restricted-issuer-screen:' || created.decision_id::text,
        'research.restricted_issuer_screened',
        now(),
        jsonb_build_object(
            'decision_id', created.decision_id,
            'security_id', security_id_value,
            'issuer_id', security_row.issuer_id,
            'purpose', purpose_value,
            'decision', decision_text,
            'compliance_decision', compliance_text
        ),
        source_lineage_value,
        now(),
        'local_research'
    );
    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION register_restricted_issuer_list(jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION screen_restricted_issuer(uuid, text, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON restricted_issuer_list_version FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON restricted_issuer_membership FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON restricted_issuer_instrument_freeze FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON restricted_issuer_screening_decision FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
