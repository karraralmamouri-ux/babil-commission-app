# Babil Commission App — Master Requirements Register & Final Truth Report

**Status:** Canonical project truth draft — 2026-08-28  
**Intended canonical repo path:** `docs/MASTER_REQUIREMENTS_REGISTER.md`

## Governance
This file is the single requirements source of truth for Babil Commission App. No implementation, audit, PR, release, or “V1 Stable” verdict is valid unless it is reconciled against every requirement in this register.

### Status vocabulary
PASS / PARTIAL / MISSING / VERIFY / DECISION REQUIRED / REPLACED / CANCELLED BY AGREEMENT / OUT OF SCOPE — OPERATIONS

### Mandatory process
Every new user clarification must first receive a requirement ID and be added here before implementation begins. Requirements are never deleted; superseded requirements stay visible as REPLACED.

## Product scope
- All financial/accounting/admin requirements are in CURRENT SCOPE.
- Only work that turns the product into a full CRM/Operations system is OUT OF SCOPE.
- Supabase is the financial/data Source of Truth.
- Browser/localStorage is not authoritative financial truth.
- GitHub Pages hosts frontend only; secrets/admin logic stay server-side.
- No production experiments that change money, recalculation, or create fake financial test data.
- Posted/paid financial history is immutable; corrections/reversals preserve original history.

## Configuration / no-hardcoding
- CFG-001: Any business rule that can change must not be hardcoded in JS/TS/SQL constants or numeric conditions. **MISSING / AUDIT REQUIRED**
- CFG-002: OLD ZONE / NEW ZONE classification must be managed from settings/master data. **MISSING**
- CFG-003: Admin can add future FDTs/cabinets without code changes or migrations. **MISSING**
- CFG-004: Admin can define FDT/cabinet ranges or explicit lists and classify them OLD/NEW. **MISSING**
- CFG-005: Admin can associate FDT/range with reseller/owner/scope where required. **MISSING / VERIFY**
- CFG-006: Mutable rates/tiers/thresholds are versioned settings/master data. **VERIFY**
- CFG-007: Values like the free-P1 threshold 350 are settings if business may change them. **VERIFY**
- CFG-008: Mutable grace periods/operational thresholds belong in settings unless explicitly permanent. **VERIFY**
- CFG-009: Material rule changes require effective dates so old periods are not rewritten. **PARTIAL / VERIFY**
- CFG-010: Financially material configuration changes require capability, actor, timestamp, reason and audit. **VERIFY**

## Users / permissions
- USR-001: Admin can create accounts in-app. **PASS**
- USR-002: Admin can manage role/status/password in-app. **PASS**
- USR-003: Accountant can pay but not freely edit master financial data. **PASS / VERIFY ACCEPTANCE**
- USR-004: Monitor/viewer remain read-only unless explicitly granted capability. **PASS / VERIFY**
- USR-005: Profiles/roles are server-managed. **PASS**
- USR-006: Last active admin protected. **PASS**
- USR-007: Session persists and refreshes correctly. **PASS**
- USR-008: Protected routes wait for capability readiness. **PASS**

## NEW / EXISTING classification
- CLS-001: Authoritative classification is server-side. **PASS**
- CLS-002: Trusted historical registry hit means EXISTING. **PASS**
- CLS-003: UNMATCHED never silently becomes NEW. **PASS**
- CLS-004: CONFLICT/NEEDS_REVIEW remain unresolved. **PASS**
- CLS-005: activations_count alone never determines NEW. **PASS**
- CLS-006: Incomplete/unknown source cannot authorize NEW. **PASS**
- CLS-007: Loan alone does not create installation entitlement/P1. **PASS**
- CLS-008: NEW requires resolved identity, no prior historical evidence, qualifying-event conditions, and complete source. **PASS**
- CLS-009: NEWNESS and activation eligibility are separate questions. **PASS**
- CLS-010: Identity bootstrap/matching is capability-gated and explicit. **PASS**
- CLS-011: Cross-username identity merge policy. **DECISION REQUIRED — CURRENT SCOPE**
- CLS-012: Identity correction must not rewrite posted history. **VERIFY**

