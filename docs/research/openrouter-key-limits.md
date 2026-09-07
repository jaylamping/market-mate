# OpenRouter key limits

The Agents page displays the inference key's credit cap, remaining credits, reset
policy, and UTC daily/weekly/monthly usage beside the separate account balance.
Details include account tier, all-time key usage, external BYOK usage, and whether
BYOK usage counts toward the cap. This uses the existing server-only inference
credential and `GET https://openrouter.ai/api/v1/key`; it needs no management key.

Connected responses are cached for 60 seconds in the connector. The visible
frontend polls every minute and the Models refresh button invalidates the same
query. Rate-limited status checks also cache for 60 seconds; other failures cache
for five seconds. The checked timestamp describes the provider observation.
An expired successful snapshot is replaced with the failure state when refresh
fails; failed frontend refreshes hide cached figures.

Missing fields mean unknown, while explicit null caps mean unlimited. Credit
usage is not a count of free inference requests. The endpoint does not provide
an authoritative remaining free-request quota, and `is_free_tier` alone cannot
establish the credits-purchased threshold for the higher daily allowance.
Deprecated `rate_limit` metadata is ignored. Provider labels and unknown fields
are excluded from the browser projection.

This change adds monitoring. It does not change execution admission, model
selection, spending bounds, fallback policy, or retry behavior. A free request
can still fail with 402 or 429. Automatic account-wide pacing and deferred retries
require coordination across the research, chat, and assignment workers; this
display must not be used as an admission counter.

Reference: [OpenRouter limits](https://openrouter.ai/docs/api_reference/limits#checking-your-limits),
checked September 7, 2026.

Validation:

```sh
cargo test --workspace
cargo fmt --check
cd frontend
npm test
npm run typecheck
npm run build
```
