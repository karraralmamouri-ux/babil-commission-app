# Productization — API and data gap audit

**Question per screen:** can the existing database answer this efficiently?

**Classification:** `READY` · `NEEDS VIEW/RPC` (data exists, no efficient
endpoint) · `MISSING MODEL` (data does not exist) · `MISSING WORKFLOW` (no
server lifecycle) · `PRESENTATION` (no backend work).

**Backend inventory at `v1.0.0`:** 50 tables · 81 callable RPCs · 5 views.

---

## 1. Headline finding — list endpoints

**Only one RPC supports real pagination.**

| RPC | Paging |
|---|---|
| `commission_cycle_events_page` | `p_limit` + `p_offset` — complete |
| `report_audit_trail` | `p_limit` only — cannot reach page 2 |
| `report_open_exceptions` | `p_limit` only — cannot reach page 2 |

Against these volumes:

| Table | Rows |
|---|---|
| `saas_activation_events` | 57,522 |
| `subscriber_identities` | 32,481 |
| `commission_exceptions` | **22,727** |
| `installation_payment_history` | 17,117 |
| `installation_subscribers` | 5,693 |

Every list screen in the target IA needs filter + sort + page + **total count**.
This is the single largest backend item, and it is additive: new read-only
functions over existing tables. No schema change, no financial rule touched.

### Proposed list endpoints

Uniform shape — filters, `p_limit`, `p_offset`, `p_sort`, returning rows plus
`total_count`:

| New RPC | Serves | Replaces |
|---|---|---|
| `list_installation_subscribers` | `/installation/subscribers` | nothing — screen absent |
| `list_commission_exceptions` | `/exceptions` | `limit=300` of 22,727 |
| `list_audit_events` | `/system/audit` | limit-only RPC |
| `list_financial_ledger` | `/finance/ledger` | `limit=50` |
| `list_payment_batches` | `/finance/payment-batches` | `limit=50` |
| `list_import_batches` | `/imports` | `limit=25` |
| `list_agents_financial` | `/commissions/agents` | client aggregation |

---

## 2. Screen-by-screen

### Home
| Need | Class | Note |
|---|---|---|
| KPI totals | **READY** | `report_management_summary` |
| Blocked exposure | **READY** | `report_commission_exception_impact` |
| KPI → filtered screen | **PRESENTATION** | routing only |

### Commission
| Need | Class | Note |
|---|---|---|
| Cycle list | **READY** | `commission_cycles` is small |
| Cycle detail | **READY** | `report_commission_cycle_detail` |
| Scopes | **READY** | `commission_cycle_snapshots` (26 rows) |
| Events, paged | **READY** | `commission_cycle_events_page` — the model to copy |
| Cycle financials | **READY** | `commission_cycle_financials`, `commission_cycle_posted_amount` |
| Exceptions, paged | **NEEDS RPC** | `list_commission_exceptions` |
| Review blockers | **NEEDS RPC** | `commission_finalization_blockers(cycle)` — the reasons exist inside `calculate_commission_cycle`; a read-only projection surfaces them without running a calculation |
| Payout preparation | **READY** | `commission_scope_payable`, `revalidate_commission_batch`, `post_commission_batch` |
| Agents list with money | **NEEDS RPC** | `list_agents_financial` |
| Agent workspace | **READY** | `agent_financial_profile` |
| FDT breakdown | **READY** | snapshots + `fdt_blocked_amount` |
| Archive | **READY** | closed cycles |

