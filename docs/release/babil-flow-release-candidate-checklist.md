# BABIL FLOW — Release Candidate Checklist

**Audited SHA:** `4b975a6cffe7dff3c7a6d8f8373d0f8fc08d54e3`
**Audit date:** 2026-08-19
**Target:** `fbgffpxpskjzgheheikd` (production) · `ACTIVE_HEALTHY` · Postgres 17.6.1.155
**Method:** read-only queries against live production, plus rolled-back transactions for
destructive paths. No payment posted, no cycle finalized, no zone classified, no
historical row altered.

Every line is PASS / FAIL / BLOCKED / N/A. Numbers are measured, not asserted.

---

## Production health

| Check | Result | Evidence |
|---|---|---|
| Application HTTP | PASS | `/` → 200 |
| Static assets (8 files) | PASS | css, 5 js modules, vendor xlsx, config json → all 200 |
| Supabase project status | PASS | `ACTIVE_HEALTHY` |
| Auth service | PASS | `/auth/v1/settings` → 200 |
| REST unauthenticated | PASS | 401 without key |
| Console errors on load | PASS | none |
| Failed resources | PASS | none |
| External origins contacted | PASS | zero — no CDN, no font host |
| Core globals present | PASS | 15/15 |
| Presentation modules present | PASS | 5/5 |

## Authentication and session

| Check | Result | Evidence |
|---|---|---|
| Login screen renders | PASS | live, branded, RTL |
| Session persisted across reload | PASS | `tests/session-persistence.test.js` (11 assertions) |
| Token refresh on expiry | PASS | same suite |
| Network failure does not erase refresh token | PASS | same suite |
| Logout clears stored session | PASS | `signOut()` → `setSbSession(null)` → `localStorage.removeItem`, and it clears **even when the logout request fails** |
| Post-logout data access | PASS | no token → 42501 at grant level |
| Disabled account | PASS | `is_active` false → capability false (proven in RLS suite) |
| Interactive login as a real user | N/A | credentials not available to the audit; entering them is out of scope |

## Permissions

| Check | Result | Evidence |
|---|---|---|
| Role templates configured | PASS | admin / accountant / monitor / viewer, 44 capabilities, 80 grants |
| Admin authority | PASS | `fdt.manage`, `commission.finalize`, `agent.manage`, `audit.view`, `saas.import` |
| Accountant scope | PASS | `commission.prepare_payment` + `report.export` **true**; `fdt.manage`, `commission.finalize`, `agent.manage` **false** |
| Monitor / viewer | PASS | `commission.view`, `report.view` only |
| Explicit user GRANT elevates | PASS | rolled-back txn: false → true |
| Explicit DENY beats GRANT | PASS | rolled-back txn: true → false |
| Explicit DENY beats admin role | PASS | admin `commission.view` → false under DENY |
| Explainability | PASS | `explain_permission` names the override |
| No test grants left behind | PASS | `user_permission_overrides` = 0 |
| Server enforces, not just hidden buttons | PASS | accountant refused on `register_fdt` and finalize with 42501 |

## Commission

| Check | Result | Evidence |
|---|---|---|
| July cycle status | PASS | `UNDER_REVIEW`, `finalized_at` null, `closed_at` null |
| Tier basis vs qualifying events kept distinct | PASS | 4,413 unique subscribers vs 4,549 events |
| OLD ZONE → Agent scope | PASS | 2 scopes, all `AGENT` |
| NEW ZONE → FDT scope | PASS | 24 scopes, all `FDT` |
| No zone/scope crossover | PASS | mapping is exactly 1:1 |
| Unknown FDT never becomes OLD ZONE | PASS | 22,724 events `zone='unresolved'`, `scope_type='UNRESOLVED'` |
| Loan-3 never earns | PASS | 0 entitlements for `Loan-3` |
| Entitlements = snapshots | PASS | 4,549 = 4,549; 21,969,500 = 21,969,500 |
| Tier bands reconcile | PASS | t1 1,066 + t2 2,539 + t3 808 = 4,413 |
| Frontend is presentation only | PASS | no rate or band literal in delivered JS |

## Installation Fees

| Check | Result | Evidence |
|---|---|---|
| Subscriber registry intact | PASS | 5,693 |
| Historical stages preserved | PASS | 3,492 DONE + 2,196 ACTIVE = 5,688 enrollments |
| Historical never restarts at P1 | PASS | stage distribution unchanged from accepted baseline |
| No historical reconstruction | PASS | 17,117 rows / 54,828,000 IQD unchanged |
| Entitlements / invoices / holds / payments | PASS | all 0 — no cycle opened |
| Eligibility function live | PASS | `installation_entitlement_eligibility` present, SECURITY DEFINER, search_path pinned |

## FDT onboarding

