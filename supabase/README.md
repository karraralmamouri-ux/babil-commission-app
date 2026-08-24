# Supabase source of truth

This directory contains the reviewed database migrations and Edge Function sources for the Babil Commission environments.

- Production ref: `fbgffpxpskjzgheheikd`.
- Staging ref: `unohqhxubraelqgjhxgh`.
- Both projects are in AWS `ap-northeast-1` (Tokyo).

## Current remote inventory — 2026-08-04

- Region: AWS `ap-northeast-1` (Tokyo), Free Plan.
- Scheduled database backups: unavailable on the current plan.
- Public data snapshot before security hardening: 2 profiles, 2 commission months, 82 commission rows, 0 rows in both audit tables, and 0 legacy `commission_agents` rows.
- Edge Functions: `admin-create-user` version 6 with JWT verification disabled, and `admin-users` version 1 with JWT verification enabled.
- The pre-change operational JSON and SHA-256 are stored only in the ignored local `backups/` directory.
- The deployed ESZIP bodies are stored only in ignored local `work/remote-supabase/`.

## Safety rules

- Never add a service-role or secret key to this directory.
- Review every migration and run role tests before applying it remotely.
- Take and verify a local data export before every remote schema or policy change while scheduled backups are unavailable.
- Keep production and staging project references outside committed configuration.
- `admin-create-user` is retained only to preserve the deployed source. The dashboard currently calls `admin-users`; consolidate only in a separate reviewed change.

## Applying to the existing remote project

The remote schema predates version-controlled migrations. Do not run a destructive reset or blindly push a reconstructed baseline. Apply reviewed forward-only migrations in order, verify their assertions, and then establish CLI migration history during the staging milestone.

## Rebuilding Staging

`20260804170000_reconstructed_baseline.sql` is a fresh-environment baseline reconstructed from the hardened production catalog. It deliberately aborts when the application tables already exist, so it must never be pushed to the existing production project.

Staging was reset and rebuilt successfully from the baseline followed by the reviewed forward migrations. Its migration history contains the baseline, authorization hardening, and financial constraints. Schema parity was verified for all 6 tables, 63 columns, 25 constraints, 19 indexes, 6 functions, 3 triggers, 17 RLS policies, and the reviewed grants.

Only `admin-users` is deployed to Staging. The unused legacy `admin-create-user` function is retained in source for recovery but is intentionally not deployed there.

See `docs/STAGING.md` for the guarded role test and operating procedure.
