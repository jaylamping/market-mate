-- Isolated, rollback-only mechanism probe for PR2 Institutional Memory
-- admission + containment (wayfinder map #171, decision #173). Run as
-- migration owner after 0097. Exercises propose/admit plus suspend,
-- supersede, contaminate, expire, scoped retrieval, and the pinned-review
-- helper, including failure rows. No outbound network calls; no cost, route,
-- or execution authority is touched. Assignments and source artifacts are
-- admitted through the 0096 workflow functions; the probe never admits
-- capacity or dispatches work.
-- A1: assert counter via a TEMP sequence created BEFORE the transaction.
-- Sequences are non-transactional for nextval (increments survive ROLLBACK),
-- while the creation itself commits before BEGIN, so the final SELECT after
-- ROLLBACK can report asserts_run. The acceptance script requires asserts_run
-- >= ASSERTS_MIN (number of contract_assert call sites, hardcoded there).
DROP SEQUENCE IF EXISTS pg_temp.probe_assert_seq;
CREATE TEMP SEQUENCE pg_temp.probe_assert_seq START 1;
BEGIN;
CREATE FUNCTION pg_temp.contract_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'contract assertion: %', message; END IF;
 PERFORM nextval('pg_temp.probe_assert_seq');
END $$;

DO $$ DECLARE
 lineage jsonb := '{"source":"research-memory-probe","entitlement_version":"probe-v1"}';
 base_pins jsonb := jsonb_build_object(
  'assignment_key', 'mem-base',
  'desk_role', 'strategy_incubation',
  'strategy_thesis_id', 'thesis-probe-1',
  'posture_profile', 'Balanced Investigator',
  'posture_version', 'posture-v3',
  'recipe_version', 'recipe-v2',
  'contract_runner', 'momentum_v1',
  'persona_id', 'persona-scout-7',
  'persona_cosmetic', true,
  'expires_at', '2030-06-01T00:00:00Z');
 a_prop_id uuid; a_crit_id uuid; a_sup1_id uuid; a_sup2_id uuid;
 a_other_id uuid; a_extra_id uuid;
 src1_id uuid; src2_id uuid;
 prov jsonb; sup jsonb; dis jsonb;
 bad_prov jsonb; bad_sup jsonb;
 l1 research_lesson%ROWTYPE;
 l1_again research_lesson%ROWTYPE;
 old_tz text;
BEGIN
  -- Pure provenance validator: full lineage accepted, gaps rejected.
  -- S2: fourteen keys including critiquing session/model.
  prov := jsonb_build_object(
   'proposing_assignment_id', '11111111-1111-4111-8111-111111111111',
   'proposing_run_key', 'run-p1',
   'critiquing_assignment_id', '22222222-2222-4222-8222-222222222222',
   'critiquing_run_key', 'run-c1',
   'provider_id', 'probe-provider',
   'provider_session', 'sess-pure-1',
   'model_id', 'probe-model-a',
   'critiquing_provider_session', 'sess-pure-critic-1',
   'critiquing_model_id', 'probe-model-critic',
   'config_revision', 3,
   'recipe_version', 'recipe-v2',
   'contract_runner', 'momentum_v1',
   'source_artifact_ids', jsonb_build_array('66666666-6666-4666-8666-666666666666'),
   'shared_dependencies', jsonb_build_array('shared-dep-1'));
  PERFORM pg_temp.contract_assert(research_lesson_provenance_is_complete(prov), 'pure_provenance_accepts_full_lineage');
  bad_prov := prov || '{"source_artifact_ids":[]}';
  PERFORM pg_temp.contract_assert(NOT research_lesson_provenance_is_complete(bad_prov), 'pure_provenance_rejects_missing_lineage');
  bad_prov := prov || '{"model_id":"  "}';
  PERFORM pg_temp.contract_assert(NOT research_lesson_provenance_is_complete(bad_prov), 'pure_provenance_rejects_missing_lineage');
  bad_prov := prov || '{"critiquing_assignment_id":"11111111-1111-4111-8111-111111111111"}';
  PERFORM pg_temp.contract_assert(NOT research_lesson_provenance_is_complete(bad_prov), 'pure_provenance_rejects_missing_lineage');
  -- S2: missing critiquing session/model rejected.
  bad_prov := prov - 'critiquing_provider_session';
  PERFORM pg_temp.contract_assert(NOT research_lesson_provenance_is_complete(bad_prov), 'pure_provenance_rejects_missing_lineage');
  bad_prov := prov || '{"critiquing_model_id":"  "}';
  PERFORM pg_temp.contract_assert(NOT research_lesson_provenance_is_complete(bad_prov), 'pure_provenance_rejects_missing_lineage');

  -- Pure support validator + disjointness: self-review, shared sessions,
  -- and repeats collapse and never corroborate. S2: session/model checked
  -- against BOTH proposing and critiquing coordinates.
  sup := jsonb_build_array(
   jsonb_build_object('assignment_id', '33333333-3333-4333-8333-333333333333', 'run_key', 'run-s1', 'provider_session', 'sess-pure-a', 'model_id', 'probe-model-b'),
   jsonb_build_object('assignment_id', '44444444-4444-4444-8444-444444444444', 'run_key', 'run-s2', 'provider_session', 'sess-pure-b', 'model_id', 'probe-model-c'));
  PERFORM pg_temp.contract_assert(research_lesson_support_is_wellformed(sup), 'pure_support_accepts_disjoint');
  PERFORM pg_temp.contract_assert(research_lesson_support_is_disjoint(prov, sup), 'pure_support_accepts_disjoint');
  bad_sup := jsonb_build_array(
   jsonb_build_object('assignment_id', '11111111-1111-4111-8111-111111111111', 'run_key', 'run-x1', 'provider_session', 'sess-pure-x', 'model_id', 'probe-model-z'));
  PERFORM pg_temp.contract_assert(NOT research_lesson_support_is_disjoint(prov, bad_sup), 'pure_support_rejects_self_review');
  bad_sup := jsonb_build_array(
   jsonb_build_object('assignment_id', '33333333-3333-4333-8333-333333333333', 'run_key', 'run-x2', 'provider_session', 'sess-pure-1', 'model_id', 'probe-model-z'));
  PERFORM pg_temp.contract_assert(NOT research_lesson_support_is_disjoint(prov, bad_sup), 'pure_support_rejects_shared_session');
  -- S2: supporter reusing the critic session/model with a fresh
  -- assignment/run must fail (fresh assignment/run, shared critic coords).
  bad_sup := jsonb_build_array(
   jsonb_build_object('assignment_id', '55555555-5555-4555-8555-555555555555', 'run_key', 'run-fresh-x1', 'provider_session', 'sess-pure-critic-1', 'model_id', 'probe-model-z'));
  PERFORM pg_temp.contract_assert(NOT research_lesson_support_is_disjoint(prov, bad_sup), 'reject_critic_session_model_reuse');
  bad_sup := jsonb_build_array(
   jsonb_build_object('assignment_id', '55555555-5555-4555-8555-555555555555', 'run_key', 'run-fresh-x2', 'provider_session', 'sess-fresh-x2', 'model_id', 'probe-model-critic'));
  PERFORM pg_temp.contract_assert(NOT research_lesson_support_is_disjoint(prov, bad_sup), 'reject_critic_session_model_reuse');
  bad_sup := jsonb_build_array(
   jsonb_build_object('assignment_id', '33333333-3333-4333-8333-333333333333', 'run_key', 'run-x3', 'provider_session', 'sess-pure-x', 'model_id', 'probe-model-y'),
   jsonb_build_object('assignment_id', '33333333-3333-4333-8333-333333333333', 'run_key', 'run-x4', 'provider_session', 'sess-pure-y', 'model_id', 'probe-model-z'));
  PERFORM pg_temp.contract_assert(NOT research_lesson_support_is_disjoint(prov, bad_sup), 'pure_support_rejects_repeated_assignment');

 -- Pure scope validator: all three typed scopes accepted, malformed rejected.
 PERFORM pg_temp.contract_assert(research_lesson_scope_is_valid('global', '{}'), 'pure_scope_accepts_all_types');
 PERFORM pg_temp.contract_assert(research_lesson_scope_is_valid('role_posture', '{"desk_role":"strategy_incubation","posture_profile":"Balanced Investigator"}'), 'pure_scope_accepts_all_types');
 PERFORM pg_temp.contract_assert(research_lesson_scope_is_valid('method_data', '{"contract_runner":"momentum_v1","recipe_version":"recipe-v2"}'), 'pure_scope_accepts_all_types');
 PERFORM pg_temp.contract_assert(NOT research_lesson_scope_is_valid('team', '{}'), 'pure_scope_rejects_malformed');
 PERFORM pg_temp.contract_assert(NOT research_lesson_scope_is_valid('global', '{"sizing":"high"}'), 'pure_scope_rejects_malformed');
 PERFORM pg_temp.contract_assert(NOT research_lesson_scope_is_valid('role_posture', '{"desk_role":"strategy_incubation","posture_profile":"Reckless Gambler"}'), 'pure_scope_rejects_malformed');

 -- Pure dissent validator: versioned dissent accepted.
 PERFORM pg_temp.contract_assert(
  research_lesson_dissent_is_wellformed('{"version":1,"entries":[{"assignment_id":"22222222-2222-4222-8222-222222222222","run_key":"run-c1","note":"critic note preserved"}]}'),
  'pure_dissent_accepts_versioned');
 PERFORM pg_temp.contract_assert(
  research_lesson_dissent_is_wellformed('{"version":2,"entries":[]}'),
  'pure_dissent_accepts_versioned');

  -- Pure guidance gate: methods guidance admitted; recipe, acceptance-check,
  -- and authority semantics rejected. S3: spaced multi-word keys + plurals.
  PERFORM pg_temp.contract_assert(
   research_lesson_guidance_is_admissible('Prefer wider lookback windows when session noise is high; keep quantile counts pinned.'),
   'pure_guidance_admits_methods');
  PERFORM pg_temp.contract_assert(
   NOT research_lesson_guidance_is_admissible('Promote recipe-v3 to required and mark the strategy paper eligible.'),
   'pure_guidance_rejects_gate_change');
  PERFORM pg_temp.contract_assert(
   NOT research_lesson_guidance_is_admissible('Change the acceptance check so failing runs pass and enable live trading.'),
   'pure_guidance_rejects_gate_change');
  -- S3 regressions: spaced + plural forms must be rejected.
  PERFORM pg_temp.contract_assert(
   NOT research_lesson_guidance_is_admissible('Change execution environment to production.'),
   'pure_guidance_rejects_spaced_keys');
  PERFORM pg_temp.contract_assert(
   NOT research_lesson_guidance_is_admissible('Use updated recipes for momentum.'),
   'pure_guidance_rejects_plural');
  PERFORM pg_temp.contract_assert(
   NOT research_lesson_guidance_is_admissible('Review lifecycle state transitions.'),
   'pure_guidance_rejects_spaced_keys');
  PERFORM pg_temp.contract_assert(
   NOT research_lesson_guidance_is_admissible('Hand orders to brokers daily.'),
   'pure_guidance_rejects_plural');

 -- Assignments: proposer, critic, two supporters, a scope outsider with a
 -- different role/posture/recipe, and a fresh supporter for duplicates.
 a_prop_id := (admit_research_assignment(base_pins || '{"assignment_key":"mem-prop","desk_role":"quantitative_research_and_experimentation"}', lineage)).assignment_id;
 a_crit_id := (admit_research_assignment(base_pins || '{"assignment_key":"mem-crit","desk_role":"economic_evaluation_and_challenge","posture_profile":"Skeptical Reviewer"}', lineage)).assignment_id;
 a_sup1_id := (admit_research_assignment(base_pins || '{"assignment_key":"mem-sup1"}', lineage)).assignment_id;
 a_sup2_id := (admit_research_assignment(base_pins || '{"assignment_key":"mem-sup2","desk_role":"data_and_feature_research","posture_profile":"Conservative Verifier"}', lineage)).assignment_id;
 a_other_id := (admit_research_assignment(base_pins || '{"assignment_key":"mem-other","desk_role":"portfolio_and_capital_efficiency","posture_profile":"Passive Observer","recipe_version":"recipe-v9"}', lineage)).assignment_id;
 a_extra_id := (admit_research_assignment(base_pins || '{"assignment_key":"mem-extra","desk_role":"market_intelligence_and_thesis"}', lineage)).assignment_id;

 -- Canonical source artifacts: one from the proposer/critic pair, one from
 -- an uninvolved author (for the own-lineage support check).
 src1_id := (record_research_artifact_manifest(
  artifact_key_value := 'mem-src1',
  assignment_id_value := a_prop_id, run_key_value := 'run-p1',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a_prop_id, author_run_key_value := 'run-p1',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a_crit_id, reviewer_run_key_value := 'run-c1',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := '{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":4,"one_way_cost_bps":10,"borrow_bps_per_session":2}',
  artifact_value := '{"engine":"momentum_v1","outcome":"diagnostic_only","mean_net_bps":12}',
  dissent_preserved_value := true, source_lineage_value := lineage)).artifact_id;
 src2_id := (record_research_artifact_manifest(
  artifact_key_value := 'mem-src2',
  assignment_id_value := a_sup1_id, run_key_value := 'run-s1',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a_sup1_id, author_run_key_value := 'run-s1',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-gamma',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL,
  reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := '{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":4,"one_way_cost_bps":10,"borrow_bps_per_session":2}',
  artifact_value := '{"engine":"momentum_v1","outcome":"diagnostic_only","mean_net_bps":12}',
  dissent_preserved_value := false, source_lineage_value := lineage)).artifact_id;

  -- Shared builders for the lesson rows below. S2: include critiquing
  -- session/model so support disjointness covers both lineages.
  prov := jsonb_build_object(
   'proposing_assignment_id', a_prop_id::text,
   'proposing_run_key', 'run-p1',
   'critiquing_assignment_id', a_crit_id::text,
   'critiquing_run_key', 'run-c1',
   'provider_id', 'probe-provider',
   'provider_session', 'sess-prop-1',
   'model_id', 'probe-model-a',
   'critiquing_provider_session', 'sess-crit-1',
   'critiquing_model_id', 'probe-model-critic',
   'config_revision', 3,
   'recipe_version', 'recipe-v2',
   'contract_runner', 'momentum_v1',
   'source_artifact_ids', jsonb_build_array(src1_id::text),
   'shared_dependencies', jsonb_build_array('shared-dep-1'));
 sup := jsonb_build_array(
  jsonb_build_object('assignment_id', a_sup1_id::text, 'run_key', 'run-s1', 'provider_session', 'sess-sup-1', 'model_id', 'probe-model-b'),
  jsonb_build_object('assignment_id', a_sup2_id::text, 'run_key', 'run-s2', 'provider_session', 'sess-sup-2', 'model_id', 'probe-model-c'));
 dis := jsonb_build_object('version', 1, 'entries',
  jsonb_build_array(jsonb_build_object('assignment_id', a_crit_id::text, 'run_key', 'run-c1', 'note', 'critic note preserved')));

 -- Propose the global lesson; the genesis event is recorded with a NULL
 -- from_status and a static reason.
 l1 := propose_research_lesson(
  lesson_key_value := 'mem-l1',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows when session noise is high; keep quantile counts pinned.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z',
  canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(l1.status = 'proposed' AND l1.admitted_at IS NULL, 'propose_lesson');
 PERFORM pg_temp.contract_assert(
  (SELECT count(*) FROM research_lesson_status_event WHERE lesson_key = 'mem-l1') = 1
  AND EXISTS (SELECT 1 FROM research_lesson_status_event WHERE lesson_key = 'mem-l1' AND from_status IS NULL AND to_status = 'proposed' AND reason = 'lesson_proposed'),
  'propose_lesson');
 -- Audit JSON renders the expiry as a canonical UTC instant.
 PERFORM pg_temp.contract_assert(
  EXISTS (SELECT 1 FROM audit_event WHERE event_type = 'research.research_lesson_proposed' AND payload->>'lesson_key' = 'mem-l1' AND (payload->>'expires_at') LIKE '%Z'),
  'propose_lesson');

 -- Full-input idempotency on the key, including across TimeZones.
 l1_again := propose_research_lesson(
  lesson_key_value := 'mem-l1',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows when session noise is high; keep quantile counts pinned.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z',
  canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(l1_again.lesson_id = l1.lesson_id, 'propose_idempotent');
 SELECT current_setting('TimeZone') INTO old_tz;
 PERFORM set_config('TimeZone', 'America/New_York', true);
 l1_again := propose_research_lesson(
  lesson_key_value := 'mem-l1',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows when session noise is high; keep quantile counts pinned.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z',
  canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(l1_again.lesson_id = l1.lesson_id, 'propose_timezone_idempotent');
 PERFORM set_config('TimeZone', old_tz, true);

  -- Failure rows at the proposal boundary. Each rejection is asserted inside
  -- its handler, so a silent acceptance aborts the probe before the name is
  -- ever recorded. A6: 3 key rows also match the SQLSTATE message text
  -- (SQLERRM LIKE) to prove the right condition fired; others stay as
  -- SQLSTATE-only by design (documented here).
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-l1', scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer narrower lookback windows instead.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted changed guidance on re-propose';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(SQLERRM LIKE '%already proposed with different inputs%', 'reject_changed_inputs'); END;
 BEGIN PERFORM propose_research_lesson(
  lesson_key_value := 'mem-badlineage', scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov || '{"model_id":""}', support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted missing lineage';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_missing_lineage'); END;
 BEGIN PERFORM propose_research_lesson(
  lesson_key_value := 'mem-nondisjoint', scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov,
  support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_prop_id::text, 'run_key', 'run-x1', 'provider_session', 'sess-x1', 'model_id', 'probe-model-z')),
  dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted proposer as support';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_nondisjoint_support'); END;
 BEGIN PERFORM propose_research_lesson(
  lesson_key_value := 'mem-selfreview', scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov,
  support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_crit_id::text, 'run_key', 'run-x2', 'provider_session', 'sess-x2', 'model_id', 'probe-model-z')),
  dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted critic as support';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_self_review_support'); END;
 BEGIN PERFORM propose_research_lesson(
  lesson_key_value := 'mem-shareddession', scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov,
  support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_sup1_id::text, 'run_key', 'run-x3', 'provider_session', 'sess-prop-1', 'model_id', 'probe-model-z')),
  dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted shared provider session';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_shared_session_support'); END;
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-gatechange', scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Promote recipe-v3 to required and mark the strategy paper eligible.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted gate-change guidance';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(SQLERRM LIKE '%touches recipe%', 'reject_gate_change_guidance'); END;
 BEGIN PERFORM propose_research_lesson(
  lesson_key_value := 'mem-unknownassign', scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov || jsonb_build_object('proposing_assignment_id', '00000000-0000-0000-0000-000000000000'),
  support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted unknown proposing assignment';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_unknown_provenance_assignment'); END;
 BEGIN PERFORM propose_research_lesson(
  lesson_key_value := 'mem-unknownartifact', scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov || jsonb_build_object('source_artifact_ids', jsonb_build_array('00000000-0000-0000-0000-000000000000')),
  support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted unknown source artifact';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_unknown_source_artifact'); END;
  -- Own-lineage support: the supporter authored a canonical source artifact
  -- without being the proposer or critic, so coordinate checks pass but the
  -- authoritative authorship closure rejects it.
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-ownlineage', scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows.',
   provenance_value := prov || jsonb_build_object('source_artifact_ids', jsonb_build_array(src2_id::text)),
   support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_sup1_id::text, 'run_key', 'run-x4', 'provider_session', 'sess-x4', 'model_id', 'probe-model-z')),
   dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted own-lineage support';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(SQLERRM LIKE '%reviews its own lineage%', 'reject_own_lineage_support'); END;
  -- S2 (proposal boundary): supporter reusing the critic session/model with a
  -- fresh assignment/run must be rejected end-to-end (pure validator already
  -- covers the function; this covers propose).
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-criticreuse', scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows.',
   provenance_value := prov,
   support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_extra_id::text, 'run_key', 'run-fresh-c1', 'provider_session', 'sess-crit-1', 'model_id', 'probe-model-z')),
   dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted critic session reuse';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_critic_session_model_reuse'); END;
  -- S7: idempotency includes source_lineage; re-proposing mem-l1 with a
  -- different lineage must be rejected (not silently idempotent).
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-l1', scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows when session noise is high; keep quantile counts pinned.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := '{"source":"research-memory-probe","entitlement_version":"probe-v2"}');
   RAISE EXCEPTION 'accepted changed source_lineage on re-propose';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_changed_source_lineage'); END;
