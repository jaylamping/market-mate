# Cursor integration

System → Integrations verifies a dedicated Cursor user API key. Agents lists account-available models and can place them on agent routes. Cursor is an agent runner, not a chat-completions provider; the driver adapts it by running one no-repo Cloud Agent per dispatch.

Create a user API key from Cursor Dashboard → API Keys, then run from the repository:

```sh
python3 scripts/setup_cursor.py
```

Input is hidden. Credentials travel over stdin to a one-shot Docker writer, are atomically stored with mode 0600 / owner 10001, and are mounted read-only in agent-driver. They never enter the frontend, repository, or research backend. Refresh System after five seconds.

The driver calls GET https://api.cursor.com/v1/models for the catalog and probe, and for dispatch POST https://api.cursor.com/v1/agents (no `repos`, no `env`), GET .../agents/{id}/runs/{runId} until the run is terminal, GET .../agents/{id}/usage, then POST .../agents/{id}/archive. Account identity fields are discarded. Outbound requests have fixed HTTPS destinations, redirects disabled, timeouts, and bounded responses. Model catalogs are cached per credential for five minutes; automatic routing IDs are excluded from the whitelist. Policy updates use revision checks and atomic replacement, with at most 100 selections.

Cursor dispatch (`protocol=cursor_agent`, migration 0090): the worker's messages are flattened into one prompt, the JSON contract from `response_format` is stated in that prompt, and the terminal run's `result` is folded into a Chat Completions body (code fences stripped) so worker parsers are unchanged. Runs are bounded by `settings.run_timeout_secs` (default 600) and cancelled on timeout; a timed-out or cancelled run is `indeterminate`, an `ERROR` run is `failed`. Streaming is unsupported, so Owner Chat cannot use Cursor routes. Cursor publishes no plan-quota API: `provider_window` rows for `cursor` are local request counts (`daily` 40, `monthly` 800 by default, editable in Agents), and a 429 cools the provider down. Model parameters, task routes, and runtime limits are controlled by the driver. The UI links to Cursor for subscription usage and spending limits; it does not infer Ultra entitlement or remaining allowance from successful key validation.

Official contracts checked 2026-09-07 (Create An Agent, Get A Run, Get Agent Usage, Archive An Agent, List Models, API Key Info):
- https://cursor.com/docs/cloud-agent/api/endpoints
- https://prod.cursor.com/docs/sdk/python

The Cursor integration uses the official 2D cube logo in light and dark variants, self-hosted unmodified from https://cursor.com/brand.
