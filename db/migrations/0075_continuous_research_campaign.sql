-- Continuous intake: the ten-completion milestone does not stop admission.
ALTER TABLE incubator_campaign DROP CONSTRAINT incubator_campaign_backlog_limit_check,
 DROP CONSTRAINT incubator_campaign_daily_limit_check, DROP CONSTRAINT incubator_campaign_open_limit_check;
ALTER TABLE incubator_campaign ADD CHECK(backlog_limit BETWEEN 1 AND 100),
 ADD CHECK(daily_limit BETWEEN 1 AND 100), ADD CHECK(open_limit BETWEEN 1 AND 20);
ALTER TABLE incubator_campaign ALTER COLUMN backlog_limit SET DEFAULT 100,
 ALTER COLUMN daily_limit SET DEFAULT 50, ALTER COLUMN open_limit SET DEFAULT 10;
CREATE FUNCTION read_incubator_ticket_usage(since_value timestamptz) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('calls',count(*),
 'input_tokens',coalesce(sum(CASE WHEN g.detail->'usage'->>'prompt_tokens' ~ '^[0-9]+$' THEN (g.detail->'usage'->>'prompt_tokens')::numeric END),0),
 'output_tokens',coalesce(sum(CASE WHEN g.detail->'usage'->>'completion_tokens' ~ '^[0-9]+$' THEN (g.detail->'usage'->>'completion_tokens')::numeric END),0),
 'reasoning_tokens',coalesce(sum(CASE WHEN g.detail->'usage'->'completion_tokens_details'->>'reasoning_tokens' ~ '^[0-9]+$' THEN (g.detail->'usage'->'completion_tokens_details'->>'reasoning_tokens')::numeric END),0),
 'unknown_token_calls',count(*) FILTER(WHERE (g.detail->'usage'->>'prompt_tokens' ~ '^[0-9]+$') IS NOT TRUE OR (g.detail->'usage'->>'completion_tokens' ~ '^[0-9]+$') IS NOT TRUE),
 'known_cost_usd',coalesce(sum(r.cost_nanos),0)::numeric/1000000000,
 'unknown_cost_calls',count(*) FILTER(WHERE r.cost_nanos IS NULL))
 FROM incubator_ticket_generation g JOIN openrouter_capacity_attempt a ON a.key='ticket-creator:'||g.id
 LEFT JOIN openrouter_capacity_result r USING(attempt_id) WHERE a.receipt_time>=since_value
$$;
REVOKE ALL ON FUNCTION read_incubator_ticket_usage(timestamptz) FROM PUBLIC;
CREATE OR REPLACE FUNCTION read_incubator_campaign() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT to_jsonb(c)-'id'||jsonb_build_object('open_count',incubator_campaign_open_count(),'target',10,'created_count',(SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued'),
 'completed_count',(SELECT count(*) FROM incubator_campaign_attempt a WHERE a.state='queued' AND EXISTS(SELECT 1 FROM incubator_evaluation e WHERE (e.run_key=a.run_key OR e.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) AND read_incubator_experiment(e.id)->>'status'='completed')),
 'attempts_today',(SELECT count(*) FROM incubator_campaign_attempt WHERE receipt_time>clock_timestamp()-interval '24 hours'),
 'symbols','["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","AVGO","JPM","JNJ","V","UNH","PG","MA","HD","DIS","PYPL","ADBE","CRM","NFLX"]'::jsonb,
 'backlog_count',(SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt)),
 'creator_status',(SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 1),
 'creator_usage',jsonb_build_object('lifetime',read_incubator_ticket_usage('-infinity'),'last_24h',read_incubator_ticket_usage(now()-interval '24 hours')),
 'creator_calls',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT g.id,g.model,g.state,a.receipt_time AS started_at,g.detail->'usage' AS usage,r.cost_nanos::numeric/1000000000 AS cost_usd FROM incubator_ticket_generation g JOIN openrouter_capacity_attempt a ON a.key='ticket-creator:'||g.id LEFT JOIN openrouter_capacity_result r USING(attempt_id) ORDER BY g.id DESC LIMIT 20) x),'[]'::jsonb),
 'agenda_limit',100,'agenda',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',p.ordinal,'generation_id',p.generation_id,'title',p.title,'spec',p.spec,'state',coalesce(a.state,'pending'),'reason',a.reason,'run_key',a.run_key,'scope',a.scope) ORDER BY p.ordinal)
 FROM (SELECT * FROM incubator_campaign_candidate ORDER BY ordinal DESC LIMIT 100) p LEFT JOIN incubator_campaign_attempt a USING(ordinal)),'[]'::jsonb)) FROM incubator_campaign c
