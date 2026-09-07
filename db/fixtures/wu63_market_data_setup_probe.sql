BEGIN;
SET LOCAL ROLE market_data_service;
DO $$
BEGIN
 BEGIN
  PERFORM setup_personal_market_data(false);
  RAISE EXCEPTION 'declined_owner_review_was_accepted';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'account_terms_review_required' THEN RAISE; END IF;
 END;
 BEGIN
  PERFORM queue_market_data_refreshes_at('2026-01-20T11:00:00Z');
  RAISE EXCEPTION 'runtime_can_override_schedule_clock';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $$;
ROLLBACK;
