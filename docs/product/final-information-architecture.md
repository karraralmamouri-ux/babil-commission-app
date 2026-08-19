# BABIL FLOW — Final Information Architecture

**Status:** approved target. Not implemented.
**Companion:** `screen-contracts.md` (per-screen detail), `full-product-gap-audit.md` (why).

Routes are History-API paths under the Pages base. Every route is deep-linkable,
Back-navigable, refresh-safe, and permission-gated **server-side** — the route
guard is convenience, never the control.

---

## 1. Navigation tree

```
الرئيسية                          /
│
عمولات الوكلاء                    /commissions
├── نظرة عامة                     /commissions
├── الدورات                       /commissions/cycles
│   └── دورة                      /commissions/cycles/:cycleId
│       ├── نظرة عامة             .../overview
│       ├── النطاقات              .../scopes
│       ├── الأحداث               .../events
│       ├── الاستثناءات           .../exceptions
│       ├── المراجعة والاعتماد    .../review
│       ├── تجهيز الصرف           .../payout
│       └── التدقيق               .../audit
├── الوكلاء                       /commissions/agents
├── الكابينات                     /commissions/fdt
├── الاستثناءات                   /commissions/exceptions
└── الأرشيف                       /commissions/archive
│
أجور التنصيب                      /installation
├── مركز التحكم                   /installation
├── المشتركون                     /installation/subscribers
│   └── ملف مشترك                 /installation/subscribers/:subscriberId
│       ├── نظرة عامة             .../overview
│       ├── التفعيلات             .../activations
│       ├── الفواتير              .../invoices
│       ├── الاستحقاقات           .../entitlements
│       ├── الدفعات               .../payments
│       ├── الإيقافات             .../holds
│       ├── التاريخ               .../history
│       └── التدقيق               .../audit
├── دورة الشهر                    /installation/cycles
│   └── دورة                      /installation/cycles/:cycleId
├── المطابقة والتصنيف             /installation/matching
├── الفواتير                      /installation/invoices
├── جاهز للصرف                    /installation/ready
├── الموقوفون                     /installation/holds
└── الأرشيف                       /installation/archive
│
المالية                           /finance
├── دفعات الصرف                   /finance/payment-batches
│   └── دفعة                      /finance/payment-batches/:batchId
├── سجل المدفوعات                 /finance/payments
└── الدفتر المالي                 /finance/ledger
│
الاستثناءات                       /exceptions
│
البيانات الرئيسية                 /master
├── الوكلاء                       /master/agents
│   └── وكيل                      /master/agents/:agentId   → shared with /agents/:id
├── الأسماء البديلة               /master/aliases
├── الكابينات                     /master/fdt
│   └── كابينة                    /master/fdt/:fdtCode
├── الباقات والخدمات              /master/packages
└── المخططات المالية              /master/schemes
    ├── مخططات العمولة            /master/schemes/commission
    └── مخططات التنصيب            /master/schemes/installation
│
الاستيراد                         /imports
│   └── دفعة استيراد              /imports/:batchId
│
التقارير                          /reports
│   └── تقرير                     /reports/:reportKey
│
النظام                            /system
├── المستخدمون                    /system/users
│   └── مستخدم                    /system/users/:userId
├── الأدوار والقدرات              /system/roles
├── التجاوزات                     /system/overrides
├── سجل التدقيق                   /system/audit
└── الإعدادات                     /system/settings
```

**Agent workspace** is reachable from both commission and master data. One route
owns it — `/agents/:agentId` — and both menus link there. Two routes rendering
one entity is how a product starts disagreeing with itself.

---

## 2. Screen register

Capability names are the existing ones. `desktop` / `mobile` describe layout
behaviour, not feature differences — no screen is desktop-only.

