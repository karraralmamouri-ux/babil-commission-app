-- Central month publishing, old-zone group identity, and shared import settings.
-- Apply to Staging and verify before production.

begin;

alter table public.commission_months
  add column status text not null default 'approved',
  add column approved_by uuid references auth.users(id),
  add column approved_at timestamptz;

alter table public.commission_months
  add constraint commission_months_status_check
  check (status in ('draft', 'approved'));

alter table public.commission_rows
  add column tier_mode text not null default 'auto',
  add column tier_basis_qty integer,
  add column tier_group_id text,
  add column tier_group_name text,
  add column source_account text,
  add column owner_name text;

alter table public.commission_rows
  add constraint commission_rows_tier_mode_check
    check (tier_mode in ('auto', 't1', 't2', 't3')),
  add constraint commission_rows_tier_basis_nonnegative_check
    check (tier_basis_qty is null or tier_basis_qty >= 0);

create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

alter table public.app_settings enable row level security;

create policy app_settings_read_authenticated
on public.app_settings for select to authenticated
using (public.current_app_role() is not null);

grant select on table public.app_settings to authenticated;
revoke insert, update, delete on table public.app_settings from authenticated;

create or replace function public.resolve_commission_tier_key(
  p_tiers jsonb,
  p_quantity integer
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select tier ->> 'key'
  from jsonb_array_elements(p_tiers) as elements(tier)
  where p_quantity >= coalesce((tier ->> 'min')::integer, 0)
    and (
      tier ->> 'max' is null
      or p_quantity <= (tier ->> 'max')::integer
    )
  order by coalesce((tier ->> 'min')::integer, 0) desc
  limit 1;
$$;

create or replace function public.save_import_settings(
  p_value jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_value) <> 'object'
    or jsonb_typeof(p_value -> 'profiles') <> 'array'
    or jsonb_typeof(p_value -> 'agents') <> 'array'
    or jsonb_typeof(p_value -> 'cabinetRanges') <> 'array'
  then
    raise exception 'Import settings are invalid' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0)
  );
  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'settings.import.saved' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('settings', v_existing.after_data, 'replayed', true);
  end if;

  select value into v_before from public.app_settings where key = 'raw_import';
  insert into public.app_settings (key, value, updated_by)
  values ('raw_import', p_value, v_actor)
  on conflict (key) do update
  set value = excluded.value, updated_by = v_actor, updated_at = now()
  returning value into v_after;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type,
    before_data, after_data, request_id
  ) values (
    v_actor, 'settings.import.saved', 'raw_import',
    coalesce(v_before, '{}'::jsonb)::text, v_after::text, 'app_setting',
    coalesce(v_before, '{}'::jsonb), v_after, p_request_id
  );
  return jsonb_build_object('settings', v_after, 'replayed', false);
end;
$$;