## Commission
- COM-001: Commission and installation-fee domains are financially separate. **PASS**
- COM-002: Final commission calculation is server-authoritative. **PASS**
- COM-003: Tier population counts subscriber once. **APPROVED / VERIFY ENGINE**
- COM-004: Same subscriber may earn commission on multiple distinct qualifying activations in one cycle. **APPROVED / VERIFY ENGINE**
- COM-005: Duplicate same activation event counts once. **APPROVED / VERIFY ENGINE**
- COM-006: Dedup uses activation/event identity, never subscriber identity. **APPROVED / VERIFY ENGINE**
- COM-007: Raw SaaS events should be retained/re-derivable. **VERIFY**
- COM-008: Unexpected/direct-company rows must not silently vanish. **VERIFY**
- COM-009: Define UNIQUE ACTIVE USER for tier basis. **DECISION REQUIRED — CURRENT SCOPE**
- COM-010: Active-user definition uses trusted persisted source evidence. **REQUIRED**
- COM-011: Mutable active-user formula belongs in config/effective dates. **REQUIRED**
- COM-012: Define NEW ZONE tier grouping (per FDT/per FDT-owner/other). **DECISION REQUIRED — CURRENT SCOPE**
- COM-013: Tier grouping must be configuration-driven. **MISSING / REQUIRED**
- COM-014: Mutable commission rates/tier boundaries are server-managed/versioned. **VERIFY**
- COM-015: Historical calculations retain scheme/rule version used at the time. **VERIFY**

## Zone / FDT
- ZON-001: Zone is not permanently inferred from hardcoded 94–119. **REPLACED CURRENT TEMP LOGIC**
- ZON-002: Settings define OLD/NEW per cabinet/FDT. **MISSING**
- ZON-003: Future FDTs can be added without deployment. **MISSING**
- ZON-004: Range-based and/or explicit-cabinet assignment supported. **REQUIRED**
- ZON-005: Same configured scope is used consistently by import/calculation/dashboard/payment. **VERIFY**
- ZON-006: Unknown/unconfigured cabinet fails safe to REVIEW/UNCONFIGURED, never silently OLD. **VERIFY**
- ZON-007: Zone config changes are audited/effective-dated if money is affected. **REQUIRED**

## Installation fees
- INS-001: 13000 → P1 → 3,000 IQD. **PASS**
- INS-002: 10000 → P2 → 3,000 IQD. **PASS**
- INS-003: 7000 → P3 → 3,000 IQD. **PASS**
- INS-004: 4000 → P4 → 4,000 IQD. **PASS**
- INS-005: 0 → DONE → 0. **PASS**
- INS-006: Blank/unknown Remaining is never guessed. **PASS**
- INS-007: Installation fees are independent financial domain. **PASS**
- INS-008: Settled entitlement cannot be silently edited/deleted. **PASS**
- INS-009: Dashboard totals/eligible P1-P4 reconcile correctly. **VERIFY**
- INS-010: Entitlement rules are server-authoritative. **PASS / VERIFY**
- INS-011: Installation correction/reversal exists without mutating original posted money. **PASS**

## Invoice audit
- INV-001: Accounting uploads the COMPLETE invoice file, not only row-by-row manual review. **MISSING**
- INV-002: System parses file and previews before apply. **MISSING**
- INV-003: System bulk-matches invoice rows to subscribers/candidates. **MISSING**
- INV-004: Preview separates matched/unknown/duplicate/already-used/invalid/conflict. **MISSING**
- INV-005: No installation-fee payment without qualifying invoice. **PASS PRINCIPLE / VERIFY BULK**
- INV-006: Subscriber absent from qualifying invoice file remains unpaid for that invoice-driven installment. **PARTIAL**
- INV-007: Same subscriber can have >1 distinct qualifying invoice in same month. **REQUIRED / NOT PROVEN**
- INV-008: Each distinct qualifying invoice advances exactly one sequential stage. **REQUIRED / NOT PROVEN**
- INV-009: P3 + two invoices same month => P3=3,000 then P4=4,000, total 7,000. **REQUIRED / NOT PROVEN**
- INV-010: No subscriber+month one-payment constraint. **VERIFY DB**
- INV-011: Cannot advance past P4/DONE. **VERIFY**
- INV-012: Same stage cannot be paid twice in progression. **VERIFY**
- INV-013: Same invoice cannot be re-used/re-imported to create another installment. **MISSING / VERIFY**
- INV-014: Audit lineage invoice→subscriber→stage→amount→decision/payment. **PARTIAL / MISSING**
- INV-015: Decide invoice identity authority (Odoo/external/Babil). **DECISION REQUIRED — CURRENT SCOPE**
- INV-016: Invoice identity remains stable across reupload. **REQUIRED**
- INV-017: Evidence attachment/source-document access with explicit security model. **DECISION REQUIRED / MISSING — CURRENT SCOPE**
- INV-018: Decide upload/read capabilities, private/signed access, retention. **DECISION REQUIRED**
- INV-019: Bulk invoice import is separate from PDF/image evidence attachment. **REQUIRED DISTINCTION**