END $$;

DO $$ DECLARE
 lineage jsonb := '{"source":"research-memory-probe","entitlement_version":"probe-v1"}';
 pins_prop jsonb; pins_other jsonb;
 a_prop_id uuid; a_crit_id uuid; a_sup1_id uuid; a_sup2_id uuid;
 a_other_id uuid; a_extra_id uuid;
 src1_id uuid;
 prov jsonb; sup jsonb; dis jsonb;
 l1 research_lesson%ROWTYPE;
BEGIN
 SELECT assignment_id INTO STRICT a_prop_id FROM research_assignment WHERE assignment_key = 'mem-prop';
 SELECT assignment_id INTO STRICT a_crit_id FROM research_assignment WHERE assignment_key = 'mem-crit';
 SELECT assignment_id INTO STRICT a_sup1_id FROM research_assignment WHERE assignment_key = 'mem-sup1';
 SELECT assignment_id INTO STRICT a_sup2_id FROM research_assignment WHERE assignment_key = 'mem-sup2';
 SELECT assignment_id INTO STRICT a_other_id FROM research_assignment WHERE assignment_key = 'mem-other';
 SELECT assignment_id INTO STRICT a_extra_id FROM research_assignment WHERE assignment_key = 'mem-extra';
 SELECT artifact_id INTO STRICT src1_id FROM research_artifact_manifest WHERE artifact_key = 'mem-src1';
 SELECT pins INTO STRICT pins_prop FROM research_assignment WHERE assignment_key = 'mem-prop';
 SELECT pins INTO STRICT pins_other FROM research_assignment WHERE assignment_key = 'mem-other';

  prov := jsonb_build_object(
   'proposing_assignment_id', a_prop_id::text,
   'proposing_run_key', 'run-p1',
   'critiquing_assignment_id', a_crit_id::text,
   'critiquing_run_key', 'run-c1',
   'provider_id', 'probe-provider',
   'provider_session', 'sess-prop-1',
   'model_id', 'probe-model-a',
   'critiquing_provider_session', 'sess-crit-1',
   'critiquing_model_id', 'probe-model-critic',
   'config_revision', 3,
   'recipe_version', 'recipe-v2',
   'contract_runner', 'momentum_v1',
   'source_artifact_ids', jsonb_build_array(src1_id::text),
   'shared_dependencies', jsonb_build_array('shared-dep-1'));
 sup := jsonb_build_array(
  jsonb_build_object('assignment_id', a_sup1_id::text, 'run_key', 'run-s1', 'provider_session', 'sess-sup-1', 'model_id', 'probe-model-b'),
  jsonb_build_object('assignment_id', a_sup2_id::text, 'run_key', 'run-s2', 'provider_session', 'sess-sup-2', 'model_id', 'probe-model-c'));
 dis := jsonb_build_object('version', 1, 'entries',
  jsonb_build_array(jsonb_build_object('assignment_id', a_crit_id::text, 'run_key', 'run-c1', 'note', 'critic note preserved')));

 -- Admit the global lesson; admission pins admitted_at and records the
 -- transition. Re-admission is idempotent and writes no new event.
 l1 := admit_research_lesson('mem-l1', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(l1.status = 'admitted' AND l1.admitted_at IS NOT NULL, 'admit_lesson');
 PERFORM pg_temp.contract_assert(
  (SELECT count(*) FROM research_lesson_status_event WHERE lesson_key = 'mem-l1') = 2
  AND EXISTS (SELECT 1 FROM research_lesson_status_event WHERE lesson_key = 'mem-l1' AND from_status = 'proposed' AND to_status = 'admitted' AND reason = 'admission_checks_passed'),
  'admit_lesson');
 l1 := admit_research_lesson('mem-l1', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(
  l1.status = 'admitted'
  AND (SELECT count(*) FROM research_lesson_status_event WHERE lesson_key = 'mem-l1') = 2,
  'admit_idempotent');

  BEGIN PERFORM admit_research_lesson('mem-absent', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'admitted unknown lesson';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_admit_unknown'); END;

  -- S1: containment directly from proposed must succeed (no CHECK violation).
  -- ever_admitted stays false and admitted_at stays NULL truthfully, with a
  -- status event emitted for each edge.
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-ps1',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows for proposed suspend.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  PERFORM suspend_research_lesson('mem-ps1', 're-review from proposed', a_crit_id, 'run-c1', lineage);
  PERFORM pg_temp.contract_assert(
   (SELECT status FROM research_lesson WHERE lesson_key = 'mem-ps1') = 'suspended'
   AND (SELECT admitted_at FROM research_lesson WHERE lesson_key = 'mem-ps1') IS NULL
   AND NOT (SELECT ever_admitted FROM research_lesson WHERE lesson_key = 'mem-ps1')
   AND (SELECT count(*) FROM research_lesson_status_event WHERE lesson_key = 'mem-ps1') = 2
   AND EXISTS (SELECT 1 FROM research_lesson_status_event WHERE lesson_key = 'mem-ps1' AND from_status = 'proposed' AND to_status = 'suspended'),
   'contain_proposed_suspend');
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-pc1',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows for proposed contaminate.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  PERFORM contaminate_research_lesson('mem-pc1', 'tainted from proposed', a_crit_id, 'run-c1', lineage);
  PERFORM pg_temp.contract_assert(
   (SELECT status FROM research_lesson WHERE lesson_key = 'mem-pc1') = 'contaminated'
   AND (SELECT admitted_at FROM research_lesson WHERE lesson_key = 'mem-pc1') IS NULL
   AND NOT (SELECT ever_admitted FROM research_lesson WHERE lesson_key = 'mem-pc1')
   AND EXISTS (SELECT 1 FROM research_lesson_status_event WHERE lesson_key = 'mem-pc1' AND from_status = 'proposed' AND to_status = 'contaminated'),
   'contain_proposed_contaminate');
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-pe1',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows for proposed expire.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  PERFORM expire_research_lesson('mem-pe1', a_crit_id, 'run-c1', lineage);
  PERFORM pg_temp.contract_assert(
   (SELECT status FROM research_lesson WHERE lesson_key = 'mem-pe1') = 'expired'
   AND (SELECT admitted_at FROM research_lesson WHERE lesson_key = 'mem-pe1') IS NULL
   AND NOT (SELECT ever_admitted FROM research_lesson WHERE lesson_key = 'mem-pe1')
   AND EXISTS (SELECT 1 FROM research_lesson_status_event WHERE lesson_key = 'mem-pe1' AND from_status = 'proposed' AND to_status = 'expired'),
   'contain_proposed_expire');

 -- Admission after expiry is blocked: the proposal is valid, but the admit
 -- clock has passed its freshness rule.
 PERFORM propose_research_lesson(
  lesson_key_value := 'mem-short',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := clock_timestamp() + interval '1 second',
  canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM pg_sleep(2);
 BEGIN PERFORM admit_research_lesson('mem-short', a_crit_id, 'run-c1', lineage);
  RAISE EXCEPTION 'admitted an expired proposal';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_admit_after_expiry'); END;

 -- Scoped lessons: role+posture and method+data retrieval filter by the
 -- assignment pins.
 PERFORM propose_research_lesson(
  lesson_key_value := 'mem-l3',
  scope_type_value := 'role_posture',
  scope_key_value := '{"desk_role":"quantitative_research_and_experimentation","posture_profile":"Balanced Investigator"}',
  guidance_value := 'Prefer wider lookback windows when session noise is high.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM admit_research_lesson('mem-l3', a_crit_id, 'run-c1', lineage);
 PERFORM propose_research_lesson(
  lesson_key_value := 'mem-l4',
  scope_type_value := 'method_data',
  scope_key_value := '{"contract_runner":"momentum_v1","recipe_version":"recipe-v2"}',
  guidance_value := 'Keep quantile counts pinned across sessions.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM admit_research_lesson('mem-l4', a_crit_id, 'run-c1', lineage);

 PERFORM pg_temp.contract_assert(
  EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l1'),
  'retrieve_admitted_global');
 PERFORM pg_temp.contract_assert(
  EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l3')
  AND NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_other, now()) WHERE lesson_key = 'mem-l3'),
  'retrieve_role_posture_scoped');
 PERFORM pg_temp.contract_assert(
  EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l4')
  AND NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_other, now()) WHERE lesson_key = 'mem-l4'),
  'retrieve_method_data_scoped');
 -- Freshness is evaluated at the caller instant: past expiry, the admitted
 -- lesson leaves retrieval without any status change.
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, '2031-01-01T00:00:00Z') WHERE lesson_key = 'mem-l1'),
  'retrieve_blocks_expired_at');

 -- Dissent survives admission versioned: the stored dissent still carries
 -- the critic entry under its original version.
 PERFORM pg_temp.contract_assert(
  (SELECT dissent->>'version' FROM research_lesson WHERE lesson_key = 'mem-l1') = '1'
  AND (SELECT dissent->'entries'->0->>'note' FROM research_lesson WHERE lesson_key = 'mem-l1') = 'critic note preserved',
  'dissent_versioned_preserved');

 -- Suspension leaves future retrieval and records the transition; pinned
 -- history is kept for the review helper below.
 PERFORM suspend_research_lesson('mem-l1', 'methodology under re-review', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l1')
  AND (SELECT count(*) FROM research_lesson_status_event WHERE lesson_key = 'mem-l1') = 3
  AND EXISTS (SELECT 1 FROM research_lesson_status_event WHERE lesson_key = 'mem-l1' AND from_status = 'admitted' AND to_status = 'suspended'),
  'suspend_blocks_retrieval');

 -- Supersession resolves to the successor in retrieval.
 PERFORM propose_research_lesson(
  lesson_key_value := 'mem-l2',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM admit_research_lesson('mem-l2', a_crit_id, 'run-c1', lineage);
 PERFORM propose_research_lesson(
  lesson_key_value := 'mem-l2b',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows with capped session weights.',
  provenance_value := prov, support_value := sup, dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
  source_lineage_value := lineage);
 PERFORM admit_research_lesson('mem-l2b', a_crit_id, 'run-c1', lineage);
 PERFORM supersede_research_lesson('mem-l2', 'mem-l2b', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l2')
  AND EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l2b'),
  'supersede_resolves_to_successor');

 -- Contamination requires a reason, then leaves future retrieval.
 BEGIN PERFORM contaminate_research_lesson('mem-l3', '  ', a_crit_id, 'run-c1', lineage);
  RAISE EXCEPTION 'contaminated without a reason';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  PERFORM pg_temp.contract_assert(true, 'reject_contaminate_without_reason'); END;
 PERFORM contaminate_research_lesson('mem-l3', 'source data contract withdrawn', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l3'),
  'contaminate_blocks_retrieval');

 -- Administrative expiry leaves future retrieval.
 PERFORM expire_research_lesson('mem-l4', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l4'),
  'expire_blocks_retrieval');

  -- Illegal edges fail closed: a suspended lesson cannot be admitted, and a
  -- merely proposed lesson cannot be superseded. A6: also match the message
  -- text for the admitted->proposed edge (SQLERRM LIKE) to prove the right
  -- condition fired.
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-l5',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  BEGIN PERFORM admit_research_lesson('mem-l1', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'admitted a suspended lesson';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(SQLERRM LIKE '%cannot transition%', 'reject_illegal_transition'); END;
  BEGIN PERFORM supersede_research_lesson('mem-l5', 'mem-l2b', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'superseded a proposed lesson';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_illegal_transition'); END;

  -- S4: successor must be admitted at write time; superseding onto a merely
  -- proposed successor must fail 55000 (not silently orphan).
  BEGIN PERFORM supersede_research_lesson('mem-l2b', 'mem-l5', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'superseded onto a proposed successor';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_supersede_proposed_successor'); END;
  -- S4: A->B then B->A must fail 55000 (cycle / already-superseded guard).
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-cyc-a',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows for cycle a.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  PERFORM admit_research_lesson('mem-cyc-a', a_crit_id, 'run-c1', lineage);
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-cyc-b',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows for cycle b.',
   provenance_value := prov, support_value := sup, dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  PERFORM admit_research_lesson('mem-cyc-b', a_crit_id, 'run-c1', lineage);
  PERFORM supersede_research_lesson('mem-cyc-a', 'mem-cyc-b', a_crit_id, 'run-c1', lineage);
  BEGIN PERFORM supersede_research_lesson('mem-cyc-b', 'mem-cyc-a', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'superseded into a cycle';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_supersede_cycle'); END;

  -- Successor linkage is verified: unknown and self successors raise. A6:
  -- also match the message for unknown successors.
  BEGIN PERFORM supersede_research_lesson('mem-l5', 'mem-absent', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'superseded to an unknown successor';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(SQLERRM LIKE '%not registered%', 'reject_unknown_successor'); END;
  BEGIN PERFORM supersede_research_lesson('mem-l5', 'mem-l5', a_crit_id, 'run-c1', lineage);
   RAISE EXCEPTION 'superseded to itself';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_unknown_successor'); END;

 -- Duplicates link to the canonical lesson: the duplicate is admitted but
 -- never retrieved directly, and it must not reuse canonical support.
 PERFORM propose_research_lesson(
  lesson_key_value := 'mem-dup',
  scope_type_value := 'global', scope_key_value := '{}',
  guidance_value := 'Prefer wider lookback windows with capped session weights.',
  provenance_value := prov || jsonb_build_object('proposing_assignment_id', a_other_id::text, 'proposing_run_key', 'run-o1'),
  support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_extra_id::text, 'run_key', 'run-e1', 'provider_session', 'sess-e1', 'model_id', 'probe-model-e')),
  dissent_value := dis,
  expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := 'mem-l2b',
  source_lineage_value := lineage);
 PERFORM admit_research_lesson('mem-dup', a_crit_id, 'run-c1', lineage);
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-dup')
  AND EXISTS (SELECT 1 FROM retrieve_lessons_for_assignment(pins_prop, now()) WHERE lesson_key = 'mem-l2b'),
  'duplicate_links_canonical');
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-dup2',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows with capped session weights.',
   provenance_value := prov || jsonb_build_object('proposing_assignment_id', a_other_id::text, 'proposing_run_key', 'run-o2'),
   support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_sup1_id::text, 'run_key', 'run-x5', 'provider_session', 'sess-x5', 'model_id', 'probe-model-z')),
   dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := 'mem-l2b',
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted duplicate reusing canonical support';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_duplicate_reused_support'); END;
  -- S4: duplicate onto a suspended canonical must be rejected (22023).
  -- mem-l1 is suspended at this point (suspended earlier).
  BEGIN PERFORM propose_research_lesson(
   lesson_key_value := 'mem-dup-suspended',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows for suspended canonical.',
   provenance_value := prov || jsonb_build_object('proposing_assignment_id', a_other_id::text, 'proposing_run_key', 'run-o3'),
   support_value := jsonb_build_array(jsonb_build_object('assignment_id', a_extra_id::text, 'run_key', 'run-e3', 'provider_session', 'sess-e3', 'model_id', 'probe-model-e3')),
   dissent_value := dis,
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := 'mem-l1',
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted duplicate onto suspended canonical';
  EXCEPTION WHEN SQLSTATE '22023' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_duplicate_suspended_canonical'); END;

  -- S6: pinned-review version staleness. Create a lesson with dissent
  -- version 2; pinning v1 must be flagged even though the status is admitted.
  PERFORM propose_research_lesson(
   lesson_key_value := 'mem-v2',
   scope_type_value := 'global', scope_key_value := '{}',
   guidance_value := 'Prefer wider lookback windows with version two dissent.',
   provenance_value := prov, support_value := sup,
   dissent_value := jsonb_build_object('version', 2, 'entries',
    jsonb_build_array(jsonb_build_object('assignment_id', a_crit_id::text, 'run_key', 'run-c1', 'note', 'critic note v2'))),
   expires_at_value := '2030-06-01T00:00:00Z', canonical_lesson_key_value := NULL,
   source_lineage_value := lineage);
  PERFORM admit_research_lesson('mem-v2', a_crit_id, 'run-c1', lineage);
  PERFORM pg_temp.contract_assert(
   EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-v2":1}') WHERE pinned_lesson_key = 'mem-v2' AND needs_review)
   AND NOT EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-v2":2}') WHERE needs_review),
   'pinned_review_flags_stale_version');
  -- S6: malformed pinned versions (non-integer, zero) fail closed to review.
  PERFORM pg_temp.contract_assert(
   EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-v2":0}') WHERE pinned_lesson_key = 'mem-v2' AND needs_review)
   AND EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-v2":"bad"}') WHERE pinned_lesson_key = 'mem-v2' AND needs_review),
   'pinned_review_flags_malformed');

 -- Pinned review: admitted pins stay quiet; suspended and unknown pins are
 -- flagged for explicit review, never silently re-pinned.
 PERFORM pg_temp.contract_assert(
  NOT EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-l2b":{"version":1}}') WHERE needs_review)
  AND EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-l2b":{"version":1},"mem-l1":{"version":1},"mem-unknown":{"version":1}}') WHERE pinned_lesson_key = 'mem-l1' AND current_status = 'suspended' AND needs_review)
  AND EXISTS (SELECT 1 FROM research_lesson_pinned_review('{"mem-l2b":{"version":1},"mem-l1":{"version":1},"mem-unknown":{"version":1}}') WHERE pinned_lesson_key = 'mem-unknown' AND current_status IS NULL AND needs_review),
  'pinned_review_flags');

  -- Lesson rows are transition-gated for every role, status history is never
  -- rewritten, and direct writes stay behind the workflow flag.
  BEGIN UPDATE research_lesson SET guidance = 'rewritten' WHERE lesson_key = 'mem-l1';
   RAISE EXCEPTION 'mutation accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'append_only'); END;
  BEGIN DELETE FROM research_lesson_status_event WHERE lesson_key = 'mem-l1';
   RAISE EXCEPTION 'mutation accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'append_only'); END;
  BEGIN INSERT INTO research_lesson (
   lesson_key, scope_type, scope_key, guidance, provenance, support, dissent,
   expires_at, source_lineage, receipt_time, record_environment)
  VALUES (
   'mem-direct', 'global', '{}', 'Prefer wider lookback windows.',
   prov, sup, dis,
   '2030-06-01T00:00:00Z', lineage, clock_timestamp(), 'local_research');
   RAISE EXCEPTION 'direct write accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'insert_guard'); END;
  -- S5: flag-armed row-gate coverage. With the workflow flag ON, direct
  -- history rewrites must still fail 55000 via the row-level transition
  -- guard (not just the statement-level flag gate).
  PERFORM set_config('market_mate.incubator_write', 'on', true);
  BEGIN UPDATE research_lesson SET guidance = 'rewritten-with-flag' WHERE lesson_key = 'mem-l1';
   RAISE EXCEPTION 'mutation accepted with flag';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_direct_write_with_flag'); END;
  PERFORM set_config('market_mate.incubator_write', 'off', true);
  -- S5: illegal admitted->proposed with the flag ON must still fail 55000
  -- via the legal-edge check (flag does not authorize illegal moves).
  PERFORM set_config('market_mate.incubator_write', 'on', true);
  BEGIN UPDATE research_lesson SET status = 'proposed' WHERE lesson_key = 'mem-l2b';
   RAISE EXCEPTION 'illegal transition accepted with flag';
  EXCEPTION WHEN SQLSTATE '55000' THEN
   PERFORM pg_temp.contract_assert(true, 'reject_illegal_transition_with_flag'); END;
  PERFORM set_config('market_mate.incubator_write', 'off', true);

  -- The memory surface ships dark: workers hold no execute or write grants.
  -- S5: assert ALL revoked workflow functions (minimum: propose/admit/
  -- suspend/supersede/contaminate/expire/retrieve/pinned_review).
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'propose_research_lesson(text,text,jsonb,text,jsonb,jsonb,jsonb,timestamptz,text,jsonb)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'admit_research_lesson(text,uuid,text,jsonb)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'suspend_research_lesson(text,text,uuid,text,jsonb)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'supersede_research_lesson(text,text,uuid,text,jsonb)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'contaminate_research_lesson(text,text,uuid,text,jsonb)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'expire_research_lesson(text,uuid,text,jsonb)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'retrieve_lessons_for_assignment(jsonb,timestamptz)', 'EXECUTE'),
   'no_worker_grants');
  PERFORM pg_temp.contract_assert(
   NOT has_function_privilege('incubator_runner', 'research_lesson_pinned_review(jsonb)', 'EXECUTE'),
   'no_worker_grants');
 PERFORM pg_temp.contract_assert(
  NOT has_table_privilege('incubator_runner', 'research_lesson', 'INSERT'),
  'no_worker_grants');
 PERFORM pg_temp.contract_assert(
  NOT has_table_privilege('incubator_runner', 'research_lesson_status_event', 'INSERT'),
  'no_worker_grants');
