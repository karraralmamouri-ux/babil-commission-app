# BABIL FLOW — Productization Gap Audit

**Audited commit:** `75f9b356b6753689ab440f1b316807d31068e075` (= `v1.0.0`, main is at the tag)
**Date:** 2026-08-19
**Scope:** analysis only. No code, schema, or production change.

---

## 1. Verdict

> **B — a dashboard-style shell over a complete financial engine.**

The financial engine is a genuine system: 50 tables, 81 callable RPCs, 5 views,
465 database assertions, a proven ledger, and server-authoritative lifecycle. The
frontend in front of it is one 265 KB HTML file that scrolls between nine anchors
and toggles seventeen panels.

The sharpest way to state the gap is not "the UI is a dashboard". It is this:

> **The navigation already promises the target information architecture. The
> screens behind it do not exist, so the labels were wired to whatever panel was
> closest.**

`docs/product/navigation-and-screen-map-vnext.md` specified the target navigation
before v1.0. The v1.0 sidebar implements that specification **label for label** —
and then points several of those labels at the same panel. The menu is a promise
the application cannot keep.

That distinction matters for planning: this is not a design problem to be
re-drawn. The IA is already agreed and already visible to users. What is missing
is the application behind it.

---

## 2. Evidence

### 2.1 Navigation collisions — measured, not asserted

Twenty sidebar entries navigate. They resolve to **fourteen** distinct
destinations.

| Destination | Labels pointing at it | Count |
|---|---|---|
| `operationsSection#queues` | دورة الشهر · الفواتير · جاهز للصرف · الموقوفون · الدفعات | **5** |
| `installationSection` | مركز التحكم · المشتركون | 2 |
| `operationsSection#master` | الوكلاء · الكابينات FDT | 2 |

Five distinct operational concepts — a monthly cycle, invoice review, payment
readiness, holds, and payment batches — are one generic widget:

```html
<div id="ops-queues" class="ops-panel active">
  <div id="opsQueueCards" class="grid2"></div>
  <div id="opsQueueDetail" style="margin-top:10px;overflow:auto"></div>
</div>
```

An operator who clicks *الفواتير* and *الموقوفون* lands in the same place with
the same content. Nothing in the interface tells them why.

### 2.2 There is no routing

Zero use of the History API for navigation. The only two hits in the entire
codebase are Supabase recovery-token cleanup:

```js
function detectRecoveryRedirect(){
  const hash=window.location.hash;
  ...
  history.replaceState(null,'',window.location.pathname+window.location.search);
```

Navigation is `scrollIntoView`: 23 `scrollToSection()` call sites.

Consequences, all currently true:

- No deep link. An exception cannot be sent to a colleague.
- Browser Back does not return to the previous screen; it leaves the app.
- Refresh always lands on the executive overview regardless of where you were.
- No screen has its own loading, error, or empty state — they are shared.

### 2.3 The work queue shows 1.3% of the work

The exceptions loader:

```
/rest/v1/commission_exceptions?...&order=created_at.desc&limit=300
```

against **22,727 exception rows**. There is no paging, no total, and no way to
reach row 301. The queue the product calls its primary workflow is capped at a
number chosen as a safety valve, not as a page size.

`reporting.js` already exports `pageParams`, `pageInfo`, and `MAX_PAGE`.
They are called **zero times** in `index.html`. Pagination was built and never
wired.

### 2.4 Composition

| | |
|---|---|
| `index.html` | 265 KB · 3,133 lines |
| — inline `<script>` | **223 KB · 306 functions · 36 module-level globals** |
| — markup | 42 KB |
| Extracted modules | 82 KB across 5 files |
| Stylesheet | 48 KB |

### 2.5 What is genuinely good, and should not be rebuilt

The five extracted modules contain **zero** DOM references and export pure
functions:

| Module | Size | DOM refs |
|---|---|---|
| `installation-fees.js` | 34 KB | 0 |
| `saas-import.js` | 22 KB | 0 |
| `reporting.js` | 10 KB | 0 |
| `commission-vnext.js` | 9 KB | 0 |
| `operations.js` | 7 KB | 0 |

82 KB of domain logic is already portable. This materially lowers migration risk
and is the main reason the plan below is staged rather than a rewrite.

---

## 3. Navigation truth audit

Classification: **REAL** = own screen, data, and states · **SHARED** = a panel
serving several labels · **ALIAS** = scroll to a section another label owns ·
**MODAL** · **ACTION** = fires a side effect, not navigation.