| Arabic | Route | Module | Entity | Capability | Desktop | Mobile |
|---|---|---|---|---|---|---|
| الرئيسية | `/` | home | — | `report.view` | KPI grid + drill-downs | stacked cards |
| نظرة عامة | `/commissions` | commission | cycle | `commission.view` | summary + cycle list | stacked |
| الدورات | `/commissions/cycles` | commission | cycle | `commission.view` | table | cards |
| دورة | `/commissions/cycles/:id` | commission | cycle | `commission.view` | tabbed workspace | tab select + stacked |
| النطاقات | `…/scopes` | commission | snapshot | `commission.view` | table, sticky head | cards |
| الأحداث | `…/events` | commission | entitlement | `commission.view` | paged table | cards |
| المراجعة | `…/review` | commission | cycle | `commission.finalize` | blocker checklist | stacked |
| تجهيز الصرف | `…/payout` | commission | batch | `commission.prepare_payment` | selection table | list + drawer |
| الوكلاء | `/commissions/agents` | commission | agent | `commission.view` | table | cards |
| وكيل | `/agents/:id` | shared | agent | `agent.view` | tabbed workspace | tabs stacked |
| الكابينات | `/commissions/fdt` | commission | fdt | `commission.view` | table | cards |
| كابينة | `/master/fdt/:code` | master | fdt | `fdt.manage` | detail + evidence | stacked |
| المشتركون | `/installation/subscribers` | installation | subscriber | `installation.view` | **server-paged** table | cards + filter drawer |
| ملف مشترك | `/installation/subscribers/:id` | installation | subscriber | `installation.view` | tabbed case | tabs stacked |
| دورة التنصيب | `/installation/cycles/:id` | installation | cycle | `cycle.view` | lifecycle workspace | stepper |
| الفواتير | `/installation/invoices` | installation | invoice | `invoice.view` | queue | cards |
| جاهز للصرف | `/installation/ready` | installation | entitlement | `payment.view` | queue | cards |
| الموقوفون | `/installation/holds` | installation | hold | `installation.view` | queue | cards |
| دفعات الصرف | `/finance/payment-batches` | finance | batch | `payment.view` | table | cards |
| دفعة | `/finance/payment-batches/:id` | finance | batch | `payment.view` | line table + validation | stacked |
| الدفتر المالي | `/finance/ledger` | finance | ledger | `report.view` | paged table | cards |
| الاستثناءات | `/exceptions` | shared | exception | `commission.view` | **server-paged** queue | cards |
| الأسماء البديلة | `/master/aliases` | master | alias | `agent.manage` | table | cards |
| الباقات | `/master/packages` | master | package | `agent.manage` | table | cards |
| المخططات | `/master/schemes/*` | master | scheme version | `rates.manage` | version list + diff | stacked |
| الاستيراد | `/imports` | imports | batch | `saas.import` | batch table | cards |
| دفعة استيراد | `/imports/:id` | imports | batch | `saas.import` | result detail | stacked |
| التقارير | `/reports` | reports | — | `report.view` | selector + preview | selector then preview |
| تقرير | `/reports/:key` | reports | — | `report.view` | filters + table + export | stacked |
| المستخدمون | `/system/users` | system | user | `users.manage` | table | cards |
| مستخدم | `/system/users/:id` | system | user | `users.manage` | detail + effective perms | stacked |
| الأدوار | `/system/roles` | system | role | `permission.manage` | matrix | scrollable matrix |
| التجاوزات | `/system/overrides` | system | override | `permission.manage` | table | cards |
| سجل التدقيق | `/system/audit` | system | audit | `audit.view` | **server-paged** table | cards |
| الإعدادات | `/system/settings` | system | — | `settings.manage` | form | stacked |

**36 screens.** Today: 10 real, 0 addressable.

---

## 3. Rules that hold across every screen

**Money is server-computed.** Screens call reports and RPCs. No screen sums,
prices, or re-derives a financial figure. A screen that needs a total it cannot
fetch is a backend gap, recorded in `productization-api-gap.md` — never a reason
to add arithmetic to the browser.

**Not-loaded is not zero.** Unloaded numeric fields render `—`. `0` means the
server said zero. This rule already exists in v1.0 and carries forward.

**Projected is never styled as final.** Any figure from a cycle before
finalization carries the `تقديري` marker.

**Every list states its bounds.** Total count, current page, and page size are
visible. A capped list that hides its cap is a defect.

**Every screen owns four states**: loading, empty, error, and no-permission.
Shared spinners across unrelated screens are not acceptable at this scale.

**Breadcrumbs follow the route**, not history. `الرئيسية › عمولات الوكلاء ›
2026-07 تموز › الاستثناءات`.

**Drill-down is the default.** Every KPI, count, and money figure either links to
the filtered list behind it or explains why it cannot.
