# Babil Commission App — Master Requirements Audit

**Type:** Read-Only Requirements-to-Evidence Audit
**Reconciled against:** [`docs/MASTER_REQUIREMENTS_REGISTER.md`](./MASTER_REQUIREMENTS_REGISTER.md) (canonical, 2026-08-28, 161 requirement IDs)
**Audited HEAD:** commit `65a90f4` (register commit) on top of `2be654e` ("PR-B3: financial correctness and LIVE issue closure (#92)")
**Branch:** `docs/master-requirements-register`
**Method:** four independent, non-overlapping evidence-gathering passes (one per requirement cluster) plus one deep-dive re-verification of the Commission cluster, each required to cite file:line for every claim and to use only the register's fixed status vocabulary. No file was edited, no migration was run, no Supabase project was touched, no payment was executed, no cycle was recalculated. This document and `docs/MASTER_REQUIREMENTS_REGISTER.md` are the only two files this task is allowed to add besides the coverage test.

Per the register's own Anti-forgetting contract (§12): *"Implemented" requires evidence; similar feature names do not count* and *"Deferred" requires explicit user approval; AI may not defer on its own.* No status below was accepted from the register's own draft column without independent evidence; every deviation from the register's draft status is called out explicitly in §7.

---

## 1. Executive Verdict

**Not V1 Stable.** The financial core — payments, cycle lifecycle, holds, historical exceptions, ownership dating, commission event-level dedup — is genuinely strong, evidenced by real DB constraints and passing tests, not merely present-looking code. But three separate, evidence-confirmed problems block closure, and none of them is cosmetic:

1. **A live, deliberate regression in zone/FDT determination.** The Aug-25 fix that made OLD/NEW zone a real settings-driven decision (`fdts.zone`, admin UI, `UNKNOWN_FDT` review queue) was reverted six weeks later (Oct-11, merged as part of PR-B3 #92) back to a bare hardcoded `fdt_code between 94 and 119` SQL literal — and the safety net for unregistered cabinets was removed at the same time, so an unknown cabinet today silently prices as payable `AGENT`/`old` scope with no review, no exception, no visibility. This is the exact opposite of what `docs/MASTER_REQUIREMENTS_REGISTER.md`'s own "Replaced approaches" section (line 229) says already happened, and it was shipped with no entry in `docs/DECISIONS.md` or `CHANGELOG.md`, contrary to the project's own governance rule in `AGENTS.md`.
2. **Bulk Invoice Audit does not exist.** What exists is a single-row manual approval gate (`review_invoice`) layered on top of an externally supplied "Remaining balance" file that drives stage progression by itself. There is no upload → parse → preview → bulk-match → apply workflow (INV-001..004), and the specific acceptance scenario the task asked to prove architecturally — subscriber at P3, two distinct qualifying invoices in one month → P3=3,000 then P4=4,000, total 7,000 — has no mechanism to occur from invoices at all (INV-007..009). One documented anti-duplication safeguard (`docs/engineering/risk-and-open-decisions.md` S-07) is cited as existing but does not exist in the schema (INV-013).
3. **Free P1 (FREE-001..006) has zero implementation anywhere** — no table, RPC, capability, UI string, or test. It is not partially built or stubbed; it is entirely absent, confirmed by exhaustive search, and its own threshold ("350") does not occur anywhere as a business value.

Beyond these three, two business decisions the code has quietly already answered (active-user definition, NEW ZONE tier grouping) were never formally ratified — the register itself, the newest document in the repo, still lists both as open, and this audit agrees with the register: a working implementation is not the same thing as a recorded business decision.

**Counts** (161 requirement IDs total; sum of all statuses below equals 161):

| Status | Count |
|---|---|
| PASS | 93 |
| PARTIAL | 16 |
| MISSING | 29 |
| VERIFY | 11 |
| DECISION REQUIRED | 7 |
| REPLACED | 0 |
| CANCELLED BY AGREEMENT | 0 |
| OUT OF SCOPE — OPERATIONS | 5 |
| **Total** | **161** |

**Safety confirmations for this task:** no financial Production data was modified; no payment was executed; no July recalculation was executed; no Production financial test data was created; nothing in this branch has been merged.

---

## 2. Requirements Coverage

Legend for evidence columns: file:line citations from this audit's four research passes. "—" means no such evidence exists (a genuine absence, not an oversight). Full source list is in §8 and in the underlying agent transcripts.

### Configuration / no-hardcoding (CFG) — 10 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| CFG-001 | No changeable business rule hardcoded | MISSING | `supabase/migrations/20261011090000_effective_ownership_and_fdt_scope.sql:29-45` (94–119 literal); `20261005090000_batch4_rule_engine.sql:277,329` (+30-day grace, hardcoded twice) | same files, no settings table backs either value | none | `tests/sql/commission-vnext.sql:159,293,362-406` locks the literal in as expected behavior | The audit-required hardcodes are current and live, not historical |
| CFG-002 | OLD/NEW zone managed from settings/master data | MISSING | `src/features/master/fdts.ts:282-366` (`fdts.zone` editable) | `fdts` table exists but `commission_qualifying_events` (`20261011090000...sql:90-91`) ignores `f.zone`, carries it for display only | `/master/fdts/:code` classify panel functions but is financially decorative | none asserts `fdts.zone` drives scope (because it doesn't) | Mechanism exists, disconnected from money |
| CFG-003 | Add future FDTs without code/migration | PARTIAL | `register_fdt`/`register_fdt_bulk`, `20260826090000_add_fdt_onboarding_workflow.sql:85-176` | `fdts` insert, no deploy needed | `/master/fdts/:code` | — | Row can be added freely, but has zero effect on commission scope — only the numeric code (94–119 or not) matters |
| CFG-004 | Range or explicit-list assignment, classify OLD/NEW | PARTIAL | `register_fdt_bulk` (explicit list, ≤500 rows), `20260826090000...sql:175-273`; legacy client `cabinetRanges` object in `index.html` inline script (range-based, exercised by `tests/new-zone-fdt-agents.test.js:55`) | no range construct server-side | disconnected legacy path only for ranges | `tests/new-zone-fdt-agents.test.js` (legacy only) | Explicit-list exists server-side; range-based exists only in a disconnected legacy client script |
| CFG-005 | FDT associated with reseller/owner/scope | PARTIAL | `fdts.agent_id` FK; `register_fdt`/`register_fdt_bulk` accept `p_agent_id` | `20260819090000_add_data_intelligence_foundation.sql:82` | `fdtDetail` agent picker, `src/features/master/fdts.ts:298-300,324-328` | — | Stored and displayed, but not load-bearing for the live `scope_id` resolved via `fdt_commission_scope` |
| CFG-006 | Mutable rates/tiers/thresholds versioned as settings | PASS | `create_commission_draft`/`update_commission_draft_tier`/`update_commission_draft_rate`/`publish_commission_version`, `20260821090000_add_commission_scheme_engine.sql:279-356`, `20260921090000_commission_scheme_workspace.sql:93-326` | `commission_schemes`/`commission_scheme_versions`/`commission_tier_definitions`/`commission_package_rates`, effective-dated, DRAFT/PUBLISHED/RETIRED | `src/features/master/commission-schemes.ts` | `tests/sql/commission-vnext.sql` | Genuinely versioned master data |
| CFG-007 | Free-P1 threshold 350 as settings if mutable | MISSING | none found | none found | none found | none found | Not a hardcode-vs-config question — Free P1 is not implemented at all (see FREE-*) |
| CFG-008 | Mutable grace periods/thresholds as settings | MISSING | `grace_status_from_dates`/`installation_grace_status`, `20261005090000_batch4_rule_engine.sql:277,329` — `+30` days literal, duplicated | no settings table | `override_grace_expired_review` allows manual per-case override only, not window config | — | Only the *outcome* is overridable (capability-gated, reasoned, audited); the window itself is a literal |
| CFG-009 | Effective dates for material rule changes | PARTIAL | `calculate_commission_cycle` selects version by `effective_from`, `20261011090000...sql:165-176`; `subscriber_ownership_at(event_created_at)` same file | `commission_scheme_versions.effective_from/to` | — | — | Rates and ownership are effective-dated; `fdt_commission_scope()` is `immutable` SQL with a bare literal — zero effective-dating on the single most consequential rule |
| CFG-010 | Material config changes: capability/actor/timestamp/reason/audit | PARTIAL | `publish_commission_version`, `register_fdt` — capability+actor+timestamp+audit present; reason (`p_notes`) enforced only client-side (`src/features/master/fdts.ts:338-342`), not server-side | `audit_logs` inserts confirmed | — | — | RPC-level config changes follow the pattern well; the 94–119 change itself bypassed this path entirely (shipped as a migration, not a runtime config change) |

### Users / permissions (USR) — 8 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| USR-001 | Admin creates accounts in-app | PASS | `src/features/system/users.ts:136-210` | Edge Function `admin-users` (service-role) | `/system/users` | none dedicated | — |
| USR-002 | Admin manages role/status/password in-app | PASS | `users.ts:325-446` | `rpc('update_user_profile')`, `edge('admin-users',{action:'update'})` | `/system/users/:id` | none dedicated | — |
| USR-003 | Accountant pays, cannot freely edit master financial data | PASS | `correctionActionsCell` gates on `payment.correct`/`payment.reverse`, `src/features/finance/paymentCorrections.ts:39-40` | accountant capability grant explicitly excludes correction/reversal, `20260820090000_add_dynamic_permissions.sql:164-170` | — | none dedicated | Comment in the grant itself: "recording payment does not grant the power to void it" |
| USR-004 | Monitor/viewer read-only unless granted | PASS | all mutating panels gate on `can(...)` | `20260820090000...sql:155-162` grants view-only capabilities | — | — | — |
| USR-005 | Profiles/roles server-managed | PASS | `user_effective_permissions()`/`permission_catalogue()`, both `SECURITY DEFINER` | `20260911090000_users_and_permissions.sql:21-185` | — | — | No client-side role logic found |
| USR-006 | Last active admin protected | PASS | `permission_administrators_remaining()` + `guard_permission_lockout()` trigger | `20260820090000...sql:337-369` | `users.ts:263-264,337-339` pre-warns before server rejects | — | — |
| USR-007 | Session persists/refreshes correctly | VERIFY | not deeply traced in this pass (session wiring in `src/services/api.ts`) | — | — | none located | Kept VERIFY, no evidence found either way |
| USR-008 | Protected routes wait for capability readiness | PASS | `src/app/router.ts:178-193`, `src/services/api.ts:18-19,128,143-144`, `src/main.ts:80-85` | — | — | `tests/live08-capability-gate.test.js` | This is LIVE-08 |

### NEW / EXISTING classification (CLS) — 12 IDs

All trace through `classify_newness()`, `supabase/migrations/20261005090000_batch4_rule_engine.sql:34-135` (final version; supersedes `20260904090000_server_side_classification.sql`), guard chain evaluated top to bottom: registry hit → identity conflict → lifetime-exceeds-observed → zero-qualifying-event → identity-unresolved (Batch 4 fix) → complete+matching → else NEEDS_REVIEW.

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| CLS-001 | Authoritative classification is server-side | PASS | batch4:38,55 `SECURITY DEFINER`, capability-gated | `20260904090000...sql:127-128` grant to `authenticated` only | `refresh_subscriber_classifications` persists to `subscriber_classifications` | production run: 27,857 rows classified server-side, 0 NEW (correctly, source was UNKNOWN at the time) | `docs/engineering/productization-api-gap.md` is stale on this point (fixed the day after it was written) |
| CLS-002 | Registry hit ⇒ EXISTING | PASS | batch4:61-63,112-113 | — | — | `tests/sql/batch4-rule-engine.sql:71-91` | — |
| CLS-003 | UNMATCHED never silently becomes NEW | PASS | batch4:122-125 (the actual Batch 4 fix) | constraint added batch4:25-32 | — | `tests/sql/batch4-rule-engine.sql:105-130` | — |
| CLS-004 | CONFLICT/NEEDS_REVIEW remain unresolved | PASS | batch4:114-115 | — | `/system/identities` explicit human resolution, capability `subscriber.match` | — | No automatic promotion path found |
| CLS-005 | activations_count alone never determines NEW | PASS | guard 3 (line 116) only ever pushes EXISTING; guard 6 (126-128) requires conjunction | — | — | `tests/sql/batch4-rule-engine.sql:172-189` | — |
| CLS-006 | Incomplete/unknown source cannot authorize NEW | PASS | batch4:72-76,126 | whitelist, no catch-all `COMPLETE` | — | `tests/sql/batch4-rule-engine.sql:130-158` | — |
| CLS-007 | Loan alone does not create entitlement/P1 | PASS | `Loan-3` seeded `DEBT_SERVICE`, excluded from `v_qualifying`; `20260820180000_wire_installation_workflow.sql:48-53` blocks `DEBT_SERVICE_NEVER_QUALIFIES` | `20260819090000...sql:480` | — | `tests/sql/batch4-rule-engine.sql:203-217` | — |
| CLS-008 | NEW requires resolved identity + no history + qualifying event + complete source | PASS | guard 6, batch4:126-128, only reachable after guards 1-5 | — | — | `tests/sql/batch4-rule-engine.sql:158-172` | — |
| CLS-009 | Newness and activation eligibility are separate questions | PASS | `classify_newness()` vs `installation_grace_status()`/`installation_reference_dates()`, batch4:236-341 | — | — | — | Documented explicitly in `docs/engineering/risk-and-open-decisions.md:320-337` |
| CLS-010 | Identity bootstrap/matching capability-gated and explicit | PASS | `run_identity_bootstrap`, `20261001090000_batch2_identity_operations.sql:22-65`, capability `subscriber.match` | not auto-run on import, `20261003090000...sql:19-20` | explicit confirm-gated UI action | `tests/sql/identity-operations.sql` | — |
| CLS-011 | Cross-username identity merge policy | DECISION REQUIRED | no code found (`grep -ri "merge"` — no cross-username-merge hits) | `subscriber_identities` is strictly 1:1 | — | — | Register's own `DEC-006`; documented as an acknowledged unsolved gap in `docs/engineering/risk-and-open-decisions.md:438-447` |
| CLS-012 | Identity correction must not rewrite posted history | PARTIAL | financial postings protected (`protect_settled_installation_entitlement`) | `refresh_subscriber_classifications` does `INSERT...ON CONFLICT...DO UPDATE` with **no audit_logs insert and no version/history column** | — | none asserting classification-row immutability | Money is protected; the classification record that justifies it is silently mutable and unaudited |

### Commission (COM) — 15 IDs

Engine: `calculate_commission_cycle`, `supabase/migrations/20261011090000_effective_ownership_and_fdt_scope.sql:125-432`. Key constraint: `commission_event_entitlements_identity unique (cycle_id, activation_event_id)` — `20260821120000_add_commission_calculation.sql:96` (event-scoped, never subscriber-scoped). `seenIds` (`index.html:1150-1177`) is the legacy pre-vNext browser dedup path — excluded from evidence per audit instructions, cited only as superseded.

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| COM-001 | Commission/installation domains financially separate | PASS | no cross-domain FKs found | separate table sets | separate feature modules | separate test suites | `docs/DECISIONS.md` ADR-020:146-158 |
| COM-002 | Final commission calculation is server-authoritative | PARTIAL | `calculate_commission_cycle` is server-authoritative for vNext; **but** legacy `publish_commission_month` (`20260815113000_add_commission_source_breakdown.sql:59`) still accepts a client-supplied `tier_basis_qty`, only bounds-checked, never derived | `commission_event_entitlements` has no client-supplied-basis column, `tests/sql/commission-vnext.sql:318-322` | UI trigger for the legacy RPC is neutered (`index.html:2483-2487`, toast only, no call) | `tests/commission-tier-trust-boundary.test.js` pins the legacy RPC as an unfixed, tracked limitation | **The legacy RPC's `EXECUTE` grant to `authenticated` was never revoked** — UI-unreachable but still directly callable via the Supabase API |
| COM-003 | Tier population counts subscriber once | PASS | `count(distinct b.subscriber_key)` — `20261011090000...sql:339` | `commission_cycle_snapshots_basis_is_sane` CHECK | `src/features/commissions/index.ts:32-33,537` | `tests/sql/commission-vnext.sql:219-224` | — |
| COM-004 | Same subscriber, multiple distinct qualifying activations, same cycle | PASS | `count(distinct b.saas_event_id)` — same file:340; one entitlement row per event | — | `index.ts:538` | `tests/sql/commission-vnext.sql:226-235` | — |
| COM-005 | Duplicate same activation event counts once | PASS | two independent constraints (raw + entitlement level) | `saas_activation_events_identity_key`, `commission_event_entitlements_identity` | — | `tests/sql/commission-vnext.sql:307-316` | — |
| COM-006 | Dedup uses activation/event identity, never subscriber identity | PASS | exact constraint confirmed event-scoped only | `20260821120000...sql:96`; `subscriber_key` only in a non-unique index | — | — | — |
| COM-007 | Raw SaaS events retained/re-derivable | PASS | `protect_raw_saas_history()` trigger raises on any update/delete | `20260819090000...sql:211-429`, `authenticated` granted SELECT only | — | — | Docs call the table `raw_saas_activation_events`; shipped name is `saas_activation_events` — naming drift, not a functional gap |
| COM-008 | Unexpected/direct-company rows must not silently vanish | PARTIAL | `UNKNOWN_AGENT` fix for old-zone/AGENT scope, `20260824090000_fix_commission_exception_classification.sql:121-135` | scoped to `t.scope_type='AGENT'` only, `20261011090000...sql:296` | — | — | No equivalent safety net for zone=new (FDT scope); a genuinely-known direct-company exclusion is correctly silent (by design), but the as-built doc's "surfaces as exception" claim is stale |
| COM-009 | Define UNIQUE ACTIVE USER for tier basis | DECISION REQUIRED | shipped, tested definition exists (`tier_basis='UNIQUE_ACTIVATED_SUBSCRIBERS'`) | `20260821090000...sql:80` | — | `tests/sql/commission-vnext.sql` | `docs/engineering/commission-engine-vnext-as-built.md` calls this "resolved," but no ADR exists and `docs/engineering/risk-and-open-decisions.md` (even at its latest commit, five days after vNext shipped) still lists D-03 as OPEN; the register (newest doc) agrees with the risk log, not the as-built doc |
| COM-010 | Active-user definition uses trusted persisted source evidence | PASS | `commission_qualifying_events` reads only persisted, trigger-protected tables | `20261011090000...sql:54-116` | — | — | PASS on mechanism, independent of COM-009's decision status |
| COM-011 | Mutable active-user formula belongs in config/effective dates | PASS | `tier_basis` versioned column, immutable once published | `20260821090000...sql:78-80,200` | — | — | — |
| COM-012 | Define NEW ZONE tier grouping | DECISION REQUIRED | pooling-mode is config (`old_zone_scope`/`new_zone_scope`); **which FDTs count as "new zone" at all is the same hardcoded 94–119 literal from ZON-001** | `20261011090000...sql:29-48` | — | — | Stronger than "undecided" — a **regression** against the register's own "Replaced approaches" line 229; mandatory acceptance case #1 (register line 262) is explicitly unmet |
| COM-013 | Tier grouping must be configuration-driven | PARTIAL | pooling-granularity is config-driven; the layer that actually assigns zone is not | `fdt_commission_scope()` literal | — | — | Same root cause as CFG-001/002/ZON-002 |
| COM-014 | Mutable commission rates/tier boundaries server-managed/versioned | PASS | `protect_published_commission_children()` blocks any mutation once published | `20260821090000...sql:118-230` | — | `tests/sql/commission-vnext.sql:301-304` | — |
| COM-015 | Historical calculations retain scheme/rule version used | PASS | `scheme_version_id` not-null FK on both snapshot and entitlement tables, populated at insert | `20260821120000...sql:87,120,144-161`; `20261011090000...sql:352,360-366` | — | — | — |

### Zone / FDT (ZON) — 7 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| ZON-001 | Zone not permanently inferred from hardcoded 94–119 | MISSING | `public.fdt_commission_scope()`, `20261011090000...sql:29-45`, `p_fdt_code::bigint between 94 and 119` | live, sole, current mechanism as of HEAD | — | `tests/sql/commission-vnext.sql:293` locks the literal in | **Register's own draft status ("REPLACED CURRENT TEMP LOGIC") is confirmed wrong.** The Aug-25 fix that did replace this with `fdts.zone` (`20260825090000_harden_fdt_zone_and_identity_pipeline.sql`) was itself reverted six weeks later by the very migration this audits |
| ZON-002 | Settings define OLD/NEW per cabinet/FDT | MISSING | `fdts.zone` mechanism exists, disconnected from money (see CFG-002) | — | `/master/fdts/:code` | — | — |
| ZON-003 | Future FDTs added without deployment | MISSING | adding a row needs no deploy but has no effect on scope | — | — | — | An unregistered cabinet needs **no admin action at all** to be treated as agent-scope — automatic and silent |
| ZON-004 | Range-based and/or explicit-cabinet assignment | PARTIAL | explicit-list server-side (`register_fdt_bulk`); range-based only in disconnected legacy `index.html` `cabinetRanges` | — | — | `tests/new-zone-fdt-agents.test.js:55` | Neither is what the calc engine actually uses |
| ZON-005 | Same configured scope used consistently by import/calculation/dashboard/payment | VERIFY | vNext internally consistent (`commission_qualifying_events` reused by KPI/corrections, `20261014090000...sql:62,69,79`) | — | legacy `/legacy` route still reachable, computes zone independently via `cabinetRanges` | `tests/new-zone-fdt-agents.test.js` | Confirmed split into ≥2 non-communicating systems; severity depends on whether `/legacy` raw-import preview is still operationally used |
| ZON-006 | Unknown/unconfigured cabinet fails safe to REVIEW, never silently OLD | MISSING | prior `UNKNOWN_FDT` exception (`20260825090000...sql:44-48,275-287`) removed by `20261011090000...sql:39-45,91`; comment at line 306-307 states this explicitly ("لا UNKNOWN_FDT بعد اليوم") | — | — | `tests/sql/commission-vnext.sql:389,401,406` lock in the removal as correct | **Confirmed regression**, deliberate and tested |
| ZON-007 | Zone config changes audited/effective-dated if money-affected | MISSING | `register_fdt` runtime path is audited but not load-bearing; the actual money-determining change (94–119) has no runtime audit trail, no `effective_from`, and no entry in `docs/DECISIONS.md`/`CHANGELOG.md` | — | — | — | Conflicts with `AGENTS.md`'s own governance rule to log new business/technical decisions |

### Installation fees (INS) — 11 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| INS-001 | 13000 → P1 → 3,000 IQD | PASS | `installation_stage_for_remaining`/`installation_amount_for_stage`, `20260815160000_add_installation_fees.sql:16-45`; JS duplicate `assets/js/installation-fees.js:17-23` | CHECKs at lines 109-112 | — | `tests/installation-fees-calculation.test.js:28-31`, `tests/sql/installation-fees-rules.sql` | Hardcoded twice, independently (SQL + JS) — flagged in §3 |
| INS-002 | 10000 → P2 → 3,000 IQD | PASS | same as INS-001 | same as INS-001 | — | same as INS-001 | Hardcoded twice, independently (SQL + JS) — flagged in §3 |
| INS-003 | 7000 → P3 → 3,000 IQD | PASS | same as INS-001 | same as INS-001 | — | same as INS-001 | Hardcoded twice, independently (SQL + JS) — flagged in §3 |
| INS-004 | 4000 → P4 → 4,000 IQD | PASS | same as INS-001 | same as INS-001 | — | same as INS-001 | Hardcoded twice, independently (SQL + JS) — flagged in §3 |
| INS-005 | 0 → DONE → 0 | PASS | same functions | `installation_entitlements_done_is_unpayable` CHECK | — | — | — |
| INS-006 | Blank/unknown Remaining never guessed | PASS | returns NULL for unmapped values, import rejects | `installation_state_unknown_remaining_has_no_stage` CHECK, `20260816090000...sql:123-125` | — | — | DB-CHECK-level guarantee |
| INS-007 | Independent financial domain | PASS | `financial_ledger_domain_check in ('commission','installation')` | — | — | — | — |
| INS-008 | Settled entitlement cannot be silently edited/deleted | PASS | `protect_settled_installation_entitlement` trigger | `20260815160000...sql:152-178`; `installation_payments_entitlement_key unique(entitlement_id)` | — | — | — |
| INS-009 | Dashboard totals reconcile | VERIFY | `installation_financials()`, `20260822120000_add_reporting_layer.sql:109-186` | — | — | `tests/installation-dashboard-source.test.js` pins one previously-shipped merge bug (fixed) | Entitlements table and enrollments/stage-distribution table are separate, not cross-checked figures — can diverge given `installation_enrollments.current_stage_code` is never updated post-enrollment (see architecture note under INV) |
| INS-010 | Entitlement rules server-authoritative | PASS | all mutating RPCs derive stage/amount server-side | `guard_installation_payment` trigger, `20260820180000...sql:297-343`, closes direct-table-write bypass | — | — | Two independent server-side gates |
| INS-011 | Correction/reversal exists without mutating original | PASS | `reverse_financial_entry`/`correct_financial_entry` | `20260818090000_add_financial_correction_ledger.sql:287-499` | `src/features/installation/index.ts` wires `paymentCorrections.ts` | — | Closed per `docs/engineering/risk-and-open-decisions.md:41-75` (R-03) |

### Invoice audit (INV) — 19 IDs

**Architecture:** stage progression is driven entirely by an externally supplied "Remaining balance" figure, re-derived through the hardcoded lookup above — never by counting or processing invoices. An "invoice" in this codebase is a single-row human approval gate (`review_invoice`) on a stage number the system already has, not a driver of stage progression.

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| INV-001 | Upload complete invoice file | MISSING | no file-upload path for invoices anywhere (contrast: Holds has a real one, `holds.ts:236-352`) | — | — | — | — |
| INV-002 | Parse file, preview before apply | MISSING | `src/features/installation/invoices.ts` is a queue viewer + per-row drawer, not a file preview | — | — | — | — |
| INV-003 | Bulk-match invoice rows to subscribers | MISSING | `review_invoice` requires caller-supplied subscriber_id/stage_code; no bulk matcher exists | — | — | — | — |
| INV-004 | Preview separates matched/unknown/duplicate/already-used/invalid/conflict | MISSING | `page_invoice_review` is a post-hoc status queue, not a pre-apply preview | `20260910090000_invoice_review.sql:34-104` | — | — | — |
| INV-005 | No installation payment without qualifying invoice | PARTIAL | `record_installation_payment` blocks unless `invoice_status='approved'`; `materialize_installation_entitlements` requires VERIFIED invoice | `20260815160000...sql:514-517`; `20260913090000_materialize_and_batch.sql:63-67` | — | `tests/sql/installation-fees-rules.sql:107-129` | Gate is real and DB-enforced, but gates on a human-typed status, not a verified bulk source |
| INV-006 | Subscriber absent from qualifying invoice file remains unpaid | PARTIAL | no "invoice file" concept to be absent from; correct outcome as a side-effect of nothing happening, not a designed rule | — | — | — | — |
| INV-007 | Subscriber can have >1 distinct qualifying invoice same month | MISSING | no constraint blocks it, but no mechanism drives it either — stage comes from Remaining re-import, not invoice count | `installation_entitlements_identity_key unique(period, subscriber_id, stage)` doesn't block it | `review_invoice` can only review the *current* stage | `tests/sql/installation-fees-import.sql:168-174` tests different-period only | — |
| INV-008 | Each distinct qualifying invoice advances exactly one sequential stage | MISSING | no invoice-count-driven advancement mechanism exists | — | — | — | — |
| INV-009 | P3 + two invoices same month ⇒ P3=3,000 then P4=4,000, total 7,000 | MISSING | architecturally not provable — no invoice-driven stage engine exists to run this scenario through | — | — | none | The exact acceptance case the task asked to test does not exist as a mechanism |
| INV-010 | No subscriber+month one-payment constraint | PASS | confirmed no `(subscriber_id, month)`/`(subscriber_id, period)` uniqueness exists anywhere | identity key is `(period, subscriber_id, stage)` only | — | — | Nothing over-restrictive blocks the required scenario; the mechanism to *create* the second stage is what's missing (INV-007/008/009) |
| INV-011 | Cannot advance past P4/DONE | PASS | `record_installation_payment` raises on `stage='DONE'` | `installation_entitlements_done_is_unpayable` CHECK | — | `tests/sql/installation-fees-rules.sql:131-142` | — |
| INV-012 | Same stage cannot be paid twice | PASS | `paid_amount>0`/`payment_status='paid'` guard | `installation_payments_entitlement_key unique(entitlement_id)` | — | `tests/sql/installation-fees-rules.sql:170-186`, `tests/sql/payout-end-to-end.sql:200-218` | — |
| INV-013 | Same invoice cannot be re-used/re-imported | MISSING | `external_invoice_id` column exists but is **never written by any code path** | `installation_invoices` has **no unique constraint** on `(subscriber_id, stage_code)`; unique index exists only on `odoo_invoice_id` | — | — | **`docs/engineering/risk-and-open-decisions.md:593` (S-07) claims a `unique(external_invoice_id, invoice_source)` constraint exists — it does not; the documentation is factually wrong** |
| INV-014 | Audit lineage invoice→subscriber→stage→amount→decision/payment | PARTIAL | lineage reconstructable via free-text `audit_logs.extra` | purpose-built FK `installation_payment_batch_items.invoice_id` is **declared but never populated** (`20260913090000...sql:179-182` omits it) | — | — | Schema anticipated direct lineage, then didn't wire it |
| INV-015 | Decide invoice identity authority (Odoo/external/Babil) | DECISION REQUIRED | "Odoo optional/read-only, never a condition" is answered (`20260823090000...sql:1-16,140-162`) | — | — | — | "Who owns invoice identity" (D-10) remains explicitly OPEN in `risk-and-open-decisions.md:225,301-302` |
| INV-016 | Invoice identity stable across reupload | MISSING | no reupload mechanism exists to test | — | — | — | Untestable until INV-001/013 exist |
| INV-017 | Evidence attachment/access with explicit security model | DECISION REQUIRED | no Supabase Storage bucket, policy, or `storage.objects` reference anywhere (`grep` across all migrations: zero hits) | — | — | — | First-party documented gap (D-11, `risk-and-open-decisions.md:254-284`), independently reproduced |
| INV-018 | Decide upload/read capabilities, private/signed access, retention | DECISION REQUIRED | same D-11 entry | — | — | — | — |
| INV-019 | Bulk invoice import separate from evidence attachment | VERIFY | moot today — neither INV-001 nor INV-017 exist yet | — | — | — | Forward-looking guardrail; nothing to violate yet |

### Holds (HLD) — 8 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| HLD-001 | Upload Excel/CSV of blocked IDs | PASS | `src/features/installation/holds.ts:236-330` | `installation_hold_uploads`, `20260906090000_installation_holds.sql:89-108` | upload UI | `tests/sql/installation-holds.sql:158-181` | — |
| HLD-002 | Preview before apply | PASS | `preview_bulk_hold`, `stable`, `20260906090000...sql:147-221` | zero rows created by preview | apply disabled until preview runs, `holds.ts:277,346` | `tests/sql/installation-holds.sql:75-104`, `tests/holds-and-payout.test.js:64-74` | Provably read-only |
| HLD-003 | Valid/unknown/already-held/already-done/already-paid/duplicates separated | PASS | bucketing CTE, `20260906090000...sql:158-213` | — | — | `tests/sql/installation-holds.sql:75-98` | All six categories individually tested |
| HLD-004 | Only valid IDs applied | PASS | `apply_bulk_hold` server-side filter, `20260906090000...sql:291-303` | partial unique index `installation_holds_active_key` | — | `tests/sql/installation-holds.sql:163-176` | — |
| HLD-005 | Held subscriber cannot be paid | PASS | `installation_entitlement_eligibility` `ON_HOLD` blocker | `20260906090000...sql:567-581`; payout-candidate gate `20260907090000...sql:166-170,231-265` | — | — | Two independent enforcement points |
| HLD-006 | Bulk source/file name retained | PASS | `installation_hold_uploads.filename` NOT NULL + non-blank CHECK | `20260906090000...sql:91,107` | rendered in UI, `holds.ts:78-82` | `tests/sql/installation-holds.sql:178-181` | — |
| HLD-007 | Release requires permission/reason/request ID/audit | PASS | `release_hold_v2(p_hold_id,p_reason,p_request_id)`, `20260906090000...sql:347-403`, capability `installation.release_hold` | CHECK `installation_holds_released_is_attributed` | — | `tests/installation-hold-release.test.js` (15 cases) | — |
| HLD-008 | Holds never delete historical financial records | PASS | no FK cascade to payment/ledger tables | — | — | `tests/holds-and-payout.test.js:49-60`; live before/after SQL, `installation-holds.sql:272-302` | — |

### Payments / corrections (PAY) — 12 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| PAY-001 | Central payment only via secure server RPC | PASS | `post_commission_batch`, `record_installation_payment`/`record_commission_payment`, all `SECURITY DEFINER`, `authenticated`-only | `20260822090000_add_commission_vnext_payout.sql:219-344`; `financial-write-boundary.sql:190-224` | — | — | — |
| PAY-002 | Atomic | PASS | row-locks batch + each item `for update`, one transaction | `20260822090000...sql:251-252,271-276` | — | — | — |
| PAY-003 | Idempotent via request ID | PASS | mandatory `p_request_id`, replay short-circuits | `20260822090000...sql:239-249` | — | — | Same pattern in `reverse_financial_entry`/`correct_financial_entry` |
| PAY-004 | Overpayment rejected | PASS | `commission_scope_payable()` blocks `amount>remaining` | `20260822090000...sql:280-289`, `AMOUNT_EXCEEDS_REMAINING` | — | — | Same guard in installation domain |
| PAY-005 | Concurrency/conflicts guarded | PASS | `pg_advisory_xact_lock` keyed by batch/entity or `financial-correction:{domain}:{id}` | `20260822090000...sql:243-244`; `20260818090000...sql:327-329,428-430` | — | `tests/sql/financial-correction-concurrency.sh` | Two racing sessions, exactly one wins |
| PAY-006 | Audit created in trusted path | PASS | every payment/correction RPC inserts `audit_logs` in the same transaction | `20260822090000...sql:334-339`; `20260818090000...sql:363-372,486-495` | — | — | Never from client code |
| PAY-007 | Posted/paid records immutable | PASS | `protect_financial_ledger()` trigger raises on delete/most updates | `20260818090000...sql:166-201` | — | — | Only `status→superseded` permitted |
| PAY-008 | Post-payment changes use correction/reversal | PASS | `reverse_financial_entry`/`correct_financial_entry` never touch the original row | `20260818090000...sql:287-499` | — | — | Insert new rows referencing original via `reverses_entry_id`/`corrects_entry_id` |
| PAY-009 | Installation correction/reversal UI exists | PASS | `correctionActionsCell`/`correctionBox`/`wireCorrectionActions` wired | — | `src/features/installation/index.ts:15,252,316-317` | — | Real, reachable screen |
| PAY-010 | Commission correction/reversal available from normal UI | MISSING | server capability exists (`correct_financial_entry`/`reverse_financial_entry` handle `p_domain='commission'`, `20260818090000...sql:252-272`) | — | `correctionActionsCell` is called **only** with `'installation'` — repo-wide grep found exactly one call site | — | `src/features/commissions/corrections.ts` is a different feature (edits which events feed an open cycle), not a posted-payment correction UI |
| PAY-011 | Correction/reversal requires reason/actor/authorization/audit | PASS | admin-only, mandatory `p_reason`/`p_request_id`, writes `audit_logs` | `20260818090000...sql:308-316,409-417` | client also enforces non-blank reason, `paymentCorrections.ts:116` | — | — |
| PAY-012 | Legacy payment path cannot conflict with new engine | PASS | `recordCentralPayment` stub performs no network call, toast only (confirmed: no `fetch`/`rpc` in current `index.html`) | `guard_commission_payment_authority()` trigger raises `42501` on any write to `commission_rows.paid` for a vNext-governed month, `20260822090000...sql:353-381` | pay button replaced with link to `#/finance/payment-batches` | none dedicated to the trigger itself | `publish_commission_month`'s grant was never revoked and `/legacy` route has no capability gate — structurally blocked by the trigger on any month that matters, but not by revocation |

### Cycles / recalculation (CYC) — 8 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| CYC-001 | Master-data changes do not silently recalculate | PASS | `flag_cycles_needs_recalculation_for_parent()` (explicit flag, not silent rewrite) | `20261012090000_recalculation_lifecycle.sql:17-22` | cycle overview warning banner | — | This is LIVE-03 |
| CYC-002 | needs_recalculation state/reason visible | PASS | `needs_recalculation`/`recalculation_reason`/`recalculation_flagged_at/_by` columns | same file | banner | — | — |
| CYC-003 | Recalculation explicit/authorized/audited | PASS | `recalculate_cycle_after_master_change()`, capability-gated, separate explicit action | `20261012090000...sql:190` | — | — | — |
| CYC-004 | No July recalc/financial mutation during verification | PASS | this audit performed zero writes, ran no migrations | — | — | — | Process rule, confirmed by this session's own read-only tool history |
| CYC-005 | Closed cycle, no posted/paid, may reopen with authority+reason+audit | PASS | `reopen_commission_cycle`, capability `commission.reopen`, non-blank reason, `request_id`, blocks if posted amount ≠ 0 | `20260821150000_add_cycle_close_reopen.sql:244-300` | `src/features/commissions/index.ts:1100` | — | — |
| CYC-006 | Closed cycle with posted/paid is immutable | PASS | same posted-money guard + `financial_ledger` immutability | — | — | — | — |
| CYC-007 | Calculated DRAFT needs explicit cancel/recovery lifecycle | PASS | `cancel_empty_commission_cycle`, pure rule functions `canCancelDraft()`/`cancelDraftError()`/`cancelDraftSuccess()` | `supabase/migrations/20260929090000_current_cycle_and_draft_lifecycle.sql` | `src/features/commissions/cancelDraft.ts` | `tests/sql/current-cycle-and-draft-lifecycle.sql` | **Register's own draft status (MISSING) is confirmed wrong.** Feature shipped in commit `fe6f374` (#82), already merged well before HEAD. This is register drift in the opposite direction — a gap the register lists as open that is actually closed |
| CYC-008 | State transitions server-enforced | PASS | multiple `raise exception ... errcode='42501'` guards; all status columns written only inside `SECURITY DEFINER` functions | — | — | — | — |

### Ownership (OWN) — 5 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| OWN-001 | Ownership is effective-dated | PASS | `subscriber_ownership` with non-overlap `EXCLUDE` constraint on `tstzrange` | `20260830080000_add_subscriber_ownership.sql:42-74` | — | — | — |
| OWN-002 | Historical attribution uses owner at event time | PASS | `subscriber_ownership_at(username_key, at)`; LIVE-01 fix wires `event_created_at` | `20261011090000...sql:108,250` | — | — | — |
| OWN-003 | Current ownership change does not rewrite old money | VERIFY | mechanics strongly imply this (OWN-001/002), but protection is inherited from CYC-006's posted-money guard, not ownership-specific | — | — | — | No contradicting evidence found either |
| OWN-004 | Installation P1-P4 history does not auto-transfer | VERIFY | no explicit trigger/rule located pinning stage history to ownership-at-payment vs current owner | — | — | — | No contrary evidence found; not traced end-to-end |
| OWN-005 | FDT/reseller assignment follows config/effective-date/audit policy | PASS | transfer UI requires `p_effective_from`, non-blank `p_reason`, `p_request_id` | — | `src/features/ownership/transfer.ts:53,143,177,190-193` | — | — |

### Imports (IMP) — 8 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| IMP-001 | Duplicate same event/file cannot duplicate financial result | VERIFY | checksum dedup (IMP-005) + request-id idempotency (PAY-003) exist | — | — | — | Not verified end-to-end across all three import domains in this pass |
| IMP-002 | Source completeness explicit; incomplete cannot authorize NEW | PASS | see CLS-006 | — | — | — | — |
| IMP-003 | Bad SaaS import batch has safe cancel/void lifecycle | MISSING | grep for `cancel*import*`/`void*import*`/`cancel_import`/`void_batch` across all migrations: zero matches | — | — | — | No RPC exists |
| IMP-004 | Cancellation never deletes posted history | PASS | all import/event FKs `on delete restrict` | `20260819090000...sql:161,213,271,349` | — | — | Structural, not an explicit "cancel" rule |
| IMP-005 | File checksum/content identity in duplicate-file detection | PASS | `source_checksum unique(source_checksum, source_kind)`, non-blank check | `20260819090000...sql:148-149`; installation: `file_checksum` tracked, `20260815160000...sql:51,210,271-272` | — | — | — |
| IMP-006 | Financially important raw source events retained/reproducible | PASS | same `on delete restrict` FKs | — | — | — | — |
| IMP-007 | Unknown/unmatched rows become visible exceptions | PASS | `subscriber_identities.identity_status` enum (`MATCHED/UNMATCHED/CONFLICT/NEEDS_REVIEW`) | `20260819090000...sql:276,291,351` | — | — | Typed states, not silently dropped |
| IMP-008 | Import preview read-only; apply separate explicit action | PASS | `src/features/system/import-run.ts` — preview populates client object, RPC only fires from separate confirm action | — | — | — | — |

### Free P1 (FREE) — 6 IDs

Exhaustive search across `src/`, `supabase/migrations/`, `assets/`, `docs/decisions` for "free"/"مجاني"/"إعفاء"/"freeP1"/"free_p1" and for the literal `350` as a business value: **zero matches anywhere.** Every `350`-looking hit is a substring of the unrelated Postgres error code `23505`.

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| FREE-001 | NEW ZONE: one free P1 per qualifying FDT over threshold | MISSING | none | none | none | none | — |
| FREE-002 | OLD ZONE: one free P1/subscription per reseller over threshold | MISSING | none | none | none | none | — |
| FREE-003 | Threshold 350 configurable if mutable | MISSING | literal `350` never occurs as a business value anywhere in the codebase | none | none | none | — |
| FREE-004 | Active-customer definition explicit/server-authoritative | DECISION REQUIRED | not implemented; would additionally inherit the unresolved COM-009 "active user" question if built | — | — | — | Blocked on an undecided definition even before implementation could start |
| FREE-005 | Free-P1 grant audited, no duplication per period | MISSING | no grant mechanism exists to audit | — | — | — | — |
| FREE-006 | Historical grants retain rule version | MISSING | no grants exist to version | — | — | — | Free P1 has **zero decision-log presence** anywhere, unlike every other DECISION REQUIRED item in this audit |

### Historical exceptions (HIST) — 5 IDs

Baseline facts (14/5/15) measured against the frozen 2026-08-15 production baseline, per `docs/engineering/historical-migration-and-cutover.md:81-95`.

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| HIST-001 | 14 mismatch subscribers remain blocked; no auto-payment | PASS | mismatch computed server-side | CHECKs `installation_state_mismatch_is_unresolved`/`_unresolved_is_never_eligible`, `20260816090000...sql:128-136` | — | `tests/sql/installation-history-eligibility.sql:69-85` | — |
| HIST-002 | Clearing mismatch requires audited correction | PASS | only write path is admin-gated, audited, idempotent `import_installation_history` | `installation_subscriber_state` is SELECT-only for `authenticated` | — | `tests/sql/installation-history-rules.sql:246-266` | On principle, not a scoped tool: no single-record correction exists — clearing means re-running a whole batch import |
| HIST-003 | 5 blank Remaining unresolved/blocked; no inference | PASS | — | CHECK `installation_state_unknown_remaining_has_no_stage`, `20260816090000...sql:123-125` | — | `tests/sql/installation-history-rules.sql:78-82` | — |
| HIST-004 | 15 balanced subscribers, incomplete P4 detail, resolved on accepted balance | PASS | `v_incomplete` computed independently of `v_resolution` | `20260816090000...sql:338,342-345` | — | `tests/sql/installation-history-eligibility.sql:106-110` | — |
| HIST-005 | Missing historical P4 detail/date never fabricated | PASS | import loop skips empty/zero amount cells | `installation_history_amount_check (amount>0)` | — | `installation-history-rules.sql:95-98`, `installation-history-eligibility.sql:110` | — |

### Archive / reports (ARC) — 6 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| ARC-001 | Archive KPI and detail reconcile from same server dataset | MISSING | `src/features/reports/index.ts` has no reconciliation logic tied to LIVE-04 | a migration/test pair (`20261013090000_fix_manual_exception_page_total.sql`, `tests/sql/pr-b3-manual-exception-page-total.sql`) is *named* LIVE-04 but the PR-B3 merge commit `2be654e` states explicitly it is unrelated to LIVE-04 and that the real archive KPI/detail mismatch remains open | — | — | **Confirmed still OPEN — a stale-filename trap for anyone auditing by name alone** |
| ARC-002 | Archive/import does not auto-publish merely because data matches | PASS | no auto-publish-on-match logic found | publishing always via explicit capability-gated RPC | — | — | — |
| ARC-003 | Historical visibility comes from central truth | PASS | consistent with OWN/IMP evidence | — | — | — | — |
| ARC-004 | Authoritative KPI never calculated from current paginated UI slice only | PASS | `page_manual_exceptions`/`page_activation_corrections`/`page_users`/`page_audit_logs` compute totals from full filtered set before limit/offset | pattern fixed and documented in `20261013090000...sql:33-45` | — | — | Established pattern, referenced explicitly in that migration's own comment |
| ARC-005 | Export/report totals reconcile with source ledger/payment/entitlement | VERIFY | not independently traced end-to-end | — | — | — | Consistent with register, not contradicted |
| ARC-006 | Audit "why" reason visible | PASS | `/audit` route reads `page_audit_logs`, shows actor/action/before-after | — | `src/features/audit/index.ts:39-60` | — | — |

### Security / recovery (SEC) — 9 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| SEC-001 | RLS protects central data | VERIFY | `enable row level security` occurs 27 times vs 55+ `create table` statements (rough proxy only) | `docs/SUPABASE_AUDIT_2026-08-04.md` covered 6 tables; schema has since grown to 55+, no later equivalent audit exists | — | — | Recommend a live `pg_tables`/`pg_policies` cross-check before declaring stable |
| SEC-002 | Sensitive financial writes use guarded server RPCs | PASS | every financial RPC sampled uses `security definer`+`set search_path=''`+`require_capability`+`request_id`+`audit_logs` | consistent pattern across 20260821/20260826/20261005/20261011 migrations | — | — | — |
| SEC-003 | Security Advisor findings closed or explicitly accepted | MISSING | only artifact is `docs/SUPABASE_AUDIT_2026-08-04.md` (manual, 6-table schema); no current-schema equivalent exists | — | — | — | Inventory-only per task scope; not remediated here |
| SEC-004 | Functions callable by anon reviewed/revoked | PARTIAL | `grep "to anon"` across all migrations: **zero** `grant ... to anon` statements found; every RPC revokes from anon | code looks clean | — | — | No formal inventory/sign-off document exists despite clean code |
| SEC-005 | SECURITY DEFINER least-privilege/search_path/auth review | VERIFY | every sampled function sets `search_path=''` and fully qualifies objects | — | — | — | No full `pg_proc` sweep performed (out of scope for a repo-only read) |
| SEC-006 | Leaked-password protection reviewed/enabled | MISSING | no mention anywhere in `docs/` | dashboard-level Auth setting, not visible in migrations | — | — | — |
| SEC-007 | Backup/recovery strategy matches current Supabase plan | PARTIAL | manual/scripted logical export before every monthly import/payment migration, `npm run inspect:backup`/`reconcile:backup` | `docs/release/babil-flow-v1.0-operations.md:157-173` — Free Plan, PITR unavailable; `docs/RISK_REGISTER.md:19` (R-015) rates this "confirmed/critical, partially mitigated" | — | — | Real but partial: no scheduled/automated backup or PITR; plan upgrade explicitly listed as a post-launch item |
| SEC-008 | Migration rebuild/test gates mandatory | PASS | `localdb:up/rebuild/test/down`, `guard:project-ref`/`guard:staging-ref` scripts | `package.json:11-14`, `scripts/assert-project-ref.mjs` | — | — | — |
| SEC-009 | Production verification stays read-only unless explicitly approved | PASS | `AGENTS.md:23` requires server-side verification/audit for any financial op; staging guarded separately from production | `scripts/assert-staging-project-ref.mjs` | — | — | This audit itself complied |

### UX — 7 IDs

| ID | Requirement | Status | Code Evidence | DB Evidence | UI Evidence | Test Evidence | Notes |
|---|---|---|---|---|---|---|---|
| UX-001 | Arabic RTL financial app | PASS | `index.html:3` `lang="ar" dir="rtl"` | — | Arabic copy throughout `src/features/*` | — | — |
| UX-002 | Exceptions/blockers visible, never silently omitted | PASS | consistent with IMP-007/CLS evidence | — | — | — | No counter-evidence found |
| UX-003 | Bulk financial workflows use Preview→Apply | PASS | confirmed via IMP-008 (imports) and Holds workflow | — | — | — | No counter-evidence for financial bulk workflows specifically |
| UX-004 | Normal supported financial corrections do not require DB console | PARTIAL | every *supported* correction path has a real screen/RPC (installation, commission-activation, cycle reopen/cancel, permission overrides) | — | — | — | The one real gap is PAY-010 — commission-payment correction has no UI, so it would require a DB-console-adjacent workaround today |
| UX-005 | Auth/connection errors fail closed, not false empty data | PASS | `workspaceMode` fixed to not stay `'loading'`; 404 distinguished from real network failure | — | — | `tests/live09-connection-status.test.js` | This is LIVE-09 |
| UX-006 | Final mobile usability/touch-target review before stable | VERIFY | spot-check of `assets/css/babil-flow.css` found control `min-height` values of 28/34/36/38/52px, several below the common 44px guideline | — | — | none | No dedicated mobile-usability pass exists; needs actual manual/device review |
| UX-007 | Settings UI exposes mutable business config safely | MISSING | full 56-route list extracted from `src/app/router.ts`/feature `index.ts` files contains no `/settings` pattern; nav groups contain no "الإعدادات" item | — | closest are `/master/*` screens editing specific tables, not a general settings surface | — | — |

### Explicitly out of scope (OPS) — 5 IDs

Per the register's own governance rule, requirements explicitly labeled `OUT OF SCOPE — OPERATIONS` in the register are self-classifying and were not re-derived from code; this audit only confirms the register itself carries this label for all five.

| ID | Requirement | Status |
|---|---|---|
| OPS-001 | Full CRM lead/opportunity inside Babil Commission | OUT OF SCOPE — OPERATIONS |
| OPS-002 | Full installation ticket/task scheduling for field teams | OUT OF SCOPE — OPERATIONS |
| OPS-003 | Field employee shift/task dispatch | OUT OF SCOPE — OPERATIONS |
| OPS-004 | Rebuilding Taskati/Odoo operational workflows | OUT OF SCOPE — OPERATIONS |
| OPS-005 | Broad operational case management unrelated to financial correctness | OUT OF SCOPE — OPERATIONS |

### Totals

**Total Requirement IDs: 161.**

| Status | Count |
|---|---|
| PASS | 93 |
| PARTIAL | 16 |
| MISSING | 29 |
| VERIFY | 11 |
| DECISION REQUIRED | 7 |
| REPLACED | 0 |
| CANCELLED BY AGREEMENT | 0 |
| OUT OF SCOPE — OPERATIONS | 5 |
| **Sum** | **161** |

---

## 3. Hardcoded Business Rules Register

| Rule | Location | Current Value | Mutable? | Settings Exists? | Financial Impact | Required Action |
|---|---|---|---|---|---|---|
| FDT commission scope (agent vs cabinet) | `supabase/migrations/20261011090000_effective_ownership_and_fdt_scope.sql:29-45` | `fdt_code between 94 and 119` → FDT, else AGENT | Yes — a business-owned boundary, not physics | `public.fdts.zone` exists but is **not read** by this function — dead for this purpose | **High** — misclassifies which tier-population bucket and rate table every event on that cabinet uses, every cycle | Route `fdt_commission_scope()` through `fdts.zone` (already built, already admin-editable) instead of the literal; restore the `UNKNOWN_FDT` review path |
| Unregistered/out-of-range cabinet fallback | same function, lines 39-44; `commission_qualifying_events` line 91 | Falls through to `AGENT`/`old`, no exception raised | N/A (behavior) | No — `UNKNOWN_FDT` mechanism was removed | **High** — a genuinely new cabinet is silently priced with no visibility, no review queue entry | Reintroduce a fail-safe `UNCONFIGURED`/review state for any cabinet not present in `fdts` |
| NEW ZONE tier-grouping boundary (which FDTs pool together) | same 94–119 literal, feeds `commission_qualifying_events`/`calculate_commission_cycle` | as above | Yes | `old_zone_scope`/`new_zone_scope` on `commission_scheme_versions` exist but are **dead/decorative** — written and displayed, never read by `commission_tier_for_subscribers`/`commission_rate_for` | **High** — same root cause as the two rows above | Wire the existing versioned columns into the calculation path, or remove them to stop misleading operators |
| Installation grace period | `supabase/migrations/20261005090000_batch4_rule_engine.sql:277,329` | `+30` days, duplicated in two functions | Yes (operational SLA) | None | Medium — mistimes `GRACE_EXPIRED_REVIEW` entry; gates the installation P1 path, not direct money | Move to a settings row; only the *override outcome*, not the window, is currently configurable |
| Installation stage/amount table | `supabase/migrations/20260815160000_add_installation_fees.sql:16-45` (SQL) **and** `assets/js/installation-fees.js:17-23` (JS) | 13000→P1/3000, 10000→P2/3000, 7000→P3/3000, 4000→P4/4000 | Register marks INS-001..005 PASS as-is (these specific numbers are treated as a stable business fact) | An unused `installation_scheme_versions`/fee-schemes engine already exists with the same values seeded (`20260820120000_add_installation_scheme_engine.sql:313-336`) | Low today (values match), but the table is defined **twice, independently** — already tracked by the project's own risk log as R-02 | Point both the SQL function and the JS mirror at the existing scheme-engine table instead of two independent literals |
| Free-P1 threshold 350 | not found anywhere in code | — | Undetermined — feature not built | None | Blocked — cannot assess mutability of something that doesn't exist | Build FREE-001..006 only after DEC-004/business sign-off; do not invent a number |

---

## 4. Proven Gaps (evidence-based only)

1. **Zone/FDT determination is regressed, not merely unconfigured.** A real, audited, settings-driven fix (Aug-25) was reverted to a hardcoded 94–119 literal six weeks later, and the unregistered-cabinet safety net was removed at the same time (ZON-001, ZON-002, ZON-003, ZON-006, CFG-001, CFG-002, COM-012, COM-013).
2. **Bulk Invoice Audit workflow does not exist.** No upload/parse/preview/bulk-match/apply path; the specific multi-invoice-same-month acceptance case has no mechanism to occur (INV-001..004, INV-007..009).
3. **A documented anti-duplication safeguard for invoices does not actually exist in the schema** — `docs/engineering/risk-and-open-decisions.md` (S-07) is factually wrong on this point (INV-013).
4. **A purpose-built lineage FK (`installation_payment_batch_items.invoice_id`) is declared but never populated**, breaking the intended invoice→payment join (INV-014).
5. **Free P1 has zero implementation** — not stubbed, not partial, confirmed by exhaustive search, with no decision-log presence at all (FREE-001, 002, 003, 005, 006).
6. **Commission-payment correction has no UI** despite the server-side RPC already handling `p_domain='commission'` (PAY-010, UX-004).
7. **A legacy RPC with a client-supplied financial input (`publish_commission_month`) is UI-disabled but not access-revoked** — still directly callable via the Supabase API by any authenticated admin (COM-002, PAY-012).
8. **No safe cancel/void lifecycle exists for a bad SaaS import batch** (IMP-003).
9. **LIVE-04 (archive KPI vs detail reconciliation) remains open**, and a same-named migration/test pair that is *not* the real fix creates a stale-filename trap for future auditors (ARC-001).
10. **`subscriber_classifications` rows can be silently overwritten with no audit trail** on a re-run of `refresh_subscriber_classifications`, even though the financial postings that depend on them are protected (CLS-012).
11. **Two independent, disconnected zone-determination systems remain live**: the Postgres `fdt_commission_scope()` literal and a legacy client-side `cabinetRanges` object still loaded via `index.html`'s inline script and exercised by tests — a third system (`fdts.zone`) is built but unused (ZON-004, ZON-005).
12. **Security Advisor findings have no current-schema inventory** — the only artifact (`docs/SUPABASE_AUDIT_2026-08-04.md`) covers 6 tables against a schema that has since grown to 55+ (SEC-001, SEC-003, SEC-004, SEC-005, SEC-006).
13. **No scheduled/automated backup or PITR** — current protection is a manual, scripted logical export, which is real and followed but not equivalent to a managed backup strategy (SEC-007).
14. **Installation stage/amount table is hardcoded independently in two places (SQL and JS)** despite an existing, unused, versioned scheme-engine table with the same seeded values (§3, R-02).
15. **New-zone (FDT-scope) events have no equivalent `UNKNOWN_AGENT`-style safety net** that old-zone (agent-scope) events received in the Aug-24 fix (COM-008).

---

## 5. Business Decisions Required (do not invent answers)

| ID | Decision | Current state |
|---|---|---|
| CLS-011 / DEC-006 | Cross-username identity merge policy | No mechanism exists; `subscriber_identities` is strictly 1:1; documented as an acknowledged, deliberately-unsolved gap |
| COM-009 / DEC-001 | UNIQUE ACTIVE USER formula for tier basis | A specific, tested, shipped definition exists (`UNIQUE_ACTIVATED_SUBSCRIBERS`), asserted "resolved" by an engineering as-built doc — but never promoted to an ADR, and the project's own newest canonical document (the register) still marks it open |
| COM-012 / DEC-002 | NEW ZONE tier grouping — per FDT / per FDT-owner / other | Pooling-mode is configurable; the deeper question of which FDTs count as "new zone" at all was answered by reintroducing the hardcoded 94–119 boundary the register explicitly says was replaced |
| FREE-004 | Active-customer definition for Free P1 | Not implemented; would additionally require resolving COM-009 first |
| INV-015 / DEC-003 | Invoice identity authority (Odoo/external/Babil) | Partially answered ("Odoo is optional, never a condition"); "who owns invoice identity" remains explicitly open |
| INV-017/018 / DEC-004 | Invoice evidence storage/access/retention | No Storage bucket or policy exists anywhere; fully open |
| — / DEC-005 | Bad-import cancellation semantics | No RPC exists (IMP-003); semantics not yet decided |

---

## 6. Replaced / Superseded Logic

- **94–119 FDT zone boundary — NOT a legitimate "replaced" case.** The register's own "Replaced approaches" section (line 229) claims *"permanent numeric 94–119 NEW-ZONE rule → configurable FDT/zone settings."* The evidence shows the opposite direction happened last: a genuine settings-driven replacement shipped 2026-08-25 (`20260825090000_harden_fdt_zone_and_identity_pipeline.sql`), and was itself reverted back to the hardcoded literal by `20261011090000_effective_ownership_and_fdt_scope.sql` (merged as PR-B3 #92, after the Aug-25 fix). This is a **regression that happened after the "replaced" claim was true**, not a stale claim about something never done. See §7 for the direct conflict with ZON-001's draft status.
- **Legacy `publish_commission_month` / central month workflow** — superseded in the UI by commission cycles (vNext), toast-only stub remains, but the RPC itself (with its client-supplied `tier_basis_qty`) is still granted to `authenticated` and unrevoked (COM-002, PAY-012).
- **Legacy `seenIds` browser-side event dedup** (`index.html:1150-1177`) — superseded by `commission_event_entitlements_identity unique(cycle_id, activation_event_id)`; excluded from evidence per the task's explicit instruction, cited only as historical context.
- **`commission_scheme_versions.old_zone_scope`/`new_zone_scope`** — not superseded by a newer mechanism, but confirmed **dead configuration**: written, versioned, displayed in the scheme UI as if authoritative, never read by the calculation engine.
- **Legacy client-side `cabinetRanges`** in `index.html`'s inline script — the register's "Replaced approaches" (localStorage financial truth → Supabase central truth) implies this should be fully retired; it is still loaded in production per `vite.config.ts`'s `copyLegacyAssets`/`verifyBundle` plugins and `docs/engineering/index-html-exit-plan.md`'s Phase G (still pending, "Legacy month workflow" intentionally kept at 11%). Not a bug — a documented, intentional migration bridge — but the register's completion claim should be reconciled against this rather than assumed done.

---

## 7. Requirement Conflicts (Master Register vs. current docs/code)

| Conflict | Register says | Evidence says | Resolution per policy |
|---|---|---|---|
| ZON-001 | `REPLACED CURRENT TEMP LOGIC` | The hardcoded 94–119 logic is the **current, live** mechanism, not something already replaced | Logged here, not auto-edited in the register, per the Source of Truth Policy — status recorded above as **MISSING** |
| CYC-007 | `MISSING` | `cancel_empty_commission_cycle` is fully implemented, tested, and shipped (commit `fe6f374`, #82) | Logged here; status recorded above as **PASS** — register drift in the *opposite* direction from most findings |
| COM-009 (and the underlying D-03) | Register: `DECISION REQUIRED — CURRENT SCOPE` (newest doc, 2026-08-28) | `docs/engineering/commission-engine-vnext-as-built.md` calls it "resolved"; `docs/engineering/risk-and-open-decisions.md`, even at its latest commit (2026-08-26, after four *other* decisions were formally approved), still lists D-03 as OPEN | Register and risk log agree with each other; the as-built doc is the outlier — audited as **DECISION REQUIRED** |
| INV-013 / S-07 | `docs/engineering/risk-and-open-decisions.md:593` states a `unique(external_invoice_id, invoice_source)` constraint exists as a safeguard | No such constraint exists anywhere in the migrations; `external_invoice_id` is never even written | Documentation is factually wrong; logged, not silently trusted |
| CLS-001 | Register/current code: server-side, persisted | `docs/engineering/productization-api-gap.md` (2026-08-19) describes classification as browser-only, never persisted | That doc is stale by one day (fixed 2026-08-20, confirmed via `git log --follow`) — a doc-drift case, not a real gap |
| COM-007 naming | Design docs (`current-vs-target-state.md`, `migration-roadmap-vnext.md`, `risk-and-open-decisions.md`) name the table `raw_saas_activation_events` | Shipped table is `saas_activation_events` (no `raw_` prefix) | Functionally equivalent; flagged so a future grep-by-documented-name doesn't wrongly conclude the infrastructure is missing |
| ZON-007 / 94–119 change | `AGENTS.md` requires every new technical/business decision to be logged in `docs/DECISIONS.md` | The 94–119 reversal has zero entry in `docs/DECISIONS.md` or `CHANGELOG.md` | The project's own governance rule was not followed for its single most consequential recent money-rule change |
| COM-008 as-built claim | `docs/engineering/commission-engine-vnext-as-built.md` §9 claims "18,536 events... surface as exceptions rather than vanishing" | Post-fix (`20260824090000...sql`), a *resolved* direct-company parent generates **zero** exception rows by design — correct financially, but the as-built doc's wording is now stale | Logged; does not change the underlying PASS-worthy mechanism, only the doc's accuracy |

---

## 8. Financial Safety Assessment

**Strong, evidenced-by-tests foundations:**
- Payment posting is atomic, idempotent, overpayment-guarded, concurrency-locked, and fully audited (PAY-001..008, PAY-011) — every claim backed by a specific trigger, constraint, or RPC guard, several with a real concurrency test (`tests/sql/financial-correction-concurrency.sh`).
- Posted/paid financial history is immutable at the DB level (`protect_financial_ledger`, `protect_settled_installation_entitlement`, `protect_finalized_snapshot`); corrections and reversals are forward-only, never mutate the original row.
- Commission event-level dedup is enforced by a real unique constraint (`commission_event_entitlements_identity`), not application logic or the legacy `seenIds` array.
- Holds and Historical Exceptions are proven end-to-end with DB CHECK constraints and passing SQL tests, not just plausible-looking code.
- Cycle lifecycle (flag → explicit recalculation → reopen-only-if-unposted → immutable-once-posted) is a coherent, tested state machine.

**Concrete financial risk found:**
- The zone/FDT regression (§4.1) has direct revenue impact: a cabinet's zone determines both its tier-population bucket and its rate table. An unregistered or misclassified cabinet is silently priced with no review trail today.
- The unrevoked `publish_commission_month` RPC and its unrevoked legacy grant remain a theoretical direct-API path to a client-influenced tier basis, even though the UI no longer offers it.
- The invoice-domain gaps (§4.2-4.4) mean installation-fee payment currently rests on a human-typed approval status over an externally supplied balance file, not on a provably-complete bulk-matched source — real money, thin verification layer.
- No scheduled/automated backup exists; recovery today depends on a manual process being followed correctly before every financial migration.

**Confirmed for this task specifically:** no Production financial data was modified, no payment was executed, no cycle was recalculated (July or otherwise), no financial test data was created in Production, and every research pass in this audit was read-only (Read/Grep/Bash-read-only tool history throughout).

---

## 9. V1 Closure Candidates

Every one of the 161 requirement IDs has now been individually classified with cited evidence (§2), so this section gives an exact count rather than an estimate.

Per the register's own Anti-forgetting contract §12 — *"Stable requires all current-scope requirements PASS, explicit accepted exception, or explicit cancellation by user"* — the in-scope universe is 156 IDs (161 minus the 5 `OUT OF SCOPE — OPERATIONS` IDs, which are excluded from closure by the register's own rule).

**Exact current blocker count: 63 of 156 in-scope requirement IDs are not yet PASS** (16 PARTIAL + 29 MISSING + 11 VERIFY + 7 DECISION REQUIRED). None of these 63 has received an "explicit accepted exception" or "explicit cancellation by user" as the contract requires — so none may be treated as closed by this audit. 93 of 156 in-scope IDs (60%) are PASS.

**Not V1-Stable-eligible until, at minimum:**
- All 3 headline gaps in §1 are resolved or explicitly, individually accepted by the user (zone/FDT regression, Bulk Invoice Audit, Free P1).
- All 7 DECISION REQUIRED items receive an actual recorded business decision (§5) — not an engineering inference, per the register's own rule 11 ("never invent a money rule").
- PAY-010 (commission correction UI) ships, or is explicitly accepted as a deferred gap by the user.
- The 11 VERIFY items are either verified with fresh evidence or explicitly accepted as-is.

This is a punch list, not a go/no-go recommendation — closure decisions belong to the user per the register's own governance.

---

## 10. Recommended Execution Order

Reordered from the register's own Execution Order (§ Execution order, A–G) with this audit's dependency and financial-risk findings folded in:

1. **Reverse the zone/FDT regression first — it is live and revenue-affecting today.** Wire `fdt_commission_scope()` to read `fdts.zone` (already built, already admin-editable) instead of the 94–119 literal; restore an `UNKNOWN_FDT`/review fail-safe for unregistered cabinets. This single fix closes or improves CFG-001/002/003/004/005, ZON-001/002/003/004/005/006/007, COM-012/013 — the largest single cluster of MISSING/PARTIAL/DECISION-REQUIRED findings in this audit, all sharing one root cause.
2. **Close the 7 business decisions (§5) before building anything further on top of them** — per the register's own rule, especially COM-009/COM-012 where code already picked an answer that was never ratified.
3. **Revoke or neutralize the legacy `publish_commission_month` RPC's grant** (COM-002, PAY-012) — small, low-risk, closes a real direct-API exposure.
4. **Build the Bulk Invoice Audit engine** (INV-001..004, INV-007..009, INV-013 fix, INV-014 lineage wiring) — the largest genuinely-unbuilt feature surface, and the one the task explicitly called "a critical area."
5. **Ship commission-domain correction/reversal UI** (PAY-010) — the server capability already exists; this is UI wiring on top of proven infrastructure.
6. **Add the bad-import cancellation/void lifecycle** (IMP-003).
7. **Resolve LIVE-04** (ARC-001) — genuinely still open behind a stale-filename trap.
8. **Build Free P1** (FREE-001..006) — only after FREE-004/DEC business sign-off, and only after COM-009 is ratified (Free P1 will need the same active-user definition).
9. **Security hardening pass**: refresh the Security Advisor inventory against the current 55+-table schema (SEC-001/003/004/005/006), then remediate — inventory first, fixes in a separate, explicitly-scoped task.
10. **Backup/recovery**: evaluate a Supabase plan upgrade for PITR, or formalize the existing manual export process as the accepted interim strategy (SEC-007).
11. **Close the remaining VERIFY items** (INS-009, ZON-005, OWN-003/004, IMP-001, ARC-005, SEC-001/005, UX-006, USR-007, INV-019) with targeted, narrow follow-up checks — none of these block the larger items above, but all are needed before a genuine V1 Stable declaration.
12. **Only then**: run the register's own Mandatory acceptance cases (all 24) end-to-end and declare V1 Stable — never from a repo-only audit, per the register's own closing line.