| # | Label | Handler destination | Class | Deep link | Back | Refresh-safe |
|---|---|---|---|---|---|---|
| 1 | الرئيسية | `dashboardSection` | REAL | ✗ | ✗ | ✗ |
| 2 | نظرة عامة | `commissionVNextSection#cycle` | REAL | ✗ | ✗ | ✗ |
| 3 | الوكلاء والكابينات | `agentsSection` | REAL | ✗ | ✗ | ✗ |
| 4 | الاستحقاقات | `commissionVNextSection#scopes` | REAL | ✗ | ✗ | ✗ |
| 5 | الصرف | `executiveSection#payout` | SHARED | ✗ | ✗ | ✗ |
| 6 | الأرشيف (عمولات) | `openArchiveManager()` | MODAL | ✗ | ✗ | ✗ |
| 7 | مركز التحكم | `installationSection` | REAL | ✗ | ✗ | ✗ |
| 8 | المشتركون | `installationSection` | **ALIAS of 7** | ✗ | ✗ | ✗ |
| 9 | دورة الشهر | `operationsSection#queues` | SHARED | ✗ | ✗ | ✗ |
| 10 | المطابقة والتدقيق | `executiveSection#installation` | SHARED | ✗ | ✗ | ✗ |
| 11 | الفواتير | `operationsSection#queues` | **ALIAS of 9** | ✗ | ✗ | ✗ |
| 12 | جاهز للصرف | `operationsSection#queues` | **ALIAS of 9** | ✗ | ✗ | ✗ |
| 13 | الموقوفون | `operationsSection#queues` | **ALIAS of 9** | ✗ | ✗ | ✗ |
| 14 | الدفعات | `operationsSection#queues` | **ALIAS of 9** | ✗ | ✗ | ✗ |
| 15 | الاستيراد / المزامنة | `operationsSection#import` | REAL | ✗ | ✗ | ✗ |
| 16 | الوكلاء (بيانات رئيسية) | `operationsSection#master` | SHARED | ✗ | ✗ | ✗ |
| 17 | الكابينات FDT | `operationsSection#master` | **ALIAS of 16** | ✗ | ✗ | ✗ |
| 18 | الباقات والإعدادات | `operationsSection#schemes` | REAL | ✗ | ✗ | ✗ |
| 19 | مركز التقارير | `executiveSection` | REAL | ✗ | ✗ | ✗ |
| 20 | تصدير تقرير العمولات | `exportAll()` | ACTION | — | — | — |
| 21 | تقرير Excel متكامل | `exportExcelReport()` | ACTION | — | — | — |
| 22 | مقارنة الأشهر | `comparisonSection` | REAL | ✗ | ✗ | ✗ |
| 23 | المستخدمون والصلاحيات | `openUserManagement()` | MODAL | ✗ | ✗ | ✗ |
| 24 | سجل التدقيق | `openAuditLog()` | MODAL | ✗ | ✗ | ✗ |
| 25 | الصلاحيات الفعّالة | `operationsSection#permissions` | REAL | ✗ | ✗ | ✗ |
| 26 | تحديث البيانات المركزية | `refreshCentralData()` | ACTION | — | — | — |
| 27 | نسخة احتياطية | `exportBackup()` | ACTION | — | — | — |
| 28 | فتح وضع تجهيز الشهر | `toggleCentralPreview()` | ACTION | — | — | — |
| 29 | استيراد ملف التفعيلات | file input click | ACTION | — | — | — |
| 30 | حفظ بيانات الشهر | `saveCurrentMonth()` | ACTION | — | — | — |
| 31 | اعتماد الشهر مركزياً | `publishCurrentMonth()` | ACTION | — | — | — |
| 32 | اختيار شهر محفوظ | `focusMonthPicker()` | ACTION | — | — | — |
| 33 | إنشاء الشهر التالي | `startNewMonth()` | ACTION | — | — | — |
| 34 | أسعار العمولات والتير | `openSettingsSection()` | ACTION | — | — | — |
| 35 | ربط الوكلاء والكابينات | `openSettingsSection()` | ACTION | — | — | — |
| 36 | English | `toggleLanguage()` | ACTION | — | — | — |

**Totals:** 10 REAL · 4 SHARED · **6 ALIAS** · 3 MODAL · 13 ACTION.
**Deep-linkable: 0 of 36. Back-navigable: 0. Refresh-safe: 0.**

### Screens the menu implies but the application does not have

`المشتركون` · `الفواتير` · `جاهز للصرف` · `الموقوفون` · `الدفعات` (as a batch
workspace) · `الأرشيف` for installation · plus every record-level workspace:
subscriber case, agent workspace, cycle workspace, batch detail, user detail.

---

## 4. Missing product capabilities

### 4.1 Case management — the largest single gap

There is no way to open one subscriber and see their situation. The domain owns
5,693 subscribers and 17,117 payment events; the interface offers no
`/installation/subscribers/:id`. An operator answering "why is this subscriber
blocked?" must read a table, then a queue, then an export.

The same absence applies to a cabinet, an agent, a batch, and a user.

### 4.2 Workflow continuity

The installation lifecycle — import → validate → match → classify → invoice
review → eligibility → payment preparation → payment → close — exists in the
database as enforced state. In the interface it is one queue widget. A user
cannot see where a cycle is in that sequence, or what specifically blocks the
next step.

### 4.3 Drill-down

KPIs are terminal. `الموقوف / قيد المراجعة` shows 66,660,500 IQD and cannot be
clicked. The number that most needs investigation is the least reachable.

### 4.4 Queues that exceed their page

Exceptions cap at 300 of 22,727. FDT candidates cap at 300 (119 today — the cap
is invisible now and will not stay invisible). Subscribers have no list screen at
all.

### 4.5 Administration in modals

Users, permissions, audit, and archive are modals. A modal cannot be linked,
filtered into, paged, or returned to. Audit in particular is a compliance
surface; it currently opens over the page and closes back to nothing.

---

## 5. What must not be rebuilt

The financial engine is accepted and frozen at `v1.0.0`. The productization work
**consumes** it and adds no financial rule:

commission vNext · installation fees rules · historical migration · ledger ·
payments · corrections and reversals · permissions and RLS · FDT rules · SaaS
import contracts · financial reports · timezone logic · July reconciliation.

Any productization task that proposes to compute money in the browser is
mis-scoped by definition.

---

## 6. Honest note on the v1.0 UI phase

The v1.0 UI work delivered a real design system, correct RTL, an accessible
palette, and a shell — and it fixed three genuine layout defects. It did not
deliver screens, and the phase brief did not ask for them. The gap identified
here is a scope gap between "final UI" and "final application", not a defect in
what was built.

What the phase did do, which now needs correcting, is wire five aliases to one
panel to satisfy the agreed menu. That was the only way to show the agreed IA
without the screens existing. It should not survive productization.
