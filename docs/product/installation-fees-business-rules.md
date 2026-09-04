# Installation Fees — Business Rules

Companion to `reseller-financial-operations-blueprint.md`. Tags: **FACT** / **INFERENCE** /
**RECOMMENDATION** / **APPROVED** / **OPEN DECISION**.

Architecture review closed 2026-08-16. Sections 2, 3 and 4 are approved business rules.

---

## 1. Stage derivation

**FACT.** Today the stage is derived from `Remaining` alone, in two places that must agree:

| Remaining | Stage | Amount |
|---|---|---|
| 13000 | P1 | 3000 |
| 10000 | P2 | 3000 |
| 7000 | P3 | 3000 |
| 4000 | P4 | 4000 |
| 0 | DONE | 0 |
| anything else, or blank | **unresolved** | none — never guessed |

Sources: `assets/js/installation-fees.js` `STAGE_BY_REMAINING`; SQL
`installation_stage_for_remaining` / `installation_amount_for_stage`
(`20260815160000_add_installation_fees.sql`).

**FACT.** `stage` means **"the next instalment due"**. It does not imply the earlier ones are
unpaid. The evidence of what was paid lives only in `installation_payment_history`.

**RECOMMENDATION.** Replace the constant with a scheme version lookup
(`configuration-engine-architecture.md` §3). A future V2 with three or five stages must not
retroactively move a subscriber enrolled under V1.

---

## 2. Resolution and eligibility

**FACT / APPROVED.** A row is `unresolved` when either:

1. `Remaining` is blank or is not one of the five known values, or
2. `total_amount − received_total ≠ remaining` (financial mismatch).

In both cases the **raw values are stored exactly as the file had them** and nothing is
corrected. Enforced by `installation_state_mismatch_is_unresolved`.

**FACT.** `payment_eligible` is a stored, server-derived column. It is true only when
`resolution = 'resolved'` **and** `current_stage ∈ {P1,P2,P3,P4}`. DONE is never eligible —
there is nothing left to pay. Enforced by two CHECK constraints; a direct `UPDATE` that
tries to violate either is rejected (verified against production, 4/4 refused).

**FACT.** Eligibility is never recomputed in the browser. The interface reads the stored
value (`fetchInstallationSubscribers` selects `payment_eligible`).

**Production distribution as of the baseline:** 5,674 resolved / 19 unresolved
(14 financial mismatch, 5 blank Remaining) · 2,196 eligible / 3,497 blocked
(3,492 DONE + 5 with no stage).

---

## 3. Incomplete payment detail

**FACT, and APPROVED at review (D-06).** 15 subscribers are `DONE` with no P4 payment
recorded. They carry the warning `historical_payment_detail_incomplete`, remain `resolved` on
the accepted historical balance, and **no P4 event or date is ever synthesised**. The flag is
retained permanently so the gap stays visible to audit. If such a row also fails the
accounting check, rule §2 governs and it becomes unresolved.

**APPROVED (D-04, D-05).** The 14 financial-mismatch and 5 blank-`Remaining` subscribers
remain **unresolved and blocked**. No automatic entitlement, no automatic payment, and
`Remaining` is never inferred. Clearing one requires an audited correction.

---

## 4. Loan-3 — FINAL

**APPROVED and FINAL.** Loan-3 does not exist anywhere in the current codebase — `grep` finds
no reference. It is a forward requirement, and the rule below is settled.

Loan-3 is a **debt service**, not a qualifying activation:

| Loan-3 | |
|---|---|
| stored in raw SaaS event history | **yes** |
| appears in the subscriber timeline | **yes** |
| counts inside SaaS lifetime `activations_count` | **yes** |
| creates an installation fee entitlement | **no** |
| triggers P1 | **no** |
| counts as a paid card activation | **no** |
| is an invoice | **no** |

The qualifying event in `created → Loan-3 → P-35000` is **P-35000**.

**RECOMMENDATION.** Encode this as package master data
(`classification = 'debt_service'`), never as an `if` on the string `Loan-3`.

---

## 5. New vs Existing

**FACT.** No such engine exists today. The current raw import deduplicates by the `id`
column **within a single file** (`seenIds`, `index.html:697`) and has no memory across
months.

**RECOMMENDATION.** Decide against the Subscriber Registry, in this order:

1. **Registry hit is decisive.** If the subscriber already exists in the Installation Fees
   registry → **EXISTING**, regardless of renewals, parent change, FDT change, inactivity,
   Loan-3, or package change.
2. Otherwise use supporting signals to separate NEW from NEEDS_REVIEW:
   `activations_count`, `old_expiration`, `new_expiration`, SaaS `created_at`, prior SaaS
   history, first qualifying paid activation, cancellation state.

