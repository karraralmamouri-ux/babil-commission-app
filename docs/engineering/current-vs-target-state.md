# Current State vs Target State

One row per domain: what exists, what is wanted, the gap, the risk, and how to get there.
Evidence is cited from this repository at `main` @ `94b1873`.

---

## Agent identity

| | |
|---|---|
| **Current** | Names in JSON. `raw-import-config.json` holds 11 agents; aliases live in `agents[].accounts[]` (24 on the first agent). `commission_rows.name` is a string. `commission_agents` is per-month, not canonical. |
| **Target** | `agents` + `agent_aliases` tables; agent identity is a foreign key. |
| **Gap** | No canonical entity; no referential integrity; a renamed agent breaks history joins. |
| **Risk** | Medium. Aliases are already editable centrally, so the operational pain is low today. |
| **Migration** | Phase 1. Straight copy from the JSON; import keeps reading JSON until Phase 3. |

## Subscriber identity

| | |
|---|---|
| **Current** | Exists for installation only: `installation_subscribers.subscriber_key` unique, 5,693 rows. **Commissions have no subscriber concept at all.** |
| **Target** | One `subscribers` registry serving both domains. |
| **Gap** | Commissions cannot answer "which subscribers did this agent earn on". |
| **Risk** | **High** — this is what blocks unique-active-user tiers (requirement §24). |
| **Migration** | Phase 3, after raw storage exists. |

## Installation fee stages

| | |
|---|---|
| **Current** | Five constants, defined twice: `STAGE_BY_REMAINING` in JS, `installation_stage_for_remaining` in SQL. |
| **Target** | Versioned scheme with stage definitions; SQL becomes a lookup. |
| **Gap** | Duplication (**R-02**); no versioning; a V2 would silently move V1 subscribers. |
| **Risk** | Medium. |
| **Migration** | Phase 4. Gate: all 5,693 keep their exact stage. |

## Historical payments

| | |
|---|---|
| **Current** | **Adequately preserved.** 17,117 rows in `installation_payment_history`, unique per `(subscriber, stage)`, every one carrying its date, protected by RLS and SELECT-only grants. |
| **Target** | Same data as `kind='historical'` in a unified ledger alongside operational payments and reversals. |
| **Gap** | Historical and operational payments live in separate tables with different shapes. |
| **Risk** | Low — the data itself is safe. |
| **Migration** | Phase 5, additive copy, reconciliation gate before proceeding. |

## Raw SaaS events

| | |
|---|---|
| **Current** | **None.** Parsed in the browser, discarded after aggregation. |
| **Target** | `raw_saas_activation_events`, append-only, with `raw jsonb`. |
| **Gap** | Total. Nothing re-derivable; dropped rows leave no trace. |
| **Risk** | **High** — everything downstream depends on it. |
| **Migration** | Phase 2. Gate: derived aggregates match the browser's, exactly. |

## New vs existing detection

| | |
|---|---|
| **Current** | None. `seenIds` deduplicates within one file and forgets. |
| **Target** | Registry-first engine producing NEW / EXISTING / NEEDS_REVIEW. |
| **Gap** | Total. |
| **Risk** | **High** — a wrong NEW pays a full installation cycle again. |
| **Migration** | Phase 3. Depends on **D-01**. |

## Attribution

| | |
|---|---|
| **Current** | One value. `parent` maps to an agent at import; nothing records what SaaS said versus what the business decided. |
| **Target** | `source_parent_at_activation` (immutable) · `current_saas_parent` · `effective_agent_id` (audited). |
| **Gap** | Corrections are not expressible. |
| **Risk** | Medium-high — attribution decides who is paid. |
| **Migration** | Phase 3. |

## Transfers

| | |
|---|---|
| **Current** | None. |
| **Target** | First-class events; `agent_id_at_payment` frozen on historical rows. |
| **Gap** | Total. |
| **Risk** | **High** — a naive `UPDATE` would silently rewrite who earned past money. |
| **Migration** | Phase 3. |

## Holds

| | |
|---|---|
| **Current** | None. |
| **Target** | Typed system and manual holds, reversible, erasing nothing. |
| **Gap** | Total (**R-07**). |
| **Risk** | Medium — today pausing someone means editing financial state. |
| **Migration** | Phase 5. |

