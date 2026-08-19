-- ---------------------------------------------------------------------------
-- صرف أجور التنصيب: الدفعة وحدةُ العمل، والسطر وحدةُ الحقيقة
--
-- لا يُصرف مشترك بمفرده من الواجهة. وحدة العمل التشغيلية دفعةٌ تُراجَع
-- بالوكيل، لكن ما يُخزَّن ويُدقَّق سطرٌ لكل (مشترك + مرحلة + مبلغ). فالدفعة
-- تُجمَّع للعرض، والحقيقة تبقى مفصَّلة: أيّ مشترك قُبض له، وعن أيّ مرحلة،
-- وكم، ومتى، وتحت أيّ دفعة، وبأيّ إشعار خارجي.
--
-- والقاعدة التي تحكم كل ما دونها: الأساس التاريخي المستورد مدفوعٌ سلفاً ولا
-- يُدفع ثانية. المتبقّي المسجَّل هو ما يحدّد القسط التالي المؤهَّل — لا
-- إعادة بناءٍ لمراحل ماضية.
--
-- وإنشاء الدفعة ليس دفعاً. لا شيء يصير مدفوعاً إلا بتأكيدٍ صريح يحمل تاريخ
-- الدفع ورقم الإشعار الخارجي، وبعد أن يُعيد الخادم فحص كل سطرٍ من جديد.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. حالات الدفعة
-- ---------------------------------------------------------------------------

alter table public.installation_payment_batches
  add column if not exists payment_date   date,
  add column if not exists payment_ref    text,
  add column if not exists payment_note   text,
  add column if not exists validated_at   timestamptz,
  add column if not exists validated_by   uuid references auth.users(id),
  add column if not exists blocked_count  integer not null default 0,
  add column if not exists cancelled_at   timestamptz,
  add column if not exists cancelled_by   uuid references auth.users(id),
  add column if not exists cancel_reason  text,
  add column if not exists request_id     uuid;

-- المجموعة القديمة كانت DRAFT/READY/POSTED/CANCELLED، وينقصها الطورُ الذي
-- تُراجَع فيه الدفعة قبل أن تُعدّ جاهزة. و«POSTED» اسمٌ ثانٍ للمدفوع لا
-- تكتبه شيفرةٌ في هذا الجدول ولا يحمله صفّ، فيُستبدل بـPAID بدل أن يبقى
-- اسمان لحالةٍ واحدة. (دفعات العمولة جدولٌ آخر، ولها POSTED الخاصّ بها.)
alter table public.installation_payment_batches
  drop constraint if exists installation_payment_batches_status_check;

alter table public.installation_payment_batches
  add constraint installation_payment_batches_status_check
  check (status in ('DRAFT', 'VALIDATED', 'READY', 'PAID', 'CANCELLED'));

do $$
begin

  -- الدفع لا يُسجَّل بلا تاريخٍ وإشعار خارجي. إنشاء الدفعة ليس دفعاً.
  if not exists (select 1 from pg_constraint
                 where conname = 'installation_payment_batches_paid_needs_reference') then
    alter table public.installation_payment_batches
      add constraint installation_payment_batches_paid_needs_reference
      check (status <> 'PAID'
             or (payment_date is not null
                 and btrim(coalesce(payment_ref, '')) <> ''
                 and posted_by is not null and posted_at is not null));
  end if;

  if not exists (select 1 from pg_constraint
                 where conname = 'installation_payment_batches_cancel_is_attributed') then
    alter table public.installation_payment_batches
      add constraint installation_payment_batches_cancel_is_attributed
      check (status <> 'CANCELLED'
             or (cancelled_by is not null and cancelled_at is not null
                 and btrim(coalesce(cancel_reason, '')) <> ''));
  end if;
end $$;

-- القيد القديم كان يتكلّم عن POSTED، وهي حالةٌ لم تعد في المجموعة.
alter table public.installation_payment_batches
  drop constraint if exists installation_payment_batches_posted_is_attributed;

