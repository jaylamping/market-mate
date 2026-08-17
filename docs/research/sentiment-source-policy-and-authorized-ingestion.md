# Sentiment-source policy and authorized ingestion methods

Research date: 2026-08-16
Scope: a private, cloud-hosted Market Mate instance analyzing a versioned Coverage Universe of approximately 20–30 U.S. securities for research and paper trading, with possible later use in live trading. This report is a source-governance decision, not an investment recommendation or legal opinion.

## Decision summary

Adopt a **closed source registry**: the Sentiment Model may ingest only a source/version whose registry entry is `active` and whose evidence records the authorized access method, permitted purpose, transformations, retention, display, deletion, rate limit, cost, and geographic/account scope. A public URL, an RSS feed, a permissive `robots.txt` rule, or technical ability to fetch a page is not authorization to collect, retain, transform, display, or redistribute it. The IETF specifically states that robots rules are not access authorization. [RFC 9309](https://www.rfc-editor.org/rfc/rfc9309.html)

The recommended initial policy is:

1. **Active immediately for Experimental Indicators:** SEC EDGAR data and filing documents through official SEC endpoints; GDELT dataset fields through official GDELT downloads/APIs. SEC records are authoritative issuer disclosures; GDELT is useful for news-volume/tone experimentation but is not a substitute for a licensed financial-news feed.
2. **Conditional certification candidates:** Alpaca's Benzinga-backed News API first, Alpha Vantage `NEWS_SENTIMENT` second, and a direct Benzinga contract if the indirect offerings cannot provide the needed rights or reliability. No candidate becomes active until its account-specific agreement or written provider response covers cloud ingestion, internal automated investment analysis, LLM/ML inference, raw and derived retention, backtesting, corrections/deletions, and dashboard display. Alpaca's documentation expressly presents sentiment analysis and algorithmic trading as News API use cases, but it does not by itself settle every storage, non-display, derivative, or redistribution right. [Alpaca historical news](https://docs.alpaca.markets/us/docs/historical-news-data)
3. **Issuer material:** prefer the SEC-filed copy of an earnings release or presentation. An issuer's own RSS/API/IR page is conditional per domain; RSS is an access mechanism, not a content license. Store only metadata and a link unless the issuer terms or written permission authorize body retention and transformation.
4. **No social source in the initial allowlist.** X can be reconsidered through the official paid API after the use is approved and deletion/compliance handling is designed. Reddit requires a separate agreement for commercial purposes or other unexpressly permitted uses and gives no general ML right over user content. Stocktwits is not accepting new API registrations and prohibits automated extraction outside an approved product. YouTube's API has material retention, refresh, privacy, and derived-metric restrictions. These sources add manipulation, identity, deletion, and historical-replay risks that are disproportionate to a $1,000 experiment.
5. **Hard deny by default:** browser scraping of publishers, financial portals, forums, search-result pages/snippets, paywalled pages, and social sites; bypassing access controls; credential sharing; CAPTCHA evasion; residential-proxy rotation; and ingestion through an unofficial API. Specific first-party terms confirm that PR Newswire, Seeking Alpha, Nasdaq, and Stocktwits prohibit the proposed automated extraction absent express authorization. [PR Newswire terms](https://www.prnewswire.com/terms-of-use/), [Seeking Alpha terms](https://about.seekingalpha.com/terms), [Nasdaq legal terms](https://www.nasdaq.com/legal), [Stocktwits terms](https://stocktwits.com/about/legal/terms/)

Sentiment remains an **Experimental Indicator**. It may influence live orders only after point-in-time validation, chronological holdouts, realistic costs, paper trading, and Strategy Version promotion under the already-decided indicator policy. A source's presence in the registry authorizes data handling; it does not validate alpha.

## Authorization model

### Public availability is not a data license

For every source, treat the following as separate permissions:

| Permission | Required evidence |
|---|---|
| Access | Official API/feed/download or provider-approved crawler identity and endpoints. |
| Collect | Terms or written permission covering automated acquisition for this individual, cloud-hosted investment-analysis use. |
| Retain raw | Exact fields/content, storage region, maximum duration, backup treatment, and termination/deletion duties. |
| Transform | Permission for sentiment inference, embeddings, summaries, entity/ticker mapping, and aggregate statistics. Training or fine-tuning is a separate permission from inference. |
| Retain derived | Whether scores, embeddings, model artifacts, aggregates, and decision manifests may survive deletion or termination. |
| Display | Whether a private owner-only dashboard may show headlines, snippets, full text, author/user identity, source marks, or only derived statistics and links. |
| Redistribute | Whether any data can leave the private application. Initial policy is **no redistribution**, even when technically permitted. |
| Backtest/replay | Historical depth, point-in-time semantics, correction history, survivable derived records, and model-version stability. |

An `active` registry entry needs evidence for every permission the adapter actually exercises. Silence is `unsupported`, not permission. If a provider changes its terms, API, ownership, price, or downstream content licensor, the entry becomes `review_required` and dependent collection pauses.

### Registry state machine

`proposed -> legal_review -> sandbox_only -> active -> review_required -> suspended -> retired`

- `sandbox_only` permits contract/schema tests with disposable data and the shortest possible retention; its observations cannot enter strategy evidence.
- `active` is scoped by source, endpoint, fields, purpose, environment, and expiry/review date. Certification of news metadata does not certify article bodies or social content.
- `suspended` blocks new collection and excludes the source from new snapshots while preserving only records the applicable retention rules permit.
- `retired` executes the provider-specific purge/tombstone process and invalidates strategies whose required evidence can no longer be reproduced.

## Provider and source-category assessment

### Recommended registry dispositions

| Category / provider | Official access method | Publicly documented rights and constraints | Retention/display posture | Cost and rate-limit evidence | Recommended status |
|---|---|---|---|---|---|
| **SEC EDGAR** | `data.sec.gov` submissions/XBRL APIs, filing archives, EDGAR RSS, and bulk ZIP files with an identifying `User-Agent` | APIs require no key; submissions update throughout the day. SEC says information on `sec.gov` is public information that may be copied or further distributed with appropriate citation. Automated access must follow fair-access policy. [SEC EDGAR APIs](https://www.sec.gov/search-filings/edgar-application-programming-interfaces), [SEC privacy and dissemination policy](https://www.sec.gov/about/privacy-information) | Retain raw filing, accession, headers, parsed text, features, and derived scores indefinitely with SEC attribution. Preserve amendments as new events; do not overwrite originals. Do not use SEC seals/logos. | No fee. SEC's published ceiling is 10 requests/second across machines and it may temporarily limit excessive clients. Use a project self-cap of 1 request/second with caching/bulk downloads. [SEC rate control](https://www.sec.gov/filergroup/announcements-old/new-rate-control-limits) | **Active — authoritative text.** |
| **GDELT** | Official GDELT 2.0 files and DOC/GKG APIs | GDELT states its datasets are available without fee for unlimited/unrestricted academic, commercial, or governmental use and may be redistributed with GDELT citation/link. It updates key 2.0 feeds every 15 minutes. [GDELT terms](https://www.gdeltproject.org/about.html), [GDELT 2.0](https://blog.gdeltproject.org/gdelt-2-0-our-global-world-in-realtime/) | Retain only GDELT dataset fields, query, response, and version; cite GDELT. Do not fetch or copy the underlying publisher article merely because GDELT supplies its URL. Dashboard may show GDELT aggregates and a source link. | No fee. No stable public request ceiling was located; therefore use cached 15-minute batches, one connection at a time, exponential backoff, and treat 429/5xx as unavailable rather than increasing concurrency. | **Active — Experimental news-volume/tone corroboration.** |
| **Alpaca News / Benzinga** | Authenticated historical REST and real-time WebSocket News API; filter by Coverage Universe symbols | Alpaca says the feed is supplied by Benzinga, dates to 2015, and may support news widgets, sentiment model training, and real-time algorithmic trading. Responses can include article content. The endpoint documents 429 handling through rate-limit headers. [Alpaca historical news](https://docs.alpaca.markets/us/docs/historical-news-data), [Alpaca News endpoint](https://docs.alpaca.markets/us/reference/news-3), [Alpaca news stream](https://docs.alpaca.markets/us/docs/streaming-real-time-news) | Until written confirmation, sandbox may retain only IDs, timestamps, ticker tags, response hashes, and short-lived test payloads. Production needs explicit raw-body, derived-score, backtest, private-display, removal, backup, and termination rights. Dashboard defaults to headline/summary only if permitted, otherwise score + source link. | Alpaca does not publicly itemize a separate News API price in the reviewed docs. Do not assume it is free or covered by a chosen trading/data plan. Batch symbols and honor returned headers; self-cap at the lesser of provider limit or 30 REST requests/minute, preferring WebSocket deltas. | **Conditional — first licensed-news candidate.** |
| **Alpha Vantage `NEWS_SENTIMENT`** | Authenticated official API, queried by ticker/topic/time | The endpoint returns live/historical market news and vendor sentiment. Free keys can specify up to five symbols per request; premium keys up to 50. Alpha Vantage's standard license is revocable, non-transferable, and personal/non-commercial unless otherwise agreed; the terms do not clearly grant the complete retention, derived-data, dashboard, and replay rights required here. [Alpha Vantage documentation](https://www.alphavantage.co/documentation/), [Alpha Vantage terms](https://www.alphavantage.co/terms_of_service/) | Use only after confirming that private automated personal-account trading is within the selected license and obtaining written answers on raw fields, derived scores, model/inference, retention, display, correction, and termination. Prefer storing vendor score, ticker relevance, timestamps, URL, provider model/version if supplied—not article body. | Free tier: 25 calls/day. Premium currently starts at $49.99/month for 75 calls/minute with no daily cap. At one independent query per ticker, 30 names already exceed the free daily cap and leave no retry budget. [Alpha Vantage support](https://www.alphavantage.co/support/), [Alpha Vantage premium](https://www.alphavantage.co/premium/) | **Conditional — low-cost comparison/pilot, not sole production feed.** |
| **Direct Benzinga API** | Licensed REST/TCP Newswire/API; `news-removed` endpoint for removals | Benzinga sells structured news APIs and directs customers to licensing; its normal website terms are personal/noncommercial and do not authorize copying/derivative use. A direct API contract, not the website terms, must define the rights. The API supports updated-since deltas, up to 50 tickers, and a removed-news endpoint. [Benzinga APIs](https://www.benzinga.com/apis/), [Benzinga API quickstart](https://docs.benzinga.com/introduction/introduction), [Benzinga news API](https://docs.benzinga.com/api-reference/news-api/press-releases/get-press-releases), [Benzinga site terms](https://www.benzinga.com/terms-and-conditions) | Contract must cover internal automated trading analysis, storage, ML inference/training separately, derived scores, point-in-time archive, removals, private dashboard, and disaster-recovery copies. Consume removals as tombstones. | Quote required; no decision-grade public price was found. Compare the direct quote to Alpaca's pass-through rights and total broker/data cost. | **Conditional — escalate if Alpaca rights/reliability are insufficient.** |
| **Issuer investor-relations material** | Prefer issuer filings/exhibits on EDGAR; otherwise an issuer-published API or RSS URL explicitly approved in a per-domain registry entry | Issuer publication establishes authenticity, not necessarily automated reuse rights. Website terms can differ by issuer and hosting vendor. RSS/XML/JSON availability does not itself grant ML or retention rights. | SEC-filed copies follow the SEC policy. For direct IR feeds, default to URL, title, issuer publication time, receipt time, and hash; raw body and dashboard text require explicit permission. | Usually no fee; rate limits are domain-specific. Poll no faster than advertised update cadence and at most hourly absent explicit guidance. | **SEC copy active; direct domain conditional.** |
| **X** | Official X API search/stream only; never scrape `x.com` | X's agreement permits analysis only as explicitly approved, restricts redistribution and foundation/frontier-model training, requires current display behavior, and requires deletion/modification of removed content. Stored X content must honor user intent; enterprise compliance streams cover deletion/edit events. [X Developer Agreement](https://docs.x.com/developer-terms/agreement), [X Developer Policy](https://docs.x.com/developer-terms/policy), [X compliance streams](https://docs.x.com/x-api/compliance/streams/introduction) | A later certification must specify whether numeric aggregates/derived models are X Content, how they are deleted, how historical decisions remain auditable after source deletion, and whether private dashboard display triggers X display rules. No raw-post archive in the initial system. | Pay-per-use: currently $0.005 per Post read, with app spending limits. Twenty posts for each of 25 tickers is about $2.50/day; 100 each is about $12.50/day, before user/trend reads. [X pricing](https://docs.x.com/x-api/getting-started/pricing) | **Deny initially; conditional later.** |
| **Reddit** | OAuth Data API under an approved registered app or separate commercial agreement; never scrape | Reddit grants a limited API license primarily to copy/display user content for an approved app. User content remains owned by users; ML/AI training needs rightsholder permission. Commercial use or unexpressly permitted use needs a separate Reddit agreement. Data not required for the approved use must be deleted; termination requires deletion of content, materials, and derived models. [Reddit Data API Terms](https://redditinc.com/policies/data-api-terms) | The required immutable backtest and derived-score retention conflict with default deletion/termination duties unless a negotiated agreement resolves them. Do not ingest usernames or post bodies. | Public terms reserve the right to charge and allow discretionary limits; decision-grade commercial pricing is not public. | **Deny until separate written agreement.** |
| **Stocktwits** | Approved API/enterprise product only | New developer registrations are currently paused. Current terms prohibit automated scraping/data mining except through an approved API or written authorization. Enterprise API access is contact-based. [Stocktwits developers](https://api.stocktwits.com/developers), [Stocktwits terms](https://stocktwits.com/about/legal/terms/), [Stocktwits subscriptions](https://stocktwits.com/subscriptions) | No collection or retention without a negotiated product agreement covering derived sentiment, identities, deletion, replay, and display. | Enterprise quote required. Consumer Edge includes Stocktwits social-sentiment display features but is not evidence of API/reuse rights. | **Deny initially.** |
| **YouTube** | Official YouTube Data API only | Default quota is 10,000 units/day. Non-authorized API data may be stored for no more than 30 days without deletion/refresh; data must be kept current. Additional derived metrics/storage policies require an audited use case and explicit permission. Privacy rules prohibit harvesting or inferring identifying/sensitive user information without consent. [YouTube API overview](https://developers.google.com/youtube/v3/getting-started), [YouTube Developer Policies](https://developers.google.com/youtube/terms/developer-policies), [YouTube policy guide](https://developers.google.com/youtube/terms/developer-policies-guide) | The 30-day refresh/deletion cycle and derived-metric restrictions are incompatible with the initial immutable research archive. No comments, transcripts, channel identities, or engagement metrics. | No direct fee is documented for the default quota, but compliance/audit and refresh costs are material. | **Deny initially; reconsider only for a separately audited use case.** |
| **Publisher/web portals** (PR Newswire, Seeking Alpha, Nasdaq, Business Wire, other news/search pages) | Only a separately licensed API/feed; no browser scraper | Public access does not authorize automated analysis. PR Newswire explicitly prohibits scraping, robots/data mining, republication, and using site content to develop software/AI without permission. Seeking Alpha and Nasdaq likewise prohibit automated extraction; Business Wire's public site did not provide decision-grade reuse authorization in the reviewed evidence. | No storage, embeddings, summaries, excerpts, or derived sentiment from scraped pages. A link discovered from an authorized source can be retained as provenance. | Not applicable until a contract supplies authorized endpoints and pricing. | **Hard deny absent written license.** |

## Initial source allowlist and denylist

### Allowlist v1

The initial production-shaped paper-research pipeline should enable only:

1. `sec.edgar.submissions`, `sec.edgar.filing`, and `sec.edgar.xbrl` through official endpoints.
2. `gdelt.gkg` and/or `gdelt.doc` dataset output, restricted to the Coverage Universe and treated as an Experimental Indicator.
3. One issuer-specific direct feed only after an individual registry entry passes the same authorization checklist; otherwise use the issuer's SEC-filed material.

This is intentionally enough to build and validate the provenance, point-in-time, security, missingness, and dashboard contracts before paying for news.

### Conditional evaluation queue

Evaluate in this order:

1. Alpaca News/Benzinga pass-through—best functional fit if the broker/account agreement supplies the missing rights.
2. Alpha Vantage `NEWS_SENTIMENT`—cheap comparative score feed for a bounded universe, subject to licensing and daily-cap validation.
3. Direct Benzinga—strongest route to explicit rights if the first two remain ambiguous, but likely requires a quote and negotiated scope.
4. X—only after news sentiment has demonstrated incremental paper value and the project can fund both API reads and deletion/compliance engineering.

### Denylist v1

- All generic website/page scraping, headless-browser harvesting, search-result extraction, RSS discovery not backed by a content license, paywall/session-cookie automation, CAPTCHA bypass, credential sharing, proxy rotation, and unofficial APIs.
- Reddit, Stocktwits, YouTube, X, Discord, Telegram, Facebook/Instagram, TikTok, forums, newsletters, podcasts/transcripts, and email lists until each has an approved official access path and written scope.
- PR Newswire, Seeking Alpha, Nasdaq, Business Wire, Yahoo Finance, Google/Google News results, publisher pages, and analyst portals unless accessed through a separately licensed product.
- Any source that cannot supply stable source IDs and publication/receipt timing, or whose terms prohibit the necessary transformation/retention.
- Full article bodies or user-generated text in the dashboard unless display is explicitly licensed.

## Required ingestion and provenance contract

Every acquired object and every derived score must be traceable. The minimum immutable envelope is:

```text
source_registry_id
provider + upstream_provider
provider_contract_version + evidence_url/hash + certification_expiry
authorized_purpose + allowed_fields + retention_class + display_class
access_method + endpoint + normalized_query_hash
provider_object_id + canonical_url + source_domain
coverage_universe_version + instrument_id + ticker_alias_version
author_or_issuer_id (only if authorized; otherwise redacted/hash)
event_time / publication_time / created_at / updated_at
available_at_provider (if supplied)
requested_at / received_at / parsed_at / scored_at
raw_payload_hash + raw_storage_pointer + parser_version
correction_state + deletion/tombstone_state + supersedes_id
language + translation_provider/version + entity-linking confidence
sentiment_model_id/version + prompt/template hash + inference parameters
per-source score + confidence + relevance + disagreement/missingness flags
research_snapshot_id + decision_manifest_ids that consumed the feature
```

`received_at` is the system's conservative availability timestamp unless a stronger provider timestamp is certified. Publication time must never substitute for availability time. Ticker mapping must use a stable instrument identity and versioned aliases so `META`, `AI`, `CAT`, or renamed/delisted symbols do not create false matches. Cashtags and ticker strings alone are insufficient evidence of entity relevance.

Raw content and derived records use separate storage policies. A provider deletion may purge raw text while retaining a permitted tombstone and a pre-authorized aggregate; if the agreement does not allow the derived value to survive, the score and dependent replay evidence must be removed or marked non-reproducible.

## Retention and dashboard policy

Use these default classes; a source contract may only narrow them unless an explicit exception is recorded:

| Class | Data | Default |
|---|---|---|
| `R0-public-record` | SEC filings and permitted government records | Indefinite raw + derived retention; owner-only dashboard may display with citation. |
| `R1-open-dataset` | GDELT dataset records | Indefinite dataset/derived retention with required attribution; do not copy linked publisher article. |
| `R2-licensed-metadata` | IDs, timestamps, ticker tags, URL, headline/summary if licensed | Contract duration/termination rules; dashboard displays only licensed fields. |
| `R3-licensed-body` | Article body or transcript | Disabled by default; encrypted, short retention unless long-term/backtest right is explicit; no dashboard body by default. |
| `R4-user-content` | Social posts/comments/identities | Disabled initially; deletion/compliance stream and privacy controls required; shortest retention; no identity display unless required and authorized. |
| `R5-derived` | Scores, embeddings, aggregates, model artifacts | Retain only if the source license explicitly permits derived retention and defines termination/deletion treatment. Embeddings are not presumed exempt from content restrictions. |

The dashboard should expose source, receipt/publication timing, model version, score, confidence, disagreement, staleness, corrections, and a link to the original. It should not imply that the application owns or endorses the content. Provider branding/attribution rules must be rendered by a provider-specific component. Export and public sharing are disabled in v1.

## Content-security and prompt-injection controls

Every web/news/social payload is hostile input, even when obtained from an approved provider. OWASP identifies remote content, hidden text, HTML/Markdown, encoding tricks, and RAG poisoning as indirect prompt-injection paths and recommends sanitization, clear data/instruction separation, output validation, least privilege, monitoring, and human controls. [OWASP prompt-injection prevention](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html), [OWASP RAG security](https://cheatsheetseries.owasp.org/cheatsheets/RAG_Security_Cheat_Sheet.html)

Required architecture:

1. **Fetch isolation:** source adapters run in a network-restricted ingestion account with read-only provider credentials, domain allowlists, DNS/IP validation, redirect limits, TLS verification, response-size/time limits, decompression limits, and no broker/order/secret access.
2. **Canonicalization:** reject unexpected MIME types; strip scripts, forms, styles, SVG, remote resources, event handlers, invisible/zero-width characters, bidi controls, metadata comments, and active links; retain a forensic raw hash, not executable markup.
3. **Schema boundary:** parsing produces typed fields. Source text is always delimited as `UNTRUSTED_CONTENT` and cannot supply system prompts, tool names, URLs to fetch, code to run, tickers to add, strategy changes, or orders.
4. **Quarantined inference:** the sentiment model has no tools, network, broker credentials, wallet access, memory-writing authority, registry-writing authority, or ability to approve a strategy. It returns a strict schema: relevance, polarity distribution, confidence, event labels, evidence spans, and security flags.
5. **Deterministic validation:** enforce ticker membership, field lengths, numeric ranges, language and timestamp validity, duplicate detection, source identity, and model/schema version. Invalid outputs become missing data; no free-form model text enters the order path.
6. **Manipulation defenses:** deduplicate syndicated stories by canonical event; cap each provider/domain/author's weight; separate issuer press releases from independent coverage; measure source disagreement; detect coordinated copy/paste bursts, bot-like repetition, and extreme outliers; never convert mention volume directly into trade authorization.
7. **No untrusted autonomy:** sentiment may create a research feature, never a direct order. The Strategy Version, Risk Policy, Safety Kernel, and order admission remain separate deterministic gates.
8. **Security evidence:** log fetch/redirect headers, hashes, sanitizer result, injection flags, inference request/response IDs, model version, and every downstream consumer. Red-team remote injection after any provider, parser, prompt, model, or tool change.

## Rate limiting, availability, and failure behavior

Each adapter needs a token bucket below the provider's stated limit, bounded exponential backoff with jitter, a retry budget, circuit breaker, cost ceiling, and provider status telemetry. A 401/403, contract-expiry warning, terms hash change, repeated schema violation, or unrecognized redirect suspends the source and alerts the Principal; it is not retried with alternate credentials or scraping.

| Failure | Required behavior |
|---|---|
| 429 / quota exhausted | Honor `Retry-After`/rate headers, stop before cost overrun, mark the source incomplete for the affected interval, and do not silently switch to a webpage scraper. |
| Timeout / 5xx / stream gap | Retry within budget, reconcile from the official historical endpoint if licensed, record the gap and recovery interval, then open the circuit. |
| Missing/stale source | Set dependent sentiment features to missing/stale. Any strategy requiring them is disabled/quarantined under the existing indicator policy. No carry-forward beyond the source-specific freshness limit. |
| Conflicting reports | Preserve all authorized observations; compute disagreement and source concentration rather than choosing the most bullish/most recent story. |
| Correction/removal | Append correction/tombstone, re-score if permitted, never overwrite the prior version, and identify every Research Snapshot/decision affected. Execute mandated deletion while retaining only permitted audit metadata. |
| Terms/license change | Move entry to `review_required`, halt collection, alert the Principal, and require fresh certification before resumption. |
| Prompt-injection/security flag | Quarantine payload and all derived outputs; no retry through another model; preserve hash/metadata and alert according to severity. |
| All sentiment unavailable | Continue price/risk/account safety processing, but no strategy whose evidence contract requires sentiment may open/increase risk. Existing positions remain governed by risk-reducing lifecycle rules, never by fabricated neutral sentiment. |

For the 20–30-name universe, do not continuously search the whole market. Poll or subscribe only to current Coverage Universe members plus mandatory open holdings/obligations. Batch where semantics are equivalent, and record the exact universe version in every query.

## Point-in-time and backtest limitations

1. **Collection starts before inference claims.** Historical availability cannot be reconstructed from a current public page or ordinary news search. For live-collected data, use `received_at` as the conservative `available_at`. Clock synchronization and ingestion lag become measured features.
2. **Vendor historical APIs are not automatically point-in-time.** Alpaca exposes `created_at`/`updated_at` and history back to 2015, but current historical results can reflect later edits, removals, tagging, or vendor processing. Alpha Vantage exposes historical news/sentiment, but the reviewed public docs do not establish historical vendor-model versions or immutable as-original snapshots. Neither source may support a point-in-time backtest until the provider confirms snapshot/correction semantics or Market Mate has accumulated its own licensed archive.
3. **Social deletion duties impair immutable replay.** X requires deletion/modification of removed content; Reddit requires deletion of stored and derived materials on termination. A historical decision manifest may retain only what the contract permits. If inputs must be deleted, mark the decision `source_evidence_removed` rather than pretending it remains reproducible.
4. **Syndication is not independent evidence.** The same press release can appear through the issuer, SEC exhibit, newswire, and many publishers. Cluster by original event/hash and give it one evidence family; otherwise repeated copies create false confidence.
5. **Publisher selection changes over time.** GDELT and news vendors change monitored outlets, tagging, translation, and ranking. Store provider/version and source-coverage metrics. A rising sentiment score caused by source-mix change is not market sentiment.
6. **Universe history must be preserved.** Backtests use the Coverage Universe membership and aliases known at each `available_at`, including later delistings, acquisitions, renames, and mandatory holdings. Do not query today's winners and backfill them into the past.
7. **Model versions never rewrite history.** A new sentiment model creates a new Experimental Indicator version. Re-scoring old raw content is a new counterfactual dataset, not the score that was available to the original decision.
8. **No causality from calibration alone.** Sentiment must prove incremental value beyond price, volatility, event type, market regime, and existing indicators on untouched chronological holdouts with realistic latency, licensing cost, spread/slippage, and multiple-testing controls.

## Cost and functionality implications

The low-cost starting combination is SEC + GDELT at no provider fee, followed by a time-boxed Alpha Vantage or Alpaca News certification. That is enough for a 20–30-name universe without committing to broad-market scraping.

- Alpha Vantage's 25-call daily free cap is operationally tight: one per ticker covers at most 25 names with no retry or supplementary calls. Its $49.99/month entry plan is 5% of the initial $1,000 capital every month, even though operating costs are funded separately; the dashboard must report that drag in strategy economics.
- X costs scale with returned posts, not just queries. At the current $0.005 per Post read, even a shallow 25-ticker sample can cost roughly $75–$375/month at 20–100 posts per ticker per day, before engineering and compliance. It should not precede evidence that social sentiment adds value.
- Alpaca's public docs do not separately price news rights, and a broker/data subscription cannot be presumed to include storage, derived, or backtest rights. Obtain an all-in written quote/entitlement statement.
- Direct Benzinga and Stocktwits Enterprise require quotes. Compare them on capability-adjusted cost: authorized fields, history, corrections/removals, derived retention, display, point-in-time quality, reliability, support, and total requests—not headline price alone.

## Certification questions for commercial providers

Before activating Alpaca News, Alpha Vantage, Benzinga, or any later social provider, obtain a written answer to each question:

1. Does this exact individual/personal plan permit a cloud service to collect data for automated analysis and trading solely in the owner's account?
2. Is non-display use permitted? Does an owner-only dashboard count as display, and which fields/attribution may it show?
3. May Market Mate run third-party LLM/ML inference on headlines, summaries, bodies, or posts? May it create embeddings? Is training/fine-tuning separately permitted?
4. Which raw fields may be retained, in which cloud/region, for how long, and in backups/disaster recovery?
5. May derived scores, aggregates, embeddings, model artifacts, and historical decision manifests be retained indefinitely and after contract termination?
6. What correction, removal, privacy, takedown, and termination events exist, and what must be deleted or updated? May a tombstone/hash remain?
7. Does historical data represent what was available at each timestamp, including original tagging/sentiment model versions, or is it today's corrected/recomputed view?
8. What upstream licensors contribute content, and can their rights or availability differ by field/source? Will a licensor change trigger notice?
9. What rate limits, concurrency, reconnect, replay, service-level, maintenance, schema/versioning, and support commitments apply?
10. What is the complete price for 30 tickers, real-time plus history, API access, non-display/derived use, storage, and dashboard rights? Are there minimums, overages, audits, or cancellation fees?

## Decision-ready resolution

The Sentiment Model should not be described as a general web scraper. It is a **licensed, point-in-time evidence pipeline** over a closed registry and bounded Coverage Universe. Start with SEC EDGAR and GDELT, then certify one structured news API. Keep all social sources and publisher-page scraping disabled until a separate authorization and value case exists.

This policy satisfies the transparency goal without publishing copyrighted content: the dashboard shows every score's provider, source link, timing, lineage, model version, confidence, disagreement, staleness, corrections, and decision consumers. Missing or unauthorized evidence fails closed for dependent strategies. No source, score, or model can bypass the Strategy Version promotion process or Safety Kernel.

## Newly surfaced decision questions

1. **Commercial-news certification choice:** after written responses and a sandbox bake-off, which of Alpaca News, Alpha Vantage, or direct Benzinga offers the best rights/reliability/cost ratio?
2. **Derived-data deletion contract:** what is the canonical process for invalidating Research Snapshots and audit records when a provider requires deletion of raw or derived data?
3. **Sentiment evidence contract:** what freshness, minimum source diversity, disagreement, relevance, calibration, and missingness thresholds must a Strategy Version declare before it may consume a sentiment feature?
4. **Issuer-domain registry:** who approves and periodically revalidates direct IR feeds, and is the SEC-only delay/coverage acceptable for the first paper phase?
5. **Personal-use classification:** providers should confirm in writing whether later formation of an LLC or any access by another user changes the plan/license category and requires commercial terms.
