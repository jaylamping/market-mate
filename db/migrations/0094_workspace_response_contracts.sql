-- Preserve typed configuration responses and scope canonical history to explicit offerings.
CREATE FUNCTION model_offerings_typed(value jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,public AS $$
 SELECT NOT EXISTS(SELECT FROM jsonb_array_elements(value) x WHERE
  jsonb_typeof(x->'provider_id') IS DISTINCT FROM 'string'
  OR jsonb_typeof(x->'model_id') IS DISTINCT FROM 'string'
  OR jsonb_typeof(x->'priority') IS DISTINCT FROM 'number'
  OR jsonb_typeof(x->'weight') IS DISTINCT FROM 'number'
  OR (x ? 'requests_per_day' AND jsonb_typeof(x->'requests_per_day') NOT IN('number','null'))
  OR (x ? 'paid_daily_cap' AND jsonb_typeof(x->'paid_daily_cap') NOT IN('number','null')))
$$;
CREATE FUNCTION model_order_typed(value jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,public AS $$
 SELECT NOT EXISTS(SELECT FROM jsonb_array_elements(value) x WHERE jsonb_typeof(x)<>'string')
 AND (SELECT count(*)=count(DISTINCT x) FROM jsonb_array_elements(value) x)
$$;
ALTER TABLE model_policy ADD CHECK(model_offerings_typed(offerings));
ALTER TABLE model_fallback_policy ADD CHECK(model_order_typed(models));
REVOKE ALL ON FUNCTION model_offerings_typed(jsonb),model_order_typed(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION read_model_requests(model_value text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.receipt_time DESC),'[]') FROM (
 SELECT d.attempt_id,d.intent_id,d.agent_id,d.provider_id,d.model_id,d.parent_attempt_id,d.receipt_time,coalesce(o.state,i.state) AS state,o.cost_nanos,o.http_status,o.receipt_time AS finished_at
 FROM dispatch_attempt d JOIN dispatch_intent i USING(intent_id) LEFT JOIN dispatch_outcome o ON o.attempt_id=d.attempt_id
 WHERE CASE WHEN EXISTS(SELECT FROM model_policy WHERE id=model_value) THEN
  EXISTS(SELECT FROM model_policy m CROSS JOIN LATERAL jsonb_array_elements(m.offerings) x WHERE m.id=model_value AND x->>'model_id'=d.model_id AND x->>'provider_id'=d.provider_id)
 ELSE d.model_id=model_value END
 ORDER BY d.receipt_time DESC LIMIT 200) t
$$;
