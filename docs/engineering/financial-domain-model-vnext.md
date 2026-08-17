# Financial Domain Model — vNext

**No migration is created by this document.** Proposal only.
Inspected state: `main` @ `94b1873`, production `fbgffpxpskjzgheheikd`.

---

## 1. What exists today

**FACT.** Nine migrations, in order:

```
20260804170000  reconstructed_baseline          commission_months/rows/agents, profiles, audit_logs, app_settings
20260804183000  harden_authorization
20260804203000  add_nonnegative_financial_constraints
20260804230000  add_atomic_financial_rpcs       calculate_commission_due, record_commission_payment
20260809190000  add_central_month_workflow      status draft/approved, is_visible, publish_commission_month
20260815113000  add_commission_source_breakdown source_breakdown jsonb + reconciliation trigger
20260815160000  add_installation_fees           entitlements, batches, payments + 3 RPCs
20260815180000  tighten_installation_grants     TRUNCATE hole fix
20260816090000  add_installation_history        subscribers, subscriber_state, payment_history + import RPC
```

**FACT.** Entity inventory by kind:

| Kind | Existing tables |
|---|---|
| Master | `profiles`, `commission_agents` (per-month, not canonical) |
| Event/ledger | `installation_payment_history`, `installation_payments` |
| Configuration | `app_settings` (single JSON blob), tiers embedded in `commission_months.tiers` |
| Snapshot | `commission_months.tiers`, `installation_subscriber_state` |
| Audit | `audit_logs`, `commission_audit_logs` |
| Raw source | **none** |

**The two gaps that shape everything else: there is no canonical agent entity, and no raw
SaaS storage at all.**

---

## 2. Proposed target model

Smallest model that satisfies the requirements. Names are suggestions.

### 2.1 Raw source — immutable

```
raw_saas_users
  id, saas_user_id (unique), username, subscriber_name,
  created_at_saas, raw jsonb, imported_at, import_batch_id

raw_saas_activation_events
  id, import_batch_id, saas_user_id, username,
  parent, fdt, fat, port,
  profile_name, activated_at,
  old_expiration, new_expiration, activations_count,
  price, total_price, transaction_id, card, card_owner,
  cancelled boolean, raw jsonb
  unique (import_batch_id, saas_user_id, activated_at, profile_name)
```

**Rule.** Append-only. No `UPDATE`, no `DELETE`. `raw jsonb` preserves every column the
export carried, including ones not yet modelled — so a later requirement never needs a
re-export.

### 2.2 Master

```
agents            id, code, official_name, status, notes
agent_aliases     id, agent_id, alias, alias_type ('saas_account'|'display'|'legacy'), active
                  unique (lower(alias)) where active
fdts              id, code, zone, agent_id, effective_from, effective_to
packages          id, code ('P-35000','Loan-3'), name,
                  classification ('qualifying_paid_activation'|'debt_service'|'non_qualifying'|'deprecated'),
                  commission_bucket ('p35'|'p45'|'p65'|null),
                  effective_from, effective_to
```

**FACT.** `agent_aliases` replaces `assets/data/raw-import-config.json` `agents[].accounts[]`
— 11 agents, 24 aliases on the first alone. Migration is a straight copy.

**`packages.commission_bucket` removes the hardcoded ternary** at `index.html:706`
(`profile==='P-35000'?'p35':…`).

### 2.3 Subscriber

```
subscribers
  id, subscriber_code (stable internal), saas_user_id, username,
  display_name, classification ('reseller'|'direct_company'),
  source_parent_at_activation,   -- immutable
  current_saas_parent,           -- refreshed on sync
  effective_agent_id,            -- business truth, audited
  fdt_id, fat, port, zone,
  saas_created_at, first_confirmed_installation_at,
  operational_status, created_at, updated_at

subscriber_attribution_history
  id, subscriber_id, field, old_value, new_value, reason,
  changed_by, changed_at

subscriber_transfer_history
  id, subscriber_id, from_agent_id, to_agent_id,
  effective_date, reason, performed_by, created_at
```

**Migration note.** `installation_subscribers` already holds the 5,693 identities with
`subscriber_key` unique. It becomes `subscribers`, gaining columns rather than being
replaced.

### 2.4 Installation scheme — versioned configuration

```
installation_fee_schemes            id, code, name, status
installation_fee_scheme_versions    id, scheme_id, version, effective_from, effective_to,
                                    status ('draft'|'review'|'published'|'superseded'),
                                    published_by, published_at
installation_fee_stage_definitions  id, scheme_version_id, stage_code, sequence,
                                    amount, expected_remaining, is_terminal
                                    unique (scheme_version_id, stage_code)
```

Seeded from the current V1: four stages plus DONE, thresholds 13000/10000/7000/4000/0,
amounts 3000/3000/3000/4000/0.

```
subscriber_installation_enrollments
  id, subscriber_id, scheme_version_id, enrolled_at,
  entry_stage_code,        -- P3 for a migrated subscriber, not P1
  unique (subscriber_id)   -- one active enrolment
```

**`scheme_version_id` is immutable after enrolment.** A future V2 cannot move a V1
subscriber.

### 2.5 Entitlement and ledger

```
installation_entitlements        (exists) + scheme_version_id, enrollment_id,
                                 agent_id_at_entitlement, cycle_id, hold_id
                                 unique (subscriber_id, stage_code, cycle_id)

installation_payment_ledger      id, subscriber_id, entitlement_id,
                                 stage_code, amount, direction ('debit'|'credit'),
                                 txn_type, source_origin,
                                 agent_id_at_payment, batch_id, cycle_id,
                                 occurred_on, posted_at, posted_by,
                                 reason, request_id, reverses_ledger_id
```

**Transaction types — APPROVED at review.**

