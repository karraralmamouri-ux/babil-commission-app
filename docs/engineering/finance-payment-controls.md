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
| No reversal path | a wrong payment can only be corrected by mutating history, which the triggers correctly forbid — so today there is **no** legal correction path |
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

**RECOMMENDATION.** Recompute the pooled basis server-side from the rows in the same
publish payload, grouped by `tier_group_id`, and reject any mismatch. The data needed is
already in the payload; only the check is missing.

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

## 6. Reversals

**RECOMMENDATION.** A reversal is a new ledger row with `kind = 'reversal'` and
`reverses_ledger_id` pointing at the original. The original is never modified or deleted.
Requires `payment.reverse`, a mandatory reason, and full audit. Current state is recomputed
from the ledger, so the subscriber returns to eligible for that stage automatically.
