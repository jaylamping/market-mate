-- Expose the creator's research premise alongside each backlog card.
CREATE OR REPLACE FUNCTION read_incubator_campaign() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT to_jsonb(c)-'id'||jsonb_build_object('open_count',incubator_campaign_open_count(),'target',10,'created_count',(SELECT count(*) FROM incubator_campaign_attempt WHERE state='queued'),
 'completed_count',(SELECT count(*) FROM incubator_campaign_attempt a WHERE a.state='queued' AND EXISTS(SELECT 1 FROM incubator_evaluation e WHERE (e.run_key=a.run_key OR e.run_key IN(SELECT fallback_run_key FROM incubator_agent_fallback WHERE parent_run_key=a.run_key)) AND read_incubator_experiment(e.id)->>'status'='completed')),
 'attempts_today',(SELECT count(*) FROM incubator_campaign_attempt WHERE receipt_time>clock_timestamp()-interval '24 hours'),
 'symbols','["AAPL","MSFT","NVDA","AMZN","GOOGL","META","TSLA","AVGO","JPM","JNJ","V","UNH","PG","MA","HD","DIS","PYPL","ADBE","CRM","NFLX"]'::jsonb,
 'backlog_count',(SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt)),
 'creator_in_progress',EXISTS(SELECT 1 FROM incubator_ticket_generation WHERE state IN('queued','dispatching')),'creator_status',(SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 1),
 'creator_usage',jsonb_build_object('lifetime',read_incubator_ticket_usage('-infinity'),'last_24h',read_incubator_ticket_usage(now()-interval '24 hours')),
 'creator_calls',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT g.id,g.model,g.state,a.receipt_time AS started_at,g.detail->'usage' AS usage,r.cost_nanos::numeric/1000000000 AS cost_usd FROM incubator_ticket_generation g JOIN openrouter_capacity_attempt a ON a.key='ticket-creator:'||g.id LEFT JOIN openrouter_capacity_result r USING(attempt_id) ORDER BY g.id DESC LIMIT 20) x),'[]'::jsonb),
 'agenda_limit',100,'agenda',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',p.ordinal,'generation_id',p.generation_id,'title',p.title,'premise',p.premise,'spec',p.spec,'state',coalesce(a.state,'pending'),'reason',a.reason,'run_key',a.run_key,'scope',a.scope) ORDER BY p.ordinal)
 FROM (SELECT * FROM incubator_campaign_candidate ORDER BY ordinal DESC LIMIT 100) p LEFT JOIN incubator_campaign_attempt a USING(ordinal)),'[]'::jsonb)) FROM incubator_campaign c
$$;
