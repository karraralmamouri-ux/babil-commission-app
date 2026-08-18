# Product Consolidation — As Built

Written after deployment, from measured results.

Starting SHA `8f1d967` → merged `7bc7ac6`.
Migrations `20260822090000` · `20260822120000` · `20260822150000` · `20260822180000`.

---

## 1. The payout gap, closed

Before this phase the engine computed per-event entitlements and finalized
snapshots, but payment still ran through legacy `commission_rows`. Financial
truth and money movement were two different things.

The payable unit is now the **finalized scope snapshot**:

```
source_table = 'commission_cycle_snapshots'
source_id    = snapshot.id
```

That single choice is what made the rest cheap. `effective_paid_amount`,
`reverse_financial_entry` and `correct_financial_entry` already key on
`(domain, source_id)`, so they work on vNext **with no change inside them**. No
second ledger, no parallel money path, no divergence to manage later.

`commission_scope_payable(snapshot_id)` answers the whole question from
authoritative sources only — gross from the snapshot, paid/reversed/adjusted/net
from the ledger:

| field | source |
|---|---|
| gross | snapshot |
| paid · reversed · adjusted · net_paid | ledger |
| remaining | gross − net_paid |
| payable | finalized **and** vNext **and** remaining > 0 |

Proven: a vNext payment is posted, then reversed through the **existing** RPC;
net paid returns to zero, remaining returns to full, the original entry survives,
and the reversal is a second row rather than an edit.

---

## 2. Payment batches

`commission_payment_batches` / `_items`, mirroring the installation batch model.

- `revalidate_commission_batch` re-reads every item and **clamps the amount to
  what is actually remaining**, so a stale prepared figure cannot overpay.
- `post_commission_batch` re-validates again inside the transaction, row-locks
  each item, writes one ledger entry per item, and records the entry id on the
  item. A CHECK makes `PAID` without a ledger entry impossible.
- A partial unique index stops one snapshot sitting in two live batches.
- Idempotent by `request_id`; an advisory lock serialises concurrent posts.

---

## 3. One payment authority per period

A trigger on `commission_rows` refuses a `paid` change for any period a
**finalized vNext cycle** governs. Legacy months stay payable through the legacy
path; vNext periods do not. One period can never have two payment authorities.

---

## 4. legacy_month_id — resolved, not left dangling

The brief required this be wired or deprecated rather than left ambiguous.

**Decision: kept as a descriptive cross-reference, never a payment input.**

- Documented on the column itself (`comment on column`).
- Read by no payment path — asserted by test.
- A trigger stops two cycles claiming the same legacy month.

Removing it would have required altering a live table for no gain; leaving it
undocumented was the actual problem, and that is fixed.

---

## 5. Reporting

Six server-side functions, all reading authoritative persisted data:

| Report | Function |
|---|---|
| Management Summary | `report_management_summary` |
| Commission Cycle Detail | `report_commission_cycle_detail` |
| Agent Financial Statement | `report_agent_statement` |
| Installation Fees Detail | `installation_financials` |
| Exceptions / Blocked | `report_open_exceptions` |
| Audit / Corrections | `report_audit_trail` |

The client **reconciles summary against detail before rendering**. Two
contradicting numbers on one screen are worse than one missing number, so the
mismatch is surfaced rather than displayed as if both were true.

Total obligations deliberately exclude already-settled history — adding paid
history into an "obligations" figure inflates it without meaning.

The exception workspace unions both domains for display while keeping each
exception's own domain, reason and identity. The rules differ; merging them
financially would have hidden that.

---

## 6. Exports

- Columns **declared explicitly**, so a new response field cannot silently leak
  into a file.
- UTF-8 BOM so Arabic opens correctly in Excel rather than as mojibake.
- Requires `report.export`, a **separate** capability from `report.view` —
  export moves data out of the system, which is a different act from reading it.
- `export_commission_cycle` writes an audit row: who exported what, when.

