-- Keep stopped candidates and provider failures inspectable without replaying work.
CREATE OR REPLACE FUNCTION read_incubator_campaign() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT to_jsonb(c)-'id'||jsonb_build_object('open_count',incubator_campaign_open_count(),'target',10,'created_count',(SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued'),
 'completed_count',(SELECT count(*) FROM incubator_campaign_attempt a WHERE a.state='queued' AND EXISTS(SELECT 1 FROM incubator_evaluation e WHERE (e.run_key=a.run_key OR e.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) AND read_incubator_experiment(e.id)->>'status'='completed')),
 'attempts_today',(SELECT count(*) FROM incubator_campaign_attempt WHERE receipt_time>clock_timestamp()-interval '24 hours'),
 'symbols','["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","AVGO","JPM","JNJ","V","UNH","PG","MA","HD","DIS","PYPL","ADBE","CRM","NFLX"]'::jsonb,
 'backlog_count',(SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt)),
 'creator_in_progress',EXISTS(SELECT 1 FROM incubator_ticket_generation WHERE state IN('queued','dispatching')),'creator_status',(SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 1),
 'creator_usage',jsonb_build_object('lifetime',read_incubator_ticket_usage('-infinity'),'last_24h',read_incubator_ticket_usage(now()-interval '24 hours')),
 'creator_calls',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT g.id,g.model,g.state,g.detail->>'reason' AS reason,g.detail->>'response_text' AS response_text,g.detail->>'validation_error' AS validation_error,g.detail->'response_truncated' AS response_truncated,a.receipt_time AS started_at,g.detail->'usage' AS usage,r.cost_nanos::numeric/1000000000 AS cost_usd FROM incubator_ticket_generation g JOIN openrouter_capacity_attempt a ON a.key='ticket-creator:'||g.id LEFT JOIN openrouter_capacity_result r USING(attempt_id) ORDER BY g.id DESC LIMIT 20) x),'[]'::jsonb),
 'agenda_limit',100,'agenda',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',p.ordinal,'generation_id',p.generation_id,'title',p.title,'premise',p.premise,'creator_model',(SELECT model FROM incubator_ticket_generation WHERE id=p.generation_id),'check',read_incubator_request_check(a.request_id)->'result','spec',p.spec,'state',coalesce(a.state,'pending'),'reason',a.reason,'run_key',a.run_key,'scope',a.scope) ORDER BY p.ordinal)
 FROM (SELECT * FROM incubator_campaign_candidate ORDER BY ordinal DESC LIMIT 100) p LEFT JOIN incubator_campaign_attempt a USING(ordinal)),'[]'::jsonb)) FROM incubator_campaign c
$$;

-- A cancelled check must not replace the creator failure or owner pause explanation.
CREATE OR REPLACE FUNCTION finish_incubator_campaign(ordinal_value integer) RETURNS jsonb
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
 UPDATE incubator_campaign SET note=CASE WHEN outcome='cancelled' THEN note ELSE reason_value END,enabled=CASE WHEN outcome='blocked' THEN false ELSE enabled END;
 PERFORM append_audit_event(a.request_id||':finished','research.campaign_candidate_finished',now(),
 jsonb_build_object('candidate',a.ordinal,'state',outcome,'run_key',r->>'run_key','reason',reason_value,'check',checked->'result'),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;

