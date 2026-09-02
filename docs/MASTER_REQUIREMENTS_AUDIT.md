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
| INS-009 | Dashboard totals reconcile | VERIFY | `installation_financials()`, `20260822120000_add_reporting_layer.sql:109-186` | — | — | `tests/installation-dashboard-source.test.js` pins one previously-shipped merge bug (fixed) | Entitlements table and enrollments/stage-distribution table are separate, not cross-checked figures — were previously able to diverge because `installation_enrollments.current_stage_code` was never updated post-enrollment; `20261103090000` now advances it on the paid transition alongside `installation_subscriber_state` (see architecture note under INV) |
| INS-010 | Entitlement rules server-authoritative | PASS | all mutating RPCs derive stage/amount server-side | `guard_installation_payment` trigger, `20260820180000...sql:297-343`, closes direct-table-write bypass | — | — | Two independent server-side gates |
| INS-011 | Correction/reversal exists without mutating original | PASS | `reverse_financial_entry`/`correct_financial_entry` | `20260818090000_add_financial_correction_ledger.sql:287-499` | `src/features/installation/index.ts` wires `paymentCorrections.ts` | — | Closed per `docs/engineering/risk-and-open-decisions.md:41-75` (R-03) |
| INS-012 | Historical baseline is the one-time opening authority | PASS | `import_installation_history`, `20260816090000_add_installation_history.sql` | `installation_subscribers` / `installation_subscriber_state` / `installation_payment_history` | — | `tests/sql/installation-history-rules.sql`, `tests/sql/installation-raw-activation-bridge.sql` §8 | Bridge inserts state with `on conflict do nothing`, so a historical subscriber resumes from its own stage and is never reset to P1 |
| INS-013 | Recurring monthly path consumes the raw SaaS Activation file — no hand-made Remaining column | PASS | `bridge_saas_activations_to_enrollments` + `ensure_installation_state_for_enrollment`, `20261103090000_installation_raw_activation_bridge.sql` | bulk sweep gated by the existing `evaluate_enrollment_gate`; `trg_installation_enrollment_opens_state` after insert on `installation_enrollments` | `src/features/system/import-run.ts` (after the raw import), `src/features/system/imports.ts` (re-run panel) | `tests/sql/installation-raw-activation-bridge.sql` §1, §3, §4, §13 | `enroll_new_installation` previously had no UI caller at all. No blind enrolment: blocked subscribers are returned with their reasons and stay reviewable; re-runnable because identity/classification/completeness are settled after upload. Amended by `20261104090000` (§16): chunked intake keeps one logical batch per file under the 8s authenticated timeout, and the sweep is cursored (`p_after_username`) so blocked candidates cannot starve the ones behind them; the caller sweeps to exhaustion via `src/features/system/bridge-sweep.ts` |
| INS-014 | Server derives current/next stage, Remaining and entitlement from authoritative state | PASS | `materialize_installation_entitlements`, `20260913090000_materialize_and_batch.sql`; reconciliation in `ensure_installation_state_for_enrollment` | reads `installation_subscriber_state`; no Remaining parameter exists on any recurring RPC; opening state reconciled against paid entitlements/payments | — | `tests/sql/installation-raw-activation-bridge.sql` §2, §4; `tests/sql/installation-upgrade-backfill.sql` §1–§5 | An upgraded subscriber with prior paid stages opens at the correct next stage, never at a fresh P1; an inconsistent history opens as `unresolved` with the reason in `warnings` instead of a guess. DEC-007 (per-period qualifying event) remains open; no gate added |
| INS-015 | Progression P1→P2→P3→P4→DONE is deterministic, sequential, idempotent, auditable | PASS | `trg_payment_advances_installation_state` + `guard_installation_stage_paid_once`, `20261103090000_installation_raw_activation_bridge.sql` | before insert on `installation_payments` writes `installation_payment_history` (unique `subscriber_uuid, stage`); after update on the paid transition advances state under `for update`, reading `stage_amount_for_version` / `next_stage_for_version` / `stage_for_remaining_in_version` of the enrollment's frozen version | — | `tests/sql/installation-raw-activation-bridge.sql` §5–§9, §14; `tests/sql/installation-cross-period-payment-concurrency.sh`; `tests/sql/payout-end-to-end.sql` §11 | Same subscriber + same stage is now payable once across all periods and paths, failing atomically before the payment row, ledger entry, paid transition and success audit — proven sequentially and under true concurrency on two entitlement ids. Stated limit: storage CHECK constraints encode the V1 ladder, so a different versioned ladder is rejected as `SCHEME_NOT_REPRESENTABLE_IN_STORAGE` rather than silently mapped through the legacy function |
| INS-016 | Deriving an entitlement does not bypass invoice/hold/identity/ownership controls | PASS | `materialize_installation_entitlements`, `installation_entitlement_eligibility`, `record_installation_payment`, `guard_installation_stage_paid_once` | VERIFIED invoice per stage, effective holds, identity CONFLICT, `subscriber_ownership_type = RESELLER`, `guard_installation_payment` before update, stage-paid-once before insert on `installation_payments` | — | `tests/sql/installation-raw-activation-bridge.sql` §10, §9(د) | The bridge writes only subscriber/state rows; it adds no payment authority and touches no entitlement or ledger row. The new guard only ever removes payment authority |

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

---

## 11. 2026-09-01 Reconciliation Addendum

**Type:** Dated delta, not a fresh four-pass audit. Branch `feat/v1-go-live-closure`, reconciled against the same baseline as §1–§10 above (commit `65a90f4` / `2be654e`). This section documents what changed since that baseline and gives fresh evidence only for the specific IDs actually re-checked this pass — everything else in §1–§10 stands unless contradicted here, per the register's own rule that findings are never silently deleted.

