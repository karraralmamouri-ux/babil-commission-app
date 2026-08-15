-- Minimal Supabase-shaped scaffolding for a THROWAWAY local Postgres.
--
-- This file exists only so the real migrations can be applied and exercised
-- without touching production or staging. It is never applied to a Supabase
-- project: Supabase already provides these roles, the auth schema, and auth.uid().
--
-- auth.uid() reads the same GUC PostgREST sets, so tests can impersonate a user
-- with:  set local role authenticated;  set local request.jwt.claim.sub = '<uuid>';

begin;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end;
$$;

grant usage on schema public to anon, authenticated, service_role;
grant anon, authenticated, service_role to postgres;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text not null default '',
  created_at timestamptz not null default now()
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

commit;