END $$;
ROLLBACK;
-- A1: asserts_run survives ROLLBACK via the TEMP sequence (non-transactional
-- nextval). The script requires asserts_run >= ASSERTS_MIN.
SELECT jsonb_build_object('probe', 'research-memory', 'passed', true,
 'asserts_run', (SELECT last_value FROM pg_temp.probe_assert_seq),
 'checks', jsonb_build_array(
 'pure_provenance_accepts_full_lineage', 'pure_provenance_rejects_missing_lineage',
 'pure_support_accepts_disjoint',
 'pure_support_rejects_self_review', 'pure_support_rejects_shared_session',
 'pure_support_rejects_repeated_assignment', 'reject_critic_session_model_reuse',
 'pure_scope_accepts_all_types', 'pure_scope_rejects_malformed',
 'pure_dissent_accepts_versioned',
 'pure_guidance_admits_methods', 'pure_guidance_rejects_gate_change',
 'pure_guidance_rejects_spaced_keys', 'pure_guidance_rejects_plural',
 'propose_lesson', 'propose_idempotent', 'propose_timezone_idempotent',
 'reject_changed_inputs', 'reject_changed_source_lineage', 'reject_missing_lineage',
 'reject_nondisjoint_support', 'reject_self_review_support',
 'reject_shared_session_support', 'reject_gate_change_guidance',
 'reject_unknown_provenance_assignment', 'reject_unknown_source_artifact',
 'reject_own_lineage_support',
 'admit_lesson', 'admit_idempotent',
 'reject_admit_unknown', 'reject_admit_after_expiry',
 'contain_proposed_suspend', 'contain_proposed_contaminate', 'contain_proposed_expire',
 'retrieve_admitted_global', 'retrieve_role_posture_scoped',
 'retrieve_method_data_scoped', 'retrieve_blocks_expired_at',
 'suspend_blocks_retrieval', 'supersede_resolves_to_successor',
 'reject_supersede_proposed_successor', 'reject_supersede_cycle',
 'contaminate_blocks_retrieval', 'reject_contaminate_without_reason',
 'expire_blocks_retrieval', 'reject_illegal_transition',
 'reject_illegal_transition_with_flag', 'reject_direct_write_with_flag',
 'reject_unknown_successor',
 'duplicate_links_canonical', 'reject_duplicate_reused_support',
 'reject_duplicate_suspended_canonical',
 'pinned_review_flags', 'pinned_review_flags_stale_version', 'pinned_review_flags_malformed',
 'dissent_versioned_preserved',
 'append_only', 'insert_guard', 'no_worker_grants'));