---

## 7. Performance — evidence-led

Measured against real production volumes (57,522 events / 22 MB, 32,481
snapshots / 12 MB, 17,117 payment rows).

**The finding.** The cycle window filter — the entry point of every calculation
— was a sequential scan:

```
Seq Scan on saas_activation_events
  (actual time=2.466..516.036 rows=29246)
  Rows Removed by Filter: 28276
```

**One index added**, and the result on a selective window:

```
Index Only Scan using saas_activation_events_created_idx
  (actual time=1.867..4.099 rows=3038)
Execution Time: 4.476 ms
```

**518 ms → 4.5 ms.** Selectivity improves further as months accumulate.

**Nothing else was added**, because nothing else needed it:

- `financial_ledger_source_idx (domain, source_table, source_id)` already serves
  `commission_scope_payable` exactly.
- The qualifying-events view joins on `subscriber_identities.username_key`,
  `agent_aliases.alias_key`, `fdts.code`, `packages.code` — all already indexed.

`commission_cycle_events_page` caps server-side at 500 rows regardless of what
the client asks, so a browser cannot pull 57,522 rows in one request.

---

## 8. Security audit

Cross-domain audit came back clean on every dimension:

| Check | Result |
|---|---|
| Tables without RLS | none |
| Non-SELECT grants to app roles | none |
| SECURITY DEFINER without pinned `search_path` | none |
| Functions executable by anon/public | **1 finding** |

The finding: `set_updated_at`, a trigger function used by four triggers, was
executable by `anon` and `public`. Triggers run with the table owner's rights and
need no EXECUTE grant, so the grant was surplus. Revoked; verified 0 in
production.

---

## 9. app_settings

**Not deleted.** The legacy import genuinely reads `raw_import`, so the
dependency is not proven unnecessary and the brief forbids removing it on that
basis.

The real problem was two independently editable authorities for one concept.
That is fixed:

- `save_import_settings` now requires **`agent.manage`** — the same capability
  that governs the master tables. Nobody can edit agents in one place under a
  weaker permission than the other.
- `master_data_drift()` compares both and reports agents/aliases present in one
  but not the other, so divergence is visible immediately rather than inferred
  later from a wrong number.
- The table carries a `comment` marking it legacy and naming the removal
  condition: retire `raw_import` when `calculateRawImport` is retired.

Production check after deployment: **11 agents in master, 11 in settings — no
drift.**

---

## 10. Tests

| Suite | Count |
|---|---|
| JS | 289 (was 260) |
| Local database assertions | 348 (was 311) |

New coverage: vNext payment posting and its ledger entry; independence from
`commission_rows`; duplicate post rejection; overpayment impossibility; reversal
and correction on vNext outcomes; authority separation; report reconciliation
(detail sum equals summary); export permission separation and audit; bounded
result sets; and the legacy month link guard.

---

## 11. Deployment notes

A recurring tooling defect was fixed at the root this time. Building the
migration-recording query inside a bash line through `node -e` crossed three
quoting layers and failed silently with HTTP 400 **after** the migration had
already succeeded — meaning a migration applied but unrecorded, which is the
worst of both states. It bit three phases running. `record-migration.js` is now a
standalone file with no shell quoting in the path.

---

## 12. Remaining major work

- **Live Odoo integration.** The invoice model carries `odoo_model` and
  `odoo_record_id`; no external call is made.
- **Release-candidate audit and visual polish.** The UI is workflow-complete and
  permission-aware; it has not had a dedicated design pass.
- **Retiring `calculateRawImport`.** Requires every remaining month to move to
  vNext cycles. Until then `app_settings.raw_import` stays, aligned but present.
- **First real vNext cycle.** The engine, payout path and reports are deployed
  and exercised by tests, but production has zero commission cycles — by design,
  since deployment must not create financial results. The first genuine cycle
  will be the first end-to-end exercise against live data.
