# Risks and Open Decisions

---

## 1. Risks found in the current system

Ordered by exposure.

### R-01 — Commission tier basis is client-supplied · **HIGH**

**FACT.** `publish_commission_month` accepts `tier_basis_qty` from the browser and only
checks that it is not *below* the row's own quantity, then validates the applied tier against
it (`20260815113000` lines 195–256). The basis is never recomputed server-side.

**Impact.** An authenticated admin posting an inflated basis moves an agent from T1 to T3 —
4,000 → 6,000 IQD per P35 activation on the shipped defaults. The database cannot prove a
published month's tier was correct.

**Fix.** Recompute the pooled basis from the payload rows grouped by `tier_group_id` and
reject a mismatch. The data is already present; only the check is missing.

### R-02 — The stage table is defined twice · **MEDIUM**

**FACT.** `STAGE_BY_REMAINING` in JavaScript and `installation_stage_for_remaining` in SQL
encode the same five thresholds independently.

**Impact.** They agree today. Editing one produces confusing constraint violations rather
than a clean failure.

**Fix.** Single published scheme version; the SQL function becomes a lookup.

### R-03 — No reversal path · **MEDIUM-HIGH**

**FACT.** `protect_settled_installation_entitlement` and
`unique (entitlement_id)` correctly prevent mutation of settled payments. No reversal or
adjustment mechanism exists.

**Impact.** A payment to the wrong agent has no legal correction path. The only remedy is a
direct database edit — precisely what the safeguards forbid, which means it would be done
outside audit.

**Fix.** Ledger with `kind = 'reversal'` and `reverses_ledger_id`.

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
match the desired tier rule — but it also means a second activation earns **no commission at
all**. Whether that is correct is **D-02**.

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

## 2. Open decisions — business input required

| # | Decision | Why it cannot be decided from code |
|---|---|---|
| **D-01** | Threshold logic separating NEW from NEEDS_REVIEW when the registry has no hit | No engine exists; `activations_count` alone is explicitly insufficient in both directions |
| **D-02** | Should a subscriber's 2nd/3rd activation in one month earn commission? | Current code silently says no by dropping it. Requirement §24 implies yes. **These conflict.** |
| **D-03** | Formal definition of "active user" for tier population | No `enabled`, `status` or expiry field exists in the current import. Must not be invented |
| **D-04** | Treatment of the 14 financial-mismatch subscribers | They are frozen as unresolved. Someone must decide whether to correct, write off, or investigate |
| **D-05** | Treatment of the 5 blank-Remaining subscribers | Same |
| **D-06** | Do the 15 incomplete-detail DONE subscribers need a back-filled P4 record? | They are accounting-balanced but missing detail |
| **D-07** | Is NEW ZONE tier really per-FDT, or per-FDT-owner? | Code says per-FDT row. Whether that matches intent is unconfirmed |
| **D-08** | Who may reverse a payment, and within what window? | No reversal exists yet |
| **D-09** | Can a closed cycle be reopened, by whom, and what happens to posted payments? | No cycle close exists yet |
| **D-10** | Does Odoo own invoice identity, or does Babil issue and Odoo mirror? | Determines whether `external_invoice_id` is authoritative or a reference |

**D-02 is the one to resolve first.** It is the only place where the written requirement and
the shipped behaviour actively contradict each other, and it changes how much money agents
are owed.

---

## 3. Hard scenarios

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
| S-16 | Incorrect payment | Reversal row, never a delete. `payment.reverse`. Audited. |
| S-17 | Correction after cycle close | Requires reopen (audited) or a correction posted to the next open cycle. **D-09.** |
| S-18 | Reopening a closed cycle | Audited event; snapshot retained; prior batches remain posted. **D-09.** |
| S-19 | Incomplete upload | Batch stays `draft`; nothing derived until confirm. |
| S-20 | Same file, different name | `file_checksum` unique per (domain, period). **R-09** — hook exists, unused. |
| S-21 | Overlapping activation uploads | Raw rows deduplicated by natural key; dispositions make the overlap visible. |
| S-22 | Unknown agent alias | Disposition `unknown_agent_alias`, blocks entitlement, appears in a queue. Today it is an exception only if the parent starts with `r.`; otherwise silently dropped — **R-08.** |
| S-23 | New SaaS subaccount | Add an `agent_aliases` row. No deployment. Audited. |
| S-24 | SaaS vs Odoo invoice conflict | Odoo is the accounting authority; SaaS `transaction_id` is never promoted to an invoice id. Conflict blocks payment and is queued. |
| S-25 | Configuration change mid-cycle | Published versions are immutable; a new version's `effective_from` decides. In-flight entitlements keep their `scheme_version_id`. |
| S-26 | Commission tier changes during an open cycle | Open cycle shows a projected tier; close persists the final snapshot. Closed months already keep their own `tiers` — **FACT**, this part works today. |
| S-27 | One subscriber, several activation events | Counts **once** toward tier population. Commissionable activations counted separately — **D-02.** |
| S-28 | Active-user definition changes | New commission scheme version with its own `effective_from`. Closed snapshots unaffected. |
