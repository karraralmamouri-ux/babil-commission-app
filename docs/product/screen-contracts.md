# Screen Contracts

Per-screen definition for the target application. Companion to
`final-information-architecture.md`.

**Contract fields:** purpose · primary user · data source · actions · filters ·
permission · lifecycle · drill-down.

**Invariant on every screen:** money comes from the server. `RPC` names below are
existing unless marked **(new)** — those are specified in
`productization-api-gap.md`.

---

## Home — `/`

| | |
|---|---|
| Purpose | Where is the money, and what needs a decision today |
| User | Manager, accountant |
| Data | `report_management_summary`, `report_commission_exception_impact` |
| Actions | none — navigation only |
| Permission | `report.view` |
| Lifecycle | reflects the selected cycle; projected figures marked |

Every figure drills:

| KPI | Drills to |
|---|---|
| إجمالي المستحق | `/commissions/cycles/:current` |
| المدفوع | `/finance/payments` |
| المتبقي | `/commissions/cycles/:current/payout` |
| **الموقوف** | `/exceptions?cycle=:current` |
| عمولات محسوبة | `/commissions/cycles/:current/scopes` |
| أجور مستحقة | `/installation/ready` |
| استثناء حاجب | `/exceptions?blocking=true` |

A KPI that cannot drill states why.

---

## Commission cycle workspace — `/commissions/cycles/:cycleId`

| | |
|---|---|
| Purpose | Operate one cycle end to end |
| User | Accountant, manager |
| Data | `report_commission_cycle_detail`, `commission_cycle_financials`, `commission_cycle_posted_amount` |
| Permission | `commission.view`; actions require `commission.finalize` / `commission.prepare_payment` |
| Lifecycle | draft → review → approved → payable → closed |

Header, always visible: cycle name · state chip · projected marker · source
completeness · window (`2026-06-30T21:00Z → 2026-07-31T21:00Z`) · tier basis ·
qualifying events · calculated · blocked · open exceptions.

**Tier basis and qualifying events are labelled distinctly and never summed.**

| Tab | Data | Actions |
|---|---|---|
| نظرة عامة | cycle detail | recalculate (`recalculate_cycle_after_master_change`) |
| النطاقات | `commission_cycle_snapshots` | open scope |
| الأحداث | `commission_cycle_events_page` | filter by scope, page |
| الاستثناءات | `list_commission_exceptions` **(new)** | route to resolution |
| المراجعة | `commission_finalization_blockers` **(new)** | finalize (`calculate_commission_cycle(finalize=true)`) |
| تجهيز الصرف | `commission_scope_payable` | prepare, `revalidate_commission_batch` |
| التدقيق | `report_audit_trail` | — |

**Review tab** lists each blocker with reason, records, subscribers, indicative
money, and a link to where it is fixed. Finalize stays disabled while any blocker
is open; the button explains what is missing rather than being silently inert.

---

## Subscriber registry — `/installation/subscribers`

| | |
|---|---|
| Purpose | Find any of 5,693 subscribers |
| User | Operations, accountant |
| Data | `list_installation_subscribers` **(new)** — server filter, sort, page, total |
| Permission | `installation.view` |

Filters: search (identity/name) · agent · cabinet · zone · stage (P1–P4, DONE) ·
eligibility · invoice state · hold · payment state · warnings.

Columns: identity · name · agent · cabinet · stage · eligibility · invoice ·
hold · amount · payment · warnings · last event.

Row → `/installation/subscribers/:id`.

**Never fetches the full table.** Total and page size always visible.

---

## Subscriber case — `/installation/subscribers/:subscriberId`

| | |
|---|---|
| Purpose | Everything about one subscriber, and why they are blocked |
| User | Operations, accountant |
| Data | `installation_subscriber_case` **(new)**, `subscriber_timeline` **(new)** |
| Permission | `installation.view` |

Header: identity · name · agent · cabinet · zone · current stage · scheme version
· eligibility · invoice state · hold state · amount due · payment state.

| Tab | Source |
|---|---|
| نظرة عامة | case document |
| التفعيلات | `saas_activation_events` (admin) / `saas_activation_events_safe` |
| الفواتير | `installation_invoices` |
| الاستحقاقات | `installation_entitlements` + `installation_entitlement_eligibility` |
| الدفعات | `installation_payments`, `installation_payment_history` |
| الإيقافات | `installation_holds` — place/release |
| التاريخ | derived timeline |
| التدقيق | `audit_logs` for this entity |

Actions: place hold · release hold · audit invoice
(`audit_installation_invoice`). **No payment posting from this screen** —
payments happen in a batch, where revalidation lives.