| Check | Result | Evidence |
|---|---|---|
| Discovery works live | PASS | 119 cabinets, 22,724 events, 16,178 subscribers |
| Registered master | PASS | 24 cabinets, all `new` |
| Zone must be explicit | PASS | null zone → `22023 Zone must be stated explicitly as old or new` |
| Permission enforced | PASS | accountant → `42501 Capability fdt.manage is required` |
| No test cabinet left behind | PASS | `fdts where code like 'RC-%'` = 0 |
| No real FDT classified for testing | PASS | 119 remain unresolved by design |

## Exceptions

| Check | Result | Evidence |
|---|---|---|
| Reason / events / subscribers / impact | PASS | `report_commission_exception_impact` returns all four |
| UNREGISTERED_FDT | PASS | 22,724 events · 16,176 subscribers · 66,660,500 IQD indicative |
| UNKNOWN_AGENT | PASS | 2 events · 2 subscribers · 8,000 IQD |
| SOURCE_INCOMPLETE | PASS | 1 row, completeness UNKNOWN |
| UNKNOWN_PACKAGE | N/A | zero in July — all packages known |
| MISSING_INVOICE / HOLD | N/A | no installation cycle open |
| Owner and action per reason | PASS | `EXCEPTION_PLAYBOOK`, asserted by tests |
| No developer-escalation language | PASS | test fails on مطوّر/developer/engineer |
| Action destination | PASS | `UNKNOWN_FDT` → `fdtOnboarding` |

## Payments

| Check | Result | Evidence |
|---|---|---|
| Unfinalized scope cannot pay | PASS | all 26 scopes `payable: false` |
| Blocked money excluded | PASS | 21,969,500 remaining, none payable |
| No batches exist | PASS | commission and installation batch tables all 0 |
| Server revalidation present | PASS | `revalidate_commission_batch`, `revalidate_payment_batch` |
| Guards are SECURITY DEFINER with pinned search_path | PASS | 5/5 |
| Duplicate / overpay / stale batch | PASS | covered by DB suite (`commission-payout.sql`, concurrency scripts) |
| **No real payment posted** | PASS | `commission_paid` = 0.00 |

## Ledger and corrections

| Check | Result | Evidence |
|---|---|---|
| Amount mutation on posted entry | PASS | `42501 A posted financial entry is immutable` |
| Direction flip | PASS | refused, same guard |
| Delete posted entry | PASS | `42501 Financial ledger entries cannot be deleted` |
| Benign annotation permitted | PASS | `reason` update allowed by design |
| Ledger net after audit | PASS | 0 rows, net 0 — probes rolled back |
| Correction / reversal functions live | PASS | `reverse_financial_entry`, `record_commission_payment`, `record_installation_payment` |
| Idempotency and concurrency | PASS | DB suite: exactly one payment, exactly one reversal under concurrent attempts |

## Reports

| Check | Result | Evidence |
|---|---|---|
| Management Summary | PASS | returns; gross 21,969,500 |
| Commission Cycle Detail | PASS | 26 rows |
| Agent Financial Statement | PASS | returns |
| Installation Fees Detail | PASS | returns |
| Exceptions / Blocked | PASS | 3 reasons with impact |
| Audit / Corrections | PASS | returns |
| **Summary = detail = source** | PASS | gross 21,969,500 and tier basis 4,413 and events 4,549 identical across report detail, summary, snapshots, entitlements |
| No frontend repricing | PASS | UI reads server reports only |

## Exports

| Check | Result | Evidence |
|---|---|---|
| Export functions present | PASS | `export_commission_cycle`, CSV helpers in `reporting.js` |
| Column contract covered | PASS | `COMMISSION_EXPORT_COLUMNS`, `EXCEPTION_EXPORT_COLUMNS` under test |
| Excel workbook builds | PASS | `xlsx-vendor` + `central-month-workflow` suites |
| No secret or password in export path | PASS | `ct_password` dropped at parse; no password column exists anywhere |
| Live end-to-end export download | N/A | requires an authenticated session |

## SaaS import

| Check | Result | Evidence |
|---|---|---|
| Normal dates | PASS | parser suite |
| Compact timestamps (`2026-04-30 235650`) | PASS | parser suite |
| Excel Date cells | PASS | parser suite |
| Machine-timezone independence | PASS | 34/34 in 5 real timezones on Linux; reverted parser fails in 4 of 5 |
| Duplicate events | PASS | 29,289 events, 29,289 distinct ids |
| Corrupt header aliases | PASS | `irstname`, `lastnam`, `tnam`, `proile_name` covered |
| Loan-3 / unknown parent / unknown FDT | PASS | classified, never silently attributed |
| `ct_password` never persisted | PASS | in `FORBIDDEN_COLUMNS`; zero password-named columns in the database |

## Historical integrity

| Check | Expected | Measured | Result |
|---|---|---|---|
| Installation subscribers | 5,693 | 5,693 | PASS |
| Historical payment rows | 17,117 | 17,117 | PASS |
| Historical paid | 54,828,000 | 54,828,000 | PASS |
| Commission paid | 0.00 | 0.00 | PASS |
| Financial ledger net | 0 | 0 | PASS |

