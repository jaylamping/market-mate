# Institutional trading-floor functions and high-velocity multi-agent operating patterns

Research date: 2026-08-22  
Scope: the Research and qualified Paper stages of the [Incubator Trading Floor Agent Operating Model](https://github.com/jaylamping/market-mate/issues/58). This note informs desk topology, work allocation, review, velocity measurement, and failure containment; it does not authorize Live execution, broker access, policy activation, or spending.

Method: primary sources only. Regulator and exchange material is treated as normative or operational evidence about the control problem. Firm material is treated as a useful description of a function, not as proof that the function causes performance. Original multi-agent papers and first-party agent guidance are treated as workflow evidence, not as evidence that an agent can make an investment decision. Terms such as Research Sandbox, Research Budget, Testing Budget, Research Posture, Velocity Objective, Global Testing Ledger, Safety Kernel, and Authority Grant retain the meanings in the [Market Mate glossary](../../CONTEXT.md).

## Decision summary

Adopt a **function-oriented, evidence-gated floor** with seven active agent desks and one non-agent authority boundary:

1. **Thesis and Research** generates questions and hypotheses inside the Research Sandbox.
2. **Evidence and Data** certifies source authority, point-in-time availability, lineage, and corrections.
3. **Strategy and Portfolio** turns qualified evidence into an immutable Strategy Version proposal; it cannot approve or execute it.
4. **Paper Execution and Operations** tests order contracts, venue behavior, event handling, replay, and reconciliation in the qualified Paper scope.
5. **Risk and Safety** independently checks hard gates, exposure, lifecycle, and containment; deterministic controls own rejection.
6. **Evaluation and Challenge** reproduces, disconfirms, stress-tests, and reports economics and robustness through genuinely independent Economic Evaluation Families.
7. **Principal and Authority** is a boundary, not an agent desk. The Principal alone can activate a proposal-bound authority change; no Incubator agent receives Live credentials or creates authority for itself.

Compose workers provisionally as `Desk Role × Strategy Thesis × Research Posture × Economic Evaluation Family`. A different name, prompt, or temperature does not create independence when workers share a model, evidence, implementation, evaluator, or failure path. This is consistent with the glossary's independence and Global Testing Ledger rules, and with evidence that heterogeneous model outputs help a layered mixture while simple agent-count consensus is not a substitute for diversity or validity. [Mixture-of-Agents](https://arxiv.org/abs/2406.04692), [controlled multi-agent-debate study](https://arxiv.org/abs/2511.07784)

The objective is **validated-learning velocity**: reduce the elapsed time from a registered question to a reproducible, decision-relevant report while preserving evidence, safety, authority, entitlement, and budget gates. It is not exchange latency, quote-to-order latency, order count, agent count, raw token throughput, paper P&L, or willingness to take more risk. Research may run concurrently; trading authority may not be widened to make research appear faster.

## What institutional practice is useful—and what it is not

### Functions to emulate

FINRA Regulatory Notice 15-09 organizes algorithmic-trading supervision around general risk assessment, code development and change, testing and validation, trading systems, and compliance. Its examples include cross-disciplinary risk review, independent quality assurance, retrievable version archives, quick disablement, limited pilots with heightened monitoring, segregated development/testing, post-trade monitoring and reconciliation, message-volume thresholds, restricted code entitlements, and surveillance across interacting algorithms. These are useful control functions for an Incubator even though the notice is guidance for FINRA member firms rather than a direct rule for this project. [FINRA Regulatory Notice 15-09](https://www.finra.org/rules-guidance/notices/15-09)

The SEC Market Access Rule FAQ gives a sharper boundary: market-access controls are expected to reject orders over pre-set credit/capital or erroneous-order limits before routing, rather than submit a bad order and attempt to cancel it immediately afterward. The required controls generally remain under the broker-dealer's direct and exclusive control and are reviewed for effectiveness. Market Mate should carry the design principle forward: a model, orchestrator, reviewer, venue adapter, or agent may propose an Order Plan, but the deterministic Safety Kernel must be the last non-bypassable authority in the order path. The rule is not being treated as direct legal applicability to Market Mate. [SEC Market Access Rule FAQ](https://www.sec.gov/rules-regulations/staff-guidance/trading-markets-frequently-asked-questions/divisionsmarketregfaq-0)

CME Globex exposes the value of narrow, explicit controls rather than one giant supervisor: pre-execution credit limits, firm-level blocking, cancel-on-disconnect/conclusion, permissions, real-time working/filled-order views, dashboards, reports, and an audit trail. CME also documents self-match prevention across common ownership, with defined cancellation behavior. The analogue for Market Mate is a set of small deterministic controls that can be independently tested and revoked, not a faster discretionary agent. [CME pre-trade risk management](https://www.cmegroup.com/solutions/market-access/globex/trade-on-globex/pre-trade-risk-management.html), [CME risk-management tools](https://www.cmegroup.com/tools-information/webhelp/globex-credit-controls/Content/Home.html), [CME self-match prevention](https://www.cmegroup.com/solutions/market-access/globex/trade-on-globex/faq-self-match.html)

Goldman Sachs' current Pillar 3 disclosure describes a three-lines structure: the first line owns risk-generating activity and controls, the second line provides independent assessment, oversight, and challenge, and Internal Audit supplies independent review. It also names risk appetite, limits, thresholds, alerts, control testing, monitoring, reporting, and escalation as core processes. Market Mate should emulate the separation of proposal, challenge, and assurance—not the headcount, hierarchy, or meeting apparatus of a large bank. [Goldman Sachs UK 2024 Pillar 3 disclosure](https://www.goldmansachs.com/disclosures/gsguk-q4-2024-pillar-3.pdf)

Citadel's public description is a useful hedge-fund example: its Portfolio Construction and Risk Group operates independently of investment teams, reports to the CEO, identifies exposures and performance drivers, monitors tolerance, and uses automated testing and risk technology. Citadel also describes engineers working with quantitative researchers and investment professionals in rapid feedback loops while building risk, data, execution, and post-trade platforms. Treat these statements as the firm's own operating description, not independent evidence of results. The design implication is nevertheless clear: embed research/engineering collaboration close to the work while keeping risk authority independent. [Citadel risk management](https://www.citadel.com/what-we-do/), [Citadel engineering](https://www.citadel.com/careers/engineering/)

Jane Street similarly describes a tight loop among traders, researchers, and software engineers, alongside separate legal/compliance, finance, tax, operations, data engineering, and technology functions. Its page is a firm self-description, but it reinforces the distinction between a fast feedback loop for work and separate functions for evidence, operations, and controls. [Jane Street departments](https://www.janestreet.com/join-jane-street/departments/), [Jane Street overview](https://www.janestreet.com/who-we-are/)

### Institutional patterns to reject

- **Latency as a proxy for learning.** A market maker's microsecond path solves a different problem from a Research Cycle's evidence and decision path. CME even states that self-match prevention has no latency impact in its matching engine, illustrating that a safety control need not be traded away for speed. [CME self-match prevention](https://www.cmegroup.com/solutions/market-access/globex/trade-on-globex/faq-self-match.html)
- **Bureaucracy as control.** Committees, titles, approvals, and copied “three lines” are not safety evidence unless they have an owner, deterministic input/output contract, decision deadline, and recorded effect. The Incubator should use the smallest function that closes a known hazard.
- **Front-office incentives as authority.** Institutional traders may own risk within a firm's limits, but an Incubator worker cannot receive that implicit trust. Any risk-increasing action remains subordinate to explicit Strategy Version, Paper/Live, Safety Kernel, Authority Grant, and Principal boundaries.
- **Institutional performance as validation.** A firm's success, a marketing claim, a paper backtest, or a multi-agent benchmark does not prove Market Mate's point-in-time, net-of-cost, reproducible evidence. Every claim still needs its own experiment lineage, independent evaluation, and hard gates.

## Multi-agent patterns worth using

The primary agent-workflow sources converge on a small set of composable patterns:

| Pattern | Evidence and safe use in the Incubator | Boundary |
| --- | --- | --- |
| **Structured sequential SOP** | MetaGPT reports that standardized operating procedures and role-specific intermediate verification can reduce cascading inconsistencies in collaborative work. Use immutable artifact contracts such as `Experiment Registration → Trial → Experiment Report → Evaluation Record`; never rely on an unstructured chat transcript as the handoff. [MetaGPT](https://arxiv.org/abs/2308.00352) | SOPs describe workflow; they do not approve a Strategy Version or grant authority. |
| **Bounded parallel fan-out** | Anthropic identifies parallelization as a useful pattern when subtasks are independent. Fan out source families, evidence windows, or negative controls in parallel, then merge through deterministic lineage and overlap checks. [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) | Shared evidence, shared implementation, or the same evaluator failure path collapses apparent independence. |
| **Orchestrator-workers** | A coordinator can decompose a complex research question, route bounded tasks, and synthesize artifacts. Anthropic and AutoGen both describe this pattern; AutoGen makes roles, capabilities, and interaction behavior explicit. [Anthropic](https://www.anthropic.com/engineering/building-effective-agents), [AutoGen paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2023/08/LLM_agent.pdf) | The orchestrator owns scheduling and synthesis only. It cannot mutate canonical evidence/policy, skip review, or invoke Paper/Live authority. |
| **Manager or typed handoff** | OpenAI describes manager-as-tools and decentralized handoffs as graph patterns. Use typed handoffs with a scope, source entitlement, budget reservation, expected artifact, deadline, and stop condition. [OpenAI practical guide](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/) | Handoff transfers work, not authority. A worker must not inherit another worker's credentials or implicit approval. |
| **Evaluator-optimizer loop** | Anthropic describes a generator/evaluator feedback loop when evaluation criteria are clear and refinement is measurable. Use it for bounded drafting, code review, or evidence-quality improvement with a fixed maximum iteration count and an immutable criterion. [Anthropic](https://www.anthropic.com/engineering/building-effective-agents) | It must not consume a sealed holdout repeatedly, tune against promotion outcomes, or become a self-approving loop. Exhaustion returns `Needs More Evidence`. |
| **Adversarial challenge** | ChatEval constructs a multi-agent referee team with explicit communication strategies. A controlled 2025 study found diversity and intrinsic reasoning strength matter more than superficial debate structure, and that majority pressure can suppress independent correction. Use reviewers to search for disconfirming evidence and failure cases, not to manufacture a majority. [ChatEval](https://arxiv.org/abs/2308.07201), [controlled debate study](https://arxiv.org/abs/2511.07784) | Preserve each dissent, rationale, and evidence path. A majority cannot convert a failed Hard Promotion Gate into a pass. |
| **Layered proposal and aggregation** | Mixture-of-Agents reports gains from layered proposals and aggregation, with heterogeneous models contributing more than identical ones in its benchmark. Use this as an exploratory way to generate candidate explanations or test cases; measure marginal validated learning per token and cost. [Mixture-of-Agents](https://arxiv.org/abs/2406.04692) | Benchmark gains are not economic evidence. Aggregation is a synthesis step, not an independent evaluator family or authority gate. |
| **Human intervention and layered guardrails** | OpenAI recommends layered guardrails and escalation for excessive retries or high-risk actions. For the Incubator, high-risk means authority, evidence mutation, entitlement, budget expansion, or Paper/Live boundary crossing; these paths stop or escalate rather than “try harder.” [OpenAI practical guide](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/) | Human review does not waive a deterministic gate or turn an external notification into a Principal Authorization Decision. |

## Proposed Incubator floor topology

The topology below is a decision input for the map; it is intentionally functional rather than a promise to instantiate permanent agents or human-style departments.

| Function / desk | Owns | May do | Must not do | Independent control or output |
| --- | --- | --- | --- | --- |
| Thesis and Research | Hypotheses, research questions, exploratory analyses, candidate experiment registrations | Read approved unprivileged evidence; create disposable sandbox work; propose a Research Posture and bounded resource request | Write canonical policy/evidence; consume sealed holdouts outside a registered path; write Paper/Live state; change sizing or order behavior without a new Strategy Version | Immutable `Research Question`, `Experiment Registration`, and complete trial record |
| Evidence and Data | Source Registry fit, point-in-time evidence, licensing/entitlements, entity and timestamp lineage, correction events | Acquire permitted evidence; version observations; flag missing, stale, conflicting, or corrected evidence | Treat unapproved or later-known content as decision-time evidence; silently repair or delete history; widen source rights | Evidence manifest, provenance, correction/invalidation event, and dependency closure |
| Strategy and Portfolio | Declarative strategy logic, thesis lineage, portfolio/risk proposal, Strategy Version packaging | Translate qualified evidence into a frozen proposal; specify limits and economic behavior for evaluation | Approve itself; alter the Safety Kernel; access credentials; place Paper/Live orders; relabel an economic change as a prompt or posture change | Immutable Strategy Version, Promotion Bundle draft, and revalidation scope |
| Paper Execution and Operations | Paper venue adapter, normalized Order Plans, event ingestion, ledger/reconciliation parity, replay, simulator qualification | Submit only approved Paper-scope intents; test venue behavior; reconcile and report execution fidelity; run operational smoke tests | Imply Paper-to-Live parity; commingle ledgers; bypass deterministic checks; present venue output as validated economics without the required overlay | Paper-only Decision Records, event lineage, reconciliation state, and venue capability evidence |
| Risk and Safety | Hard gates, deterministic risk state, options lifecycle checks, exposure and containment rules | Reject or narrow actions; quarantine affected scope; invoke approved containment; test fail-closed behavior | Generate economic theses; widen limits; approve its own changes; grant Live authority; override uncertain custody or evidence | Safety decision, current authority state, containment event, and recovery gate |
| Evaluation and Challenge | Reproducibility, independent economic/robustness/benchmark review, adversarial cases, negative controls | Re-run from pinned inputs; challenge assumptions; report nulls/failures; preserve dissent; classify `Pass`, `Fail`, or `Needs More Evidence` | Share a material failure path with the proposer and count it as independent; rewrite evidence; vote past a Hard Promotion Gate | Independent Evaluation Record with family identity, overlap assessment, uncertainty, and dissent |
| Control Tower / Operations | Queueing, Research Budget, Testing Budget, Operating Cost Envelope, observability, leases, incident routing, audit indexing | Allocate approved resources; enforce concurrency and deadlines; stop/requeue work; publish status and cost | Expand budgets or authority; suppress critical alerts; silently retry forever; decide economics | Queue ledger, budget ledger, liveness record, alerts, and incident timeline |
| Principal and Authority boundary | Authority Grant, policy activation, expansion, Live promotion, recovery handback | Approve or reject an exact immutable proposal inside authenticated Market Mate | Delegate approval to a message, model, desk, vote, or self-authored policy; permit raw credentials to an agent | Principal Authorization Decision with scope, expiry, evidence, and audit trail |

The Risk and Safety desk is analogous to independent risk/control functions, but Market Mate's Safety Kernel remains deterministic and authoritative. The Control Tower may stop work and surface evidence; it may not loosen a gate. The Principal boundary is deliberately not an agent, so “autonomous trading floor” never becomes a route to autonomous authority.

## Decision inputs for work allocation

### Use typed work envelopes

Every dispatched unit should carry:

- immutable `Strategy Thesis` or research-question identity and parent `Experiment Lineage`;
- one `Desk Role`, one `Research Posture`, and one claimed `Economic Evaluation Family` where applicable;
- exact source registry and data-entitlement scope, decision-time cutoff, and evidence window;
- expected artifact and acceptance checks, including reproducibility and negative-control requirements;
- reserved Research Budget, Testing Budget, Operating Cost, concurrency, token/compute, and Principal Operational Budget impact;
- stop rule, maximum turns/retries, deadline, escalation route, and failure-containment action; and
- a write policy: append-only sandbox output, reviewable proposal, Paper-only state, or no external write.

The envelope makes parallelism safe to reason about. It also lets the Control Tower distinguish useful queue time from model time, review time, evidence waiting, and blocked time rather than hiding all delay behind “agent speed.”

### Allocate by information value under hard budgets

Rank discretionary research by a reviewable score such as:

`priority = (expected uncertainty reduction × safety relevance × applicability × independence value) / (expected tokens + compute + data cost + Principal attention)`

This is a queue heuristic, not a trading signal or automatic spending authority. Reserve capacity first for evidence integrity, reconciliation, Hard Promotion Gates, disconfirming tests, and incident containment; then allocate remaining capacity to exploratory work. Deduplicate related hypotheses against the Global Testing Ledger before adding concurrency. Any Research Budget, Testing Budget, entitlement, Operating Cost Envelope, or Principal Operational Budget limit is a stop/escalation condition; an agent may propose expansion but cannot activate it.

Use short-lived workers with expiring leases and immutable handoffs. Do not let workers share mutable prompts, canonical scratchpads, evaluator state, or unreviewed code. If a task stalls, requeue or narrow it; do not add unbounded agents merely to make a queue dashboard look active. Rotations may improve coverage or expose blind spots, but the identity and lineage of the desk role, thesis, posture, and evaluation family must remain auditable.

## Review and promotion inputs

The review sequence should be deterministic and evidence-first:

1. **Preflight:** verify source rights, point-in-time cutoff, instrument identity, experiment registration, budget reservation, dependency closure, and Paper/Live environment. A failed Hard Promotion Gate is terminal for that review.
2. **Reproduction:** run the artifact from pinned inputs and record successful, null, failed, invalid, aborted, and infrastructure-interrupted trials. A result does not disappear because it is unattractive.
3. **Independent challenge:** require at least two genuinely independent Economic Evaluation Families for economics/robustness/benchmark claims. Independence is assessed across model/provider, data, implementation, evaluator, and failure paths; apparent duplicate reviewers count once.
4. **Adversarial review:** ask for disconfirming evidence, leakage, selection, latency, liquidity, lifecycle, accounting, compliance, and failure scenarios. Keep the original proposal and every dissent visible.
5. **Decision:** produce `Pass`, `Fail`, or `Needs More Evidence` with the exact evidence and unresolved hazards. No majority vote, MoA aggregator, orchestrator, or Principal decision can turn an unmet Hard Promotion Gate into a pass.
6. **Stage transition:** only the owning Strategy Factory/lifecycle workflow can move a Strategy Version to Research Qualified or Paper Authorized. Promotion is not deployment, and Paper qualification never implies Live eligibility or authority.

This structure keeps rapid evaluator feedback useful without confusing consensus with independence. NIST's AI RMF likewise calls for documented risks, testing before deployment and during operation, independent review, metrics with uncertainty, and explicit go/no-go decisions; these principles support Market Mate's existing evidence contracts without replacing them. [NIST AI RMF Core](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/)

## Measuring validated-learning velocity

Define one unit of learning as a registered question that reaches a reproducible, decision-ready report. Record at least:

| Measure | Definition | Guard against gaming |
| --- | --- | --- |
| **Cycle time** | Registration acceptance to complete `Experiment Report` plus Evaluation Record, reported as median and p90; break out queue, evidence wait, compute, review, and rework time | Do not start the clock only after the hard part or close a trial without its failure record |
| **Decision-ready throughput** | Complete reports per period, including null, failed, invalid, and stopped trials | Do not count prompts, agent calls, orders, or drafts |
| **Reproducibility rate** | Independent reruns satisfying the declared output contract divided by reruns attempted | Do not rerun only the easiest winners or overwrite failed artifacts |
| **Validated-learning yield** | Decision-ready reports divided by registered starts, with the reason for every non-decision | A low yield may reveal a valuable early stop; never optimize it by lowering evidence gates |
| **Uncertainty reduction** | Pre-registered change in uncertainty or in a named decision-relevant unknown, with effective independent sample size and dependence disclosed | Do not substitute raw sample count, agreement, or model confidence for uncertainty |
| **Cost per decision** | Research tokens, compute, data, Operating Cost, and Principal review burden per decision-ready report | Keep Research Budget, Testing Budget, and Operating Cost separate; no silent overspend |
| **Independence health** | Shared-path findings, merged evaluator families, evidence overlap, and testing-ledger consumption | Do not treat agent count, model-name count, or parallel prompts as independence |
| **Dissent and rework** | Material dissent retained; reopened, invalidated, quarantined, or superseded artifacts and why | Do not reward forced agreement or hide rework in a new issue/strategy name |
| **Containment** | Detection-to-quarantine, stale-work fencing, reconciliation, and recovery-gate times | Do not trade containment time for more throughput; critical incidents bypass discretionary attention budgets |

The standing objective is to minimize time to **reproducible, decision-relevant learning**, consistent with the [Velocity Objective glossary](../../CONTEXT.md). Execution latency should be a separate Paper venue diagnostic—order acknowledgement, event delivery, fill/reconciliation timing, and simulator friction—and never be used as a proxy for research velocity. Raw Paper P&L is a downstream evidence input with its own fidelity and cost controls, not a speed metric.

## Failure containment and stop conditions

Contain the narrowest scope that is proven affected, preserve the original evidence, and leave risk-reducing/reconciliation work available when it is deterministically safe. The following matrix is the minimum operating contract:

| Failure | Immediate response | What remains allowed | Resume condition |
| --- | --- | --- | --- |
| Worker hallucination, bad code, or malformed artifact | Reject sandbox output; preserve trace; revoke task lease; bounded retry or requeue | Independent research on clean inputs | Reviewer verifies corrected artifact and lineage; no silent overwrite |
| Shared-source correction, deletion, entitlement loss, or time leak | Emit Evidence Control Event; close the dependency closure; quarantine affected experiments/strategies; preserve permitted tombstones | Unaffected research and explicitly authorized reconciliation | Corrected evidence is rebuilt and revalidated as a new version; prior conclusions are not silently restored |
| Evaluator disagreement or apparent consensus with shared path | Record all views and overlap; return `Needs More Evidence`; do not average away conflict | New independent evaluation, negative controls, and evidence collection | Independence and hard gates pass with no material unresolved dissent |
| Infinite debate, retry storm, or orchestrator failure | Enforce max turns/time/cost; stop and escalate; fence stale work and credentials | Independent bounded work and incident analysis | New lease and reproducibility checks; no automatic authority inheritance |
| Paper venue outage, event loss, or ledger mismatch | Stop new Paper exposure; preserve venue evidence; reconcile against the isolated Paper Ledger; contain uncertain state | Deterministic risk reduction/reconciliation when safely classifiable | Venue and ledger parity restored, replay passes, and the owning certification lease remains valid |
| Safety Kernel or lifecycle Hard Gate failure | Reject or narrow the Order Plan; quarantine dependent Strategy Version; invoke approved cancellation/kill controls | Risk-reducing actions only if deterministic and safe | Fresh evidence and an explicit recovery/promotion decision; never a timeout-based release |
| Security, identity, host, or authority-boundary compromise | Enter Recovery State; revoke sessions/leases; fence submissions; preserve audit evidence | Verification, broker reconciliation, evidence preservation, and approved recovery work | Authenticated manual Live Resumption if a future Live stage is in scope; no broader authority than before |
| Research/Testing/Operating Cost/Principal Operational limit reached | Throttle or stop discretionary work; record utilization and expansion proposal | Critical containment, incident response, and independent safety work | Principal-approved expansion with updated budget and evidence; no silent overspend |
| Cross-desk state or lifecycle disagreement | Effective state becomes the most restrictive consistently supported state; open a Decision Liveness Record | Verification, reconciliation, and safe risk reduction | Canonical records agree and the owning control signs the transition |

These responses align with FINRA's recommendations for quick disablement, pilots, independent testing, monitoring, reconciliation, and message controls; CME's block/cancel/permission/audit functions; NIST's continuous Govern/Map/Measure/Manage cycle and incident-response emphasis on reducing impact through prepared response, containment, and recovery. [FINRA Regulatory Notice 15-09](https://www.finra.org/rules-guidance/notices/15-09), [CME risk-management tools](https://www.cmegroup.com/tools-information/webhelp/globex-credit-controls/Content/Home.html), [NIST AI RMF Core](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/), [NIST SP 800-61 Rev. 3](https://csrc.nist.gov/pubs/sp/800/61/r3/final)

## Anti-patterns to reject explicitly

| Anti-pattern | Why it fails | Decision |
| --- | --- | --- |
| **Microsecond theater**: optimize agent response or quote latency before validated evidence exists | Conflates market-execution latency with research-cycle time and can incentivize unsafe shortcuts | Reject; measure the two clocks separately |
| **Agent-count independence**: ten similar workers become ten votes | Shared model/data/prompt/implementation creates correlated errors and false effective sample size | Reject; use path-level family identity and overlap ledger |
| **Majority promotion** | Majority pressure can suppress independent correction; a failed Hard Promotion Gate is not a vote | Reject; preserve dissent and return `Needs More Evidence` |
| **Central manager with authority** | An orchestrator becomes a hidden policy writer or approval bottleneck | Reject; manager schedules/synthesizes only; deterministic controls and Principal authority remain outside it |
| **Unbounded debate or self-reflection** | Tokens, time, and attention grow without a new evidence contract; repetition can look like progress | Reject; fixed criteria, budgets, stop rules, and escalation |
| **Paper P&L as learning velocity** | Simulator optimism, cost omissions, and lifecycle gaps can reward unrealistic behavior | Reject; execution fidelity and economic evidence are separate certification inputs |
| **Shared mutable memory/policy** | One compromised or mistaken worker can contaminate every desk and erase provenance | Reject; append-only artifacts, versioned policy, isolated Trust Zones |
| **Self-expansion** | More agents, data, compute, or budget can become authority by accident | Reject; proposals require the applicable Principal Authorization Decision |
| **Success-only dashboards** | Suppresses nulls, failures, invalid trials, cost, dissent, and rework | Reject; report the full experiment population and uncertainty |
| **Copied corporate bureaucracy** | Adds review latency and prestige without a bounded hazard or decision contract | Reject; retain only named functions with measurable safety or learning value |
| **Live-by-analogy** | Institutional trading-floor patterns and agent benchmarks do not establish Market Mate's Live eligibility | Reject; keep Research/Paper scope explicit and require separate promotion decisions |

## Concrete choices for the map

The research supports these decisions for the next Incubator operating-model tickets:

- **Desk topology:** adopt functional desks with role leases and explicit Trust Zones; keep Research, Evidence, Evaluation, Paper Operations, Risk/Safety, and Control Tower separable; do not instantiate a Live desk in the Incubator.
- **Work allocation:** dispatch typed work envelopes; parallelize only independent, bounded subtasks; rank by expected information value under approved budgets; track overlap and dependencies before counting throughput.
- **Review:** require proposer/reviewer separation, deterministic preflight, at least two genuinely independent Economic Evaluation Families for economic claims, preserved dissent, and no majority override of Hard Promotion Gates.
- **Velocity:** use median/p90 registration-to-decision cycle time, decision-ready throughput, reproducibility, uncertainty reduction, cost, independence health, dissent/rework, and containment. Treat execution latency, order count, tokens, agent count, and raw Paper P&L as non-goals or separate diagnostics.
- **Failure containment:** fail closed on authority/evidence/identity uncertainty; fence stale work; quarantine by dependency closure; isolate Paper and Live records; retain deterministic reconciliation and risk reduction where safe; require explicit recovery evidence and Principal handback for any future Live stage.

These are operating-model inputs, not runtime implementation. They preserve the map's existing Research Budget, Testing Budget, entitlements, Operating Cost Envelope, Principal Operational Budget, Safety Kernel, evidence, authority, Paper/Live, and Principal-approval boundaries.

## Primary source register

- [FINRA Regulatory Notice 15-09 — supervision and control practices for algorithmic trading](https://www.finra.org/rules-guidance/notices/15-09)
- [SEC Market Access Rule FAQ](https://www.sec.gov/rules-regulations/staff-guidance/trading-markets-frequently-asked-questions/divisionsmarketregfaq-0)
- [CME Globex pre-trade risk management](https://www.cmegroup.com/solutions/market-access/globex/trade-on-globex/pre-trade-risk-management.html)
- [CME Globex risk-management tools help](https://www.cmegroup.com/tools-information/webhelp/globex-credit-controls/Content/Home.html)
- [CME Globex self-match prevention FAQ](https://www.cmegroup.com/solutions/market-access/globex/trade-on-globex/faq-self-match.html)
- [Goldman Sachs UK 2024 Pillar 3 disclosure](https://www.goldmansachs.com/disclosures/gsguk-q4-2024-pillar-3.pdf)
- [Citadel — What We Do / risk management](https://www.citadel.com/what-we-do/)
- [Citadel — Engineering](https://www.citadel.com/careers/engineering/)
- [Jane Street — Departments](https://www.janestreet.com/join-jane-street/departments/)
- [Jane Street — Who We Are](https://www.janestreet.com/who-we-are/)
- [Anthropic — Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)
- [OpenAI — A practical guide to building agents](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/)
- [AutoGen — Enabling Next-Gen LLM Applications via Multi-Agent Conversations](https://www.microsoft.com/en-us/research/wp-content/uploads/2023/08/LLM_agent.pdf)
- [MetaGPT — Meta Programming for a Multi-Agent Collaborative Framework](https://arxiv.org/abs/2308.00352)
- [ChatEval — Towards Better LLM-based Evaluators through Multi-Agent Debate](https://arxiv.org/abs/2308.07201)
- [Mixture-of-Agents Enhances Large Language Model Capabilities](https://arxiv.org/abs/2406.04692)
- [Can LLM Agents Really Debate? A Controlled Study](https://arxiv.org/abs/2511.07784)
- [NIST AI RMF Core](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/)
- [NIST SP 800-61 Rev. 3](https://csrc.nist.gov/pubs/sp/800/61/r3/final)
