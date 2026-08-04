-- Route financial writes through audited, idempotent transactions.
-- The current dashboard is not switched to these RPCs by this migration.

begin;

alter table public.audit_logs
  add column entity_type text,
  add column entity_id uuid,
  add column before_data jsonb,
  add column after_data jsonb,
  add column request_id uuid;

create unique index audit_logs_actor_request_uidx
on public.audit_logs (actor_id, request_id)
where request_id is not null;

create or replace function public.calculate_commission_due(
  p_tiers jsonb,
  p_p35 integer,
  p_p45 integer,
  p_p65 integer,
  p_custom_tier text
)
returns numeric
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_quantity integer;
  v_tier jsonb;
  v_p35_rate numeric;
  v_p45_rate numeric;
  v_p65_rate numeric;
begin
  if p_p35 < 0 or p_p45 < 0 or p_p65 < 0 then
    raise exception 'Commission quantities cannot be negative'
      using errcode = '22023';
  end if;

  if jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) = 0 then
    raise exception 'Commission tiers must be a non-empty array'
      using errcode = '22023';
  end if;

  if p_custom_tier is null
    or p_custom_tier not in ('auto', 't1', 't2', 't3')
  then
    raise exception 'Unknown commission tier mode'
      using errcode = '22023';
  end if;

  v_quantity := p_p35 + p_p45 + p_p65;

  if p_custom_tier = 'auto' then
    select tier
    into v_tier
    from jsonb_array_elements(p_tiers) as elements(tier)
    where v_quantity >= coalesce((tier ->> 'min')::integer, 0)
      and (
        tier ->> 'max' is null
        or v_quantity <= (tier ->> 'max')::integer
      )
    order by coalesce((tier ->> 'min')::integer, 0) desc
    limit 1;
  else
    select tier
    into v_tier
    from jsonb_array_elements(p_tiers) as elements(tier)
    where tier ->> 'key' = p_custom_tier
    limit 1;
  end if;

  if v_tier is null then
    raise exception 'No matching commission tier'
      using errcode = '22023';
  end if;

  begin
    v_p35_rate := (v_tier ->> 'p35')::numeric;
    v_p45_rate := (v_tier ->> 'p45')::numeric;
    v_p65_rate := (v_tier ->> 'p65')::numeric;
  exception
    when invalid_text_representation then
      raise exception 'Commission tier rates must be numeric'
        using errcode = '22023';
  end;

  if v_p35_rate is null or v_p35_rate < 0
    or v_p45_rate is null or v_p45_rate < 0
    or v_p65_rate is null or v_p65_rate < 0
  then
    raise exception 'Commission tier rates must be non-negative numbers'
      using errcode = '22023';
  end if;

  return p_p35 * v_p35_rate
    + p_p45 * v_p45_rate
    + p_p65 * v_p65_rate;
end;
$$;

create or replace function public.update_commission_row(
  p_row_id uuid,
  p_expected_updated_at timestamptz,
  p_name text,
  p_p35 integer,
  p_p45 integer,
  p_p65 integer,
  p_custom_tier text,
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
  v_before public.commission_rows%rowtype;
  v_after public.commission_rows%rowtype;
  v_month_key text;
  v_tiers jsonb;
  v_due numeric;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required'
      using errcode = '42501';
  end if;

  if p_request_id is null then
    raise exception 'request_id is required'
      using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0)
  );

  select *
  into v_existing
  from public.audit_logs
  where actor_id = v_actor
    and request_id = p_request_id;

  if found then
    if v_existing.action <> 'commission.row.updated'
      or v_existing.entity_id is distinct from p_row_id
    then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;

    return jsonb_build_object(
      'row', v_existing.after_data,
      'due', (v_existing.extra)::numeric,
      'replayed', true,
      'request_id', p_request_id
    );
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'Agent name is required'
      using errcode = '22023';
  end if;

  if p_p35 < 0 or p_p45 < 0 or p_p65 < 0 then
    raise exception 'Commission quantities cannot be negative'
      using errcode = '22023';
  end if;

  if p_custom_tier is null
    or p_custom_tier not in ('auto', 't1', 't2', 't3')
  then
    raise exception 'Unknown commission tier mode'
      using errcode = '22023';
  end if;

  select r.*
  into v_before
  from public.commission_rows as r
  where r.id = p_row_id
  for update;

  if not found then
    raise exception 'Commission row was not found'
      using errcode = 'P0002';
  end if;

  if p_expected_updated_at is null
    or v_before.updated_at is distinct from p_expected_updated_at
  then
    raise exception 'Commission row changed since it was loaded'
      using errcode = '40001';
  end if;

  select month_key, tiers
  into v_month_key, v_tiers
  from public.commission_months
  where id = v_before.month_id;

  v_due := public.calculate_commission_due(
    v_tiers,
    p_p35,
    p_p45,
    p_p65,
    p_custom_tier
  );

  if v_before.paid > v_due then
    raise exception 'Updated commission due cannot be lower than recorded payment'
      using errcode = '23514';
  end if;

  update public.commission_rows
  set name = btrim(p_name),
      p35 = p_p35,
      p45 = p_p45,
      p65 = p_p65,
      custom_tier = p_custom_tier
  where id = p_row_id
  returning * into v_after;

  insert into public.audit_logs (
    actor_id,
    month_key,
    zone,
    agent,
    action,
    field,
    old_value,
    new_value,
    extra,
    entity_type,
    entity_id,
    before_data,
    after_data,
    request_id
  ) values (
    v_actor,
    v_month_key,
    v_after.zone,
    v_after.name,
    'commission.row.updated',
    'name,p35,p45,p65,custom_tier',
    to_jsonb(v_before)::text,
    to_jsonb(v_after)::text,
    v_due::text,
    'commission_row',
    v_after.id,
    to_jsonb(v_before),
    to_jsonb(v_after),
    p_request_id
  );

  return jsonb_build_object(
    'row', to_jsonb(v_after),
    'due', v_due,
    'replayed', false,
    'request_id', p_request_id
  );
