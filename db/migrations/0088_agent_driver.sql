-- One agent driver for every model provider: registry, quota windows, agents, tiered routes, dispatch lineage.
-- OpenRouter admission (try_openrouter_capacity) stays authoritative for OpenRouter spend; the driver walks tiers above it.
CREATE ROLE agent_driver LOGIN PASSWORD 'local-driver-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT USAGE ON SCHEMA public TO agent_driver;

CREATE TABLE provider (
 id text PRIMARY KEY CHECK(id ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
 display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
 kind text NOT NULL CHECK(kind IN('subscription','free','paid','catalog_only')),
 protocol text NOT NULL CHECK(protocol IN('openai_chat','openai_responses','none')),
 base_url text NOT NULL CHECK(base_url='' OR base_url ~ '^https://[a-z0-9.-]+(/[A-Za-z0-9._/-]*)?$'),
 credential_path text NOT NULL CHECK(credential_path ~ '^/var/lib/[a-z0-9-]+/credentials\.json$'),
 catalog_source text NOT NULL CHECK(catalog_source IN('live','static','none')),
 catalog_url text CHECK(catalog_url IS NULL OR catalog_url ~ '^https://'),
 static_models jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(static_models)='array' AND jsonb_array_length(static_models)<=64),
 usage_url text CHECK(usage_url IS NULL OR usage_url ~ '^https://'),
 status_url text CHECK(status_url IS NULL OR status_url ~ '^https://'),
 settings jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(settings)='object' AND octet_length(settings::text)<=16000),
 enabled boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_object(table_name,kind) VALUES('provider','control');
CREATE TABLE provider_window (
 provider_id text NOT NULL REFERENCES provider ON DELETE CASCADE,
 window_name text NOT NULL CHECK(window_name IN('rolling_5h','weekly','monthly','daily','minute')),
 source text NOT NULL CHECK(source IN('api','local')),
 threshold_pct integer NOT NULL DEFAULT 95 CHECK(threshold_pct BETWEEN 1 AND 100),
 pacing_slack_pct integer NOT NULL DEFAULT 100 CHECK(pacing_slack_pct BETWEEN 0 AND 100),
 limit_count integer CHECK(limit_count IS NULL OR limit_count>0),
 PRIMARY KEY(provider_id,window_name)
);
INSERT INTO schema_object(table_name,kind) VALUES('provider_window','control');
CREATE TABLE provider_state (
 provider_id text PRIMARY KEY REFERENCES provider ON DELETE CASCADE,
 cooldown_until timestamptz,
 cooldown_reason text,
 probe_state text,
 probe_at timestamptz,
 last_error text
);
INSERT INTO schema_object(table_name,kind) VALUES('provider_state','control');
CREATE TABLE provider_usage_sample (
 sample_id bigserial PRIMARY KEY,
 provider_id text NOT NULL REFERENCES provider ON DELETE CASCADE,
 window_name text NOT NULL CHECK(window_name IN('rolling_5h','weekly','monthly','daily','minute')),
 percent_used numeric(6,2) CHECK(percent_used IS NULL OR percent_used BETWEEN 0 AND 100),
 status text NOT NULL CHECK(status IN('ok','rate_limited','unknown')),
 resets_at timestamptz,
 source text NOT NULL CHECK(source IN('api','local')),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE INDEX provider_usage_sample_latest ON provider_usage_sample(provider_id,window_name,receipt_time DESC);

CREATE TABLE agent (
 id text PRIMARY KEY CHECK(id ~ '^[a-z][a-z0-9_]{0,39}$'),
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 80),
 spec jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(spec)='object' AND octet_length(spec::text)<=64000 AND NOT incubator_json_claims_authority(spec)),
 priority integer NOT NULL DEFAULT 100 CHECK(priority BETWEEN 1 AND 1000),
 hold_at_pct integer NOT NULL DEFAULT 100 CHECK(hold_at_pct BETWEEN 1 AND 100),
 enabled boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_object(table_name,kind) VALUES('agent','control');
CREATE TABLE agent_route (
 agent_id text NOT NULL REFERENCES agent ON DELETE CASCADE,
 tier text NOT NULL CHECK(tier IN('subscription','free','paid')),
 ordinal integer NOT NULL CHECK(ordinal BETWEEN 0 AND 15),
 provider_id text NOT NULL REFERENCES provider,
 model_id text NOT NULL CHECK(model_id ~ '^[a-zA-Z0-9._/:~-]+$' AND char_length(model_id)<=256 AND model_id NOT LIKE 'openrouter/%'),
 share_pct integer NOT NULL DEFAULT 100 CHECK(share_pct BETWEEN 1 AND 100),
 PRIMARY KEY(agent_id,tier,ordinal)
);
INSERT INTO schema_object(table_name,kind) VALUES('agent_route','control');