**FACT (business-confirmed).** `activations_count` is the **lifetime** number of SaaS
activation events for the user.

**The trap to avoid:** `activations_count = 1` does **not** mean new, and
`activations_count > 1` does **not** mean existing. A brand-new subscriber can legitimately
show `Loan-3 + P-35000` → `activations_count = 2`. Conversely one raw event this month with
`activations_count = 17` clearly indicates prior activity → EXISTING.

**Outputs:** `NEW` · `EXISTING` · `NEEDS_REVIEW`.
`NEEDS_REVIEW` must never auto-generate a financial entitlement.

**DEFERRED — D-01.** The exact threshold logic separating NEW from NEEDS_REVIEW when the
registry has no hit. Not blocking today: rule 1 above (registry hit → EXISTING) is approved
and covers every migrated subscriber. D-01 is needed by Phase 3 and must land as versioned
configuration, not code.

The only decision still blocking work is **D-03**, the definition of "active user"
(`../engineering/risk-and-open-decisions.md` §3).

---

## 6. Agent identity

**FACT.** Agent aliases already work, but only in JSON configuration, not in the database:
`assets/data/raw-import-config.json` holds 11 agents; the first alone has **24 SaaS account
aliases** (`r.saeed.ammar`, `r.saeed.ammar.sub1` … `sub23`). `calculateRawImport` maps each
`parent` to its canonical agent through this table.

**FACT.** The config can be edited centrally (`app_settings.raw_import` via
`save_import_settings`), so adding a subaccount does **not** require a deployment today.

**RECOMMENDATION.** Promote agents and aliases to first-class tables
(`agents`, `agent_aliases`) so that agent identity is referential, not string matching, and
so an alias change is auditable.

---

## 7. Direct company subscribers

**FACT.** Not modelled today. Raw values such as `TTH_Users` / `FTTH_Users` fall into the
`ignoredAccounts` counter when they do not start with `r.` (`index.html:701`) — they are
silently dropped from commissions and never reach Installation Fees.

**RECOMMENDATION.** Normalize both spellings to a canonical `DIRECT_COMPANY` agent that is
**not** automatically eligible for reseller installation fees, but is visible and
correctable — because SaaS attribution is sometimes wrong in both directions.

---

## 8. Source vs effective attribution

**RECOMMENDATION.** Keep three separate fields, never collapsing them:

| Field | Meaning | Mutable |
|---|---|---|
| `source_parent_at_activation` | what SaaS said at the moment of activation | **never** |
| `current_saas_parent` | what SaaS says now | on each sync |
| `effective_agent_id` | who the business says gets paid | by permission, audited |

Changing `effective_agent_id` changes **who receives money**. It requires
`subscriber.correct_agent`, and stores before / after / reason / actor / timestamp.

---

## 9. Transfers

**RECOMMENDATION.** A transfer is an event, never a silent `UPDATE`:
`from_agent`, `to_agent`, `effective_date`, `reason`, `performed_by`, `created_at`.

Historical financial rows keep `agent_id_at_entitlement` and `agent_id_at_payment`.
**A transfer must never rewrite who earned money already paid.**

---

## 10. Holds

**RECOMMENDATION.** First-class, typed, and reversible.

*System:* Missing Invoice · Financial Mismatch · Duplicate · Subscriber Unmatched ·
Already Paid · Invalid Stage
*Manual:* Investigation · Company Decision · Agent Issue · Administrative

A hold **stops future payments and erases nothing**. A subscriber holding paid P1 and P2 who
is held and later released resumes at **P3**. Never restarts.

---

## 11. Corrections

**RECOMMENDATION.** Operational fields (notes, FDT, contact) may be edited with audit.
Financial values may not be silently overwritten — they require an explicit correction
record carrying before / after / reason / actor / timestamp, and after posting they require
a reversal or adjustment rather than an edit.

---

## 12. The monthly operational workflow

**APPROVED** — owner-confirmed 2026-09-04, implemented as **ADR-034**. This section governs
the *operational* workflow. It supersedes the payout-centric assumptions elsewhere in this
document and in DEC-007 **for that workflow only**; the older path still works and its
description above still describes it accurately.

### 12.1 One monthly source

**FACT.** After the one-time historical baseline, the operator uploads **one** file per month:
the SaaS activation/invoice export. `saas_activation_events` remains the single canonical raw
event source, and both the commission engine and the installation engine read from it. There
is no second upload for invoice audit, and no separate entitlement build. No second parser and
no second ingestion path for the same file.

