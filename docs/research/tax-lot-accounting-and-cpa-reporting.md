# Tax-lot accounting and CPA reporting requirements

Research date: 2026-08-21
Scope: records, lot methods, wash-sale and straddle handling, option exercise and assignment, Section 1256 distinctions, broker-statement reconciliation, forms, retention, and CPA review checkpoints that the Capital Ledger and Audit Dashboard must support for a Kansas Principal's personally owned, self-directed taxable brokerage account. This is a research inventory of primary-source requirements, not tax advice, a return-preparation procedure, or an investment recommendation.
Method: current Internal Revenue Code text, IRS publications and form instructions, and Kansas statute. Claims that depend on facts and circumstances, elections, or professional judgment are labeled as such. The already-closed decision [Require tax-ready accounting before live options trading](https://github.com/jaylamping/market-mate/issues/28) requires this package before live options authorization and requires a qualified tax professional to review wash-sale, straddle, assignment/exercise, and Section 1256 treatment for the selected strategies. This report does not assume trader-tax status or a section 475 mark-to-market election.

## Decision summary

The Capital Ledger cannot treat a broker 1099-B, a realized-P&L dashboard, or an environment-level cash balance as the tax books. For the contemplated personal account, tax reporting is lot-based, form-driven, and often stricter than broker reporting:

1. **Keep an immutable Tax Lot for every covered and noncovered security and option position.** Cost basis includes commissions and purchase costs. Amount realized is reduced by selling commissions and similar sale expenses. If the Principal does not adequately identify lots at sale time, FIFO is the default for ordinary stock. Average basis is not a general stock method; it is a mutual-fund / DRIP election. [Publication 550](https://www.irs.gov/publications/p550), [Publication 551](https://www.irs.gov/publications/p551)
2. **Treat broker Form 1099-B as a reconciliation input, not the authority.** Brokers must report wash-sale disallowances in box 1g only for same-account, same-CUSIP, covered-security pairs. The taxpayer still cannot deduct a wash-sale loss that the broker omitted, including cross-account, spouse, IRA, and option-to-acquire replacements. [Instructions for Form 1099-B](https://www.irs.gov/instructions/i1099b), [Instructions for Schedule D (Form 1040)](https://www.irs.gov/instructions/i1040sd)
3. **Model listed equity options under section 1234, not section 1256, unless a product is a nonequity option.** For a non-dealer individual, listed single-stock and other equity options generally produce capital gain or loss on lapse or close, and premium adjusts stock basis or amount realized on exercise or assignment. Listed nonequity options, including many broad-based index options, are section 1256 contracts: year-end mark-to-market and 60/40 character, reported on Form 6781. [26 U.S.C. §1234](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1234&num=0&edition=prelim), [26 U.S.C. §1256](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1256&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)
4. **Do not certify a multi-leg options strategy as tax-complete until a CPA reviews straddle, qualified-covered-call, constructive-sale, and mixed-straddle exposure.** Offsetting stock and option positions can defer losses against unrecognized gain, require Form 6781, and interact with wash-sale coordination rules. A defined-risk package is not automatically a qualified covered call or an identified straddle. [26 U.S.C. §1092](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1092&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)
5. **Kansas starts from federal adjusted gross income.** There is no general Kansas capital-gain exclusion in the listed modifications. Keep the federal lot ledger and Form 8949/Schedule D package; add only Kansas Schedule S modifications that actually apply. [K.S.A. 79-32,117](https://www.ksrevisor.gov/statutes/chapters/ch79/079_032_0117.html)
6. **Retain property records until the limitations period expires for the year of taxable disposition**, and keep the rest of the CPA-ready package at least through the ordinary three-year period, six years if substantial omitted income is possible, and seven years for worthless-security claims. [How long should I keep records?](https://www.irs.gov/businesses/small-businesses-self-employed/how-long-should-i-keep-records)

Paper Ledger events remain structurally comparable but must never be commingled with Capital Ledger tax lots or used as tax evidence.

## What this research is and is not

| Label | Meaning |
|---|---|
| **Documented** | A current statute, IRS publication, or form instruction states the rule. |
| **Facts and circumstances** | The source gives a standard (for example “substantially identical”) but not a mechanical test for every instrument pair. |
| **Professional review required** | Applying the rule to a Strategy Version is tax advice. Market Mate records the evidence; a CPA or attorney concludes treatment. |
| **Out of scope here** | Opening accounts, filing returns, recommending securities, assuming section 475, or treating Market Mate as a tax preparer. |

A Tax Lot is a reporting and evidence object. It does not authorize an order, replace a Risk Decision, or convert Paper P&L into Live economics.

## Required records

Publication 550 and Publication 551 require enough history to compute adjusted basis and holding period. Publication 552 and the Form 8949 instructions imply the same fields for investment property. For Market Mate's contemplated stocks and listed options, each Capital Ledger Tax Lot and each later adjustment must retain at least:

| Field | Why it is required |
|---|---|
| Instrument identity, CUSIP or OCC option symbol, put/call, strike, expiration, underlying | Wash-sale same-CUSIP reporting; equity versus nonequity classification; Form 8949 description |
| Execution Environment, venue account, and Environment Epoch | Paper and Live never share lots; brokers compute wash sales per account |
| Acquisition trade date and time, quantity, cash paid, commissions, transfer fees | Cost basis; trade-date holding period for exchange-traded securities |
| Lot method used and, if specific identification, the trade-time instruction plus broker written confirmation | Adequate identification versus FIFO default |
| Covered or noncovered status and whether basis was reported to the IRS | Form 8949 boxes A–F |
| Corporate-action and return-of-capital adjustments, with issuer notices | Split, spin-off, and reorganization basis allocation |
| Wash-sale disallowances, replacement-lot basis add-backs, and tacked holding periods, including events the broker omitted | Taxpayer duty beyond box 1g |
| Option premium, role (holder or writer), open/close/lapse/exercise/assignment, cash versus physical settlement | Section 1234 premium adjustments |
| Linked stock lots created or closed by exercise or assignment | Holding period starts the day after exercise; writer assignment adjusts stock basis or amount realized |
| Year-end fair market value of open section 1256 contracts and prior-year mark-to-market already recognized | Section 1256(a); Form 6781 |
| Year-end fair market value of offsetting positions with unrecognized gain | Section 1092; Form 6781 Part III |
| Short-sale open and close dates, delivered lot, and substitute payments | Short-sale character rules; payments in lieu of dividends |
| Broker Form 1099-B / substitute statement lines and every Form 8949 column (f)/(g) adjustment | Reconciliation contract |

Holding period for securities traded on an established market begins the day after the purchase trade date and ends on the sale trade date. Do not use settlement date for that clock. A December 31 sale of exchange-traded stock is reported for that calendar year even if cash settles in January. [Publication 550](https://www.irs.gov/publications/p550)

Worthless securities are treated as sold on the last day of the year they become wholly worthless. A later refund claim for that loss generally has a seven-year window. [Publication 550](https://www.irs.gov/publications/p550), [How long should I keep records?](https://www.irs.gov/businesses/small-businesses-self-employed/how-long-should-i-keep-records)

## Tax-lot methods

### Cost and amount realized

The original basis of purchased investment property is cost. For stocks and bonds that includes purchase commissions and recording or transfer fees. Amount realized is everything received minus sale expenses such as sales commissions, redemption fees, or exit fees. Gain or loss is amount realized minus adjusted basis. [Publication 550](https://www.irs.gov/publications/p550), [Publication 551](https://www.irs.gov/publications/p551), [Instructions for Form 8949](https://www.irs.gov/instructions/i8949)

The Capital Ledger already records Cash Movements at currency-minor-unit precision. Tax lots need the same precision plus an explicit split between amounts that enter basis, amounts that reduce proceeds, and amounts that are currently deductible investment expenses. Do not collapse those three into a single “fee” bucket.

### Specific identification, FIFO, and average basis

| Method | Documented use |
|---|---|
| **Specific identification** | Allowed when the taxpayer adequately identifies the particular shares or bonds sold. |
| **FIFO** | Default when lots cannot be adequately identified. Oldest remaining shares are treated as sold first. |
| **Average basis** | Available for identical mutual-fund / RIC shares, and for DRIP shares under the Publication 550 conditions. Not a general method for ordinary common stock. |

Publication 550 and Publication 551 describe adequate identification of broker-held stock as: specify the particular shares **at the time of the sale or transfer**, and receive **written confirmation within a reasonable time**. The taxpayer still has the burden of proving basis of the specified shares. If certificates from a stated lot are delivered, that delivery can also identify the lot. [Publication 550](https://www.irs.gov/publications/p550), [Publication 551](https://www.irs.gov/publications/p551)

Broker Form 1099-B instructions use the same idea: if the customer sells less than the entire position and provides adequate and timely identification, report that sale; otherwise report unknown-acquisition-date shares first, then FIFO. [Instructions for Form 1099-B](https://www.irs.gov/instructions/i1099b)

**Facts and circumstances / unknown:** Publication 550 and Publication 551 do not treat a standing broker lot preference, by itself, as adequate identification. Whether a standing instruction can satisfy Treasury Regulation §1.1012-1 is a professional-review question. Until a CPA confirms a standing-order design, Market Mate should record a trade-time lot instruction on the Order Plan and retain the broker confirmation as evidence.

Average basis, if ever used, requires written notice to the custodian for covered securities and is effective only for dispositions after that notice. The election can be revoked only on a short timeline. Once average basis has been used for shares in a mutual fund, cost-basis specific identification is no longer available for other shares in that fund. [Publication 550](https://www.irs.gov/publications/p550)

**Blueprint implication:** default the live Capital Ledger to specific identification with FIFO fallback. Do not invent a tax-optimized lot picker that chooses lots after seeing the result. Identification must exist at sale time. Paper Ledger may simulate the same methods for parity, but Paper lots never become tax lots.

### Corporate actions

Nontaxable stock splits and identical stock dividends allocate old basis across the enlarged share count. Nontaxable reorganizations and spin-offs generally carry basis over or allocate it using issuer information. Publication 550 tells taxpayers to keep that issuer allocation until the limitations period expires for the year the stock is disposed of in a taxable transaction. [Publication 550](https://www.irs.gov/publications/p550)

## Wash sales

### Statutory pattern

A wash sale exists when stock or securities are sold or otherwise disposed of at a loss and, within 30 days before or after that disposition, the taxpayer acquires substantially identical stock or securities, acquires them in a fully taxable trade, or acquires a contract or option to acquire them. Acquisition by a spouse or a controlled corporation also counts. Losses are disallowed except for a dealer acting in the ordinary course of business. The disallowed loss is added to the basis of the replacement property, and the replacement holding period includes the holding period of the shares sold. [Publication 550](https://www.irs.gov/publications/p550), [26 U.S.C. §1091](https://uscode.house.gov/view.xhtml?edition=2023&num=0&req=granuleid%3AUSC-2023-title26-section1091)

Section 1091 expressly includes contracts or options to acquire or sell stock or securities, including cash-settled contracts. [26 U.S.C. §1091](https://uscode.house.gov/view.xhtml?edition=2023&num=0&req=granuleid%3AUSC-2023-title26-section1091)

Publication 550 applies wash-sale rules to losses on contracts and options to acquire or sell stock or securities, and not to commodity futures or foreign currencies. Buying replacement shares inside an IRA or Roth IRA can still create a wash sale; the IRA acquisition does not receive the usual basis add-back. The ledger must therefore record the loss disallowance separately from any replacement-lot basis increase and holding-period tacking. [Publication 550](https://www.irs.gov/publications/p550)

Partial replacement matches purchases against sold shares; only the matched quantity loses the current deduction. [Publication 550](https://www.irs.gov/publications/p550)

### Substantially identical

Publication 550 says to consider all facts and circumstances. Stock of one corporation is ordinarily not substantially identical to stock of another. Common and preferred or bonds of the same issuer are ordinarily not identical unless convertibility and market prices make them so. Selling common and buying warrants of the same corporation is a wash sale; the reverse is a wash sale only if the warrant and common are substantially identical. [Publication 550](https://www.irs.gov/publications/p550)

**Facts and circumstances:** whether two ETFs, an ETF and a mutual fund, or two option contracts are substantially identical is not a bright-line table in these sources. The ledger must retain enough instrument and timing evidence for a CPA to apply the standard. Market Mate must not invent a “same-issuer equals identical” or “same-sector equals identical” rule.

### Short-sale wash sales

Wash-sale rules apply to a short-sale loss if the taxpayer sells, or enters another short sale of, substantially identical stock or securities in a window beginning 30 days before the short sale is complete and ending 30 days after. For wash-sale purposes a short sale can be complete on the date it is entered if the taxpayer already owns identical stock or a contract or option to acquire it and later delivers to close; otherwise it is complete on delivery. [Publication 550](https://www.irs.gov/publications/p550)

### What brokers report versus what the taxpayer must compute

Form 1099-B box 1g **must** report section 1091 disallowances when both the sale and the replacement occur in the same account, in covered securities, with the same CUSIP. Brokers **may** report other wash sales, including cross-account replacements, but are not required to. Brokers need not consider transactions outside the account. Checking box 5 on a noncovered sale can leave box 1g blank. [Instructions for Form 1099-B](https://www.irs.gov/instructions/i1099b)

Publication 550 and the Schedule D instructions are explicit: the taxpayer still cannot deduct a wash-sale loss that Form 1099-B omitted. Report the sale on Form 8949, enter code **W** in column (f), and enter the disallowed loss as a positive number in column (g). If the broker’s box 1g amount is wrong, enter the correct disallowance and attach an explanation when the taxpayer’s amount is smaller. [Publication 550](https://www.irs.gov/publications/p550), [Instructions for Form 8949](https://www.irs.gov/instructions/i8949), [Instructions for Schedule D (Form 1040)](https://www.irs.gov/instructions/i1040sd)

**Blueprint implication:** the Safety Kernel and Coverage Universe can create wash sales that no venue 1099-B will see: replacement in a different paper-versus-live discussion is irrelevant because Paper is not tax, but Live replacements across CUSIPs, option contracts, or future additional accounts are taxpayer-side. Autonomous re-entry within 30 days after a loss is a tax-event generator, not merely a trading-style choice. Whether the system should block, warn, or only record those replacements is a later ledger/governance decision; the evidence requirement is not optional.

Section 1256 mark-to-market losses taken into account under section 1256(a)(1) are not wash sales. That exception does not rescue ordinary equity-option or stock wash sales. [26 U.S.C. §1256(f)(5)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1256&num=0&edition=prelim)

## Straddles

A straddle is offsetting positions in actively traded personal property. An offsetting position substantially reduces risk of loss from another position. Stock is generally excluded, but is included when it is actively traded and at least one offsetting position is in that stock or substantially similar or related property, or when a corporation is used to take offsetting personal-property positions. Option pairs, stock-plus-option hedges, and marketed spreads or butterflies can meet the presumption tests. Positions held by a spouse are attributed. [26 U.S.C. §1092](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1092&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)

### Loss deferral

Unrecognized losses on straddle positions are allowed only to the extent they exceed unrecognized gain on offsetting positions at year-end. Excess loss carries forward and is tested again. Unrecognized gain is, broadly, the mark-to-market gain that would be realized if offsetting positions were sold on the last business day of the year, plus realized but unrecognized gain. [26 U.S.C. §1092(a)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1092&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)

Publication 550 also coordinates wash-sale-like replacement rules with straddle deferral when a straddle includes stock or securities: a loss can be blocked by a 30-day replacement and then further limited by unrecognized gain in successor or remaining offsetting positions.

### Identified straddles and mixed-straddle elections

An identified straddle, clearly identified on the taxpayer’s records by the close of the day the straddle is acquired, uses basis adjustments instead of the basic loss-deferral rule. Mixed straddles (at least one but not all positions are section 1256 contracts) have elections commonly labeled A (elect out of mark-to-market for the 1256 legs), B (straddle-by-straddle identification), and C (mixed-straddle account). Publication 550 says to choose only one. Detail lives in section 1092(b) regulations. [Publication 550](https://www.irs.gov/publications/p550), [26 U.S.C. §1092](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1092&num=0&edition=prelim)

### Qualified covered calls

Section 1092 excepts certain qualified covered call options written against the optioned stock from straddle treatment, if they are exchange-traded, granted more than 30 days before expiration, not deep-in-the-money, and meet the remaining statutory tests. Deep-in-the-money is a strike below the lowest qualified benchmark derived from available strikes and the applicable stock price. A year-end timing rule can still pull a loss back into section 1092(a). This exception is narrower than “any covered call” or “any defined-risk package.” [26 U.S.C. §1092(c)(4)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1092&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)

**Professional review required:** whether a Market Mate covered-call, collar, vertical, or calendar is a straddle, an identified straddle, a qualified covered call, or a mixed straddle is not something a Strategy Version may decide. The Options Lifecycle Engine must retain the economic legs, identification timestamps, strikes, and year-end values so a CPA can decide.

### Constructive sales

Entering a short sale, offsetting notional principal contract, or futures/forward to deliver the same or substantially identical property against an appreciated financial position can be a constructive sale: gain is recognized as if the position were sold at fair market value, and holding period restarts. Mark-to-market section 1256 positions are excepted. A closed-out transaction can escape if it is closed within a short window after year-end and risk of loss is not reduced for 60 days. [Publication 550](https://www.irs.gov/publications/p550)

Short-against-the-box style hedges are therefore tax events even if the long stock lot is never delivered.

## Option exercise, assignment, and Section 1256

### Non-dealer equity options

For a non-dealer individual, listed equity options (options on stock or a narrow-based security index) are generally **not** section 1256 contracts. They follow Publication 550’s puts-and-calls rules and section 1234. [26 U.S.C. §1256(b), (g)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1256&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)

Publication 550 Table 4-3, condensed:

| Event | Holder | Writer |
|---|---|---|
| Call exercised | Add call cost to basis of stock purchased | Increase amount realized on the stock sale by the call premium |
| Put exercised | Reduce amount realized on the stock sale by the put cost | Reduce basis of stock purchased by the put premium |
| Option expires | Capital loss equal to cost; holding period ends on expiration | Short-term capital gain equal to premium |
| Closing sale or repurchase | Capital gain or loss versus cost; long-term or short-term by option holding period | Short-term capital gain or loss versus premium |

Writer premium is not income when received; it sits in a deferred account until lapse, exercise, or closing. Holder premium is a capital expenditure, not a current deduction. Holding period of stock acquired by exercising an option begins the day after exercise. Writer stock purchased on put assignment begins its holding period on the purchase date, not the date the put was written. Buying a put is generally treated as a short sale and can restart the holding period of recently acquired underlying stock. [Publication 550](https://www.irs.gov/publications/p550), [26 U.S.C. §1234](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1234&num=0&edition=prelim)

If a written call is assigned and the premium is missing from Form 1099-B proceeds, Form 8949 uses code **E** and a positive column (g) adjustment. Lapsed purchased options are reported as “Expired.” [Publication 550](https://www.irs.gov/publications/p550), [Instructions for Form 8949](https://www.irs.gov/instructions/i8949)

Cash-settled options are still options. Exercise of an option on a section 1256 contract recognizes gain or loss. [26 U.S.C. §1234(c)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1234&num=0&edition=prelim)

### Section 1256 contracts

A section 1256 contract includes regulated futures contracts, certain foreign-currency contracts, **nonequity options**, dealer equity options, and dealer securities futures contracts. A nonequity option is a listed option that is not an equity option, including many debt, commodity, currency, and **broad-based stock-index** options. [26 U.S.C. §1256(b), (g)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1256&num=0&edition=prelim), [Publication 550](https://www.irs.gov/publications/p550)

Each section 1256 contract held at year-end is treated as sold at fair market value on the last business day. Terminations during the year, including exercise, assignment, and lapse, use the same regime. Capital gain or loss is 40% short-term and 60% long-term regardless of holding period. Report on Form 6781 Part I, including Form 1099-B box 11 amounts, then carry the 60/40 split to Schedule D. [26 U.S.C. §1256(a), (c)](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1256&num=0&edition=prelim), [2025 Form 6781](https://www.irs.gov/pub/irs-pdf/f6781.pdf)

**Unknown until product certification:** whether a particular index or ETF option is narrow-based (equity option) or broad-based (nonequity / section 1256) is a securities-law classification, not something Market Mate may infer from the ticker. The Venue Capability Manifest and instrument identity contract must record that classification before any such product is Trade Eligible.

If the initial live universe stays in single-stock and ETF equity options, Form 6781 Part I may rarely apply. Form 6781 Parts II and III can still apply if equity options and stock form a straddle.

## Broker-statement reconciliation and forms

### Annual reporting chain

1. Venue issues Form 1099-B (due to the taxpayer by mid-February for the prior year) showing proceeds and, for covered securities, basis, term, accrued market discount, and some wash-sale disallowances. [Publication 550](https://www.irs.gov/publications/p550)
2. Taxpayer completes Form 8949 to reconcile those lines to actual basis, holding period, wash-sale adjustments, selling expenses, and option-premium adjustments. [Instructions for Form 8949](https://www.irs.gov/instructions/i8949)
3. Form 8949 totals flow to Schedule D. Exception 1 allows some clean covered, basis-reported, unadjusted 1099-B lines to summarize directly on Schedule D lines 1a/8a. [Instructions for Form 8949](https://www.irs.gov/instructions/i8949)
4. Section 1256 contracts and straddles use Form 6781 before Schedule D. [Publication 550](https://www.irs.gov/publications/p550)
5. Kansas K-40 uses federal adjusted gross income plus or minus listed modifications. [K.S.A. 79-32,117](https://www.ksrevisor.gov/statutes/chapters/ch79/079_032_0117.html)

### Form 8949 boxes and codes the Audit Dashboard must be able to populate

| Box | Meaning |
|---|---|
| A / D | 1099-B received; basis shown and reported to the IRS (short-term / long-term) |
| B / E | 1099-B received; basis missing or not reported to the IRS |
| C / F | No 1099-B |

| Code | Meaning the ledger must support |
|---|---|
| **W** | Nondeductible wash-sale loss |
| **B** | Basis on the 1099-B is wrong |
| **T** | Term (short-term vs long-term) on the 1099-B is wrong |
| **E** | Selling expenses or written-call premium not reflected on the form |
| **L** | Other nondeductible loss |

Always report the 1099-B proceeds in column (d). If basis was reported to the IRS, start from that basis in column (e) and correct in column (g). [Instructions for Form 8949](https://www.irs.gov/instructions/i8949)

### Short sales

Report a short sale on Form 8949 in the year it closes. Form 8949 treats the acquired date as the date property is delivered to close. Brokers generally do not report post-2010 short sales until delivery. Special character rules can force short-term gain or long-term loss when substantially identical property is already held. [Instructions for Schedule D (Form 1040)](https://www.irs.gov/instructions/i1040sd), [Instructions for Form 1099-B](https://www.irs.gov/instructions/i1099b), [Publication 550](https://www.irs.gov/publications/p550)

Payments in lieu of dividends on an open short that is closed too quickly are capitalized into the basis of the closing shares rather than deducted. Substitute payments the broker reports on Form 1099-MISC are other income, not dividends. [Publication 550](https://www.irs.gov/publications/p550)

### Reconciliation identity

The Capital Ledger must prove, for each tax year and venue account:

- every 1099-B line maps to one or more Tax Lots and Venue Events;
- every Tax Lot disposition maps to a 1099-B line, a no-1099 Form 8949 row, or a documented exception;
- cash, position, and lot quantities still agree after fees, assignments, and corporate actions;
- Paper Ledger totals are excluded from that proof.

A Reconciliation Break already freezes new exposure. A tax-lot break against a 1099-B is a Reconciliation Break, not a cosmetic reporting difference.

## Retention

Keep records that support income, deductions, and credits until the period of limitations for that return expires. Returns filed early are treated as filed on the due date. [How long should I keep records?](https://www.irs.gov/businesses/small-businesses-self-employed/how-long-should-i-keep-records), [Topic no. 305](https://www.irs.gov/taxtopics/tc305)

| Situation | Documented period |
|---|---|
| Ordinary assessment / ordinary records | 3 years after filing |
| Claim for credit or refund | Later of 3 years after filing or 2 years after payment |
| Omitted income more than 25% of gross income shown | 6 years |
| Worthless-security or bad-debt loss claim | 7 years |
| No return or fraudulent return | Indefinite |
| Property / basis records | Until the limitations period expires for the year of taxable disposition; keep exchanged-property records until the replacement is disposed of |

Form 6781’s paperwork notice states the same underlying rule: retain books and records as long as their contents may become material in administering any Internal Revenue law. [2025 Form 6781](https://www.irs.gov/pub/irs-pdf/f6781.pdf)

Kansas Department of Revenue income instructions tell taxpayers to keep a copy of the federal return because the state may request it later. K.S.A. 79-3234 requires the secretary to preserve returns for three years; that is an agency duty, not a taxpayer maximum. No official KDOR page located in this review sets a shorter brokerage-record period than the federal property-record rule.

**Blueprint implication:** do not purge Tax Lots, confirmations, or corporate-action notices when a position closes. Retention follows the later of the federal property-record rule and any CPA-specified longer period.

## Kansas reporting

Kansas adjusted gross income of an individual is federal adjusted gross income for the taxable year, with the modifications specified in K.S.A. 79-32,117. The listed additions and subtractions include items such as certain state/local interest, state income-tax deductions, and U.S. obligation interest. The statute includes a subtraction where Kansas adjusted basis exceeds federal adjusted basis, limited for long-term capital gain to the portion included in federal AGI. This review found **no general Kansas exclusion for capital gains**. [K.S.A. 79-32,117](https://www.ksrevisor.gov/statutes/chapters/ch79/079_032_0117.html)

For a newly acquired taxable brokerage account whose federal and Kansas bases match, the federal Form 8949/Schedule D package is the Kansas evidence package, plus K-40 / Schedule S for any listed modification that actually applies.

**Unknown:** future Kansas legislation could add a capital-gain preference. The ledger should store federal character and holding period so a later state modification can be applied without rebuilding lots.

## CPA-ready evidence package

[Require tax-ready accounting before live options trading](https://github.com/jaylamping/market-mate/issues/28) already requires a CPA-ready package before live options authorization. The sources above imply the following artifact list. This is a documentation inventory, not a filing instruction.

1. Year-to-date and year-end Tax Lot register, covered and noncovered, with method (specific identification or FIFO), trade-time identification evidence, and tacked holding periods.
2. All Forms 1099-B and substitute statements, transfer statements, and a line-level reconciliation to Form 8949.
3. Draft Form 8949 and Schedule D, including codes W, B, T, E, and Expired rows, plus any Exception 1 rollups.
4. Option lifecycle journal: premiums, opens, closes, lapses, exercises, assignments, cash settlements, and the resulting stock-lot basis or amount-realized adjustments.
5. Wash-sale workpapers for same-account and taxpayer-side (cross-CUSIP, option-replacement, IRA, related-party) matches the broker may omit.
6. Year-end mark file: open section 1256 values; unrecognized gain on possible straddle offsets; constructive-sale candidates (short-against-the-box, offsetting forwards).
7. Draft Form 6781 if any section 1256 contract or straddle exists, including mixed-straddle election state (none unless a CPA directs an election).
8. Corporate-action and issuer basis-allocation notices.
9. Short-sale and substitute-payment journal.
10. Capital-loss carryover worksheet from Publication 550 / Schedule D.
11. Federal return copy and Kansas K-40 / Schedule S bridge from federal AGI.
12. Written CPA review covering wash-sale, straddle, assignment/exercise, and Section 1256 treatment of each Strategy Version proposed for live options use.

The Audit Dashboard should show this package as evidence, not as a prepared return. Market Mate is not the taxpayer’s return preparer.

## Ledger and dashboard requirements for later tickets

[Live Capital Ledger, Paper Ledger, P&L attribution, and reconciliation rules](https://github.com/jaylamping/market-mate/issues/16) should treat the following as constraints, not optional reports:

- Cash Movement is not realized gain or loss. Realized tax gain or loss exists only when a Tax Lot is disposed of under the rules above, and it can differ from economic P&L because of wash-sale deferral, straddle deferral, constructive sales, and 60/40 marks.
- Unrealized dashboard P&L is not unrecognized gain for section 1092 unless it is computed on the statutory year-end valuation of the offsetting position.
- Paper lots may mirror the schema for parity tests. They must use a distinct identifier space and must be omitted from every CPA package and 1099-B reconciliation.
- Autonomous strategy loops that re-enter a name or a contract to acquire it within 30 days after a loss are wash-sale events even when the Safety Kernel approved both trades.
- Multi-leg options require an Options Lifecycle Engine journal that can reconstruct holder versus writer, premium deferral, and stock-lot linkage after assignment.

No Strategy Version, sentiment model, or dashboard export may rewrite a closed Tax Lot. Corrections are append-only adjustments with Decision Records.

## Unknowns and professional-review items

- Whether any specific ETF, index option, or warrant pair is “substantially identical” or “substantially similar or related property.”
- Whether a standing broker lot algorithm can be adequate identification without a per-trade instruction.
- Exact wash-sale treatment of every option replacement pattern beyond the statute’s “contract or option to acquire” language.
- Whether a given Market Mate spread is a straddle, qualified covered call, identified straddle, or mixed straddle.
- Narrow-based versus broad-based classification of any index product the system does not yet certify.
- Kansas city or local tax, estimated-tax cash-flow, and net-investment-income tax computations (federal Form 8960) were not required to answer the ticket and were not researched in full.
- Any change in law after the 2025 publications and the Code text retrieved on 2026-08-21.

Those unknowns do not block the recordkeeping contract. They block any claim that Market Mate can certify tax results without a CPA.

## Sources

- [Publication 550 (2025), Investment Income and Expenses](https://www.irs.gov/publications/p550)
- [Publication 551 (December 2025), Basis of Assets](https://www.irs.gov/publications/p551)
- [Publication 552, Recordkeeping for Individuals](https://www.irs.gov/publications/p552)
- [Instructions for Form 8949 (2025)](https://www.irs.gov/instructions/i8949)
- [Instructions for Schedule D (Form 1040) (2025)](https://www.irs.gov/instructions/i1040sd)
- [Instructions for Form 1099-B](https://www.irs.gov/instructions/i1099b)
- [2025 Form 6781](https://www.irs.gov/pub/irs-pdf/f6781.pdf)
- [How long should I keep records?](https://www.irs.gov/businesses/small-businesses-self-employed/how-long-should-i-keep-records)
- [Topic no. 305, Recordkeeping](https://www.irs.gov/taxtopics/tc305)
- [26 U.S.C. §1091](https://uscode.house.gov/view.xhtml?edition=2023&num=0&req=granuleid%3AUSC-2023-title26-section1091)
- [26 U.S.C. §1092](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1092&num=0&edition=prelim)
- [26 U.S.C. §1234](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1234&num=0&edition=prelim)
- [26 U.S.C. §1256](https://uscode.house.gov/view.xhtml?req=granuleid:USC-prelim-title26-section1256&num=0&edition=prelim)
- [K.S.A. 79-32,117](https://www.ksrevisor.gov/statutes/chapters/ch79/079_032_0117.html)
