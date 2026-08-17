# Installation Fees — Business Rules

Companion to `reseller-financial-operations-blueprint.md`. Tags: **FACT** / **INFERENCE** /
**RECOMMENDATION** / **OPEN DECISION**.

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

**FACT.** A row is `unresolved` when either:

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

**FACT.** 15 subscribers are `DONE` with no P4 payment recorded. They carry the warning
`historical_payment_detail_incomplete`, remain `resolved`, and **no P4 event is invented**.
If such a row also fails the accounting check, rule §2 governs and it becomes unresolved.

---

## 4. Loan-3 — FINAL

**OPEN DECISION (implementation), rule is FINAL (business).** Loan-3 does not exist anywhere
in the current codebase — `grep` finds no reference. It is a forward requirement.

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

**OPEN DECISION D-01.** The exact threshold logic separating NEW from NEEDS_REVIEW when the
registry has no hit. Must be versioned configuration, not code.

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
