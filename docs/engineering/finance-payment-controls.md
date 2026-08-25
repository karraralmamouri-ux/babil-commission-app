# Finance and Payment Controls

---

## 1. Controls that already work

**FACT.** Verified against production `fbgffpxpskjzgheheikd` during the historical import
release. These are the product's strongest area and must not regress.

| Control | Implementation | Evidence |
|---|---|---|
| Idempotency | `request_id` matched against `audit_logs` before any write; replay returns the original result | re-import produced 0 new rows, twice |
| Concurrency | `pg_advisory_xact_lock` on a period key + `select … for update` | concurrency test: 2 sessions, 1 payment, 1 ledger row |
| No second payment | `installation_payments_entitlement_key unique (entitlement_id)` | schema |
| Invoice gate | `record_installation_payment` refuses unless `invoice_status = 'approved'` | schema |
| DONE unpayable | `installation_entitlements_done_is_unpayable` | schema |
| Unresolved unpayable | `installation_state_unresolved_is_never_eligible` | 4/4 direct writes refused on production |
| Mismatch cannot be resolved | `installation_state_mismatch_is_unresolved` | as above |
| Settled rows frozen | trigger `protect_settled_installation_entitlement` | schema |
| Server-side authority | every financial RPC is `SECURITY DEFINER` with `set search_path = ''` and checks `current_app_role()` | non-admin rejected on production |
| Browser cannot write | `authenticated` holds `SELECT` only; `anon` holds nothing | `aclexplode` on production |
| Amounts never client-supplied | stage and amount derived server-side from `Remaining` | `import_installation_history` |

**One historical lesson worth keeping visible.** Migration `20260815160000` revoked only
`insert, update, delete` from `authenticated`. Supabase's default privileges had already
granted `ALL`, which left `TRUNCATE` — and **TRUNCATE is not filtered by RLS**. Any signed-in
user of any role could have emptied the tables. Fixed by `20260815180000` with
`revoke all` followed by an explicit `grant select`.

**Rule for every future table: `revoke all` first, then grant only what is needed.**
Never `revoke` a list of verbs.

---

## 2. Gaps

| Gap | Consequence |
|---|---|
| No hold model | nothing can pause a subscriber without deleting or editing financial state |
| No reversal path | **CLOSED.** The ledger and RPCs shipped as a Phase 0 foundation (§5–6); the installation-domain operator UI shipped in Batch 2 (§5, "UI deliberately deferred"). The commission-domain equivalent (`commission_rows`) has no frontend yet — see that note. |
| No payment batch | payments are one-at-a-time; no reviewed set, no batch total |
| No cycle close | nothing freezes a period |
| Tier basis client-supplied | see §4 |
| No invoice uniqueness | the same external invoice can back two entitlements |

**The missing reversal path is the most urgent.** The system is safe against accidental
double payment but has no answer to "we paid the wrong person" other than a manual database
edit, which is exactly what the constraints are designed to prevent.

---

## 3. Payment batch design

**RECOMMENDATION.**

```
Draft ──► Reviewed ──► Posted ──► Paid
```

At **Posted**, the server revalidates every line from scratch and refuses the whole batch if
any line fails:

- entitlement still exists, still eligible, still unpaid
- invoice still `approved` and not linked to another paid entitlement
- subscriber not held, not unresolved, not DONE
- cycle still open
- scheme version unchanged since the line was prepared
- `agent_id_at_payment` still resolves

**Never trust the client's view of eligibility.** The browser's list is a proposal; the
server's revalidation is the decision.

Each posted line writes one ledger row carrying `request_id`, so a retried post is a no-op.

---

## 4. Commission tier basis — a real exposure

**FACT.** In `publish_commission_month`:

```sql
v_tier_basis := coalesce((v_item ->> 'tier_basis_qty')::integer, v_p35 + v_p45 + v_p65);
...
or v_tier_basis < v_p35 + v_p45 + v_p65   -- rejected
...
v_expected_tier := resolve_commission_tier_key(p_tiers, v_tier_basis);
if v_expected_tier is distinct from v_applied_tier then raise ...
```

The server checks that the applied tier is consistent with the basis, and that the basis is
not *below* the row's own quantity. It never recomputes the basis independently.

**INFERENCE.** A client that inflates `tier_basis_qty` upward — for example sending 401 for
an agent whose true pooled quantity is 150 — passes both checks and moves the agent from T1
to T3. Using the shipped default tiers that is 4000 → 6000 IQD per P35 activation.

This requires an authenticated admin, so it is not an anonymous exploit. It is an integrity
gap: **the database cannot currently prove a published month's tier was correct.**

**APPROVED at review.** The client-supplied basis must not remain the financial source of
truth. The server or database derives or verifies the authoritative basis from trusted
persisted data. The browser may display a projected tier; it must never determine it. This is
a **critical integrity migration requirement**, not a nice-to-have.

**Fix, in two steps.**

