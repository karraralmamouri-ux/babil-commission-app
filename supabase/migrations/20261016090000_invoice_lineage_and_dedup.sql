-- توثيق السلسلة: فاتورة → استحقاق → بند دفعة، ومنع التسابق على فاتورة نفس المرحلة.
--
-- (1) قيد فريد ناقص. review_invoice يقرأ فيبحث ثم يقرّر إدراجاً أو تحديثاً،
--     ولا قيد قاعدة بيانات يمنع نداءين متزامنين من الإدراج معاً لنفس
--     (subscriber_id, stage_code) — سباقٌ كلاسيكي بين القراءة والإدراج، لا
--     يظهر إلا تحت تزامن حقيقي. يُغلَق هنا بفهرس فريد جزئي، وبإعادة كتابة
--     الدالة بـ INSERT ... ON CONFLICT ذرّياً بدل SELECT ثم فرع.
--
-- (2) installation_payment_batch_items.invoice_id معلَنٌ في المخطّط
--     (20260820150000) ولا يُملأ قط: create_installation_batch يُدرج سبعة
--     أعمدة ويسقط invoice_id، فسلسلة التتبّع فاتورة→استحقاق→دفعة تنقطع عند
--     الدفعة رغم وجود العمود لهذا بالضبط. يُملأ هنا من فاتورة المرحلة
--     المدقَّقة نفسها التي أهّلت الاستحقاق أصلاً — قراءة، لا افتراض جديد.
--
-- forward-only. لا صف مالي يُمَس، ولا فاتورة تُعاد تدقيقها، ولا دفعة تُعاد بناؤها.

begin;

-- ---------------------------------------------------------------------------
-- 1. قيد فريد: فاتورة واحدة لكل (مشترك، مرحلة). review_invoice هو الكاتب
--    الوحيد لهذا الجدول (لا مسار استيراد آخر اليوم)، وهو يشترط أصلاً مرحلة
--    من P1..P4، فلا صفّ قائم يخالف هذا القيد.
-- ---------------------------------------------------------------------------

create unique index if not exists installation_invoices_subscriber_stage_key
  on public.installation_invoices (subscriber_id, stage_code)
  where stage_code is not null;

create or replace function public.review_invoice(
  p_subscriber_id text,
  p_stage_code text,
  p_status text,
  p_note text,
  p_invoice_number text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  uuid := auth.uid();
  v_id     uuid;
  v_before text;
  v_amount bigint;
  v_sid    text;
begin
  -- التدقيق يفتح مالاً، والرفض يُغلقه. صلاحيتان مختلفتان لقرارين مختلفين.
  if p_status = 'VERIFIED' then
    perform public.require_capability('invoice.verify');
  else
    perform public.require_capability('invoice.reject');
  end if;

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_status not in ('PENDING', 'VERIFIED', 'MISSING', 'REJECTED') then
    raise exception 'Unknown invoice status %', p_status using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'An invoice decision must state its reason' using errcode = '22023';
  end if;
  if p_stage_code not in ('P1', 'P2', 'P3', 'P4') then
    raise exception 'Invoices are reviewed per payable stage' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'installation.invoice.reviewed') then
    return jsonb_build_object('subscriber_id', p_subscriber_id, 'idempotent', true);
  end if;

  -- المرحلة المدقَّقة يجب أن تكون القسط القادم فعلاً: تدقيق مرحلةٍ ماضية
  -- يفتح مالاً عن قسطٍ دُفع.
  select s.subscriber_id into v_sid
  from public.installation_subscribers s
  join public.installation_subscriber_state st on st.subscriber_uuid = s.id
  where lower(btrim(s.subscriber_id)) = lower(btrim(p_subscriber_id))
    and st.current_stage = p_stage_code
    and coalesce(st.remaining, 0) > 0;
  if v_sid is null then
    raise exception 'Stage % is not the next unpaid instalment for %',
      p_stage_code, p_subscriber_id using errcode = '22023';
  end if;

  v_amount := public.installation_amount_for_stage(p_stage_code);

  select status into v_before
  from public.installation_invoices
  where subscriber_id = v_sid and stage_code = p_stage_code;
  v_before := coalesce(v_before, 'NOT_CHECKED');

  -- ذرّي: القيد الفريد أعلاه يجعل هذا معاملة إدراج-أو-تحديث واحدة، فلا
  -- نداءان متزامنان ينتجان صفّين لنفس (المشترك، المرحلة).
  insert into public.installation_invoices (
    subscriber_id, stage_code, invoice_number, invoice_source, amount, status,
    verified_by, verified_at, rejected_by, rejected_at, rejection_reason, created_by)
  values (
    v_sid, p_stage_code, nullif(btrim(coalesce(p_invoice_number, '')), ''),
    'MANUAL', v_amount, p_status,
    case when p_status = 'VERIFIED' then v_actor end,
    case when p_status = 'VERIFIED' then now() end,
    case when p_status = 'REJECTED' then v_actor end,
    case when p_status = 'REJECTED' then now() end,
    case when p_status = 'REJECTED' then btrim(p_note) end,
    v_actor)
  on conflict (subscriber_id, stage_code) where stage_code is not null do update
  set status = excluded.status,
      invoice_number = coalesce(excluded.invoice_number, public.installation_invoices.invoice_number),
      verified_by = excluded.verified_by,
      verified_at = excluded.verified_at,
      rejected_by = excluded.rejected_by,
      rejected_at = excluded.rejected_at,
      rejection_reason = excluded.rejection_reason
  returning id into v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.invoice.reviewed', 'status', v_before, p_status,
    'installation_invoice', v_id, p_request_id,
    'subscriber=' || v_sid || ' stage=' || p_stage_code
      || ' amount=' || v_amount::text
      || coalesce(' number=' || nullif(btrim(coalesce(p_invoice_number, '')), ''), '')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object(
    'subscriber_id', v_sid, 'stage', p_stage_code,
    'status_before', v_before, 'status_after', p_status,
    'amount', v_amount, 'idempotent', false);
