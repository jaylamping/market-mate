# ADR-0008: Pace backlog claims below capacity, retry unusable Experiment replies

- Status: superseded in part by [ADR-0011](0011-campaign-exact-case-check.md) for claim spacing. Experiment-reply retry remains accepted.
- Date: 2026-09-07
- Decision source: User-directed after admitted campaign tickets failed at the Experiment agent and pickup still felt slow.
- Implementation: implemented in [0081](../../db/migrations/0081_campaign_experiment_throughput.sql), [experiment completion](../../backend/src/incubator_experiment.rs), and [campaign worker](../../backend/src/incubator_campaign.rs).

## Context

OpenRouter free remaining was still hundreds of calls, with a 3.2s start interval. Campaign claim set `next_at` 60 seconds after each check, and the worker slept 30 seconds. Admitted tickets then failed at the Experiment agent: ling returned `finish_reason=stop` with reasoning tokens and content that missed the strict JSON contract. Setup already succeeded on the same tickets. Public experiment events hide the model reason behind a managed-dataset message.

## Decision

Campaign claim spacing is 10 seconds. The campaign worker polls every 5 seconds. That stays slower than the capacity start interval and the daily free ceiling. The Experiment request disables reasoning when the catalog allows it and uses the same JSON-schema envelope as other workers. Completion accepts an enclosing fence or a first JSON object, then keeps only the contract fields. One automatic `experiment_retry` is allowed after `dispatching` when the managed or public reason is an unusable Experiment reply. The original failed event stays. A second dispatch uses the existing two-dispatch budget.

## Alternatives and consequences

Leaving the 60-second claim gap wastes free capacity that is not the limiter. Treating every invalid Experiment reply as terminal leaves Setup-ready tickets stuck. Auto-executing after a bad Experiment reply would skip the preregistered execute check. Owner-only retry would leave the unattended campaign queue stopped.

## Verification

[dispatch retry probe](../../db/fixtures/experiment_dispatch_retry_probe.sql), existing experiment and campaign probes, `bash scripts/incubator_experiment_test.sh`, `bash scripts/research_campaign_test.sh`. Live OpenRouter remaining counts are runtime observations.

## Reconsider when

A more reliable free Experiment model is authorized, or capacity start interval and daily free remaining become the observed limiter.
