-- WU-44 Operating Cost model probe. Run inside a caller-managed
-- transaction; fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu44_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu44-probe","entitlement_version":"cost-model-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_env_spec jsonb;
  v_stage1 jsonb;
  v_over jsonb;
  v_assumptions jsonb;
  v_over_ass jsonb;
  v_env operating_cost_envelope%ROWTYPE;
  v_model operating_cost_model%ROWTYPE;
  v_again operating_cost_model%ROWTYPE;
  v_over_model operating_cost_model%ROWTYPE;
BEGIN
  v_env_spec := jsonb_build_object(
    'envelope_key', 'wu44-stage-1',
    'monthly_hard_ceiling_cents', 25000,
    'year_one_hard_ceiling_cents', 200000,
    'monthly_warn_threshold_cents', 20000,
    'year_one_warn_threshold_cents', 160000,
    'year_one_starts_at', '2026-01-01T00:00:00Z'
  );
  SELECT * INTO v_env FROM register_operating_cost_envelope(v_env_spec, v_lineage);

  v_stage1 := jsonb_build_array(
    jsonb_build_object(
      'vendor', 'local-mac', 'category', 'hosting',
      'monthly_cents', 5000, 'months', 2, 'one_time_cents', 0),
    jsonb_build_object(
      'vendor', 'local-paper', 'category', 'infrastructure',
      'monthly_cents', 17500, 'months', 2, 'one_time_cents', 0),
    jsonb_build_object(
      'vendor', 'digitalocean-cloud-paper', 'category', 'hosting',
      'monthly_cents', 16500, 'months', 4, 'one_time_cents', 0),
    jsonb_build_object(
      'vendor', 'restricted-live-host', 'category', 'hosting',
      'monthly_cents', 19000, 'months', 4, 'one_time_cents', 0)
  );
  v_assumptions := jsonb_build_object(
    'envelope_key', 'wu44-stage-1',
    'vendor_set_key', 'stage-1-local-to-restricted-live',
    'concurrency', 'sequential'
  );
  SELECT * INTO v_model FROM record_operating_cost_model(
    'wu44-stage-1-vendor-set', v_stage1, v_assumptions, v_lineage);
  SELECT * INTO v_again FROM record_operating_cost_model(
    'wu44-stage-1-vendor-set', v_stage1, v_assumptions, v_lineage);

  v_results := jsonb_build_object(
    'stage1_within_caps',
      v_model.within_caps
      AND v_model.required_decision IS NULL
      AND (v_model.result->>'monthly_projected_cents')::bigint = 19000
      AND (v_model.result->>'year_one_projected_cents')::bigint = 187000
      AND (v_model.result->>'monthly_escalation') = 'ok'
      AND (v_model.result->>'year_one_escalation') = 'warning'
      AND (v_model.result->>'absolute_monthly_hard_ceiling_cents')::bigint = 25000
      AND (v_model.result->>'absolute_year_one_hard_ceiling_cents')::bigint = 200000,
    'escalation_flagged',
      (v_model.result->>'year_one_escalation') = 'warning'
      AND (v_model.result->>'year_one_projected_cents')::bigint >= 160000
      AND (v_model.result->>'year_one_projected_cents')::bigint <= 200000,
    'record_is_idempotent',
      v_again.model_id = v_model.model_id
      AND (SELECT count(*) FROM operating_cost_model
           WHERE model_key = 'wu44-stage-1-vendor-set') = 1
  );

  v_over := jsonb_build_array(
    jsonb_build_object(
      'vendor', 'consolidated-data', 'category', 'data',
      'monthly_cents', 9900, 'months', 12, 'one_time_cents', 0),
    jsonb_build_object(
      'vendor', 'always-on-cloud', 'category', 'hosting',
      'monthly_cents', 16500, 'months', 12, 'one_time_cents', 0)
  );
  BEGIN
    PERFORM record_operating_cost_model(
      'wu44-over-cap-unnamed',
      v_over,
      jsonb_build_object(
        'envelope_key', 'wu44-stage-1',
        'vendor_set_key', 'full-year-cloud-plus-data',
        'concurrency', 'concurrent'
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: over-cap model without a decision was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%does not name the required decision%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unnamed_over_cap_blocked', true);
  END;

  v_over_ass := jsonb_build_object(
    'envelope_key', 'wu44-stage-1',
    'vendor_set_key', 'full-year-cloud-plus-data',
    'concurrency', 'concurrent',
    'required_decision',
      'Principal authorization required to raise the #41 monthly ceiling and approve a full-year paid data commitment'
  );
  SELECT * INTO v_over_model FROM record_operating_cost_model(
    'wu44-over-cap-named', v_over, v_over_ass, v_lineage);
  v_results := v_results || jsonb_build_object(
    'over_cap_names_decision',
      v_over_model.within_caps = false
      AND v_over_model.required_decision LIKE '%Principal authorization%'
      AND v_over_model.result->>'monthly_escalation' = 'exceeded'
      AND (v_over_model.result->>'monthly_projected_cents')::bigint = 26400
      AND (v_over_model.result->>'year_one_projected_cents')::bigint = 316800
  );

  BEGIN
    PERFORM record_operating_cost_model(
      'wu44-missing-quote',
      jsonb_build_array(jsonb_build_object(
        'vendor', 'x', 'category', 'other', 'months', 1, 'one_time_cents', 0
      )),
      v_assumptions, v_lineage);
    RAISE EXCEPTION 'probe corrupted: quote missing monthly_cents was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%quotes are invalid%'
         AND SQLERRM NOT LIKE '%missing required inputs%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_quote_input_blocked', true);
  END;

  BEGIN
    PERFORM record_operating_cost_model(
      'wu44-no-envelope',
      v_stage1,
      jsonb_build_object(
        'envelope_key', 'wu44-missing',
        'vendor_set_key', 'stage-1-local-to-restricted-live',
        'concurrency', 'sequential'
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: missing envelope was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%envelope is not registered%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('missing_envelope_blocked', true);
  END;

  BEGIN
    PERFORM record_operating_cost_model(
      'wu44-stage-1-vendor-set',
      v_over, v_over_ass, v_lineage);
    RAISE EXCEPTION 'probe corrupted: model key mutation was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%already recorded with a different result or lineage%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('spec_mismatch_blocked', true);
  END;

  BEGIN
    INSERT INTO operating_cost_model (
      model_key, envelope_id, quotes, quotes_digest, assumptions,
      result, result_digest, within_caps,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      'wu44-direct', v_model.envelope_id, v_model.quotes, v_model.quotes_digest,
      v_model.assumptions, v_model.result, v_model.result_digest, true,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct cost model INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the operating cost model workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE operating_cost_model SET within_caps = false WHERE model_id = v_model.model_id;
    RAISE EXCEPTION 'probe corrupted: cost model was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('model_update_blocked', true);
  END;

  BEGIN
    DELETE FROM operating_cost_model WHERE model_id = v_model.model_id;
    RAISE EXCEPTION 'probe corrupted: cost model was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('model_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE operating_cost_model;
    RAISE EXCEPTION 'probe corrupted: cost model was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('model_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'model_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.operating_cost_model_recorded'
        AND payload->>'result_digest' = v_model.result_digest
    ),
    'no_authority_grant',
      v_model.record_environment = 'local_research'
      AND v_over_model.record_environment = 'local_research'
  );

  INSERT INTO wu44_probe_result (result) VALUES (v_results);
END
$probe$;
