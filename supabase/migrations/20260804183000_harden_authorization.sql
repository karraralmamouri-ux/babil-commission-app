-- Prevent profile self-escalation and reduce public database privileges.
-- Designed as a forward-only change for the existing production schema.

begin;

create or replace function public.current_app_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.get_my_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.current_user_role() = 'admin', false);
$$;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;

create policy profiles_select_own_or_admin
on public.profiles
for select
to authenticated
using (id = auth.uid() or public.is_admin());

-- Audit records are append-only. Service-role recovery remains available.
drop policy if exists audit_delete_admin on public.commission_audit_logs;

revoke all privileges on all tables in schema public from anon;
revoke all privileges on all sequences in schema public from anon;

revoke all privileges on table
  public.profiles,
  public.audit_logs,
  public.commission_agents,
  public.commission_audit_logs,
  public.commission_months,
  public.commission_rows
from authenticated;

grant select on table public.profiles to authenticated;
grant select, insert on table public.audit_logs to authenticated;
grant select, insert, update, delete on table public.commission_agents to authenticated;
grant select, insert on table public.commission_audit_logs to authenticated;
grant select, insert, update, delete on table public.commission_months to authenticated;
grant select, insert, update, delete on table public.commission_rows to authenticated;

grant usage, select on all sequences in schema public to authenticated;

revoke execute on function public.current_app_role() from public, anon;
revoke execute on function public.current_user_role() from public, anon;
revoke execute on function public.get_my_role() from public, anon;
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.protect_accountant_rows() from public, anon;

grant execute on function public.current_app_role() to authenticated;
grant execute on function public.current_user_role() to authenticated;
grant execute on function public.get_my_role() to authenticated;
grant execute on function public.is_admin() to authenticated;

alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;

commit;