end;
$fn$;

revoke execute on function public.review_invoice(text,text,text,text,text,uuid) from public, anon;
grant execute on function public.review_invoice(text,text,text,text,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. سلسلة الإحالة: بند الدفعة يحمل الفاتورة التي أهّلته. القيد أعلاه يضمن
--    فاتورة واحدة على الأكثر لكل (مشترك، مرحلة)، فالربط هنا لا يُضاعف سطراً.
-- ---------------------------------------------------------------------------

create or replace function public.create_installation_batch(
  p_name text,
  p_reseller text default null,
  p_period text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_items integer := 0;
  v_sum   bigint := 0;
begin
  perform public.require_capability('payment.prepare');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A batch must be named' using errcode = '22023';
  end if;

  select id into v_id from public.installation_payment_batches
  where request_id = p_request_id;
  if found then
    return jsonb_build_object('batch_id', v_id, 'idempotent', true);
  end if;

  insert into public.installation_payment_batches (
    name, status, prepared_by, prepared_at, request_id)
  values (btrim(p_name), 'DRAFT', v_actor, now(), p_request_id)
  returning id into v_id;

  -- يُدرَج ما يجتاز التعريف المشترك للقابلية، لا ما يبدو جاهزاً في شاشة.
  with candidates as (
    select t.id, t.subscriber_id, t.reseller, t.stage, t.amount,
           inv.id as invoice_id
    from public.installation_entitlements t
    left join public.installation_invoices inv
      on inv.subscriber_id = t.subscriber_id
     and inv.stage_code = t.stage
     and inv.status = 'VERIFIED'
    where t.payment_status <> 'paid'
      and (p_reseller is null or t.reseller = p_reseller)
      and (p_period is null or t.period = p_period)
      and (public.installation_line_payable(t.id) ->> 'payable')::boolean
      and not exists (
        select 1 from public.installation_payment_batch_items i
        join public.installation_payment_batches b on b.id = i.batch_id
        where i.entitlement_id = t.id
          and b.status in ('DRAFT','VALIDATED','READY','PAID')
          and i.status <> 'SKIPPED')
    order by t.reseller, t.subscriber_id
  )
  insert into public.installation_payment_batch_items (
    batch_id, entitlement_id, subscriber_id, agent_name, stage_code, amount, invoice_id, status)
  select v_id, c.id, c.subscriber_id, c.reseller, c.stage, c.amount, c.invoice_id, 'PENDING'
  from candidates c;

  get diagnostics v_items = row_count;

  select coalesce(sum(amount), 0) into v_sum
  from public.installation_payment_batch_items where batch_id = v_id;

  update public.installation_payment_batches
  set item_count = v_items, total_amount = v_sum
  where id = v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.batch.created', 'item_count', '0', v_items::text,
    'installation_payment_batch', v_id, p_request_id,
    'name=' || btrim(p_name) || coalesce(' reseller=' || p_reseller, '')
      || ' amount=' || v_sum::text);

  return jsonb_build_object(
    'batch_id', v_id, 'idempotent', false,
    'items', v_items, 'amount', v_sum, 'status', 'DRAFT');
end;
$fn$;

revoke execute on function public.create_installation_batch(text,text,text,uuid) from public, anon;
grant execute on function public.create_installation_batch(text,text,text,uuid) to authenticated;

commit;