## Invoices

| | |
|---|---|
| **Current** | `installation_entitlements.invoice_status` + note. No external reference, no uniqueness. |
| **Target** | `invoice_links` with `unique (external_invoice_id, invoice_source)` and Odoo fields reserved. |
| **Gap** | The same invoice can back two entitlements. |
| **Risk** | Medium. |
| **Migration** | Phase 6. |

## Payment ledger

| | |
|---|---|
| **Current** | Two tables, no reversal. `installation_payments` unique per entitlement; settled rows frozen by trigger. |
| **Target** | One ledger with `kind` and `reverses_ledger_id`. |
| **Gap** | **No legal correction path exists** (**R-03**). |
| **Risk** | **Critical** — a wrong payment forces an out-of-audit database edit. |
| **Migration** | **Phase 0b — promoted at review to a foundation that must land before payment workflows expand.** Typed transactions (`HISTORICAL_PAYMENT`/`PAYMENT`/`ADJUSTMENT`/`CORRECTION`/`REVERSAL`); physical table consolidation optional, compatibility layer preferred. |

## Commission tier calculation

| | |
|---|---|
| **Current** | Basis = `p35+p45+p65` (activation counts), deduplicated by `id` within one file. Scope: **agent** for OLD ZONE (`tierGroupId`/`groupTotals`), **per-FDT** for NEW ZONE. Basis is **client-supplied**; the server validates the tier against it but never recomputes it. Tiers are snapshotted per month — that part is correct. |
| **Target** | Basis = `COUNT(DISTINCT active subscriber)` in scope; commissionable activations counted separately; both frozen in `commission_cycle_snapshots`. |
| **Gap** | Wrong basis; repeat activations dropped rather than paid; server cannot prove the tier. |
| **Risk** | **Highest** (**R-01** critical, **R-05**). |
| **Migration** | Phase 0a: server-side basis check (**approved as a critical integrity requirement**). Phase 8: unique-active-user basis and event-level commissionable activations per **approved D-02** — waits on **D-03** only. |

## Configuration

| | |
|---|---|
| **Current** | `app_settings` single JSON blob + tiers snapshotted per month. Stage table, package buckets and role matrix hardcoded. |
| **Target** | Master data + versioned configuration with Draft → Review → Published and effective dates. |
| **Gap** | No versioning outside commission tiers, which already do it correctly. |
| **Risk** | Medium. |
| **Migration** | Phases 1 and 4. |

## Permissions

| | |
|---|---|
| **Current** | 4 roles × 6 booleans, hardcoded in `ROLE_PERMISSIONS` **and** in `profiles_role_check`. Server-side enforcement is real and works. |
| **Target** | Capabilities + role templates + per-user overrides + scopes. |
| **Gap** | No granularity, no overrides, no scoping, **and no explainability** (**R-06**). |
| **Risk** | Medium. |
| **Migration** | Phase 7, starting with a behaviour-preserving shim. |

## Audit

| | |
|---|---|
| **Current** | Real and used. `audit_logs` with `before_data`/`after_data`/`request_id`; financial RPCs write on every operation; `request_id` doubles as the idempotency key. |
| **Target** | Extend to permission changes, configuration publishing, holds, transfers, reversals, cycle close. |
| **Gap** | Coverage, not mechanism. |
| **Risk** | Low. |
| **Migration** | Alongside each phase. |

## Cycle closure

| | |
|---|---|
| **Current** | Commissions have `status ∈ {draft, approved}` and `update_commission_row` refuses a non-draft month. Installation has no cycle. |
| **Target** | Full lifecycle with an immutable close snapshot for both domains. |
| **Gap** | Installation has none; commission's is two states. |
| **Risk** | Medium. |
| **Migration** | Phase 6. **D-09 approved:** reopen only when no posted or paid money exists; otherwise correction/adjustment/reversal. |

## Archive

| | |
|---|---|
| **Current** | Commission archive snapshots data **and its tiers** — so a closed month keeps its own rates. Genuinely good. |
| **Target** | Same idea extended: configuration versions, tier snapshots, matching decisions, batches. |
| **Gap** | Installation has no archive. |
| **Risk** | Low-medium. |
| **Migration** | Phase 6. |
