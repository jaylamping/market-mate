# Self-directed automated-trading prohibited-conduct and account-rule inventory

Research date: 2026-08-20  
Jurisdiction and operating assumption: one Kansas-resident Principal, one cloud-hosted system, and only the Principal's own U.S. brokerage account. No client accounts, compensation for advice, public recommendations, custody of another person's assets, or broker/dealer services. Stocks and listed options are in scope; futures, swaps, cryptoassets, and foreign-market access are not.

## Decision-ready conclusion

Market Mate can make a broad class of prohibited or account-invalid actions **technically impossible**, but it cannot guarantee that every action is lawful or that the Principal could never face civil or criminal exposure. Materiality, nonpublic status, duties of trust, manipulative purpose, beneficial ownership outside the connected account, sanctions ownership, employer restrictions, and some tax classifications depend on facts the software cannot independently know. The safe policy is therefore:

1. keep the platform strictly single-Principal and self-directed;
2. make a deterministic Compliance Gate part of the non-bypassable Safety Kernel;
3. reject structurally prohibited orders before they reach a broker;
4. quarantine fact- or intent-sensitive situations for an authenticated Principal attestation or qualified counsel;
5. treat broker acceptance as necessary but never as proof of legality;
6. preserve complete evidence for every decision and submission; and
7. freeze only affected new exposure when a controlling rule, entitlement, agreement, or legal classification is unknown or stale.

The Principal's request to prevent illegal actions should become a **Compliance Invariant**, not a promise of legal immunity: no agent, strategy, administrator, or Principal interface may bypass a hard legal/account control. The GUI may explain a denial and provide a counsel-review workflow, but it may not expose an override button for a prohibited action.

This report is planning research, not legal or tax advice. A Kansas securities lawyer should validate the marked questions before Restricted Live activation and before any change from single-user, own-account use.

## Authority and applicability model

| Class | Examples | Directly binds whom | Market Mate treatment |
|---|---|---|---|
| Federal law and SEC rules | Exchange Act antifraud/manipulation provisions, Regulation SHO, Regulation T | The Principal and/or executing broker according to the provision | Hard gate where objective; quarantine where facts or intent determine liability |
| Kansas law | Kansas Uniform Securities Act antifraud and registration provisions | Persons and conduct within Kansas jurisdiction | Treat as an independent prohibition; obtain Kansas counsel on registration boundaries |
| FINRA/exchange rules | FINRA margin/options rules and exchange trading rules | Primarily the member broker and associated persons | Broker must enforce them, but Market Mate must model the resulting customer limits and never attempt evasion |
| OCC contract rules and disclosure | Standardized-option exercise, assignment, adjustment, and settlement mechanics | Clearing members and option holders/writers through account agreements | Dedicated lifecycle controls; broker/OCC evidence remains authoritative |
| Broker agreement and API policy | Trading permission, option level, short availability, order limits, token use, automation terms | Principal as customer/API user | Capability-scoped venue certification; stricter broker policy wins |
| Market-data contract | Display/non-display, derived use, redistribution, retention, device/user reporting | Subscriber and/or application operator | Data may not enter research, models, alerts, or execution until its exact use is licensed |
| Tax law | Wash-sale, straddle, constructive-sale, option and Section 1256 classifications | Principal as taxpayer | Accounting/reporting controls; never claim tax certainty where external accounts or facts are unavailable |

FINRA rules do not become optional merely because they formally regulate the broker rather than the customer. The broker can reject, liquidate, restrict, close, or report the account, and a strategy designed to exploit a broker's control gap can independently evidence prohibited intent.

## Mandatory system boundary

The current own-account design materially reduces federal registration risk. Federal law defines a broker as a person in the business of effecting securities transactions for others, and the dealer definition contains an exception for a person buying and selling for that person's own account but not as part of a regular dealing business. The SEC says individuals buying and selling for themselves generally are traders rather than dealers. [15 U.S.C. § 78c(a)(4)–(5)](https://uscode.house.gov/view.xhtml?edition=prelim&num=0&req=granuleid%3AUSC-prelim-title15-section78c), [SEC broker-dealer registration guide](https://www.sec.gov/about/divisions-offices/division-trading-markets/division-trading-markets-compliance-guides/guide-broker-dealer-registration)

