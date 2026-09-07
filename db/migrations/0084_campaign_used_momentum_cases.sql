-- Ticket Creator sees every occupied momentum case, including assignment history.
CREATE FUNCTION incubator_used_momentum_cases() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(DISTINCT case_fields),'[]'::jsonb) FROM (
  SELECT incubator_momentum_case_fields(spec) AS case_fields FROM incubator_campaign_candidate
  UNION
  SELECT coalesce(incubator_momentum_case_fields(item->'spec'),incubator_momentum_case_spec(item->>'text'))
  FROM jsonb_array_elements(incubator_assignment_corpus()) item
 ) used WHERE case_fields IS NOT NULL
$$;
CREATE FUNCTION incubator_assignment_momentum_case_occupied(spec jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT incubator_momentum_case_fields(spec) IS NOT NULL AND EXISTS (
  SELECT 1 FROM jsonb_array_elements(incubator_assignment_corpus()) item
  WHERE incubator_momentum_case_fields(spec)=coalesce(incubator_momentum_case_fields(item->'spec'),incubator_momentum_case_spec(item->>'text'))
 )
$$;
CREATE OR REPLACE FUNCTION finish_incubator_ticket_generation(id_value bigint,state_value text,detail_value jsonb) RETURNS void
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
   IF NOT EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE spec=p->'spec')
    AND NOT incubator_assignment_momentum_case_occupied(p->'spec') THEN
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
REVOKE ALL ON FUNCTION incubator_used_momentum_cases(),incubator_assignment_momentum_case_occupied(jsonb),finish_incubator_ticket_generation(bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_used_momentum_cases(),incubator_assignment_momentum_case_occupied(jsonb),finish_incubator_ticket_generation(bigint,text,jsonb) TO incubator_runner;
