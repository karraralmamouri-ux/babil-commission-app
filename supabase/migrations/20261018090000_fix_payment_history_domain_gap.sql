-- LIVE-04 / ARC-001: تقرير الدفعات كان يقتصر على domain='installation'، بينما
-- archive_overview().totals.ledger_entries يعدّ كل النطاقات بلا تمييز
-- (supabase/migrations/20260915090000_imports_reports_archive.sql:322). مذ
-- صار لدى العمولات مسارها الخاص (commission_payment_batches/_items، ثم قيود
-- التصحيح/العكس المضافة في c96d8a2/cd4e939)، صار KPI "قيود الدفتر" يعرض عدداً
-- لا يستطيع رابط التفصيل نفسه بلوغه أبداً — لا شاشة أخرى تسرد صفوف العمولة
-- (docs/engineering/risk-and-open-decisions.md:68-71 يؤكد: لا شيء غير
-- الملخصات المجمّعة موجود لنطاق العمولة). هذا سهو، لا قرار: لا تعليق في
-- الهجرة الأصلية يبرّر التقييد، ولا تقرير بديل يغطي صفوف العمولة الفردية.
--
-- الإصلاح: توسيع الأساس (base) ليشمل الاتحاد مع نطاق العمولة، بربط كل صف
-- بدفعته عبر commission_payment_batch_items.ledger_entry_id — إشارة مباشرة
-- ١:١ للقيد (يوجَد فقط بعد الدفع فعلياً، بحكم قيد
-- commission_payment_batch_items_paid_has_ledger)، بلا حاجة لمطابقة عبر
-- entitlement_id كما يفعل فرع التنصيب. فرع التنصيب بقي بلا تغيير حرفياً.

begin;

create or replace function public.report_payment_history(
  p_from date default null,
  p_to date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_sum jsonb; v_lim integer; v_off integer;
begin
  perform public.require_capability('report.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select l.id, l.created_at, l.subscriber_id, l.agent_name, l.stage,
           l.amount, l.month_key, l.txn_type, l.direction, l.source_origin,
           b.name as batch_name, b.payment_ref, b.payment_date
    from public.financial_ledger l
    left join public.installation_payments ip on ip.entitlement_id = l.source_id
    left join public.installation_payment_batch_items bi on bi.entitlement_id = l.source_id
    left join public.installation_payment_batches b on b.id = bi.batch_id
    where l.domain = 'installation'
      and (p_from is null or l.created_at >= p_from)
      and (p_to is null or l.created_at < (p_to + 1))
    union all
    select l.id, l.created_at, l.subscriber_id, l.agent_name, l.stage,
           l.amount, l.month_key, l.txn_type, l.direction, l.source_origin,
           cb.name as batch_name, cb.payment_reference as payment_ref,
           cb.posted_at::date as payment_date
    from public.financial_ledger l
    left join public.commission_payment_batch_items cbi on cbi.ledger_entry_id = l.id
    left join public.commission_payment_batches cb on cb.id = cbi.batch_id
    where l.domain = 'commission'
      and (p_from is null or l.created_at >= p_from)
      and (p_to is null or l.created_at < (p_to + 1))
  )
  select count(*),
    jsonb_build_object(
      'entries', count(*),
      'total_amount', coalesce(sum(amount * direction), 0),
      'payments', count(*) filter (where txn_type = 'PAYMENT'),
      'reversals', count(*) filter (where txn_type = 'REVERSAL'),
      'adjustments', count(*) filter (where txn_type = 'ADJUSTMENT')),
    coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select b.* from base b order by b.created_at desc
        limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_sum, v_rows
  from base;

  return jsonb_build_object(
    'summary', v_sum,
    'page', public.page_envelope(v_rows, v_total, v_lim, v_off));
end;
$fn$;

commit;
