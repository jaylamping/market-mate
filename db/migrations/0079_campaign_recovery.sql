-- Retry creates a linked proposal; original checks and dispatch receipts remain immutable.
ALTER TABLE incubator_campaign_candidate ADD COLUMN retry_of integer UNIQUE REFERENCES incubator_campaign_candidate(ordinal);
CREATE FUNCTION incubator_campaign_retry_blocker(ordinal_value integer) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT CASE
 WHEN a.ordinal IS NULL OR a.state NOT IN ('blocked','cancelled') THEN 'Only failed or cancelled checks can be retried.'
 WHEN EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE retry_of=ordinal_value) THEN 'A retry already exists.'
 WHEN EXISTS(SELECT 1 FROM openrouter_capacity_attempt d LEFT JOIN openrouter_capacity_result r USING(attempt_id)
  WHERE d.key LIKE 'similarity:'||a.request_id||':%' AND (r.attempt_id IS NULL OR r.outcome->>'state' IS NULL OR r.outcome->>'state'='indeterminate'))
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(read_incubator_request_check(a.request_id)->'result'->'attempts','[]'::jsonb)) t WHERE t->>'state'='indeterminate')
 THEN 'Reconcile the uncertain provider request before retrying.'
 ELSE NULL END FROM (SELECT ordinal_value AS ordinal) p LEFT JOIN incubator_campaign_attempt a USING(ordinal)
$$;
CREATE FUNCTION retry_incubator_campaign(ordinal_value integer,revision_value integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; p incubator_campaign_candidate%ROWTYPE; child integer; blocker text;
BEGIN
 SELECT * INTO c FROM incubator_campaign WHERE id FOR UPDATE;
 SELECT ordinal INTO child FROM incubator_campaign_candidate WHERE retry_of=ordinal_value;
 IF FOUND THEN RETURN read_incubator_campaign(); END IF;
 IF revision_value IS DISTINCT FROM c.revision THEN RAISE EXCEPTION 'campaign_changed_refresh'; END IF;
 blocker:=incubator_campaign_retry_blocker(ordinal_value);
 IF blocker IS NOT NULL THEN RAISE EXCEPTION '%',blocker; END IF;
 IF (SELECT count(*) FROM incubator_campaign_candidate WHERE ordinal NOT IN(SELECT ordinal FROM incubator_campaign_attempt))>=c.backlog_limit THEN RAISE EXCEPTION 'campaign_backlog_full'; END IF;
 SELECT * INTO STRICT p FROM incubator_campaign_candidate WHERE ordinal=ordinal_value;
 INSERT INTO incubator_campaign_candidate(title,premise,spec,generation_id,retry_of) VALUES(p.title,p.premise,p.spec,p.generation_id,p.ordinal) RETURNING ordinal INTO child;
 PERFORM append_audit_event('campaign-retry:'||p.ordinal,'research.campaign_retry_requested',now(),
 jsonb_build_object('original_candidate',p.ordinal,'candidate',child,'original_request_id',(SELECT request_id FROM incubator_campaign_attempt WHERE ordinal=p.ordinal),'campaign_revision',c.revision),
 '{"source":"research-campaign","entitlement_version":"campaign-recovery-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;

ALTER FUNCTION read_incubator_campaign() RENAME TO read_incubator_campaign_before_recovery;
CREATE FUNCTION read_incubator_campaign() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 WITH base AS (SELECT read_incubator_campaign_before_recovery() AS value), latest AS (SELECT * FROM incubator_ticket_generation ORDER BY id DESC LIMIT 1)
 SELECT value||jsonb_build_object(
 'note',CASE WHEN value->>'enabled'='false' AND value->>'note' IN ('Campaign paused or changed during checking.','Ticket Creator needs attention. Its recorded attempts are preserved; uncertain requests are not replayed.')
 AND (SELECT state FROM latest) IN ('failed','indeterminate') THEN
 'Ticket Creator call #'||(SELECT id FROM latest)||' stopped: '||coalesce((SELECT detail->>'validation_error' FROM latest),(SELECT detail->>'reason' FROM latest),'unknown failure')||'. Review its request and response before resuming.' ELSE value->>'note' END,
 'creator_calls',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (
 SELECT g.id,g.model,g.state,g.detail->>'reason' AS reason,g.detail->>'response_text' AS response_text,g.detail->>'validation_error' AS validation_error,
 g.detail->'response_truncated' AS response_truncated,g.detail->'finish_reason' AS finish_reason,g.detail->'usage' AS usage,g.detail AS diagnostics,
 g.receipt_time AS started_at,'ticket-creator:'||g.id AS request_id,g.request,r.cost_nanos::numeric/1000000000 AS cost_usd
 FROM incubator_ticket_generation g LEFT JOIN openrouter_capacity_attempt a ON a.key='ticket-creator:'||g.id LEFT JOIN openrouter_capacity_result r USING(attempt_id)
 ORDER BY g.id DESC LIMIT 20) x),'[]'::jsonb),
 'agenda',coalesce((SELECT jsonb_agg(item||jsonb_build_object('retry_of',p.retry_of,'retry_candidate',(SELECT ordinal FROM incubator_campaign_candidate WHERE retry_of=p.ordinal),
 'retry_blocker',incubator_campaign_retry_blocker(p.ordinal),'request_id',a.request_id,'check_input',read_incubator_request_check(a.request_id)->'input',
 'creator_call',(SELECT jsonb_build_object('request_id','ticket-creator:'||g.id,'state',g.state,'request',g.request,'diagnostics',g.detail) FROM incubator_ticket_generation g WHERE g.id=p.generation_id),
 'check_requests',coalesce((SELECT jsonb_agg(jsonb_build_object('event_id',e.event_id,'request',e.payload->'request') ORDER BY e.chain_position) FROM audit_event e WHERE e.event_type='research.similarity_dispatched' AND e.payload->>'request_id'=a.request_id),'[]'::jsonb)) ORDER BY p.ordinal)
 FROM jsonb_array_elements(value->'agenda') item JOIN incubator_campaign_candidate p ON p.ordinal=(item->>'ordinal')::integer LEFT JOIN incubator_campaign_attempt a USING(ordinal)),'[]'::jsonb)) FROM base
