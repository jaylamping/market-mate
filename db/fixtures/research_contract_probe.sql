-- Isolated, rollback-only mechanism probe for PR1 research contracts
-- (wayfinder map #171, decision #172). Run as migration owner after 0096.
-- Exercises admit_research_assignment plus all three verification gates,
-- including failure rows. No outbound network calls; no cost, route, or
-- execution authority is touched. Driver linkage rows are inserted directly
-- as owner; the probe never admits capacity or dispatches work.
BEGIN;
CREATE FUNCTION pg_temp.contract_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'contract assertion: %', message; END IF;
END $$;

-- Driver linkage doubles: one completed, one indeterminate, one failed, one
-- open (no outcome yet), and one bare parent for fallback ancestry.
INSERT INTO agent(id, name) VALUES ('probe_contract_agent', 'Probe Contract');
INSERT INTO dispatch_intent(intent_id, key, agent_id, purpose, request, fingerprint) VALUES
 ('probe-intent-1', 'probe:contract:1', 'probe_contract_agent', 'research', '{"probe":1}', 'fp1'),
 ('probe-intent-2', 'probe:contract:2', 'probe_contract_agent', 'research', '{"probe":2}', 'fp2'),
 ('probe-intent-3', 'probe:contract:3', 'probe_contract_agent', 'research', '{"probe":3}', 'fp3'),
 ('probe-intent-4', 'probe:contract:4', 'probe_contract_agent', 'research', '{"probe":4}', 'fp4'),
 ('probe-intent-5', 'probe:contract:5', 'probe_contract_agent', 'research', '{"probe":5}', 'fp5');
INSERT INTO dispatch_attempt(attempt_id, intent_id, agent_id, provider_id, model_id, tier, ordinal, request_sha256, source_lineage, receipt_time, record_environment) VALUES
 ('probe-att-complete', 'probe-intent-1', 'probe_contract_agent', 'zai', 'glm-5.3-flash', 'free', 0, 'fp1', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research'),
 ('probe-att-indeterminate', 'probe-intent-2', 'probe_contract_agent', 'zai', 'glm-5.3-flash', 'free', 0, 'fp2', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research'),
 ('probe-att-failed', 'probe-intent-3', 'probe_contract_agent', 'zai', 'glm-5.3-flash', 'free', 0, 'fp3', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research'),
 ('probe-att-open', 'probe-intent-4', 'probe_contract_agent', 'zai', 'glm-5.3-flash', 'free', 0, 'fp4', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research'),
 ('probe-parent-1', 'probe-intent-5', 'probe_contract_agent', 'zai', 'glm-5.3-flash', 'free', 0, 'fp5', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research');
INSERT INTO dispatch_outcome(attempt_id, state, detail, source_lineage, receipt_time, record_environment) VALUES
 ('probe-att-complete', 'completed', '{"reason":"probe_ok"}', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research'),
 ('probe-att-indeterminate', 'indeterminate', '{"reason":"probe_timeout"}', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research'),
 ('probe-att-failed', 'failed', '{"reason":"probe_error"}', '{"source":"research-contract-probe","entitlement_version":"probe-v1"}', clock_timestamp(), 'local_research');

DO $$ DECLARE
 lineage jsonb := '{"source":"research-contract-probe","entitlement_version":"probe-v1"}';
 base_pins jsonb := jsonb_build_object(
  'assignment_key', 'probe-base',
  'desk_role', 'strategy_incubation',
  'strategy_thesis_id', 'thesis-probe-1',
  'posture_profile', 'Balanced Investigator',
  'posture_version', 'posture-v3',
  'recipe_version', 'recipe-v2',
  'contract_runner', 'momentum_v1',
  'persona_id', 'persona-scout-7',
  'persona_cosmetic', true,
  'expires_at', '2030-06-01T00:00:00Z');
  a1 research_assignment%ROWTYPE;
  a1_again research_assignment%ROWTYPE;
  a_child research_assignment%ROWTYPE;
  old_tz text;
BEGIN
 -- Pure pin validator mirrors the admission boundary.
 PERFORM pg_temp.contract_assert(research_assignment_pins_valid(base_pins), 'pure pins accept the minimal set');
 PERFORM pg_temp.contract_assert(NOT research_assignment_pins_valid(base_pins || '{"persona_cosmetic":false}'), 'pure pins reject a non-cosmetic persona');
 PERFORM pg_temp.contract_assert(NOT research_assignment_pins_valid(base_pins || '{"posture_profile":"Reckless Gambler"}'), 'pure pins reject an unknown posture');
 PERFORM pg_temp.contract_assert(NOT research_assignment_pins_valid(base_pins || '{"sizing":{"risk":"high"}}'), 'pure pins reject unknown fields');
 -- Pure spec validator enforces the contract quantile set {2,4,5,10}.
 PERFORM pg_temp.contract_assert(research_momentum_spec_is_valid('{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":10,"one_way_cost_bps":10,"borrow_bps_per_session":2}'), 'pure spec accepts quantile 10');
 PERFORM pg_temp.contract_assert(NOT research_momentum_spec_is_valid('{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":3,"one_way_cost_bps":10,"borrow_bps_per_session":2}'), 'pure spec rejects quantile 3');
 PERFORM pg_temp.contract_assert(NOT research_momentum_spec_is_valid('{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":4,"one_way_cost_bps":10,"borrow_bps_per_session":2,"tuning":{}}'), 'pure spec rejects a sixth key');

 -- Admission pins the minimal set and is idempotent on the key.
 a1 := admit_research_assignment(base_pins || '{"assignment_key":"probe-a1","desk_role":"quantitative_research_and_experimentation"}', lineage);
 a1_again := admit_research_assignment(base_pins || '{"assignment_key":"probe-a1","desk_role":"quantitative_research_and_experimentation"}', lineage);
  PERFORM pg_temp.contract_assert(a1.assignment_id = a1_again.assignment_id, 'admit is idempotent on assignment key');
  -- S3: identical instants stay idempotent across TimeZones (UTC canonical).
  SELECT current_setting('TimeZone') INTO old_tz;
  PERFORM set_config('TimeZone', 'America/New_York', true);
  a1_again := admit_research_assignment(base_pins || '{"assignment_key":"probe-a1","desk_role":"quantitative_research_and_experimentation"}', lineage);
  PERFORM pg_temp.contract_assert(a1_again.assignment_id = a1.assignment_id, 'admit stays idempotent across TimeZone');
  PERFORM set_config('TimeZone', old_tz, true);
  PERFORM admit_research_assignment(base_pins || '{"assignment_key":"probe-a2"}', lineage);
  PERFORM admit_research_assignment(base_pins || '{"assignment_key":"probe-a-expired","expires_at":"2001-01-01T00:00:00Z"}', lineage);
  -- S5: parent lineage is genuinely asserted, not self-reported.
  a_child := admit_research_assignment(
   base_pins || jsonb_build_object('assignment_key', 'probe-a-child', 'parent_assignment_id', a1.assignment_id::text), lineage);
  PERFORM pg_temp.contract_assert(a_child.parent_assignment_id = a1.assignment_id, 'child parent id matches');
  PERFORM pg_temp.contract_assert((a_child.pins->>'parent_assignment_id') = a1.assignment_id::text, 'child pins parent round-trips');

 -- Failure rows at the admission boundary.
 BEGIN PERFORM admit_research_assignment(base_pins || '{"posture_profile":"Reckless Gambler"}', lineage);
  RAISE EXCEPTION 'accepted bad posture';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"persona_cosmetic":false}', lineage);
  RAISE EXCEPTION 'accepted non-cosmetic persona';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"strategy_thesis_id":"  "}', lineage);
  RAISE EXCEPTION 'accepted missing thesis';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"desk_role":"risk"}', lineage);
  RAISE EXCEPTION 'accepted forbidden desk role';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"contract_runner":"alpha_v9"}', lineage);
  RAISE EXCEPTION 'accepted foreign runner';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"note":{"paper_eligible":true}}', lineage);
  RAISE EXCEPTION 'accepted authority claim in pins';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"sizing":{"risk":"high"}}', lineage);
  RAISE EXCEPTION 'accepted unknown pin';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(base_pins || '{"expires_at":"soon"}', lineage);
  RAISE EXCEPTION 'accepted bad expiry';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(
  base_pins || '{"assignment_key":"probe-a1","desk_role":"quantitative_research_and_experimentation","strategy_thesis_id":"thesis-changed"}', lineage);
  RAISE EXCEPTION 'accepted changed pins on re-admit';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM admit_research_assignment(
  base_pins || '{"assignment_key":"probe-a-orphan","parent_assignment_id":"00000000-0000-0000-0000-000000000000"}', lineage);
  RAISE EXCEPTION 'accepted unknown parent';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;

DO $$ DECLARE
 lineage jsonb := '{"source":"research-contract-probe","entitlement_version":"probe-v1"}';
 a1_id uuid; a2_id uuid; expired_id uuid;
 spec_good jsonb := '{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":4,"one_way_cost_bps":10,"borrow_bps_per_session":2}';
 artifact_good jsonb := '{"engine":"momentum_v1","outcome":"diagnostic_only","mean_net_bps":12}';
 m research_artifact_manifest%ROWTYPE;
 m_again research_artifact_manifest%ROWTYPE;
BEGIN
 SELECT assignment_id INTO STRICT a1_id FROM research_assignment WHERE assignment_key = 'probe-a1';
 SELECT assignment_id INTO STRICT a2_id FROM research_assignment WHERE assignment_key = 'probe-a2';
 SELECT assignment_id INTO STRICT expired_id FROM research_assignment WHERE assignment_key = 'probe-a-expired';

 -- The ready path: separate assignment, run, and role; different family; dissent preserved.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-ready',
  assignment_id_value := a1_id,
  run_key_value := 'run-author-1',
  intent_id_value := 'probe-intent-1',
  attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free","provider_id":"openrouter-free"}',
  actual_route_value := '{"tier":"free","provider_id":"openrouter-free"}',
  config_revision_value := 3,
  fallback_ancestry_value := '["probe-parent-1"]',
  author_assignment_id_value := a1_id,
  author_run_key_value := 'run-author-1',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL,
  refiner_run_key_value := NULL,
  refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id,
  reviewer_run_key_value := 'run-reviewer-1',
  reviewer_role_value := 'economic_evaluation_and_challenge',
  reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}',
  lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := artifact_good,
  dissent_preserved_value := true,
  source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_contract_validity(m.artifact_id) = 'valid', 'ready manifest is valid');
 PERFORM pg_temp.contract_assert(research_reproducibility(m.artifact_id) = 'reproduced', 'ready manifest reproduces');
 PERFORM pg_temp.contract_assert(research_methodological_readiness(m.artifact_id) = 'ready', 'ready manifest is ready');
 m_again := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-ready',
  assignment_id_value := a1_id,
  run_key_value := 'run-author-1',
  intent_id_value := 'probe-intent-1',
  attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free","provider_id":"openrouter-free"}',
  actual_route_value := '{"tier":"free","provider_id":"openrouter-free"}',
  config_revision_value := 3,
  fallback_ancestry_value := '["probe-parent-1"]',
  author_assignment_id_value := a1_id,
  author_run_key_value := 'run-author-1',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL,
  refiner_run_key_value := NULL,
  refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id,
  reviewer_run_key_value := 'run-reviewer-1',
  reviewer_role_value := 'economic_evaluation_and_challenge',
  reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}',
  lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := artifact_good,
  dissent_preserved_value := true,
  source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(m_again.artifact_id = m.artifact_id, 'record is idempotent on artifact key');
 BEGIN m_again := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-ready',
  assignment_id_value := a1_id,
  run_key_value := 'run-author-1',
  intent_id_value := 'probe-intent-1',
  attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}',
  actual_route_value := '{"tier":"free"}',
  config_revision_value := 3,
  fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id,
  author_run_key_value := 'run-author-1',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL,
  refiner_run_key_value := NULL,
  refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id,
  reviewer_run_key_value := 'run-reviewer-1',
  reviewer_role_value := 'economic_evaluation_and_challenge',
  reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}',
  lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := '{"engine":"momentum_v1","outcome":"diagnostic_only","mean_net_bps":99}',
  dissent_preserved_value := true,
  source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted changed artifact on re-record';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  -- S1: same key+digests with a different run_key must diverge, not return existing.
  BEGIN m_again := record_research_artifact_manifest(
   artifact_key_value := 'probe-m-ready',
   assignment_id_value := a1_id,
   run_key_value := 'run-author-changed',
   intent_id_value := 'probe-intent-1',
   attempt_id_value := 'probe-att-complete',
   requested_route_value := '{"tier":"free","provider_id":"openrouter-free"}',
   actual_route_value := '{"tier":"free","provider_id":"openrouter-free"}',
   config_revision_value := 3,
   fallback_ancestry_value := '["probe-parent-1"]',
   author_assignment_id_value := a1_id,
   author_run_key_value := 'run-author-1',
   author_role_value := 'strategy_incubation',
   refiner_assignment_id_value := NULL,
   refiner_run_key_value := NULL,
   refiner_role_value := NULL,
   author_family_value := 'family-alpha',
   reviewer_assignment_id_value := a2_id,
   reviewer_run_key_value := 'run-reviewer-1',
   reviewer_role_value := 'economic_evaluation_and_challenge',
   reviewer_family_value := 'family-beta',
   recipe_versions_value := '{"recipe":"recipe-v2"}',
   lesson_versions_value := '{}',
   spec_value := spec_good,
   artifact_value := artifact_good,
   dissent_preserved_value := true,
   source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted changed run_key on re-record';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  -- S2: mismatched intent/attempt linkage must fail against dispatch_attempt.
  BEGIN PERFORM record_research_artifact_manifest(
   artifact_key_value := 'probe-m-badlink',
   assignment_id_value := a1_id, run_key_value := 'run-author-badlink',
   intent_id_value := 'probe-intent-1', attempt_id_value := 'probe-att-indeterminate',
   requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
   config_revision_value := 3, fallback_ancestry_value := '[]',
   author_assignment_id_value := a1_id, author_run_key_value := 'run-author-badlink',
   author_role_value := 'strategy_incubation',
   refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
   author_family_value := 'family-alpha',
   reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL,
   reviewer_role_value := NULL, reviewer_family_value := NULL,
   recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
   spec_value := spec_good, artifact_value := artifact_good,
   dissent_preserved_value := true, source_lineage_value := lineage);
   RAISE EXCEPTION 'accepted mismatched intent/attempt';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;

  -- Same-family approval holds and never counts as critique.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-samefam',
  assignment_id_value := a1_id, run_key_value := 'run-author-2',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-2',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-2',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-alpha',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_methodological_readiness(m.artifact_id) = 'held:same_family', 'same-family review holds');

 -- Missing critique holds.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-nocrit',
  assignment_id_value := a1_id, run_key_value := 'run-author-3',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-3',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL,
  reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_methodological_readiness(m.artifact_id) = 'held:missing_critique', 'missing critique holds');

 -- Missing dissent holds.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-nodissent',
  assignment_id_value := a1_id, run_key_value := 'run-author-4',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-4',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-4',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := false, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_methodological_readiness(m.artifact_id) = 'held:dissent_not_preserved', 'missing dissent holds');

 -- Same run holds even across assignments.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-samerun',
  assignment_id_value := a1_id, run_key_value := 'run-shared-1',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-shared-1',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-shared-1',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_methodological_readiness(m.artifact_id) = 'held:same_assignment_or_run', 'shared run holds');

 -- Same role holds even with separate assignment, run, and family.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-samerole',
  assignment_id_value := a1_id, run_key_value := 'run-author-6',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-6',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-6',
  reviewer_role_value := 'strategy_incubation', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_methodological_readiness(m.artifact_id) = 'held:same_role', 'shared role holds');

 -- Expired assignments fail validity, not readiness.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-expired',
  assignment_id_value := expired_id, run_key_value := 'run-author-7',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := expired_id, author_run_key_value := 'run-author-7',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-7',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_contract_validity(m.artifact_id) = 'invalid:assignment_expired', 'expired assignment is invalid');

 -- Open fallback ancestry diverges lineage closure.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-openlineage',
  assignment_id_value := a1_id, run_key_value := 'run-author-8',
  intent_id_value := NULL, attempt_id_value := 'probe-att-complete',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '["probe-missing-parent"]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-8',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-8',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_reproducibility(m.artifact_id) = 'diverged:lineage_open', 'open ancestry diverges');

 -- Indeterminate outcomes stay indeterminate; unknown outcomes stay
 -- indeterminate; failed outcomes diverge. None silently pass or fail.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-indeterminate',
  assignment_id_value := a1_id, run_key_value := 'run-author-9',
  intent_id_value := 'probe-intent-2', attempt_id_value := 'probe-att-indeterminate',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-9',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-9',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_reproducibility(m.artifact_id) = 'indeterminate:dispatch_indeterminate', 'indeterminate dispatch stays indeterminate');
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-unknown',
  assignment_id_value := a1_id, run_key_value := 'run-author-10',
  intent_id_value := 'probe-intent-4', attempt_id_value := 'probe-att-open',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-10',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-10',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_reproducibility(m.artifact_id) = 'indeterminate:dispatch_outcome_unknown', 'missing outcome stays indeterminate');
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-failed',
  assignment_id_value := a1_id, run_key_value := 'run-author-11',
  intent_id_value := 'probe-intent-3', attempt_id_value := 'probe-att-failed',
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 3, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-11',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-11',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_reproducibility(m.artifact_id) = 'diverged:dispatch_failed', 'failed dispatch diverges');

 -- Unlinked local artifacts replay from pinned inputs alone.
 m := record_research_artifact_manifest(
  artifact_key_value := 'probe-m-nolink',
  assignment_id_value := a1_id, run_key_value := 'run-author-12',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-author-12',
  author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := 'run-reviewer-12',
  reviewer_role_value := 'economic_evaluation_and_challenge', reviewer_family_value := 'family-beta',
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good, artifact_value := artifact_good,
  dissent_preserved_value := true, source_lineage_value := lineage);
 PERFORM pg_temp.contract_assert(research_reproducibility(m.artifact_id) = 'reproduced', 'unlinked artifact reproduces');
 PERFORM pg_temp.contract_assert(
  research_spec_digest(spec_good) = (SELECT spec_digest FROM research_artifact_manifest WHERE artifact_key = 'probe-m-nolink'),
  'pinned-version replay reproduces the byte-identical spec digest');

 -- Failure rows at the record boundary.
 BEGIN PERFORM record_research_artifact_manifest(
  artifact_key_value := 'probe-m-badquant', assignment_id_value := a1_id, run_key_value := 'run-bad-1',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-bad-1', author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL, reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := '{"runner":"momentum_v1","lookback_sessions":2,"quantile_count":3,"one_way_cost_bps":10,"borrow_bps_per_session":2}',
  artifact_value := artifact_good, dissent_preserved_value := true, source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted quantile 3';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM record_research_artifact_manifest(
  artifact_key_value := 'probe-m-sixkeys', assignment_id_value := a1_id, run_key_value := 'run-bad-2',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-bad-2', author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL, reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good || '{"tuning":{}}',
  artifact_value := artifact_good, dissent_preserved_value := true, source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted sixth spec key';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM record_research_artifact_manifest(
  artifact_key_value := 'probe-m-authority', assignment_id_value := a1_id, run_key_value := 'run-bad-3',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-bad-3', author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL, reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := '{"engine":"momentum_v1","paper":{"eligible":true}}',
  dissent_preserved_value := true, source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted authority claim in artifact';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM record_research_artifact_manifest(
  artifact_key_value := 'probe-m-norun', assignment_id_value := a1_id, run_key_value := '  ',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-bad-4', author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL, reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := artifact_good, dissent_preserved_value := true, source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted blank run key';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM record_research_artifact_manifest(
  artifact_key_value := 'probe-m-partialreview', assignment_id_value := a1_id, run_key_value := 'run-bad-5',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-bad-5', author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := a2_id, reviewer_run_key_value := NULL, reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := artifact_good, dissent_preserved_value := true, source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted partial reviewer';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM record_research_artifact_manifest(
  artifact_key_value := 'probe-m-noassign', assignment_id_value := '00000000-0000-0000-0000-000000000000', run_key_value := 'run-bad-6',
  intent_id_value := NULL, attempt_id_value := NULL,
  requested_route_value := '{"tier":"free"}', actual_route_value := '{"tier":"free"}',
  config_revision_value := 0, fallback_ancestry_value := '[]',
  author_assignment_id_value := a1_id, author_run_key_value := 'run-bad-6', author_role_value := 'strategy_incubation',
  refiner_assignment_id_value := NULL, refiner_run_key_value := NULL, refiner_role_value := NULL,
  author_family_value := 'family-alpha',
  reviewer_assignment_id_value := NULL, reviewer_run_key_value := NULL, reviewer_role_value := NULL, reviewer_family_value := NULL,
  recipe_versions_value := '{"recipe":"recipe-v2"}', lesson_versions_value := '{}',
  spec_value := spec_good,
  artifact_value := artifact_good, dissent_preserved_value := true, source_lineage_value := lineage);
  RAISE EXCEPTION 'accepted unknown assignment';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;

 -- A diverged replay (digest recorded over different bytes) is rejected at
 -- the write boundary, and digests distinguish replay bytes.
 PERFORM pg_temp.contract_assert(
  research_artifact_digest('{"engine":"momentum_v1","n":1}') <> research_artifact_digest('{"engine":"momentum_v1","n":2}'),
  'digests distinguish replay bytes');
 PERFORM set_config('market_mate.incubator_write', 'on', true);
 BEGIN
  INSERT INTO research_artifact_manifest (
   artifact_key, assignment_id, run_key, requested_route, actual_route,
   config_revision, fallback_ancestry,
   author_assignment_id, author_run_key, author_role, author_family,
   recipe_versions, lesson_versions, spec, spec_digest, artifact,
   artifact_digest, dissent_preserved,
   source_lineage, receipt_time, record_environment)
  VALUES (
   'probe-m-diverged', a1_id, 'run-diverged', '{}', '{}',
   0, '[]',
   a1_id, 'run-diverged', 'strategy_incubation', 'family-alpha',
   '{}', '{}', spec_good, research_spec_digest(spec_good), artifact_good,
   '0000000000000000000000000000000000000000000000000000000000000000', true,
   lineage, clock_timestamp(), 'local_research');
  RAISE EXCEPTION 'accepted diverged digest';
 EXCEPTION WHEN SQLSTATE '23514' THEN NULL; END;
 PERFORM set_config('market_mate.incubator_write', 'off', true);

 -- Evidence tables are append-only for every role, and direct writes stay
 -- behind the workflow flag.
 BEGIN UPDATE research_assignment SET desk_role = 'x' WHERE assignment_key = 'probe-a1';
  RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 BEGIN DELETE FROM research_artifact_manifest WHERE artifact_key = 'probe-m-ready';
  RAISE EXCEPTION 'mutation accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;
 BEGIN INSERT INTO research_assignment (
  assignment_key, desk_role, strategy_thesis_id, posture_profile,
  posture_version, recipe_version, contract_runner, persona_id,
  persona_cosmetic, expires_at, pins,
  source_lineage, receipt_time, record_environment)
 VALUES (
  'probe-a-direct', 'strategy_incubation', 'thesis-probe-1', 'Balanced Investigator',
  'posture-v3', 'recipe-v2', 'momentum_v1', 'persona-scout-7',
  true, '2030-06-01T00:00:00Z',
  '{"assignment_key":"probe-a-direct","desk_role":"strategy_incubation","strategy_thesis_id":"thesis-probe-1","posture_profile":"Balanced Investigator","posture_version":"posture-v3","recipe_version":"recipe-v2","contract_runner":"momentum_v1","persona_id":"persona-scout-7","persona_cosmetic":true,"expires_at":"2030-06-01 00:00:00+00"}',
  lineage, clock_timestamp(), 'local_research');
  RAISE EXCEPTION 'direct write accepted';
 EXCEPTION WHEN SQLSTATE '55000' THEN NULL; END;

 -- The contract ships dark: workers hold no execute or write grants.
 PERFORM pg_temp.contract_assert(
  NOT has_function_privilege('incubator_runner', 'admit_research_assignment(jsonb,jsonb)', 'EXECUTE'),
  'no worker execute on admission');
 PERFORM pg_temp.contract_assert(
  NOT has_table_privilege('incubator_runner', 'research_artifact_manifest', 'INSERT'),
  'no worker insert on manifests');
END $$;
ROLLBACK;
SELECT jsonb_build_object('probe', 'research-contract', 'passed', true, 'checks', jsonb_build_array(
 'admit_pins', 'pure_pin_validator', 'pure_spec_validator', 'contract_quantile_set',
 'idempotent_admit', 'timezone_idempotent_admit', 'parent_assignment_lineage',
 'reject_bad_pins', 'reject_changed_pins', 'reject_unknown_parent',
 'record_manifest', 'idempotent_record', 'reject_changed_artifact',
 'reject_changed_run_key', 'reject_mismatched_intent',
 'validity_gate', 'reproducibility_gate', 'readiness_gate',
 'reject_bad_spec', 'reject_authority_claim', 'reject_partial_reviewer', 'reject_unknown_assignment',
 'expired_assignment_invalid',
 'same_family_held', 'missing_critique_held', 'missing_dissent_held',
 'same_assignment_or_run_held', 'same_role_held',
 'pinned_replay_byte_identical', 'diverged_digest_rejected', 'digest_distinguishes_bytes',
 'lineage_open_diverged', 'indeterminate_preserved', 'unknown_outcome_indeterminate',
 'failed_dispatch_diverged', 'unlinked_artifact_reproduces',
 'append_only', 'insert_guard', 'no_worker_grants'));
