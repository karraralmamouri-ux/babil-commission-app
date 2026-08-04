# Supabase audit — 2026-08-04

## Scope and method

Read-only inspection was performed through the authenticated Supabase Dashboard and SQL Editor. No secrets, row values, or user emails are recorded here. Before preparing any remote change, the six public tables were exported locally to ignored storage and verified with SHA-256.

Project inventory:

- Free Plan in AWS `ap-northeast-1` (Tokyo).
- 2 Auth users and 2 active profiles: one `admin`, one `accountant`.
- 2 commission months and 82 normalized `commission_rows`.
- 0 legacy `commission_agents` rows.
- 0 rows in both `audit_logs` and `commission_audit_logs`.
- No `supabase_migrations.schema_migrations` history.
- No scheduled database backup is available on the Free Plan.
- Two deployed Edge Functions: `admin-create-user` and `admin-users`.

## Findings

### Critical — profile self-escalation

The original `profiles_update` RLS policy allowed a user to update their own profile, while `authenticated` had table-level `UPDATE` on all profile columns. A signed-in accountant could therefore attempt to set their own `role` to `admin` or reactivate an account. The admin Edge Functions correctly re-check the caller profile, but that check is only trustworthy when the profile cannot be self-promoted.

Remediation: `20260804183000_harden_authorization.sql` removes direct profile mutation policies and grants, keeps own/admin read access, and requires active profiles in all role helpers.

### High — no database restore point

Scheduled backups are not included on the current plan. A verified local JSON snapshot was taken before the migration, but it is not equivalent to managed point-in-time recovery or a full Postgres dump.

Remediation: keep a verified export before each change, obtain a full schema/data dump when CLI/database access is established, and evaluate Pro/PITR before production centralization.

### High — audit is not operational

Both audit tables are empty despite existing financial data. `commission_audit_logs` also had an admin delete policy, contrary to the append-only target.

Remediation: the authorization migration removes direct audit deletion. A later transaction/RPC milestone must write audit events atomically with financial changes.

### High — remote state was not reproducible

The database had no version-controlled migration history, and both Edge Function sources existed only in the dashboard.

Remediation: the exact reviewed function sources are now under `supabase/functions`; forward-only migrations begin under `supabase/migrations`. A reconstructed baseline and staging project remain required.

### Medium — duplicate generations of the model

`commission_agents` overlaps with normalized `commission_months` plus `commission_rows`; `audit_logs` overlaps with `commission_audit_logs`. Only the normalized commission tables contain data. Removing the empty legacy tables is deferred until application usage and rollback requirements are proven.

### Medium — legacy duplicate Edge Function

The application calls `admin-users`, which supports list/create/update. `admin-create-user` is a separate older implementation with JWT verification disabled, accepts an extra `follower` role rejected by the database constraint, and returns some internal error messages to clients.

Remediation: retain its source for recovery, stop invoking it, then retire it in a separate change after log review and a rollback window.

### Medium — missing financial value constraints

The database enforces zone and role values but not non-negative P35/P45/P65 or `paid`. Current data has zero violations and uses only `auto` and `t1` tier modes. Add validated constraints in a separate migration after authenticated role tests.

## Verified controls

- RLS is enabled on all six public tables.
- Normalized commission rows use UUID keys, foreign keys, unique `(month_id, zone, name)`, and an accountant protection trigger.
- Role helper functions are `SECURITY DEFINER` and had a fixed search path; the hardening migration further uses an empty search path with qualified objects.
- `admin-users` verifies the bearer user, active profile, and `admin` role before constructing a service-role client.
- The dashboard uses only the publishable key; service-role access remains inside Edge Functions.

## Remaining acceptance gates

1. Apply the hardening migration and re-query policies/grants.
2. Verify admin and accountant sign-in against the deployed dashboard.
3. Create staging accounts for `monitor` and `viewer` without production data.
4. Establish a full database dump and restorable staging environment.
5. Add non-negative financial constraints and transactional audit writes.
