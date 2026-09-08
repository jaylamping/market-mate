-- Cheaper Inference: wallet-backed OpenAI-compatible marketplace (same shape as OpenRouter paid).
-- Spend authority is the persisted monthly budget in settings; the poller converts /v1/usage/daily
-- spend into a `monthly` window percentage so the shared threshold/hold logic applies unchanged.
INSERT INTO provider(id,display_name,kind,protocol,base_url,credential_path,catalog_source,catalog_url,static_models,usage_url,status_url,settings) VALUES
('cheaper-inference','Cheaper Inference','paid','openai_chat','https://api.cheaperinference.com/v1','/var/lib/cheaper-inference/credentials.json','live','https://api.cheaperinference.com/v1/models','[]',
 'https://api.cheaperinference.com/v1/usage/daily',NULL,
 '{"usage_format":"cheaper_inference","monthly_budget_usd":"10","insufficient_balance_status":402,"aliases_field":"aliases"}');
INSERT INTO provider_window(provider_id,window_name,source,threshold_pct,pacing_slack_pct,limit_count) VALUES
('cheaper-inference','monthly','api',95,25,NULL),
('cheaper-inference','daily','local',100,100,200);
INSERT INTO provider_state(provider_id) VALUES('cheaper-inference');
INSERT INTO config_revision(entity,entity_id,revision,source,diff) VALUES('provider','cheaper-inference',0,'seed',jsonb_build_object('seeded',true));