### Installation
| Need | Class | Note |
|---|---|---|
| Control centre totals | **READY** | `installation_financials` |
| Subscriber registry | **NEEDS RPC** | `list_installation_subscribers` — the P0 endpoint |
| **Subscriber case** | **NEEDS RPC** | `installation_subscriber_case(id)` — one document assembling enrollment, stage, entitlements, invoices, payments, holds, eligibility. All data exists across 6 tables; assembling it client-side would be 6 round trips per row |
| **Subscriber timeline** | **NEEDS RPC** | `subscriber_timeline(id)` — derived from activation events + payment history + ledger + audit. **Derived, never stored**: a stored timeline is a second truth that drifts |
| Activations per subscriber | **READY** | `saas_activation_events` (admin) / `_safe` view |
| Invoice queue | **NEEDS RPC** | `list_installation_invoices` |
| Ready for payment | **READY** | `installation_entitlement_eligibility` |
| Holds | **READY** | `installation_holds` + `place_installation_hold` |
| Monthly cycle workspace | **NEEDS RPC** | `installation_cycle_state(id)` — lifecycle position and blockers |
| Classification counts | **NEEDS RPC** | `subscriber_classifications` is **empty in production** — classification runs in the browser during import and is never persisted. See §3 |
| Payment batches | **READY** | tables + `revalidate_payment_batch` |
| Import history | **READY** | `saas_import_batches` |
| Archive | **READY** | closed cycles |

### Finance / exceptions / master / system / reports
| Need | Class | Note |
|---|---|---|
| Batch list and detail | **NEEDS RPC** | `list_payment_batches`; detail READY |
| Ledger, paged | **NEEDS RPC** | `list_financial_ledger` |
| Exceptions queue | **NEEDS RPC** | `list_commission_exceptions` |
| Exception → action | **PRESENTATION** | playbook exists in `commission-vnext.js` |
| Agents, aliases, packages, FDT | **READY** | small tables + `register_fdt`, `register_fdt_bulk` |
| Scheme versions | **READY** | `publish_scheme_version`, `publish_commission_version` |
| **Scheme version diff** | **NEEDS VIEW** | `scheme_version_diff(a,b)` — versions are stored; comparison is not exposed |
| Users | **READY** | `profiles` + admin Edge Function |
| Effective permission | **READY** | `explain_permission` — already returns role, overrides, decision |
| Audit, paged and filtered | **NEEDS RPC** | `list_audit_events` |
| Six reports | **READY** | all six exist and are authoritative |
| Report → record drill-down | **PRESENTATION** | routing only |

---

## 3. Two real data gaps

### 3.1 `subscriber_classifications` is empty

The table exists with its guard constraint (`NEW` requires a proven-complete
source). Production holds **0 rows**: `classifyNewness` runs in the browser during
import and its output is displayed, never persisted.

Consequence: the installation cycle screen cannot show NEW / EXISTING /
NEEDS_REVIEW counts without re-deriving them client-side across 20,772
subscribers — which is exactly the "no financial truth in the browser" rule.

**Fix:** persist classification at import time through an RPC that applies the
same rules server-side. This is a **workflow gap, not a rule change** — the rules
are already specified and tested; they simply run in the wrong place.

**Severity P1**, not P0: no money depends on it today, because installation
entitlements are not yet generated from it.

### 3.2 No finalization-blocker projection

`calculate_commission_cycle` knows exactly why a cycle cannot be finalized. It
raises on the count and does not expose the list. The review screen needs to show
an operator what to fix, without running a calculation to find out.

**Fix:** `commission_finalization_blockers(cycle)` — read-only, returns reason,
count, subscribers, indicative money, and the resolving screen. **Severity P0**
for the review screen.

---

## 4. Not needed

No new table is required for any target screen. Everything either exists, or is a
read-only projection of what exists. Two things must **not** be built:

- **A stored timeline.** Derive it. A stored copy becomes a second truth.
- **A frontend cache of financial figures.** Screens re-read; the server is the
  cache boundary.

---

## 5. Summary

| Class | Count |
|---|---|
| READY | 24 |
| NEEDS VIEW/RPC | 12 |
| MISSING MODEL | 0 |
| MISSING WORKFLOW | 1 (persist classification) |
| PRESENTATION only | 4 |

**The backend is ~70% ready and needs no schema change.** The 12 additions are
read-only list and projection functions over existing authoritative tables.
