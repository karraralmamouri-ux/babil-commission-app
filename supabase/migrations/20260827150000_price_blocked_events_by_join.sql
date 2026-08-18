-- تسعير المحجوب بالانضمام لا بنداء لكل صف.
--
-- بعد إصلاح سياسات الصفوف بقي تقرير أثر الاستثناءات عند 7,920 مللي ثانية،
-- وBuffers: shared hit=290,354. المسح ليس الجاني: الدالة تستدعي لكل صف من
-- 22,724 صفاً نداءين STABLE — commission_version_for_cycle ثم
-- commission_rate_for — وكلاهما يقرأ جداول التهيئة من جديد.
--
-- والحقيقة أن النسخة ثابتة للدورة كلها، والأسعار ثلاثة صفوف لا غير (عدد
-- الباقات). فالحساب الصحيح: تُحلّ النسخة مرة، ويُبنى جدول سعرٍ صغير مرة،
-- ثم يُنضَمّ إليه. اثنان وعشرون ألف نداء يصيران انضماماً واحداً.
--
-- لا قاعدة عمل تتغيّر: السعر نفسه من الشريحة الأولى نفسها، والرقم يبقى
-- indicative — مؤشِّر حجم لا التزاماً، لأن الشريحة الحقيقية لا تُعرف قبل أن
-- يُحسَم سبب الحجب.
--
-- forward-only. لا صف بيانات يُمَس.

begin;

-- ---------------------------------------------------------------------------
-- جدول السعر المؤشِّر لنسخة مخطَّط: صفٌّ لكل باقة، يُبنى مرة ويُنضَمّ إليه.
-- ---------------------------------------------------------------------------

create or replace function public.indicative_rates(p_cycle_id uuid)
returns table (package_code text, rate bigint)
language sql
stable
set search_path = ''
as $fn$
  select p.code,
         coalesce(public.commission_rate_for(
           public.commission_version_for_cycle(p_cycle_id), 'new', 1, p.code), 0)::bigint
  from public.packages p;
$fn$;

grant execute on function public.indicative_rates(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- أثر الاستثناءات
-- ---------------------------------------------------------------------------

create or replace function public.report_commission_exception_impact(p_cycle_id uuid)
returns table (
  reason_code text,
  blocking boolean,
  open_rows integer,
  blocked_events integer,
  blocked_subscribers integer,
  indicative_amount bigint
)
language sql
stable
security definer
set search_path = ''
as $fn$
  with rates as materialized (
    select r.package_code, r.rate from public.indicative_rates(p_cycle_id) r
  )
  select
    x.reason_code,
    bool_or(x.blocks_finalization),
    count(*)::integer,
    count(distinct x.activation_event_id)::integer,
    count(distinct x.subscriber_key)::integer,
    coalesce(sum(coalesce(rt.rate, 0)), 0)::bigint
  from public.commission_exceptions x
  left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
  left join rates rt on rt.package_code = e.profile_name
  where x.cycle_id = p_cycle_id
    and x.status = 'OPEN'
    and public.has_capability('report.view')
  group by x.reason_code
  order by 6 desc, 3 desc;
$fn$;

revoke execute on function public.report_commission_exception_impact(uuid) from public, anon;
grant execute on function public.report_commission_exception_impact(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- المبلغ المحجوب بكابينة — النافذة نفسها، والسعر بالانضمام
--
-- تُستدعى مرة لكل كابينة في شاشة الإدخال، فتكلفتها تُضرَب في 119.
-- ---------------------------------------------------------------------------

create or replace function public.fdt_blocked_amount(p_cycle_id uuid, p_fdt_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with rates as materialized (
    select r.package_code, r.rate from public.indicative_rates(p_cycle_id) r
  )
  select jsonb_build_object(
    'fdt_code', p_fdt_code,
    'blocked_events', count(*),
    'blocked_subscribers', count(distinct e.username_key),
    'indicative_amount', coalesce(sum(coalesce(rt.rate, 0)), 0)
  )
  from public.saas_activation_events e
  join public.commission_cycles c on c.id = p_cycle_id
  left join public.fdts f on f.code = e.fdt_code
  left join rates rt on rt.package_code = e.profile_name
  where e.fdt_code = p_fdt_code
    and f.code is null
    and coalesce(e.canceled, false) = false
    and e.event_created_at >= public.cycle_window_start(c.period_start)
    and e.event_created_at < public.cycle_window_end(c.period_end);
$fn$;

revoke execute on function public.fdt_blocked_amount(uuid, text) from public, anon;
grant execute on function public.fdt_blocked_amount(uuid, text) to authenticated;

-- الاستثناء يُقرأ بالدورة والحالة معاً في كل شاشة؛ الفهرس يتبع القراءة.
create index if not exists commission_exceptions_cycle_status_idx
  on public.commission_exceptions (cycle_id, status);

commit;
