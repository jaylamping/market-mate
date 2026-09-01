-- WU-43 Operating Cost Register probe. Run inside a caller-managed
-- transaction; fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu43_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu43-probe","entitlement_version":"operating-cost-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_env_spec jsonb;
  v_year_spec jsonb;
  v_env operating_cost_envelope%ROWTYPE;
  v_year_env operating_cost_envelope%ROWTYPE;
  v_first operating_cost_entry%ROWTYPE;
  v_warn operating_cost_entry%ROWTYPE;
  v_again operating_cost_entry%ROWTYPE;
  v_year_warn operating_cost_entry%ROWTYPE;
  v_post operating_cost_entry%ROWTYPE;
BEGIN
  v_env_spec := jsonb_build_object(
    'envelope_key', 'wu43-stage-1',
    'monthly_hard_ceiling_cents', 25000,
    'year_one_hard_ceiling_cents', 200000,
    'monthly_warn_threshold_cents', 20000,
    'year_one_warn_threshold_cents', 160000,
    'year_one_starts_at', '2026-01-01T00:00:00Z'
  );
  SELECT * INTO v_env FROM register_operating_cost_envelope(v_env_spec, v_lineage);

  BEGIN
    PERFORM register_operating_cost_envelope(
      jsonb_set(v_env_spec, '{envelope_key}', '"wu43-raised-ceiling"'::jsonb)
        || jsonb_build_object('monthly_hard_ceiling_cents', 26000),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: raised monthly ceiling was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%#41 cap floors%' THEN RAISE; END IF;
      v_results := jsonb_build_object('raised_ceiling_blocked', true);
  END;

  BEGIN
    PERFORM register_operating_cost_envelope(
      jsonb_set(v_env_spec, '{envelope_key}', '"wu43-warn-at-hard"'::jsonb)
        || jsonb_build_object('monthly_warn_threshold_cents', 25000),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: warn-at-hard was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%#41 cap floors%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('warn_at_hard_blocked', true);
  END;

  SELECT * INTO v_first FROM record_operating_cost(
    jsonb_build_object(
      'payee', 'Fly.io',
      'category', 'hosting',
      'purpose', 'local research evidence stack',
      'amount_cents', 15000,
      'occurred_at', '2026-01-15T12:00:00Z',
      'commitment', 'monthly',
      'envelope_key', 'wu43-stage-1',
      'spending_classified', true,
      'experiment_ref', 'stage-1-research-evidence-mvp'
    ),
    v_lineage);
  SELECT * INTO v_again FROM record_operating_cost(
    jsonb_build_object(
      'payee', 'Fly.io',
      'category', 'hosting',
      'purpose', 'local research evidence stack',
      'amount_cents', 15000,
      'occurred_at', '2026-01-15T12:00:00Z',
      'commitment', 'monthly',
      'envelope_key', 'wu43-stage-1',
      'spending_classified', true,
      'experiment_ref', 'stage-1-research-evidence-mvp'
    ),
    v_lineage);
  SELECT * INTO v_warn FROM record_operating_cost(
    jsonb_build_object(
      'payee', 'Polygon.io',
      'category', 'data',
      'purpose', 'historical EOD entitlement',
      'amount_cents', 6000,
      'occurred_at', '2026-01-20T12:00:00Z',
      'commitment', 'monthly',
      'envelope_key', 'wu43-stage-1',
      'spending_classified', true
    ),
    v_lineage);

  v_results := v_results || jsonb_build_object(
    'expense_recorded',
      v_first.payee = 'Fly.io'
      AND v_first.category = 'hosting'
      AND v_first.purpose = 'local research evidence stack'
      AND v_first.amount_cents = 15000
      AND v_first.commitment = 'monthly'
      AND v_first.spending_classified
      AND v_first.reporting_prominence >= 1
      AND v_first.cap_status->>'monthly_state' = 'ok'
      AND (v_first.cap_status->>'warning')::boolean = false
      AND (v_first.cap_status->>'reporting_prominence')::int
          >= (v_first.cap_status->>'profit_reporting_prominence')::int,
    'warning_on_approach',
      (v_warn.cap_status->>'warning')::boolean = true
      AND v_warn.cap_status->>'monthly_state' = 'warning'
      AND (v_warn.cap_status->>'monthly_spent_cents')::bigint = 21000
      AND (v_warn.cap_status->>'monthly_hard_ceiling_cents')::bigint = 25000,
    'prominence_at_least_profit',
      v_first.reporting_prominence >= operating_cost_profit_prominence()
      AND v_warn.reporting_prominence >= operating_cost_profit_prominence(),
    'record_is_idempotent',
      v_again.entry_id = v_first.entry_id
      AND (SELECT count(*) FROM operating_cost_entry
           WHERE entry_digest = v_first.entry_digest) = 1
  );

  BEGIN
    PERFORM record_operating_cost(
      jsonb_build_object(
        'payee', 'OpenAI',
        'category', 'models',
        'purpose', 'would exceed monthly hard ceiling',
        'amount_cents', 5000,
        'occurred_at', '2026-01-22T12:00:00Z',
        'commitment', 'monthly',
        'envelope_key', 'wu43-stage-1',
        'spending_classified', true
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: over-ceiling spend was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%hard ceiling would be exceeded%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('monthly_ceiling_blocked', true);
  END;

  v_year_spec := jsonb_build_object(
    'envelope_key', 'wu43-year-one',
    'monthly_hard_ceiling_cents', 25000,
    'year_one_hard_ceiling_cents', 20000,
    'monthly_warn_threshold_cents', 20000,
    'year_one_warn_threshold_cents', 15000,
    'year_one_starts_at', '2026-01-01T00:00:00Z'
  );
  SELECT * INTO v_year_env FROM register_operating_cost_envelope(v_year_spec, v_lineage);
  SELECT * INTO v_year_warn FROM record_operating_cost(
    jsonb_build_object(
      'payee', 'Cloudflare',
      'category', 'infrastructure',
      'purpose', 'year-one warn demo',
      'amount_cents', 16000,
      'occurred_at', '2026-02-01T00:00:00Z',
      'commitment', 'one_time',
      'envelope_key', 'wu43-year-one',
      'spending_classified', true
    ),
    v_lineage);
  v_results := v_results || jsonb_build_object(
    'year_one_warning',
      (v_year_warn.cap_status->>'warning')::boolean = true
      AND v_year_warn.cap_status->>'year_one_state' = 'warning'
      AND v_year_warn.cap_status->>'monthly_state' = 'ok'
  );

  BEGIN
    PERFORM record_operating_cost(
      jsonb_build_object(
        'payee', 'Cloudflare',
        'category', 'infrastructure',
        'purpose', 'would exceed year-one hard ceiling',
        'amount_cents', 5000,
        'occurred_at', '2026-02-02T00:00:00Z',
        'commitment', 'one_time',
        'envelope_key', 'wu43-year-one',
        'spending_classified', true
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: over year-one ceiling was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%hard ceiling would be exceeded%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('year_one_ceiling_blocked', true);
  END;

  BEGIN
    PERFORM record_operating_cost(
      jsonb_build_object(
        'payee', 'Fly.io',
        'category', 'hosting',
        'purpose', 'non-finite timestamp',
        'amount_cents', 100,
        'occurred_at', 'infinity',
        'commitment', 'one_time',
        'envelope_key', 'wu43-stage-1',
        'spending_classified', true
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: infinite occurred_at was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%operating cost entry is invalid%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('nonfinite_occurred_at_blocked', true);
  END;

  SELECT * INTO v_post FROM record_operating_cost(
    jsonb_build_object(
      'payee', 'Fastmail',
      'category', 'other',
      'purpose', 'after year-one window',
      'amount_cents', 5000,
      'occurred_at', '2027-02-01T00:00:00Z',
      'commitment', 'one_time',
      'envelope_key', 'wu43-year-one',
      'spending_classified', true
    ),
    v_lineage);
  v_results := v_results || jsonb_build_object(
    'year_one_window_respected',
      v_post.spending_classified
      AND (v_post.cap_status->>'year_one_spent_cents')::bigint = 16000
      AND v_post.cap_status->>'monthly_state' = 'ok'
  );

  BEGIN
    PERFORM record_operating_cost(
      jsonb_build_object(
        'category', 'hosting',
        'purpose', 'missing payee',
        'amount_cents', 100,
        'occurred_at', '2026-01-10T00:00:00Z',
        'commitment', 'one_time',
        'envelope_key', 'wu43-stage-1',
        'spending_classified', true
      ),
      v_lineage);
    RAISE EXCEPTION 'probe corrupted: incomplete expense was admitted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%operating cost entry is invalid%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('incomplete_entry_blocked', true);
  END;

  BEGIN
    INSERT INTO operating_cost_entry (
      envelope_id, spec, entry_digest, payee, category, purpose,
      amount_cents, occurred_at, commitment, spending_classified,
      reporting_prominence, cap_status,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_first.envelope_id, v_first.spec, v_first.entry_digest,
      v_first.payee, v_first.category, v_first.purpose,
      v_first.amount_cents, v_first.occurred_at, v_first.commitment,
      v_first.spending_classified, v_first.reporting_prominence, v_first.cap_status,
      v_lineage, now(), 'local_research'
    );
    RAISE EXCEPTION 'probe corrupted: direct operating_cost INSERT was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%must go through the operating cost workflow%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE operating_cost_entry SET amount_cents = 1 WHERE entry_id = v_first.entry_id;
    RAISE EXCEPTION 'probe corrupted: operating cost entry was mutable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('entry_update_blocked', true);
  END;

  BEGIN
    DELETE FROM operating_cost_entry WHERE entry_id = v_first.entry_id;
    RAISE EXCEPTION 'probe corrupted: operating cost entry was deletable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('entry_delete_blocked', true);
  END;

  BEGIN
    TRUNCATE operating_cost_entry, operating_cost_envelope;
    RAISE EXCEPTION 'probe corrupted: operating cost register was truncatable';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('entry_truncate_blocked', true);
  END;

  v_results := v_results || jsonb_build_object(
    'entry_audited', (
      SELECT count(*) >= 1
      FROM audit_event
      WHERE event_type = 'research.operating_cost_recorded'
        AND payload->>'entry_digest' = v_first.entry_digest
    ),
    'no_authority_grant',
      v_first.record_environment = 'local_research'
      AND v_env.record_environment = 'local_research'
  );

  INSERT INTO wu43_probe_result (result) VALUES (v_results);
END
$probe$;
