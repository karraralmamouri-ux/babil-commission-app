-- Reconstructed from the hardened production catalog on 2026-08-04.
-- Fresh environments only: never apply this baseline to the existing production project.

begin;

do $$
begin
  if to_regclass('public.profiles') is not null
    or to_regclass('public.commission_months') is not null
    or to_regclass('public.commission_rows') is not null
  then
    raise exception 'reconstructed baseline requires an empty public application schema';
  end if;
end;
$$;

create table public.profiles (
  id uuid not null,
  full_name text not null default '',
  email text not null default '',
  role text not null default 'viewer',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_pkey primary key (id),
  constraint profiles_id_fkey foreign key (id) references auth.users(id) on delete cascade,
  constraint profiles_role_check check (role = any (array['admin'::text, 'accountant'::text, 'monitor'::text, 'viewer'::text]))
);

create table public.commission_months (
  id uuid not null default gen_random_uuid(),
  month_key text not null,
  tiers jsonb not null default '[]'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint commission_months_pkey primary key (id),
  constraint commission_months_month_key_key unique (month_key),
  constraint commission_months_created_by_fkey foreign key (created_by) references auth.users(id),
  constraint commission_months_updated_by_fkey foreign key (updated_by) references auth.users(id)
);

create table public.commission_rows (
  id uuid not null default gen_random_uuid(),
  month_id uuid not null,
  zone text not null,
  name text not null,
  p35 integer not null default 0,
  p45 integer not null default 0,
  p65 integer not null default 0,
  custom_tier text not null default 'auto',
  source_breakdown jsonb,
  paid numeric not null default 0,
  payment_date date,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint commission_rows_pkey primary key (id),
  constraint commission_rows_month_id_zone_name_key unique (month_id, zone, name),
  constraint commission_rows_month_id_fkey foreign key (month_id) references public.commission_months(id) on delete cascade,
  constraint commission_rows_created_by_fkey foreign key (created_by) references auth.users(id),
  constraint commission_rows_updated_by_fkey foreign key (updated_by) references auth.users(id),
  constraint commission_rows_zone_check check (zone = any (array['old'::text, 'new'::text])),
  constraint commission_rows_source_breakdown_array_check check (source_breakdown is null or jsonb_typeof(source_breakdown) = 'array')
);

create table public.commission_agents (
  id uuid not null default gen_random_uuid(),
  month_key text not null,
  zone text not null,
  name text not null,
  p35 integer not null default 0,
  p45 integer not null default 0,
  p65 integer not null default 0,
  custom_tier text default 'auto',
  paid numeric not null default 0,
  payment_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commission_agents_pkey primary key (id),
  constraint commission_agents_month_key_zone_name_key unique (month_key, zone, name),
  constraint commission_agents_zone_check check (zone = any (array['old'::text, 'new'::text]))
);

create table public.audit_logs (
  id bigint generated always as identity,
  created_at timestamptz not null default now(),
  actor_id uuid not null default auth.uid(),
  month_key text,
  zone text,
  agent text,
  action text not null,
  field text,
  old_value text,
  new_value text,
  extra text,
  constraint audit_logs_pkey primary key (id),
  constraint audit_logs_actor_id_fkey foreign key (actor_id) references auth.users(id)
);

create table public.commission_audit_logs (
  id uuid not null default gen_random_uuid(),
  user_id uuid,
  month_id uuid,
  month_key text,
  zone text,
  agent text,
  action text not null,
  field text,
  old_value text,
  new_value text,
  extra text,
  created_at timestamptz not null default now(),
  constraint commission_audit_logs_pkey primary key (id),
  constraint commission_audit_logs_user_id_fkey foreign key (user_id) references auth.users(id),
  constraint commission_audit_logs_month_id_fkey foreign key (month_id) references public.commission_months(id)
);

