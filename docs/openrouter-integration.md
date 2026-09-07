# OpenRouter integration

System → Integrations contains the API-key connection check. Agents contains the model picker and saved whitelist. Free and paid models are both selectable. Inference for every provider goes through `agent-driver`; this configures availability and routes future Incubator work. Saving a whitelist never starts a model call. An empty list approves nothing.

## Setup

Run `docker compose up -d --build agent-driver frontend`, then run `python3 scripts/setup_openrouter.py` from the project root. Create a dedicated key at https://openrouter.ai/settings/keys and enter it at the hidden terminal prompt. Refresh System after five seconds.

The key lives in the `openrouter-secrets` Docker volume, readable only by the agent-driver user (UID 10001, file mode 600), with a read-only mount. Credentials remain on provider volumes and are not stored in the frontend, source tree, container environment, or research workers. The driver has no published host port. Key verification calls only GET https://openrouter.ai/api/v1/key and returns allowlisted status metadata, never upstream error bodies or key labels.

## Agents and model whitelist

Agents is the provider/model configuration home. Provider priority, explicit blacklists, usage limits, and personas are visibly planned rather than functioning controls. Incubator remains the activity/progress home.

The model picker reads GET https://openrouter.ai/api/v1/models. Catalog base input/output prices are displayed in USD per million tokens; actual pricing can vary by provider, context, and other capabilities. The free filter requires all reported pricing fields to be zero. Dynamic OpenRouter routers are excluded because they can select a model outside an explicit whitelist.

Selections are saved in `openrouter-policy` as an atomically replaced JSON file, separately from credentials. Revisions reject conflicting edits. Unknown model IDs cannot be newly approved; retired selections remain visible and removable. Invalid stored policy fails closed. The agent driver consults the stored whitelist and registers OpenRouter twice, as `openrouter-free` and `openrouter-paid`, so free capacity and paid spending remain distinct route tiers.

Browser reads and writes use TanStack Query. The local Next proxy requires a matching loopback Origin/Host for policy writes; broker and research read-only routes retain their existing boundaries. This is a local integration-configuration control, not trading authority. Model policy requires an authentication/authorization boundary before any remote deployment.

Sources: https://openrouter.ai/docs/api_reference/limits and https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.

## Account balance

`GET /openrouter/balance` reads `GET https://openrouter.ai/api/v1/credits` and projects remaining USD credits (`total_credits - total_usage`). This is account-wide, not a key's spending limit. Zero and negative balances are preserved; unavailable data has no numeric amount. Balance checks cache for 60 seconds and never affect connection status.

The existing inference key is tried when no separate management credential is configured. OpenRouter documents management-key access for this endpoint. If needed, create a dedicated management key and run `python3 scripts/setup_openrouter_balance.py`. It is saved as `management.json` in the existing private volume, with the same hidden-stdin/0600 storage pattern. The agent driver uses this key only for the fixed read-only credits endpoint. No management operations are exposed.

The amount appears beside OpenRouter on System and Agents. The checked time is in its tooltip. Refresh connections/models refreshes the balance query, subject to the agent driver's one-minute cache.

Source: https://openrouter.ai/docs/api/api-reference/credits/get-credits
