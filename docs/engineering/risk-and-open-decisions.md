# Risks and Open Decisions

**Architecture review closed on 2026-08-16.** Nine of the ten open decisions are now
approved business rules and appear in §2. One remains open (**D-03**) and is the only
business input still blocking the commission engine.

---

## 1. Risks found in the current system

Ordered by exposure.

### R-01 — Commission tier basis is client-supplied · **CRITICAL**

**FACT.** `publish_commission_month` accepts `tier_basis_qty` from the browser and only
checks that it is not *below* the row's own quantity, then validates the applied tier against
it (`20260815113000` lines 195–256). The basis is never recomputed server-side.

**Impact.** An authenticated admin posting an inflated basis moves an agent from T1 to T3 —
4,000 → 6,000 IQD per P35 activation on the shipped defaults. The database cannot prove a
published month's tier was correct.

**Approved at review: the client-supplied basis must not remain the financial source of
truth.** The server/database derives or verifies the authoritative basis from trusted
persisted data. The browser may show a projected tier; it may never determine it.

**Fix.** Short term (Phase 0): recompute the pooled basis from the payload rows grouped by
`tier_group_id` and reject a mismatch — the data is already present, only the check is
missing. Long term (Phase 8): derive the basis from persisted subscriber-level data.

### R-02 — The stage table is defined twice · **MEDIUM**

**FACT.** `STAGE_BY_REMAINING` in JavaScript and `installation_stage_for_remaining` in SQL
encode the same five thresholds independently.

**Impact.** They agree today. Editing one produces confusing constraint violations rather
than a clean failure.

**Fix.** Single published scheme version; the SQL function becomes a lookup.

### R-03 — No reversal path · **CRITICAL — foundation, not a later feature**

**FACT.** `protect_settled_installation_entitlement` and
`unique (entitlement_id)` correctly prevent mutation of settled payments. No reversal or
adjustment mechanism exists.

**Impact.** A payment to the wrong agent has no legal correction path. The only remedy is a
direct database edit — precisely what the safeguards forbid, which means it would be done
outside audit.

**Approved at review: promoted to a critical implementation foundation.** The system must
offer a legal, audited correction path. Direct database editing must never be the normal
correction mechanism.

A wrong-agent payment resolves as three ledger rows, all retained:
original payment · reversal · correct replacement payment. The original posted transaction
is never deleted or overwritten.

**Fix.** Ledger with transaction types and `reverses_ledger_id`. **Sequencing rule: this
must land before payment workflows are expanded, not after.**

### R-04 — Raw activation data is never stored · **MEDIUM**

**FACT.** `calculateRawImport` runs in the browser; only aggregates persist.

**Impact.** Nothing is re-derivable. A matching improvement cannot be applied retroactively.
Rows dropped as `ignoredAccounts` or `duplicateIds` leave no trace. Cross-month subscriber
identity is impossible.

**Fix.** `raw_saas_activation_events`, append-only.

### R-05 — Repeat activations are silently dropped · **MEDIUM**

**FACT.** `seenIds` drops any row whose `id` was already seen in the same file
(`index.html:697`), counting it as `duplicateIds`.

**Impact.** This makes the tier basis unique-per-subscriber *by accident*, which happens to
match the approved tier-population rule — but it also means a second activation earns **no
commission at all**, which **contradicts approved decision D-02**.

**Status: formally incompatible legacy behaviour.** Must be replaced in Commission Engine
vNext (Phase 8) with event-level deduplication keyed on activation identity, never on the
subscriber.

### R-06 — Permission model cannot express the requirement · **MEDIUM**

**FACT.** Four roles × six booleans, hardcoded in JS and constrained in SQL. No per-user
grant, no scope.

**Impact.** "Let this one accountant correct agent attribution" is unachievable without
granting full admin.

### R-07 — No hold model · **MEDIUM**

**Impact.** Pausing a subscriber requires editing or deleting financial state — exactly what
must not happen.

### R-08 — Direct-company subscribers vanish silently · **LOW-MEDIUM**

**FACT.** A `parent` not starting with `r.` increments `ignoredAccounts` and is dropped.

