-- WU-45 command ledger probe. Run inside a caller-managed transaction;
-- fixture evidence is rolled back by the acceptance script.

CREATE TEMP TABLE wu45_probe_result (result jsonb NOT NULL);

DO $probe$
DECLARE
  v_lineage jsonb := '{"source":"wu45-probe","entitlement_version":"command-ledger-v1"}';
  v_results jsonb := '{}'::jsonb;
  v_clean jsonb;
  v_tampered jsonb;
  v_head bigint;
  v_break bigint;
  v_appended bigint;
BEGIN
  SELECT read_command_ledger((SELECT max(chain_position) FROM audit_checkpoint)) INTO v_clean;

  v_results := jsonb_build_object(
    'variant_a', v_clean->>'variant' = 'A',
    'local_research', v_clean->>'environment' = 'local_research',
    'no_order_authority', (v_clean->>'order_authority')::boolean IS NOT TRUE
      AND v_clean#>>'{system_truth,order_authority}' = 'none',
    'checkpoints_verified_before_display',
      (v_clean->>'checkpoints_verified')::boolean
      AND v_clean#>>'{system_truth,state}' = 'CHECKPOINT PENDING'
      AND (v_clean#>>'{chain,valid}')::boolean
      AND jsonb_array_length(v_clean->'tape') >= 1
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_clean->'tape') ev
        WHERE (ev->>'trusted')::boolean
      )
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_clean->'tape') ev
        WHERE ev->>'distrust_reason' = 'outside_verified_checkpoint'
      )
  );

  SELECT max(chain_position) INTO v_head FROM audit_event;
  PERFORM append_audit_event(
    'wu45-range-' || gen_random_uuid()::text,
    'research.command_ledger_range_marker',
    now(),
    jsonb_build_object('probe', 'wu45'),
    v_lineage,
    now(),
    'local_research'
  );
  SELECT max(chain_position) INTO v_appended FROM audit_event;

  SELECT read_command_ledger((SELECT max(chain_position) FROM audit_checkpoint)) INTO v_tampered;
  v_results := v_results || jsonb_build_object(
    'post_checkpoint_events_untrusted',
      v_tampered#>>'{system_truth,state}' = 'CHECKPOINT PENDING'
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_tampered->'tape') ev
        WHERE (ev->>'chain_position')::bigint = v_appended
          AND (ev->>'trusted')::boolean IS NOT TRUE
          AND ev->>'distrust_reason' = 'outside_verified_checkpoint'
      )
  );

  SET LOCAL session_replication_role = replica;
  UPDATE audit_event
     SET payload = jsonb_set(payload, '{tampered}', 'true'::jsonb)
   WHERE chain_position = v_appended;
  SET LOCAL session_replication_role = origin;

  SELECT read_command_ledger((SELECT max(chain_position) FROM audit_checkpoint)) INTO v_tampered;
  v_break := (v_tampered#>>'{chain,break_position}')::bigint;

  v_results := v_results || jsonb_build_object(
    'tamper_distrusts_affected_range',
      (v_tampered#>>'{chain,valid}')::boolean IS NOT TRUE
      AND v_tampered#>>'{system_truth,state}' = 'CHAIN DISTRUSTED'
      AND v_break = v_appended
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_tampered->'exceptions') ex
        WHERE ex->>'kind' = 'chain_break'
          AND (ex->>'position')::bigint = v_appended
      )
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_tampered->'tape') ev
        WHERE (ev->>'chain_position')::bigint = (
            SELECT max(chain_position) FROM audit_checkpoint)
          AND (ev->>'trusted')::boolean
      )
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_tampered->'tape') ev
        WHERE (ev->>'chain_position')::bigint = v_appended
          AND (ev->>'trusted')::boolean IS NOT TRUE
          AND ev->>'distrust_reason' = 'affected_range'
      )
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_tampered->'tape') ev
        WHERE (ev->>'chain_position')::bigint <= (
            SELECT max(chain_position) FROM audit_checkpoint)
          AND (ev->>'trusted')::boolean IS NOT TRUE
      )
  );

  INSERT INTO wu45_probe_result (result) VALUES (
    v_results || jsonb_build_object(
      'break_position', v_break,
      'head_before_append', v_head,
      'tamper_position', v_appended,
      'tampered_ledger', v_tampered
    )
  );
END
$probe$;
