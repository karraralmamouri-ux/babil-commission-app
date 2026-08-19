# BABIL FLOW — Post-launch backlog

Findings from the release-candidate audit at `4b975a6` that are **not** release
blockers. None affects the correctness of a financial calculation, none permits
an unauthorized payment, none exposes a secret.

Ordered by the cost of leaving it alone.

---

## 1. Enable point-in-time recovery — *do this first*

**Severity:** high (operational, not code)

**Cutover finding:** the organization is on the Supabase **free plan**, where
point-in-time recovery is not offered. Enabling it requires a plan upgrade — a
billing decision — so it was deliberately not actioned during cutover.

`pitr_enabled` is `false` and the backups API lists zero restorable points.
`walg_enabled` is true, so the physical infrastructure exists, but there is no
verified restore target the team can point at.

Mitigated for launch by a complete logical backup taken at cutover: 50 tables,
184,322 rows, per-table SHA-256, migration state and release SHA, at
`2026-08-19T05:50:30Z` against `e6a6933` / `v1.0.0`. Its per-table checksums are
byte-identical to the audit backup taken 28 minutes earlier, which independently
confirms no data drifted between audit and release.

Why it matters: the historical installation payment history (17,117 rows,
54,828,000 IQD) exists in exactly one place. It originated in Excel files the
business holds, so it is reconstructable — but reconstruction is a project, not
a restore.

**Action:** upgrade the plan, enable PITR, confirm the first restore point
appears, and record it in the runbook. Until then the logical backup **is** the
recovery point, and must be taken before every monthly import and before every
payment posting run.

---

## 2. Back-record the five pre-tracking migrations

**Severity:** medium

`supabase_migrations.schema_migrations` holds 29 versions; the repo holds 34.
The five missing are the earliest:

```
20260804170000_reconstructed_baseline
20260804183000_harden_authorization
20260804203000_add_nonnegative_financial_constraints
20260804230000_add_atomic_financial_rpcs
20260809190000_add_central_month_workflow
```

Their schema **is** present — every table, policy, constraint and RPC was
verified live during the audit. Production predates the tracking process and the
baseline was reconstructed from the running database, so the rows were never
written.

The hazard is narrow: a future `supabase db push` would try to replay them
against a database that already has their objects. That is already forbidden by
project policy and blocked by the deployment scripts, which is why this is not a
blocker.

**Action:** insert the five version rows (recording only — do not execute the
files), so the history is self-describing and `db push` stops being a loaded gun.

---

## 3. Narrow `subscriber_identities` read access

**Severity:** medium

The policy is `using (true)`, so any authenticated user — including `viewer` —
can read all 32,481 rows.

What that exposes: subscriber usernames, stable SaaS ids, raw parent, and cabinet
topology. What it does **not** expose: phone, national id, card owner or display
name. Those live in `saas_user_snapshots` and `saas_activation_events`, which are
admin-only and were verified during the audit to return zero rows to an
accountant.

This was a deliberate, documented decision in `20260819140000_restrict_raw_saas_pii`,
which judged the remaining ten tables reference data. It is worth revisiting only
because a read-only `viewer` has no obvious need for the full subscriber list.

**Action:** consider gating on `installation.view` or `commission.view`. Verify no
operational read breaks first — several screens join through this table.

---

## 4. Touch targets below 44px on mobile

**Severity:** low

The sidebar collapse toggle and the five navigation group headers render 30px
tall at 375px. That clears the WCAG 2.5.8 AA minimum of 24px but sits under the
44px comfort target.

**Action:** raise to 44px inside the `max-width: 860px` block. Purely CSS.

---

## 5. Clear in-memory workspace state on logout

**Severity:** low (defence in depth)

`logout()` revokes the token, removes the stored session — even when the logout
request itself fails — and returns to the login screen. The workspace is hidden
and every subsequent read re-fetches under the new identity with RLS applied, so
there is no path by which user B reads user A's data.

But the previous `state.data` object survives in JavaScript memory until
overwritten. Nothing renders it, and `setWorkspaceMode('loading')` hides the
workspace during the switch. It is simply tidier to clear it.

**Action:** null `state.data` and `state.archive` in `logout()`.

---

## 6. Retire the legacy backup script

**Severity:** low

`prod-backup.sh` covers 7 tables. Production now has 50. It predates the
commission vNext, installation operations, identity and SaaS domains, so a backup
taken with it would look successful while omitting most of the database — the
worst failure mode a backup tool has.

**Action:** replace it with the full-table approach used in this audit, or delete
it so nobody trusts it.

---

## 7. Deferred by product decision

- **Odoo integration.** Preparation is complete and intact; live discovery remains
  deferred. No key in code, no live call.
- **August invoice export.** Not available until month end by design.
- **119 unclassified cabinets.** Operational data classification, not a defect.
  Their money is blocked and the admin workflow to resolve them is live.