**Impact.** A reseller subscriber wrongly labelled `FTTH_Users` in SaaS disappears with no
exception raised. Nobody is told.

### R-09 — `file_checksum` is accepted but never sent · **LOW**

**FACT.** `import_installation_history` takes `p_file_checksum`; the browser passes `null`.

**Impact.** The same file under a different name is not detected by content.

### R-10 — Line-ending churn in `index.html` · **LOW (process)**

**FACT.** The file is stored with mixed endings (498 CRLF, 1,445 LF). Editing tools rewrite
all lines, turning a 139-line change into 3,035 and making review impossible. This occurred
three times during recent releases.

**Fix.** Normalize once via `.gitattributes`, or keep the pre-commit check comparing
`git diff --numstat` against `--ignore-cr-at-eol`.

---

## 2. Approved decisions

Resolved at architecture review, 2026-08-16. These are business rules now, not questions.

### D-02 — Repeated activations · **APPROVED**

> A subscriber counts **once** toward tier population. The same subscriber **may** earn
> commission on **multiple distinct qualifying activation events** in the same cycle.

Two separate measures, never conflated:

| Measure | Counts | Deduplicated by |
|---|---|---|
| **Tier population** | `COUNT(DISTINCT active subscriber identity)` | subscriber |
| **Commissionable activations** | every distinct qualifying activation event | **event identity** |

Worked example — subscriber A with activation events X and Y:
tier contribution **1**, commissionable activations **2**. If event X arrives twice through a
duplicate import, X counts **once** — that is import deduplication, not business
deduplication.

**Consequence for the current code.** `seenIds` (`index.html:697`) drops the second
activation of a subscriber within a file, so event Y earns nothing. This is now formally
**incompatible legacy behaviour** and must be replaced in Commission Engine vNext. It is
recorded as **R-05**.

**Event identity.** Deduplication must key on a stable *activation* identity — SaaS
activation id, or `transaction_id`, or the safest composite the export supports
(`saas_user_id + activated_at + profile_name`). It must never key on the subscriber.

### D-04 — 14 financial-mismatch subscribers · **APPROVED**

Remain **unresolved** and **blocked**. No automatic entitlement, no automatic payment.
Clearing one requires an audited correction.

### D-05 — 5 subscribers with blank Remaining · **APPROVED**

Remain **unresolved** and **blocked**. `Remaining` and stage are **never** inferred or
guessed.

### D-06 — 15 balanced subscribers with incomplete P4 detail · **APPROVED**

Remain **financially resolved** on the accepted historical balance. Missing P4 payment
details and dates are **never synthesised**. The flag
`historical_payment_detail_incomplete` is retained so the gap stays visible to audit.

### D-08 / D-09 — Reversal authority and cycle reopening · **APPROVED**

See §4 of `../product/financial-state-machine.md`. A closed cycle with no posted or paid
transactions may be reopened by an authorised capability with reason, actor, timestamp and
audit event. A closed cycle containing posted or paid transactions is **immutable**;
change happens through correction, adjustment or reversal.

### D-01, D-07, D-10 — deferred, not blocking

Still unanswered but they block nothing in phases 0–5:

| # | Decision | Needed by |
|---|---|---|
| D-01 | NEW vs NEEDS_REVIEW threshold when the registry has no hit | Phase 3 |
| D-07 | Is NEW ZONE tier per-FDT or per-FDT-owner? | Phase 8 |
| D-10 | Does Odoo own invoice identity, or mirror Babil's? | Phase 10 |

---

## 3. The one decision still open

### D-03 — Definition of "active user" · **OPEN**

**The intended tier basis is UNIQUE ACTIVE USERS.** That much is approved. What remains
undecided is what makes a user *active*.

**FACT.** The current import carries no such field. There is no `enabled`, no account state,
no expiry in the columns `calculateRawImport` reads. The formula cannot be derived from this
repository.

Potential evidence once raw SaaS storage exists (Phase 2): `enabled`, `expiration` /
`new_expiration`, service or account state.

**This must not be invented.** Until it is confirmed, commission scheme V1 records the honest
current basis (`activation_events`) and V2 waits. Phase 8 is blocked on this and on nothing
else.

