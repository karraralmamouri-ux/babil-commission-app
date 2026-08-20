-- ---------------------------------------------------------------------------
-- عدّ الكابينة: تفعيلات الدورة لا مجموع التاريخ
--
-- `page_fdt_mapping` و`page_fdts` و`fdt_detail` كانت تعدّ
-- `saas_activation_events` بلا نافذة زمنية، وتعرض الناتج في شاشةٍ تشغيلية
-- إلى جانب أرقام الدورة. فيُقرأ الرقم على أنه تفعيلات الشهر وهو مجموع كل
-- ما وصل.
--
-- واليوم لا يظهر الفرق: 28,233 حدثاً من أيار وحزيران لا تحمل رمز كابينة،
-- فيتساوى المجموع مع نافذة تموز في كل كابينة مسجَّلة. العيب كامنٌ لا
-- عامل — ويستيقظ أوّل ما يصل ملفُّ آب، أو أوّل ما تُنسب تلك الأحداث إلى
-- كابيناتها.
--
-- والعدّ الجديد لا يُعيد اشتقاق «المؤهَّل»: يقرأ ما أنتجه المحرّك فعلاً
-- (`commission_event_entitlements`). صيغتان للتأهيل تتباعدان يوماً ما،
-- وقراءةُ ناتج المحرّك لا تتباعد عنه بحكم التعريف — وتشمل تصحيحات
-- التفعيلات دون أن يعرف هذا الملفّ بوجودها.
-- ---------------------------------------------------------------------------

begin;

/** الدورة المقصودة: المطلوبة، وإلا أحدث دورة. */
create or replace function public.current_commission_cycle_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select id from public.commission_cycles order by period_start desc limit 1;
$fn$;

revoke execute on function public.current_commission_cycle_id() from public, anon;
grant execute on function public.current_commission_cycle_id() to authenticated;

-- التوقيع القديم يُزال قبل الجديد.
--
-- إضافة معاملٍ جديد لا تستبدل الدالّة بل تُنشئ حِملاً ثانياً لها، فيصير
-- النداء بستّة معاملات غامضاً بين توقيعين — وPostgREST يردّ عندها بخطأ
-- لا بنتيجة. فالقديم يُسقَط صراحةً في المعاملة نفسها.
drop function if exists public.page_fdt_mapping(text,text,text,boolean,integer,integer);

create or replace function public.page_fdt_mapping(
  p_search text default null,
  p_agent text default null,
  p_zone text default null,
  p_mapped boolean default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_cycle_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer; v_cycle uuid;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);
  v_cycle := coalesce(p_cycle_id, public.current_commission_cycle_id());

  with cycle_counts as (
    select x.scope_id as code,
           count(*)::bigint as cycle_events,
           count(distinct x.subscriber_key)::bigint as cycle_subscribers
    from public.commission_event_entitlements x
    where x.cycle_id = v_cycle and x.scope_type = 'FDT'
    group by x.scope_id
  ),
  kept as (
    select f.code, f.label, f.zone, f.status, f.notes,
           f.agent_id, a.code as agent_code, a.official_name as agent_name,
           a.status as agent_status,
           coalesce(c.cycle_events, 0) as cycle_events,
           coalesce(c.cycle_subscribers, 0) as cycle_subscribers,
           -- المجموع التاريخي يبقى معروضاً، لكن باسمه.
           (select count(*) from public.saas_activation_events e
            where e.fdt_code = f.code) as lifetime_events
    from public.fdts f
    left join public.agents a on a.id = f.agent_id
    left join cycle_counts c on c.code = f.code
    where (p_zone is null or f.zone = p_zone)
      and (p_mapped is null
           or (p_mapped and f.agent_id is not null)
           or (not p_mapped and f.agent_id is null))
      and (p_agent is null or btrim(p_agent) = ''
           or a.code ilike '%' || p_agent || '%'
           or a.official_name ilike '%' || p_agent || '%')
      and (p_search is null or btrim(p_search) = ''
           or f.code ilike '%' || p_search || '%'
           or f.label ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k
      order by (k.agent_id is not null), k.cycle_events desc, k.code
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off)
    || jsonb_build_object('cycle_id', v_cycle);
end;
$fn$;

revoke execute on function public.page_fdt_mapping(
  text,text,text,boolean,integer,integer,uuid) from public, anon;
grant execute on function public.page_fdt_mapping(
  text,text,text,boolean,integer,integer,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- تفصيل الكابينة: الأحداث التي صنعت الرقم، لا الرقم وحده
--
-- «41» لا تُراجَع بوصفها رقماً. فتُعرض الأحداث التي أنتجتها، كلٌّ بمشتركه
-- وباقته ووقته وصفّه في الملفّ المصدر — ومعها ما استُبعد وما أُضيف.
-- ---------------------------------------------------------------------------

create or replace function public.fdt_cycle_events(
  p_code text,
  p_cycle_id uuid default null,
  p_limit integer default 200,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer; v_cycle uuid;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);
  v_cycle := coalesce(p_cycle_id, public.current_commission_cycle_id());

  with kept as (
    select x.activation_event_id, x.subscriber_key, x.package_code, x.tier_code,
           x.amount, x.event_at, x.agent_name, x.raw_parent,
           (x.activation_event_id like 'MANUAL-%') as manual,
           e.username, e.source_sheet, e.source_row, e.transaction_id,
           b.source_filename
    from public.commission_event_entitlements x
    left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    left join public.saas_import_batches b on b.id = e.import_batch_id
    where x.cycle_id = v_cycle and x.scope_type = 'FDT' and x.scope_id = p_code
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.event_at
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off)
    || jsonb_build_object(
      'cycle_id', v_cycle,
      'code', p_code,
      'unique_subscribers', (
        select count(distinct subscriber_key) from public.commission_event_entitlements
        where cycle_id = v_cycle and scope_type = 'FDT' and scope_id = p_code),
      'lifetime_events', (
        select count(*) from public.saas_activation_events where fdt_code = p_code),
      'corrections', (
        select count(*) from public.activation_corrections
        where cycle_id = v_cycle and status = 'ACTIVE'
          and (fdt_code = p_code
               or source_event_id in (
                 select saas_event_id from public.saas_activation_events
                 where fdt_code = p_code))));
end;
$fn$;

revoke execute on function public.fdt_cycle_events(text,uuid,integer,integer)
  from public, anon;
grant execute on function public.fdt_cycle_events(text,uuid,integer,integer)
  to authenticated;

commit;