### 12.2 Where a subscriber starts

**APPROVED.**
- In the historical registry → start from the subscriber's **currently committed** stage.
- Not in the registry → the **existing** newness/classification rules decide. There is no
  second NEW/EXISTING classifier. Only a genuinely new and eligible subscriber enters
  Installation Fees automatically, and starts at **P1** under the active scheme version.
- `NEEDS_REVIEW` stays reviewable and **never silently generates money**.

### 12.3 Several events for one subscriber in one month

**APPROVED.** Two valid invoices for the same subscriber in one month are **not** a conflict.
Eligible events are processed chronologically (`event_created_at ASC`, deterministic tie-break
on event id) and **each valid event consumes the subscriber's next stage**.

| Opening | Events | Awarded | Month total | Closing |
|---|---|---|---|---|
| P3 | 1 | P3 | 3,000 | P4 |
| P3 | 2 | P3, P4 | 7,000 | DONE |
| P1 | 4 | P1, P2, P3, P4 | 13,000 | DONE |
| P4 | 2 | P4 only | 4,000 | DONE |
| DONE | any | — | 0 | DONE |

A stage is never awarded twice, in this month or any other: a unique key on
(subscriber, stage) across every approved result enforces it. Nothing goes past `DONE`.

### 12.4 Calculation is not payment

**APPROVED.** Calculating a month is a **preview**. It writes only the run and its lines; it
does not touch `installation_subscribers`, `installation_subscriber_state`,
`installation_enrollments`, or `installation_payment_history`. Re-running it on the same
source rebuilds the lines rather than duplicating them.

Lifecycle: `CALCULATED` → `NEEDS_REVIEW` (if blockers) → `READY_TO_APPROVE` → `APPROVED`.

**"اعتماد نتيجة الشهر" is not a payment.** Approving persists the result, registers eligible
new subscribers, commits each subscriber's resulting stage for the next month, and keeps the
full audit trail. It creates **no** payment row, **no** payment batch, and **no** financial
ledger entry, and marks nothing as paid. Approval is idempotent by request id, and the same
event or the same (subscriber, stage) can never be consumed twice.

Historical paid rows stay historical paid evidence. Post-system calculations live in their own
tables, so the two are semantically distinct and no fake payment is ever inserted to advance a
stage.

### 12.5 Eligibility, holds and grace

**APPROVED.** The monthly calculation reuses the **existing** gate — eligibility, newness,
ownership, holds, package semantics, and the approved grace rule (30 calendar days from the
first recorded SaaS operation to a qualifying paid activation, with the existing audited
override). No duplicate rule engine. A blocked subscriber never receives an installment
silently: **every excluded or review row carries an explicit reason code**.

### 12.6 Reseller identity and the Parent → Print hierarchy

**APPROVED.** Reseller = Print. Identity is a stable id, never display-name equality.
`agents` gains `parent_agent_id` (self-reference, depth-guarded) so a Parent may have Branch/
Print children; `agent_aliases` continues to absorb source-name variants. Agents with no
parent remain valid.

Historical attribution is **preserved as recorded**: the historical file names only the main
Parent, and no old installment is retroactively reassigned to a guessed branch. For new
monthly events, the actual Print/Branch is resolved from the source parent/alias and the
stable id is stored on the calculation evidence. **Stage history belongs to the subscriber,
not the branch** — changing reseller or Print never resets P1/P2/P3/P4. Reporting gives both
the Print/Branch result and the Parent aggregate, derived from the same lines so they
reconcile exactly.

### 12.7 Unknown Print or reseller names

**APPROVED.** An unmapped source parent/Print name **blocks the affected rows from approval**
and appears in a confirmation queue. An admin resolves it as (a) alias of an existing Print,
(b) a new Branch/Print under an existing Parent, (c) a genuinely new independent Parent/Print,
or (d) an existing non-reseller/direct-company classification. The mapping is persisted.
**Financial ownership is never assigned by fuzzy matching.**

### 12.8 What this does not change

Commission formulas: unchanged. Installation stage amounts (P1 3,000 · P2 3,000 · P3 3,000 ·
P4 4,000) and the `Remaining → stage` map: unchanged. Historical rows: not rebuilt, not
redistributed, not reset. The old payout path: not deleted.

### 12.9 Known limit

`installation_subscriber_state` can only store a `Remaining` on the standard ladder. A scheme
version with other amounts computes correctly but cannot be committed; the preview surfaces it
as `SCHEME_NOT_REPRESENTABLE_IN_STORAGE` rather than letting a table constraint fail at
approval. Widening the storage is an open decision, not a silent gap.
