-- WU-21 containment probe. Run inside a caller-managed transaction; the
-- acceptance script rolls all fixture data back.

CREATE TEMP TABLE wu21_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu21-probe","entitlement_version":"cycle-containment-v1"}';
  v_now timestamptz := clock_timestamp();
  v_security_snapshot research_snapshot%ROWTYPE;
  v_options_snapshot research_snapshot%ROWTYPE;
  v_stale_security_snapshot research_snapshot%ROWTYPE;
  v_incomplete_security_snapshot research_snapshot%ROWTYPE;
  v_failed_security_snapshot research_snapshot%ROWTYPE;
  v_conflict_security_snapshot research_snapshot%ROWTYPE;
  v_bad_post_close_snapshot research_snapshot%ROWTYPE;
  v_legacy_actions_snapshot research_snapshot%ROWTYPE;
  v_late_snapshot research_snapshot%ROWTYPE;
  v_future_snapshot research_snapshot%ROWTYPE;
  v_complete research_post_close_cycle%ROWTYPE;
  v_degraded research_post_close_cycle%ROWTYPE;
  v_stale research_post_close_cycle%ROWTYPE;
  v_incomplete research_cycle_manifest%ROWTYPE;
  v_failed research_cycle_manifest%ROWTYPE;
  v_empty research_cycle_manifest%ROWTYPE;
  v_conflict research_cycle_manifest%ROWTYPE;
  v_late research_cycle_manifest%ROWTYPE;
  v_inconsistent research_cycle_manifest%ROWTYPE;
  v_future research_cycle_manifest%ROWTYPE;
  v_unpublished research_cycle_manifest%ROWTYPE;
  v_legacy_cycle research_post_close_cycle%ROWTYPE;
  v_complete_expected jsonb;
  v_degraded_expected jsonb;
  v_stale_expected jsonb;
  v_security_consumer research_cycle_consumer_contract%ROWTYPE;
  v_options_consumer research_cycle_consumer_contract%ROWTYPE;
  v_complete_security_decision research_cycle_scope_decision%ROWTYPE;
  v_complete_options_decision research_cycle_scope_decision%ROWTYPE;
  v_degraded_security_decision research_cycle_scope_decision%ROWTYPE;
  v_degraded_options_decision research_cycle_scope_decision%ROWTYPE;
  v_stale_security_decision research_cycle_scope_decision%ROWTYPE;
  v_stale_options_decision research_cycle_scope_decision%ROWTYPE;
  v_incomplete_security_decision research_cycle_scope_decision%ROWTYPE;
  v_incomplete_options_decision research_cycle_scope_decision%ROWTYPE;
  v_failed_security_decision research_cycle_scope_decision%ROWTYPE;
  v_failed_options_decision research_cycle_scope_decision%ROWTYPE;
  v_gate_decision research_cycle_scope_decision%ROWTYPE;
  v_results jsonb;
