-- مسار دفع العمولة vNext: من الاستحقاق المعتمد إلى الدفتر مباشرة.
--
-- الثغرة المتبقية بعد المرحلة السابقة: المحرّك يحسب استحقاقاً لكل حدث ويعتمد
-- لقطة لكل نطاق، لكن الدفع كان ما يزال يمرّ بـcommission_rows — أي أن الحقيقة
-- المالية شيء والمدفوع منها شيء آخر.
--
-- الوحدة القابلة للدفع هنا هي لقطة النطاق (وكيل في المنطقة القديمة، كابينة في
-- الجديدة)، لأنها الموضع الذي يوجد فيه الإجمالي المعتمد. وبذلك يصير:
--
--   source_table = 'commission_cycle_snapshots'
--   source_id    = معرّف اللقطة
--
-- وهذا يجعل effective_paid_amount ودوالّ التصحيح والعكس تعمل على vNext بلا
-- أي تعديل فيها. لا دفتر ثانٍ، ولا مسار مالٍ موازٍ.
--
-- commission_rows تبقى كما هي: تاريخ مجمَّد يُقرأ ولا يُكتب.
--
-- forward-only. لا صف مالي قائم يُمَس، ولا دفعة تُنشأ بالنشر.

begin;

-- ---------------------------------------------------------------------------
-- 1. الوضع المالي لنطاق معتمد.
--
-- المصدر الوحيد للحقيقة: الإجمالي من اللقطة، والمدفوع الصافي من الدفتر.
-- لا شيء منه يُقرأ من commission_rows ولا يُحسب في المتصفح.
-- ---------------------------------------------------------------------------