$$;
REVOKE ALL ON FUNCTION read_incubator_campaign_before_recovery(),incubator_campaign_retry_blocker(integer),retry_incubator_campaign(integer,integer),read_incubator_campaign() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_incubator_campaign(),retry_incubator_campaign(integer,integer) TO incubator_runner;

CREATE FUNCTION incubator_ticket_dispatch_recorded(id_value bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT EXISTS(SELECT 1 FROM openrouter_capacity_attempt WHERE key='ticket-creator:'||id_value)
$$;
REVOKE ALL ON FUNCTION incubator_ticket_dispatch_recorded(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_ticket_dispatch_recorded(bigint) TO incubator_runner;

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
 IF NOT c.enabled OR c.revision<>a.campaign_revision THEN outcome:='cancelled'; reason_value:='Check cancelled. '||(read_incubator_campaign()->>'note');
 ELSIF checked->'input'->>'title' IS DISTINCT FROM p.title
 OR checked->'input'->>'text' IS DISTINCT FROM (p.premise||E'\nExact diagnostic spec: '||p.spec::text)
 OR checked->'input'->>'model' IS DISTINCT FROM a.model
 OR checked->'result'->>'complete' IS DISTINCT FROM 'true' THEN outcome:='blocked'; reason_value:='Similarity check stopped: '||coalesce((SELECT string_agg(issue,'; ') FROM jsonb_array_elements_text(checked->'result'->'issues') issue),'Check input changed or its result was not recorded. Review request history before retrying.');
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
 jsonb_build_object('request_id',a.request_id,'candidate',a.ordinal,'state',outcome,'run_key',r->>'run_key','reason',reason_value,'check',checked->'result'),'{"source":"research-campaign","entitlement_version":"pilot-agenda-v1"}',now(),'local_research');
 RETURN read_incubator_campaign();
END $$;
