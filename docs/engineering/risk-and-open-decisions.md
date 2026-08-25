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

### R-03 — Reversal path has no frontend · **CLOSED for installation domain, 2026-08-25 (Batch 2)**

**FACT, corrected 2026-08-25 (was "No reversal path exists" — stale since 2026-08-18).**
`protect_settled_installation_entitlement` and `unique (entitlement_id)` correctly prevent
mutation of settled payments. The originally-approved fix **landed as `20260818090000_add_financial_correction_ledger.sql`**, two days after this register closed: `reverse_financial_entry`
and `correct_financial_entry`, writing typed rows to `financial_ledger`
(`txn_type in ('HISTORICAL_PAYMENT','PAYMENT','ADJUSTMENT','CORRECTION','REVERSAL')`,
`reverses_entry_id`/`corrects_entry_id`, never deleting or overwriting the original posted
row) — this register's §4 already documents the resulting behaviour at **S-16**, but this
entry was never updated to match. A later migration
(`20260916090000_corrections_register.sql`) added a read-only aggregation RPC,
`subscriber_corrections`, explicitly to show raw-vs-approved-vs-who-changed-it across all
four correction domains (parent, ownership, FDT, and this one).

**Backend exists?** Yes — `reverse_financial_entry`, `correct_financial_entry`,
`subscriber_corrections`, capability-gated and audited, confirmed present in
`supabase/migrations/`.
**Frontend — installation domain: wired in Batch 2.** A "تصحيح / عكس" action pair on the
entitlements-tab table (`src/features/finance/paymentCorrections.ts`, called from
`src/features/installation/index.ts`), gated on `payment.correct`/`payment.reverse` for
visibility only (the RPCs check `current_app_role() = 'admin'` themselves). The subscriber
case file's history tab now also renders `subscriber_corrections()`'s `financial` rows —
`subscriber_timeline()` never surfaced these, since its `AUDIT` branch joins on
`installation_subscribers.id` while these RPCs log under `entity_type = 'financial_ledger'`.
Regression coverage: `tests/financial-corrections-ui.test.js` (mandatory reason, confirm-
before-execute, fresh `request_id` per click, replay handled as quiet success, server errors
surfaced not swallowed).
**Frontend — commission domain: still open.** `ensure_financial_origin` supports
`p_domain = 'commission'` against `commission_rows`, but no screen lists individual rows by
id — only aggregated scope/zone rollups exist. Out of scope for Batch 2 (would need a new
paginated browse RPC, beyond a minimal-footprint change); candidate for a future batch.

**Impact (residual).** Installation-domain corrections now have a normal in-app action with
disclosure and audit. The commission domain still requires direct database access to reach
these RPCs.

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

### R-11 — `subscriber_identities` bootstrap has no caller · **CLOSED, 2026-08-25 (Batch 2)**

**FACT.** `subscriber_identities` was empty in production because, per the migration's own
comment (`20260825090000_harden_fdt_zone_and_identity_pipeline.sql`), "the tables and pure
functions exist, and no RPC writes to them." `bootstrap_subscriber_identities()` was added
there (refined `20260825120000_fix_identity_bootstrap_aggregate.sql`) to close that.

**Backend exists?** Yes — `bootstrap_subscriber_identities()`, confirmed present.
**Frontend — wired in Batch 2.** `/system/identities` (`src/features/system/identities.ts`,
capability `subscriber.match`): a KPI row over matched/conflict/unmatched counts, a "شغّل
المطابقة الآن" action behind an explicit confirm, and a filterable/paginated browse table.
The run action calls a new capability-gated wrapper, `run_identity_bootstrap(request_id)`
(`supabase/migrations/20261001090000_batch2_identity_operations.sql`), which is the only
caller of the underlying engine function; the browse table reads through a new
`page_subscriber_identities()`. Both are admin-invoked, not automatic — running still
requires an operator to open the screen and confirm, it is not wired into the import
pipeline as a side effect. `action_center()`'s `IDENTITY_CONFLICT` decision now opens this
screen (`?status=CONFLICT`) instead of the generic subscriber list.
Regression coverage: `tests/sql/identity-operations.sql` (capability enforcement, mandatory
`request_id`, idempotent replay, zero side effects on any financial/subscriber table, "bootstrap
≠ new subscriber") and `tests/financial-corrections-ui.test.js` (confirm-before-run, fresh
`request_id` per click, replay handled quietly).