**Timeline is derived on read.** No stored timeline table: a stored copy is a
second truth that drifts from the ledger.

---

## Exceptions — `/exceptions`

| | |
|---|---|
| Purpose | The work queue, not an error list |
| User | Operations, master-data admin |
| Data | `list_commission_exceptions` **(new)**, `report_commission_exception_impact` |
| Permission | `commission.view` |

Filters: domain · reason · agent · cabinet · cycle · blocking · financial impact
· owner · status. All in the query string.

Every row answers: what happened · how many records · how many subscribers · how
much money · who owns it · what resolves it · where to go.

| Reason | Owner | Destination |
|---|---|---|
| UNKNOWN_FDT | master data | `/master/fdt/:code` |
| UNKNOWN_AGENT | master data | `/master/aliases?q=:parent` |
| UNKNOWN_PACKAGE | master data | `/master/packages` |
| SOURCE_INCOMPLETE | import | `/imports/:batchId` |
| IDENTITY_CONFLICT | subscriber review | `/installation/subscribers/:id` |
| MISSING_INVOICE | invoice review | `/installation/invoices?subscriber=:id` |
| HOLD | operations | `/installation/holds` |

The playbook already exists in `commission-vnext.js` and carries forward
unchanged. **No reason routes to a developer.**

---

## Payment batch — `/finance/payment-batches/:batchId`

| | |
|---|---|
| Purpose | Prepare, validate and post one batch |
| User | Accountant |
| Data | `commission_payment_batch_items`, `commission_scope_payable` |
| Actions | `revalidate_commission_batch`, `post_commission_batch` |
| Permission | view `payment.view`; post `commission.pay` |
| Lifecycle | draft → validated → posted (server-owned) |

Per line: scope · agent · domain · gross · already paid · payable · state ·
**server reason when rejected**.

Posting requires a fresh revalidation. Stale batch, duplicate, overpay and
blocked-record inclusion are all refused **server-side**; the screen surfaces the
refusal and never pre-empts it with client logic.

---

## Agent workspace — `/agents/:agentId`

| | |
|---|---|
| Purpose | One agent's complete financial position |
| Data | `agent_financial_profile` |
| Permission | `agent.view` |

Header: identity · code · status · zones · aliases · cabinets.

**Commission and installation are presented side by side and never merged** —
their accounting rules differ, and a combined total would imply a rule that does
not exist.

| Section | Fields |
|---|---|
| Commission | calculated · blocked · paid · remaining · tier · cycle history · cabinet breakdown |
| Installation | subscribers · P1–P4 distribution · due · ready · blocked · paid · remaining |
| Exceptions | open items attributed to this agent |
| Payments | batches and ledger entries |
| Audit | changes affecting this agent |

Visibility only. No calculation.

---

## Remaining screens

| Screen | Route | Data | Permission |
|---|---|---|---|
| Cycles list | `/commissions/cycles` | `commission_cycles` | `commission.view` |
| Agents list | `/commissions/agents` | `list_agents_financial` **(new)** | `commission.view` |
| Cabinet detail | `/master/fdt/:code` | `unregistered_fdt_candidates`, `fdt_blocked_amount` | `fdt.manage` |
| Installation control | `/installation` | `installation_financials` | `installation.view` |
| Installation cycle | `/installation/cycles/:id` | `installation_cycle_state` **(new)** | `cycle.view` |
| Invoices | `/installation/invoices` | `list_installation_invoices` **(new)** | `invoice.view` |
| Ready for payment | `/installation/ready` | `installation_entitlement_eligibility` | `payment.view` |
| Holds | `/installation/holds` | `installation_holds` | `installation.view` |
| Ledger | `/finance/ledger` | `list_financial_ledger` **(new)** | `report.view` |
| Aliases | `/master/aliases` | `agent_aliases` | `agent.manage` |
| Packages | `/master/packages` | `packages` | `agent.manage` |
| Schemes | `/master/schemes/*` | scheme version tables | `rates.manage` |
| Imports | `/imports` | `list_import_batches` **(new)** | `saas.import` |
| Reports | `/reports/:key` | the six reports | `report.view` |
| Users | `/system/users` | `profiles` + admin function | `users.manage` |
| User detail | `/system/users/:id` | `explain_permission` | `users.manage` |
| Roles | `/system/roles` | role templates | `permission.manage` |
| Overrides | `/system/overrides` | `user_permission_overrides` | `permission.manage` |
| Audit | `/system/audit` | `list_audit_events` **(new)** | `audit.view` |
