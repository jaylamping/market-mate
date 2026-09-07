-- Bounded, owner-enabled pilot agenda. No autonomous scope or spending expansion.
CREATE TABLE incubator_campaign (
 id boolean PRIMARY KEY DEFAULT true CHECK(id),
 enabled boolean NOT NULL DEFAULT false,
 creator_model text NOT NULL DEFAULT '',
 backlog_limit integer NOT NULL DEFAULT 10 CHECK(backlog_limit BETWEEN 1 AND 20),
 revision integer NOT NULL DEFAULT 0,
 daily_limit integer NOT NULL DEFAULT 2 CHECK(daily_limit BETWEEN 1 AND 10),
 open_limit integer NOT NULL DEFAULT 3 CHECK(open_limit BETWEEN 1 AND 3),
 next_at timestamptz NOT NULL DEFAULT now(),
 note text NOT NULL DEFAULT 'Paused. Review the pilot scope and enable to start.'
);
INSERT INTO incubator_campaign(id) VALUES(true);
CREATE TABLE incubator_campaign_candidate (
 ordinal integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 title text NOT NULL,
 premise text NOT NULL,
 spec jsonb NOT NULL
);
CREATE TABLE incubator_campaign_attempt (
 ordinal integer PRIMARY KEY REFERENCES incubator_campaign_candidate,
 request_id text UNIQUE NOT NULL,
 campaign_revision integer NOT NULL,
 scope jsonb NOT NULL,
 model text NOT NULL CHECK(model LIKE '%:free'),
 state text NOT NULL CHECK(state IN ('checking','queued','duplicate','blocked','cancelled')),
 run_key text UNIQUE REFERENCES incubator_agent_run,
 reason text,
 receipt_time timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_object(table_name,kind) VALUES('incubator_campaign','control'),('incubator_campaign_candidate','control'),('incubator_campaign_attempt','control');
REVOKE ALL ON incubator_campaign,incubator_campaign_candidate,incubator_campaign_attempt FROM PUBLIC;

CREATE TABLE incubator_ticket_generation (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 campaign_revision integer NOT NULL,
 model text NOT NULL,
 state text NOT NULL CHECK(state IN('queued','dispatching','completed','failed','indeterminate','cancelled')),
 request jsonb,
 detail jsonb,
 receipt_time timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE incubator_campaign_candidate ADD COLUMN generation_id bigint NOT NULL REFERENCES incubator_ticket_generation;
INSERT INTO schema_object(table_name,kind) VALUES('incubator_ticket_generation','control');
REVOKE ALL ON incubator_ticket_generation FROM PUBLIC;
CREATE FUNCTION incubator_campaign_open_count() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT count(*) FROM incubator_campaign_attempt a
 LEFT JOIN LATERAL(SELECT coalesce(read_incubator_agent_fallback(a.run_key),read_incubator_agent_run(a.run_key)) AS r) run ON true
 LEFT JOIN LATERAL(SELECT id FROM incubator_evaluation WHERE run_key=r->>'run_key' ORDER BY revision DESC LIMIT 1) e ON true
 WHERE a.state='checking' OR (a.state='queued' AND NOT coalesce((r->>'archived')::boolean,false)
 AND (r->>'state' NOT IN ('failed','completed') OR (r->>'state'='completed'
 AND (e.id IS NULL OR (read_incubator_evaluation(e.id)->>'status' NOT IN ('close','failed','superseded')
 AND coalesce(read_incubator_experiment(e.id)->>'status','') NOT IN ('completed','failed'))))))
$$;
CREATE FUNCTION read_incubator_campaign() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT to_jsonb(c)-'id'||jsonb_build_object('open_count',incubator_campaign_open_count(),'target',10,'created_count',(SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued'),
 'completed_count',(SELECT count(*) FROM incubator_campaign_attempt a WHERE a.state='queued' AND EXISTS(SELECT 1 FROM incubator_evaluation e WHERE (e.run_key=a.run_key OR e.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) AND read_incubator_experiment(e.id)->>'status'='completed')),
 'attempts_today',(SELECT count(*) FROM incubator_campaign_attempt WHERE receipt_time>clock_timestamp()-interval '24 hours'),
 'symbols','["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","AVGO","JPM","JNJ","V","UNH","PG","MA","HD","DIS","PYPL","ADBE","CRM","NFLX"]'::jsonb,
 'backlog_count',(SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt)),
 'creator_status',(SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 1),
 'agenda',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',p.ordinal,'generation_id',p.generation_id,'title',p.title,'spec',p.spec,'state',coalesce(a.state,'pending'),'reason',a.reason,'run_key',a.run_key,'scope',a.scope) ORDER BY p.ordinal)
 FROM incubator_campaign_candidate p LEFT JOIN incubator_campaign_attempt a USING(ordinal)),'[]'::jsonb)) FROM incubator_campaign c
