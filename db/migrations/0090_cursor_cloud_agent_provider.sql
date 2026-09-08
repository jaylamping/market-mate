-- Cursor as an inference provider through no-repo Cloud Agents (POST /v1/agents without repos;
-- the terminal run's `result` is the reply). Cursor publishes no plan-quota API, so pacing is local
-- request counts; 429 replies still trigger the shared cooldown. Windows and counts are editable.
ALTER TABLE provider DROP CONSTRAINT provider_protocol_check;
ALTER TABLE provider ADD CONSTRAINT provider_protocol_check CHECK(protocol IN('openai_chat','openai_responses','cursor_agent','none'));
UPDATE provider SET display_name='Cursor (cloud agents)',kind='subscription',protocol='cursor_agent',base_url='https://api.cursor.com/v1',
 settings='{"run_timeout_secs":600,"poll_interval_secs":5,"archive_after_run":true,"catalog_note":"Model ids come from GET /v1/models; the reply is one agent run, not a chat completion."}'
WHERE id='cursor';
INSERT INTO provider_window(provider_id,window_name,source,threshold_pct,pacing_slack_pct,limit_count) VALUES
('cursor','daily','local',100,100,40),
('cursor','monthly','local',95,25,800);
INSERT INTO config_revision(entity,entity_id,revision,source,diff)
VALUES('provider','cursor',1,'seed',jsonb_build_object('kind','subscription','protocol','cursor_agent','base_url','https://api.cursor.com/v1','windows',jsonb_build_array('daily','monthly')));