---

## 4. Hard scenarios

For each: **source of truth · what is mutable · who may change it · what blocks payment ·
what is audited · what stays immutable.**

| # | Scenario | Handling |
|---|---|---|
| S-01 | Agent transfer | Transfer event. `agent_id_at_payment` on past rows never changes. `subscriber.transfer`. Blocks nothing. Audited. |
| S-02 | FDT change | Operational edit with history. `subscriber.change_fdt`. Does not block. Audited. |
| S-03 | Wrong SaaS parent | `source_parent_at_activation` immutable; `effective_agent_id` corrected. `subscriber.correct_agent`. Audited. |
| S-04 | Reseller marked Direct Company | Same as S-03 — correction, not a re-import. |
| S-05 | Direct Company assigned to a reseller | Same mechanism, opposite direction. Blocks payment until resolved. |
| S-06 | Duplicate activation | Raw rows both stored; one qualifying event per stage. Disposition `duplicate_in_file` or `duplicate_across_period`, both reviewable. |
| S-07 | Same invoice linked twice | `unique (external_invoice_id, invoice_source)`. Blocks payment. |
| S-08 | Subscriber across multiple months | Registry hit → EXISTING. No second "new installation". |
| S-09 | Long-inactive subscriber returns | Registry hit → EXISTING regardless of gap. |
| S-10 | Username/ID change | Match on `saas_user_id` first; alias/merge event, audited. Never a new subscriber. |
| S-11 | Cancelled activation | Stored raw with cancellation state; non-qualifying. Blocks entitlement. |
| S-12 | Loan-3 before paid package | Loan-3 stored, counts in lifetime `activations_count`, creates no entitlement. Entitlement begins at the qualifying package. |
| S-13 | Partial payment | Ledger holds each posting; stage closes only when fully paid. |
| S-14 | Payment then hold | Payments stand; future stages blocked. Release resumes at the next stage. |
| S-15 | Whole-agent hold | Hold at agent scope blocks all its subscribers' payments; erases nothing. |
| S-16 | Incorrect payment | **APPROVED (R-03):** original `PAYMENT` + `REVERSAL` + replacement `PAYMENT`, all three retained. Never a delete or an edit. `payment.reverse`. Audited. |
| S-17 | Correction after cycle close | **APPROVED (D-09):** if the cycle has no posted/paid money, reopen with capability + reason + actor + timestamp + audit. If it has, the money is immutable — use Correction / Adjustment / Reversal. |
| S-18 | Reopening a closed cycle | **APPROVED (D-09):** allowed only for a cycle with no posted or paid transactions. Snapshot retained; the reopen is itself an audit event. |
| S-19 | Incomplete upload | Batch stays `draft`; nothing derived until confirm. |
| S-20 | Same file, different name | `file_checksum` unique per (domain, period). **R-09** — hook exists, unused. |
| S-21 | Overlapping activation uploads | Raw rows deduplicated by natural key; dispositions make the overlap visible. |
| S-22 | Unknown agent alias | Disposition `unknown_agent_alias`, blocks entitlement, appears in a queue. Today it is an exception only if the parent starts with `r.`; otherwise silently dropped — **R-08.** |
| S-23 | New SaaS subaccount | Add an `agent_aliases` row. No deployment. Audited. |
| S-24 | SaaS vs Odoo invoice conflict | Odoo is the accounting authority; SaaS `transaction_id` is never promoted to an invoice id. Conflict blocks payment and is queued. |
| S-25 | Configuration change mid-cycle | Published versions are immutable; a new version's `effective_from` decides. In-flight entitlements keep their `scheme_version_id`. |
| S-26 | Commission tier changes during an open cycle | Open cycle shows a projected tier; close persists the final snapshot. Closed months already keep their own `tiers` — **FACT**, this part works today. |
| S-27 | One subscriber, several activation events | **APPROVED (D-02):** counts **once** toward tier population; **each qualifying event is commissionable**. Deduplicate on activation identity, never on the subscriber. |
| S-28 | Active-user definition changes | New commission scheme version with its own `effective_from`. Closed snapshots unaffected. |
