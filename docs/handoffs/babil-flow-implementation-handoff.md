# BABIL FLOW — Results → Decisions → Actions · Implementation Handoff

| | |
|---|---|
| Starting SHA | `c28be6f972f0821bbadc4668cc069338c37b9099` |
| Branch | `main` (work branch `results-decisions-actions`, merged and deleted) |
| Current HEAD | `ae86f5439eb7d4c0d3b112fe98de929b9142cafb` |
| PR | [#75](https://github.com/karraralmamouri-ux/babil-commission-app/pull/75) — CI green, squash-merged |
| Pages | deployed and verified live |
| JS tests | **533 / 533** pass |
| DB assertions | **801** pass |
| `tsc --noEmit` | clean |
| production build | clean, bundle verified |

> **On the missing audit document.** `docs/audits/babil-flow-preimplementation-audit.md`
> exists in **no ref, branch or commit** — verified with `git fetch --all` and a
> tree search across every ref. Everything below labelled
> **DERIVED DURING IMPLEMENTATION AUDIT** was established from the codebase and
> production directly, as explicitly authorized. It is not sourced from that document.

---

## 1 · Completed

### Phase 1 — correctness

**Agent picker — root cause found and fixed.** `list_agents_for_pick` filtered
`a.status = 'ACTIVE'`; `agents_status_check` permits only `'active'`/`'inactive'`.
Proof, isolated per predicate:

| predicate | matches |
|---|---|
| `has_capability('agent.view')` | 11 |
| `status = 'ACTIVE'` | **0** ← the failing predicate |
| `status = 'active'` | 11 |
| `list_agents_for_pick()` returned | **0** |

The RPC **succeeded** and returned `[]` — there was never a network error to
capture. Comparison is now `lower(a.status) = 'active'`. The frontend's
`catch(() => [])` was also replaced with an explicit error + retry, but as
error-handling debt, **not** as the cause. Live: **11 agents**.

**Commission Overview contract.** `report_commission_cycle_detail` returns
`TABLE(cycle_name, scope_type, …)` — a set of rows. The screen read
`detail['totals']` off the resulting array, a key that response can never carry,
so every KPI rendered `—`. It was fetched **3×** (`index.ts:62, 239, 341`), each
`catch(() => null)`, making an outage indistinguishable from empty data.
`commission_cycle_result(p_cycle_id)` now returns one object read once via
`src/domain/cycle.ts`; failure renders **تعذر تحميل بيانات الدورة** with retry.

**DIRECT_COMPANY blocker generation — ALREADY APPLIED TO PRODUCTION.**
`tmp_billable` excluded DIRECT_COMPANY; the `UNKNOWN_FDT` insert did not — the
same ownership question answered two ways. Both blocker inserts now resolve
ownership first using `source_classification`, the same predicate the money uses.
`UNKNOWN_AGENT` additionally aligned (it previously consulted only
`parent_resolution`).

**Baghdad time.** `src/domain/time.ts` added; 8 files migrated off
`.replace('T',' ').slice(0,16)`, which rendered UTC — an event at 00:30 Baghdad
displayed as the previous day. Stored `timestamptz` values untouched.

### Phase 2/3 — results and decisions

- Home reads the typed contract; commission cards are now
  **محسوب ← معتمد ← جاهز ← مدفوع**. `إجمالي المستحق` removed — it mislabelled an
  UNDER_REVIEW figure as a final obligation.
- Commission Overview shows the visible reconciliation box.
- Work Center gained two decision groups, ordered first by financial weight:
  `UNRESOLVED_OWNERSHIP` and `HISTORICAL_UNRESOLVED`.
- Two decision screens at `/work/ownership` and `/work/historical`, both following
  المشكلة → الأثر المالي → الأدلّة → القرار المطلوب.

### Phase 6 — navigation

Regrouped to **النتائج المالية → مركز العمل → البيانات → النظام**.
**No route moved**, so every deep link still resolves. Screens that left the
sidebar are enumerated in `CONTEXTUAL_ROUTES` (`src/app/shell.ts`) with a test
asserting each is still registered in the router.

---

## 2 · Files

**Added** — `src/domain/cycle.ts`, `src/domain/time.ts`,
`src/features/work/decisions.ts`,
`supabase/migrations/20260925090000_phase1_correctness.sql`,
`supabase/migrations/20260926090000_decision_groups.sql`,
`tests/sql/ownership-and-contracts.sql`, this document.

**Modified** — `src/app/shell.ts`, `src/main.ts`,
`src/features/{home,commissions}/index.ts`, `src/features/master/mapping.ts`,
`src/features/{audit,reports,system/imports,system/users,installation/holds,finance/installation-batches,master/fdts}` (Baghdad time),
`tests/app-routing.test.js`, `tests/babil-flow-ui.test.js`,
`tests/system-and-brand.test.js`, `tests/sql/subscriber-ownership.sql`,
`tests/sql/run-local-tests.sh`.

---

## 3 · Migrations and production parity

| migration | contents |
|---|---|
| `20260925090000_phase1_correctness.sql` | picker fix · engine ownership guard · `commission_cycle_result` |
| `20260926090000_decision_groups.sql` | `action_center` +2 groups · `unresolved_ownership_decisions` · `historical_unresolved_subscribers` |

**Parity: 65 migration files = 65 ledger rows.** Both applied to production and
recorded. No destructive migration.

### Applied to production data

`calculate_commission_cycle(<july>, false)` was run **once** — a projected
recalculation, not a finalization — after proving in a rolled-back transaction
that gross, qualifying events and tier basis were byte-identical. This is what
made the DIRECT_COMPANY correction take effect.

**No payment. No finalization. No raw source mutation.**

---

## 4 · Financial regression — current production

```
gross              21,969,500      unchanged
qualifying          4,549          unchanged
tier basis          4,413          unchanged
status              UNDER_REVIEW   unchanged
paid                0              unchanged

known agents       21,950,750
unresolved            18,750
                   ──────────
                   21,969,500     ✓ reconciles

Saeed Ammar        16,928,750
Ahmed Abdulabbas    5,022,000
```

Installation: 5,693 subscribers · 17,117 history rows · 54,828,000 paid ·
2,196 candidates · 7,278,000 · **Ready 0** · 5,688 in visible stages + 5 unresolved.

### Blockers

| | before | after |
|---|---|---|
| blocking exceptions | 22,726 | **4,218** |
| `UNKNOWN_FDT` | 22,723 | **4,215** |
| `UNKNOWN_AGENT` | 2 | 2 |
| `SOURCE_INCOMPLETE` | 1 | 1 |
| DIRECT_COMPANY in reseller blocker path | **18,508** | **0** |

---

## 5 · Open business decisions — DO NOT GUESS

**The four events / 18,750 IQD.** No `effective_agent_id`; all four share raw
parent `hrins.office`; all P-35000, new zone, cabinets 100/107/107/98,
2026-07-03. Evidence surfaced includes that **`hrins.oice` exists as a similar
source name** — that is evidence for one decision group, *not* permission to
auto-assign. Visible at `/work/ownership`.

**The five installation subscribers** outside P1–P4/DONE, at `/work/historical`
with remaining balance and payment history. Not classified.

**Unchanged and still open:** 119 unregistered FDT codes (now correctly excluding
DIRECT_COMPANY from the reseller queue), 22 unresolved parents, 2,196 invoices
awaiting verification, July source completeness.

---

## 6 · Not yet done

Untouched from the initiative, in the brief's own order:

- **§23 Agent financial profile** — raw HTML/escaping issue; RESULT → DETAIL →
  DECISIONS → ACTIONS reordering.
- **§25–26 Installation control centre** — top-level hierarchy reorder; stage
  breakdown with amounts; source diagnostics demoted.
- **§27 Invoice review UX** — focused drawer, no default VERIFIED, no full-page
  reload, preserve filters/pagination, السابق/التالي.
- **§12 Commission cycle page** — result-first layout (tabs still work).
- **§15 Commission events** — visible hierarchy and filters.
- **§17 Exception → business labels** — `UNKNOWN_FDT` etc. still show raw codes
  in some surfaces.
- **§32–34** Reports parity, Archive separation, Audit human-readable view.
- **§35** Remaining silent fallbacks — **DERIVED**: 19 occurrences across 10
  files; Commission Overview and the agent picker are fixed, the rest are not.
- **§38–39** Branding/logo consolidation; touched legacy inline-style debt.
- **§42** Terminology sweep.

**No route is knowingly broken or half-wired.** Everything committed is complete
and green.

---

## 7 · Exact next step

Start with **§27 invoice review** — it carries the largest live workload (2,196
decisions) and the current flow full-page-reloads after every save, losing
filters and pagination. `review_invoice` server logic is audited and correct;
this is UI-only. Then §23 agent profile, then §25 installation control centre.

---

## DO NOT REDO / DO NOT REGRESS

1. **`list_agents_for_pick` must stay case-insensitive.** The uppercase literal
   silently emptied the picker with no error. A test now requires a non-empty
   list before asserting status.
2. **The old picker assertion was vacuously true** — it tested a status value over
   an always-empty set. Do not restore that shape.
3. **Blockers and money must use the same ownership predicate**
   (`source_classification <> 'DIRECT_COMPANY'`). Splitting them again re-creates
   18,508 phantom blockers.
4. **Do not read `totals` from `report_commission_cycle_detail`** — it returns a
   TABLE. Use `commission_cycle_result` / `readCycleResult`.
5. **Do not allocate the 18,750 to any agent** to make totals balance. The
   reconciliation is intentionally displayed as known + unresolved.
6. **Per-agent anchors are 16,928,750 and 5,022,000** — not 16,934,750 /
   5,034,750, which pre-allocate the four undecided events.
7. **Do not restore FDT numeric ranges** as ownership or zone truth.
8. **Activation corrections stay immutable** (ACTIVE→REVOKED only) and never
   mutate `saas_activation_events`.
9. **Cycle-scoped FDT counts read `commission_event_entitlements`** — the engine's
   own output. Do not add a second qualification formula.
10. **Timestamps render in Asia/Baghdad; stored values are never modified.**
11. **`CONTEXTUAL_ROUTES` is not dead code** — those routes stay registered and
    are reached from context. A test enforces this.
12. **July stays UNDER_REVIEW**, 0 paid, `v1.0.0` = `75f9b356…` untouched.

---

# Continuation from `3ecfe0d` — frontend-safe scope

Date: 2026-08-21
Branch: `feat/remaining-results-decisions-actions`
Starting checkpoint: `3ecfe0d221d4fe3f7352112a64e1999d787d78e5`

## Completed and verified locally

- Focused Invoice Review drawer: explicit empty decision, evidence-first, no page reload, preserves current page/filters, previous/next, row state updates after save.
- Commission cycle consumes `commission_cycle_result` once; old TABLE-as-object calls removed from this surface. Financial result and operational volumes are separate.
- Commission events prioritize subscriber/package/tier/commission/Baghdad time; event ID is technical detail. Existing scope filters are exposed.
- Exception/blocker codes have human business labels; raw codes remain under technical details.
- Agent profile fixes raw status HTML escaping, prioritizes server rows and decisions, demotes aliases/UUID, and fixes FDT deep links.
- Installation Control Center uses existing authoritative reads for subscribers, historical paid, candidates, ready, holds, P1–P4 amounts, DONE, and the five unresolved historical cases.
- Commission result report shows known allocation and unresolved ownership as separate reconciliation lines; export uses the same displayed rows and authoritative totals.
- Archive separates `CLOSED` cycles from old-date cycles that are still unfinished.
- Audit is human-first and Baghdad-time; technical identifiers/JSON are collapsed.
- Meaningful silent `catch(() => null/[]/0)` patterns removed from executable TypeScript. Failures no longer look like valid empty data.
- BABIL FLOW browser title, theme colour and favicon use the existing approved identity.

Logical commits before documentation:

- `de96b64` focused invoice review workflow
- `766a79c` commission result presentation
- `8533472` installation control center
- `f6ef387` reports, archive and audit readability
- `ee313a4` read failure visibility and branding

No migration added. No SQL, RLS, ownership, payment, finalization or production data changed.

## Pull request and CI

- Draft PR: `#77` — `Complete frontend-safe results, decisions, and actions`.
- Initial PR CI run `32461776098`: TypeScript passed; JavaScript passed `556/556`; production build passed with 38 modules transformed and all 9 referenced assets present.
- The checked-in CI workflow does **not** run `npm run localdb:test`, PostgreSQL or Docker. Exact DB result: the 801 assertions were **not run**, so this CI run is not an authoritative DB regression result.
- PR remains draft and unmerged pending the database regression environment for the blocked contracts below.

## Financial invariants preserved

```text
Commission gross          21,969,500 IQD
Known allocation          21,950,750 IQD
Unresolved ownership          18,750 IQD
Reconciliation            21,969,500 IQD
Status                    UNDER_REVIEW
Paid                      0
DIRECT_COMPANY blockers   0

Installation subscribers  5,693
Historical rows           17,117
Historical paid           54,828,000 IQD
Candidates                2,196
Candidate amount          7,278,000 IQD
Ready                     0
Historical unresolved     5
```

These are the accepted anchors from the merged handoff. This frontend-only branch does not mutate or rederive them. Live production verification remains pending deployment.

## BLOCKED — DB REGRESSION ENVIRONMENT REQUIRED

1. Agent-level unified calculated/approved/ready/paid/remaining summary. Current `agent_financial_profile` returns scope rows and ledger rows, not one authoritative summary; the frontend does not aggregate a replacement.
2. Commission event Agent/FDT/source columns and Subscriber/Agent/FDT/Package/Tier/Date filters. Current event page RPC returns subscriber/package/tier/amount/time but not agent, FDT or source and accepts only scope filters.
3. Commission report FDT/Tier/P35/P45/P65/Ready columns in one export-safe contract.
4. Cycle-scoped audit. Current audit read accepts entity type but not entity ID; the cycle tab refuses to present all commission audit rows as if scoped.
5. Any new Work Center decision groups not already returned by `action_center`.
6. Local 801 database assertions and independent live migration-ledger parity verification. Docker/PostgreSQL is unavailable in this workspace.

Required order when the environment exists: regression first → minimal read-contract migration → all 801+ DB assertions → JS/type/build → PR/CI → review → merge → production migration → live verification.

## Safety statement

No payment posted. No July finalization. No fabricated ownership. No fabricated FDT classification. No fabricated invoice verification. No raw source mutation.

## Product acceptance fix batch — branch handoff

Branch: `feat/product-acceptance-fix` (not merged). The former DB-environment
blockers above now have additive read-only contracts in migration
`20260927090000_product_acceptance_read_contracts.sql`. Nothing in that
migration writes business data or changes calculation, ownership, RLS,
payment, or finalisation.

Completed locally:

- Correct blocker terminology, authoritative server-side commission Ready,
  and an explicit “not calculated yet” state.
- Navigable Agent/FDT context; human event evidence plus server filters and
  pagination; current-cycle UNKNOWN_FDT decision/evidence pages.
- Unified agent financial profile, export-safe commission report, and
  cycle-scoped audit read contracts.
- Exact Work Center destinations for FDT, incomplete imports,
  classification review and pending business decisions.
- Subscriber “history and evidence” consolidation, shared presentation
  labels, and scoped refresh that preserves route/query/scroll state.
- BF-SA-13 (logo) intentionally excluded.

Local verification: JavaScript `556/556`, TypeScript clean, production build
green (40 modules, 9 referenced assets). PostgreSQL is unavailable locally;
the new suite adds 11 contract assertions, so the authoritative expected CI
result is **812 DB assertions** across **66 deterministic migrations**. The PR
must remain unmerged unless that exact CI DB gate is green.

Financial anchors remain unchanged: 21,969,500 gross; 21,950,750 known;
18,750 unresolved; 4,549 qualifying; 4,413 tier basis; UNDER_REVIEW; paid 0;
DIRECT_COMPANY blockers 0. Installation remains 5,693 / 17,117 /
54,828,000 / 2,196 / 7,278,000 / Ready 0 / unresolved 5.