$$;
CREATE OR REPLACE FUNCTION set_incubator_campaign(enabled_value boolean,daily_value integer,open_value integer,revision_value integer,creator_value text,backlog_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 IF revision_value IS DISTINCT FROM c.revision THEN RAISE EXCEPTION 'campaign_changed_refresh'; END IF;
 IF creator_value IS NULL OR (enabled_value AND creator_value='') OR length(creator_value)>256 OR backlog_value IS NULL OR backlog_value NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_campaign_creator'; END IF;
 IF enabled_value IS NULL OR daily_value IS NULL OR daily_value NOT BETWEEN 1 AND 100 OR open_value IS NULL OR open_value NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'invalid_campaign_limits'; END IF;
 UPDATE incubator_campaign SET enabled=enabled_value,creator_model=creator_value,backlog_limit=backlog_value,daily_limit=daily_value,open_limit=open_value,revision=revision+1,
 note=CASE WHEN enabled_value THEN 'Enabled. Waiting for the next eligible agenda item.' ELSE 'Paused. Existing tickets continue; no new tickets will be admitted.' END;
 PERFORM append_audit_event('campaign:config:'||(c.revision+1),'research.campaign_configured',now(),
 jsonb_build_object('before',to_jsonb(c),'after',read_incubator_campaign()),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;
CREATE OR REPLACE FUNCTION claim_incubator_campaign(model_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; scope_value jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE state='checking' ORDER BY ordinal LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(a)||jsonb_build_object('fresh',false); END IF;
 IF NOT c.enabled THEN RETURN NULL; END IF;
 IF clock_timestamp()<c.next_at THEN RETURN NULL; END IF;
 IF (SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued' AND receipt_time>clock_timestamp()-interval '24 hours')>=c.daily_limit OR incubator_campaign_open_count()>=c.open_limit THEN RETURN NULL; END IF;
 IF model_value IS NULL OR model_value !~ '^[a-zA-Z0-9._/-]+:free$' OR model_value LIKE 'openrouter/%' THEN UPDATE incubator_campaign SET note='Waiting for an approved free Research model. Configure Models to continue.'; RETURN NULL; END IF;
 SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt) ORDER BY ordinal LIMIT 1;
 IF NOT FOUND THEN UPDATE incubator_campaign SET note='Waiting for Ticket Creator to stock the backlog.'; RETURN NULL; END IF;
 IF NOT EXISTS(SELECT 1 FROM market_data_source WHERE market_data_source_available(id)) THEN
  UPDATE incubator_campaign SET note='Waiting for an available market data connection.'; RETURN NULL;
 END IF;
 BEGIN
  scope_value:=incubator_campaign_scope();
 EXCEPTION WHEN raise_exception THEN
  UPDATE incubator_campaign SET enabled=false,note='The supported calendar cannot supply 60 completed sessions. Update calendar coverage before resuming.'; RETURN NULL;
 END;
 INSERT INTO incubator_campaign_attempt(ordinal,request_id,campaign_revision,scope,model,state) VALUES(p.ordinal,'campaign-pilot-v1-'||p.ordinal,c.revision,scope_value,model_value,'checking') RETURNING * INTO a;
 UPDATE incubator_campaign SET next_at=clock_timestamp()+interval '60 seconds',note='Checking the next research question against assignment history.';
 PERFORM append_audit_event(a.request_id||':claimed','research.campaign_candidate_claimed',now(),to_jsonb(a),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN to_jsonb(a)||jsonb_build_object('fresh',true,'title',p.title,'text',p.premise||E'\nExact diagnostic spec: '||p.spec::text);
END $$;
CREATE OR REPLACE FUNCTION claim_incubator_ticket_generation() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; g incubator_ticket_generation%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO g FROM incubator_ticket_generation WHERE state IN('queued','dispatching') ORDER BY id LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(g)||jsonb_build_object('uncertain',EXISTS(SELECT 1 FROM openrouter_capacity_attempt WHERE key='ticket-creator:'||g.id)); END IF;
 IF NOT c.enabled OR c.creator_model=''
 OR (SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt))>=c.backlog_limit
 OR (SELECT count(*) FROM incubator_ticket_generation WHERE receipt_time>clock_timestamp()-interval '24 hours')>=500 THEN RETURN NULL; END IF;
 INSERT INTO incubator_ticket_generation(campaign_revision,model,state) VALUES(c.revision,c.creator_model,'queued') RETURNING * INTO g;
 PERFORM append_audit_event('ticket-creator:'||g.id||':queued','research.ticket_generation_queued',now(),to_jsonb(g),'{"source":"ticket-creator","entitlement_version":"campaign-v1"}',now(),'local_research');
 RETURN to_jsonb(g);
END $$;
