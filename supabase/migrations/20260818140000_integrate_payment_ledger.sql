-- ربط مسار الدفع العادي بالدفتر، وإغلاق فجوة «المدفوع القديم مقابل صافي الدفتر».
--
-- الفجوة. بعد 20260818090000 صار التصحيح يغيّر الصافي الفعلي دون أن يمسّ
-- commission_rows.paid. لكن record_commission_payment كان يقيس تجاوز السقف
-- بـ paid وحده:
--
--   المستحق 10000 · paid القديم 3000 · تصحيح +1000 ⇒ الفعلي 4000
--   الأقصى الإضافي الصحيح 6000، بينما الدالة كانت تسمح بـ 7000.
--
-- أي أن التصحيح كان يفتح باب دفع زائد. هذا غير مقبول ويُغلق هنا.
--
-- الحل بأصغر شكل متوافق:
--   1. effective_paid_amount تجيب عن «كم دُفع فعلاً» من مصدر واحد متماسك.
--   2. حارس التجاوز يقيس الزيادة الجديدة فوق الوضع الفعلي لا فوق paid.
--   3. كل دفعة جديدة تكتب قيدها في الدفتر داخل المعاملة نفسها.
--
-- لا يتغير شيء آخر: نفس الأدوار، نفس الأقفال، نفس idempotency، نفس التدقيق،
-- ونفس قواعد التير والمبالغ. لا backfill لأي دفعة تاريخية.
--
-- forward-only.

begin;

-- ---------------------------------------------------------------------------
-- 1. الوضع المالي الفعلي — إجابة واحدة لا إجابتان متنافستان.
--
-- ما دام السجل بلا أي قيد في الدفتر، فالمصدر القديم هو الحقيقة.
-- وبمجرد وجود قيد واحد، يصير الدفتر هو الحقيقة الكاملة لذلك السجل: كل دفعة
-- لاحقة تُكتب فيه أيضاً، فلا ازدواج ولا مصدران.
-- ---------------------------------------------------------------------------

create or replace function public.effective_paid_amount(
  p_domain text,
  p_source_id uuid,
  p_legacy_paid numeric default 0
) returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when count(*) = 0 then coalesce(p_legacy_paid, 0)
    else coalesce(sum(l.amount * l.direction), 0)::numeric
  end
  from public.financial_ledger l
  where l.domain = p_domain and l.source_id = p_source_id;
$$;

comment on function public.effective_paid_amount(text, uuid, numeric) is
  'Authoritative paid position: the legacy column until the ledger holds an entry for this source, the ledger net thereafter. Never computed in the browser.';

-- ---------------------------------------------------------------------------
-- 2. دفعة العمولة: نفس الدالة السابقة حرفياً، مع فارقين.
--
--   • الحارس صار: الفعلي قبل + الزيادة الجديدة ≤ المستحق.
--   • تُلحق قيد PAYMENT بقيمة الزيادة، فيبقى مجموع الدفتر مساوياً للمدفوع.
-- ---------------------------------------------------------------------------

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
  v_effective_before numeric;
  v_delta numeric;