BEGIN
  SELECT * INTO v_security_consumer FROM register_research_cycle_consumer(
    'wu21-security-research', 'research_candidate', 'stock_eligible', 'research',
    '["security_daily"]'::jsonb, v_lineage
  );
  SELECT * INTO v_options_consumer FROM register_research_cycle_consumer(
    'wu21-options-new-exposure', 'trade_eligible', 'options_eligible', 'new_exposure',
    '["options"]'::jsonb, v_lineage
  );

  SELECT * INTO v_security_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-COMPLETE","close":100,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_options_snapshot FROM append_research_snapshot(
    'options_chain', '{"security":"WU21-COMPLETE","observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  v_complete_expected := jsonb_build_array(
    jsonb_build_object(
      'snapshot_key', 'WU21-complete-security', 'snapshot_id', v_security_snapshot.snapshot_id::text,
      'source', 'eod_prices', 'state', 'complete',
      'dependency_scope', jsonb_build_array('security_daily')
    ),
    jsonb_build_object(
      'snapshot_key', 'WU21-complete-options', 'snapshot_id', v_options_snapshot.snapshot_id::text,
      'source', 'historical_options', 'state', 'complete',
      'dependency_scope', jsonb_build_array('options')
    )
  );
  SELECT * INTO v_complete FROM publish_post_close_cycle(
    '2026-08-29', clock_timestamp() - interval '2 hours', clock_timestamp(),
    v_complete_expected, v_lineage
  );

  SELECT * INTO v_security_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-DEGRADED","close":101,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  v_degraded_expected := jsonb_build_array(
    jsonb_build_object(
      'snapshot_key', 'WU21-degraded-security', 'snapshot_id', v_security_snapshot.snapshot_id::text,
      'source', 'eod_prices', 'state', 'complete',
      'dependency_scope', jsonb_build_array('security_daily')
    ),
    jsonb_build_object(
      'snapshot_key', 'WU21-degraded-options', 'source', 'historical_options', 'state', 'failed',
      'failure_reason', 'licensed options source unavailable',
      'dependency_scope', jsonb_build_array('options')
    )
  );
  SELECT * INTO v_degraded FROM publish_post_close_cycle(
    '2026-08-30', clock_timestamp() - interval '3 hours', clock_timestamp(),
    v_degraded_expected, v_lineage
  );

  SELECT * INTO v_stale_security_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-STALE","close":102,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  v_stale_expected := jsonb_build_array(
    jsonb_build_object(
      'snapshot_key', 'WU21-stale-security', 'snapshot_id', v_stale_security_snapshot.snapshot_id::text,
      'source', 'eod_prices', 'state', 'complete',
      'dependency_scope', jsonb_build_array('security_daily')
    ),
    jsonb_build_object(
      'snapshot_key', 'WU21-stale-options', 'snapshot_id', v_options_snapshot.snapshot_id::text,
      'source', 'historical_options', 'state', 'complete',
      'dependency_scope', jsonb_build_array('options')
    )
  );
  SELECT * INTO v_stale FROM publish_post_close_cycle(
    '2026-08-31', v_now - interval '3 hours', v_now + interval '4 minutes',
    v_stale_expected, v_lineage
  );

  SELECT * INTO v_legacy_actions_snapshot FROM append_research_snapshot(
    'corporate_action', '{"security":"WU21-LEGACY","action_state":"none"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_legacy_cycle FROM publish_post_close_cycle(
    '2026-09-02', clock_timestamp() - interval '2 hours', clock_timestamp(),
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-legacy-corporate-actions',
        'snapshot_id', v_legacy_actions_snapshot.snapshot_id::text,
        'source', 'eod_corporate_actions', 'state', 'complete',
        'dependency_scope', jsonb_build_array('corporate_actions')
      )
    ), v_lineage
  );

  SELECT * INTO v_complete_security_decision FROM assess_research_cycle_consumer(
    v_complete.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_complete_options_decision FROM assess_research_cycle_consumer(
    v_complete.manifest_id, v_options_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_degraded_security_decision FROM assess_research_cycle_consumer(
    v_degraded.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_degraded_options_decision FROM assess_research_cycle_consumer(
    v_degraded.manifest_id, v_options_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_stale_security_decision FROM assess_research_cycle_consumer(
    v_stale.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_stale_options_decision FROM assess_research_cycle_consumer(
    v_stale.manifest_id, v_options_consumer.consumer_key, clock_timestamp(), v_lineage
  );

  SELECT * INTO v_incomplete_security_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-INCOMPLETE","close":103,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_incomplete FROM record_research_cycle_manifest(
    'wu21-incomplete-cycle', 'event_driven', v_incomplete_security_snapshot.receipt_time,
    2, 1, 'incomplete', 'incomplete',
    NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-incomplete-security', 'snapshot_id', v_incomplete_security_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      ),
      jsonb_build_object(
        'snapshot_key', 'WU21-incomplete-options', 'completion_state', 'failed', 'evidence_state', 'failed'
      )
    ), v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_incomplete.manifest_id, 'WU21-incomplete-security', 'security_daily', 'available', NULL, v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_incomplete.manifest_id, 'WU21-incomplete-options', 'options', 'blocked',
    'incomplete options evidence', v_lineage
  );

  SELECT * INTO v_failed_security_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-FAILED","close":104,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_failed FROM record_research_cycle_manifest(
    'wu21-failed-cycle', 'event_driven', v_failed_security_snapshot.receipt_time,
    2, 1, 'failed', 'failed',
    NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-failed-security', 'snapshot_id', v_failed_security_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      ),
      jsonb_build_object(
        'snapshot_key', 'WU21-failed-options', 'completion_state', 'failed', 'evidence_state', 'failed'
      )
    ), v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_failed.manifest_id, 'WU21-failed-security', 'security_daily', 'available', NULL, v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_failed.manifest_id, 'WU21-failed-options', 'options', 'blocked',
    'failed options evidence', v_lineage
  );

  SELECT * INTO v_incomplete_security_decision FROM assess_research_cycle_consumer(
    v_incomplete.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_incomplete_options_decision FROM assess_research_cycle_consumer(
    v_incomplete.manifest_id, v_options_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_failed_security_decision FROM assess_research_cycle_consumer(
    v_failed.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  SELECT * INTO v_failed_options_decision FROM assess_research_cycle_consumer(
    v_failed.manifest_id, v_options_consumer.consumer_key, clock_timestamp(), v_lineage
  );

  v_results := jsonb_build_object(
    'typed_consumers_bound', v_security_consumer.coverage_stage = 'research_candidate'
      AND v_options_consumer.decision_purpose = 'new_exposure',
    'legacy_post_close_scope_preserved', v_legacy_cycle.publication_state = 'complete'
      AND EXISTS (
        SELECT 1 FROM research_post_close_cycle_dependency
        WHERE cycle_id = v_legacy_cycle.cycle_id
          AND dependency_scope @> '["corporate_actions"]'::jsonb
      ),
    'complete_scopes_available', v_complete_security_decision.decision_state = 'available'
      AND v_complete_options_decision.decision_state = 'available',
    'degraded_compatible_restricted', v_degraded_security_decision.decision_state = 'restricted'
      AND v_degraded_security_decision.blocked_scopes = '[]'::jsonb,
    'degraded_incompatible_blocked', v_degraded_options_decision.decision_state = 'blocked'
      AND v_degraded_options_decision.blocked_scopes @> '["options"]'::jsonb,
    'incomplete_dependent_blocked', v_incomplete_options_decision.decision_state = 'blocked'
      AND v_incomplete_options_decision.blocked_scopes @> '["options"]'::jsonb,
    'incomplete_independent_continues', v_incomplete_security_decision.decision_state = 'available',
    'failed_dependent_blocked', v_failed_options_decision.decision_state = 'blocked'
      AND v_failed_options_decision.blocked_scopes @> '["options"]'::jsonb,
    'failed_independent_continues', v_failed_security_decision.decision_state = 'available',
    'stale_new_exposure_blocked', v_stale_options_decision.decision_state = 'blocked'
      AND v_stale_options_decision.decision_reason->>'stale_interval' = 'active',
    'stale_research_restricted', v_stale_security_decision.decision_state = 'restricted'
      AND v_stale_security_decision.decision_reason->>'stale_interval' = 'active',
    'blocked_consumer_gate_raises', false,
    'compatible_consumer_gate_allows', false,
    'restricted_consumer_gate_allows', false,
    'decisions_bind_profiles', v_complete_security_decision.profile_resolution_id IS NOT NULL
      AND v_complete_options_decision.profile_resolution_id IS NOT NULL,
    'scope_effect_mismatch_rejected', false,
    'scope_effect_source_mismatch_rejected', false,
    'post_close_scope_ledger_exclusive', false,
    'post_close_scope_source_mismatch_rejected', false,
    'conflicting_scope_effects_rejected', false,
    'no_proven_scope_effects_rejected', false,
    'historical_effects_excluded', false,
    'profile_scope_policy_rejected', false,
    'unregistered_scope_rejected', false,
    'late_snapshot_rejected', false,
    'inconsistent_manifest_rejected', false,
    'future_cycle_rejected', false,
    'unpublished_post_close_rejected', false,
    'consumer_direct_insert_blocked', false,
    'consumer_delete_blocked', false,
    'decision_direct_insert_blocked', false,
    'decision_update_blocked', false,
    'consumer_update_blocked', false,
    'decision_truncate_blocked', false,
    'scope_effect_direct_insert_blocked', false,
    'scope_effect_update_blocked', false,
    'scope_effect_truncate_blocked', false
  );

  BEGIN
    SELECT * INTO v_gate_decision FROM require_research_cycle_consumer_access(
      v_degraded.manifest_id, v_options_consumer.consumer_key, clock_timestamp(), v_lineage
    );
    RAISE EXCEPTION 'probe accepted blocked downstream use';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%is blocked for downstream use%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('blocked_consumer_gate_raises', true);
  END;

  SELECT * INTO v_gate_decision FROM require_research_cycle_consumer_access(
    v_incomplete.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  v_results := v_results || jsonb_build_object(
    'compatible_consumer_gate_allows', v_gate_decision.decision_state = 'available'
  );

  SELECT * INTO v_gate_decision FROM require_research_cycle_consumer_access(
    v_degraded.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
  );
  v_results := v_results || jsonb_build_object(
    'restricted_consumer_gate_allows', v_gate_decision.decision_state = 'restricted'
  );

  BEGIN
    PERFORM register_research_cycle_consumer(
      'wu21-invalid-options-scope', 'trade_eligible', 'options_eligible', 'new_exposure',
      '["security_daily"]'::jsonb, v_lineage
    );
    RAISE EXCEPTION 'probe accepted an options consumer without its required scope';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%omit the profile-required scope set%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('profile_scope_policy_rejected', true);
  END;

  BEGIN
    PERFORM register_research_cycle_consumer(
      'wu21-unregistered-scope', 'research_candidate', 'stock_eligible', 'research',
      '["news_feed"]'::jsonb, v_lineage
    );
    RAISE EXCEPTION 'probe accepted an unregistered consumer dependency scope';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%contain an unregistered scope%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unregistered_scope_rejected', true);
  END;

  BEGIN
    PERFORM assess_research_cycle_consumer(
      v_complete.manifest_id, v_security_consumer.consumer_key, v_complete.published_at, v_lineage
    );
    RAISE EXCEPTION 'probe accepted evidence recorded after the historical as-of time';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%has no proven scope effects%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('historical_effects_excluded', true);
  END;

  BEGIN
    PERFORM record_research_cycle_scope_effect(
      v_complete.manifest_id, 'WU21-complete-security', 'security_daily', 'available', NULL, v_lineage
    );
    RAISE EXCEPTION 'probe accepted a second scope ledger for a post-close cycle';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%sourced from the dependency ledger%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('post_close_scope_ledger_exclusive', true);
  END;

  SELECT * INTO v_late_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-LATE","close":107,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_late FROM record_research_cycle_manifest(
    'wu21-late-cycle', 'event_driven', v_late_snapshot.receipt_time - interval '1 minute',
    1, 1, 'complete', 'complete', NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-late-security', 'snapshot_id', v_late_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      )
    ), v_lineage
  );
  BEGIN
    PERFORM record_research_cycle_scope_effect(
      v_late.manifest_id, 'WU21-late-security', 'security_daily', 'available', NULL, v_lineage
    );
    RAISE EXCEPTION 'probe accepted snapshot evidence received after the cycle as-of';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%received after the cycle as-of%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('late_snapshot_rejected', true);
  END;

  SELECT * INTO v_inconsistent FROM record_research_cycle_manifest(
    'wu21-inconsistent-cycle', 'event_driven', v_now, 1, 0, 'complete', 'failed',
    NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-inconsistent-security', 'snapshot_id', v_security_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      )
    ), v_lineage
  );
  PERFORM set_config('market_mate.cycle_scope_effect_write', 'on', true);
  INSERT INTO research_cycle_scope_effect (
    manifest_id, snapshot_key, scope_key, effect_state, effect_reason,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_inconsistent.manifest_id, 'WU21-inconsistent-security', 'security_daily', 'available',
    NULL, v_lineage, clock_timestamp(), 'local_research'
  );
  PERFORM set_config('market_mate.cycle_scope_effect_write', 'off', true);
  BEGIN
    PERFORM assess_research_cycle_consumer(
      v_inconsistent.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
    );
    RAISE EXCEPTION 'probe accepted inconsistent cycle manifest metadata';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%metadata is inconsistent%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('inconsistent_manifest_rejected', true);
  END;

  SELECT * INTO v_future_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-FUTURE","close":108,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_future FROM record_research_cycle_manifest(
    'wu21-future-cycle', 'event_driven', clock_timestamp() + interval '1 hour',
    1, 1, 'complete', 'complete', NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-future-security', 'snapshot_id', v_future_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      )
    ), v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_future.manifest_id, 'WU21-future-security', 'security_daily', 'available', NULL, v_lineage
  );
  BEGIN
    PERFORM assess_research_cycle_consumer(
      v_future.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
    );
    RAISE EXCEPTION 'probe accepted a future cycle before its cycle as-of';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%not available at the requested assessment as-of%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('future_cycle_rejected', true);
  END;

  SELECT * INTO v_unpublished FROM record_research_cycle_manifest(
    'wu21-unpublished-post-close', 'post_close', clock_timestamp() - interval '1 second',
    1, 1, 'complete', 'complete', NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-unpublished-security', 'snapshot_id', v_security_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      )
    ), v_lineage
  );
  PERFORM set_config('market_mate.cycle_scope_effect_write', 'on', true);
  INSERT INTO research_cycle_scope_effect (
    manifest_id, snapshot_key, scope_key, effect_state, effect_reason,
    source_lineage, receipt_time, record_environment
  ) VALUES (
    v_unpublished.manifest_id, 'WU21-unpublished-security', 'security_daily', 'available',
    NULL, v_lineage, clock_timestamp(), 'local_research'
  );
  PERFORM set_config('market_mate.cycle_scope_effect_write', 'off', true);
  BEGIN
    PERFORM assess_research_cycle_consumer(
      v_unpublished.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
    );
    RAISE EXCEPTION 'probe accepted an unpublished post-close cycle';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%has no authoritative post-close cycle%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('unpublished_post_close_rejected', true);
  END;

  SELECT * INTO v_bad_post_close_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-BAD-POST-CLOSE","close":106,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  BEGIN
    PERFORM publish_post_close_cycle(
      '2026-09-01', v_bad_post_close_snapshot.receipt_time - interval '1 minute',
      v_bad_post_close_snapshot.receipt_time + interval '1 minute',
      jsonb_build_array(
        jsonb_build_object(
          'snapshot_key', 'WU21-bad-post-close',
          'snapshot_id', v_bad_post_close_snapshot.snapshot_id::text,
          'source', 'eod_prices', 'state', 'complete',
          'dependency_scope', jsonb_build_array('options')
        )
      ), v_lineage
    );
    RAISE EXCEPTION 'probe accepted options scope for an eod_price post-close snapshot';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%not proven by snapshot kind%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('post_close_scope_source_mismatch_rejected', true);
  END;

  BEGIN
    PERFORM record_research_cycle_scope_effect(
      v_incomplete.manifest_id, 'WU21-incomplete-options', 'options', 'available', NULL, v_lineage
    );
    RAISE EXCEPTION 'probe accepted an available effect for failed evidence';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%cannot be marked available%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('scope_effect_mismatch_rejected', true);
  END;

  BEGIN
    PERFORM record_research_cycle_scope_effect(
      v_incomplete.manifest_id, 'WU21-incomplete-security', 'options', 'available', NULL, v_lineage
    );
    RAISE EXCEPTION 'probe accepted a scope unrelated to the complete snapshot kind';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%not proven by snapshot kind%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('scope_effect_source_mismatch_rejected', true);
  END;

  SELECT * INTO v_empty FROM record_research_cycle_manifest(
    'wu21-empty-cycle', 'event_driven', v_now, 1, 0, 'pending', 'incomplete',
    NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-empty', 'completion_state', 'pending', 'evidence_state', 'incomplete'
      )
    ), v_lineage
  );
  BEGIN
    PERFORM assess_research_cycle_consumer(
      v_empty.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
    );
    RAISE EXCEPTION 'probe accepted a cycle without proven scope effects';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%has no proven scope effects%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('no_proven_scope_effects_rejected', true);
  END;

  SELECT * INTO v_conflict_security_snapshot FROM append_research_snapshot(
    'eod_price', '{"security":"WU21-CONFLICT","close":105,"observation_state":"current"}'::jsonb,
    v_lineage, NULL, NULL
  );
  SELECT * INTO v_conflict FROM record_research_cycle_manifest(
    'wu21-conflict-cycle', 'event_driven', v_conflict_security_snapshot.receipt_time,
    2, 1, 'incomplete', 'incomplete',
    NULL, NULL, NULL, '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object(
        'snapshot_key', 'WU21-conflict-available', 'snapshot_id', v_conflict_security_snapshot.snapshot_id::text,
        'completion_state', 'complete', 'evidence_state', 'complete'
      ),
      jsonb_build_object(
        'snapshot_key', 'WU21-conflict-blocked', 'completion_state', 'failed', 'evidence_state', 'failed'
      )
    ), v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_conflict.manifest_id, 'WU21-conflict-available', 'security_daily', 'available', NULL, v_lineage
  );
  PERFORM record_research_cycle_scope_effect(
    v_conflict.manifest_id, 'WU21-conflict-blocked', 'security_daily', 'blocked',
    'conflicting security evidence', v_lineage
  );
  BEGIN
    PERFORM assess_research_cycle_consumer(
      v_conflict.manifest_id, v_security_consumer.consumer_key, clock_timestamp(), v_lineage
    );
    RAISE EXCEPTION 'probe accepted conflicting scope effects';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%has conflicting scope effects%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('conflicting_scope_effects_rejected', true);
  END;

  BEGIN
    INSERT INTO research_cycle_consumer_contract (
      consumer_key, coverage_stage, coverage_capability, decision_purpose,
      required_dependency_scopes, source_lineage, receipt_time, record_environment
    ) VALUES (
      'WU21-direct-consumer', 'research_candidate', 'stock_eligible', 'research',
      '["security_daily"]'::jsonb, v_lineage, clock_timestamp(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted a directly inserted cycle consumer';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%must be registered through register_research_cycle_consumer%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('consumer_direct_insert_blocked', true);
  END;

  BEGIN
    DELETE FROM research_cycle_consumer_contract
    WHERE consumer_key = v_security_consumer.consumer_key;
    RAISE EXCEPTION 'probe corrupted: cycle consumer contract was deletable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('consumer_delete_blocked', true);
  END;

  BEGIN
    INSERT INTO research_cycle_scope_decision (
      manifest_id, consumer_contract_id, profile_resolution_id, as_of_at,
      decision_state, required_scopes, available_scopes, blocked_scopes,
      decision_reason, source_lineage, receipt_time, record_environment
    ) VALUES (
      v_complete.manifest_id, v_security_consumer.consumer_id, v_complete_security_decision.profile_resolution_id,
      clock_timestamp(), 'available', '["security_daily"]'::jsonb, '["security_daily"]'::jsonb,
      '[]'::jsonb, '{}'::jsonb, v_lineage, clock_timestamp(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted a directly inserted cycle scope decision';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%must be recorded through assess_research_cycle_consumer%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('decision_direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE research_cycle_scope_decision
       SET decision_state = 'available'
     WHERE decision_id = v_complete_options_decision.decision_id;
    RAISE EXCEPTION 'probe corrupted: cycle scope decision was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('decision_update_blocked', true);
  END;

  BEGIN
    UPDATE research_cycle_consumer_contract
       SET decision_purpose = 'risk_reduction'
     WHERE consumer_key = v_security_consumer.consumer_key;
    RAISE EXCEPTION 'probe corrupted: cycle consumer contract was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('consumer_update_blocked', true);
  END;

  BEGIN
    TRUNCATE research_cycle_scope_decision;
    RAISE EXCEPTION 'probe corrupted: cycle scope decisions were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('decision_truncate_blocked', true);
  END;

  BEGIN
    INSERT INTO research_cycle_scope_effect (
      manifest_id, snapshot_key, scope_key, effect_state, effect_reason,
      source_lineage, receipt_time, record_environment
    ) VALUES (
      v_incomplete.manifest_id, 'WU21-incomplete-security', 'security_daily', 'available',
      NULL, v_lineage, clock_timestamp(), 'local_research'
    );
    RAISE EXCEPTION 'probe accepted a directly inserted cycle scope effect';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%must be recorded through record_research_cycle_scope_effect%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('scope_effect_direct_insert_blocked', true);
  END;

  BEGIN
    UPDATE research_cycle_scope_effect
       SET effect_reason = 'tampered'
     WHERE manifest_id = v_incomplete.manifest_id
       AND snapshot_key = 'WU21-incomplete-options'
       AND scope_key = 'options';
    RAISE EXCEPTION 'probe corrupted: cycle scope effect was mutable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('scope_effect_update_blocked', true);
  END;

  BEGIN
    TRUNCATE research_cycle_scope_effect;
    RAISE EXCEPTION 'probe corrupted: cycle scope effects were truncatable';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
      v_results := v_results || jsonb_build_object('scope_effect_truncate_blocked', true);
  END;

  INSERT INTO wu21_probe_result (result) VALUES (v_results);
END
$probe$;