**Impact.** Running the bootstrap is now a normal in-app action instead of a manual RPC call
from the SQL console; every readiness/blocker check that reads `subscriber_identities` for an
`IDENTITY` conflict can be kept populated without direct database access.

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

### D-03 — Definition of "active user" · **OPEN, deferred to Phase 8**

**The intended tier basis is UNIQUE ACTIVE USERS.** That much is approved. What remains
undecided is what makes a user *active*.

Three separate layers, deliberately kept apart — conflating them makes the decision look
harder than it is:

| Layer | Status |
|---|---|
| **Source capability** | The SaaS User Master **does carry active-state evidence**: `enabled`, `expiration`, `parent_name`, `created_at`, and the SaaS user identity. The data exists at source. |
| **Current application limitation** | **FACT.** The commission pipeline neither persists nor uses that evidence. `calculateRawImport` reads only `id`, `profile_name`, `parent` and `lastname`, and stores aggregates. Nothing in the database can answer "was this user active on that date". |
| **Business open decision** | **D-03.** Which combination of those fields authoritatively constitutes ACTIVE. A business rule, and it **must not be invented.** |

**The gap is in the pipeline, not in SaaS.** Phase 2 — raw SaaS storage including user-state
snapshots (`saas-import-matching-contract.md` §3.5) — closes the application limitation and
makes the evidence available and historically queryable. D-03 then decides the formula.

**Blocking scope — explicit.** D-03 blocks **Commission Engine vNext (Phase 8) final tier
calculation** and nothing else. It does **not** block Phases 0–7. Foundational work proceeds
without it: commission scheme V1 records the honest current basis (`activation_events`), and
V2 with `unique_active_users` waits for the answer.

### D-11 — Invoice evidence attachment: storage/security/retention foundation · **OPEN**

**Raised during Installation Operations Batch 1 (2026-08-25), Phase 4.** The task asked for
evidence attachment on `installation_invoices` (file/subscriber/invoice reference, filename,
content type, uploaded_by, uploaded_at) so a reviewer can open the source document from the
invoice review screen before deciding `VERIFIED`/`REJECTED`.

**FACT.** No Supabase Storage bucket, bucket policy, or `storage.objects` reference exists
anywhere in `supabase/migrations/`. `installation_invoices` carries only text metadata
(`external_invoice_id`, `invoice_number`, `invoice_reference`) — fields the table's own
migration comment says are kept deliberately separate "حتى لا يُبنى ربط على افتراض" (so no
linkage is built on an assumption). There is no file/URL column, and no prior architectural
decision about file storage in `docs/DECISIONS.md` or `docs/ARCHITECTURE.md` (both mention
only browser `localStorage`, an unrelated legacy mechanism).

**Why this stayed a STOP, not an implementation.** Building evidence attachment on this gap
means making three decisions with no prior precedent in this codebase, each financial/security
in nature:

1. **Bucket + access policy** — who may upload, who may read raw evidence (same set as
   `invoice.verify`/`invoice.reject`, or broader), public vs. signed-URL access.
2. **Retention** — how long evidence is kept, whether rejected-invoice evidence is retained
   differently from verified-invoice evidence.
3. **Identity of the reference** — a Storage object key, or an external URL (Odoo, SaaS) —
   given `odoo_model`/`odoo_record_id` already exist on the table for a future Odoo-owned
   invoice record.

Per this task's own instruction, an undocumented bucket/security/retention decision halts
Phase 4 only; it does not block Phases 1–3, which shipped independently.

**Needed by:** Phase 4 (Invoice Evidence), next batch. Not currently blocking anything else.

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