## Timezone

| Check | Result | Evidence |
|---|---|---|
| Business timezone declared once | PASS | `business_timezone()` = `Asia/Baghdad` |
| July window lower bound (inclusive) | PASS | `2026-06-30T21:00:00Z` |
| July window upper bound (exclusive) | PASS | `2026-07-31T21:00:00Z` |
| Session timezone cannot move the boundary | PASS | DB session is `UTC`; window still Baghdad |
| No event silently outside a cycle | PASS | 29,289 file events fully reconciled, no remainder |

## Performance (production, `EXPLAIN ANALYZE`)

| Path | Before RLS fix | Now | Result |
|---|---|---|---|
| Open exceptions count | 16,426 ms | **26.9 ms** | PASS |
| Exception financial impact | 7,923 ms | **291 ms** | PASS |
| Commission entitlements count | 3,211 ms | **4.7 ms** | PASS |
| Management summary | — | 68.5 ms | PASS |
| Cycle detail | — | 10.9 ms | PASS |
| Agent profile | — | 9.3 ms | PASS |
| FDT candidate list | — | 38.0 ms | PASS |

## UI and responsive (live deployment)

| Width | Overflow | Unclipped elements | Layout | Result |
|---|---|---|---|---|
| 1440 | 0 | 0 | sidebar right, 4 KPI columns | PASS |
| 1366 | 0 | 0 | sidebar right, 4 KPI columns | PASS |
| 768 | 0 | 0 | drawer off-screen → on-screen → off-screen; overlay 0→1→0; `aria-expanded` tracks | PASS |
| 375 | 0 | 0 | 1 KPI column, tables become labelled cards | PASS |

| Check | Result |
|---|---|
| RTL root and logical properties | PASS |
| Cycle state always visible | PASS |
| Projected never styled as final | PASS |
| Money format single rule | PASS |

## Accessibility

| Check | Result | Evidence |
|---|---|---|
| Contrast — all real pairs | PASS | 4.55 – 16.68, every pair ≥ AA |
| Gold never text on light | PASS | enforced by test (2.64:1 would fail) |
| Status not colour-only | PASS | dot + text for every state |
| Focus visible | PASS | 2px outline, `:focus-visible` |
| Skip link | PASS | present |
| Icon-only buttons labelled | PASS | 0 unlabelled among 78 focusable |
| Touch targets ≥ 24px (AA) | PASS | smallest 30px |
| Touch targets ≥ 44px (AAA) | FAIL (non-blocking) | sidebar toggle and 5 nav headers at 30px → backlog |

## Security

| Check | Result | Evidence |
|---|---|---|
| RLS on every public table | PASS | 0 tables without RLS |
| SECURITY DEFINER search_path pinned | PASS | 0 functions unpinned |
| Anonymous table privileges | PASS | none |
| Anonymous REST read | PASS | 42501 on cycles, identities, raw events |
| Raw SaaS PII admin-only | PASS | accountant sees 0 rows in `saas_activation_events` and `saas_user_snapshots` |
| Display names excluded from identity | PASS | 0 of 32,481 carry `display_name` |
| No password column anywhere | PASS | 0 |
| Browser key is publishable, not service-role | PASS | `sb_publishable_…`, not a JWT, not service |
| No secret in delivered code | PASS | only match is a comment forbidding it |
| Odoo | PASS | deferred; no live call, no key in code |

## Backup and recovery

| Check | Result | Evidence |
|---|---|---|
| Point-in-time recovery | **FAIL (non-blocking, action required)** | `pitr_enabled: false` |
| Managed backups listed | **FAIL (non-blocking, action required)** | API returns 0 |
| WAL-G physical backup infrastructure | PASS | `walg_enabled: true` |
| Fresh complete logical backup taken | PASS | 50 tables · 184,322 rows · per-table SHA-256 · migration state, `2026-08-19T05-22-32Z` |
| Recovery procedure documented and tested | PASS | `docs/RUNBOOK.md` §الاسترجاع المستهدف; `pg_restore` rehearsed on staging per `docs/STAGING.md` |

## Migrations

| Check | Result | Evidence |
|---|---|---|
| Deployed migrations match repo (recent) | PASS | 29 recorded, none deployed that is absent from the repo |
| Schema of the 5 unrecorded early migrations | PASS | every table, policy, constraint and RPC verified present |
| History-recording anomaly | **Noted (non-blocking)** | 5 pre-tracking versions absent from `schema_migrations` → backlog |
| No blind `db push` used | PASS | targeted deployment only |

## Tests

| Suite | Baseline | Measured | Result |
|---|---|---|---|
| JS | 380 | 380 pass / 0 fail | PASS |
| DB assertions | 465 | 465 | PASS |
