-- Bring the installation tables in line with the commission tables: SELECT and
-- nothing else for a browser session.
--
-- Why this is needed. 20260815160000 revoked insert/update/delete from
-- `authenticated`, which was enough on a bare Postgres and on staging. On a
-- real Supabase project the platform's default privileges grant ALL on new
-- tables to `authenticated`, so revoking only those three left TRUNCATE,
-- REFERENCES, TRIGGER and MAINTAIN behind:
--
--   installation tables : authenticated=rDxtm      <- D is TRUNCATE
--   commission tables   : authenticated=r
--
-- TRUNCATE is not filtered by row level security, so any signed-in user of any
-- role could have emptied the entitlement, batch and payment tables regardless
-- of the policies on them.
--
-- Forward-only: 20260815160000 is already applied and recorded, so this is a
-- separate migration rather than an edit to it.

begin;

revoke all on table public.installation_batches from authenticated;
revoke all on table public.installation_entitlements from authenticated;
revoke all on table public.installation_payments from authenticated;

grant select on table public.installation_batches to authenticated;
grant select on table public.installation_entitlements to authenticated;
grant select on table public.installation_payments to authenticated;

revoke all on table public.installation_batches from anon;
revoke all on table public.installation_entitlements from anon;
revoke all on table public.installation_payments from anon;

-- New tables added later in this schema must not inherit ALL either.
alter default privileges in schema public revoke all on tables from anon;

commit;