-- لا تُضاف أعمدة دفعة/تاريخ/إشعار إلى installation_payments.
--
-- الوصلة موجودة سلفاً: صفُّ الدفع مرتبطٌ باستحقاقه، والاستحقاق بسطرٍ في
-- الدفعة، والدفعة تحمل التاريخ والإشعار. وإضافتها هنا كانت ستعني كتابة
-- صفٍّ ماليّ ثم ترقيعه، فتُفتح لحظةٌ يوجد فيها دفعٌ بلا مرجع.

-- حالات السطر معرَّفة سلفاً: PENDING | PAID | BLOCKED | SKIPPED. لا تُضاف
-- مفردات موازية لها — «جاهز» هو PENDING، و«مُخرَج» هو SKIPPED.

-- ---------------------------------------------------------------------------
-- 2. حالة السطر — يقرّرها الخادم لا المتصفّح
-- ---------------------------------------------------------------------------

create or replace function public.installation_payment_state(p_entitlement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_ent   public.installation_entitlements%rowtype;
  v_eval  jsonb;
  v_item  record;
begin
  perform public.require_capability('installation.view');

  select * into v_ent from public.installation_entitlements where id = p_entitlement_id;
  if not found then
    return jsonb_build_object('state', 'UNKNOWN', 'blockers', '[]'::jsonb);
  end if;

  if v_ent.payment_status = 'paid' then
    return jsonb_build_object('state', 'PAID', 'blockers', '[]'::jsonb,
                              'amount', v_ent.amount, 'stage', v_ent.stage);
  end if;

  select b.id as batch_id, b.name as batch_name, b.status as batch_status, i.status as item_status
    into v_item
  from public.installation_payment_batch_items i
  join public.installation_payment_batches b on b.id = i.batch_id
  where i.entitlement_id = p_entitlement_id
    and b.status in ('DRAFT', 'VALIDATED', 'READY')
    and i.status <> 'SKIPPED'
  limit 1;

  v_eval := public.installation_entitlement_eligibility(p_entitlement_id);

  if not (v_eval ->> 'eligible')::boolean then
    return jsonb_build_object('state', 'BLOCKED', 'blockers', v_eval -> 'blockers',
                              'amount', v_ent.amount, 'stage', v_ent.stage,
                              'batch_id', v_item.batch_id, 'batch_name', v_item.batch_name);
  end if;

  if v_item.batch_id is not null then
    return jsonb_build_object('state', 'IN_BATCH', 'blockers', '[]'::jsonb,
                              'amount', v_ent.amount, 'stage', v_ent.stage,
                              'batch_id', v_item.batch_id, 'batch_name', v_item.batch_name,
                              'batch_status', v_item.batch_status);
  end if;

  return jsonb_build_object('state', 'READY', 'blockers', '[]'::jsonb,
                            'amount', v_ent.amount, 'stage', v_ent.stage);
end;
$fn$;

revoke execute on function public.installation_payment_state(uuid) from public, anon;
grant execute on function public.installation_payment_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. مرشّحو الصرف من الأساس التاريخي
--
-- ليست استحقاقات: لا صفوف تُنشأ ولا مالٌ يُلتزم به. قراءةٌ تقول ما الذي
-- يؤهّله المتبقّي المسجَّل ليكون القسط التالي. تُسمّى مرشّحاً لا مستحقاً كي
-- لا يُقرأ رقمٌ استكشافي على أنه التزام.
-- ---------------------------------------------------------------------------

create or replace function public.installation_payout_candidates()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with base as (
    select
      s.subscriber_id,
      s.reseller,
      st.remaining,
      st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      st.resolution,
      st.payment_eligible,
      exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at)) as held
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  )
  select jsonb_build_object(
    'subscribers', count(*),
    'amount', coalesce(sum(amount), 0),
    'held', count(*) filter (where held),
    'held_amount', coalesce(sum(amount) filter (where held), 0),
    'unresolved', count(*) filter (where resolution <> 'resolved' or not payment_eligible),
    'by_stage', coalesce((
      select jsonb_object_agg(x.stage, jsonb_build_object('subscribers', x.n, 'amount', x.amt))
      from (select stage, count(*) as n, sum(amount) as amt from base group by stage) x), '{}'::jsonb),
    'by_reseller', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select b.reseller,
               count(*) as subscribers,
               sum(b.amount) as amount,
               count(*) filter (where b.stage = 'P1') as p1,
               count(*) filter (where b.stage = 'P2') as p2,
               count(*) filter (where b.stage = 'P3') as p3,
               count(*) filter (where b.stage = 'P4') as p4,
               count(*) filter (where b.held) as held,
               count(*) filter (where not b.held
                 and b.resolution = 'resolved' and b.payment_eligible) as ready
        from base b
        group by b.reseller
        order by sum(b.amount) desc) y), '[]'::jsonb))
  from base
  where public.has_capability('installation.view');