create index audit_logs_actor_idx on public.audit_logs using btree (actor_id);
create index audit_logs_created_at_idx on public.audit_logs using btree (created_at desc);
create index audit_logs_month_idx on public.audit_logs using btree (month_key);
create index idx_commission_agents_month on public.commission_agents using btree (month_key);
create index idx_commission_agents_zone on public.commission_agents using btree (zone);
create index idx_audit_created on public.commission_audit_logs using btree (created_at desc);
create index idx_audit_month on public.commission_audit_logs using btree (month_id);
create index idx_audit_user on public.commission_audit_logs using btree (user_id);
create index idx_commission_rows_month on public.commission_rows using btree (month_id);
create index idx_commission_rows_zone on public.commission_rows using btree (zone);

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

create or replace function public.protect_accountant_rows()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_app_role() = 'accountant' then
    if new.month_id is distinct from old.month_id
      or new.zone is distinct from old.zone
      or new.name is distinct from old.name
      or new.p35 is distinct from old.p35
      or new.p45 is distinct from old.p45
      or new.p65 is distinct from old.p65
      or new.custom_tier is distinct from old.custom_tier
    then
      raise exception 'المحاسب يستطيع تعديل بيانات الصرف فقط';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end;
$$;

create trigger trg_month_updated
before update on public.commission_months
for each row execute function public.set_updated_at();

create trigger trg_protect_accountant
before update on public.commission_rows
for each row execute function public.protect_accountant_rows();

create trigger trg_row_updated
before update on public.commission_rows
for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.commission_months enable row level security;
alter table public.commission_rows enable row level security;
alter table public.commission_agents enable row level security;
alter table public.audit_logs enable row level security;
alter table public.commission_audit_logs enable row level security;

create policy months_select
on public.commission_months for select to authenticated
using (public.current_app_role() = any (array['admin'::text, 'accountant'::text, 'monitor'::text, 'viewer'::text]));

create policy months_insert_admin
on public.commission_months for insert to authenticated
with check (public.current_app_role() = 'admin'::text);

create policy months_update_admin
on public.commission_months for update to authenticated
using (public.current_app_role() = 'admin'::text)
with check (public.current_app_role() = 'admin'::text);

create policy months_delete_admin
on public.commission_months for delete to authenticated
using (public.current_app_role() = 'admin'::text);

create policy rows_select
on public.commission_rows for select to authenticated
using (public.current_app_role() = any (array['admin'::text, 'accountant'::text, 'monitor'::text, 'viewer'::text]));

create policy rows_insert_admin
on public.commission_rows for insert to authenticated
with check (public.current_app_role() = 'admin'::text);

create policy rows_update_admin_accountant
on public.commission_rows for update to authenticated
using (public.current_app_role() = any (array['admin'::text, 'accountant'::text]))
with check (public.current_app_role() = any (array['admin'::text, 'accountant'::text]));

create policy rows_delete_admin
on public.commission_rows for delete to authenticated
using (public.current_app_role() = 'admin'::text);

create policy agents_select_active_users
on public.commission_agents for select to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid() and p.is_active = true
));

create policy agents_insert_admin_accountant
on public.commission_agents for insert to authenticated
with check (exists (
  select 1 from public.profiles p
  where p.id = auth.uid()
    and p.is_active = true
    and p.role = any (array['admin'::text, 'accountant'::text])
));

create policy agents_update_admin_accountant
on public.commission_agents for update to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid()
    and p.is_active = true
    and p.role = any (array['admin'::text, 'accountant'::text])
))
with check (exists (
  select 1 from public.profiles p
  where p.id = auth.uid()
    and p.is_active = true
    and p.role = any (array['admin'::text, 'accountant'::text])
));

create policy agents_delete_admin
on public.commission_agents for delete to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid()
    and p.is_active = true
    and p.role = 'admin'::text
));

create policy audit_select_authenticated
on public.audit_logs for select to authenticated
using (public.current_user_role() is not null);

create policy audit_insert_authenticated
on public.audit_logs for insert to authenticated
with check (actor_id = auth.uid() and public.current_user_role() is not null);

create policy audit_select
on public.commission_audit_logs for select to authenticated
using (public.current_app_role() = any (array['admin'::text, 'accountant'::text, 'monitor'::text, 'viewer'::text]));

create policy audit_insert
on public.commission_audit_logs for insert to authenticated
with check (user_id = auth.uid());

revoke all privileges on all tables in schema public from anon, authenticated;
revoke all privileges on all sequences in schema public from anon, authenticated;

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