$$;
CREATE FUNCTION set_incubator_campaign(enabled_value boolean,daily_value integer,open_value integer,revision_value integer,creator_value text,backlog_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 IF revision_value IS DISTINCT FROM c.revision THEN RAISE EXCEPTION 'campaign_changed_refresh'; END IF;
 IF creator_value IS NULL OR (enabled_value AND creator_value='') OR length(creator_value)>256 OR backlog_value IS NULL OR backlog_value NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'invalid_campaign_creator'; END IF;
 IF enabled_value IS NULL OR daily_value IS NULL OR daily_value NOT BETWEEN 1 AND 10 OR open_value IS NULL OR open_value NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'invalid_campaign_limits'; END IF;
 UPDATE incubator_campaign SET enabled=enabled_value,creator_model=creator_value,backlog_limit=backlog_value,daily_limit=daily_value,open_limit=open_value,revision=revision+1,
 note=CASE WHEN enabled_value THEN 'Enabled. Waiting for the next eligible agenda item.' ELSE 'Paused. Existing tickets continue; no new tickets will be admitted.' END;
 PERFORM append_audit_event('campaign:config:'||(c.revision+1),'research.campaign_configured',now(),
 jsonb_build_object('before',to_jsonb(c),'after',read_incubator_campaign()),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;

-- Reuse the acquisition calendar itself instead of maintaining a second holiday list.
CREATE FUNCTION incubator_campaign_scope() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE today date:=(statement_timestamp() AT TIME ZONE 'America/New_York')::date; d jsonb; sessions jsonb:='[]'; expanded jsonb; day_value date;
BEGIN
 d:=jsonb_build_object('calendar','XNYS_2025_2026_v1','symbols',read_incubator_campaign()->'symbols','benchmark','SPY','symbol_asof',today::text,'cash','zero_interest');
 -- Candidate one-day ranges are expanded as a group of up to 60 sessions, then trimmed.
 FOR day_value IN SELECT generate_series((today-100)::timestamp,(today-1)::timestamp,interval '1 day')::date LOOP
  BEGIN
   expanded:=expand_market_data_request(d||jsonb_build_object('start',day_value::text,'end',(today-1)::text),
    '{"runner":"momentum_v1","lookback_sessions":5,"quantile_count":10,"one_way_cost_bps":10,"borrow_bps_per_session":2}');
   IF jsonb_array_length(expanded->'sessions')=60 THEN sessions:=expanded->'sessions'; EXIT; END IF;
  EXCEPTION WHEN raise_exception THEN
   IF SQLERRM NOT IN ('incompatible_panel_request') THEN RAISE; END IF;
  END;
 END LOOP;
 IF jsonb_array_length(sessions)<>60 THEN RAISE EXCEPTION 'campaign_calendar_unavailable'; END IF;
 RETURN d||jsonb_build_object('start',sessions->>0,'end',sessions->>59);
END $$;
CREATE FUNCTION claim_incubator_campaign(model_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; scope_value jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE state='checking' ORDER BY ordinal LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(a)||jsonb_build_object('fresh',false); END IF;
 IF NOT c.enabled THEN RETURN NULL; END IF;
 IF (SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued')>=10 THEN
  UPDATE incubator_campaign SET enabled=false,note='Ten-ticket admission target reached. Existing tickets continue through the workflow.'; RETURN NULL;
 END IF;
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
CREATE FUNCTION finish_incubator_campaign(ordinal_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; a incubator_campaign_attempt%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; checked jsonb; outcome text; reason_value text; r jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO a FROM incubator_campaign_attempt WHERE ordinal=ordinal_value FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown_campaign_candidate'; END IF;
 IF a.state<>'checking' THEN RETURN read_incubator_campaign(); END IF;
 checked:=read_incubator_request_check(a.request_id);
 SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal=a.ordinal;
 IF NOT c.enabled OR c.revision<>a.campaign_revision THEN outcome:='cancelled'; reason_value:='Campaign paused or changed during checking.';
 ELSIF checked->'input'->>'title' IS DISTINCT FROM p.title
 OR checked->'input'->>'text' IS DISTINCT FROM (p.premise||E'\nExact diagnostic spec: '||p.spec::text)
 OR checked->'input'->>'model' IS DISTINCT FROM a.model
 OR checked->'result'->>'complete' IS DISTINCT FROM 'true' THEN outcome:='blocked'; reason_value:='Similarity checking did not complete. Review the check before starting more work.';
 ELSIF jsonb_array_length(checked->'result'->'matches')>0 THEN outcome:='duplicate'; reason_value:='Similar research already exists; no ticket was created.';
 ELSE
  PERFORM pg_advisory_xact_lock(53001);
  LOCK TABLE incubator_assignment,incubator_plan_revision IN SHARE ROW EXCLUSIVE MODE;
  IF (SELECT corpus_digest FROM incubator_request_check WHERE request_id=a.request_id) IS DISTINCT FROM incubator_corpus_digest(incubator_assignment_corpus()) THEN
   outcome:='blocked'; reason_value:='Assignment history changed during checking. No ticket was created.';
  ELSIF incubator_campaign_open_count()>c.open_limit THEN outcome:='blocked'; reason_value:='Unfinished ticket limit reached.';
  ELSE
   SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal=a.ordinal;
   r:=admit_incubator_brief('campaign-pilot-v1-'||p.ordinal,a.model,jsonb_build_object('key',a.request_id,'title',p.title,
    'text',p.premise||E'\nCampaign-approved fixed diagnostic spec: '||p.spec::text||E'\nCampaign-approved observed data request: '||a.scope::text||E'\nPreserve this exact scope in the research plan. These are exploratory diagnostics; no parameter selection, statistical significance or independent confirmation is claimed. Record missing data and limitations. Do not change symbols, dates, benchmark, costs or runner. The existing one-session decile pilot is historical context, not an untouched holdout.',
    'classification','project_authored_research_brief','permitted_destination','openrouter','entitlement_scope','Model-proposed research premise within the approved campaign scope; no observed prices or account data.'),true);
   outcome:='queued'; reason_value:='Created by Ticket Creator and admitted after a complete duplicate check.';
  END IF;
 END IF;
 UPDATE incubator_campaign_attempt SET state=outcome,run_key=r->>'run_key',reason=reason_value WHERE ordinal=a.ordinal;
 UPDATE incubator_campaign SET note=reason_value,enabled=CASE WHEN outcome='blocked' THEN false ELSE enabled END;
 PERFORM append_audit_event(a.request_id||':finished','research.campaign_candidate_finished',now(),
 jsonb_build_object('candidate',a.ordinal,'state',outcome,'run_key',r->>'run_key','reason',reason_value,'check',checked->'result'),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;

ALTER FUNCTION next_incubator_manual_run() RENAME TO next_incubator_manual_run_before_campaign;
CREATE FUNCTION next_incubator_manual_run() RETURNS text
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(next_incubator_manual_run_before_campaign(),(SELECT r.run_key FROM incubator_campaign_attempt a
 JOIN incubator_agent_run r ON (r.run_key=a.run_key OR r.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) JOIN LATERAL(SELECT state FROM incubator_agent_event WHERE run_key=r.run_key ORDER BY sequence DESC LIMIT 1)e ON true
 WHERE a.state='queued' AND e.state IN('admitted','preparing','dispatched') AND (e.state<>'admitted' OR openrouter_capacity_ready('research:'||r.run_key))
 AND NOT EXISTS(SELECT 1 FROM incubator_agent_run x WHERE read_incubator_agent_run(x.run_key)->>'state'='indeterminate')
 ORDER BY (e.state IN('preparing','dispatched')) DESC,r.receipt_time LIMIT 1))
$$;
-- Preserve existing read wrappers and show automatic origin for campaign tickets.
ALTER FUNCTION read_incubator_agent_run(text) RENAME TO read_incubator_agent_run_before_campaign;
CREATE FUNCTION read_incubator_agent_run(key_value text) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_incubator_agent_run_before_campaign(key_value)||CASE WHEN EXISTS(SELECT 1 FROM incubator_campaign_attempt WHERE run_key=key_value) THEN '{"created_by":"agent"}'::jsonb ELSE '{}'::jsonb END
$$;
REVOKE ALL ON FUNCTION incubator_campaign_open_count(),read_incubator_campaign(),set_incubator_campaign(boolean,integer,integer,integer,text,integer),incubator_campaign_scope(),claim_incubator_campaign(text),finish_incubator_campaign(integer),next_incubator_manual_run_before_campaign(),next_incubator_manual_run(),read_incubator_agent_run_before_campaign(text),read_incubator_agent_run(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_campaign(),set_incubator_campaign(boolean,integer,integer,integer,text,integer),claim_incubator_campaign(text),finish_incubator_campaign(integer),next_incubator_manual_run(),read_incubator_agent_run(text) TO incubator_runner;
GRANT EXECUTE ON FUNCTION read_incubator_agent_run(text) TO incubator_chat;

-- Enforce the campaign contract at every downstream input boundary, including fallbacks.
CREATE FUNCTION incubator_campaign_contract(id_value bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('scope',a.scope,'spec',p.spec) FROM incubator_evaluation e
 JOIN incubator_campaign_attempt a ON (a.run_key=e.run_key OR a.run_key=(SELECT parent_run_key FROM incubator_agent_fallback WHERE fallback_run_key=e.run_key))
 JOIN incubator_campaign_candidate p USING(ordinal) WHERE e.id=id_value AND a.state='queued'
$$;
ALTER FUNCTION record_incubator_experiment_event(bigint,text,jsonb) RENAME TO record_incubator_experiment_event_before_campaign;
CREATE FUNCTION record_incubator_experiment_event(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE contract jsonb:=incubator_campaign_contract(id_value);
BEGIN
 IF contract IS NOT NULL AND state_value IN('awaiting_data','ready') THEN
  IF detail_value->'spec' IS DISTINCT FROM contract->'spec' THEN RAISE EXCEPTION 'campaign_spec_mismatch'; END IF;
  IF state_value='awaiting_data' AND detail_value->'data_request' IS DISTINCT FROM contract->'scope' THEN RAISE EXCEPTION 'campaign_scope_mismatch'; END IF;
 END IF;
 PERFORM record_incubator_experiment_event_before_campaign(id_value,state_value,detail_value);
END $$;
ALTER FUNCTION supply_market_data_request(bigint,jsonb) RENAME TO supply_market_data_request_before_campaign;
CREATE FUNCTION supply_market_data_request(id_value bigint,request_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE contract jsonb:=incubator_campaign_contract(id_value);
BEGIN
 IF contract IS NOT NULL AND request_value IS DISTINCT FROM contract->'scope' THEN RAISE EXCEPTION 'campaign_scope_mismatch'; END IF;
 PERFORM supply_market_data_request_before_campaign(id_value,request_value);
END $$;
ALTER FUNCTION bind_incubator_experiment_dataset(bigint,uuid) RENAME TO bind_incubator_experiment_dataset_before_campaign;
CREATE FUNCTION bind_incubator_experiment_dataset(id_value bigint,snapshot_value uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE contract jsonb:=incubator_campaign_contract(id_value); stored jsonb; class text;
BEGIN
 IF contract IS NOT NULL THEN
  SELECT request,panel->>'dataset_class' INTO stored,class FROM market_data_payload p JOIN market_data_dataset d ON d.id=p.dataset_id WHERE d.snapshot_id=snapshot_value;
  IF class IS DISTINCT FROM 'observed' OR (stored-'spec') IS DISTINCT FROM (expand_market_data_request(contract->'scope',contract->'spec')-'spec') THEN RAISE EXCEPTION 'campaign_dataset_mismatch'; END IF;
 END IF;
 PERFORM bind_incubator_experiment_dataset_before_campaign(id_value,snapshot_value);
END $$;
REVOKE ALL ON FUNCTION incubator_campaign_contract(bigint),record_incubator_experiment_event_before_campaign(bigint,text,jsonb),supply_market_data_request_before_campaign(bigint,jsonb),bind_incubator_experiment_dataset_before_campaign(bigint,uuid) FROM PUBLIC,incubator_runner,market_data_acquirer,market_data_service;
REVOKE ALL ON FUNCTION record_incubator_experiment_event(bigint,text,jsonb),supply_market_data_request(bigint,jsonb),bind_incubator_experiment_dataset(bigint,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION record_incubator_experiment_event(bigint,text,jsonb),supply_market_data_request(bigint,jsonb),bind_incubator_experiment_dataset(bigint,uuid) TO incubator_runner;

CREATE FUNCTION claim_incubator_ticket_generation() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; g incubator_ticket_generation%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO g FROM incubator_ticket_generation WHERE state IN('queued','dispatching') ORDER BY id LIMIT 1;
 IF FOUND THEN RETURN to_jsonb(g)||jsonb_build_object('uncertain',EXISTS(SELECT 1 FROM openrouter_capacity_attempt WHERE key='ticket-creator:'||g.id)); END IF;
 IF NOT c.enabled OR c.creator_model='' OR (SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued')>=10
 OR (SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt))>=c.backlog_limit
 OR (SELECT count(*) FROM incubator_ticket_generation WHERE receipt_time>clock_timestamp()-interval '24 hours')>=40 THEN RETURN NULL; END IF;
 INSERT INTO incubator_ticket_generation(campaign_revision,model,state) VALUES(c.revision,c.creator_model,'queued') RETURNING * INTO g;
 PERFORM append_audit_event('ticket-creator:'||g.id||':queued','research.ticket_generation_queued',now(),to_jsonb(g),'{"source":"ticket-creator","entitlement_version":"campaign-v1"}',now(),'local_research');
 RETURN to_jsonb(g);
END $$;
CREATE FUNCTION prepare_incubator_ticket_generation(id_value bigint,request_value jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; g incubator_ticket_generation%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO STRICT g FROM incubator_ticket_generation WHERE id=id_value FOR UPDATE;
 IF NOT c.enabled OR c.revision<>g.campaign_revision THEN UPDATE incubator_ticket_generation SET state='cancelled',detail='{"reason":"campaign_changed"}' WHERE id=id_value; PERFORM cancel_openrouter_capacity('ticket-creator:'||id_value); RETURN false; END IF;
 IF g.state<>'queued' THEN RAISE EXCEPTION 'generation_already_dispatched'; END IF;
 IF request_value->>'model' IS DISTINCT FROM g.model OR coalesce((request_value->>'max_tokens')::int,(request_value->>'max_completion_tokens')::int,0) NOT BETWEEN 1 AND 2048 OR octet_length(request_value::text)>96000 THEN RAISE EXCEPTION 'invalid_generation_request'; END IF;
 IF g.request IS NOT NULL AND g.request IS DISTINCT FROM request_value THEN RAISE EXCEPTION 'generation_request_changed'; END IF;
 UPDATE incubator_ticket_generation SET request=request_value WHERE id=id_value;
 RETURN true;
END $$;
CREATE FUNCTION dispatch_incubator_ticket_generation(id_value bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE g incubator_ticket_generation%ROWTYPE; c incubator_campaign%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO STRICT g FROM incubator_ticket_generation WHERE id=id_value FOR UPDATE;
 IF NOT c.enabled OR c.revision<>g.campaign_revision THEN
  UPDATE incubator_ticket_generation SET state='cancelled',detail='{"reason":"campaign_changed_before_dispatch"}' WHERE id=id_value;
  PERFORM append_audit_event('ticket-creator:'||g.id||':cancelled','research.ticket_generation_cancelled',now(),jsonb_build_object('model',g.model,'reason','campaign_changed_before_dispatch'),'{"source":"ticket-creator","entitlement_version":"campaign-v1"}',now(),'local_research');
  RETURN false;
 END IF;
 IF g.state<>'queued' OR g.request IS NULL THEN RAISE EXCEPTION 'generation_not_prepared'; END IF;
 UPDATE incubator_ticket_generation SET state='dispatching' WHERE id=id_value;
 PERFORM append_audit_event('ticket-creator:'||g.id||':dispatch','research.ticket_generation_dispatched',now(),jsonb_build_object('model',g.model,'request',g.request),'{"source":"ticket-creator","entitlement_version":"campaign-v1"}',now(),'local_research');
 RETURN true;
END $$;
CREATE FUNCTION finish_incubator_ticket_generation(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; g incubator_ticket_generation%ROWTYPE; p jsonb:=detail_value->'proposal'; scope_value jsonb;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT * INTO STRICT g FROM incubator_ticket_generation WHERE id=id_value FOR UPDATE;
 IF g.state NOT IN('queued','dispatching') THEN RETURN; END IF;
 IF state_value NOT IN('completed','failed','indeterminate') OR detail_value IS NULL OR octet_length(detail_value::text)>64000 THEN RAISE EXCEPTION 'invalid_generation_result'; END IF;
 IF state_value='completed' THEN
  IF g.state<>'dispatching' THEN RAISE EXCEPTION 'generation_not_dispatched'; END IF;
  IF NOT c.enabled OR c.revision<>g.campaign_revision THEN state_value:='cancelled';
  ELSE
   IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(p))<>3 OR coalesce(length(btrim(p->>'title')),0)=0 OR octet_length(p->>'title')>240 OR coalesce(length(btrim(p->>'premise')),0)=0 OR octet_length(p->>'premise')>3000 OR incubator_json_claims_authority(p) THEN RAISE EXCEPTION 'invalid_ticket_proposal'; END IF;
   scope_value:=incubator_campaign_scope();
   PERFORM expand_market_data_request(scope_value,p->'spec');
   IF NOT EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE spec=p->'spec') THEN
    INSERT INTO incubator_campaign_candidate(title,premise,spec,generation_id) VALUES(p->>'title',p->>'premise',p->'spec',g.id);
   ELSE detail_value:=detail_value||'{"deduplicated":true}'; END IF;
  END IF;
 END IF;
 IF g.state='queued' THEN PERFORM cancel_openrouter_capacity('ticket-creator:'||id_value); END IF;
 UPDATE incubator_ticket_generation SET state=state_value,detail=detail_value WHERE id=id_value;
 IF state_value='indeterminate' OR (SELECT count(*) FROM (SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 3) recent WHERE state='failed')=3 THEN
  UPDATE incubator_campaign SET enabled=false,note='Ticket Creator needs attention. Its recorded attempts are preserved; uncertain requests are not replayed.';
 END IF;
 PERFORM append_audit_event('ticket-creator:'||g.id||':result','research.ticket_generation_finished',now(),jsonb_build_object('state',state_value,'detail',detail_value),'{"source":"ticket-creator","entitlement_version":"campaign-v1"}',now(),'local_research');
END $$;
REVOKE ALL ON FUNCTION claim_incubator_ticket_generation(),prepare_incubator_ticket_generation(bigint,jsonb),dispatch_incubator_ticket_generation(bigint),finish_incubator_ticket_generation(bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION claim_incubator_ticket_generation(),prepare_incubator_ticket_generation(bigint,jsonb),dispatch_incubator_ticket_generation(bigint),finish_incubator_ticket_generation(bigint,text,jsonb) TO incubator_runner;

CREATE FUNCTION incubator_campaign_free_work(key_value text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE id_value bigint;
BEGIN
 IF key_value LIKE 'research:campaign-pilot-v1-%' OR key_value LIKE 'similarity:campaign-pilot-v1-%' THEN RETURN true; END IF;
 IF key_value ~ '^(evaluation|experiment|refinement):[0-9]+(:|$)' THEN
  id_value:=split_part(key_value,':',2)::bigint;
  RETURN incubator_campaign_contract(id_value) IS NOT NULL;
 END IF;
 IF key_value LIKE 'research:fallback-%' THEN
  RETURN EXISTS(SELECT 1 FROM incubator_agent_fallback f JOIN incubator_campaign_attempt a ON a.run_key=f.parent_run_key WHERE key_value LIKE 'research:'||f.fallback_run_key||'%');
 END IF;
 RETURN false;
END $$;
REVOKE ALL ON FUNCTION incubator_campaign_free_work(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_campaign_free_work(text) TO incubator_runner,incubator_chat;