## Holds
- HLD-001: Upload Excel/CSV of blocked Subscriber IDs. **PASS**
- HLD-002: Preview before apply. **PASS**
- HLD-003: Valid/unknown/already-held/already-done/already-paid/duplicates separated. **PASS**
- HLD-004: Only valid IDs applied. **PASS**
- HLD-005: Held subscriber cannot be paid. **PASS**
- HLD-006: Bulk source/file name retained. **PASS**
- HLD-007: Release requires permission, reason, request ID and audit. **PASS**
- HLD-008: Holds never delete historical financial records. **PASS**

## Payments / corrections
- PAY-001: Central payment only through secure server RPC. **PASS**
- PAY-002: Atomic. **PASS**
- PAY-003: Idempotent via request ID. **PASS**
- PAY-004: Overpayment rejected. **PASS**
- PAY-005: Concurrency/conflicts guarded. **PASS**
- PAY-006: Audit created in trusted path. **PASS**
- PAY-007: Posted/paid records immutable. **PASS**
- PAY-008: Post-payment changes use correction/adjustment/reversal. **PASS**
- PAY-009: Installation correction/reversal UI exists. **PASS**
- PAY-010: Commission correction/reversal available from normal UI. **MISSING**
- PAY-011: Correction/reversal requires reason/actor/authorization/audit. **PASS / VERIFY**
- PAY-012: Legacy payment path cannot conflict with new engine. **PASS / VERIFY RETIREMENT**

## Cycles / recalculation
- CYC-001: Master-data changes do not silently recalculate. **PASS**
- CYC-002: needs_recalculation state/reason visible. **PASS**
- CYC-003: Recalculation explicit/authorized/audited. **PASS**
- CYC-004: No July recalc/financial mutation during verification. **PASS PROCESS RULE**
- CYC-005: Closed cycle with no posted/paid may reopen with authority+reason+audit. **VERIFY E2E**
- CYC-006: Closed cycle with posted/paid is immutable. **PASS PRINCIPLE**
- CYC-007: Calculated DRAFT needs explicit cancellation/recovery lifecycle. **MISSING**
- CYC-008: State transitions server-enforced. **VERIFY**

## Ownership
- OWN-001: Ownership is effective-dated. **PASS**
- OWN-002: Historical attribution uses owner at event time. **PASS / VERIFY PROD E2E**
- OWN-003: Current ownership change does not rewrite old money. **VERIFY**
- OWN-004: Installation P1–P4 history does not auto-transfer unless explicit business rule says so. **VERIFY**
- OWN-005: FDT/reseller assignment follows config/effective-date/audit policy. **REQUIRED**

## Imports
- IMP-001: Duplicate same event/file cannot duplicate financial result. **VERIFY ALL DOMAINS**
- IMP-002: Source completeness explicit; incomplete cannot authorize NEW. **PASS**
- IMP-003: Bad SaaS import batch has safe cancellation/void lifecycle. **MISSING / DECISION REQUIRED**
- IMP-004: Cancellation never deletes posted history. **REQUIRED**
- IMP-005: File checksum/content identity participates in duplicate-file detection. **VERIFY**
- IMP-006: Financially important raw source events are retained/reproducibly referenced. **VERIFY**
- IMP-007: Unknown/unmatched rows become visible exceptions, never silently dropped. **VERIFY**
- IMP-008: Import preview is read-only; apply is separate explicit action. **VERIFY**

