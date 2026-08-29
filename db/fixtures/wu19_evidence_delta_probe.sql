-- WU-19 Research Evidence Delta probe. Run inside a caller-managed
-- transaction; the acceptance script rolls all fixture data back.

CREATE TEMP TABLE wu19_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu19-probe","entitlement_version":"evidence-delta-v1"}';
  v_prior research_snapshot%ROWTYPE;
  v_current research_snapshot%ROWTYPE;
  v_delta research_evidence_delta%ROWTYPE;
  v_prose research_evidence_delta_prose%ROWTYPE;
  v_results jsonb;
BEGIN
  SELECT * INTO v_prior FROM append_research_snapshot(
    'security_research',
    '{
      "facts": {
        "identity": {"value":"WU19","observation_state":"current"},
        "old_metric": {"value":10,"observation_state":"current"},
        "removed_metric": {"value":4,"observation_state":"current"},
        "expiring_metric": {"value":5,"observation_state":"current","expires_at":"2026-08-28T20:00:00Z"}
      },
      "indicators": {
        "trend": {"value":"up","observation_state":"current"},
        "obsolete": {"value":"keep","observation_state":"current"}
      },
      "dependencies": {
        "options": {"effect_state":"available"},
        "sentiment": {"effect_state":"blocked"}
      }
    }'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_current FROM append_research_snapshot(
    'security_research',
    '{
      "facts": {
        "identity": {"value":"WU19","observation_state":"current"},
        "old_metric": {"value":12,"observation_state":"current"},
        "new_metric": {"value":7,"observation_state":"current"},
        "expiring_metric": {"value":5,"observation_state":"expired","expires_at":"2026-08-28T20:00:00Z"}
      },
      "indicators": {
        "trend": {"value":"down","observation_state":"current"},
        "quality": {"value":"improved","observation_state":"current"}
      },
      "dependencies": {
        "options": {"effect_state":"blocked"},
        "sentiment": {"effect_state":"available"}
      }
    }'::jsonb,
    v_lineage, v_prior.snapshot_id, 'vendor correction and dependency restoration'
  );

  SELECT * INTO v_delta FROM compute_research_evidence_delta(
    v_current.snapshot_id, v_prior.snapshot_id,
    '2026-08-29T22:00:00Z', v_lineage
  );
  SELECT * INTO v_prose FROM record_research_evidence_delta_prose(
    v_delta.delta_id, 'Generated summary: WU19 changed evidence.', v_lineage
  );

  v_results := jsonb_build_object(
    'delta_covers_additions', v_delta.delta->'additions' @> '[{"key":"new_metric"}]'::jsonb,
    'delta_covers_removals', v_delta.delta->'removals' @> '[{"key":"removed_metric"}]'::jsonb,
    'delta_covers_corrections', v_delta.delta->'corrections' @> '[{"key":"old_metric"}]'::jsonb,
    'delta_covers_expiry', v_delta.delta->'expiries' @> '[{"key":"expiring_metric"}]'::jsonb,
    'delta_covers_observation_state_changes', v_delta.delta->'observation_state_changes' @> '[{"key":"expiring_metric"}]'::jsonb,
    'delta_covers_indicator_changes', v_delta.delta->'indicator_changes' @> '[{"indicator_key":"trend"}]'::jsonb,
    'delta_covers_newly_blocked_dependency', v_delta.delta->'dependency_changes' @> '[{"dependency_key":"options","change_type":"newly_blocked"}]'::jsonb,
    'delta_covers_restored_dependency', v_delta.delta->'dependency_changes' @> '[{"dependency_key":"sentiment","change_type":"restored"}]'::jsonb,
    'delta_digest_bound', v_delta.delta_digest = encode(digest('market-mate-evidence-delta-v1|' || v_delta.delta::text, 'sha256'), 'hex'),
    'generated_prose_non_authoritative', v_prose.authority_state = 'non_authoritative',
    'prose_digest_bound', v_prose.prose_digest = encode(digest('market-mate-generated-prose-v1|' || v_prose.generated_text, 'sha256'), 'hex'),
    'delta_update_blocked', false,
    'prose_update_blocked', false
  );

  BEGIN
    UPDATE research_evidence_delta
       SET as_of_at = as_of_at + interval '1 second'
     WHERE delta_id = v_delta.delta_id;
    RAISE EXCEPTION 'probe corrupted: Research Evidence Delta was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('delta_update_blocked', true);
  END;

  BEGIN
    UPDATE research_evidence_delta_prose
       SET authority_state = 'non_authoritative'
     WHERE prose_id = v_prose.prose_id;
    RAISE EXCEPTION 'probe corrupted: generated delta prose was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('prose_update_blocked', true);
  END;

  INSERT INTO wu19_probe_result (result) VALUES (v_results);
END
$probe$;
