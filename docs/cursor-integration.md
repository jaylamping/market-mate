# Cursor integration

System → Integrations verifies a dedicated Cursor user API key. Agents lists account-available models and stores an explicit whitelist in a separate Docker volume. Cursor is an agent runner, not a chat-completions provider.

Create a user API key from Cursor Dashboard → API Keys, then run from the repository:

```sh
python3 scripts/setup_cursor.py
```

Input is hidden. Credentials travel over stdin to a one-shot Docker writer, are atomically stored with mode 0600 / owner 10001, and are mounted read-only in cursor-connector. They never enter the frontend, repository, or research backend. Refresh System after five seconds.

The connector only calls GET https://api.cursor.com/v1/me and GET https://api.cursor.com/v1/models. Account identity fields are discarded. Outbound requests have fixed HTTPS destinations, redirects disabled, timeouts, and bounded responses. Model catalogs are cached per credential for five minutes; automatic routing IDs are excluded from the whitelist. Policy updates use revision checks and atomic replacement, with at most 100 selections.

No agent creation, task execution, repository modification, or model inference is exposed. The saved whitelist is configuration for a future runtime, which must enforce it before dispatch. Model parameters, task roles, and runtime limits remain future work. The UI links to Cursor for subscription usage and spending limits; it does not infer Ultra entitlement or remaining allowance from successful key validation.

Official contracts checked 2026-09-06:
- https://cursor.com/docs/cloud-agent/api/endpoints
- https://prod.cursor.com/docs/sdk/python

The Cursor integration uses the official 2D cube logo in light and dark variants, self-hosted unmodified from https://cursor.com/brand.