## Free P1
- FREE-001: NEW ZONE one free P1 per qualifying FDT over approved active threshold. **VERIFY**
- FREE-002: OLD ZONE one free P1/subscription per reseller over approved active threshold. **VERIFY**
- FREE-003: Threshold 350 or future threshold is configurable if mutable. **REQUIRED / VERIFY**
- FREE-004: Active-customer definition is explicit/server-authoritative. **DECISION/ALIGNMENT REQUIRED**
- FREE-005: Free-P1 grant is audited and cannot duplicate for same qualifying unit/rule period. **VERIFY**
- FREE-006: Historical grants retain rule version used. **VERIFY**

## Historical exceptions
- HIST-001: 14 financial-mismatch subscribers remain blocked/unresolved; no auto-payment. **PASS**
- HIST-002: Clearing mismatch requires audited correction. **PASS PRINCIPLE**
- HIST-003: 5 blank Remaining remain unresolved/blocked; no inference. **PASS**
- HIST-004: 15 balanced subscribers with incomplete P4 detail remain resolved on accepted balance. **PASS**
- HIST-005: Missing historical P4 detail/date is never fabricated. **PASS**

## Archive / reports
- ARC-001: Archive KPI and detail reconcile from same server dataset. **OPEN — LIVE-04**
- ARC-002: Archive/import does not auto-publish merely because data matches. **PASS**
- ARC-003: Historical visibility comes from central truth. **PASS / VERIFY**
- ARC-004: Authoritative KPI never calculated from current paginated UI slice only. **PASS**
- ARC-005: Export/report totals reconcile with source ledger/payment/entitlement. **VERIFY**
- ARC-006: Audit “why” reason visible. **PASS**

## Security / recovery
- SEC-001: RLS protects central data. **PASS / HARDENING OPEN**
- SEC-002: Sensitive financial writes use guarded server RPCs. **PASS / REVIEW**
- SEC-003: Security Advisor findings must be closed or explicitly accepted before stable freeze. **OPEN**
- SEC-004: Functions callable by anon reviewed/revoked if unnecessary. **OPEN**
- SEC-005: SECURITY DEFINER objects get least-privilege/search_path/auth review. **OPEN / VERIFY**
- SEC-006: Leaked-password protection reviewed/enabled where available. **OPEN**
- SEC-007: Backup/recovery strategy must match current Supabase plan. **REQUIRED**
- SEC-008: Migration rebuild/test gates remain mandatory. **PASS**
- SEC-009: Production verification remains read-only unless explicitly approved financial operation. **REQUIRED PROCESS**

## UX
- UX-001: Arabic RTL financial app. **PASS**
- UX-002: Exceptions/blockers are visible, never silently omitted. **VERIFY**
- UX-003: Bulk financial workflows use Preview→Apply. **PASS HOLDS / MISSING INVOICES**
- UX-004: Normal supported financial corrections do not require DB console. **PARTIAL**
- UX-005: Auth/connection errors fail closed rather than false empty data. **PASS / VERIFY**
- UX-006: Final mobile usability/touch-target review before stable. **REQUIRED**
- UX-007: Settings UI exposes mutable business config safely. **MISSING**

## Explicitly out of scope
- OPS-001: Full CRM lead/opportunity inside Babil Commission. **OUT OF SCOPE — OPERATIONS**
- OPS-002: Full installation ticket/task scheduling for field teams. **OUT OF SCOPE — OPERATIONS**
- OPS-003: Field employee shift/task dispatch. **OUT OF SCOPE — OPERATIONS**
- OPS-004: Rebuilding Taskati/Odoo operational workflows. **OUT OF SCOPE — OPERATIONS**
- OPS-005: Broad operational case management unrelated to financial correctness. **OUT OF SCOPE — OPERATIONS**

## Replaced approaches
- localStorage financial truth → Supabase central truth.
- browser final money → server-authoritative calculation.
- hardcoded role booleans → capabilities.
- current-owner-only attribution → effective-dated ownership.
- direct client financial writes → guarded RPCs.
- edit/delete posted money → correction/reversal.
- silent recalculation → explicit recalculation lifecycle.
- permanent numeric 94–119 NEW-ZONE rule → configurable FDT/zone settings.
- invoice attachment treated as bulk invoice matching → two separate requirements.
- all deferred items assumed V2 → all financial/admin deferred items are now current scope.
- full Operations/CRM expansion → excluded from current closure.

