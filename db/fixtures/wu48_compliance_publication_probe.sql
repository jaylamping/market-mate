-- WU-48 compliance evidence publication probe. Run inside a caller-managed
-- transaction; fixture evidence is rolled back by the acceptance script.
-- Requires temp table wu48_canonical(content text) holding the canonical file.

CREATE TEMP TABLE wu48_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu48-probe","entitlement_version":"compliance-publication-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_content text;
  v_digest text;
  v_key text := 'prohibited-conduct-inventory';
  v_path text := 'docs/research/self-directed-automated-trading-prohibited-conduct-and-account-rule-inventory.md';
  v_evidence_commit text := 'bcfcdc2a34f65c7c342326bba9e4f031445a9104';
  v_publication_commit text := '8d430300b8cff9a592d7548055cf42a08acd34c0';
  v_accepted compliance_evidence_acceptance%ROWTYPE;
  v_published compliance_evidence_publication%ROWTYPE;
BEGIN
  SELECT content INTO v_content FROM wu48_canonical;
  IF v_content IS NULL OR v_content = '' THEN
    RAISE EXCEPTION 'probe corrupted: canonical compliance evidence is missing';
  END IF;
  v_digest := compliance_evidence_digest(v_content);

  BEGIN
    PERFORM publish_compliance_evidence(
      v_key, v_digest, v_evidence_commit, v_publication_commit,
      'merge', '#55', v_lineage);
    RAISE EXCEPTION 'probe corrupted: unaccepted evidence was published';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%not accepted%' THEN RAISE; END IF;
      v_results := jsonb_build_object('unaccepted_publish_fail_closed', true);
  END;

  BEGIN
    PERFORM accept_compliance_evidence(
      v_key, 'docs/other/not-canonical.md', v_content, '#52', v_lineage);
    RAISE EXCEPTION 'probe corrupted: non-canonical path was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%canonical docs/research/%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('canonical_path_required', true);
  END;

  SELECT * INTO v_accepted FROM accept_compliance_evidence(
    v_key, v_path, v_content, '#52', v_lineage);

  BEGIN
    PERFORM publish_compliance_evidence(
      v_key, v_digest, v_evidence_commit, v_publication_commit,
      'squash', '#55', v_lineage);
    RAISE EXCEPTION 'probe corrupted: squash provenance was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%merge provenance%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('squash_refused', true);
  END;

  BEGIN
    PERFORM publish_compliance_evidence(
      v_key, repeat('0', 64), v_evidence_commit, v_publication_commit,
      'merge', '#55', v_lineage);
    RAISE EXCEPTION 'probe corrupted: mutated conclusions were published';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%conclusions must remain unchanged%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('conclusions_unchanged', true);
  END;

  SELECT * INTO v_published FROM publish_compliance_evidence(
    v_key, v_digest, v_evidence_commit, v_publication_commit,
    'merge', '#55', v_lineage);

  BEGIN
    PERFORM accept_compliance_evidence(
      v_key, v_path, v_content || E'\n', '#52', v_lineage);
    RAISE EXCEPTION 'probe corrupted: mutated acceptance was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%conclusions must remain unchanged%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('acceptance_immutable', true);
  END;

  v_results := v_results || jsonb_build_object(
    'published_on_canonical_path',
      v_published.canonical_path = v_path
      AND v_published.content_digest = v_digest
      AND v_accepted.content_digest = v_digest
      AND v_accepted.acceptance_state = 'accepted',
    'merge_provenance_preserved',
      v_published.publication_method = 'merge'
      AND v_published.evidence_commit = v_evidence_commit
      AND v_published.publication_commit = v_publication_commit
      AND v_published.evidence_commit <> v_published.publication_commit
      AND v_published.conclusions_unchanged
      AND v_published.provenance->>'publication_ticket' = '#55'
      AND v_published.provenance->>'source_ticket' = '#52'
  );

  BEGIN
    INSERT INTO compliance_evidence_publication (
      acceptance_id, artifact_key, canonical_path, content_digest,
      evidence_commit, publication_commit, publication_method,
      publication_ticket, conclusions_unchanged,
      provenance, provenance_digest,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_accepted.acceptance_id, 'direct-insert', v_path, v_digest,
      v_evidence_commit, v_publication_commit, 'merge', '#55', true,
      '{}'::jsonb, repeat('a', 64),
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct publication INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the compliance-publication workflow%' THEN
        RAISE;
      END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE compliance_evidence_publication
       SET conclusions_unchanged = true
     WHERE publication_id = v_published.publication_id;
    RAISE EXCEPTION 'probe corrupted: publication was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('publication_update_blocked', true);
  END;

  BEGIN
    DELETE FROM compliance_evidence_publication
     WHERE publication_id = v_published.publication_id;
    RAISE EXCEPTION 'probe corrupted: publication was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('publication_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE compliance_evidence_publication, compliance_evidence_acceptance;
    RAISE EXCEPTION 'probe corrupted: compliance publication tables were truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('publication_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'publication_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.compliance_evidence_published'
        AND payload->>'canonical_path' = v_path
        AND payload->>'evidence_commit' = v_evidence_commit
        AND payload->>'publication_commit' = v_publication_commit
        AND payload->>'publication_method' = 'merge'
    ),
    'no_authority_grant',
      v_published.record_environment = 'local_research'
      AND v_accepted.record_environment = 'local_research',
    'content_digest', v_digest,
    'canonical_path', v_path,
    'evidence_commit', v_evidence_commit,
    'publication_commit', v_publication_commit
  );

  INSERT INTO wu48_probe_result (result) VALUES (v_results);
END
$probe$;