create or replace function public.publish_commission_month(
  p_month_key text,
  p_tiers jsonb,
  p_rows jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_month_id uuid;
  v_item jsonb;
  v_zone text;
  v_name text;
  v_key text;
  v_seen text[] := array[]::text[];
  v_p35 integer;
  v_p45 integer;
  v_p65 integer;
  v_tier_mode text;
  v_applied_tier text;
  v_expected_tier text;
  v_tier_basis integer;
  v_tier jsonb;
  v_tier_keys text[] := array[]::text[];
  v_due numeric;
  v_paid numeric;
  v_old_count integer := 0;
  v_new_count integer := 0;
  v_previous jsonb;
  v_after jsonb;
  v_stale public.commission_rows%rowtype;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_month_key is null or p_month_key !~ '^(0[1-9]|1[0-2])/[0-9]{4}$' then
    raise exception 'Month key must use MM/YYYY' using errcode = '22023';
  end if;
  if jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) = 0 then
    raise exception 'Commission tiers must be a non-empty array' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array'
    or jsonb_array_length(p_rows) = 0
    or jsonb_array_length(p_rows) > 2000
  then
    raise exception 'Commission rows must contain between 1 and 2000 rows' using errcode = '22023';
  end if;

  for v_tier in select value from jsonb_array_elements(p_tiers)
  loop
    v_key := v_tier ->> 'key';
    if v_key is null
      or v_key not in ('t1', 't2', 't3')
      or v_key = any(v_tier_keys)
      or coalesce(jsonb_typeof(v_tier -> 'min'), 'missing') <> 'number'
      or (v_tier ->> 'min')::integer < 0
      or (
        v_tier ? 'max'
        and jsonb_typeof(v_tier -> 'max') <> 'null'
        and (
          coalesce(jsonb_typeof(v_tier -> 'max'), 'missing') <> 'number'
          or (v_tier ->> 'max')::integer < (v_tier ->> 'min')::integer
        )
      )
      or coalesce(jsonb_typeof(v_tier -> 'p35'), 'missing') <> 'number'
      or coalesce(jsonb_typeof(v_tier -> 'p45'), 'missing') <> 'number'
      or coalesce(jsonb_typeof(v_tier -> 'p65'), 'missing') <> 'number'
      or (v_tier ->> 'p35')::numeric < 0
      or (v_tier ->> 'p45')::numeric < 0
      or (v_tier ->> 'p65')::numeric < 0
    then
      raise exception 'Commission tier settings are invalid' using errcode = '22023';
    end if;
    v_tier_keys := array_append(v_tier_keys, v_key);
  end loop;
  if cardinality(v_tier_keys) <> 3 then
    raise exception 'Commission tiers t1, t2, and t3 are required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('publish:' || p_month_key, 0)
  );
  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'commission.month.published'
      or v_existing.month_key is distinct from p_month_key
    then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('month', v_existing.after_data, 'replayed', true);
  end if;

  select jsonb_build_object('exists', true, 'rows', count(*))
  into v_previous
  from public.commission_rows r
  join public.commission_months m on m.id = r.month_id
  where m.month_key = p_month_key;

  insert into public.commission_months (
    month_key, tiers, status, approved_by, approved_at, created_by, updated_by
  ) values (
    p_month_key, p_tiers, 'approved', v_actor, now(), v_actor, v_actor
  )
  on conflict (month_key) do update
  set tiers = excluded.tiers,
      status = 'approved',
      approved_by = v_actor,
      approved_at = now(),
      updated_by = v_actor,
      updated_at = now()
  returning id into v_month_id;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_zone := btrim(coalesce(v_item ->> 'zone', ''));
    v_name := btrim(coalesce(v_item ->> 'name', ''));
    v_p35 := coalesce((v_item ->> 'p35')::integer, 0);
    v_p45 := coalesce((v_item ->> 'p45')::integer, 0);
    v_p65 := coalesce((v_item ->> 'p65')::integer, 0);
    v_tier_mode := coalesce(v_item ->> 'tier_mode', 'auto');
    v_applied_tier := v_item ->> 'applied_tier';
    v_tier_basis := coalesce((v_item ->> 'tier_basis_qty')::integer, v_p35 + v_p45 + v_p65);
    v_key := v_zone || chr(31) || v_name;

    if v_zone not in ('old', 'new') or v_name = ''
      or v_p35 < 0 or v_p45 < 0 or v_p65 < 0
      or v_tier_basis < v_p35 + v_p45 + v_p65
      or v_tier_mode not in ('auto', 't1', 't2', 't3')
      or v_applied_tier not in ('t1', 't2', 't3')
    then
      raise exception 'Invalid commission row: %', v_name using errcode = '22023';
    end if;
    if v_key = any(v_seen) then
      raise exception 'Duplicate commission row: %', v_name using errcode = '23505';
    end if;
    v_seen := array_append(v_seen, v_key);

    v_expected_tier := case
      when v_tier_mode = 'auto' then public.resolve_commission_tier_key(p_tiers, v_tier_basis)
      else v_tier_mode
    end;
    if v_expected_tier is distinct from v_applied_tier then
      raise exception 'Applied tier does not match server calculation for %', v_name using errcode = '23514';
    end if;
    v_due := public.calculate_commission_due(p_tiers, v_p35, v_p45, v_p65, v_applied_tier);
    select paid into v_paid from public.commission_rows
    where month_id = v_month_id and zone = v_zone and name = v_name
    for update;
    if found and v_paid > v_due then
      raise exception 'Updated commission due cannot be lower than recorded payment for %', v_name using errcode = '23514';
    end if;

    insert into public.commission_rows (
      month_id, zone, name, p35, p45, p65, custom_tier, tier_mode,
      tier_basis_qty, tier_group_id, tier_group_name, source_account,
      owner_name, created_by, updated_by
    ) values (
      v_month_id, v_zone, v_name, v_p35, v_p45, v_p65, v_applied_tier, v_tier_mode,
      v_tier_basis, nullif(v_item ->> 'tier_group_id', ''),
      nullif(v_item ->> 'tier_group_name', ''), nullif(v_item ->> 'source_account', ''),
      nullif(v_item ->> 'owner_name', ''), v_actor, v_actor
    )
    on conflict (month_id, zone, name) do update
    set p35 = excluded.p35,
        p45 = excluded.p45,
        p65 = excluded.p65,
        custom_tier = excluded.custom_tier,
        tier_mode = excluded.tier_mode,
        tier_basis_qty = excluded.tier_basis_qty,
        tier_group_id = excluded.tier_group_id,
        tier_group_name = excluded.tier_group_name,
        source_account = excluded.source_account,
        owner_name = excluded.owner_name,
        updated_by = v_actor,
        updated_at = now();

    if v_zone = 'old' then v_old_count := v_old_count + 1;
    else v_new_count := v_new_count + 1;
    end if;
  end loop;

  for v_stale in
    select * from public.commission_rows
    where month_id = v_month_id
      and not ((zone || chr(31) || name) = any(v_seen))
    for update
  loop
    if v_stale.paid <> 0 then
      raise exception 'Cannot remove a row with recorded payment: %', v_stale.name using errcode = '23514';
    end if;
    delete from public.commission_rows where id = v_stale.id;
  end loop;

  v_after := jsonb_build_object(
    'id', v_month_id, 'month_key', p_month_key, 'status', 'approved',
    'old_rows', v_old_count, 'new_rows', v_new_count,
    'approved_at', now()
  );
  insert into public.audit_logs (
    actor_id, month_key, action, field, old_value, new_value, extra,
    entity_type, entity_id, before_data, after_data, request_id
  ) values (
    v_actor, p_month_key, 'commission.month.published', 'month',
    coalesce(v_previous, '{}'::jsonb)::text, v_after::text,
    (v_old_count + v_new_count)::text, 'commission_month', v_month_id,
    coalesce(v_previous, '{}'::jsonb), v_after, p_request_id
  );
  return jsonb_build_object('month', v_after, 'replayed', false);
end;
$$;

revoke execute on function public.resolve_commission_tier_key(jsonb, integer) from public, anon, authenticated;
revoke execute on function public.save_import_settings(jsonb, uuid) from public, anon;
revoke execute on function public.publish_commission_month(text, jsonb, jsonb, uuid) from public, anon;
grant execute on function public.save_import_settings(jsonb, uuid) to authenticated;
grant execute on function public.publish_commission_month(text, jsonb, jsonb, uuid) to authenticated;

alter default privileges in schema public revoke execute on functions from public, anon;

commit;