CREATE TABLE dispatch_intent (
 intent_id text PRIMARY KEY,
 key text NOT NULL UNIQUE CHECK(length(key) BETWEEN 1 AND 240),
 agent_id text NOT NULL REFERENCES agent,
 purpose text NOT NULL CHECK(length(purpose) BETWEEN 1 AND 96),
 request jsonb NOT NULL CHECK(jsonb_typeof(request)='object' AND octet_length(request::text)<=160000),
 fingerprint text NOT NULL,
 allow_paid boolean NOT NULL DEFAULT false,
 state text NOT NULL DEFAULT 'queued' CHECK(state IN('queued','held','admitted','dispatched','completed','failed','indeterminate','blocked','cancelled')),
 route jsonb,
 attempt_id text,
 parent_attempt_id text,
 held_until timestamptz,
 reason text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_object(table_name,kind) VALUES('dispatch_intent','control');
CREATE INDEX dispatch_intent_state ON dispatch_intent(state,updated_at);
CREATE TABLE dispatch_attempt (
 attempt_id text PRIMARY KEY,
 intent_id text NOT NULL REFERENCES dispatch_intent,
 agent_id text NOT NULL,
 provider_id text NOT NULL,
 model_id text NOT NULL,
 tier text NOT NULL,
 ordinal integer NOT NULL,
 parent_attempt_id text,
 openrouter_attempt_id text,
 request_sha256 text NOT NULL,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE INDEX dispatch_attempt_provider_time ON dispatch_attempt(provider_id,receipt_time);
CREATE INDEX dispatch_attempt_agent_provider_time ON dispatch_attempt(agent_id,provider_id,receipt_time);
CREATE TABLE dispatch_outcome (
 attempt_id text PRIMARY KEY REFERENCES dispatch_attempt,
 state text NOT NULL CHECK(state IN('completed','failed','indeterminate','cancelled')),
 detail jsonb NOT NULL CHECK(jsonb_typeof(detail)='object' AND octet_length(detail::text)<=64000),
 cost_nanos bigint CHECK(cost_nanos IS NULL OR cost_nanos>=0),
 http_status integer,
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research')
);
CREATE TABLE tool_call (
 call_id bigserial PRIMARY KEY,
 attempt_id text NOT NULL REFERENCES dispatch_attempt,
 ordinal integer NOT NULL CHECK(ordinal BETWEEN 0 AND 999),
 tool text NOT NULL CHECK(tool ~ '^[a-z][a-z0-9_]{0,63}$'),
 arguments jsonb NOT NULL CHECK(octet_length(arguments::text)<=16000),
 result jsonb CHECK(result IS NULL OR octet_length(result::text)<=64000),
 source_lineage jsonb NOT NULL CHECK(source_lineage_is_valid(source_lineage)),
 receipt_time timestamptz NOT NULL,
 record_environment record_environment NOT NULL CHECK(record_environment='local_research'),
 UNIQUE(attempt_id,ordinal)
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['provider_usage_sample','dispatch_attempt','dispatch_outcome','tool_call'] LOOP
  PERFORM register_evidence_table(t);
  EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE OR TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION guard_incubator_write()',t||'_append_only',t);
 END LOOP;
END $$;
CREATE TABLE config_revision (
 revision_id bigserial PRIMARY KEY,
 entity text NOT NULL CHECK(entity IN('provider','agent')),
 entity_id text NOT NULL,
 revision bigint NOT NULL,
 source text NOT NULL CHECK(source IN('import','ui','api','seed')),
 actor text NOT NULL DEFAULT 'principal',
 diff jsonb NOT NULL CHECK(jsonb_typeof(diff)='object' AND octet_length(diff::text)<=64000),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_object(table_name,kind) VALUES('config_revision','control');
REVOKE ALL ON provider,provider_window,provider_state,provider_usage_sample,agent,agent_route,dispatch_intent,dispatch_attempt,dispatch_outcome,tool_call,config_revision FROM PUBLIC,incubator_runner,incubator_chat,agent_driver;

-- Seeded providers. Credentials live only in Docker volumes; these rows carry no secrets.
INSERT INTO provider(id,display_name,kind,protocol,base_url,credential_path,catalog_source,catalog_url,static_models,usage_url,status_url,settings) VALUES
('zai','Z.ai GLM Coding Plan','subscription','openai_chat','https://api.z.ai/api/coding/paas/v4','/var/lib/zai/credentials.json','static',NULL,
 '[{"id":"glm-5.3","name":"GLM-5.3","context_length":200000,"pricing":{"prompt":"0","completion":"0"}},{"id":"glm-5.3-flash","name":"GLM-5.3-Flash","context_length":200000,"pricing":{"prompt":"0","completion":"0"}}]',
 'https://api.z.ai/api/monitor/usage/quota/limit',NULL,'{"rate_limit_codes":["1302"],"overload_codes":["1305"],"peak_hours":{"timezone":"Asia/Singapore","weekdays_only":true,"start":"14:00","end":"18:00","multiplier":3}}'),
('opencode-go','OpenCode Go','subscription','openai_chat','https://opencode.ai/zen/go/v1','/var/lib/opencode/credentials.json','live','https://opencode.ai/zen/go/v1/models','[]',
 'https://opencode.ai/zen/go/v1/usage',NULL,'{"model_protocols":{"muse-spark-1.3-contributor":"openai_responses","muse-spark-1.3":"openai_responses","muse-spark-1.2":"openai_responses"},"no_plan_status":403}'),
('openrouter-free','OpenRouter (free models)','free','openai_chat','https://openrouter.ai/api/v1','/var/lib/openrouter/credentials.json','live','https://openrouter.ai/api/v1/models','[]',NULL,'https://openrouter.ai/api/v1/key','{"model_filter":":free","admission":"openrouter_capacity"}'),
('openrouter-paid','OpenRouter (paid models)','paid','openai_chat','https://openrouter.ai/api/v1','/var/lib/openrouter/credentials.json','live','https://openrouter.ai/api/v1/models','[]',NULL,'https://openrouter.ai/api/v1/key','{"model_filter":"paid","admission":"openrouter_capacity"}'),
('cursor','Cursor (catalog only)','catalog_only','none','','/var/lib/cursor/credentials.json','live','https://api.cursor.com/v1/models','[]',NULL,'https://api.cursor.com/v1/me','{"inference":"unavailable"}');
INSERT INTO provider_window(provider_id,window_name,source,threshold_pct,pacing_slack_pct,limit_count) VALUES
('zai','rolling_5h','api',95,100,NULL),('zai','weekly','api',95,15,NULL),
('opencode-go','rolling_5h','api',95,100,NULL),('opencode-go','weekly','api',95,15,NULL),('opencode-go','monthly','api',95,10,NULL),
('openrouter-free','daily','local',100,100,1000),('openrouter-free','minute','local',100,100,20);
INSERT INTO provider_state(provider_id) SELECT id FROM provider;
INSERT INTO config_revision(entity,entity_id,revision,source,diff) SELECT 'provider',id,0,'seed',jsonb_build_object('seeded',true) FROM provider;

CREATE FUNCTION provider_window_length(window_value text) RETURNS interval
LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE window_value WHEN 'rolling_5h' THEN interval '5 hours' WHEN 'weekly' THEN interval '7 days' WHEN 'monthly' THEN interval '30 days'
  WHEN 'daily' THEN interval '24 hours' WHEN 'minute' THEN interval '61 seconds' END
$$;
-- Local windows are recounted from attempts; OpenRouter free windows read the capacity ledger so both views agree.
CREATE FUNCTION provider_window_status(provider_value text,window_value text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE w provider_window%ROWTYPE; s provider_usage_sample%ROWTYPE; used numeric; reset_value timestamptz; at_time timestamptz:=clock_timestamp();
 elapsed numeric; status_value text:='ok'; observed timestamptz; length_value interval;
BEGIN
 SELECT * INTO w FROM provider_window WHERE provider_id=provider_value AND window_name=window_value;
 IF NOT FOUND THEN RETURN NULL; END IF;
 length_value:=provider_window_length(window_value);
 IF w.source='api' THEN
  SELECT * INTO s FROM provider_usage_sample WHERE provider_id=provider_value AND window_name=window_value ORDER BY receipt_time DESC LIMIT 1;
  IF FOUND AND s.receipt_time>at_time-interval '30 minutes' THEN
   used:=s.percent_used; reset_value:=s.resets_at; status_value:=s.status; observed:=s.receipt_time;
  ELSE
   status_value:='unknown'; observed:=s.receipt_time;
   IF w.limit_count IS NOT NULL THEN
    SELECT count(*)*100.0/w.limit_count INTO used FROM dispatch_attempt WHERE provider_id=provider_value AND receipt_time>at_time-length_value;
   END IF;
  END IF;
 ELSIF provider_value LIKE 'openrouter%' THEN
  SELECT count(*)*100.0/w.limit_count,min(receipt_time)+length_value INTO used,reset_value FROM openrouter_capacity_attempt WHERE is_free AND receipt_time>at_time-length_value;
  observed:=at_time;
 ELSE
  SELECT count(*)*100.0/w.limit_count,min(receipt_time)+length_value INTO used,reset_value FROM dispatch_attempt WHERE provider_id=provider_value AND receipt_time>at_time-length_value;
  observed:=at_time;
 END IF;
 elapsed:=CASE WHEN reset_value IS NULL OR reset_value<=at_time THEN 100 ELSE greatest(0,least(100,100-extract(epoch FROM reset_value-at_time)/extract(epoch FROM length_value)*100)) END;
 RETURN jsonb_build_object('window',window_value,'source',w.source,'percent_used',round(coalesce(used,0),2),'status',status_value,'resets_at',reset_value,'observed_at',observed,
  'threshold_pct',w.threshold_pct,'pacing_slack_pct',w.pacing_slack_pct,'limit_count',w.limit_count,'elapsed_pct',round(elapsed,2),
  'over_threshold',coalesce(used,0)>=w.threshold_pct OR status_value='rate_limited',
  'over_pace',w.pacing_slack_pct<100 AND coalesce(used,0)>elapsed+w.pacing_slack_pct);
END $$;
CREATE FUNCTION provider_windows(provider_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(provider_window_status(provider_id,window_name) ORDER BY array_position(ARRAY['minute','rolling_5h','daily','weekly','monthly'],window_name)),'[]') FROM provider_window WHERE provider_id=provider_value
$$;
-- Route eligibility: enabled, not cooling down, every window under threshold and pace, agent share and hold respected.
CREATE FUNCTION provider_route_eligibility(provider_value text,agent_value text,share_value integer,hold_value integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE p provider%ROWTYPE; st provider_state%ROWTYPE; w jsonb; next_at timestamptz; reason_value text; at_time timestamptz:=clock_timestamp();
 agent_used bigint; total_used bigint;
BEGIN
 SELECT * INTO p FROM provider WHERE id=provider_value;
 IF NOT FOUND OR NOT p.enabled OR p.kind='catalog_only' THEN RETURN jsonb_build_object('eligible',false,'reason','provider_disabled'); END IF;
 SELECT * INTO st FROM provider_state WHERE provider_id=provider_value;
 IF st.cooldown_until>at_time THEN RETURN jsonb_build_object('eligible',false,'reason',coalesce(st.cooldown_reason,'provider_cooldown'),'next_eligible_at',st.cooldown_until); END IF;
 -- The driver probes credentials at startup and on a timer; a provider it could not open is skipped, not failed.
 IF st.probe_state IN('not_configured','credentials_rejected') THEN RETURN jsonb_build_object('eligible',false,'reason','provider_'||st.probe_state,'next_eligible_at',at_time+interval '5 minutes'); END IF;
 FOR w IN SELECT * FROM jsonb_array_elements(provider_windows(provider_value)) LOOP
  IF (w->>'over_threshold')::boolean OR (w->>'percent_used')::numeric>=hold_value THEN
   reason_value:=CASE WHEN (w->>'percent_used')::numeric>=hold_value AND NOT (w->>'over_threshold')::boolean THEN 'agent_hold' ELSE 'window_exhausted' END||':'||(w->>'window');
   next_at:=coalesce((w->>'resets_at')::timestamptz,at_time+interval '5 minutes');
   RETURN jsonb_build_object('eligible',false,'reason',reason_value,'next_eligible_at',next_at);
  END IF;
  IF (w->>'over_pace')::boolean THEN
   RETURN jsonb_build_object('eligible',false,'reason','pacing:'||(w->>'window'),'next_eligible_at',at_time+interval '15 minutes');
  END IF;
 END LOOP;
 IF share_value<100 THEN
  SELECT count(*) FILTER(WHERE agent_id=agent_value),count(*) INTO agent_used,total_used FROM dispatch_attempt WHERE provider_id=provider_value AND receipt_time>at_time-interval '5 hours';
  IF total_used>=10 AND agent_used*100>total_used*share_value THEN
   RETURN jsonb_build_object('eligible',false,'reason','share_exhausted','next_eligible_at',at_time+interval '10 minutes');
  END IF;
 END IF;
 RETURN jsonb_build_object('eligible',true);
END $$;

CREATE FUNCTION read_providers() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'kind',p.kind,'protocol',p.protocol,'base_url',p.base_url,'credential_path',p.credential_path,
  'catalog_source',p.catalog_source,'catalog_url',p.catalog_url,'static_models',p.static_models,'usage_url',p.usage_url,'status_url',p.status_url,'settings',p.settings,'enabled',p.enabled,'revision',p.revision,
  'windows',provider_windows(p.id),'state',jsonb_build_object('cooldown_until',s.cooldown_until,'cooldown_reason',s.cooldown_reason,'probe_state',s.probe_state,'probe_at',s.probe_at,'last_error',s.last_error)) ORDER BY array_position(ARRAY['subscription','free','paid','catalog_only'],p.kind),p.id),'[]')
 FROM provider p LEFT JOIN provider_state s ON s.provider_id=p.id
$$;
CREATE FUNCTION save_provider(id_value text,expected bigint,patch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE p provider%ROWTYPE; w jsonb; BEGIN
 PERFORM pg_advisory_xact_lock(88001,1);
 SELECT * INTO p FROM provider WHERE id=id_value;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown_provider' USING ERRCODE='22023'; END IF;
 IF expected IS DISTINCT FROM p.revision THEN RETURN jsonb_build_object('status','conflict','revision',p.revision); END IF;
 IF jsonb_typeof(patch) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(patch) k WHERE k NOT IN('enabled','windows','display_name')) THEN RAISE EXCEPTION 'invalid_provider_patch' USING ERRCODE='22023'; END IF;
 IF patch ? 'enabled' THEN
  IF jsonb_typeof(patch->'enabled')<>'boolean' THEN RAISE EXCEPTION 'invalid_provider_patch' USING ERRCODE='22023'; END IF;
  UPDATE provider SET enabled=(patch->>'enabled')::boolean WHERE id=id_value;
 END IF;
 IF patch ? 'display_name' THEN UPDATE provider SET display_name=patch->>'display_name' WHERE id=id_value; END IF;
 IF patch ? 'windows' THEN
  IF jsonb_typeof(patch->'windows')<>'array' THEN RAISE EXCEPTION 'invalid_provider_patch' USING ERRCODE='22023'; END IF;
  FOR w IN SELECT * FROM jsonb_array_elements(patch->'windows') LOOP
   UPDATE provider_window SET threshold_pct=coalesce((w->>'threshold_pct')::integer,threshold_pct),pacing_slack_pct=coalesce((w->>'pacing_slack_pct')::integer,pacing_slack_pct)
    WHERE provider_id=id_value AND window_name=w->>'window';
   IF NOT FOUND THEN RAISE EXCEPTION 'unknown_provider_window' USING ERRCODE='22023'; END IF;
  END LOOP;
 END IF;
 UPDATE provider SET revision=revision+1,updated_at=clock_timestamp() WHERE id=id_value;
 INSERT INTO config_revision(entity,entity_id,revision,source,diff) VALUES('provider',id_value,expected+1,'ui',patch);
 RETURN jsonb_build_object('status','saved','revision',expected+1);
END $$;
CREATE FUNCTION record_usage_sample(provider_value text,window_value text,percent_value numeric,status_value text,resets_value timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM provider_window WHERE provider_id=provider_value AND window_name=window_value AND source='api') THEN RAISE EXCEPTION 'unknown_api_window' USING ERRCODE='22023'; END IF;
 INSERT INTO provider_usage_sample(provider_id,window_name,percent_used,status,resets_at,source,source_lineage,receipt_time,record_environment)
 VALUES(provider_value,window_value,percent_value,status_value,resets_value,'api','{"source":"agent_driver_usage_poll","entitlement_version":"local-research-v1"}',clock_timestamp(),'local_research');
 IF status_value='rate_limited' THEN
  UPDATE provider_state SET cooldown_until=greatest(cooldown_until,coalesce(resets_value,clock_timestamp()+interval '5 minutes')),cooldown_reason='usage_rate_limited:'||window_value WHERE provider_id=provider_value;
 END IF;
 RETURN provider_window_status(provider_value,window_value);
END $$;
CREATE FUNCTION record_provider_probe(provider_value text,state_value text,error_value text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 UPDATE provider_state SET probe_state=state_value,probe_at=clock_timestamp(),last_error=left(error_value,400) WHERE provider_id=provider_value
$$;
CREATE FUNCTION record_provider_cooldown(provider_value text,until_value timestamptz,reason_value text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 UPDATE provider_state SET cooldown_until=greatest(cooldown_until,until_value),cooldown_reason=left(reason_value,120) WHERE provider_id=provider_value
$$;

CREATE FUNCTION agent_routes(agent_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('tier',tier,'ordinal',ordinal,'provider_id',provider_id,'model_id',model_id,'share_pct',share_pct) ORDER BY array_position(ARRAY['subscription','free','paid'],tier),ordinal),'[]') FROM agent_route WHERE agent_id=agent_value
$$;
-- model_filter pins the walk to routes serving one model id (workers that still choose their own model);
-- the tier walk then balances that model across every provider offering it.
CREATE FUNCTION current_agent_route(agent_value text,allow_paid_value boolean,model_filter text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a agent%ROWTYPE; r agent_route%ROWTYPE; e jsonb; skipped jsonb:='[]'; next_at timestamptz;
BEGIN
 SELECT * INTO a FROM agent WHERE id=agent_value;
 IF NOT FOUND THEN RETURN jsonb_build_object('status','blocked','reason','unknown_agent'); END IF;
 IF NOT a.enabled THEN RETURN jsonb_build_object('status','blocked','reason','agent_disabled'); END IF;
 FOR r IN SELECT * FROM agent_route WHERE agent_id=agent_value AND (model_filter IS NULL OR model_id=model_filter) ORDER BY array_position(ARRAY['subscription','free','paid'],tier),ordinal LOOP
  IF r.tier='paid' AND NOT allow_paid_value THEN
   skipped:=skipped||jsonb_build_object('provider_id',r.provider_id,'model_id',r.model_id,'tier',r.tier,'ordinal',r.ordinal,'reason','paid_not_allowed'); CONTINUE;
  END IF;
  e:=provider_route_eligibility(r.provider_id,agent_value,r.share_pct,a.hold_at_pct);
  IF (e->>'eligible')::boolean THEN
   RETURN jsonb_build_object('status','eligible','route',jsonb_build_object('provider_id',r.provider_id,'model_id',r.model_id,'tier',r.tier,'ordinal',r.ordinal),'skipped',skipped);
  END IF;
  next_at:=least(next_at,(e->>'next_eligible_at')::timestamptz);
  IF next_at IS NULL THEN next_at:=(e->>'next_eligible_at')::timestamptz; END IF;
  skipped:=skipped||jsonb_build_object('provider_id',r.provider_id,'model_id',r.model_id,'tier',r.tier,'ordinal',r.ordinal,'reason',e->>'reason','next_eligible_at',e->'next_eligible_at');
 END LOOP;
 IF jsonb_array_length(skipped)=0 THEN RETURN jsonb_build_object('status','blocked','reason',CASE WHEN model_filter IS NULL THEN 'no_routes' ELSE 'model_not_routed' END,'skipped',skipped); END IF;
 RETURN jsonb_build_object('status','held','held_until',coalesce(next_at,clock_timestamp()+interval '5 minutes'),'skipped',skipped);
END $$;
CREATE FUNCTION read_agents() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'spec',spec,'priority',priority,'hold_at_pct',hold_at_pct,'enabled',enabled,'revision',revision,'updated_at',updated_at,
  'routes',agent_routes(id),'current',current_agent_route(id,false)) ORDER BY priority,id),'[]') FROM agent
$$;
CREATE FUNCTION save_agent(id_value text,expected bigint,patch jsonb,source_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a agent%ROWTYPE; r jsonb; n integer:=0; BEGIN
 PERFORM pg_advisory_xact_lock(88001,2);
 IF jsonb_typeof(patch) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(patch) k WHERE k NOT IN('name','spec','priority','hold_at_pct','enabled','routes')) THEN RAISE EXCEPTION 'invalid_agent_patch' USING ERRCODE='22023'; END IF;
 SELECT * INTO a FROM agent WHERE id=id_value;
 IF NOT FOUND THEN
  IF expected IS DISTINCT FROM 0 THEN RETURN jsonb_build_object('status','conflict','revision',NULL); END IF;
  INSERT INTO agent(id,name) VALUES(id_value,coalesce(patch->>'name',id_value)) RETURNING * INTO a;
 ELSIF expected IS DISTINCT FROM a.revision THEN RETURN jsonb_build_object('status','conflict','revision',a.revision); END IF;
 UPDATE agent SET name=coalesce(patch->>'name',name),spec=coalesce(patch->'spec',spec),priority=coalesce((patch->>'priority')::integer,priority),
  hold_at_pct=coalesce((patch->>'hold_at_pct')::integer,hold_at_pct),enabled=coalesce((patch->>'enabled')::boolean,enabled),revision=expected+1,updated_at=clock_timestamp() WHERE id=id_value;
 IF patch ? 'routes' THEN
  IF jsonb_typeof(patch->'routes')<>'array' OR jsonb_array_length(patch->'routes')>48 THEN RAISE EXCEPTION 'invalid_agent_routes' USING ERRCODE='22023'; END IF;
  DELETE FROM agent_route WHERE agent_id=id_value;
  FOR r IN SELECT * FROM jsonb_array_elements(patch->'routes') LOOP
   INSERT INTO agent_route(agent_id,tier,ordinal,provider_id,model_id,share_pct)
   VALUES(id_value,r->>'tier',coalesce((r->>'ordinal')::integer,n),r->>'provider_id',r->>'model_id',coalesce((r->>'share_pct')::integer,100));
   n:=n+1;
  END LOOP;
 END IF;
 INSERT INTO config_revision(entity,entity_id,revision,source,diff) VALUES('agent',id_value,expected+1,source_value,patch);
 RETURN jsonb_build_object('status','saved','revision',expected+1);
END $$;

-- Dispatch: one intent per key; admission picks the first eligible route. OpenRouter routes are delegated
-- to try_openrouter_capacity by the driver, which then records the attempt with the capacity receipt id.
CREATE FUNCTION admit_dispatch(key_value text,agent_value text,purpose_value text,request_value jsonb,allow_paid_value boolean,parent_value text,model_value text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE i dispatch_intent%ROWTYPE; pick jsonb; fp text; id_value text; p provider%ROWTYPE; at_time timestamptz:=clock_timestamp();
BEGIN
 PERFORM pg_advisory_xact_lock(88001,3);
 IF jsonb_typeof(request_value) IS DISTINCT FROM 'object' OR octet_length(request_value::text)>160000 THEN RAISE EXCEPTION 'invalid_dispatch_request' USING ERRCODE='22023'; END IF;
 fp:=encode(digest(request_value::text,'sha256'),'hex');
 SELECT * INTO i FROM dispatch_intent WHERE key=key_value;
 IF FOUND THEN
  IF i.fingerprint<>fp OR i.agent_id<>agent_value THEN RAISE EXCEPTION 'dispatch_key_conflict' USING ERRCODE='22023'; END IF;
  IF i.state IN('admitted','dispatched','completed','failed','indeterminate','cancelled') THEN
   RETURN jsonb_build_object('status',i.state,'intent_id',i.intent_id,'attempt_id',i.attempt_id,'route',i.route,'reason',i.reason,'held_until',i.held_until);
  END IF;
  IF i.state='held' AND i.held_until>at_time THEN
   RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',i.held_until,'reason',i.reason);
  END IF;
 ELSE
  INSERT INTO dispatch_intent(intent_id,key,agent_id,purpose,request,fingerprint,allow_paid,parent_attempt_id)
  VALUES(gen_random_uuid()::text,key_value,agent_value,purpose_value,request_value,fp,allow_paid_value,parent_value) RETURNING * INTO i;
 END IF;
 pick:=current_agent_route(agent_value,i.allow_paid,model_value);
 IF pick->>'status'='blocked' THEN
  UPDATE dispatch_intent SET state='blocked',reason=pick->>'reason',updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','blocked','intent_id',i.intent_id,'reason',pick->>'reason','skipped',pick->'skipped');
 END IF;
 IF pick->>'status'='held' THEN
  UPDATE dispatch_intent SET state='held',held_until=(pick->>'held_until')::timestamptz,reason=coalesce(pick->'skipped'->0->>'reason','held'),updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',pick->'held_until','reason',pick->'skipped'->0->>'reason','skipped',pick->'skipped');
 END IF;
 SELECT * INTO p FROM provider WHERE id=pick->'route'->>'provider_id';
 IF p.settings->>'admission'='openrouter_capacity' THEN
  UPDATE dispatch_intent SET state='queued',route=pick->'route',reason=NULL,updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','delegate','intent_id',i.intent_id,'route',pick->'route','skipped',pick->'skipped');
 END IF;
 IF EXISTS(SELECT 1 FROM dispatch_attempt a LEFT JOIN dispatch_outcome o USING(attempt_id) WHERE a.provider_id=p.id AND o.attempt_id IS NULL AND a.receipt_time>at_time-interval '150 seconds' HAVING count(*)>=4) THEN
  UPDATE dispatch_intent SET state='held',held_until=at_time+interval '5 seconds',reason='in_flight_capacity',updated_at=at_time WHERE intent_id=i.intent_id;
  RETURN jsonb_build_object('status','held','intent_id',i.intent_id,'held_until',at_time+interval '5 seconds','reason','in_flight_capacity');
 END IF;
 id_value:=gen_random_uuid()::text;
 INSERT INTO dispatch_attempt(attempt_id,intent_id,agent_id,provider_id,model_id,tier,ordinal,parent_attempt_id,request_sha256,source_lineage,receipt_time,record_environment)
 VALUES(id_value,i.intent_id,agent_value,p.id,pick->'route'->>'model_id',pick->'route'->>'tier',(pick->'route'->>'ordinal')::integer,i.parent_attempt_id,fp,'{"source":"agent_driver","entitlement_version":"local-research-v1"}',at_time,'local_research');
 UPDATE dispatch_intent SET state='admitted',route=pick->'route',attempt_id=id_value,reason=NULL,held_until=NULL,updated_at=at_time WHERE intent_id=i.intent_id;
 RETURN jsonb_build_object('status','admitted','intent_id',i.intent_id,'attempt_id',id_value,'route',pick->'route','skipped',pick->'skipped');
END $$;
CREATE FUNCTION record_delegated_attempt(intent_value text,openrouter_attempt text,request_sha text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE i dispatch_intent%ROWTYPE; id_value text; at_time timestamptz:=clock_timestamp(); BEGIN
 PERFORM pg_advisory_xact_lock(88001,3);
 SELECT * INTO STRICT i FROM dispatch_intent WHERE intent_id=intent_value;
 IF i.state<>'queued' OR i.route IS NULL THEN RAISE EXCEPTION 'delegated_attempt_not_expected' USING ERRCODE='55000'; END IF;
 id_value:=gen_random_uuid()::text;
 INSERT INTO dispatch_attempt(attempt_id,intent_id,agent_id,provider_id,model_id,tier,ordinal,parent_attempt_id,openrouter_attempt_id,request_sha256,source_lineage,receipt_time,record_environment)
 VALUES(id_value,i.intent_id,i.agent_id,i.route->>'provider_id',i.route->>'model_id',i.route->>'tier',(i.route->>'ordinal')::integer,i.parent_attempt_id,openrouter_attempt,request_sha,'{"source":"agent_driver","entitlement_version":"local-research-v1"}',at_time,'local_research');
 UPDATE dispatch_intent SET state='admitted',attempt_id=id_value,updated_at=at_time WHERE intent_id=intent_value;
 RETURN jsonb_build_object('status','admitted','intent_id',intent_value,'attempt_id',id_value,'route',i.route);
END $$;
CREATE FUNCTION hold_dispatch(intent_value text,until_value timestamptz,reason_value text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 UPDATE dispatch_intent SET state=CASE WHEN reason_value IN('cancelled') THEN 'cancelled' WHEN reason_value LIKE 'blocked:%' THEN 'blocked' ELSE 'held' END,held_until=until_value,reason=left(reason_value,120),updated_at=clock_timestamp()
  WHERE intent_id=intent_value AND state IN('queued','held','admitted');
 RETURN read_dispatch(intent_value);
END $$;
CREATE FUNCTION mark_dispatched(attempt_value text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 UPDATE dispatch_intent SET state='dispatched',updated_at=clock_timestamp() WHERE attempt_id=attempt_value AND state='admitted'
$$;
CREATE FUNCTION record_dispatch_outcome(attempt_value text,state_value text,detail_value jsonb,cost_value bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE a dispatch_attempt%ROWTYPE; o dispatch_outcome%ROWTYPE; status_value integer; at_time timestamptz:=clock_timestamp(); retry_ms bigint; BEGIN
 PERFORM pg_advisory_xact_lock(88001,3);
 SELECT * INTO STRICT a FROM dispatch_attempt WHERE attempt_id=attempt_value;
 SELECT * INTO o FROM dispatch_outcome WHERE attempt_id=attempt_value;
 IF FOUND THEN RETURN jsonb_build_object('status','recorded','intent_id',a.intent_id); END IF;
 IF jsonb_typeof(detail_value) IS DISTINCT FROM 'object' OR incubator_json_claims_authority(detail_value) THEN RAISE EXCEPTION 'invalid_dispatch_outcome' USING ERRCODE='22023'; END IF;
 status_value:=CASE WHEN detail_value->>'http_status' ~ '^[0-9]{3}$' THEN (detail_value->>'http_status')::integer END;
 INSERT INTO dispatch_outcome(attempt_id,state,detail,cost_nanos,http_status,source_lineage,receipt_time,record_environment)
 VALUES(attempt_value,state_value,detail_value,cost_value,status_value,a.source_lineage,at_time,'local_research');
 UPDATE dispatch_intent SET state=state_value,reason=detail_value->>'reason',updated_at=at_time WHERE intent_id=a.intent_id;
 IF status_value=429 OR detail_value->>'provider_code' IN('1302','1305') THEN
  retry_ms:=CASE WHEN detail_value->>'retry_ms' ~ '^[0-9]{1,9}$' THEN least(3600000,greatest(60000,(detail_value->>'retry_ms')::bigint)) ELSE 60000 END;
  UPDATE provider_state SET cooldown_until=greatest(cooldown_until,at_time+retry_ms*interval '1 millisecond'),cooldown_reason='rate_limited' WHERE provider_id=a.provider_id;
 ELSIF state_value='completed' THEN
  UPDATE provider_state SET cooldown_until=NULL,cooldown_reason=NULL WHERE provider_id=a.provider_id AND cooldown_reason='rate_limited';
 END IF;
 RETURN jsonb_build_object('status','recorded','intent_id',a.intent_id);
END $$;
CREATE FUNCTION read_dispatch(intent_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('intent_id',i.intent_id,'key',i.key,'agent_id',i.agent_id,'purpose',i.purpose,'state',i.state,'route',i.route,'attempt_id',i.attempt_id,'parent_attempt_id',i.parent_attempt_id,
  'held_until',i.held_until,'reason',i.reason,'created_at',i.created_at,'updated_at',i.updated_at,
  'outcome',CASE WHEN o.attempt_id IS NULL THEN NULL ELSE jsonb_build_object('state',o.state,'detail',o.detail,'cost_nanos',o.cost_nanos,'http_status',o.http_status,'receipt_time',o.receipt_time) END,
  'openrouter_attempt_id',a.openrouter_attempt_id)
 FROM dispatch_intent i LEFT JOIN dispatch_attempt a ON a.attempt_id=i.attempt_id LEFT JOIN dispatch_outcome o ON o.attempt_id=i.attempt_id WHERE i.intent_id=intent_value
$$;
CREATE FUNCTION read_dispatch_by_key(key_value text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT read_dispatch(intent_id) FROM dispatch_intent WHERE key=key_value
$$;
CREATE FUNCTION expire_dispatch_attempts() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n integer; BEGIN
 -- A dead driver process must not hold in-flight slots forever; the outcome stays unknown.
 INSERT INTO dispatch_outcome(attempt_id,state,detail,source_lineage,receipt_time,record_environment)
 SELECT a.attempt_id,'indeterminate','{"reason":"dispatch_timeout"}',a.source_lineage,clock_timestamp(),'local_research'
 FROM dispatch_attempt a LEFT JOIN dispatch_outcome o USING(attempt_id) WHERE o.attempt_id IS NULL AND a.receipt_time<clock_timestamp()-interval '150 seconds';
 GET DIAGNOSTICS n=ROW_COUNT;
 UPDATE dispatch_intent i SET state='indeterminate',reason='dispatch_timeout',updated_at=clock_timestamp() FROM dispatch_outcome o WHERE o.attempt_id=i.attempt_id AND o.detail->>'reason'='dispatch_timeout' AND i.state IN('admitted','dispatched');
 RETURN n;
END $$;
CREATE FUNCTION read_usage_summary() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('providers',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'kind',p.kind,'enabled',p.enabled,'probe_state',s.probe_state,'cooldown_until',s.cooldown_until,'windows',provider_windows(p.id))
   ORDER BY array_position(ARRAY['subscription','free','paid','catalog_only'],p.kind),p.id) FROM provider p LEFT JOIN provider_state s ON s.provider_id=p.id WHERE p.kind<>'catalog_only'),'[]'),
  'holds',(SELECT count(*) FROM dispatch_intent WHERE state='held'),
  'in_flight',(SELECT count(*) FROM dispatch_attempt a LEFT JOIN dispatch_outcome o USING(attempt_id) WHERE o.attempt_id IS NULL),
  'observed_at',clock_timestamp())
$$;
CREATE FUNCTION read_config_revisions(limit_value integer) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.revision_id DESC),'[]') FROM (SELECT * FROM config_revision ORDER BY revision_id DESC LIMIT least(greatest(limit_value,1),500)) c
$$;

-- Campaign paid authorization must also accept the driver identity that now performs OpenRouter dispatch.
CREATE OR REPLACE FUNCTION incubator_campaign_paid_authorized(key_value text,model_value text,purpose text,actual_request jsonb,fingerprint text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c incubator_campaign%ROWTYPE; campaign_request text; generation_id bigint;
BEGIN
 IF session_user NOT IN('incubator_runner','agent_driver') AND coalesce(current_setting('role',true),'') NOT IN('incubator_runner','agent_driver') THEN RETURN false; END IF;
 IF model_value ~ '^[a-zA-Z0-9._/-]+:free$' OR model_value LIKE 'openrouter/%' THEN RETURN false; END IF;
 SELECT * INTO STRICT c FROM incubator_campaign;
 IF c.creator_model IS DISTINCT FROM model_value THEN RETURN false; END IF;
 IF key_value ~ '^ticket-creator:[0-9]{1,19}$' AND pg_input_is_valid(split_part(key_value,':',2),'bigint') THEN
  generation_id:=split_part(key_value,':',2)::bigint;
  RETURN purpose='ticket_creator' AND c.enabled AND EXISTS(
   SELECT 1 FROM incubator_ticket_generation g WHERE g.id=generation_id AND g.state='queued' AND g.request IS NOT NULL AND g.model=model_value
   AND fingerprint=encode(digest(g.request::text,'sha256'),'hex')
   AND (actual_request #- '{provider,max_price}') IS NOT DISTINCT FROM (g.request #- '{provider,max_price}')
   AND c.revision=g.campaign_revision);
 END IF;
 IF key_value ~ '^similarity:campaign-pilot-v1-[0-9]{1,10}$' THEN
  campaign_request:=split_part(key_value,':',2);
  RETURN purpose='similarity' AND EXISTS(SELECT 1 FROM incubator_campaign_attempt a WHERE a.request_id=campaign_request AND a.model=model_value AND a.state IN('checking','queued'));
 END IF;
 IF key_value ~ '^research:campaign-pilot-v1-[0-9]{1,10}(:retry)?$' THEN
  campaign_request:=split_part(key_value,':',2);
  RETURN purpose='research' AND EXISTS(SELECT 1 FROM incubator_campaign_attempt a WHERE a.request_id=campaign_request AND a.state='queued');
 END IF;
 RETURN false;
END $$;

REVOKE ALL ON FUNCTION provider_window_length(text),provider_window_status(text,text),provider_windows(text),provider_route_eligibility(text,text,integer,integer),read_providers(),save_provider(text,bigint,jsonb),
 record_usage_sample(text,text,numeric,text,timestamptz),record_provider_probe(text,text,text),record_provider_cooldown(text,timestamptz,text),agent_routes(text),current_agent_route(text,boolean,text),read_agents(),save_agent(text,bigint,jsonb,text),
 admit_dispatch(text,text,text,jsonb,boolean,text,text),record_delegated_attempt(text,text,text),hold_dispatch(text,timestamptz,text),mark_dispatched(text),record_dispatch_outcome(text,text,jsonb,bigint),
 read_dispatch(text),read_dispatch_by_key(text),expire_dispatch_attempts(),read_usage_summary(),read_config_revisions(integer),incubator_campaign_paid_authorized(text,text,text,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION provider_window_status(text,text),provider_windows(text),provider_route_eligibility(text,text,integer,integer),read_providers(),save_provider(text,bigint,jsonb),
 record_usage_sample(text,text,numeric,text,timestamptz),record_provider_probe(text,text,text),record_provider_cooldown(text,timestamptz,text),agent_routes(text),current_agent_route(text,boolean,text),read_agents(),save_agent(text,bigint,jsonb,text),
 admit_dispatch(text,text,text,jsonb,boolean,text,text),record_delegated_attempt(text,text,text),hold_dispatch(text,timestamptz,text),mark_dispatched(text),record_dispatch_outcome(text,text,jsonb,bigint),
 read_dispatch(text),read_dispatch_by_key(text),expire_dispatch_attempts(),read_usage_summary(),read_config_revisions(integer) TO agent_driver;
-- Workers read dispatch results and the usage summary; they never admit or record provider outcomes themselves.
GRANT EXECUTE ON FUNCTION read_dispatch(text),read_dispatch_by_key(text),read_usage_summary(),read_agents(),current_agent_route(text,boolean,text) TO incubator_runner,incubator_chat;
-- The driver performs OpenRouter admission on behalf of workers, so it needs the capacity entrypoints the workers had.
GRANT EXECUTE ON FUNCTION read_openrouter_capacity(),enqueue_openrouter_capacity(text,jsonb,text),openrouter_capacity_ready(text),cancel_openrouter_capacity(text),try_openrouter_capacity(text,text,bigint,text,jsonb),finish_openrouter_capacity(text,jsonb),save_openrouter_capacity(bigint,jsonb),
 defer_openrouter_capacity(text,text),incubator_campaign_free_work(text),read_incubator_agent_run(text) TO agent_driver;
SELECT assert_all_evidence_table_conventions();