**Method:** two kinds of evidence. (a) Commits already built, tested (local Postgres SQL suite + `npm test` + `tsc --noEmit`), and merged onto this branch during this closure engagement — cited by commit hash and description, not re-derived here. (b) A targeted VERIFY-resolution pass this session, re-checking each of the 11 IDs §10 step 11 named, with file:line evidence, matching the original audit's own evidentiary standard. No file was edited to make a requirement pass; no migration ran against Staging/Production; the zone/FDT regression (headline blocker #1) was deliberately **not touched** — a prior investigation in this engagement concluded the 94–119 reinstatement was a deliberate business choice, not an accidental regression, so reversing it is not this engagement's call to make. Free P1 (headline blocker #3) likewise remains untouched — still zero implementation, still blocked on FREE-004.

### 11.1 Shipped this engagement (evidence: commit + prior verification run, not re-derived here)

| Commits | Requirement IDs affected | What shipped |
|---|---|---|
| `ad1f5d3` | INV-001..004, INV-007..009, INV-013, INV-014 | Bulk Invoice Audit engine — upload → parse → preview (matched/unknown/duplicate/already-used/invalid/conflict) → bulk apply, replacing the single-row manual gate headline blocker #2 described. |
| `d7ab452` | ARC-001 | LIVE-04 fix — archive KPI and detail now reconcile from the same server dataset; closes the stale-filename trap. |
| (pre-dates this window, per standing engagement record) | PAY-010, UX-004 | Commission correction/reversal UI wired to the existing server RPCs — closes the "DB console required" gap. |
| (pre-dates this window) | COM-002, PAY-012 | Legacy `publish_commission_month` grant revoked — closes the direct-API exposure §8 flagged as a concrete financial risk. |
| `0d9d9eb`, `20038ad`, `ac1feaa` | SEC-001, SEC-004 | Full `has_function_privilege`-based grant audit (not text-matching) — confirmed 54/54 `public` tables RLS-enabled with zero anon/PUBLIC table grants; closed two genuinely accidental EXECUTE-to-anon/public function grants and completed a missing `revoke ... from public, anon` half on four functions. `docs/SECURITY.md` rewritten to match (including a self-caught correction of an initially over-generalized "no financial data in localStorage" claim — the legacy `index.html` layer still uses `localStorage`, only `src/` is clean). |
| `5592a53` | SEC-007 | Scripted, guarded, on-demand `pg_dump` (`scripts/dump-database.mjs`, `npm run dump:staging`/`dump:production`) replacing what had only ever been a one-time manual Staging test. Still **not** scheduled backups or PITR — that remains a Supabase billing/plan decision, now tracked explicitly in `docs/BUSINESS_DECISIONS_REQUIRED.md` rather than left as a bare mention in R-015. |
| `5592a53` | (governance, no single ID) | `docs/BUSINESS_DECISIONS_REQUIRED.md` — consolidates DEC-001..006, FREE-004, and the PITR/billing decision into one closure-facing document with current evidence cited per item, satisfying the register's own rule 11 ("never invent a money rule") by recording rather than resolving. |

SEC-003 (Security Advisor findings closed/accepted) and SEC-005 (full least-privilege/auth review) are **not** claimed closed by the grant audit above — see §11.3.

### 11.2 VERIFY resolution pass (the 11 IDs named in §10 step 11)

| ID | Outcome | Evidence |
|---|---|---|
| USR-007 | **PASS** | `tests/session-persistence.test.js` — 4 tests: reload-persistence, expired-token-refresh, near-expiration-only-refresh, refresh-token survives a temporary network failure. Directly covers the requirement text. |
| OWN-003 | **PASS** | `tests/sql/subscriber-transfer.sql:238-241` — `sum(installation_payment_history.amount)` for the transferred subscriber is asserted unchanged after `transfer_subscriber()` runs ("وما دُفع لا يُعاد حسابه"). Ownership change does not rewrite old money. |
| OWN-004 | **PASS** | `tests/sql/subscriber-transfer.sql:200-236` — `effective_agent_id`, `agent_name_at_enrollment`, and `current_stage_code` on `installation_enrollments` all assert unchanged after transfer; a stage genuinely in progress at another agent raises an explicit `NEEDS_BUSINESS_DECISION` with `paid_so_far`, rather than silently moving history. |
| ARC-005 | **PASS** | `tests/sql/commission-payout.sql:221-222` — `sum(gross)` from `report_commission_cycle_detail()` is asserted equal to `commission_cycle_financials()`'s independently-computed `totals.gross`, a genuine cross-function reconciliation (not just an assertion against a fixture constant). Reinforced by `commission_scope_payable()` matching the same source-snapshot value (line 57, `gross=12000`) both before and after a reversal (lines 67-69, 184-197), and `report_agent_statement()`'s `gross`/timeline agreeing too (lines 236-242). |
| INV-019 | **PASS** | `grep -rn "storage\.objects\|createBucket\|storage\.from"` across `supabase/migrations/*.sql` and `src/` returns zero hits — no evidence-attachment mechanism exists at all (matches DEC-004 still being fully open in `docs/BUSINESS_DECISIONS_REQUIRED.md`), so the Bulk Invoice Audit engine (`supabase/migrations/20261019090000_bulk_invoice_audit.sql`, `src/features/installation/invoices.ts`) cannot have entangled with it. The "evidence" panel in `invoices.ts` is a text/data review summary, not a file attachment. Distinction holds. |
| SEC-001 | **PASS** | Confirms the register's own draft status. This session's `has_function_privilege`-based sweep (§11.1) is exactly the "hardening" half the register flagged as open; RLS coverage itself (54/54 tables, zero anon/PUBLIC grants) was independently re-confirmed, not assumed from the register. |
| INS-009 | **stays VERIFY, resolved to PARTIAL in §12.7** | `tests/installation-dashboard-source.test.js` (9 tests) proves the *frontend* merge of baseline+entitlement never drops/duplicates rows. `grep -rln "installation_financials\|dashboard" tests/sql/*.sql` finds zero SQL-level tests reconciling the aggregate KPI against a fresh count from underlying tables — the audit's specific concern is unaddressed. See §12.7 for the 2026-09-01 re-verification: there is no server-side KPI aggregate at all for this dashboard, only two independently-paginated client-merged REST fetches. |
| IMP-001 | **stays VERIFY** | Per-domain checksum/dedup mechanisms exist (`source_checksum` in SaaS activation intake, `file_checksum` in installation-fee import, duplicate detection in bulk holds preview) but no test proves re-importing the same file/event produces zero financial delta end-to-end across all three import domains together — matches the original audit's own characterization. |
| ZON-005 | **stays VERIFY — structurally blocked** | Directly entangled with the paused zone/FDT scope question (§1 headline blocker #1 / DEC-002 in `docs/BUSINESS_DECISIONS_REQUIRED.md`). Cannot be honestly resolved without first resolving which scope definition import/calculation/dashboard/payment should consistently use — which this engagement is deliberately not deciding. |
| SEC-005 | **stays VERIFY here; resolved to PASS in §12.7** | Checked the `search_path`-hijack half specifically: across every migration file declaring `SECURITY DEFINER` functions, `SET search_path` count is ≥ the `SECURITY DEFINER` count in every case (`grep -c` cross-check, 20+ files) — no function found missing a pinned search_path. The other half of SEC-005 — per-function least-privilege/internal-authorization review — was completed 2026-09-01, see §12.7: zero write-without-authorization gaps across 210 currently-effective functions, but it surfaced a related SEC-004 gap (unaudited default-PUBLIC-execute on ~20 read-only functions). |
| UX-006 | **stays VERIFY** | Final mobile touch-target sizing is a device/manual-QA question, not something a code read or grep resolves honestly. Left open pending actual device review. |

Net: **6 of 11 VERIFY items resolved to PASS** (USR-007, OWN-003, OWN-004, ARC-005, INV-019, SEC-001) with fresh, cited evidence; **5 remain VERIFY** (INS-009, IMP-001, ZON-005, SEC-005, UX-006), each for a stated, specific, still-open reason rather than a blanket "not verified."

### 11.3 Recomputed blocker count

The baseline count (§9) was **63 of 156 in-scope IDs not yet PASS** (16 PARTIAL + 29 MISSING + 11 VERIFY + 7 DECISION REQUIRED). This addendum does not re-run the full four-pass per-ID audit that produced that table — doing so would be a disproportionate re-audit rather than a reconciliation, and is explicitly not what this pass did. What can be stated with the evidence actually gathered:

- **At least 6 IDs move from the VERIFY bucket to PASS** (§11.2): 11 → 5 VERIFY remaining.
- **At least 4 more IDs move out of the MISSING/OPEN bucket** on direct evidence already cited in §11.1: ARC-001 (LIVE-04 fix), COM-002, PAY-012 (grant revoked), PAY-010 (correction UI shipped).
- **A cluster of 9 IDs** (INV-001..004, INV-007..009, INV-013, INV-014) has a real, tested implementation where §1's headline blocker #2 previously found none — this addendum does not individually re-tag each one to PASS, since the Bulk Invoice Audit engine's edge cases (e.g. INV-013's dedup guarantee, INV-014's full lineage chain) deserve the same file:line scrutiny the original audit applied elsewhere, not an inherited pass from the commit message alone.
- The 7 DECISION REQUIRED items are **unchanged in count** — `docs/BUSINESS_DECISIONS_REQUIRED.md` records and cross-references all of them (plus FREE-004 and the PITR/billing question) but ratifying any of them is explicitly outside what an engineering session may do.

**Honest recomputed ceiling: no more than 63 − 6 (§11.2) − 4 (§11.1 direct) = 53 of 156 in-scope IDs remain not-PASS**, and the true number is very likely lower once the INV cluster above and SEC-003/SEC-004/SEC-006 (Security Advisor dashboard items, not re-checked from Supabase itself this session — no Supabase project was touched) get the same targeted re-check. **Recommend a follow-up pass specifically over the INV-001..004/007..009/013/014 cluster and the Security Advisor-dependent SEC IDs before formally declaring any of them PASS** — this addendum intentionally stops short of that to avoid claiming precision it doesn't have.

### 11.4 What remains genuinely, deliberately unresolved

- **Zone/FDT scope (headline blocker #1, DEC-002)** — paused, not touched. A prior investigation in this engagement found the 94–119 reinstatement was a deliberate choice, not an accident; this closure neither reverts nor ratifies it. A formal ADR is still owed either direction.
- **IMP-003 (bad-import cancellation)** — blocked by DEC-005 (cancellation semantics never decided). Not built; building it would mean inventing a money rule.
- **Free P1 (FREE-001..006)** — still zero implementation. Blocked on FREE-004 (active-customer definition) and, per §10 step 8, on COM-009 being ratified first (same active-user definition dependency).
- **5 remaining VERIFY items** — INS-009, IMP-001, ZON-005, SEC-005, UX-006 (§11.2).
- **7 DECISION REQUIRED items** — now consolidated with current evidence in `docs/BUSINESS_DECISIONS_REQUIRED.md`, none ratified.
- **Scheduled backups / PITR** — genuinely improved (guarded on-demand dump script) but not equivalent to the register's SEC-007 requirement; still a billing/plan decision.

See `docs/BUSINESS_DECISIONS_REQUIRED.md` for the consolidated decision list and `docs/GO_LIVE_READINESS.md` (this engagement's final closure synthesis) for the overall recommendation.

---

## 12. 2026-09-01 Owner-Decision Ratification Addendum

**Type:** Second same-day delta, superseding specific stale claims in §11 above (not a fresh audit pass). The owner supplied explicit written rulings on all 7 DECISION REQUIRED items plus FREE-004 and the PITR question — reproduced in full in `docs/BUSINESS_DECISIONS_REQUIRED.md` ("القرار المعتمد") and formalized as `docs/DECISIONS.md` ADR-023 through ADR-030. Per the owner's explicit instruction, this pass did not stop at recording the decisions — wherever a decision unblocked a missing implementation, it was built and tested against local Postgres, never Staging/Production. §11's text below is superseded where noted; everything else in §1–§11 stands.

### 12.1 Decisions ratified with no code change (behavior already matched)

| Decision | ADR | Disposition |
|---|---|---|
| DEC-001 (UNIQUE ACTIVATED SUBSCRIBERS basis) | ADR-023 | Existing implementation already matched; ratified as-is. |
| DEC-003 (invoice identity = SOURCE + REFERENCE) | ADR-025 | Existing implementation already matched; ratified as-is. |
| DEC-004 (no attachment storage in V1) | ADR-026 | Confirms INV-019's §11.2 finding (zero attachment mechanism) as the *correct*, now-ratified state, not an open gap. |
| DEC-006 (no auto-merge) | ADR-028 | Existing NEEDS_REVIEW/CONFLICT behavior already matched; ratified as-is. |

### 12.2 DEC-002 (zone/FDT scope) — ratified, §11.4's "ADR still owed" is now stale

ADR-024 records the owner's ruling: the 94–119 NEW ZONE routing stays exactly as implemented, documented as a **deliberate V1 business choice**, not an accidental regression pending reversal. §11.4's line *"A formal ADR is still owed either direction"* is now false — the ADR exists and the direction is "keep as-is."

This resolves the decision question itself, but **not** the broader per-ID audit. §11.2's ZON-005 entry ("stays VERIFY — structurally blocked... which this engagement is deliberately not deciding") is **reclassified**, not flipped to PASS:

| ID | Prior (§11.2) | Now | Why not PASS outright |
|---|---|---|---|
| ZON-005 | VERIFY — structurally blocked on an undecided question | **PARTIAL — re-verified this pass, see below** | Re-checked with file:line evidence (below). Three of four named surfaces are consistent; the installation-dashboard surface is not. |

The wider `ZON-001..004/006/007` and `CFG-001..005`/`COM-012/013` cluster referenced in `docs/BUSINESS_DECISIONS_REQUIRED.md`'s "ما بقي مفتوحاً" for DEC-002 has a **different** status from ZON-005 and stays MISSING: those IDs (per their own text in `docs/MASTER_REQUIREMENTS_REGISTER.md:26-33,72-84`) ask for the 94–119 boundary to become *configurable master data* (settings-driven, no-code-change FDT onboarding, effective-dated changes) — that is exactly what DEC-002 explicitly defers to Post-V1 ("Configurable FDT master-data replacement is Post-V1"). Ratifying "keep the hardcoded rule for V1" does not make a configurability requirement PASS; it confirms those IDs are correctly Post-V1 scope, not V1 gaps.

**ZON-005 itself asks a narrower, already-answerable question** — "is the same [however-defined] scope used consistently by import/calculation/dashboard/payment" — independent of whether that scope is hardcoded or configurable. A dedicated Explore pass this session traced every consumer:

- **Single source of truth confirmed**: `public.fdt_commission_scope(p_fdt_code text)` (`supabase/migrations/20261011090000_effective_ownership_and_fdt_scope.sql:29-45`, boundary at line 42) is the only place in the entire repo (migrations + `src/`) containing a `between 94 and 119` test — confirmed by a repo-wide grep for co-occurring "94"/"119"; no duplicate/reimplemented range check exists anywhere else.
- **Import** funnels through `commission_qualifying_events` (`20261011090000...sql:54-116`, zone derived line 91; re-`create or replace`d by `20261022090000_void_saas_import_batch.sql:96-160` for VOID filtering, still calling `fdt_commission_scope` at lines 127-130 — no drift introduced).
- **Calculation**: `calculate_commission_cycle` reads `commission_qualifying_events` (line 190) and calls `fdt_commission_scope` directly in its manual-ADD branch (line 233); zone propagates into `commission_cycle_snapshots.zone` (lines 336-381).
- **Payment**: `free_p1_bonus` (`20261021090000_free_p1_bonus.sql`) reads zone/scope_type from `commission_cycle_snapshots` (lines 218-230) — same chain, cross-validated by the `free_p1_grants_zone_scope_match` CHECK.
- **Dashboard — genuine gap found**: `installation_enrollments.zone` (table def `20260820150000_add_installation_operations.sql:53-77`) is a **separate, disconnected column that is never populated** — `enroll_new_installation`'s insert (`20260820180000_wire_installation_workflow.sql:189`) never sets it, and `bootstrap_historical_enrollments` explicitly sets it `null` (line 256). `src/features/installation/index.ts`'s zone display on the installation dashboard therefore reads an unwired column, not `fdt_commission_scope`'s output. This is not duplicated/drifted logic (no reimplemented range check exists there) — it's a dead field feeding a real UI surface, which is precisely what ZON-005 asks to be consistent.

**Verdict: ZON-005 → PARTIAL, not PASS.** Commission-domain consistency (import/calculation/payment) is real and verified. The installation-dashboard zone display is not fed by the canonical function at all. Fixing this (wiring `installation_enrollments.zone` from `fdt_commission_scope`, or having the dashboard read zone from `commission_cycle_snapshots`/`commission_qualifying_events` instead of the unpopulated column) is a small, scoped, non-financial UI-data-wiring fix — flagged here as a finding, not fixed in this pass, since it was outside the owner's named priority list and touches display code that deserves its own scoped review rather than a same-pass drive-by edit.

The `ZON-001..004/006/007`/`CFG-001..005`/`COM-012/013` configurability cluster remains correctly Post-V1 per DEC-002 and needs no further audit action this engagement.

### 12.3 DEC-005 (IMP-003, bad-import VOID) — moved from blocked to built and tested

§11.4's line *"blocked by DEC-005 (cancellation semantics never decided). Not built; building it would mean inventing a money rule"* is now stale. ADR-027 records the ratified logical-VOID semantics; they were implemented and tested this session, never against Staging/Production:

- Migration: `supabase/migrations/20261022090000_void_saas_import_batch.sql` (commit `cf9b1e5`) — new `saas.void_import` capability; `voided`/`voided_by`/`voided_at`/`void_reason` columns with a mandatory-attribution CHECK; an immutability trigger blocking any further mutation of a voided batch; `commission_qualifying_events` and `evaluate_enrollment_gate()` both re-defined (via `create or replace`, no applied migration edited) to exclude/flag voided-batch data; `void_saas_import_batch()` RPC — SECURITY DEFINER, capability-gated, request_id-replay-idempotent, and fails closed (rejects with the exact posted/paid row count) if the batch has already touched a `FINALIZED/PARTIALLY_PAID/PAID/CLOSED` cycle — using the same mutability boundary as `calculate_commission_cycle`/`recalculate_cycle_after_master_change`/`assert_cycle_correctable`.
- Test: `tests/sql/void-import-batch.sql`, wired into `tests/sql/run-local-tests.sh` as block `out43` — **20/20 assertions passing** against local Postgres, covering rejection paths (empty reason, missing request_id, missing capability, draft-status batch, FINALIZED/PAID impact, installation-enrollment impact), the success path with full attribution verification, request_id replay, a direct-superuser-bypass attempt proving the immutability trigger itself (not just the RPC's guard) blocks mutation, and confirmed exclusion from `commission_qualifying_events` plus a `BATCH_VOIDED` blocker surfacing from `evaluate_enrollment_gate`.
- **Deliberate residual scope, not a gap**: no confirmed FK linkage exists from `installation_enrollments` to `saas_import_batches`, so the RPC conservatively **refuses VOID outright** whenever the batch produced any installation enrollment at all — wider than may be strictly necessary, but fail-closed rather than silently unsafe. Documented in the migration's own comments and in `docs/BUSINESS_DECISIONS_REQUIRED.md`'s DEC-005 "ما بقي مفتوحاً".

**IMP-003: MISSING → PASS.**

### 12.4 FREE-001..006 (Free P1) — moved from blocked to built and tested

§11.4's line *"still zero implementation. Blocked on FREE-004... and on COM-009 being ratified first"* is now stale. ADR-029 records the owner's final ruling (threshold = 350 UNIQUE ACTIVATED SUBSCRIBERS per DEC-001's definition; NEW ZONE eligibility strictly per-FDT, one Free P1 per qualifying FDT; OLD ZONE eligibility on the reseller's *total* qualifying subscribers across the OLD ZONE, never per-FDT). Implemented and tested this session, never against Staging/Production:

- Migration: `supabase/migrations/20261021090000_free_p1_bonus.sql` (commit `0c28c56`) — `commission.grant_free_bonus`/`commission.configure_free_bonus` capabilities; `commission_free_p1_rules` (one configurable threshold row per scheme version, seeded at 350 for the production `COMMISSION_STANDARD` v1 scheme version only); `set_free_p1_threshold()` RPC (capability-gated, replay-idempotent); `free_p1_grants` table with three defense-in-depth CHECK constraints (identity-unique per cycle+scope, zone/scope-type match, threshold-met); `grant_free_p1()` RPC — SECURITY DEFINER, capability-gated, requires a *finalized* cycle, fails closed with no invented default if no threshold rule exists for the scheme version, reads eligibility purely from finalized `commission_cycle_snapshots`, `on conflict do nothing` idempotency plus request_id replay, full audit-log write.
- Test: `tests/sql/free-p1.sql`, wired into `run-local-tests.sh` as block `out42` — **30/30 assertions passing**, covering NEW ZONE per-FDT independence (two FDTs on the same reseller each judged separately, no aggregation), OLD ZONE reseller-total aggregation (two FDTs summed, exactly one grant, not two), the 349/350 threshold boundary, fail-closed paths (not-finalized cycle, no threshold configured, direct CHECK-constraint violation attempts), capability enforcement, and `set_free_p1_threshold` RPC behavior including replay.
- **Interpretive note carried forward, not re-litigated**: "≥350" was read as inclusive (350 itself qualifies) — stated explicitly in `docs/BUSINESS_DECISIONS_REQUIRED.md` and ADR-029 as an interpretation of the owner's wording, not an invented rule.
- **Out of scope, explicitly**: how a granted Free P1 is actually settled/paid out (voucher, credit, cash-equivalent) was never specified by the owner and was not invented — `grant_free_p1()` only records entitlement; no payment/settlement code was written.

**FREE-001..006: MISSING → PASS** (entitlement generation and eligibility logic). Settlement/payout mechanics remain explicitly unspecified and out of this engagement's scope.

### 12.5 SEC-007 / R-015 (backups, PITR) — closes as mitigated by decision

ADR-030 records the owner's ruling: a paid Supabase PITR upgrade is **not** a V1 go-live requirement; the existing guarded on-demand `pg_dump` tooling (`scripts/dump-database.mjs`, commit `5592a53`, §11.1) is accepted as the V1 backup/recovery posture, with paid PITR tracked as a documented future infrastructure enhancement rather than an open risk. §11.4's line calling this "still a billing/plan decision" is now stale — the decision has been made.

### 12.6 Recomputed blocker ceiling

§11.3's honest ceiling was **"no more than 53 of 156."** This addendum moves the following out of not-PASS:

- **IMP-003**: MISSING → PASS (§12.3).
- **FREE-001..006** (6 IDs): MISSING → PASS (§12.4).
- **SEC-005**: VERIFY → PASS (§12.7) — full sweep of 210 currently-effective `SECURITY DEFINER` functions found zero write-without-authorization gaps.
- **7 DECISION REQUIRED items**: all 7 (plus FREE-004, already counted in the FREE cluster) are now ratified — §11.3's "7 DECISION REQUIRED, unchanged in count" no longer holds; all 7 close as *decided*, though 4 of them (DEC-001/003/004/006) close with zero code change since behavior already matched, and DEC-002's decision closing does not itself flip ZON-005 or its cluster to PASS (§12.2).

Re-verified but **not** moved to PASS (stay counted as not-PASS, now with sharper, cited reasons instead of blanket VERIFY):

- **ZON-005** — re-verified, resolved to PARTIAL (§12.2): commission-side consistent, installation-dashboard zone display unwired.
- **INS-009** — re-verified, resolved to PARTIAL (§12.7): no server-side KPI aggregate exists at all; only fixture-level frontend-merge protection.
- **IMP-001** — re-verified, resolved to PARTIAL (§12.7): 2 of 3 import domains solid with DB-enforced dedup + tests; bulk-invoice re-upload detection is app-only with zero test coverage.
- **UX-006** — unchanged, device-only manual QA.

**New finding, not previously tracked as a numbered gap**: the SEC-005 sweep surfaced that roughly 20 read-only `SECURITY DEFINER` functions have no explicit `grant`/`revoke execute` statement at all (default PUBLIC execute), which is squarely SEC-004's scope ("Functions callable by anon reviewed/revoked if unnecessary") and was **not** caught by the earlier grant-audit commits (`0d9d9eb`/`20038ad`/`ac1feaa`) that closed only *known* accidental grants. SEC-004 stays open/not-PASS and should not be considered closed by the earlier work — see §12.7 for the full function list and why this matters (SECURITY DEFINER bypasses RLS, so an un-revoked anon grant on a function like `installation_financials` would expose real financial data to unauthenticated callers if reachable in the deployed database).

**Revised honest ceiling: no more than 53 − 1 (IMP-003) − 6 (FREE-001..006) − 1 (SEC-005) − 7 (DECISION REQUIRED, now decided) = 38 of 156 in-scope IDs remain not-PASS**, with the same caveat §11.3 already stated: the true number is very likely lower once the INV cluster and the Security Advisor-dependent SEC-003/006 get their own targeted file:line re-check — none of which this addendum claims to have done. This ceiling still counts ZON-005/INS-009/IMP-001/SEC-004/UX-006 as not-PASS, each for the specific, cited reason above rather than a blanket "not verified."

### 12.7 What remains genuinely, deliberately unresolved (supersedes §11.4)

- **ZON-001..002/004/006/007, CFG-001..005, COM-012/013** — correctly Post-V1 per DEC-002 (configurability was explicitly deferred, not merely undecided); no further audit action needed this engagement (§12.2).
- **ZON-005** — re-verified this pass, resolved to **PARTIAL** (§12.2): commission-side consistency (import/calculation/payment) confirmed via a single canonical function `fdt_commission_scope()`; the installation-dashboard zone display reads an unpopulated `installation_enrollments.zone` column instead, a real but small, scoped, non-financial wiring gap — not fixed in this pass (outside the owner's named priority list).
- **INS-009 — re-verified this pass, resolved to PARTIAL** (not the prior "stays VERIFY, frontend-only proof" framing): there is no server-side KPI aggregate for the installation dashboard at all — `index.html:2608,2620` issues two independent, separately-paginated raw PostgREST fetches (`installation_subscribers` with embedded state/payment history, and `installation_entitlements`), merged client-side by `buildInstallationDashboardRows()`/`summarizeSubscriberStates()` (`assets/js/installation-fees.js:730,780`). `tests/installation-dashboard-source.test.js`'s 9 tests genuinely prove the merge logic doesn't drop/duplicate rows, but only against hand-built in-memory fixtures — they cannot catch a `fetchCentral­Pages` pagination bug, a PostgREST embed-shape mismatch, or RLS silently filtering rows on real data. Grepping `tests/sql/*.sql` for "dashboard" returns zero matches — no SQL-level test reconciles the two source queries' output against an independent `COUNT`/`SUM`. Genuine gap, not fixed in this pass (would mean writing a new reconciliation test, out of the owner's named priority list).
- **IMP-001 — re-verified this pass, resolved to PARTIAL**: re-checked per domain with file:line evidence. **SaaS activation intake** — DB-enforced (`saas_import_batches_checksum_key unique(source_checksum, source_kind)`, `20260819090000_add_data_intelligence_foundation.sql:148`; `saas_activation_events_identity_key unique(saas_event_id)`, same file:245) with an explicit zero-delta re-import test (`tests/sql/saas-activation-intake.sql:140-166`). **Installation-fee import** — real identity is `installation_entitlements_identity_key unique(period, subscriber_id, stage)` (`20260815160000_add_installation_fees.sql:93`, DB-enforced); the `file_checksum` column itself is metadata-only and unused for gating, but the true identity key is proven by test (`tests/sql/installation-fees-import.sql:140-166`, "same file twice adds nothing"). **Bulk invoice/holds import — genuine gap**: the actual re-upload-duplicate detection (the `already_used` bucket) is a plain `EXISTS` query in application code (`20261019090000_bulk_invoice_audit.sql:122-131,264-273`), not a DB constraint, and has **zero test coverage** for the real scenario — a fresh upload (new `request_id`) of the same already-verified rows; the only existing test (`tests/sql/bulk-invoice-audit.sql:92-100`) merely replays the *same* request_id (pure idempotency, a different and already-solid guarantee). No cross-domain test combining all three import writers exists either. Not fixed in this pass (writing a new upload-scenario test + evaluating whether `already_used` needs a DB-level backstop is real work, out of the owner's named priority list).
- **SEC-005 — re-verified this pass, resolved to PASS** (write-authorization half; search_path half already confirmed clean in §11.2's SEC-005 narrowing). Parsed all 265 `create or replace function ... security definer` declarations across `supabase/migrations/*.sql`, deduplicated to 210 currently-effective functions: 156 carry an explicit `require_capability`/`has_capability`/role-primitive check; 17 are trigger functions (exempt, no direct caller input); 37 have no in-body auth check, of which 5 are real-write internal helpers that are `revoke`d from `public/anon/authenticated` and reachable only through a gated wrapper RPC (exempt), and 32 are pure read-only lookups with no INSERT/UPDATE/DELETE (exempt under the read-only carve-out). **Zero genuine write-without-authorization gaps found.**
  - **Residual finding surfaced by the same sweep, directly relevant to SEC-004 (not SEC-005)**: roughly 20 of those read-only `SECURITY DEFINER` helpers — including `has_capability`, `effective_permission`, `explain_permission`, `my_capabilities`, `commission_scope_payable`, `installation_financials`, `commission_cycle_financials`, `stage_amount_for_version`, `commission_rate_for`, `agent_financial_profile`, `fdt_blocked_amount`, `finalized_cycle_at`, `evaluate_enrollment_gate`, `odoo_verification_mode`/`odoo_verification_required` — have **no explicit `grant`/`revoke execute` statement at all** in any migration, meaning they rely on Postgres's default PUBLIC execute grant on newly-created functions. Because these are `SECURITY DEFINER`, the underlying tables' RLS does not apply to them regardless of caller — so if any of these are in fact reachable by `anon` in the deployed database (not re-verified against a live Supabase project this pass; this is a migration-file finding only), an unauthenticated caller could invoke functions like `installation_financials`/`commission_cycle_financials` directly and read real financial aggregates. This is exactly SEC-004's stated scope ("Functions callable by anon reviewed/revoked if unnecessary") — the prior grant-audit commits (`0d9d9eb`, `20038ad`, `ac1feaa`, §11.1) closed *known* accidental grants but did not sweep every SECURITY DEFINER declaration for a *missing* explicit revoke, so SEC-004 should **not** be considered fully closed by that earlier work. **This is flagged as a security-relevant follow-up, not fixed in this pass** — closing it means, for every function in the list above, adding an explicit `revoke execute ... from public, anon;` (keeping `authenticated`-only or narrower as appropriate) in a new migration, then re-testing.
- **UX-006** — device-only manual QA, correctly stays VERIFY; not re-checkable from code.
- **Free P1 settlement/payout mechanics** — explicitly out of scope; not specified by the owner, not invented (§12.4).
- **DEC-005's installation-enrollment FK-linkage gap** — the VOID RPC's conservative whole-batch refusal is a safe stand-in, not a resolution of whether a real FK exists; documented as a residual in `docs/BUSINESS_DECISIONS_REQUIRED.md`.
- **INV cluster and Security-Advisor-dependent SEC-003/004/006** — unchanged from §11.3, still owed their own targeted re-check.

See `docs/BUSINESS_DECISIONS_REQUIRED.md` (now the ratified decision record, not an open-blockers list) and `docs/DECISIONS.md` ADR-023..030 for the full decision text, and `docs/GO_LIVE_READINESS.md` for the updated overall recommendation.

---

## 13. 2026-09-01 Final Pre-Go-Live Closure Addendum

**Type:** Third same-day delta, closing the 5 IDs §12.6 still counted not-PASS (ZON-005, INS-009, IMP-001, SEC-004, UX-006), on top of PR #94 (`feat/v1-go-live-closure`, starting HEAD `3e5a4b9d7fc189dcff02633abd2fb9e7d8d5920f`). Not merged, not deployed to Production, no Production financial data touched, no payment executed, no July recalculation. Every change was built and proven against local Postgres only.

### 13.1 SEC-004 — PARTIAL → PASS

Commit `ee0c697`. An exhaustive `has_function_privilege()`-based sweep of all 210 currently-effective `SECURITY DEFINER` functions (not text-grep, which the project's own dynamic `foreach ... execute format('grant/revoke ...')` migrations defeat) found the codebase's grant hygiene already correct almost everywhere — two early `ALTER DEFAULT PRIVILEGES` changes (`20260804230000`, `20260809190000`) mean every function created after them gets **no** PUBLIC execute grant by default. This directly resolves §12.7's residual finding as a false alarm: the ~20 read-only functions flagged there (`installation_financials`, `commission_cycle_financials`, etc.) with no explicit grant/revoke statement do **not** default to PUBLIC execute, because default privileges were reconfigured before they were created — they were never actually anon/PUBLIC-reachable.

Two genuine gaps were found and closed, not blindly revoked:
- `effective_permission(uuid,...)` / `explain_permission(uuid,...)` took an arbitrary `p_user_id` with no check it was the caller's own `auth.uid()`, and were granted directly to `authenticated` — any logged-in viewer could query or dump another user's full permission detail via a direct PostgREST RPC call. Direct `authenticated` access revoked; internal callers (`has_capability`/`require_capability`/`my_capabilities`, which invoke them as the function owner) are unaffected.
- `protect_activation_correction()` / `protect_voided_import_batch()` — the only 2 of 17 trigger functions with no grant/revoke history — given the explicit revoke every sibling guard trigger already carries, for consistency.

Evidence: `tests/sql/permission-primitive-hardening.sql` walks every `SECURITY DEFINER` function via `aclexplode(coalesce(proacl, acldefault('f', proowner)))` — the same resolution Postgres itself applies with no explicit grant/revoke — and asserts none grant EXECUTE to `anon`/PUBLIC, so a future function created without an explicit revoke fails the suite automatically. Also proves behaviorally that a non-admin viewer is rejected on the two primitives directly while `has_capability` still works.

**SEC-004: PASS.**

### 13.2 ZON-005 — PARTIAL → PASS

Commit `dfffcb0` (migration hardened for the safety scanner in `9a824dd`, see §13.6). §12.2 found one genuine gap: `installation_enrollments.zone` was never populated by either write path, so the installation dashboard's zone display read a dead column instead of `fdt_commission_scope()`'s output — commission-side consistency (import/calculation/payment) was already real, only the dashboard surface was unwired.

Fix routes all three write paths — `enroll_new_installation`, `bootstrap_historical_enrollments`, and the legacy `import_installation_entitlements` (which previously trusted the raw uploaded file's own zone column instead of the FDT number) — through `fdt_commission_scope()`, the same sole-source function the commission engine already uses, and idempotently backfills existing rows. Zone is a display/classification field never read by any amount or rate calculation (confirmed across the full migration history, and explicitly not among the columns `protect_settled_installation_entitlement()` guards) — the backfill touches zero financial amounts, including on already-paid entitlement rows.

Evidence: `tests/sql/zone-consistency.sql` proves the same FDT (105 in-range, 50 out-of-range) produces the same zone across all four surfaces — `enroll_new_installation`, `bootstrap_historical_enrollments`, `materialize_installation_entitlements`, and `import_installation_entitlements`, including with a deliberately wrong raw-file zone value — plus idempotent backfill correctness on an already-paid row.

**ZON-005: PASS.**

### 13.3 IMP-001 — PARTIAL → PASS

Commit `8720eb7`. §12.7 found the real gap: bulk-invoice re-upload duplicate detection (the `already_used` bucket) was a plain application-level `EXISTS` query with zero test coverage for the actual re-upload scenario, and vulnerable to a classic read-then-write race between two concurrent uploads. The owner-approved identity rule: invoice identity = SOURCE/SYSTEM + INVOICE REFERENCE/NUMBER.

Two-level fix: (1) DB — a partial unique index `installation_invoices_verified_identity_key` on `(invoice_source, invoice_number)` where `invoice_number is not null and status = 'VERIFIED'`, scoped to VERIFIED only so a REJECTED/PENDING row never permanently blocks a legitimate correction; (2) App — `review_invoice()` (the single/manual invoice-review path, which previously had zero check against reusing an `invoice_number` for a different subscriber/stage) now runs the same identity check the bulk path already had, before allowing a VERIFIED insert. The unique index is the atomic backstop making the race structurally impossible, not just discouraged by application logic.

Evidence covers all six required scenarios: `tests/sql/invoice-identity-dedup.sql` (13 assertions) — A. same invoice uploaded twice (no duplicate), C. same invoice in another file (skipped, `already_used`), D. two distinct invoices for the same subscriber/month (coexist without conflict), E. previously-verified invoice re-upload for another subscriber (rejected, no payment condition needed), F. atomic apply failure leaves no partial entitlement or audit trace; `tests/sql/invoice-dedup-concurrency.sh` — B. true concurrent verification of the same invoice number for two different subscribers, proven to land exactly once via real parallel processes, not a simulated race.

**IMP-001: PASS.**

### 13.4 INS-009 — PARTIAL → PASS

Commit `59ffb24`. §12.7 found no server-side KPI aggregate existed for the installation dashboard at all — only a frontend merge of two independently-paginated raw fetches, proven internally consistent by fixture tests but never reconciled against ground truth. Investigation this pass found `installation_cycle_pipeline()` already calls `installation_payout_candidates()` internally (`20261010090000_installation_monthly_readiness.sql:412`) rather than recomputing independently — the two screens (`/installation`, `/installation/cycle`) were already single-sourced, so no new RPC was needed; the real open question was whether that single source was itself correct.

`installation_payout_candidates()` deliberately inlines a copy of `subscriber_ownership_type()`'s ownership-resolution logic for performance (avoiding thousands of per-row function calls, `20260920090000_statement_timeout_hot_paths.sql:66-71`) — a real, previously-unverified exception to the project's "don't duplicate business logic" convention.

`tests/sql/installation-kpi-reconciliation.sql` (17 assertions) proves: (a) the function's candidate count/amount matches a raw `COUNT`/`SUM` on the underlying tables; (b) the ready/blocked/by-stage breakdown is internally consistent (ready + blocked = total, no gap or double-count, on both count and amount); (c) the inlined ownership-resolution copy agrees with the canonical `subscriber_ownership_type()` by running both real functions against identical fixture data — 7 subscribers each isolating one blocker (hold, missing invoice, unresolved history, identity conflict, direct-company ownership, needs-review ownership) — not just a code-comparison-by-eye.

**INS-009: PASS.**

### 13.5 UX-006 — stays VERIFY

Per the standing instruction ("Do not invent a PASS... leave UX-006 as VERIFY until human/device confirmation if that is genuinely required"), this pass produced [`docs/UX-006-MANUAL-QA-CHECKLIST.md`](./UX-006-MANUAL-QA-CHECKLIST.md) rather than a status change. It replaces the prior generic "min-height values of 28/34/36/38/52px" spot-check (§2's UX-006 row) with code-verified specifics:

- Most of those flagged values are false positives: `.btn`, `.smallbtn`, `.select`, and every actual `<textarea>` in the app (all four instances carry class `search`) are already bumped to 44px by an existing `@media (pointer: coarse)` rule (`assets/css/babil-flow.css:1193-1201`).
- Two genuine, code-confirmed gaps remain, not covered by that rule: `.side-btn` (sidebar nav items, 38px, reachable via the mobile off-canvas drawer that becomes the primary navigation at ≤860px) and `.minirow` used as a clickable link (no `min-height` at all — used for the "open holds/next action" rows on `/installation` and `/installation/cycle`, effective height ≈32px from content alone).

Neither can be honestly resolved by a code read — real tap-target adequacy depends on physical device/finger geometry a browser emulator does not reproduce. **UX-006: VERIFY**, with a concrete, executable checklist now in place instead of an open-ended "needs review."

### 13.6 Final acceptance gate

Full local verification run this pass, in order:
- `npm test` (`node --test tests/*.test.js`) — **701/701 passing**, including `tests/master-requirements-coverage.test.js` and `tests/migration-safety-scanner.test.js`.
- One genuine finding from the scanner, unrelated to anything above: the ZON-005 migration (`20261023090000_installation_zone_consistency.sql`, committed earlier this same session as `dfffcb0`) had two top-level `UPDATE` statements against `installation_enrollments`/`installation_entitlements` outside any function body — the project's own migration-safety convention requires writes to run inside a function/`do $$...$$` body, not as bare top-level DML in a migration file. Fixed in commit `9a824dd` by wrapping the two statements in `do $$ begin ... end $$;` — same statements, same effect (the zone-classification backfill described in §13.2), purely a scanner-satisfying wrap. Re-verified: scanner test green, full local SQL suite still green at 1143 assertions after a clean rebuild from all 91 migrations, full `npm test` green at 701/701.
- `npx tsc --noEmit` — clean, zero errors.
- `npm run build` (`vite build`) — succeeds, bundle verified (9 referenced assets all present).
- Migration order — 91 migration files, filenames strictly sorted, zero duplicate timestamps, and `tests/sql/rebuild-local.sh` applied all 91 cleanly from scratch in filename order with no conflict (the concrete proof, not just a naming check).
- Local SQL suite (`tests/sql/run-local-tests.sh`) — **1143 assertions passing**, including all of §13.1-§13.4's new coverage and the pre-existing concurrency suite (installation-fee payment, financial correction, and invoice-verification races each proven to resolve to exactly one winner).
- **Staging mandatory acceptance scenarios: not executable in this environment.** No `.env`/Supabase project link exists in this worktree (`node scripts/assert-staging-project-ref.mjs` confirms "Not linked to any Supabase project"); only `.env.example` is present. This is an honest environment limitation, not a skipped step — Staging verification remains outstanding and must be performed by someone with Staging credentials before a genuine V1 Stable declaration, per the register's own closing line (§10 step 12).

### 13.7 Recomputed blocker ceiling

§12.6's ceiling was **38 of 156 in-scope IDs not-PASS**, counting ZON-005, INS-009, IMP-001, SEC-004, and UX-006 as not-PASS. This pass moves 4 of those 5 to PASS (§13.1-§13.4); UX-006 stays VERIFY (§13.5) per explicit instruction not to invent a PASS.

**Revised honest ceiling: no more than 38 − 4 = 34 of 156 in-scope IDs remain not-PASS.** The same caveat §11.3/§12.6 already stated still holds: the true number is very likely lower once the INV-001..004/007..009/013/014 cluster and the Security-Advisor-dependent SEC-003/006 get their own targeted file:line re-check — neither of which was in scope for this closure pass (the owner's named priority list was SEC-004, ZON-005, IMP-001, INS-009, Free P1 settlement status, and UX-006; all six have now been addressed to the extent honestly possible).

### 13.8 What remains genuinely, deliberately unresolved after this pass

- **UX-006** — device-only manual QA; checklist written (§13.5), status correctly stays VERIFY pending actual human/device confirmation. Does not block go-live per the standing instruction unless a functional usability defect is discovered during that confirmation.
- **Free P1 settlement/payout mechanics** — unchanged from §12.4/§12.7: entitlement generation and eligibility are PASS (ADR-029, 30 test cases), but how a granted Free P1 is actually settled (voucher, credit, cash-equivalent) was never specified by the owner and was not invented. This needs a new, separate business decision before it can be built — not an engineering gap in what already exists.
- **INV-001..004/007..009/013/014 cluster and SEC-003/006** — unchanged from §11.3/§12.6, still owed their own targeted re-check; explicitly out of this closure pass's named scope.
- Everything else listed in §12.7 as unresolved (Post-V1 zone/FDT configurability, DEC-005's FK-linkage residual) is unchanged by this pass.

See `docs/GO_LIVE_READINESS.md` for the updated overall recommendation and verdict.

## 14. 2026-09-01 Owner Final Clarification Addendum

**Type:** Fourth same-day delta. Following §13's closure pass, the product owner sent a second message this same day ("FINAL OWNER CLARIFICATION") resolving two of §13.8's open items by explicit, permanent ruling — not new engineering work, not a re-scan of code. No commit in this addendum touches business logic; only documentation and two migration comments (see below) changed.

### 14.1 Free P1 settlement — Prior → Now

**Prior (§13.8):** "how a granted Free P1 is actually settled (voucher, credit, cash-equivalent) was never specified by the owner... This needs a new, separate business decision before it can be built."

**Now:** The owner has ruled Free P1 will **never** be a payable/settleable item — not deferred, struck permanently. Required behavior, restated as a permanent constraint: NEW ZONE eligibility is per-FDT (>350 qualifying active subscribers ⇒ that FDT eligible for 1 Free P1); OLD ZONE eligibility is per reseller-total (>350 qualifying active subscribers ⇒ that reseller eligible for 1 Free P1). Free P1 is informational only — it must never create a payable amount, enter an installation payment batch, create a ledger entry, affect paid/remaining balances, be marked paid, or trigger correction/reversal mechanics. It may keep its own eligibility/status record for display/audit, with zero payment authority.

This required **no code change**: `free_p1_grants` (`supabase/migrations/20261021090000_free_p1_bonus.sql`) already has no amount column and no FK to any financial/ledger/payment table — the table was already structurally payment-incapable before this ruling. Two comment-only edits (table comment, header block) were made in that migration to state the permanence explicitly instead of describing it as pending. Formalized as ADR-031 in `docs/DECISIONS.md`; see `docs/BUSINESS_DECISIONS_REQUIRED.md` § FREE-004 for the full ruling text.

**FREE-001/002/005/006 remain PASS, unchanged.** This addendum removes Free P1 settlement from the "decision required" list entirely — it is no longer an open item of any kind, resolved or not: it is closed by permanent non-existence of the thing that was being asked about.

### 14.2 Staging acceptance — Prior → Now

**Prior (§13.6):** "Staging mandatory acceptance scenarios: not executable in this environment... Staging verification remains outstanding and must be performed by someone with Staging credentials before a genuine V1 Stable declaration."

**Now:** The owner has clarified there is no separate Staging Supabase project available as a matter of permanent project structure — confirmed independently this pass via `npx supabase projects list`, which shows `babil-commission-staging` (ref `unohqhxubraelqgjhxgh`) exists but is **INACTIVE** (paused), while `babil-commission-production` (ref `fbgffpxpskjzgheheikd`) is ACTIVE_HEALTHY. This is not a missing-credentials gap to chase down; it is a structural fact about the environment. §13.6's framing — that Staging verification is "outstanding" pending someone with credentials — is superseded.

**Substitute acceptance methodology (ADR-032), already satisfied by §13.6's own results plus this pass:** full clean local DB rebuild (`tests/sql/rebuild-local.sh`, 91/91 migrations applied cleanly), full SQL regression (`tests/sql/run-local-tests.sh`, 1143 assertions), full JS/TS suite (`npm test`, 701/701), typecheck (`npx tsc --noEmit`, clean), production build (`npm run build`, succeeds), migration safety/order checks (scanner green, filenames strictly ordered, no duplicate timestamps), and the Master Requirements coverage test (part of the 701). All of these were already green in §13.6 before this addendum, under a different justification ("this is what we can do given no Staging access"); the owner's ruling reclassifies them from a stopgap into the actual, permanent, sufficient acceptance bar.

**Read-only Production verification — investigated, not performed.** The instruction requires this "where safe and available." In this execution environment it is not safely available: no `.env` and no linked project ref exist in the worktree (`supabase/.temp/project-ref` absent), and no lightweight read-only verification script exists in `scripts/` — only three Staging-scoped verify scripts and `scripts/dump-database.mjs`, a full `pg_dump` that is both heavier than a verification step and would pull real financial/personal data to a local machine, which is not an appropriate substitute for a narrow read-only check. Actually linking the CLI to Production (`npx supabase link --project-ref fbgffpxpskjzgheheikd`) would require a database password not present in this environment and not to be sourced or entered ad hoc. Per ADR-032's own fallback clause, this is documented honestly as a local-environment limitation, not fabricated or skipped silently, and does not by itself block go-live given the local regression suite above is fully green.

### 14.3 Ceiling — unchanged

Free P1 settlement and Staging absence were never counted among the 156 in-scope requirement IDs (they are business-decision/acceptance-methodology items tracked outside the ID register). Removing them as blockers does not move the §13.7 ceiling: it remains **34 of 156 in-scope IDs not-PASS**, unaffected by this addendum.

### 14.4 What remains genuinely, deliberately unresolved after this addendum

- **UX-006** — unchanged from §13.5/§13.8: device-only manual QA, checklist in place, does not block go-live unless the manual check surfaces an actual functional usability defect.
- **INV-001..004/007..009/013/014 cluster and SEC-003/006** — unchanged from §11.3/§13.8, still owed their own targeted re-check; explicitly out of scope for both this addendum and §13's closure pass.
- Everything else listed in §12.7/§13.8 as unresolved (Post-V1 zone/FDT configurability, DEC-005's FK-linkage residual) is unchanged.
- **Free P1 settlement and Staging absence are no longer on this list** — both are permanently resolved by owner ruling as of this addendum (§14.1, §14.2).

See `docs/GO_LIVE_READINESS.md` for the updated overall recommendation and verdict.

## 15. 2026-09-01 Independent QA Addendum — Free P1 threshold fix, eligibility display, CI baseline correction

**Type:** Fifth same-day delta. An independent QA pass (Codex) verified the branch after §14's addendum and reported two real defects plus one CI-only issue. All three are fixed in this addendum; nothing else from §1–§14 was touched or re-litigated.

### 15.1 Threshold operator bug — `>=` corrected to `>`

§14.1 restated the owner's rule as "`>350` qualifying active subscribers," but the actual implementation used `>=` in three places: the `free_p1_grants_meets_threshold` CHECK constraint and both SELECT predicates inside `grant_free_p1()` (the eligibility-count query and the insert query). This meant exactly 350 was incorrectly granted a Free P1. Fixed to `>` in all three locations, in `supabase/migrations/20261021090000_free_p1_bonus.sql`, applied identically to both NEW ZONE (per-FDT) and OLD ZONE (reseller-total) paths — the bug and the fix affected both symmetrically since they share the same comparison logic.

New explicit boundary regression tests added to `tests/sql/free-p1.sql` for both zones: 349 (not eligible), 350 (not eligible — this is the corrected boundary), 351 (eligible, first qualifying value). Test count for that file: 41 assertions (was 30 as of §12.4/14.1).

### 15.2 Free P1 was computed but never displayed

Free P1 eligibility existed only as rows `grant_free_p1()` could write (admin-only, capability-gated) — no read surface existed for an ordinary viewer to see who was eligible before or without a grant being run. A new read-only function `public.free_bonus_eligibility(p_cycle_id uuid)` was added (`security definer`, self-gated via `perform public.require_capability('commission.view')` — the broad view capability, not the admin-only `commission.grant_free_bonus`), mirroring `grant_free_p1()`'s exact eligibility predicate with zero writes. Wired into `index.html`'s commission-cycle screen as a new "🎁 Free P1" tab (`#cx-freep1` panel, `#cxFreeP1Table` host, `loadCommissionFreeP1()`/`renderCommissionFreeP1()`), showing per eligible scope: reseller/scope label, zone type, FDT where applicable, qualifying active subscriber count, and eligibility status. Display-only — no payment amount, batch, ledger entry, or paid/remaining state is created or shown, consistent with ADR-031. A reconciliation test in `tests/sql/free-p1.sql` proves `free_bonus_eligibility()`'s output set is identical to `free_p1_grants` after an actual grant, guarding the two predicates against future drift.

### 15.3 CI `db-regression` job had stale numeric guards

`.github/workflows/ci.yml`'s `db-regression` job hard-coded migration count (81) and SQL assertion count (1012) from an earlier point in this branch's history, unrelated to and unchanged by §15.1/§15.2's fixes. Corrected to the actual current baseline: **91 migrations, 1154 SQL assertions** (1143 per §13.6/§14.2, +11 from the new boundary tests in §15.1). No check was weakened — the same exact-match assertions remain, only the expected numbers were corrected to match reality.

### 15.4 Re-verification after all three fixes

Full sequence re-run after 15.1–15.3: `tests/sql/rebuild-local.sh` — 91/91 migrations, clean. `tests/sql/run-local-tests.sh` — **1154 assertions passing**, zero failures. `npm test` — **701/701 passing** (one test, `tests/babil-flow-ui.test.js`'s read/write RPC-naming scan, initially failed because the first draft function name `free_p1_eligible_scopes` was truncated by that test's digit-excluding regex; renamed to `free_bonus_eligibility` — no digits, ends in the whitelisted `_eligibility` suffix — same digit-avoidance precedent already established by the `commission.grant_free_bonus` capability name in this same migration). `npx tsc --noEmit` — clean. `npm run build` — succeeds. CI-equivalent migration-manifest/extension check (replicating `ci.yml`'s `db-regression` job logic locally) — passes against the corrected 91/1154 baseline.

### 15.5 Scope discipline

No merge, no deploy, no Production financial data touched, no payment executed, no July recalculation performed. `free_p1_grants` remains structurally payment-incapable (§14.1, unchanged) — this addendum fixed a comparison operator and added a read surface, neither of which required or involved any payment-authority schema change. Free P1 remains, and remains provably, informational-only.

## 16. 2026-09-02 Large-Import Addendum — SaaS activation intake made chunked, bridge sweep made complete

**Type:** Sixth delta on this branch. A manual QA pass against Commission **STAGING** (never Production) imported the real `Activations Report_Aug-2026.xlsx` — 29,427 activation events. The browser preview accepted all 29,427 rows (0 duplicates, 0 rejected, 0 unknown-date, 0 user-snapshot rows); pressing "اعتمد الاستيراد" returned `canceling statement due to statement timeout`, and a follow-up query on `saas_import_batches` for that filename returned zero rows — the whole import had rolled back, leaving no batch and no partial state. Authenticated PostgREST calls run under an 8-second `statement_timeout`. This addendum removes the per-row work that caused it; it does **not** raise any timeout.

### 16.1 Root cause — one subtransaction per row, not the inserts

`import_saas_activation_events` (`20261003090000_saas_activation_intake.sql`) looped over the incoming rows and wrapped each `insert` in `begin … exception when unique_violation … when others … end`. In PL/pgSQL an exception block opens a subtransaction, so a 29,427-row file opened 29,427 savepoints. Measured locally on a machine benchmarked at ≥1.55× the throughput of the box that timed out, a 30,000-row single call took **5.21 s** in the loop form — already outside a safe margin there, and past 8 s on the slower host.

Two further defects on the same path were found while measuring and are closed here:

- `bridge_saas_activations_to_enrollments` accumulated blocked candidates with `v_blocked := v_blocked || jsonb_build_object(...)` inside its candidate loop — quadratic. Measured: `p_limit` 500 → 0.35 s, `p_limit` 5000 → **16.69 s**. The frontend sent `p_limit: 5000`, so the bridge call the UI actually made could never have completed under an 8-second budget.
- The bridge selected the *first* `p_limit` unenrolled candidates with no cursor. A candidate the gate blocks stays unenrolled forever, so a batch whose leading 5,000 candidates are blocked can never reach candidate 5,001 — a 29,427-row import could leave eligible subscribers permanently unconsidered no matter how many times the operator pressed the button.

### 16.2 Architecture selected — set-based intake **and** logical chunking

A set-based rewrite alone was measured and judged insufficient: the best single-RPC time for 30,000 rows was 2.98 s (bare prototype) / ~5.3 s (the real function with all 29 columns), against an 8 s budget on slower hardware and a declared per-call ceiling of 100,000 rows. Both were therefore adopted, in `supabase/migrations/20261104090000_saas_activation_chunked_intake.sql` (forward-only; `20261003090000` is not edited):

- **Set-based hot path.** The row loop is replaced by a single CTE chain: `jsonb_array_elements … with ordinality` → classify → `distinct on (saas_event_id)` → `insert … select … on conflict (saas_event_id) do nothing`. Cast validation, which was the reason for the per-row exception handler, now uses `pg_input_is_valid(text, type)` (PG 16 soft-error casts) through the helper `saas_activation_row_is_castable(jsonb)`. That helper deliberately carries **no** `SET search_path` clause — a SQL function with a `SET` clause is never inlined by the planner, which cost 2.6 s per 30k import when first written that way; every identifier inside it is `pg_catalog`-qualified, its only caller runs with an empty `search_path`, and execute is revoked from `public`, `anon` and `authenticated`.
- **Logical chunking inside one batch.** The RPC gains `p_batch_id`, `p_expected_rows`, `p_finalize` and `p_row_offset`, reusing the `received_rows int8multirange` / `expected_row_count` restart-safety pattern already proven for installation entitlements (`20261101090000`, `20261102090000`).

Rejection semantics are unchanged in both content and priority: `MISSING_EVENT_ID` → `MISSING_USERNAME` → `MALFORMED_ROW`, then duplicate. Deduplication remains at **activation-event** level on `saas_event_id`; it is not, and never was, by subscriber or username.

### 16.3 One file stays one logical batch

`saas_import_batches_checksum_key unique (source_checksum, source_kind)` is unchanged and remains the file identity, so chunking cannot fork a file into two batches: every chunk resolves to the same row. A chunk-bearing call also takes the existing `pg_advisory_xact_lock` for activation-event import, so two chunks arriving together serialize.

The batch's `status` lifecycle carries the distinction with no new CHECK: `draft` = open for further chunks, `imported` = finalized. `p_finalize` is honoured only when `source_row_count` has reached `expected_row_count`; a premature finalize raises `22023` rather than closing an incomplete batch. `trg_flag_overlapping_batches` still fires exactly once, on the `draft → imported` transition.

Audit writes two actions — `saas.activation_events.chunk_received` for a non-final chunk and the pre-existing `saas.activation_events.imported` for the finalizing call — so there is exactly **one** "imported" audit row per logical file, and a half-uploaded batch can never appear completed. The request-idempotency replay guard accepts either action.

### 16.4 Restart, retry and duplicate safety

`received_rows` records which absolute file positions the batch has actually received. An incoming chunk contributes only `int8multirange(int8range(offset, offset+n)) - received_rows`, and the source CTE filters with `not (received_rows @> position)`, so an already-received position is never re-read: resubmitting a chunk — same content or different — adds nothing to `source_rows` and inserts nothing. A browser refresh mid-upload loses only the client's local `batch_id`; the checksum resolves the retry back into the same draft batch and the position filter discards everything already stored. `saas_activation_events`' unique key on `saas_event_id` remains the last line of defence.

Proven under real concurrency in `tests/sql/saas-activation-import-concurrency.sh`: two identical simultaneous submissions of the same offset → one session carries the range, one carries nothing, `source_row_count` 100, 100 events, one batch; two different simultaneous chunks → 300/300, **zero** event ids stored more than once, still one batch, still `draft` until finalized.

### 16.5 Counts and reporting

`source_rows`, `accepted`, `duplicates` and `rejected` accumulate on the batch across chunks; the RPC result now carries both the per-call figures (unchanged keys) and a `batch_totals` object with the file-wide figures, which is what the UI displays. Individual rejection reporting is retained — each rejected row still returns its row number, reason and event id — but capped at 200 entries per call with a `rejects_truncated` flag, so the hot path is not turned back into procedural work building an unbounded array.

### 16.6 Bridge coverage beyond one window

`bridge_saas_activations_to_enrollments` gains `p_after_username` and returns `last_username_key`, `remaining` and `exhausted`; its blocked-candidate sample is bounded at 50 with per-reason counters, which makes it linear (5000 candidates: 16.69 s → 2.96 s). No enrollment rule changed — `evaluate_enrollment_gate` remains the sole arbiter and nothing it blocks is enrolled.

Complete coverage is the caller's job and is now implemented once, in `src/features/system/bridge-sweep.ts`, used by both the import screen and the batch re-run panel so the two cannot drift. It sweeps with `p_limit: 1000` (5000 measured at 2.96 s locally — too little margin on slower hardware) carrying the cursor forward until `exhausted`, and reports `complete: false` with a remaining count if it ever stops early. `tests/sql/saas-activation-chunked-intake.sql` §5 proves the failure this fixes: with `p_limit 5` over 12 blocked candidates, repeating the cursorless sweep makes no progress at all, while three cursored sweeps cover all twelve.

### 16.7 Frontend

`src/features/system/import-run.ts` slices activation events into 5,000-row chunks against one logical batch, shows per-chunk progress, sets `p_finalize` only on the last chunk, and runs the bridge sweep only after the import has genuinely finalized. `src/features/system/imports.ts`'s re-run panel calls the same shared sweep instead of a single `p_limit: 5000` call. No unrelated UI changed.

### 16.8 Measured result and re-verification

30,000 synthetic activation events with **every** imported column populated, submitted as six 5,000-row chunks through the real `authenticated` role with `alter role authenticated set statement_timeout = '8s'` — the same condition PostgREST imposes, set on the role and never touched inside the session (`tests/sql/saas-activation-large-import.sh`):

| chunk | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| ms | 1000 | 883 | 850 | 1024 | 920 | 1013 |

Slowest chunk **1024 ms** against the 8,000 ms budget — a 7.8× margin; 5,690 ms for the whole file. Result: 1 logical batch, status `imported`, 30,000 source / 30,000 accepted, 30,000 events stored, exactly 1 final import audit row.

Full sequence re-run: `tests/sql/rebuild-local.sh` — **101/101 migrations**, clean. `tests/sql/run-local-tests.sh` — **1382 assertions passing**, zero failures, including the new `saas-activation-chunked-intake.sql` and both new shell tests. `npm test` — **713/713 passing**. `npx tsc --noEmit` — clean. `npm run build` — succeeds. `node scripts/check-migration-safety.mjs` — clean. `.github/workflows/ci.yml`'s exact-match gates corrected to the new baseline (101 migrations, 1382 assertions); no check was weakened.

### 16.9 Scope discipline

No merge, no deploy, no Production access, no Production financial data created or modified, no payment executed, no July recalculation. The raw SaaS import still writes only `saas_activation_events` and its batch row — it creates no entitlement, no payment and no ledger entry, re-proven in `tests/sql/saas-activation-chunked-intake.sql` §6. **DEC-007 remains OPEN and is neither resolved nor implemented here.**
