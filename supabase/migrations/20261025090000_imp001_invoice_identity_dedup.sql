-- IMP-001: هوية الفاتورة = SOURCE/SYSTEM + INVOICE REFERENCE/NUMBER — لا
-- تُنشئ استحقاقاً مرتين، ولا يتخطّاها تزامنٌ ولا رفعٌ مكرَّر.
--
-- الفجوة الفعلية بعد قراءة كل مسار كتابة على installation_invoices:
--
--   القيد الفريد الوحيد اليوم (20261016090000) هو (subscriber_id, stage_code)
--   — يمنع فاتورتين لنفس القسط، لا يمنع نفس رقم الفاتورة من خدمة قسطين
--   مختلفين. فحص "already_used بالرقم" (invoice_number_used) موجودٌ فقط
--   داخل preview_bulk_invoice_upload/apply_bulk_invoice_upload كمنطق تطبيقٍ
--   مُعاد حسابه خادمياً — لا كقيد قاعدة بيانات. review_invoice نفسها (نقطة
--   الكتابة الوحيدة الفعلية، ومصدر UI المراجعة الفردية) لا تفحص رقم الفاتورة
--   إطلاقاً: مستخدمان (أو نداءان متزامنان لنفس المستخدم) يستطيعان اليوم
--   تدقيق نفس رقم الفاتورة لمشتركين مختلفين تماماً بلا رفض — لا فحصاً
--   تطبيقياً ولا قيداً قاعدياً يوقفهما. وحتى مسار الرفعة الجماعية، رغم فحصه
--   التطبيقي الصحيح، يبقى عرضة لسباق قراءة-ثم-كتابة كلاسيكي بين رفعتين
--   متزامنتين: كلتاهما قد تقرآن invoice_number_used=false قبل أن تُدرج
--   أيّهما، فتمرّان معاً.
--
-- الإصلاح على مستويين، كما طُلب: تطبيقي (رسالة خطأ واضحة عند المراجعة
-- الفردية، مطابقة لمنطق الرفعة الجماعية تماماً) وقاعدي (فهرس فريد جزئي
-- يجعل السباق مستحيلاً بنيوياً، لا فقط نادراً).
--
-- النطاق: (invoice_source, invoice_number) حيث invoice_number ليس فارغاً
-- وstatus='VERIFIED' فقط — لا PENDING ولا REJECTED، لأن هذين لا يفتحان
-- مالاً بعد (create_installation_batch لا يقرأ إلا VERIFIED)، فحجز الرقم
-- عليهما دائماً يمنع تصحيحاً مشروعاً لاحقاً (فاتورة رُفضت لمطابقةٍ خاطئة،
-- ثم أُعيد ربط رقمها الصحيح بمشتركٍ آخر). invoice_source يبقى 'MANUAL' من
-- كلا المسارين اليوم (لا مسار ODOO/SAAS/IMPORT فعلي بعد يكتب على هذا
-- الجدول) — فالفهرس يحمي عملياً بالرقم وحده حتى يُضاف مسارٌ آخر، لكن
-- عمود المصدر جزءٌ من مفتاحه من الآن، مطابقاً لقاعدة الملكية المعتمدة، لا
-- إعادة صياغة لاحقاً حين يظهر مصدرٌ ثانٍ فعلي.
--
-- لا صفّ قائم يخالف هذا القيد: القيد الوحيد السابق (subscriber_id,
-- stage_code) يعني صفّاً واحداً VERIFIED لكل مشترك/مرحلة، وrecord فريد لكل
-- منها؛ رقمان مختلفان بالتصادف لمشتركين مختلفين ممكنان نظرياً فقط لو
-- استُخدم نفس الرقم فعلاً، وهو ما لم يكن هذا الفهرس موجوداً ليمنعه أصلاً —
-- فحصٌ عبر البيانات القائمة قبل هذه الهجرة يلزم أولاً في أي بيئة فيها صفوف
-- (محلياً لا صفوف بعد، فالفهرس ينشأ مباشرة).

begin;

create unique index if not exists installation_invoices_verified_identity_key
  on public.installation_invoices (invoice_source, invoice_number)
  where invoice_number is not null and status = 'VERIFIED';

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
  v_number text;
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

  v_number := nullif(btrim(coalesce(p_invoice_number, '')), '');

  -- هوية الفاتورة = المصدر + الرقم. رقمٌ مُدقَّق (VERIFIED) سلفاً لمشتركٍ
  -- آخر (أو حتى لنفس المشترك بمرحلةٍ أخرى) لا يُتاح لفتح مالٍ ثانٍ به —
  -- رسالة واضحة هنا، والفهرس الفريد أدناه هو الحارس الذري ضد السباق بين
  -- هذا الفحص وبين INSERT (نداءان متزامنان بالرقم نفسه لمشتركين مختلفين).
  if p_status = 'VERIFIED' and v_number is not null and exists (
    select 1 from public.installation_invoices ei
    where ei.invoice_number = v_number
      and ei.invoice_source = 'MANUAL'
      and ei.status = 'VERIFIED'
      and not (ei.subscriber_id = v_sid and ei.stage_code = p_stage_code)
  ) then
    raise exception 'Invoice number % is already verified for another subscriber/stage',
      v_number using errcode = '23505';
  end if;

  v_amount := public.installation_amount_for_stage(p_stage_code);

  select status into v_before
  from public.installation_invoices
  where subscriber_id = v_sid and stage_code = p_stage_code;
  v_before := coalesce(v_before, 'NOT_CHECKED');

  -- ذرّي: القيد الفريد (subscriber_id, stage_code) يجعل هذا إدراج-أو-تحديث
  -- واحداً لا نداءان متزامنان ينتجان صفّين لنفس (المشترك، المرحلة)؛ وفهرس
  -- هوية الفاتورة أعلاه يمنع بنفس الذرّية إدراجاً بالرقم نفسه لصفٍّ آخر.
  insert into public.installation_invoices (
    subscriber_id, stage_code, invoice_number, invoice_source, amount, status,
    verified_by, verified_at, rejected_by, rejected_at, rejection_reason, created_by)
  values (
    v_sid, p_stage_code, v_number,
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
      || coalesce(' number=' || v_number, '')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object(
    'subscriber_id', v_sid, 'stage', p_stage_code,
    'status_before', v_before, 'status_after', p_status,
    'amount', v_amount, 'idempotent', false);
end;
$fn$;

revoke execute on function public.review_invoice(text,text,text,text,text,uuid) from public, anon;
grant execute on function public.review_invoice(text,text,text,text,text,uuid) to authenticated;

commit;
