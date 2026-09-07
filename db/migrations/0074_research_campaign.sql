-- Bounded, owner-enabled pilot agenda. No autonomous scope or spending expansion.
CREATE TABLE incubator_campaign (
 id boolean PRIMARY KEY DEFAULT true CHECK(id),
 enabled boolean NOT NULL DEFAULT false,
 revision integer NOT NULL DEFAULT 0,
 daily_limit integer NOT NULL DEFAULT 2 CHECK(daily_limit BETWEEN 1 AND 10),
 open_limit integer NOT NULL DEFAULT 3 CHECK(open_limit BETWEEN 1 AND 3),
 next_at timestamptz NOT NULL DEFAULT now(),
 note text NOT NULL DEFAULT 'Paused. Review the pilot scope and enable to start.'
);
INSERT INTO incubator_campaign(id) VALUES(true);
CREATE TABLE incubator_campaign_candidate (
 ordinal integer PRIMARY KEY,
 title text NOT NULL,
 premise text NOT NULL,
 spec jsonb NOT NULL
);
INSERT INTO incubator_campaign_candidate VALUES
 (1,'Does three-session momentum retain an after-cost edge?',
 'Test whether ranking three-session trailing close returns produces positive next-open to close long-short mean returns after explicit costs, relative to SPY and zero-interest cash. Falsify this bounded premise if its net mean fails either baseline. Explain economic persistence and why this differs from the existing one-session pilot.',
 '{"runner":"momentum_v1","lookback_sessions":3,"quantile_count":10,"one_way_cost_bps":10,"borrow_bps_per_session":2}'),
 (2,'Does broader portfolio participation improve momentum economics?',
 'Test a five-quantile portfolio, holding the top and bottom fifth of the universe at equal weight and total gross exposure one. Use one-session rankings. Falsify its bounded after-cost premise if its next-open net mean fails SPY or cash. Explain diversification versus dilution and preserve the distinction from the existing decile pilot.',
 '{"runner":"momentum_v1","lookback_sessions":1,"quantile_count":5,"one_way_cost_bps":10,"borrow_bps_per_session":2}'),
 (3,'Can slower momentum withstand a larger execution-cost hurdle?',
 'Test a five-session trailing-close signal under 25 basis points per side and two basis points of borrowing per session, with next-open entry and same-session close exit. Reject the bounded premise if the mean net return does not exceed SPY and cash. Explain the economic cost hurdle, distinguish signal lookback from holding duration, and do not infer profitability from model agreement.',
 '{"runner":"momentum_v1","lookback_sessions":5,"quantile_count":10,"one_way_cost_bps":25,"borrow_bps_per_session":2}');
-- Distinct registered parameter questions, with spare candidates when history overlaps.
INSERT INTO incubator_campaign_candidate
SELECT row_number() OVER(ORDER BY lookback,quantiles,cost)+3,
 format('Does %s-session momentum with %s quantiles survive %s bps per side?',lookback,quantiles,cost),
 format('Study persistence of %s-session trailing-close rankings using %s quantiles at %s basis points per side and 2 basis points of borrowing per session. Form equal-weight top and bottom groups with total gross exposure one; enter next open and exit that session close. The bounded falsifiable premise is that mean net return exceeds both SPY over the same entry/exit interval and zero-interest cash. Distinguish this exact parameter case from other campaign cases. This is a predeclared exploratory sensitivity case, not selection of a profitable strategy or a statistical confirmation. No extra data, bootstrap, changing exposure, or multi-day holding is required.',lookback,quantiles,cost),
 jsonb_build_object('runner','momentum_v1','lookback_sessions',lookback,'quantile_count',quantiles,'one_way_cost_bps',cost,'borrow_bps_per_session',2)
FROM (VALUES(1),(2),(3),(4),(5)) l(lookback) CROSS JOIN (VALUES(2),(5),(10)) q(quantiles) CROSS JOIN (VALUES(5),(15)) c(cost);
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
 'agenda',(SELECT jsonb_agg(jsonb_build_object('ordinal',p.ordinal,'title',p.title,'spec',p.spec,'state',coalesce(a.state,'pending'),'reason',a.reason,'run_key',a.run_key,'scope',a.scope) ORDER BY p.ordinal)
 FROM incubator_campaign_candidate p LEFT JOIN incubator_campaign_attempt a USING(ordinal))) FROM incubator_campaign c
$$;
CREATE FUNCTION set_incubator_campaign(enabled_value boolean,daily_value integer,open_value integer,revision_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 IF revision_value IS DISTINCT FROM c.revision THEN RAISE EXCEPTION 'campaign_changed_refresh'; END IF;
 IF enabled_value IS NULL OR daily_value IS NULL OR daily_value NOT BETWEEN 1 AND 10 OR open_value IS NULL OR open_value NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'invalid_campaign_limits'; END IF;
 UPDATE incubator_campaign SET enabled=enabled_value,daily_limit=daily_value,open_limit=open_value,revision=revision+1,
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
 IF (SELECT count(*) FROM incubator_campaign_attempt WHERE receipt_time>clock_timestamp()-interval '24 hours')>=c.daily_limit OR incubator_campaign_open_count()>=c.open_limit THEN RETURN NULL; END IF;
 IF model_value IS NULL OR model_value !~ '^[a-zA-Z0-9._/-]+:free$' OR model_value LIKE 'openrouter/%' THEN UPDATE incubator_campaign SET note='Waiting for an approved free Research model. Configure Models to continue.'; RETURN NULL; END IF;
 SELECT * INTO p FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt) ORDER BY ordinal LIMIT 1;
 IF NOT FOUND THEN UPDATE incubator_campaign SET enabled=false,note='Agenda complete. Review its results before adding another campaign.'; RETURN NULL; END IF;
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
    'classification','project_authored_research_brief','permitted_destination','openrouter','entitlement_scope','Project-authored pilot agenda and scope only; no observed prices or account data.'),true);
   outcome:='queued'; reason_value:='Created from the pilot agenda after a complete duplicate check.';
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
REVOKE ALL ON FUNCTION incubator_campaign_open_count(),read_incubator_campaign(),set_incubator_campaign(boolean,integer,integer,integer),incubator_campaign_scope(),claim_incubator_campaign(text),finish_incubator_campaign(integer),next_incubator_manual_run_before_campaign(),next_incubator_manual_run(),read_incubator_agent_run_before_campaign(text),read_incubator_agent_run(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_campaign(),set_incubator_campaign(boolean,integer,integer,integer),claim_incubator_campaign(text),finish_incubator_campaign(integer),next_incubator_manual_run(),read_incubator_agent_run(text) TO incubator_runner;
GRANT EXECUTE ON FUNCTION read_incubator_agent_run(text) TO incubator_chat;
