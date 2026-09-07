-- Operator retry after attachment failure, including an exhausted attempt budget.
CREATE OR REPLACE FUNCTION control_market_data_acquisition(id_value bigint,action text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE j market_data_acquisition%ROWTYPE; source_value uuid;
BEGIN
 SELECT source_id INTO STRICT source_value FROM market_data_acquisition WHERE experiment_id=id_value;
 PERFORM 1 FROM market_data_source WHERE id=source_value FOR UPDATE;
 SELECT * INTO STRICT j FROM market_data_acquisition WHERE experiment_id=id_value FOR UPDATE;
 IF action='cancel' AND j.state IN ('queued','leased','retry_wait','failed') THEN
  UPDATE market_data_acquisition SET state='cancelled',lease_token=NULL,lease_until=NULL WHERE experiment_id=id_value;
 ELSIF action='retry' AND j.state='failed' AND j.request IS NOT NULL AND market_data_source_available(source_value)
  AND (j.attempts<3 OR j.error_code='commit_rejected') THEN
  UPDATE market_data_acquisition SET state='queued',error_code=NULL,attempts=CASE WHEN j.error_code='commit_rejected' AND j.attempts>=3 THEN 2 ELSE j.attempts END,next_attempt_at=clock_timestamp() WHERE experiment_id=id_value;
 ELSE RAISE EXCEPTION 'acquisition_control_rejected'; END IF;
 PERFORM pg_notify('incubator_experiment','changed');
END $$;
