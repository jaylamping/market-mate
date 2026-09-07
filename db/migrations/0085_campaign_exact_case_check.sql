-- Campaign duplicate checks are local exact-case comparisons. Do not pace them
-- behind a claim timer; provider capacity applies to research workers, not Check.
CREATE OR REPLACE FUNCTION claim_incubator_campaign(model_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; scope_value jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE state='checking' ORDER BY ordinal LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(a)||jsonb_build_object('fresh',false); END IF;
 IF (SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued' AND receipt_time>clock_timestamp()-interval '24 hours')>=c.daily_limit OR incubator_campaign_open_count()>=c.open_limit THEN RETURN NULL; END IF;
 IF model_value IS NULL OR model_value LIKE 'openrouter/%' OR length(model_value)>256 OR model_value !~ '^[a-zA-Z0-9._/:~-]+$'
  OR (model_value !~ '^[a-zA-Z0-9._/-]+:free$' AND model_value IS DISTINCT FROM c.creator_model) THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for an approved campaign Research model. Configure Models or the Ticket Creator model to continue.'; END IF;
  RETURN NULL;
 END IF;
 SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt) ORDER BY ordinal LIMIT 1;
 IF NOT FOUND THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for Ticket Creator to stock the backlog.'; END IF;
  RETURN NULL;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM market_data_source WHERE market_data_source_available(id)) THEN
  IF c.enabled THEN UPDATE incubator_campaign SET note='Waiting for an available market data connection.'; END IF;
  RETURN NULL;
 END IF;
 BEGIN
  scope_value:=incubator_campaign_scope();
 EXCEPTION WHEN raise_exception THEN
  UPDATE incubator_campaign SET enabled=false,note='The supported calendar cannot supply 60 completed sessions. Update calendar coverage before resuming.'; RETURN NULL;
 END;
 INSERT INTO incubator_campaign_attempt(ordinal,request_id,campaign_revision,scope,model,state) VALUES(p.ordinal,'campaign-pilot-v1-'||p.ordinal,c.revision,scope_value,model_value,'checking') RETURNING * INTO a;
 UPDATE incubator_campaign SET next_at=clock_timestamp(),note=CASE WHEN c.enabled THEN 'Checking exact diagnostic cases against assignment history.' ELSE note END;
 PERFORM append_audit_event(a.request_id||':claimed','research.campaign_candidate_claimed',now(),to_jsonb(a),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN to_jsonb(a)||jsonb_build_object('fresh',true,'title',p.title,'text',p.premise||E'\nExact diagnostic spec: '||p.spec::text);
END $$;
REVOKE ALL ON FUNCTION claim_incubator_campaign(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION claim_incubator_campaign(text) TO incubator_runner;
