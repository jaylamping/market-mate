-- Ticket Creator intake discards near-duplicate momentum cases: same lookback and
-- quantile count with one-way cost and borrow cost in the same 10 bps bin.
-- Campaign Check and manual admission keep the exact four-tuple contract (ADR-0011).
CREATE FUNCTION incubator_momentum_case_bucket(spec jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,public AS $$
 SELECT CASE WHEN incubator_momentum_case_fields(spec) IS NOT NULL
  AND jsonb_typeof(spec->'one_way_cost_bps')='number' AND jsonb_typeof(spec->'borrow_bps_per_session')='number'
 THEN jsonb_build_object('lookback_sessions',spec->'lookback_sessions','quantile_count',spec->'quantile_count',
  'one_way_cost_bin',floor((spec->>'one_way_cost_bps')::numeric/10),'borrow_bin',floor((spec->>'borrow_bps_per_session')::numeric/10)) END
$$;
CREATE FUNCTION incubator_used_momentum_buckets() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(DISTINCT bucket),'[]'::jsonb) FROM (
  SELECT incubator_momentum_case_bucket(spec) AS bucket FROM incubator_campaign_candidate
  UNION
  SELECT incubator_momentum_case_bucket(coalesce(incubator_momentum_case_fields(item->'spec'),incubator_momentum_case_spec(item->>'text')))
  FROM jsonb_array_elements(incubator_assignment_corpus()) item
 ) used WHERE bucket IS NOT NULL
$$;
CREATE FUNCTION incubator_momentum_case_bucket_occupant(spec jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT occupant FROM (
  SELECT incubator_momentum_case_fields(spec) AS occupant FROM incubator_campaign_candidate
  UNION ALL
  SELECT coalesce(incubator_momentum_case_fields(item->'spec'),incubator_momentum_case_spec(item->>'text'))
  FROM jsonb_array_elements(incubator_assignment_corpus()) item
 ) used
 WHERE occupant IS NOT NULL AND incubator_momentum_case_bucket(occupant) IS NOT NULL
  AND incubator_momentum_case_bucket(occupant)=incubator_momentum_case_bucket($1)
 LIMIT 1
$$;
CREATE OR REPLACE FUNCTION finish_incubator_ticket_generation(id_value bigint,state_value text,detail_value jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; g incubator_ticket_generation%ROWTYPE; p jsonb:=detail_value->'proposal'; scope_value jsonb; occupant jsonb;
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
   IF EXISTS(SELECT 1 FROM incubator_campaign_candidate WHERE spec=p->'spec') OR incubator_assignment_momentum_case_occupied(p->'spec') THEN
    detail_value:=detail_value||'{"deduplicated":true}';
   ELSE
    occupant:=incubator_momentum_case_bucket_occupant(p->'spec');
    IF occupant IS NOT NULL THEN
     detail_value:=detail_value||jsonb_build_object('deduplicated',true,'near_duplicate',true,'nearest_case',occupant);
    ELSE
     INSERT INTO incubator_campaign_candidate(title,premise,spec,generation_id) VALUES(p->>'title',p->>'premise',p->'spec',g.id);
    END IF;
   END IF;
  END IF;
 END IF;
 IF g.state='queued' THEN PERFORM cancel_openrouter_capacity('ticket-creator:'||id_value); END IF;
 UPDATE incubator_ticket_generation SET state=state_value,detail=detail_value WHERE id=id_value;
 IF state_value='indeterminate' OR (SELECT count(*) FROM (SELECT state FROM incubator_ticket_generation ORDER BY id DESC LIMIT 3) recent WHERE state='failed')=3 THEN
  UPDATE incubator_campaign SET enabled=false,note='Ticket Creator needs attention. Its recorded attempts are preserved; uncertain requests are not replayed.';
 END IF;
 PERFORM append_audit_event('ticket-creator:'||g.id||':result','research.ticket_generation_finished',now(),jsonb_build_object('state',state_value,'detail',detail_value),'{"source":"ticket-creator","entitlement_version":"campaign-v1"}',now(),'local_research');
END $$;
REVOKE ALL ON FUNCTION incubator_momentum_case_bucket(jsonb),incubator_used_momentum_buckets(),incubator_momentum_case_bucket_occupant(jsonb),finish_incubator_ticket_generation(bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION incubator_momentum_case_bucket(jsonb),incubator_used_momentum_buckets(),incubator_momentum_case_bucket_occupant(jsonb),finish_incubator_ticket_generation(bigint,text,jsonb) TO incubator_runner;