Kansas is not a clean statutory own-account safe harbor. Kansas defines an investment adviser around compensated advice to others, but its broker-dealer definition includes a person in the business of effecting transactions for the person's own account and does not reproduce the federal trader exception on its face. Kansas registration is required unless an exemption applies. Ordinary personal investing may not be `engaged in the business`, but the effect of frequent autonomous activity or an LLC is fact-sensitive. [K.S.A. 17-12a102](https://www.ksrevisor.gov/statutes/chapters/ch17/017_012a_0102.html), [K.S.A. 17-12a401](https://www.ksrevisor.gov/statutes/chapters/ch17/017_012a_0401.html)

That conclusion is scope-dependent, not a blanket exemption. Before Restricted Live, Kansas counsel should confirm the treatment of the exact individual/LLC ownership and automated pattern. The system must automatically remain Paper-only if any of these conditions becomes true without a new legal determination:

- another person can fund, own, direct, approve, copy, or benefit from trades;
- Market Mate advises, manages, or routes orders for another person's account;
- the Principal receives transaction-based or advisory compensation;
- the application, signals, rankings, or strategies are offered to the public;
- the system holds itself out as a broker, adviser, market maker, liquidity provider, or trading venue;
- it routinely quotes both sides, carries inventory, or otherwise changes into a dealing business; or
- an LLC or other entity introduces owners, clients, employees, or a business purpose beyond holding the Principal's own capital.

The public URL does not itself make the application public-facing financial advice if registration is closed and only the Principal can access content. No rankings, recommendations, positions, forecasts, or trade rationales may be published outside the authenticated Principal boundary.

## Prohibited-conduct inventory

### Insider trading and material nonpublic information

Exchange Act Section 10(b), Rule 10b-5, and Rules 10b5-1/10b5-2 govern deceptive trading and trading while aware of material nonpublic information where a duty or relationship of trust and confidence exists. Rule 10b5-1's affirmative defense has formal conditions; an autonomous strategy created or modified while aware of MNPI is not made lawful merely because later execution is automatic. [15 U.S.C. § 78j](https://uscode.house.gov/view.xhtml?edition=prelim&num=0&req=granuleid%3AUSC-prelim-title15-section78j), [17 C.F.R. § 240.10b5-1](https://www.ecfr.gov/current/title-17/chapter-II/part-240/section-240.10b5-1), [17 C.F.R. § 240.10b5-2](https://www.ecfr.gov/current/title-17/chapter-II/part-240/section-240.10b5-2), [SEC 2022 Rule 10b5-1 amendments](https://www.sec.gov/rules-regulations/2022/12/insider-trading-arrangements-related-disclosures)

**Hard controls:**

- Maintain a Principal Restricted-Issuer List covering employers, clients, consulting engagements, board roles, household-controlled entities, tender/transaction involvement, and every issuer the Principal manually identifies.
- Block the issuer, its securities, options, and economically linked instruments from all new exposure; allow only counsel-approved or broker-required risk reduction.
- Require an explicit `No known MNPI or applicable blackout` attestation before first Live activation, after Restricted-Issuer List changes, and before any manually requested trade or unplanned earnings hold.
- Provide an immediate `I may possess confidential information` control that freezes the affected issuer without asking the Principal to enter the information itself.
- Exclude private messages, private work systems, paid expert-network content, private deal rooms, leaked datasets, and access-controlled material from research ingestion.
- Record source provenance and public-release time for every research fact. A source being found on the internet does not by itself prove lawful acquisition or that the information is public.
- Never represent an ordinary Market Mate strategy as a Rule 10b5-1 plan. Such a plan requires separate issuer/counsel treatment and is outside the initial scope.

**The system cannot know:** whether information in the Principal's mind is material, whether it was obtained under a duty, whether a rumor reflects a tip, whether public dissemination was sufficient, or whether another household member creates a duty or restricted relationship. Ambiguity requires issuer quarantine and securities counsel, not an AI materiality judgment.