begin
  if v_actor is null or v_role is null
    or v_role not in ('admin', 'accountant')
  then
    raise exception 'Payment permission is required' using errcode = '42501';
  end if;

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0)
  );

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;

  if found then
    if v_existing.action <> 'commission.payment.recorded'
      or v_existing.entity_id is distinct from p_row_id
    then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'row', v_existing.after_data, 'due', (v_existing.extra)::numeric,
      'replayed', true, 'request_id', p_request_id
    );
  end if;

  if p_paid is null or p_paid < 0 then
    raise exception 'Payment cannot be negative' using errcode = '22023';
  end if;

  select r.* into v_before from public.commission_rows as r
  where r.id = p_row_id for update;

  if not found then
    raise exception 'Commission row was not found' using errcode = 'P0002';
  end if;

  if p_expected_updated_at is null
    or v_before.updated_at is distinct from p_expected_updated_at
  then
    raise exception 'Commission row changed since it was loaded' using errcode = '40001';
  end if;

  select month_key, tiers into v_month_key, v_tiers
  from public.commission_months where id = v_before.month_id;

  v_due := public.calculate_commission_due(
    v_tiers, v_before.p35, v_before.p45, v_before.p65, v_before.custom_tier);

  -- الفارق الجوهري عن النسخة السابقة. القيمة الممرّرة مطلقة، فالزيادة الجديدة
  -- هي الفرق عن العمود القديم؛ والسقف يُقاس فوق الوضع الفعلي الذي يشمل أي
  -- تصحيح أو عكس سابق. بدون هذا يصبح التصحيح الموجب باباً للدفع الزائد.
  -- ملاحظة: القفل على الصف أعلاه يسلسل هذا الفحص مع أي دفعة متزامنة، والقفل
  -- الاستشاري في دوال التصحيح يسلسله مع أي تصحيح متزامن.
  v_effective_before := public.effective_paid_amount('commission', p_row_id, v_before.paid);
  v_delta := p_paid - v_before.paid;

  if v_effective_before + v_delta > v_due then
    raise exception 'Payment cannot exceed commission due'
      using errcode = '23514',
            detail = format('effective paid %s + new %s exceeds due %s',
                            v_effective_before, v_delta, v_due);
  end if;

  update public.commission_rows
  set paid = p_paid, payment_date = p_payment_date
  where id = p_row_id
  returning * into v_after;

  -- قيد الدفتر يحمل الزيادة لا الإجمالي، فيبقى مجموع الدفتر متطابقاً مع
  -- المدفوع. زيادة صفرية أو سالبة لا تُنشئ حركة: تعديل التاريخ وحده ليس مالاً.
  if v_delta > 0 then
    insert into public.financial_ledger (
      domain, txn_type, source_origin, source_table, source_id,
      agent_name, month_key, original_cycle_key,
      amount, direction, reason, request_id, created_by, posted_by
    ) values (
      'commission', 'PAYMENT', 'PAYMENT_PATH', 'commission_rows', p_row_id,
      v_after.name, v_month_key, v_month_key,
      v_delta::bigint, 1, null, p_request_id, v_actor, v_actor
    );
  end if;

  insert into public.audit_logs (
    actor_id, month_key, zone, agent, action, field,
    old_value, new_value, extra, entity_type, entity_id,
    before_data, after_data, request_id
  ) values (
    v_actor, v_month_key, v_after.zone, v_after.name,
    'commission.payment.recorded', 'paid,payment_date',
    to_jsonb(v_before)::text, to_jsonb(v_after)::text, v_due::text,
    'commission_row', v_after.id,
    to_jsonb(v_before), to_jsonb(v_after), p_request_id
  );

  return jsonb_build_object(
    'row', to_jsonb(v_after), 'due', v_due,
    'effective_paid', v_effective_before + greatest(v_delta, 0),
    'replayed', false, 'request_id', p_request_id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. دفعة التنصيب: نفس الدالة حرفياً، مع إلحاق قيد الدفتر.
--
-- لا حاجة لحارس فعلي هنا: الدفعة كل-أو-لا-شيء، ومفتاح فريد على الاستحقاق
-- يمنع الثانية، وحالة الاستحقاق تبقى paid بعد العكس فيرفض المسار العادي
-- تكرارها. هذا مقصود وموثّق: العكس لا يعيد فتح المرحلة.
-- ---------------------------------------------------------------------------

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

  select * into v_before from public.installation_entitlements
  where id = p_entitlement_id for update;
  if not found then
    raise exception 'Installation entitlement was not found' using errcode = 'P0002';
  end if;
  if p_expected_updated_at is not null and v_before.updated_at <> p_expected_updated_at then
    raise exception 'Installation entitlement changed since it was loaded' using errcode = '40001';
  end if;

  if v_before.stage = 'DONE' then
    raise exception 'A completed subscriber has no instalment to pay' using errcode = '23514';
  end if;
  if v_before.invoice_status <> 'approved' then
    raise exception 'Payment is blocked until the invoice is approved' using errcode = '23514';
  end if;
  -- يشمل الحالة بعد العكس: الاستحقاق يبقى paid، فلا تُدفع المرحلة مرة ثانية
  -- عبر المسار العادي. البديل بعد العكس يمرّ من correct_financial_entry وحدها.
  if v_before.payment_status = 'paid' or v_before.paid_amount > 0 then
    raise exception 'This instalment was already paid' using errcode = '23505';
  end if;

  v_amount := public.installation_amount_for_stage(v_before.stage);
  if v_amount is null or v_amount <= 0 or v_amount <> v_before.amount then
    raise exception 'Installation amount does not match the recorded stage' using errcode = '23514';
  end if;

  insert into public.installation_payments (entitlement_id, amount, request_id, created_by)
  values (p_entitlement_id, v_amount, p_request_id, v_actor);

  update public.installation_entitlements
  set payment_status = 'paid', paid_amount = v_amount,
      paid_by = v_actor, paid_at = now()
  where id = p_entitlement_id
  returning * into v_after;

  insert into public.financial_ledger (
    domain, txn_type, source_origin, source_table, source_id,
    agent_name, subscriber_id, stage, month_key, original_cycle_key,
    amount, direction, reason, request_id, created_by, posted_by
  ) values (
    'installation', 'PAYMENT', 'PAYMENT_PATH', 'installation_entitlements', p_entitlement_id,
    v_after.reseller, v_after.subscriber_id, v_after.stage, v_after.period, v_after.period,
    v_amount, 1, null, p_request_id, v_actor, v_actor
  );

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
      'id', v_after.id, 'stage', v_after.stage,
      'paid_amount', v_after.paid_amount, 'payment_status', v_after.payment_status,
      'updated_at', v_after.updated_at
    ),
    'replayed', false
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. الصلاحيات كما كانت بالضبط.
-- ---------------------------------------------------------------------------

revoke execute on function public.effective_paid_amount(text, uuid, numeric) from public, anon;
grant execute on function public.effective_paid_amount(text, uuid, numeric) to authenticated;

revoke execute on function public.record_commission_payment(uuid, timestamptz, numeric, date, uuid)
  from public, anon;
grant execute on function public.record_commission_payment(uuid, timestamptz, numeric, date, uuid)
  to authenticated;

revoke execute on function public.record_installation_payment(uuid, timestamptz, uuid)
  from public, anon;
grant execute on function public.record_installation_payment(uuid, timestamptz, uuid)
  to authenticated;

commit;
