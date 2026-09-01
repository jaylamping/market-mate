-- WU-45 Dashboard command ledger. Variant A (dense audit tape +
-- exception rail + permanent system-truth header) is projected from
-- the signed audit chain after checkpoint verification. A tampered
-- chain is displayed as distrusted from the break onward. Stage-1
-- surfaces belong to WU-46.

CREATE FUNCTION read_command_ledger(verified_position bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    chain record;
    break_at bigint;
    checkpoints_ok boolean := verified_position IS NOT NULL;
    checkpoint_count integer;
    exceptions jsonb := '[]'::jsonb;
    tape jsonb := '[]'::jsonb;
    ev record;
    trusted boolean;
    distrust_reason text;
    truth_state text;
    truth_detail text;
    as_of timestamptz;
    head bigint;
BEGIN
    SELECT * INTO chain FROM verify_audit_event_chain();
    SELECT max(chain_position), max(receipt_time)
      INTO head, as_of
      FROM audit_event;

    IF chain.valid THEN
        break_at := NULL;
    ELSE
        break_at := chain.break_position;
        exceptions := exceptions || jsonb_build_array(jsonb_build_object(
            'kind', 'chain_break',
            'position', chain.break_position,
            'reason', chain.reason,
            'detail', 'signed audit chain is untrusted from this position onward'
        ));
    END IF;

    SELECT count(*) INTO checkpoint_count FROM audit_checkpoint;
    IF NOT checkpoints_ok THEN
        exceptions := exceptions || jsonb_build_array(jsonb_build_object(
            'kind', 'checkpoint_missing',
            'position', NULL,
            'reason', 'checkpoint_unverified',
            'detail', 'no signed checkpoint; command ledger will not display the chain as trusted'
        ));
    END IF;

    IF checkpoints_ok AND head > verified_position THEN
        exceptions := exceptions || jsonb_build_array(jsonb_build_object(
            'kind', 'checkpoint_pending',
            'position', verified_position + 1,
            'reason', 'outside_verified_checkpoint',
            'detail', format(
                'events after position %s are not covered by a signed checkpoint',
                verified_position)
        ));
    END IF;

    FOR ev IN
        SELECT chain_position, event_id, event_type, event_time,
               record_environment
        FROM audit_event
        ORDER BY chain_position
    LOOP
        IF NOT checkpoints_ok THEN
            trusted := false;
            distrust_reason := 'checkpoint_unverified';
        ELSIF NOT chain.valid
           AND break_at IS NOT NULL
           AND ev.chain_position >= break_at THEN
            trusted := false;
            distrust_reason := 'affected_range';
        ELSIF ev.chain_position > verified_position THEN
            trusted := false;
            distrust_reason := 'outside_verified_checkpoint';
        ELSE
            trusted := true;
            distrust_reason := NULL;
        END IF;
        tape := tape || jsonb_build_array(jsonb_build_object(
            'chain_position', ev.chain_position,
            'event_id', ev.event_id,
            'event_type', ev.event_type,
            'event_time', to_char(
                ev.event_time AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'record_environment', ev.record_environment::text,
            'trusted', trusted,
            'distrust_reason', to_jsonb(distrust_reason)
        ));
    END LOOP;

    IF chain.valid AND checkpoints_ok AND head <= verified_position THEN
        truth_state := 'CHAIN VERIFIED';
        truth_detail :=
            'Signed audit chain and checkpoints verified. Local Research. Zero order authority.';
    ELSIF NOT checkpoints_ok THEN
        truth_state := 'CHECKPOINT UNVERIFIED';
        truth_detail :=
            'Checkpoints were not verified; the tape is displayed as untrusted.';
    ELSIF NOT chain.valid THEN
        truth_state := 'CHAIN DISTRUSTED';
        truth_detail := format(
            'Break at position %s (%s). The dashboard distrusts the affected range.',
            chain.break_position, chain.reason);
    ELSE
        truth_state := 'CHECKPOINT PENDING';
        truth_detail := format(
            'Signed checkpoint verifies through position %s. Later events remain untrusted.',
            verified_position);
    END IF;

    RETURN jsonb_build_object(
        'variant', 'A',
        'environment', 'local_research',
        'order_authority', false,
        'checkpoints_verified', checkpoints_ok,
        'chain', jsonb_build_object(
            'valid', chain.valid,
            'checked_events', chain.checked_events,
            'break_position', to_jsonb(chain.break_position),
            'reason', to_jsonb(chain.reason)
        ),
        'checkpoint_count', checkpoint_count,
        'system_truth', jsonb_build_object(
            'environment', 'LOCAL RESEARCH',
            'state', truth_state,
            'detail', truth_detail,
            'head_position', to_jsonb(head),
            'as_of', to_char(
                coalesce(as_of, clock_timestamp()) AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'order_authority', 'none'
        ),
        'exceptions', exceptions,
        'tape', tape
    );
END;
$$;

REVOKE ALL ON FUNCTION read_command_ledger(bigint) FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