create or replace function public.commission_scope_payable(p_snapshot_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snap public.commission_cycle_snapshots%rowtype;
  v_cycle public.commission_cycles%rowtype;
  v_paid bigint;
  v_reversed bigint;
  v_adjusted bigint;
  v_net bigint;
begin
  select * into v_snap from public.commission_cycle_snapshots where id = p_snapshot_id;
  if not found then
    return jsonb_build_object('found', false);
  end if;
  select * into v_cycle from public.commission_cycles where id = v_snap.cycle_id;

  -- المدفوع الصافي: مجموع الحركات باتجاهها. العكس سالب، فيُنقص من نفسه.
  select
    coalesce(sum(case when l.direction = 1 and l.txn_type in ('PAYMENT','HISTORICAL_PAYMENT')
                      then l.amount else 0 end), 0),
    coalesce(sum(case when l.direction = -1 then l.amount else 0 end), 0),
    coalesce(sum(case when l.txn_type in ('ADJUSTMENT','CORRECTION') and l.direction = 1
                      then l.amount else 0 end), 0),
    coalesce(sum(l.amount * l.direction), 0)
  into v_paid, v_reversed, v_adjusted, v_net
  from public.financial_ledger l
  where l.domain = 'commission'
    and l.source_table = 'commission_cycle_snapshots'
    and l.source_id = p_snapshot_id;

  return jsonb_build_object(
    'found', true,
    'snapshot_id', p_snapshot_id,
    'cycle_id', v_snap.cycle_id,
    'cycle_name', v_cycle.name,
    'engine_version', v_cycle.engine_version,
    'scope_type', v_snap.scope_type,
    'scope_id', v_snap.scope_id,
    'scope_label', v_snap.scope_label,
    'zone', v_snap.zone,
    'tier', v_snap.tier_code,
    'unique_activated_subscribers', v_snap.unique_activated_subscribers,
    'qualifying_event_count', v_snap.qualifying_event_count,
    'package_breakdown', v_snap.package_breakdown,
    'gross', v_snap.gross_commission,
    'paid', v_paid,
    'reversed', v_reversed,
    'adjusted', v_adjusted,
    'net_paid', v_net,
    'remaining', greatest(v_snap.gross_commission - v_net, 0),
    -- الدفع لا يجوز إلا من لقطة معتمدة في دورة vNext.
    'payable', v_snap.finalized_at is not null
               and v_cycle.engine_version = 'VNEXT'
               and v_snap.gross_commission - v_net > 0
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. دفعات دفع العمولة.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_payment_batches (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  cycle_id uuid not null references public.commission_cycles(id) on delete restrict,
  status text not null default 'DRAFT',
  payment_reference text,
  prepared_by uuid references auth.users(id),
  prepared_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  total_amount bigint not null default 0,
  item_count integer not null default 0,
  constraint commission_payment_batches_name_key unique (name),
  constraint commission_payment_batches_status_check
    check (status in ('DRAFT', 'READY', 'POSTED', 'CANCELLED')),
  constraint commission_payment_batches_posted_is_attributed
    check (status <> 'POSTED' or (posted_by is not null and posted_at is not null))
);

create table if not exists public.commission_payment_batch_items (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.commission_payment_batches(id) on delete cascade,
  snapshot_id uuid not null references public.commission_cycle_snapshots(id) on delete restrict,
  scope_type text not null,
  scope_id text not null,
  scope_label text,
  zone text,
  agent_name text,
  tier_code text,
  gross_amount bigint not null,
  already_paid bigint not null default 0,
  amount bigint not null,
  status text not null default 'PENDING',
  blocked_reason text,
  ledger_entry_id uuid references public.financial_ledger(id),
  paid_at timestamptz,
  constraint commission_payment_batch_items_identity unique (batch_id, snapshot_id),
  constraint commission_payment_batch_items_status_check
    check (status in ('PENDING', 'PAID', 'BLOCKED', 'SKIPPED')),
  constraint commission_payment_batch_items_amount_check check (amount >= 0),
  -- المدفوع يحمل قيده في الدفتر. لا دفع بلا أثر.
  constraint commission_payment_batch_items_paid_has_ledger
    check (status <> 'PAID' or (ledger_entry_id is not null and paid_at is not null))
);

-- اللقطة الواحدة لا تدخل دفعتين حيّتين.
create unique index if not exists commission_payment_batch_items_snapshot_key
  on public.commission_payment_batch_items (snapshot_id)
  where status in ('PENDING', 'PAID');

create index if not exists commission_payment_batch_items_batch_idx
  on public.commission_payment_batch_items (batch_id, status);

-- ---------------------------------------------------------------------------
-- 3. إعادة التحقق قبل الترحيل.
--
-- حالة «جاهز» محسوبة قبل دقيقة ليست إذناً بالدفع الآن — القاعدة نفسها
-- المطبَّقة في أجور التنصيب.
-- ---------------------------------------------------------------------------

create or replace function public.revalidate_commission_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item record;
  v_state jsonb;
  v_ok integer := 0;
  v_blocked integer := 0;
  v_total bigint := 0;
begin
  perform public.require_capability('commission.prepare_payment');

  for v_item in
    select * from public.commission_payment_batch_items
    where batch_id = p_batch_id and status = 'PENDING'
  loop
    v_state := public.commission_scope_payable(v_item.snapshot_id);

    if not (v_state ->> 'payable')::boolean then
      update public.commission_payment_batch_items
      set status = 'BLOCKED',
          blocked_reason = case
            when (v_state ->> 'engine_version') is distinct from 'VNEXT' then 'NOT_A_VNEXT_CYCLE'
            when (v_state ->> 'remaining')::bigint <= 0 then 'NOTHING_REMAINING'
            else 'SNAPSHOT_NOT_FINALIZED' end
      where id = v_item.id;
      v_blocked := v_blocked + 1;
    else
      -- المبلغ يُعاد ضبطه على المتبقي الحقيقي لحظة التحقق، لا على ما أُعِدّ.
      update public.commission_payment_batch_items
      set amount = least(v_item.amount, (v_state ->> 'remaining')::bigint),
          already_paid = (v_state ->> 'net_paid')::bigint,
          gross_amount = (v_state ->> 'gross')::bigint,
          blocked_reason = null
      where id = v_item.id;
      v_ok := v_ok + 1;
      v_total := v_total + least(v_item.amount, (v_state ->> 'remaining')::bigint);
    end if;
  end loop;

  update public.commission_payment_batches
  set item_count = v_ok, total_amount = v_total,
      status = case when v_ok > 0 and status = 'DRAFT' then 'READY' else status end
  where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'payable', v_ok,
                            'blocked', v_blocked, 'total_amount', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. الترحيل.
--
-- كل بند يُعاد التحقق منه داخل المعاملة، ويُقفل صفّه، ويُكتب قيده في الدفتر
-- نفسه الذي تعمل عليه دوالّ التصحيح والعكس. الحماية من التجاوز تقيس على
-- الصافي من الدفتر لا على عمود محفوظ.
-- ---------------------------------------------------------------------------

create or replace function public.post_commission_batch(
  p_batch_id uuid, p_payment_reference text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_batch public.commission_payment_batches%rowtype;
  v_item record;
  v_state jsonb;
  v_entry uuid;
  v_paid integer := 0;
  v_blocked integer := 0;
  v_total bigint := 0;
  v_cycle public.commission_cycles%rowtype;
begin
  perform public.require_capability('commission.execute_payment');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('commission-batch:' || p_batch_id::text, 0));

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_batch from public.commission_payment_batches
  where id = p_batch_id for update;
  if not found then
    raise exception 'Commission payment batch was not found' using errcode = 'P0002';
  end if;
  if v_batch.status = 'POSTED' then
    raise exception 'The batch is already posted' using errcode = '42501';
  end if;
  if v_batch.status = 'CANCELLED' then
    raise exception 'A cancelled batch cannot be posted' using errcode = '42501';
  end if;

  select * into v_cycle from public.commission_cycles where id = v_batch.cycle_id;
  if v_cycle.engine_version <> 'VNEXT' then
    raise exception 'Only a vNext cycle is paid through this path' using errcode = '42501';
  end if;
  if v_cycle.finalized_at is null then
    raise exception 'The cycle is not finalized' using errcode = '42501';
  end if;

  for v_item in
    select i.* from public.commission_payment_batch_items i
    where i.batch_id = p_batch_id and i.status = 'PENDING'
    order by i.id
    for update
  loop
    -- إعادة تحقق لحظية: ما تغيّر بعد الإعداد يُمسك هنا، لا في الواجهة.
    v_state := public.commission_scope_payable(v_item.snapshot_id);

    if not (v_state ->> 'payable')::boolean
       or v_item.amount <= 0
       or v_item.amount > (v_state ->> 'remaining')::bigint then
      update public.commission_payment_batch_items
      set status = 'BLOCKED',
          blocked_reason = coalesce(nullif(v_state ->> 'payable', 'true'), 'AMOUNT_EXCEEDS_REMAINING')
      where id = v_item.id;
      v_blocked := v_blocked + 1;
      continue;
    end if;

    insert into public.financial_ledger (
      domain, txn_type, source_origin, source_table, source_id,
      agent_name, month_key, original_cycle_key,
      amount, direction, reason, request_id, created_by, posted_by
    ) values (
      'commission', 'PAYMENT', 'PAYMENT_PATH',
      'commission_cycle_snapshots', v_item.snapshot_id,
      v_item.agent_name, v_cycle.name, v_cycle.name,
      v_item.amount, 1,
      coalesce(nullif(btrim(coalesce(p_payment_reference, '')), ''), null),
      p_request_id, v_actor, v_actor
    )
    returning id into v_entry;

    update public.commission_payment_batch_items
    set status = 'PAID', ledger_entry_id = v_entry, paid_at = now(),
        already_paid = (v_state ->> 'net_paid')::bigint
    where id = v_item.id;

    v_paid := v_paid + 1;
    v_total := v_total + v_item.amount;
  end loop;

  update public.commission_payment_batches
  set status = 'POSTED', posted_by = v_actor, posted_at = now(),
      payment_reference = p_payment_reference,
      total_amount = v_total, item_count = v_paid
  where id = p_batch_id;

  -- حالة الدورة تتبع ما دُفع فعلاً، محسوباً من الدفتر لا من عدّاد.
  update public.commission_cycles
  set status = case
    when (select coalesce(sum(s.gross_commission), 0)
          from public.commission_cycle_snapshots s where s.cycle_id = v_batch.cycle_id)
         <= (select coalesce(sum(l.amount * l.direction), 0)
             from public.financial_ledger l
             join public.commission_cycle_snapshots s2 on s2.id = l.source_id
             where l.domain = 'commission'
               and l.source_table = 'commission_cycle_snapshots'
               and s2.cycle_id = v_batch.cycle_id)
    then 'PAID' else 'PARTIALLY_PAID' end
  where id = v_batch.cycle_id and status in ('FINALIZED', 'PARTIALLY_PAID');

  insert into public.audit_logs (
    actor_id, action, field, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.batch.posted', 'status', 'POSTED',
    'commission_payment_batch', p_batch_id, p_request_id,
    'paid=' || v_paid::text || ' blocked=' || v_blocked::text || ' total=' || v_total::text
    || coalesce(' ref=' || nullif(btrim(coalesce(p_payment_reference,'')),''), ''));

  return jsonb_build_object('replayed', false, 'batch_id', p_batch_id,
    'paid_items', v_paid, 'blocked_items', v_blocked, 'total_amount', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. حارس خلط السلطتين.
--
-- دورة vNext لا تُدفَع عبر commission_rows، والعكس بالعكس. الحارس يمنع أن
-- يصير لدورة واحدة مرجعان ماليان.
-- ---------------------------------------------------------------------------

create or replace function public.guard_commission_payment_authority()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_month text;
begin
  if new.paid is not distinct from old.paid then
    return new;
  end if;
  select month_key into v_month from public.commission_months where id = new.month_id;
  if exists (
    select 1 from public.commission_cycles
    where engine_version = 'VNEXT' and name = v_month
      and status in ('FINALIZED','PARTIALLY_PAID','PAID','CLOSED')
  ) then
    raise exception
      'This period is governed by a finalized vNext cycle; pay it through the vNext batch path'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_commission_payment_authority on public.commission_rows;
create trigger trg_guard_commission_payment_authority
  before update on public.commission_rows
  for each row execute function public.guard_commission_payment_authority();

-- ---------------------------------------------------------------------------
-- 6. legacy_month_id — حسمُ الارتباط المعلّق.
--
-- القرار: يبقى العمود مرجعاً وصفياً للتقارير فقط، ولا يقرؤه أي مسار دفع.
-- سبب إبقائه: الدورات القديمة مجمَّدة والدورات الجديدة تُنشأ للفترات المقبلة،
-- فلا حاجة إليه للدفع؛ لكنه يفيد لاحقاً في وصل تقرير بشهر قديم.
-- سبب عدم حذفه: الحذف يستلزم مهاجرة تُعدّل جدولاً حياً بلا فائدة مقابلة.
--
-- والحارس أدناه يمنع الغموض: لا يجوز أن يشير إلى شهر تحكمه دورة vNext أخرى.
-- ---------------------------------------------------------------------------

comment on column public.commission_cycles.legacy_month_id is
  'Descriptive cross-reference to a frozen legacy month, for reporting only. No payment path reads this column; payment authority is engine_version.';

create or replace function public.guard_legacy_month_link()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.legacy_month_id is null then
    return new;
  end if;
  if exists (
    select 1 from public.commission_cycles c
    where c.legacy_month_id = new.legacy_month_id and c.id <> new.id
  ) then
    raise exception 'That legacy month is already cross-referenced by another cycle'
      using errcode = '23505';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_legacy_month_link on public.commission_cycles;
create trigger trg_guard_legacy_month_link
  before insert or update on public.commission_cycles
  for each row execute function public.guard_legacy_month_link();

-- ---------------------------------------------------------------------------
-- 7. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['commission_payment_batches','commission_payment_batch_items'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.has_capability(''commission.view''))',
      t || '_select', t);
  end loop;
end;
$$;

revoke execute on function public.guard_commission_payment_authority() from public, anon, authenticated;
revoke execute on function public.guard_legacy_month_link() from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.commission_scope_payable(uuid)',
    'public.revalidate_commission_batch(uuid)',
    'public.post_commission_batch(uuid, text, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