- *Phase 0a* — recompute the pooled basis from the rows in the same publish payload, grouped
  by `tier_group_id`, and reject a mismatch. The data is already there; only the check is
  missing.
- *Phase 8* — derive the basis from persisted subscriber-level facts
  (`commission_activation_facts`), so the payload stops being an input to the calculation at
  all.

---

## 5. Invoice controls

**RECOMMENDATION.**

- `unique (external_invoice_id, invoice_source)` on `invoice_links` — one invoice backs one
  entitlement.
- `invoice.verify` and `payment.execute` are distinct capabilities.
- `transaction_id` from SaaS is stored as a SaaS reference, **never** written into
  `external_invoice_id`, until Odoo integration establishes a real mapping.
- Odoo fields (`odoo_model`, `odoo_record_id`) are reserved now and populated later. No Odoo
  integration is built in this phase; when it is, it runs in an Edge Function with the
  credentials server-side, never in the browser.

---

## 5.5 Implemented in Phase 0b — the correction layer

`20260818090000_add_financial_correction_ledger.sql`.

**`financial_ledger`** — one table serving both domains, with real financial
columns rather than a JSON blob. `domain` · `txn_type` · `source_origin` ·
`source_table` / `source_id` · `agent_name` · `subscriber_id` · `stage` ·
`month_key` · `original_cycle_key` · `amount` · `direction` · `currency` ·
`status` · `reason` · `reverses_entry_id` · `corrects_entry_id` · `request_id` ·
actor and timestamps.

**`financial_net_position`** — a view answering original / reversed / corrected /
**net** per source record, without touching any original row.

**Two RPCs, admin only:**

| RPC | Produces |
|---|---|
| `reverse_financial_entry(domain, source_id, reason, request_id)` | `REVERSAL` referencing the original. Net → 0. |
| `correct_financial_entry(domain, source_id, reason, agent, amount, request_id)` | `REVERSAL` + `CORRECTION` in one transaction. Net → the corrected figure. |

**Why the ledger starts empty.** Production holds zero payments today
(`installation_payments` 0, commission paid 0.00), so there is nothing to
backfill and no synthetic history is invented. `ensure_financial_origin` clones a
live record into the ledger only at the moment it is first corrected, tagged
`LEGACY_BACKFILL`.

**Why the entitlement is never reset.** A reversal does not return the
subscriber to `eligible`. Doing so would let the normal payment path pay the same
stage a second time — the exact failure this phase exists to prevent. The
entitlement keeps saying `paid`, which remains true: it *was* paid once. What
changed is the net, and the net lives in the ledger.

**Guards:** one reversal per entry (partial unique index, so it holds under
concurrency), `(created_by, request_id, txn_type)` unique for idempotency,
advisory lock per source record, mandatory reason, and a trigger that refuses
`DELETE` outright and permits `UPDATE` only of `status`.

### UI — installation domain shipped, commission domain deferred

Batch 2 wired the installation domain: a "تصحيح / عكس" action pair on the
entitlements-tab table (`src/features/finance/paymentCorrections.ts`, called from
`src/features/installation/index.ts`), gated on the existing `payment.correct` /
`payment.reverse` capabilities for visibility only — the server's own
`current_app_role() = 'admin'` check is unaffected by the frontend gate. The
subscriber case file's history tab now also renders the ledger's
`CORRECTION`/`REVERSAL`/`ADJUSTMENT` rows for that subscriber (via the existing
`subscriber_corrections()` read, not a new query), since `subscriber_timeline()`
indexes its `AUDIT` branch by `installation_subscribers.id` while these RPCs log
under `entity_type = 'financial_ledger'` — a different id space that the
timeline was never going to surface on its own.

**Still deferred: the commission domain.** `ensure_financial_origin` supports
`p_domain = 'commission'` against `commission_rows` (frozen legacy history), but
no screen lists individual `commission_rows` by id — only aggregated
scope/zone rollups exist today. Building a browse surface for this was judged
out of scope for Batch 2's minimal-footprint goal; it needs its own small
paginated RPC before a correction action can be attached to a row.

---

## 6. Reversals

**APPROVED — critical foundation, scheduled in Phase 0b.**

A reversal is a new ledger row with `txn_type = 'REVERSAL'` and `reverses_ledger_id` pointing
at the original. The original is never modified or deleted. Requires `payment.reverse`, a
mandatory reason, and full audit. Current state is recomputed from the ledger, so the
subscriber returns to eligible for that stage automatically.

**Wrong-agent payment resolves as three retained rows:**

| # | Row | `txn_type` |
|---|---|---|
| 1 | original payment to Agent A | `PAYMENT` |
| 2 | reversal of row 1 | `REVERSAL` |
| 3 | payment to Agent B | `PAYMENT` |

**Direct database editing must never be the normal correction mechanism.** If operators have
to edit rows by hand, every control in §1 becomes theatre.