### Manipulation, wash trades, spoofing, layering, marking, and misleading statements

Exchange Act Section 9 prohibits transactions involving no change in beneficial ownership and matched orders when used to create a false or misleading appearance, series of transactions intended to induce others, and false or misleading statements used to induce trading. Section 10(b) and Rule 10b-5 are broader antifraud authorities. Kansas separately prohibits schemes, material misstatements/omissions, and practices operating as fraud in connection with a security; intentional violations can be felonies. [15 U.S.C. § 78i](https://uscode.house.gov/view.xhtml?edition=prelim&req=granuleid%3AUSC-prelim-title15-section78i), [17 C.F.R. § 240.10b-5](https://www.ecfr.gov/current/title-17/chapter-II/part-240/section-240.10b-5), [K.S.A. 17-12a501](https://ksrevisor.gov/statutes/chapters/ch17/017_012a_0501.html), [K.S.A. 17-12a508](https://ksrevisor.gov/statutes/chapters/ch17/017_012a_0508.html)

FINRA identifies wash/cross trades, closing-price influence, spoofing, layering, momentum ignition, and cross-product manipulation involving an underlying and options as surveillance risks. Those publications describe broker supervision, but the behaviors can expose a customer to the federal prohibitions and account closure. [FINRA Regulatory Notice 19-18](https://www.finra.org/rules-guidance/notices/19-18), [FINRA manipulative-trading report](https://www.finra.org/rules-guidance/guidance/reports/2023-finras-examination-and-risk-monitoring-program/manipulative-trading), [FINRA algorithmic-trading guidance](https://www.finra.org/rules-guidance/notices/15-09)

**Hard controls:**

- Reject potentially self-matching or coordinated opposite-side orders across every Market Mate-controlled account, venue, strategy, and related instrument. Open orders must be checked before each submission.
- Do not submit an order the strategy expects or intends to cancel rather than execute. Cancellation is permitted only for a documented market/risk/order-state reason.
- Block patterns of layered same-side orders, rapid cancel/replace bursts, quote stuffing, momentum ignition, or orders whose purpose is to move a quote, print, auction imbalance, close, open, reference price, or option value.
- Restrict illiquid/OTC orders, auction-period activity, order frequency, cancellation ratio, participation rate, and price distance through conservative instrument-specific limits.
- Prevent a strategy from trading an underlying to benefit an option position or trading an option to affect the underlying/reference market.
- Require bona-fide economic purpose and immutable intent for every order, including expected fill, holding thesis, risk, and cancellation rules.
- Detect cross-strategy and cross-instrument patterns, not just a single order. Quarantine on surveillance alerts and preserve the full sequence.
- Prohibit public posts, messages, or generated content intended to influence price or liquidity. The system may not publish promotional statements about held or planned securities.

**The system cannot know:** beneficial ownership in disconnected accounts, coordinated activity by another person, or subjective purpose with certainty. Therefore, the Principal must disclose all controlled brokerage accounts and planned coordinated trading; suspicious patterns must be blocked even if the Principal says they are accidental. There is no GUI override for a manipulation surveillance block—only cancellation, risk reduction, or counsel/compliance review.

`Wash trade` is a market-integrity concept; `wash sale` is a tax-loss deferral rule. They must remain separate domain terms and controls.

## Cash, settlement, margin, and day-trading controls

### Cash accounts, T+1, freeriding, and good-faith violations

Regulation T allows cash-account purchases when sufficient funds are present or the broker in good faith expects prompt full payment. Its cash-account rules can impose a 90-day freeze after certain sales before payment. Most stocks and listed options settle T+1. FINRA describes freeriding as buying and selling before paying and describes good-faith violations where a security bought with unsettled proceeds is sold before those proceeds settle. [12 C.F.R. § 220.8](https://www.ecfr.gov/current/title-12/chapter-II/subchapter-A/part-220/section-220.8), [FINRA brokerage accounts](https://www.finra.org/investors/investing/investment-accounts/brokerage-accounts), [FINRA T+1 overview](https://www.finra.org/investors/insights/understanding-settlement-cycles), [FINRA frequent intraday trading](https://syndication.finra.org/content/frequent-intraday-trading-understanding-basics)

Market Mate must maintain settled cash, unsettled proceeds, contractual settlement, actual settlement, restrictions, and broker buying power separately. For a cash account it must reject any purchase not fully supportable with settled cash and reject any sale that would create a broker-defined freeride/good-faith violation. Broker-calculated availability is a ceiling, not a substitute for the internal ledger. Deposits remain unavailable until broker-confirmed as settled and not reversible.

### Margin and the 2026 PDT transition

On April 14, 2026 the SEC approved FINRA's replacement of the pattern-day-trader provisions and $25,000 minimum with intraday margin standards. The new requirements became effective June 4, 2026, but brokers may use an 18-month transition through October 20, 2027. A firm may still operate under the old PDT framework during transition or migrate sooner. The system must therefore support **venue-declared rule regimes**, not assume one universal nationwide state. [SEC Release 34-105226](https://www.sec.gov/files/rules/sro/finra/2026/34-105226.pdf), [FINRA intraday-margin transition](https://syndication.finra.org/content/understanding-new-intraday-margin-requirements), [FINRA filing SR-FINRA-2025-017](https://www.finra.org/rules-guidance/rule-filings/sr-finra-2025-017)

**Hard controls:**

- Query and persist broker account type, margin regime, day-trade count/status, house margin, options buying power, calls, restrictions, and effective dates before new exposure.
- Model both legacy PDT and new intraday-margin rules during transition; apply the strictest applicable broker response when status is unclear.
- Never evade a day-trade count, margin call, account freeze, or restriction by splitting orders, changing strategies, using correlated instruments, or moving between connected accounts.
- The initial $1,000 account must not rely on margin borrowing. Broker margin capability may exist solely to support defined-risk option mechanics; internal allowed utilization and modeled-loss limits remain stricter.
- Any debit, margin call, forced liquidation notice, stale regime, or broker restriction freezes new exposure while permitting validated risk reduction.

FINRA permits brokers to impose house requirements above regulatory minima and liquidate positions without first contacting the customer. Broker-reported margin is therefore authoritative for what the broker permits but not a guarantee that an order is safe. [FINRA margin regulation](https://www.finra.org/rules-guidance/key-topics/margin-accounts)

## Short-sale controls

Regulation SHO requires order marking, a locate before most short sales, price-test restrictions after specified declines, and close-out of failures to deliver. The executing broker performs the regulatory locate and marking, but the Principal may not lie about ownership, availability, intent, or delivery. [SEC Regulation SHO FAQ](https://www.sec.gov/rules-regulations/staff-guidance/trading-markets-frequently-asked-questions-8), [SEC Regulation SHO investor guidance](https://www.sec.gov/investor/pubs/regsho.htm)

Initial Live policy should prohibit intentional short-stock orders and all naked short option positions. A broker locate response must never be synthesized or cached across orders. If exercise, assignment, correction, or broker liquidation unexpectedly creates short stock, record it as Containment Exposure, stop new exposure, and permit only broker-validated risk reduction. Market Mate must not automatically assume that buying later the same day cures a missing locate or delivery obligation.

## Options approval, exercise, assignment, and position limits

FINRA Rule 2360 requires broker approval before accepting listed-option orders, delivery of the current options disclosure document, due diligence regarding the customer's situation and objectives, position/exercise limits, and broker procedures for exercise and assignment. OCC's current Characteristics and Risks of Standardized Options is the controlling risk disclosure for standardized products. [FINRA Rule 2360](https://www.finra.org/finramanual/rules/r2360/), [OCC options disclosure document](https://www.theocc.com/company-information/documents-and-archives/options-disclosure-document)

**Hard controls:**

- Discover exact broker-granted option level and eligible strategy set; never infer approval from a successful quote or preview.
- Submit only atomic, defined-risk packages whose worst-case deliverables, fees, pin risk, early assignment, expiration, and settlement are covered under both normal and stressed states.
- Do not rely on a long leg automatically exercising to cover an assigned short leg. Track each leg and broker/OCC notice independently.
- Bind every option order to current contract identity, multiplier, deliverable, exercise style, settlement type, expiration calendar, broker cutoff, position limit, and account buying power.
- Treat broker preview as mandatory evidence when available but not final acceptance; monitor the definitive order state.
- Block new positions near lifecycle deadlines if assignment/exercise state, market data, notification delivery, or Principal/broker access is stale.
- Exercise, contrary-exercise, do-not-exercise, and lapse decisions require a dedicated lifecycle rule and broker-confirmed deadline. Missing authoritative evidence fails closed for new exposure and alerts the Principal.

The system cannot prevent an option holder from exercising or the clearing allocation of an assignment. It can only constrain what positions it opens, maintain deliverable capacity, monitor notices, and contain the resulting exposure.

## Broker agreement and API automation

API availability is permission, not blanket authorization for every automation pattern. Venue certification must archive the exact customer agreement, API terms, market-data terms, accepted disclosures, option level, authentication method, rate limits, automation restrictions, and version/effective date. A change or inability to retrieve the controlling agreement makes the affected capability `Uncertified`.

Current official examples show why venue-specific review is mandatory:

- Tradier expressly supports an individual user's own applications and algorithms with a personal token; distribution requires Partner status. Its documentation recommends sandbox testing and order previews and warns that an API `200` only means receipt—the order can still be rejected. [Tradier authentication](https://docs.tradier.com/docs/authentication), [Tradier FAQ](https://docs.tradier.com/docs/faq), [Tradier trading API](https://docs.tradier.com/docs/trading)
- tastytrade advertises read/write API access and a sandbox, but its agreement makes the license personal, limited, revocable, tied to a valid customer account and relevant certifications, and subject to its permitted-purpose terms. [tastytrade Open API](https://tastytrade.com/api/), [tastytrade API Terms of Service](https://assets.tastyworks.com/production/documents/USA/open_api_terms_and_conditions.pdf)
- IBKR expressly supports custom code for an individual's own account. It separately expects third-party automated-trading vendors to obtain regulatory registrations or a legal opinion and compliance approval. Its account terms put credential security and accepted order executions on the client. [IBKR API solutions](https://gdcdyn.interactivebrokers.com/en/trading/ib-api.php?menu=B), [IBKR Trading Web API](https://www.interactivebrokers.com/campus/ibkr-api-page/web-api-trading/), [IBKR essential legal terms](https://ndcdyn.interactivebrokers.com/Universal/Application?action=formSampleView&formdb=2109&preferredFormat=html)
- Alpaca requires OAuth for Connect applications, written approval for commercial apps, and approval before allowing Live trading for other users. Those Connect requirements are distinct from a Principal trading only the Principal's own account, but the chosen product and agreement must match actual use. [Alpaca Connect terms](https://docs.alpaca.markets/us/docs/about-connect-api)

Market Mate may not bypass broker UI/API restrictions, rotate identities to defeat rate limits, scrape private endpoints, automate a consumer interface against its terms, share credentials, misstate customer facts, or continue after permission is revoked. Only a trade-scoped, withdrawal-disabled credential may reach the Live sender.

## Market-data and non-display licensing

Automated analysis and order generation commonly constitute non-display use even when the same quote also appears in a GUI. Nasdaq's current U.S. data policy says non-display use can be fee-liable in the cloud and includes devices that run computations or create derived data; its official clarification expressly lists automated trading. NYSE likewise lists automated order generation, algorithmic price referencing, investment analysis, risk, compliance, and valuation as non-display uses. CTA publishes a separate non-display policy for consolidated data. [Nasdaq U.S. equities/options data policies](https://www.nasdaqtrader.com/content/AdministrationSupport/Policy/USEquitiesandOptionsDataPolicies.pdf), [Nasdaq non-display clarification](https://www.nasdaqtrader.com/TraderNews.aspx?id=dn2015-09), [NYSE non-display policy](https://www.nyse.com/publicdocs/nyse/data/Non-Display_Use_Policy.pdf), [CTA policies](https://www.ctaplan.com/policy)

**Hard controls:**

- No feed enters research, backtesting, model training, valuation, risk, alerts, order generation, or the dashboard until a Data Contract explicitly authorizes that exact use.
- Record display/non-display, automated-trading, derived-data, cloud/device, retention, redistribution, professional/nonprofessional, and audit/reporting entitlements separately.
- Prevent data or derived values from being exposed to another user, public endpoint, model provider, or retained dataset unless licensed.
- Do not assume a broker's free display entitlement permits server-side automated use. Obtain written vendor/broker confirmation for ambiguous personal-use API data.
- Disable the dependent strategy before entitlement expiry; delayed data is not acceptable for Live order/risk decisions merely because it is cheaper.

Whether a derived value remains licensable data and whether a one-person cloud service is fee-liable can turn on the exact agreement and architecture. This requires written provider confirmation, not an AI interpretation.

## Sanctions and restricted instruments

OFAC sanctions can block property and prohibit transactions beyond names appearing on a list, including entities owned 50% or more in aggregate by blocked persons. OFAC can impose civil penalties on a strict-liability basis, meaning a person may be civilly liable without knowing or having reason to know the conduct was prohibited. The SDN list changes without a predetermined schedule, and OFAC provides live downloadable list products. [OFAC consolidated FAQs](https://ofac.treasury.gov/faqs/all-faqs), [OFAC compliance introduction](https://ofac.treasury.gov/media/935656/download?inline), [OFAC 50 Percent Rule FAQ](https://ofac.treasury.gov/faqs/400), [OFAC Sanctions List Service](https://ofac.treasury.gov/sanctions-list-service), [OFAC update-frequency FAQ](https://ofac.treasury.gov/faqs/topic/1631)

For the initial U.S.-listed scope, require all of the following: the broker reports the instrument/account eligible; the Security Master has no known sanctions/restricted status; current OFAC list/version checks and provider restrictions are healthy; and no unsupported foreign/OTC exposure is opened. A sanctions hit or uncertain ownership match quarantines the instrument and alerts the Principal. Market Mate must never independently unblock or divest blocked property; broker instructions and sanctions counsel control. Because list matching alone cannot establish 50% ownership, indirect interests, licenses, or program-specific prohibitions, sanctions ambiguity requires counsel/OFAC guidance.

## Records, communications, and tax-adjacent boundaries

The Principal is not a FINRA member, so broker-dealer books-and-records rules do not automatically turn Market Mate into a regulated broker record system. Nonetheless, complete immutable evidence is necessary to prove compliance and reconcile the broker. Preserve source inputs, decision/intent, approval, policy versions, broker messages, order lifecycle, fills, cancellations, position/lifecycle state, surveillance alerts, attestations, denials, corrections, and data entitlements for the experiment's lifetime and at least seven years after closure, subject to longer property/tax requirements already adopted by the Capital Ledger policy.

The application must not generate public recommendations, testimonials, performance promotions, or social posts. If any communication surface later becomes public or serves another person, freeze it pending broker/adviser, advertising, privacy, and recordkeeping counsel.

Tax controls must be accurate but must not be used to obstruct lawful risk reduction. IRS Publication 550 covers wash-sale application to options, short sales, straddles, constructive sales, and product-specific rules; it also demonstrates that classifications depend on related persons and offsetting positions Market Mate may not observe. The IRS says property records generally should be kept until the limitations period expires for the year of disposition. [IRS Publication 550 (2025)](https://www.irs.gov/publications/p550), [IRS record-retention guidance](https://www.irs.gov/businesses/small-businesses-self-employed/how-long-should-i-keep-records)

The system should warn and preserve tax evidence, but only a CPA/tax professional should resolve uncertain substantially-identical securities, straddle identification, constructive sales, mixed straddles, trader status/Section 475 elections, box-spread/conversion treatment, and incomplete spouse/external-account activity. `Tax-review pending` does not mean `illegal`; it prevents false reporting claims, not necessary position exits.

## Future-scale statutory tripwires

The initial $1,000 account is far below these thresholds, but the platform must monitor them rather than assuming they can never matter:

- Exchange Act Rule 13h-1 can require a Large Trader filing and identifier when NMS-security transactions reach $20 million in a day or $200 million in a calendar month. Aggregate activity under common control matters. [SEC Rule 13h-1 FAQ](https://www.sec.gov/rules-regulations/staff-guidance/trading-markets-frequently-asked-questions/responses-frequently-0)
- Beneficial ownership above 5% of a covered class can trigger Schedule 13D or 13G obligations, with form and deadline depending on status and intent. Aggregate beneficial ownership and relevant groups matter. [SEC Regulation 13D-G interpretations](https://www.sec.gov/rules-regulations/staff-guidance/corporation-finance-interpretations/exchange-act-sections-13d-13g-regulation-13d-g-beneficial-ownership-reporting)
- Issuer officers, directors, and beneficial owners of more than 10% of a registered equity class can become subject to Section 16 reporting and short-swing-profit rules. [SEC officers, directors, and 10% shareholders](https://www.sec.gov/resources-small-businesses/going-public/officers-directors-10-shareholders)
- Restricted or control securities can require Rule 144 analysis, holding periods, volume/manner limits, current public information, and Form 144. [SEC Rule 144 guidance](https://www.sec.gov/reports/rule-144-selling-restricted-control-securities)

The Coverage Universe admission gate should calculate known ownership/concentration, identify restricted/control legends and Principal issuer roles, and generate early warnings well before a threshold. The system cannot determine every beneficial-ownership group, household holding, voting arrangement, or control fact, so approaching 4.5%, any officer/director role, any restricted security, or 50% of a Rule 13h-1 activity threshold should freeze expansion and require counsel review.

## Enforceable control catalog

### Always reject before broker submission

- any order without a complete Decision Record, Compliance Decision, Risk Decision, fresh broker state, licensed data, and certified venue capability;
- withdrawals, funds transfers, journals, credential/account changes, or trading for another person;
- intentional short stock, naked/uncovered options, non-atomic multi-leg exposure, or unsupported instruments;
- orders exceeding broker permission, option level, position/exercise limits, settled cash, margin, buying power, or internal risk limits;
- known self-match, matched-order, non-bona-fide layered/spoofing pattern, close/open/reference-price influence, or cross-product manipulation pattern;
- orders in a Restricted Issuer, sanctions quarantine, broker restriction, stale entitlement, unresolved reconciliation break, or unknown contract identity;
- broker/API calls outside documented endpoints/scopes, after revocation, or intended to defeat controls; and
- public distribution of data, advice, rankings, positions, or forecasts.

### Quarantine and require facts or counsel

- possible MNPI, confidentiality duty, employer blackout, tender offer, or Restricted-Issuer relationship;
- suspected coordination or beneficial ownership outside connected accounts;
- ambiguous order purpose or repeated manipulation-surveillance alert;
- uncertain sanctions ownership/license or restricted security;
- provider ambiguity about non-display/derived/cloud use;
- any move beyond single-Principal own-account operation;
- disputed Kansas or federal broker/dealer/adviser status;
- uncertain option deliverable, exercise/assignment, corporate action, or broker permission; and
- tax classifications that cannot be derived from certified rules and complete observed facts.

### Principal attestation is useful but not dispositive

An attestation may supply facts only the Principal knows, such as employment relationships, controlled external accounts, or awareness of confidential information. It cannot override objective evidence, legal prohibitions, a broker restriction, a surveillance block, sanctions quarantine, or the Safety Kernel. False or incomplete answers remain the Principal's legal risk, so the interface must use specific factual questions rather than a generic `I comply with all laws` checkbox.

## Compliance Decision contract

Every proposed order should produce an immutable machine-readable Compliance Decision containing:

- jurisdiction, account owner/type, environment, venue, and timestamps;
- exact instrument/contract and strategy/version;
- controlling rule/policy/data-agreement versions and current effective regime;
- settled-funds, margin/PDT or intraday-margin, options permission, short-sale, position-limit, sanctions, data-entitlement, Restricted-Issuer, self-match, manipulation-surveillance, and broker-terms results;
- external facts/attestations relied upon and their age;
- `Allowed`, `Denied`, or `Counsel/Principal Fact Review Required` outcome;
- human-readable reason codes and linked evidence;
- expiry and events that invalidate the decision; and
- the exact order/package hash authorized.

Only `Allowed` decisions may reach the Live sender. Any material change in price/size/legs, open orders, broker state, rules, permissions, data, sanctions, attestation, or timing invalidates the decision and requires re-evaluation. A broker preview or acceptance is appended as evidence but cannot change `Denied` to `Allowed`.

## Update and recertification cadence

Legal/account controls are versioned dependencies, not static documentation:

- **Before every order:** broker permissions/restrictions, account state, settled funds, open orders/self-match, instrument eligibility, option limits/lifecycle, sanctions quarantine, data entitlement, and Compliance Decision freshness.
- **Event-driven:** immediately ingest broker notices, agreement/API changes, options/corporate actions, OFAC changes, SEC/FINRA/exchange notices, data-vendor entitlement changes, employer/Principal restrictions, and enforcement alerts.
- **Daily:** verify official sanctions-list versions, broker/API status, option/instrument restrictions, data licenses, and active quarantines.
- **Weekly:** automated diff of official SEC, eCFR, FINRA rulebook/filings, OCC, OFAC, Kansas Revisor, broker legal/API pages, and market-data policy sources; produce a signed change report even when no change occurs.
- **Monthly:** formal capability recertification already required by the venue architecture, including exact agreement/rule hashes and unresolved changes.
- **Before each Restricted Live activation and after material change:** counsel-approved legal-policy version, deterministic tests, Paper replay, and Principal approval.

If a source cannot be fetched or a material change cannot be classified, affected new exposure freezes. Research and Paper may continue in quarantine. No model may interpret a legal update and promote its own new authority; it may draft a change proposal with citations and tests.

## Questions requiring qualified counsel

Obtain written, scoped advice before Restricted Live on:

1. whether the exact Kansas individual or any later single-member LLC structure remains outside Kansas/federal broker, dealer, and investment-adviser registration for the planned activity;
2. whether any employment, consulting, household, fiduciary, tender-offer, or confidential-information relationships require issuer-specific restrictions beyond the proposed attestation/list controls;
3. the manipulation-surveillance thresholds and treatment of correlated underlying/options activity, auctions, illiquid securities, and repeated cancel/replace behavior;
4. sanctions screening sufficiency for the chosen U.S.-listed/OTC universe and response to restricted-property events;
5. each selected broker's written acceptance of unattended personal automation, credential method, and exact options strategies;
6. each data supplier's written display/non-display, cloud, derived-data, storage, model-training, and automated-order entitlements;
7. whether any future public dashboard, additional user, copied strategy, subscription, compensation, or external-account connection changes registration/communications obligations; and
8. tax treatment of box spreads, conversions, straddles, constructive sales, mixed products, and external/household wash-sale exposure with a CPA or tax attorney.

Counsel review is a promotion prerequisite, not a standing approval of future changes. The legal opinion must state facts, scope, assumptions, date, jurisdictions, and invalidation triggers.

## Implementation handoff

The blocked human policy decision should choose the exact severity and operator workflow, but the following are non-negotiable design constraints surfaced by this research:

- `Compliance Gate` is a deterministic Safety Kernel module and has no Principal override for hard denials.
- `Restricted Issuer`, `Compliance Decision`, `Surveillance Alert`, `Legal Policy Version`, `Broker Rule Regime`, and `Data Entitlement` are first-class domain objects.
- All connected Principal accounts must participate in self-match, manipulation-pattern, wash-sale-evidence, and exposure checks; unconnected controlled accounts must be disclosed as limitations.
- A legal/account rule change can remove authority immediately but can add authority only through validated promotion.
- The GUI must say why an action was blocked, distinguish law from broker/data policy, and offer safe next actions: cancel, reduce risk, update facts, or obtain counsel.
- No wording should claim that Market Mate guarantees legality, prevents prosecution, or replaces legal/tax advice.

Under this design, Market Mate can strongly reduce prohibited-conduct risk and make known structural violations non-executable. It cannot eliminate liability arising from hidden facts, false attestations, ambiguous intent, unobserved accounts, provider errors, or future rule changes.
