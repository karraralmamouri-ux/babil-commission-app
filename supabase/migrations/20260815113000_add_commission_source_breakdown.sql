-- Preserve the raw parent/FDT allocation behind every final commission row.
-- The breakdown is descriptive and must reconcile exactly with the priced row.

begin;

alter table public.commission_rows
  add column if not exists source_breakdown jsonb;

alter table public.commission_rows
  alter column source_breakdown drop not null,
  alter column source_breakdown drop default;

alter table public.commission_rows
  drop constraint if exists commission_rows_source_breakdown_array_check;

alter table public.commission_rows
  add constraint commission_rows_source_breakdown_array_check
  check (source_breakdown is null or jsonb_typeof(source_breakdown) = 'array');

create or replace function public.validate_commission_source_breakdown()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_p35 integer;
  v_p45 integer;
  v_p65 integer;
begin
  -- Null marks a legacy row created before detailed raw allocation existed.
  if new.source_breakdown is null then
    return new;
  end if;
  if jsonb_typeof(new.source_breakdown) <> 'array' then
    raise exception 'source_breakdown must be an array' using errcode = '22023';
  end if;
  select
    coalesce(sum((item ->> 'p35')::integer), 0),
    coalesce(sum((item ->> 'p45')::integer), 0),
    coalesce(sum((item ->> 'p65')::integer), 0)
  into v_p35, v_p45, v_p65
  from jsonb_array_elements(new.source_breakdown) item;
  if (new.p35 + new.p45 + new.p65) > 0 and jsonb_array_length(new.source_breakdown) = 0 then
    raise exception 'source_breakdown is required for a non-empty row' using errcode = '23514';
  end if;
  if v_p35 <> new.p35 or v_p45 <> new.p45 or v_p65 <> new.p65 then
    raise exception 'source_breakdown does not reconcile with row quantities' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_commission_source_breakdown on public.commission_rows;
create trigger validate_commission_source_breakdown
before insert or update of p35, p45, p65, source_breakdown
on public.commission_rows
for each row execute function public.validate_commission_source_breakdown();

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
  v_breakdown jsonb;
  v_source jsonb;
  v_source_p35 integer;
  v_source_p45 integer;
  v_source_p65 integer;
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
    month_key, tiers, status, is_visible, approved_by, approved_at, created_by, updated_by
  ) values (
    p_month_key, p_tiers, 'approved', true, v_actor, now(), v_actor, v_actor
  )
  on conflict (month_key) do update
  set tiers = excluded.tiers,
      status = 'approved',
      is_visible = true,
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
    v_breakdown := coalesce(v_item -> 'source_breakdown', '[]'::jsonb);
    v_key := v_zone || chr(31) || v_name;

    if v_zone not in ('old', 'new') or v_name = ''
      or v_p35 < 0 or v_p45 < 0 or v_p65 < 0
      or v_tier_basis < v_p35 + v_p45 + v_p65
      or v_tier_mode not in ('auto', 't1', 't2', 't3')
      or v_applied_tier not in ('t1', 't2', 't3')
      or jsonb_typeof(v_breakdown) <> 'array'
      or jsonb_array_length(v_breakdown) > 10000
      or (v_p35 + v_p45 + v_p65 > 0 and jsonb_array_length(v_breakdown) = 0)
    then
      raise exception 'Invalid commission row: %', v_name using errcode = '22023';
    end if;
    if v_key = any(v_seen) then
      raise exception 'Duplicate commission row: %', v_name using errcode = '23505';
    end if;
    v_seen := array_append(v_seen, v_key);

    v_source_p35 := 0;
    v_source_p45 := 0;
    v_source_p65 := 0;
    for v_source in select value from jsonb_array_elements(v_breakdown)
    loop
      if btrim(coalesce(v_source ->> 'parent', '')) = ''
        or coalesce(jsonb_typeof(v_source -> 'p35'), 'missing') <> 'number'
        or coalesce(jsonb_typeof(v_source -> 'p45'), 'missing') <> 'number'
        or coalesce(jsonb_typeof(v_source -> 'p65'), 'missing') <> 'number'
        or (v_source ->> 'p35')::numeric < 0
        or (v_source ->> 'p45')::numeric < 0
        or (v_source ->> 'p65')::numeric < 0
        or trunc((v_source ->> 'p35')::numeric) <> (v_source ->> 'p35')::numeric
        or trunc((v_source ->> 'p45')::numeric) <> (v_source ->> 'p45')::numeric
        or trunc((v_source ->> 'p65')::numeric) <> (v_source ->> 'p65')::numeric
        or (
          v_source ? 'fdt'
          and jsonb_typeof(v_source -> 'fdt') <> 'null'
          and (
            jsonb_typeof(v_source -> 'fdt') <> 'number'
            or (v_source ->> 'fdt')::numeric < 0
            or trunc((v_source ->> 'fdt')::numeric) <> (v_source ->> 'fdt')::numeric
          )
        )
      then
        raise exception 'Invalid source breakdown for %', v_name using errcode = '22023';
      end if;
      v_source_p35 := v_source_p35 + (v_source ->> 'p35')::integer;
      v_source_p45 := v_source_p45 + (v_source ->> 'p45')::integer;
      v_source_p65 := v_source_p65 + (v_source ->> 'p65')::integer;
    end loop;
    if v_source_p35 <> v_p35 or v_source_p45 <> v_p45 or v_source_p65 <> v_p65
    then
      raise exception 'Source breakdown does not reconcile for %', v_name using errcode = '23514';
    end if;

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
      source_breakdown, owner_name, created_by, updated_by
    ) values (
      v_month_id, v_zone, v_name, v_p35, v_p45, v_p65, v_applied_tier, v_tier_mode,
      v_tier_basis, nullif(v_item ->> 'tier_group_id', ''),
      nullif(v_item ->> 'tier_group_name', ''), nullif(v_item ->> 'source_account', ''),
      v_breakdown, nullif(v_item ->> 'owner_name', ''), v_actor, v_actor
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
        source_breakdown = excluded.source_breakdown,
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

commit;