| `txn_type` | Meaning | Typical origin |
|---|---|---|
| `HISTORICAL_PAYMENT` | an instalment paid before cutover | Excel baseline |
| `PAYMENT` | an operational disbursement | payment batch |
| `ADJUSTMENT` | a deliberate change in the amount owed | finance |
| `CORRECTION` | a fix to a mis-recorded attribute | finance |
| `REVERSAL` | undoes one specific prior row | finance, with `reverses_ledger_id` |

`source_origin` records provenance (`excel_baseline`, `batch:<id>`, `correction:<id>`).

**Key design point.** Current state is derived from the ledger; history is permanent. A
reversal is a new row pointing at the row it reverses — **never a delete, never an edit**.

**Physical migration — APPROVED to remain compatible.** `installation_payment_history`
(17,117 rows) and `installation_payments` may stay **physically separate during migration**.
What the architecture requires is one *coherent ledger concept*, not one table on day one. A
view or compatibility layer presenting both under the vocabulary above satisfies it, and is
safer than a big-bang rewrite. Physical consolidation, if it happens at all, comes only after
the reconciliation gate proves derived state matches stored state exactly.

### 2.6 Holds, invoices, cycles, batches

```
holds          id, subscriber_id|agent_id, hold_type, category ('system'|'manual'),
               reason, note, created_by, created_at,
               released_by, released_at, resolution

invoice_links  id, entitlement_id, external_invoice_id, invoice_number,
               invoice_reference, invoice_source ('odoo'|'manual'|'saas'),
               verification_source, verified_by, verified_at,
               odoo_model, odoo_record_id
               unique (external_invoice_id, invoice_source)   -- one invoice, one link

monthly_cycles id, period, domain ('installation'|'commission'),
               status, opened_at, closed_at, closed_by, snapshot jsonb

payment_batches id, cycle_id, code, status ('draft'|'reviewed'|'posted'|'paid'),
                total_amount, prepared_by, reviewed_by, posted_by, posted_at
```

**`unique (external_invoice_id, invoice_source)` is what prevents the "same invoice linked
twice" scenario** (`risk-and-open-decisions.md` S-06).

### 2.7 Commission — unique users and snapshots

```
commission_scheme_versions   id, version, tier_basis ('unique_active_users'|'activation_events'),
                             tier_scope ('agent'|'fdt'), effective_from, status
commission_tier_definitions  id, scheme_version_id, tier_key, min_qty, max_qty,
                             rate_p35, rate_p45, rate_p65

commission_cycle_snapshots   id, cycle_id, scope_type, scope_id,
                             active_unique_users_snapshot,
                             commissionable_activations,
                             tier_key_snapshot, tier_rule_version,
                             calculated_at
```

**FACT — why this matters.** Today the tier basis is `p35 + p45 + p65`
(`index.html` `calc()`), i.e. **activation counts**, and the basis value is
**client-supplied** (`tier_basis_qty` in the publish payload). The server validates only
that the applied tier matches the supplied basis and that the basis is not *below* the row's
own quantity (`20260815113000` line 201) — it never recomputes the basis independently.

**FACT — the accidental partial correctness.** `calculateRawImport` skips a row whose `id`
was already seen in the same file (`seenIds`, `duplicateIds`). So within one month a
subscriber is counted once. That happens to match "unique users" for tier population — but
it also means the second and third activations **earn no commission at all**, which does not
match the requirement that commissionable activations may be paid per event.

**APPROVED (D-02).** The two measures are separate and must never be conflated:

- `active_unique_users_snapshot` = `COUNT(DISTINCT subscriber)` in scope → **drives the tier**
- `commissionable_activations` = every distinct qualifying activation event → **drives payout**

A subscriber with two qualifying events in one cycle contributes **1** to tier population and
**2** commissionable activations.

```
commission_activation_facts   id, cycle_id, subscriber_id, agent_id_at_activation,
                              raw_event_id, activation_identity,
                              package_code, commission_bucket,
                              is_qualifying, counted_for_tier, counted_for_payout
                              unique (cycle_id, activation_identity)
```

**`activation_identity` is an event key, never a subscriber key.** Derived from the SaaS
activation id, or `transaction_id`, or the safest composite the export supports
(`saas_user_id + activated_at + profile_name`). The unique constraint deduplicates a
*re-imported event*; it must never deduplicate a *second genuine activation*.

Tier population is then `count(distinct subscriber_id) where counted_for_tier`, and payout is
driven by `count(*) where counted_for_payout` — one table, two questions, no ambiguity.

Both figures are frozen into `commission_cycle_snapshots` at close.

**Legacy note.** `seenIds` in `calculateRawImport` deduplicates by subscriber and therefore
drops the second activation entirely. This is incompatible with the approved rule and is
replaced in Phase 8 (**R-05**).

**OPEN — D-03:** the definition of "active" in `active_unique_users_snapshot`. The tier basis
is approved as unique active users; the activity test itself is still pending business
confirmation and must not be invented.

### 2.8 Permissions and audit

```
capabilities            code (pk), domain, description
role_templates          id, code, name
role_template_caps      role_template_id, capability_code
user_permission_grants  id, user_id, capability_code,
                        effect ('grant'|'revoke'), granted_by, granted_at, reason
permission_scopes       id, user_id, scope_type ('agent'|'fdt'|'zone'), scope_id
audit_events            id, actor_id, action, entity_type, entity_id,
                        before jsonb, after jsonb, reason, request_id, created_at
```

---

## 3. Compatibility

**RECOMMENDATION.** Nothing above deletes an existing table. `commission_rows`,
`commission_months`, `commission_agents` keep working unchanged for the whole migration.
`installation_entitlements` gains columns. `installation_payment_history` is read by the
ledger view before it is folded in. Every step is additive and independently revertible.
