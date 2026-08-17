# Historical Migration and Cutover

---

## 1. What is frozen

**FACT.** Production `fbgffpxpskjzgheheikd`, imported `2026-08-15`, as-of date
**`2026-07-31`**, batch type `historical`, one batch, one audit entry.

| | |
|---|---|
| Subscribers | 5,693 |
| State rows | 5,693 (one per subscriber, `as_of_date = 2026-07-31`) |
| Historical payments | 17,117 — P1 4,911 · P2 4,558 · P3 4,171 · P4 3,477 |
| Payments missing a date | 0 |
| Stages | DONE 3,492 · P1 774 · P2 347 · P3 385 · P4 690 · no stage 5 |
| Resolution | 5,674 resolved · 19 unresolved |
| Eligibility | 2,196 eligible · 3,497 blocked |
| Warnings | 14 financial mismatch · 5 blank Remaining · 15 incomplete detail |
| Per reseller | صفاء 1 → 3,945 · احمد عبد العباس → 1,505 · بارق ليث شعران → 243 |

The three subscriber counts match the workbook's own `Dashboard` sheet exactly.

---

## 2. The rule that governs everything

**Historical Excel payment data is a record of what was actually paid.**

It must **never** be reconstructed from SaaS activation history. If the financial history
says P1 paid, P2 paid, P3 pending, the system continues at **P3** and can never restart the
subscriber at P1.

**FACT.** Structurally guaranteed today by
`installation_history_identity_key unique (subscriber_uuid, stage)` — a second P1 for the
same subscriber is impossible.

**RECOMMENDATION.** Add a second guarantee at the entitlement layer: an entitlement may only
be raised for the subscriber's *current* stage as stored in
`installation_subscriber_state`, and `unique (subscriber_id, stage_code, cycle_id)` prevents
raising the same stage twice. Belt and braces, because this is the rule whose violation
would silently pay people twice.

---

## 3. Cutover

| Period | Authority | Mutability |
|---|---|---|
| ≤ 2026-07-31 | historical baseline | read-only forever |
| ≥ 2026-08-01 | operational system | normal workflow |

**Excel after cutover.** Useful for migration, export, reporting and reference. It must
**not** remain a second operational source of truth — two systems editing the same money is
how divergence starts.

**RECOMMENDATION.** Once the operational cycle runs, the historical import path should be
restricted (capability `installation.import_historical`, admin only) so a stray upload cannot
overwrite the baseline. The RPC is already admin-gated; making it a distinct capability makes
the intent explicit.

---

## 4. Migrating the baseline into the target model

Every step is additive; the 5,693 rows are never rewritten.

| Step | Action | Risk |
|---|---|---|
| 1 | `installation_subscribers` → `subscribers`, adding columns | none — rename or view |
| 2 | Backfill `effective_agent_id` from `reseller` via the new `agents`/`agent_aliases` | **low** — `reseller` is already the canonical name from the sheet |
| 3 | Seed fee scheme V1 from the current constants | none — mechanical |
| 4 | Create one enrolment per subscriber, `scheme_version_id = V1`, `entry_stage_code = current_stage` | **the critical step** |
| 5 | Present the 17,117 rows as `HISTORICAL_PAYMENT` — in place via a compatibility layer, or copied | none — additive, verify count |
| 6 | Derive current state from the ledger and compare with the stored state | **verification gate** |
| 7 | Only after 6 reconciles exactly: raise entitlements for the first operational cycle | — |

**Step 6 is the gate.** If ledger-derived state does not reproduce
`5,693 / 2,196 / 3,497 / 19` exactly, stop. Do not proceed to step 7.

### 4.1 The historical exceptions — APPROVED at review

These 34 subscribers are the migration's canary. If any phase "fixes" one of them without an
audited business correction, that phase has a bug.

| Group | Count | Approved treatment |
|---|---|---|
| Financial mismatch (`Total − Received ≠ Remaining`) | 14 | Stay **unresolved** and **blocked**. No automatic entitlement or payment. Clearing one requires an audited correction. |
| Blank `Remaining`, real subscriber | 5 | Stay **unresolved** and **blocked**. `Remaining` and stage are **never** inferred or guessed. |
| Balanced DONE with no P4 detail | 15 | Stay **financially resolved** on the accepted historical balance. P4 details and dates are **never synthesised**. The flag `historical_payment_detail_incomplete` is retained so the gap stays visible to audit. |

The first two groups are unpayable by construction — the CHECK constraints in
`finance-payment-controls.md` §1 already guarantee it. The third group is payable-by-nothing
because DONE has no next instalment, so no constraint is needed; what matters is that the
flag survives migration.

---

## 5. Preservation checks

Run before and after every migration step:

```sql
select count(*) from subscribers;                        -- 5693
select count(*) from <ledger>
  where txn_type = 'HISTORICAL_PAYMENT';                 -- 17117
select count(*) from <ledger>
  where txn_type = 'HISTORICAL_PAYMENT'
    and occurred_on is null;                             -- 0
select current_stage, count(*) from ... group by 1;      -- 3492/774/347/385/690/5
select count(*) where payment_eligible;                  -- 2196
select count(*) where resolution = 'unresolved';         -- 19
```

Plus the zero-guards that already pass on production: no duplicate subscribers, no duplicate
`(subscriber, stage)` payments, no unresolved-and-eligible row, no warned-and-eligible row,
no payment without a date.

---

## 6. Rollback

Every step is additive, so rollback is "stop using the new table", not "restore data". No
step deletes or rewrites a historical row. The logical backup taken before the historical
release — `C:\Users\karar.haydar\production-backups\babil-commission\20260815T202129Z\`,
nine tables with SHA-256 manifest, verified row-for-row — remains the pre-import reference
point.