$fn$;

revoke execute on function public.installation_payout_candidates() from public, anon;
grant execute on function public.installation_payout_candidates() to authenticated;

-- سطور وكيلٍ واحد — للمراجعة المحاسبية قبل إنشاء الدفعة.
create or replace function public.page_payout_candidate_lines(
  p_reseller text default null,
  p_stage text default null,
  p_only_ready boolean default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select
      s.subscriber_id, s.reseller, s.fdt,
      st.remaining, st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      st.resolution, st.payment_eligible,
      (select h.id from public.installation_holds h
       where h.subscriber_id = s.subscriber_id
         and public.hold_is_effective(h.status, h.permanence, h.expires_at)
       limit 1) as hold_id,
      (select coalesce(h.reason_note, h.note) from public.installation_holds h
       where h.subscriber_id = s.subscriber_id
         and public.hold_is_effective(h.status, h.permanence, h.expires_at)
       limit 1) as hold_reason,
      exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED') as invoice_ok
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  ),
  kept as (
    select b.*,
      (b.hold_id is null and b.resolution = 'resolved' and b.payment_eligible) as is_ready
    from base b
    where (p_reseller is null or b.reseller = p_reseller)
      and (p_stage is null or b.stage = p_stage)
  ),
  filtered as (
    select * from kept k
    where p_only_ready is null or k.is_ready = p_only_ready
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select f.subscriber_id, f.reseller, f.fdt, f.stage, f.amount, f.remaining,
             f.hold_id is not null as held, f.hold_reason, f.invoice_ok,
             f.resolution, f.payment_eligible, f.is_ready
      from filtered f
      order by f.is_ready desc, f.subscriber_id
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from filtered;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_payout_candidate_lines(text,text,boolean,integer,integer)
  from public, anon;
grant execute on function public.page_payout_candidate_lines(text,text,boolean,integer,integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3.5 هل يُدفع هذا السطر؟ — تعريفٌ واحد يستعمله الطرفان
--
-- الأهلية وحدها لا تكفي جواباً. مسار الدفع القائم
-- (assert_installation_payment_allowed) يتسامح مع NOT_ENROLLED عمداً: مشتركو
-- الأساس التاريخي لا صفَّ تسجيلٍ لهم، فاشتراطه يحجب الأساس كلّه.
--
-- ولو كتبتُ هنا شرطاً أشدّ لبدا أحوط وهو في الحقيقة كسرٌ للمسار المعتمد:
-- تُعرَض الدفعة جاهزة ثم تُرفض عند الترحيل، أو العكس. فالتعريف واحد،
-- ويحرسه اختبارٌ يقارن الطرفين على الحالات نفسها.
-- ---------------------------------------------------------------------------

create or replace function public.installation_line_payable(p_entitlement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_eval jsonb;
  v_rest jsonb;
begin
  perform public.require_capability('installation.view');

  v_eval := public.installation_entitlement_eligibility(p_entitlement_id);

  -- ما عدا NOT_ENROLLED من الحواجب.
  select coalesce(jsonb_agg(b), '[]'::jsonb) into v_rest
  from jsonb_array_elements_text(v_eval -> 'blockers') b
  where b <> 'NOT_ENROLLED';

  return jsonb_build_object(
    'entitlement_id', p_entitlement_id,
    'payable', jsonb_array_length(v_rest) = 0,
    'blockers', v_rest,
    'amount', v_eval -> 'amount',
    'stage', v_eval -> 'stage');
end;
$fn$;

revoke execute on function public.installation_line_payable(uuid) from public, anon;
grant execute on function public.installation_line_payable(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. إعادة التحقّق من الدفعة
--
-- تُستدعى عند التحقّق وقبل التأكيد معاً. المشترك الذي عُلّق بعد إدراجه في
-- مسوّدةٍ يجب أن يخرج من الدفعة بسببه المكتوب، لا أن يمرّ لأنه كان مؤهَّلاً
-- ساعةَ الإدراج.
-- ---------------------------------------------------------------------------

create or replace function public.revalidate_installation_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_batch   public.installation_payment_batches%rowtype;
  v_item    record;
  v_eval    jsonb;
  v_ready   integer := 0;
  v_blocked integer := 0;
  v_total   bigint := 0;
begin
  perform public.require_capability('payment.prepare');

  select * into v_batch from public.installation_payment_batches
  where id = p_batch_id for update;
  if not found then
    raise exception 'Batch not found' using errcode = '22023';
  end if;
  if v_batch.status in ('PAID', 'CANCELLED') then
    raise exception 'A % batch cannot be revalidated', v_batch.status using errcode = '22023';
  end if;

  for v_item in
    select i.id, i.entitlement_id from public.installation_payment_batch_items i
    where i.batch_id = p_batch_id and i.status <> 'SKIPPED'
  loop
    v_eval := public.installation_line_payable(v_item.entitlement_id);

    if (v_eval ->> 'payable')::boolean then
      update public.installation_payment_batch_items
      set status = 'PENDING', blocked_reason = null
      where id = v_item.id;
      v_ready := v_ready + 1;
      v_total := v_total + coalesce((v_eval ->> 'amount')::bigint, 0);
    else
      -- السبب يُكتب بنصّه لا برمزٍ مبهم، فيُقرأ على الشاشة كما هو.
      update public.installation_payment_batch_items
      set status = 'BLOCKED',
          blocked_reason = array_to_string(
            array(select jsonb_array_elements_text(v_eval -> 'blockers')), ', ')
      where id = v_item.id;
      v_blocked := v_blocked + 1;
    end if;
  end loop;

  update public.installation_payment_batches
  set status = case when v_blocked = 0 and v_ready > 0 then 'READY' else 'VALIDATED' end,
      total_amount = v_total,
      item_count = v_ready + v_blocked,
      blocked_count = v_blocked,
      validated_at = now(),
      validated_by = auth.uid()
  where id = p_batch_id;

  return jsonb_build_object(
    'batch_id', p_batch_id,
    'status', case when v_blocked = 0 and v_ready > 0 then 'READY' else 'VALIDATED' end,
    'ready', v_ready, 'blocked', v_blocked, 'total_amount', v_total);
end;
$fn$;

revoke execute on function public.revalidate_installation_batch(uuid) from public, anon;
grant execute on function public.revalidate_installation_batch(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. تأكيد الدفع — الخطوة الوحيدة التي تُنشئ مالاً
--
-- تُعيد الفحص داخل المعاملة نفسها ثم تُرحّل سطراً سطراً عبر مسار الدفع
-- القائم، فتبقى كل حراساته سارية: لا مرحلة مدفوعة مرّتين، ولا فاتورة غير
-- معتمدة، ولا مبلغٌ يخالف مرحلته، وقيدُ دفترٍ لكل سطر.
-- ---------------------------------------------------------------------------

create or replace function public.confirm_installation_batch_payment(
  p_batch_id uuid,
  p_payment_date date,
  p_reference text,
  p_note text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_batch public.installation_payment_batches%rowtype;
  v_check jsonb;
  v_item  record;
  v_paid  integer := 0;
  v_sum   bigint := 0;
begin
  perform public.require_capability('payment.execute');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_payment_date is null then
    raise exception 'A payment needs its date' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reference, '')) = '' then
    raise exception 'A payment needs an external reference' using errcode = '22023';
  end if;

  if exists (select 1 from public.installation_payment_batches
             where request_id = p_request_id and status = 'PAID') then
    return jsonb_build_object('batch_id', p_batch_id, 'idempotent', true);
  end if;

  select * into v_batch from public.installation_payment_batches
  where id = p_batch_id for update;
  if not found then
    raise exception 'Batch not found' using errcode = '22023';
  end if;
  if v_batch.status = 'PAID' then
    return jsonb_build_object('batch_id', p_batch_id, 'idempotent', true);
  end if;
  if v_batch.status not in ('VALIDATED', 'READY') then
    raise exception 'A % batch cannot be paid; validate it first', v_batch.status
      using errcode = '22023';
  end if;

  -- الفحص من جديد في المعاملة نفسها: ما تغيّر منذ التحقّق يظهر الآن.
  v_check := public.revalidate_installation_batch(p_batch_id);
  if (v_check ->> 'blocked')::integer > 0 then
    raise exception 'Batch has % blocked line(s); they must be resolved or removed',
      v_check ->> 'blocked' using errcode = '23514';
  end if;
  if (v_check ->> 'ready')::integer = 0 then
    raise exception 'Batch has no payable line' using errcode = '22023';
  end if;

  for v_item in
    select i.id, i.entitlement_id, i.amount
    from public.installation_payment_batch_items i
    where i.batch_id = p_batch_id and i.status = 'PENDING'
    order by i.id
  loop
    -- معرّف الطلب مشتقٌّ من الدفعة والسطر، فإعادة التأكيد لا تدفع مرّتين.
    perform public.record_installation_payment(
      v_item.entitlement_id, null,
      public.uuid_from_parts(p_request_id, v_item.id));


    update public.installation_payment_batch_items
    set status = 'PAID', paid_at = now()
    where id = v_item.id;

    v_paid := v_paid + 1;
    v_sum := v_sum + coalesce(v_item.amount, 0);
  end loop;

  update public.installation_payment_batches
  set status = 'PAID', payment_date = p_payment_date,
      payment_ref = btrim(p_reference),
      payment_note = nullif(btrim(coalesce(p_note, '')), ''),
      posted_by = v_actor, posted_at = now(),
      request_id = p_request_id,
      total_amount = v_sum, item_count = v_paid, blocked_count = 0
  where id = p_batch_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.batch.paid', 'status', v_batch.status, 'PAID',
    'installation_payment_batch', p_batch_id, p_request_id,
    'lines=' || v_paid || ' amount=' || v_sum
      || ' date=' || p_payment_date::text || ' ref=' || btrim(p_reference));

  return jsonb_build_object(
    'batch_id', p_batch_id, 'idempotent', false,
    'lines_paid', v_paid, 'amount', v_sum,
    'payment_date', p_payment_date, 'reference', btrim(p_reference));
end;
$fn$;

revoke execute on function public.confirm_installation_batch_payment(uuid,date,text,text,uuid)
  from public, anon;
grant execute on function public.confirm_installation_batch_payment(uuid,date,text,text,uuid)
  to authenticated;

-- معرّف مشتقّ ثابت: الدفعة نفسها والسطر نفسه يُنتجان المعرّف نفسه دائماً.
create or replace function public.uuid_from_parts(p_a uuid, p_b uuid)
returns uuid
language sql
immutable
set search_path = ''
as $fn$
  select md5(p_a::text || ':' || p_b::text)::uuid;
$fn$;

revoke execute on function public.uuid_from_parts(uuid,uuid) from public, anon;
grant execute on function public.uuid_from_parts(uuid,uuid) to authenticated;

create index if not exists installation_payment_batch_items_batch_idx
  on public.installation_payment_batch_items (batch_id, status);

commit;
