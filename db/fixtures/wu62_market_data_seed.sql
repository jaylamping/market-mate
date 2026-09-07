-- Synthetic source registration for disposable tests only. Never apply to real data.
CREATE FUNCTION pg_temp.source(label text, certification text DEFAULT 'certified') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE s uuid; v uuid; e uuid; ev uuid; lineage jsonb:='{"source":"isolated-wu61-fixture","entitlement_version":"fixture-only"}'; BEGIN
 INSERT INTO source_registry(source_key,source_name,source_kind,source_lineage,receipt_time,record_environment) VALUES(label,label,'market_data',lineage,now(),'local_research') RETURNING source_id INTO s;
 INSERT INTO source_registry_version(source_id,registry_version,lifecycle,license_terms,permitted_use,lineage_rules,observation_states,correction_semantics,effective_from,source_lineage,receipt_time,record_environment)
 VALUES(s,1,'active','{"name":"isolated test only"}','{"purposes":["local_research"]}','{"required_fields":[]}',ARRAY['current'],ARRAY['required_deletion'],now()-interval '1 day',lineage,now(),'local_research') RETURNING source_version_id INTO v;
 INSERT INTO data_entitlement(entitlement_key,account_scope,plan_name,source_lineage,receipt_time,record_environment) VALUES(label,'fixture account','fixture plan',lineage,now(),'local_research') RETURNING entitlement_id INTO e;
 INSERT INTO data_entitlement_version(entitlement_id,entitlement_version,source_registry_version_id,certification_state,authorized_purposes,effective_from,certification_basis,source_lineage,receipt_time,record_environment)
 VALUES(e,1,v,certification,ARRAY['local_research'],now()-interval '1 day','{"authority":"isolated acceptance fixture, not a real provider approval"}',lineage,now(),'local_research') RETURNING entitlement_version_id INTO ev;
 RETURN configure_market_data_source(v,ev);
END $$;
CREATE TABLE wu62_source AS SELECT pg_temp.source('wu62-test')::text id;