## Confirmed current gaps
1. Configurable business rules and zone/FDT settings.
2. Bulk complete invoice-file audit.
3. Multi-invoice same-month sequential P-stage payment behavior.
4. Stable invoice identity/dedup and invoice→stage→amount lineage.
5. Commission-domain correction/reversal UI.
6. Safe cancellation/void lifecycle for bad import batches and calculated DRAFT cycles.
7. LIVE-04 archive KPI/detail reconciliation.
8. Security hardening.
9. Active-user definition (former D-03), now current scope.
10. NEW-ZONE tier grouping decision (former D-07), now current scope and configuration-driven.
11. Invoice identity authority (former D-10), now current scope.
12. Invoice evidence storage/access/retention (former D-11), now current scope.
13. Free-P1 verification/configuration hardening.
14. Ownership E2E proof.
15. Raw-import/checksum/no-silent-drop verification.
16. Final UX/mobile/settings acceptance.
17. Backup/recovery strategy.

## Explicit business decisions still required
- DEC-001: ACTIVE USER formula.
- DEC-002: NEW ZONE tier grouping.
- DEC-003: invoice identity authority.
- DEC-004: invoice evidence storage/security/retention.
- DEC-005: bad import cancellation semantics.
- DEC-006: cross-username subscriber identity resolution.

## Mandatory acceptance cases
1. OLD/NEW follows settings, not numeric constant.
2. Add future FDT in settings without deployment.
3. Effective-dated setting change leaves old closed period unchanged.
4. Same subscriber + two distinct commission activations => tier population +1, commissions +2.
5. Duplicate same activation => +0.
6. Full invoice file preview shows match/unknown/duplicate/already-used.
7. Subscriber at P3 + two distinct same-month invoices => P3=3,000 then P4=4,000, total 7,000.
8. Re-import same invoice identities => no extra payment.
9. No qualifying invoice => no installation payment.
10. Held subscriber => payment rejected.
11. Release hold => authority+reason+audit.
12. Posted payment cannot be edited/deleted.
13. Correction/reversal preserves original and creates traceable ledger relation.
14. Commission correction available from normal UI.
15. Closed cycle with posted payment cannot be destructively reopened.
16. Bad import safely voided per approved state machine.
17. Archive KPI equals detail under same filters.
18. Ownership change does not reassign old financial history.
19. Free P1 OLD/NEW cases are correct and non-duplicating.
20. Security Advisor has no unexplained critical/high-risk findings.
21. Backup/recovery procedure documented/tested.
22. Role/capability acceptance passes.
23. Mobile/settings workflows usable.
24. Production acceptance uses no fake financial data or unapproved payment/recalculation.

## Execution order
A. Commit this register and point stale status docs to it.  
B. Build configuration foundation (CFG/ZON).  
C. Close business decisions DEC-001..006.  
D. Build invoice engine + multi-invoice logic.  
E. Close commission correction UI, import/cycle cancellation, Free P1, ownership E2E.  
F. Reconciliation/security/backup.  
G. Run acceptance matrix and only then declare V1 Stable.

## Anti-forgetting contract
1. This file is the only canonical requirements list.
2. Every requirement has a permanent ID.
3. Requirements are never deleted; replaced/cancelled rules stay visible.
4. Every implementation prompt must cite requirement IDs.
5. Every PR description must list implemented IDs.
6. Tests should reference requirement IDs where practical.
7. Every release gate uses: ID → code evidence → DB evidence → test → UI → status.
8. Any status doc disagreeing with this register is stale unless this file is intentionally updated first.
9. “Implemented” requires evidence; similar feature names do not count.
10. “Deferred” requires explicit user approval; AI may not defer on its own.
11. “Business decision” means stop and record the decision; never invent a money rule.
12. Stable requires all current-scope requirements PASS, explicit accepted exception, or explicit cancellation by user.

## Current conclusion
The project’s financial foundation is strong, but requirements governance drift caused false closure counts and missed requirements. The main recovered gaps are bulk invoice audit, multi-invoice sequential installment logic, configurable zone/FDT/business rules, commission correction UI, safe cancellation lifecycles, and remaining business/security/recovery decisions.

Stable must be declared from **Requirements → Evidence reconciliation**, never from a repo-only audit.
