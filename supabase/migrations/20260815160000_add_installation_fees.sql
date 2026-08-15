-- Installation fees: a separate financial domain from agent commissions.
--
-- P1..P4/DONE are installation instalments. They share resellers, zones and FDT
-- with the commission domain but never share a calculation: P35/P45/P65 and tier
-- pricing belong to commissions only.
--
-- Amounts are IQD integers (bigint). The instalment amount is a function of the
-- subscriber's Remaining balance and is enforced here, so a browser can never
-- submit its own figure.
--
-- NOT DEPLOYED. Validated on a throwaway local Postgres only.

begin;

-- Remaining -> stage. Any other value has no stage and must be rejected upstream.
create or replace function public.installation_stage_for_remaining(p_remaining bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_remaining
    when 13000 then 'P1'
    when 10000 then 'P2'
    when 7000  then 'P3'
    when 4000  then 'P4'
    when 0     then 'DONE'
  end;
$$;

-- Stage -> amount due now.
create or replace function public.installation_amount_for_stage(p_stage text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case p_stage
    when 'P1' then 3000::bigint
    when 'P2' then 3000::bigint
    when 'P3' then 3000::bigint
    when 'P4' then 4000::bigint
    when 'DONE' then 0::bigint
  end;
$$;

create table public.installation_batches (
  id uuid primary key default gen_random_uuid(),
  period text not null,
  file_name text not null default '',
  file_checksum text,
  source_rows integer not null default 0,
  accepted_rows integer not null default 0,
  duplicate_rows integer not null default 0,
  rejected_rows integer not null default 0,
  status text not null default 'completed',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  constraint installation_batches_period_check check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  constraint installation_batches_status_check check (status in ('completed', 'no_new_rows')),
  constraint installation_batches_counts_check check (
    source_rows >= 0 and accepted_rows >= 0 and duplicate_rows >= 0 and rejected_rows >= 0
  )
);

create table public.installation_entitlements (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid references public.installation_batches(id) on delete restrict,
  period text not null,
  subscriber_id text not null,
  subscriber_name text not null default '',
  reseller text not null,
  zone text,
  fdt text,
  remaining bigint not null,
  stage text not null,
  amount bigint not null,
  invoice_status text not null default 'pending',
  invoice_audited_by uuid references auth.users(id),
  invoice_audited_at timestamptz,
  invoice_note text,
  payment_status text not null default 'awaiting_invoice',
  paid_amount bigint not null default 0,
  paid_by uuid references auth.users(id),
  paid_at timestamptz,
  created_by uuid not null references auth.users(id),
  -- Maintained by the shared set_updated_at() trigger, like the commission tables.
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Business identity. A row number is never a financial identity.
  constraint installation_entitlements_identity_key unique (period, subscriber_id, stage),
  constraint installation_entitlements_period_check check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  constraint installation_entitlements_subscriber_check check (btrim(subscriber_id) <> ''),
  constraint installation_entitlements_reseller_check check (btrim(reseller) <> ''),
  constraint installation_entitlements_zone_check check (zone is null or zone in ('old', 'new')),
  constraint installation_entitlements_stage_check check (stage in ('P1', 'P2', 'P3', 'P4', 'DONE')),
  constraint installation_entitlements_invoice_check
    check (invoice_status in ('pending', 'approved', 'missing', 'rejected')),
  constraint installation_entitlements_payment_check
    check (payment_status in ('not_eligible', 'awaiting_invoice', 'eligible', 'paid')),
  constraint installation_entitlements_remaining_check check (remaining >= 0),
  constraint installation_entitlements_paid_range_check check (paid_amount >= 0 and paid_amount <= amount),

  -- Rule 3: Remaining, stage and amount must agree. No fuzzy values survive.
  -- `is not distinct from` is required: an unknown Remaining makes the lookup
  -- return NULL, and a plain `=` would yield NULL, which a CHECK accepts.
  constraint installation_entitlements_stage_matches_remaining
    check (stage is not distinct from public.installation_stage_for_remaining(remaining)),
  constraint installation_entitlements_amount_matches_stage
    check (amount is not distinct from public.installation_amount_for_stage(stage)),

  -- Rule 2: a completed subscriber can never carry or receive money.
  constraint installation_entitlements_done_is_unpayable
    check (stage <> 'DONE' or (paid_amount = 0 and payment_status <> 'paid')),

  -- A paid row must record who paid it and when.
  constraint installation_entitlements_paid_is_attributed
    check (payment_status <> 'paid' or (paid_by is not null and paid_at is not null and paid_amount = amount))
);

create index installation_entitlements_period_idx on public.installation_entitlements (period);
create index installation_entitlements_reseller_idx on public.installation_entitlements (reseller);
create index installation_entitlements_stage_idx on public.installation_entitlements (stage);
create index installation_entitlements_invoice_idx on public.installation_entitlements (invoice_status);
create index installation_entitlements_payment_idx on public.installation_entitlements (payment_status);
create index installation_entitlements_batch_idx on public.installation_entitlements (batch_id);

-- Payments are a ledger, not an overwritable field.
create table public.installation_payments (
  id uuid primary key default gen_random_uuid(),
  entitlement_id uuid not null references public.installation_entitlements(id) on delete restrict,
  amount bigint not null,
  payment_date date not null default current_date,
  request_id uuid not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  constraint installation_payments_amount_check check (amount > 0),
  -- Rule 4: one instalment is paid at most once.
  constraint installation_payments_entitlement_key unique (entitlement_id)
);

create index installation_payments_created_at_idx on public.installation_payments (created_at desc);

create trigger trg_installation_entitlement_updated
before update on public.installation_entitlements
for each row execute function public.set_updated_at();

-- Archive protection: once an instalment is paid, the figures that produced that
-- payment are frozen. A later import or rate change can never restate history.
create or replace function public.protect_settled_installation_entitlement()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.payment_status = 'paid' and (
       new.period is distinct from old.period
    or new.subscriber_id is distinct from old.subscriber_id
    or new.stage is distinct from old.stage
    or new.amount is distinct from old.amount
    or new.remaining is distinct from old.remaining
    or new.reseller is distinct from old.reseller
    or new.paid_amount is distinct from old.paid_amount
    or new.paid_at is distinct from old.paid_at
    or new.paid_by is distinct from old.paid_by
  ) then
    raise exception 'A settled installation entitlement cannot be restated'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger trg_installation_entitlement_archive
before update on public.installation_entitlements
for each row execute function public.protect_settled_installation_entitlement();

alter table public.installation_batches enable row level security;
alter table public.installation_entitlements enable row level security;
alter table public.installation_payments enable row level security;

create policy installation_batches_select
on public.installation_batches for select to authenticated
using (public.current_app_role() = any (array['admin', 'accountant', 'monitor', 'viewer']));

create policy installation_entitlements_select
on public.installation_entitlements for select to authenticated
using (public.current_app_role() = any (array['admin', 'accountant', 'monitor', 'viewer']));

create policy installation_payments_select
on public.installation_payments for select to authenticated
using (public.current_app_role() = any (array['admin', 'accountant', 'monitor', 'viewer']));

-- Read-only for every browser session. Every write goes through a checked RPC.
grant select on table public.installation_batches to authenticated;
grant select on table public.installation_entitlements to authenticated;
grant select on table public.installation_payments to authenticated;
revoke insert, update, delete on table public.installation_batches from authenticated;
revoke insert, update, delete on table public.installation_entitlements from authenticated;
revoke insert, update, delete on table public.installation_payments from authenticated;

-- The only write path for entitlements. The browser sends raw subscriber rows;
-- the stage and the amount are derived here and never accepted from the caller.
-- The whole import is one transaction: it either lands completely or not at all.
create or replace function public.import_installation_entitlements(
  p_period text,
  p_file_name text,
  p_file_checksum text,
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
  v_batch_id uuid;
  v_item jsonb;
  v_subscriber text;
  v_reseller text;
  v_zone text;
  v_remaining bigint;
  v_stage text;
  v_amount bigint;
  v_key text;
  v_seen text[] := array[]::text[];
  v_source integer := 0;
  v_accepted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_status text;
  v_result jsonb;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Period must use YYYY-MM' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 20000 then
    raise exception 'Rows must contain between 1 and 20000 entries' using errcode = '22023';
  end if;

  -- Replaying the same request returns the original outcome instead of importing twice.
  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.batch.imported' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('batch', v_existing.after_data, 'replayed', true);
  end if;

  -- One import per period at a time, so two uploads cannot interleave.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('installation-import:' || p_period, 0)
  );

  insert into public.installation_batches (period, file_name, file_checksum, created_by)
  values (p_period, coalesce(btrim(p_file_name), ''), nullif(btrim(coalesce(p_file_checksum, '')), ''), v_actor)
  returning id into v_batch_id;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_source := v_source + 1;
    v_subscriber := btrim(coalesce(v_item ->> 'subscriber_id', ''));
    v_reseller := btrim(coalesce(v_item ->> 'reseller', ''));
    v_zone := nullif(lower(btrim(coalesce(v_item ->> 'zone', ''))), '');

    if v_subscriber = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'missing_subscriber');
      continue;
    end if;
    if v_reseller = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'missing_reseller');
      continue;
    end if;
    if v_zone is not null and v_zone not in ('old', 'new') then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'invalid_zone');
      continue;
    end if;

    -- Remaining must be an exact integer; anything else has no stage.
    begin
      v_remaining := (v_item ->> 'remaining')::bigint;
    exception when others then
      v_remaining := null;
    end;
    v_stage := case when v_remaining is null then null
                    else public.installation_stage_for_remaining(v_remaining) end;
    if v_stage is null then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'unknown_remaining');
      continue;
    end if;
    v_amount := public.installation_amount_for_stage(v_stage);

    v_key := lower(v_subscriber) || chr(31) || v_stage;
    if v_key = any(v_seen) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;
    v_seen := array_append(v_seen, v_key);

    if exists (
      select 1 from public.installation_entitlements
      where period = p_period and subscriber_id = v_subscriber and stage = v_stage
    ) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;

    insert into public.installation_entitlements (
      batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
      remaining, stage, amount, payment_status, created_by
    ) values (
      v_batch_id, p_period, v_subscriber,
      btrim(coalesce(v_item ->> 'subscriber_name', '')), v_reseller, v_zone,
      nullif(btrim(coalesce(v_item ->> 'fdt', '')), ''),
      v_remaining, v_stage, v_amount,
      case when v_stage = 'DONE' then 'not_eligible' else 'awaiting_invoice' end,
      v_actor
    );
    v_accepted := v_accepted + 1;
  end loop;

  v_status := case when v_accepted = 0 then 'no_new_rows' else 'completed' end;
  update public.installation_batches
  set source_rows = v_source,
      accepted_rows = v_accepted,
      duplicate_rows = v_duplicate,
      rejected_rows = v_rejected,
      status = v_status
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'id', v_batch_id, 'period', p_period, 'file_name', coalesce(btrim(p_file_name), ''),
    'source_rows', v_source, 'accepted', v_accepted, 'duplicates', v_duplicate,
    'rejected', v_rejected, 'status', v_status,
    'rejections', case when jsonb_array_length(v_rejects) > 50
                       then jsonb_build_object('truncated', true)
                       else v_rejects end
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, extra, before_data, after_data, request_id
  ) values (
    v_actor, 'installation.batch.imported', 'installation_batch', v_batch_id, 'entitlements',
    '0', v_accepted::text, p_period,
    jsonb_build_object('period', p_period, 'file_name', coalesce(btrim(p_file_name), '')),
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$$;

-- Accounts audits the invoice. Approving an invoice does not pay it.
create or replace function public.audit_installation_invoice(
  p_entitlement_id uuid,
  p_status text,
  p_note text,
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
  v_before public.installation_entitlements%rowtype;
  v_after public.installation_entitlements%rowtype;
  v_existing public.audit_logs%rowtype;
  v_payment_status text;
begin
  if v_actor is null or v_role not in ('admin', 'accountant') then
    raise exception 'Admin or accountant permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_status not in ('pending', 'approved', 'missing', 'rejected') then
    raise exception 'Unknown invoice status' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.invoice.audited'
      or v_existing.entity_id is distinct from p_entitlement_id
    then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('entitlement', v_existing.after_data, 'replayed', true);
  end if;

  select * into v_before from public.installation_entitlements
  where id = p_entitlement_id for update;
  if not found then
    raise exception 'Installation entitlement was not found' using errcode = 'P0002';
  end if;
  if v_before.payment_status = 'paid' then
    raise exception 'A paid instalment cannot be re-audited' using errcode = '23514';
  end if;

  -- A completed subscriber is never eligible, whatever the invoice says.
  v_payment_status := case
    when v_before.stage = 'DONE' then 'not_eligible'
    when p_status = 'approved' then 'eligible'
    else 'awaiting_invoice'
  end;

  update public.installation_entitlements
  set invoice_status = p_status,
      invoice_note = nullif(btrim(coalesce(p_note, '')), ''),
      invoice_audited_by = v_actor,
      invoice_audited_at = now(),
      payment_status = v_payment_status
  where id = p_entitlement_id
  returning * into v_after;

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, before_data, after_data, request_id
  ) values (
    v_actor, 'installation.invoice.audited', 'installation_entitlement', p_entitlement_id,
    'invoice_status', v_before.invoice_status, v_after.invoice_status,
    jsonb_build_object('invoice_status', v_before.invoice_status, 'payment_status', v_before.payment_status),
    jsonb_build_object('invoice_status', v_after.invoice_status, 'payment_status', v_after.payment_status),
    p_request_id
  );

  return jsonb_build_object(
    'entitlement', jsonb_build_object(
      'id', v_after.id,
      'invoice_status', v_after.invoice_status,
      'payment_status', v_after.payment_status,
      'updated_at', v_after.updated_at
    ),
    'replayed', false
  );
end;
$$;

-- The invoice gate. The amount is derived here; the caller never supplies it.
create or replace function public.record_installation_payment(
  p_entitlement_id uuid,
  p_expected_updated_at timestamptz,
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
  v_before public.installation_entitlements%rowtype;
  v_after public.installation_entitlements%rowtype;
  v_existing public.audit_logs%rowtype;
  v_amount bigint;
begin
  if v_actor is null or v_role not in ('admin', 'accountant') then
    raise exception 'Admin or accountant permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.payment.recorded'
      or v_existing.entity_id is distinct from p_entitlement_id
    then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('entitlement', v_existing.after_data, 'replayed', true);
  end if;

  -- Rule 6: the row lock serialises concurrent attempts on the same instalment.
  select * into v_before from public.installation_entitlements
  where id = p_entitlement_id for update;
  if not found then
    raise exception 'Installation entitlement was not found' using errcode = 'P0002';
  end if;
  if p_expected_updated_at is not null and v_before.updated_at <> p_expected_updated_at then
    raise exception 'Installation entitlement changed since it was loaded' using errcode = '40001';
  end if;

  -- Rule 2: nothing is owed on a completed subscriber.
  if v_before.stage = 'DONE' then
    raise exception 'A completed subscriber has no instalment to pay' using errcode = '23514';
  end if;
  -- Rule 1: no approved invoice, no payment.
  if v_before.invoice_status <> 'approved' then
    raise exception 'Payment is blocked until the invoice is approved' using errcode = '23514';
  end if;
  -- Rule 4: already settled.
  if v_before.payment_status = 'paid' or v_before.paid_amount > 0 then
    raise exception 'This instalment was already paid' using errcode = '23505';
  end if;

  -- Rule 5 and 51: the amount comes from the verified stage, never from the caller.
  v_amount := public.installation_amount_for_stage(v_before.stage);
  if v_amount is null or v_amount <= 0 or v_amount <> v_before.amount then
    raise exception 'Installation amount does not match the recorded stage' using errcode = '23514';
  end if;

  insert into public.installation_payments (entitlement_id, amount, request_id, created_by)
  values (p_entitlement_id, v_amount, p_request_id, v_actor);

  update public.installation_entitlements
  set payment_status = 'paid',
      paid_amount = v_amount,
      paid_by = v_actor,
      paid_at = now()
  where id = p_entitlement_id
  returning * into v_after;

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, extra, before_data, after_data, request_id
  ) values (
    v_actor, 'installation.payment.recorded', 'installation_entitlement', p_entitlement_id,
    'paid_amount', v_before.paid_amount::text, v_after.paid_amount::text, v_before.stage,
    jsonb_build_object('payment_status', v_before.payment_status, 'paid_amount', v_before.paid_amount),
    jsonb_build_object('payment_status', v_after.payment_status, 'paid_amount', v_after.paid_amount,
                       'stage', v_after.stage, 'reseller', v_after.reseller),
    p_request_id
  );

  return jsonb_build_object(
    'entitlement', jsonb_build_object(
      'id', v_after.id,
      'stage', v_after.stage,
      'paid_amount', v_after.paid_amount,
      'payment_status', v_after.payment_status,
      'updated_at', v_after.updated_at
    ),
    'replayed', false
  );
end;
$$;

revoke execute on function public.installation_stage_for_remaining(bigint) from public, anon;
revoke execute on function public.installation_amount_for_stage(text) from public, anon;
revoke execute on function public.import_installation_entitlements(text, text, text, jsonb, uuid) from public, anon;
revoke execute on function public.audit_installation_invoice(uuid, text, text, uuid) from public, anon;
revoke execute on function public.record_installation_payment(uuid, timestamptz, uuid) from public, anon;
grant execute on function public.import_installation_entitlements(text, text, text, jsonb, uuid) to authenticated;
grant execute on function public.audit_installation_invoice(uuid, text, text, uuid) to authenticated;
grant execute on function public.record_installation_payment(uuid, timestamptz, uuid) to authenticated;

commit;