end;
$$;

create or replace function public.record_commission_payment(
  p_row_id uuid,
  p_expected_updated_at timestamptz,
  p_paid numeric,
  p_payment_date date,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := public.current_app_role();
  v_existing public.audit_logs%rowtype;
  v_before public.commission_rows%rowtype;
  v_after public.commission_rows%rowtype;
  v_tiers jsonb;
  v_month_key text;
  v_due numeric;
begin
  if v_actor is null or v_role is null
    or v_role not in ('admin', 'accountant')
  then
    raise exception 'Payment permission is required'
      using errcode = '42501';
  end if;

  if p_request_id is null then
    raise exception 'request_id is required'
      using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0)
  );

  select *
  into v_existing
  from public.audit_logs
  where actor_id = v_actor
    and request_id = p_request_id;

  if found then
    if v_existing.action <> 'commission.payment.recorded'
      or v_existing.entity_id is distinct from p_row_id
    then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;

    return jsonb_build_object(
      'row', v_existing.after_data,
      'due', (v_existing.extra)::numeric,
      'replayed', true,
      'request_id', p_request_id
    );
  end if;

  if p_paid is null or p_paid < 0 then
    raise exception 'Payment cannot be negative'
      using errcode = '22023';
  end if;

  select r.*
  into v_before
  from public.commission_rows as r
  where r.id = p_row_id
  for update;

  if not found then
    raise exception 'Commission row was not found'
      using errcode = 'P0002';
  end if;

  if p_expected_updated_at is null
    or v_before.updated_at is distinct from p_expected_updated_at
  then
    raise exception 'Commission row changed since it was loaded'
      using errcode = '40001';
  end if;

  select month_key, tiers
  into v_month_key, v_tiers
  from public.commission_months
  where id = v_before.month_id;

  v_due := public.calculate_commission_due(
    v_tiers,
    v_before.p35,
    v_before.p45,
    v_before.p65,
    v_before.custom_tier
  );

  if p_paid > v_due then
    raise exception 'Payment cannot exceed commission due'
      using errcode = '23514';
  end if;

  update public.commission_rows
  set paid = p_paid,
      payment_date = p_payment_date
  where id = p_row_id
  returning * into v_after;

  insert into public.audit_logs (
    actor_id,
    month_key,
    zone,
    agent,
    action,
    field,
    old_value,
    new_value,
    extra,
    entity_type,
    entity_id,
    before_data,
    after_data,
    request_id
  ) values (
    v_actor,
    v_month_key,
    v_after.zone,
    v_after.name,
    'commission.payment.recorded',
    'paid,payment_date',
    to_jsonb(v_before)::text,
    to_jsonb(v_after)::text,
    v_due::text,
    'commission_row',
    v_after.id,
    to_jsonb(v_before),
    to_jsonb(v_after),
    p_request_id
  );

  return jsonb_build_object(
    'row', to_jsonb(v_after),
    'due', v_due,
    'replayed', false,
    'request_id', p_request_id
  );
end;
$$;

-- Direct financial and audit writes are disabled for browser sessions.
-- Security-definer RPCs above are the only authenticated mutation path.
revoke insert, update, delete on table public.commission_months from authenticated;
revoke insert, update, delete on table public.commission_rows from authenticated;
revoke insert, update, delete on table public.commission_agents from authenticated;
revoke insert on table public.audit_logs from authenticated;
revoke insert on table public.commission_audit_logs from authenticated;

revoke execute on function public.calculate_commission_due(jsonb, integer, integer, integer, text)
from public, anon, authenticated;
revoke execute on function public.update_commission_row(uuid, timestamptz, text, integer, integer, integer, text, uuid)
from public, anon;
revoke execute on function public.record_commission_payment(uuid, timestamptz, numeric, date, uuid)
from public, anon;

grant execute on function public.update_commission_row(uuid, timestamptz, text, integer, integer, integer, text, uuid)
to authenticated;
grant execute on function public.record_commission_payment(uuid, timestamptz, numeric, date, uuid)
to authenticated;

alter default privileges in schema public revoke execute on functions from public, anon;

commit;
