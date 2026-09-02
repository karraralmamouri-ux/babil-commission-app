-- تدقيق QA ما بعد الإطلاق (2026-09-01) — كابينات ٢٧/٦١/٨٧/٩٥ تظهر «بلا
-- تصنيف» رغم أن أرقامها تحسم منطقتها بيقين.
--
-- الجذر: page_unknown_fdts / unknown_fdt_summary / fdt_detail
-- (20260914090000) لا تزال تقرأ «غير مسجَّلة في fdts» على أنها «منطقة غير
-- محسومة» — وهو بالضبط ما أُلغي من محرّك العمولة (20261011090000، تعليق
-- LIVE-02) ومن مسار التنصيب (20261023090000، ZON-005). شاشة ربط الوكلاء
-- (20260922090000) نفسها تنصّ صراحةً: «غير مسجَّلة» ليست «غير مربوطة» — وهو
-- بالضبط الخلط الذي وقعت فيه هذه الشاشة وحدها.
--
-- والإصلاح نفسه، حرفياً: zone تُشتقّ من fdt_commission_scope() دوماً، بلا
-- شرط التسجيل. «غير مسجَّلة في fdts» تبقى إشارة عائديّة (لا وكيل معروف)، لا
-- إشارة منطقة. كابينة ٩٥ نطاقها NEW باليقين نفسه سواء سُجِّلت أم لا —
-- المشكلة الحقيقية فيها عائديّتها، لا منطقتها (طلب #4). لا حدّ 94–119 يتغيّر
-- هنا، ولا register_fdt، ولا عمود fdts.zone نفسه — بيانات تشغيلية منفصلة
-- كما استقرّ في 20261011090000، فقط القراءة كانت الثغرة.

begin;

create or replace function public.page_unknown_fdts(
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
  v_cid uuid; v_start date; v_end date;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  select c.id, c.period_start, c.period_end into v_cid, v_start, v_end
  from public.commission_cycles c order by c.period_start desc limit 1;

  with rates as materialized (
    select r.package_code, r.rate from public.indicative_rates(v_cid) r
  ),
  unknown_codes as (
    select
      e.fdt_code,
      count(*)::bigint as events,
      count(distinct e.username_key)::bigint as subscribers,
      count(distinct e.raw_parent)::bigint as parents,
      min(e.event_created_at) as first_seen,
      max(e.event_created_at) as last_seen,
      -- المبلغ المؤشِّر داخل نافذة الدورة وحدها.
      coalesce(sum(coalesce(rt.rate, 0)) filter (
        where v_cid is not null
          and e.event_created_at >= public.cycle_window_start(v_start)
          and e.event_created_at <  public.cycle_window_end(v_end)), 0)::bigint as indicative_amount
    from public.saas_activation_events e
    left join rates rt on rt.package_code = e.profile_name
    where e.fdt_code is not null and btrim(e.fdt_code) <> ''
      and coalesce(e.canceled, false) = false
      and not exists (select 1 from public.fdts f where f.code = e.fdt_code)
    group by e.fdt_code
  ),
  kept as (
    select * from unknown_codes u
    where p_search is null or btrim(p_search) = '' or u.fdt_code ilike '%' || p_search || '%'
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.*,
        -- المنطقة محسومة بالرقم وحده — راجع fdt_commission_scope. لا علاقة
        -- لتسجيل الكابينة في fdts بهذا الحكم.
        (case when public.fdt_commission_scope(k.fdt_code) = 'FDT' then 'new' else 'old' end) as zone,
        -- أكثر أبٍ ورد مع هذه الكابينة: شاهدٌ يساعد على نسبتها لا حكمٌ.
        (select e2.raw_parent from public.saas_activation_events e2
         where e2.fdt_code = k.fdt_code and e2.raw_parent is not null
         group by e2.raw_parent order by count(*) desc limit 1) as top_parent
      from kept k
      order by k.indicative_amount desc, k.events desc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

create or replace function public.unknown_fdt_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_cid uuid; v_start date; v_end date; v_doc jsonb;
begin
  perform public.require_capability('commission.view');

  select c.id, c.period_start, c.period_end into v_cid, v_start, v_end
  from public.commission_cycles c order by c.period_start desc limit 1;

  with rates as materialized (
    select r.package_code, r.rate from public.indicative_rates(v_cid) r
  ),
  u as (
    select e.fdt_code,
           count(*) as events,
           count(distinct e.username_key) as subs,
           coalesce(sum(coalesce(rt.rate, 0)) filter (
             where v_cid is not null
               and e.event_created_at >= public.cycle_window_start(v_start)
               and e.event_created_at <  public.cycle_window_end(v_end)), 0) as amt,
           (case when public.fdt_commission_scope(e.fdt_code) = 'FDT' then 'new' else 'old' end) as zone
    from public.saas_activation_events e
    left join rates rt on rt.package_code = e.profile_name
    where e.fdt_code is not null and btrim(e.fdt_code) <> ''
      and coalesce(e.canceled, false) = false
      and not exists (select 1 from public.fdts f where f.code = e.fdt_code)
    group by e.fdt_code
  )
  select jsonb_build_object(
    'cabinets', count(*),
    'events', coalesce(sum(events), 0),
    'subscribers', coalesce(sum(subs), 0),
    'indicative_amount', coalesce(sum(amt), 0),
    -- المنطقة محسومة دوماً؛ هذا تقسيمها لا حالة ثالثة «غير محسوم».
    'unknown_old', coalesce(sum(1) filter (where zone = 'old'), 0),
    'unknown_new', coalesce(sum(1) filter (where zone = 'new'), 0),
    'registered', (select count(*) from public.fdts),
    'registered_old', (select count(*) from public.fdts where zone = 'old'),
    'registered_new', (select count(*) from public.fdts where zone = 'new'))
  into v_doc from u;

  return v_doc;
end;
$fn$;

create or replace function public.fdt_detail(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'code', p_code,
    -- المنطقة محسومة بالرقم وحده دوماً — بصرف النظر عن التسجيل. راجع
    -- fdt_commission_scope(). لا تُشتقّ من fdts.zone (بيانات تشغيلية منفصلة
    -- لا تُستخدم للحساب، 20261011090000).
    'zone', case when public.fdt_commission_scope(p_code) = 'FDT' then 'new' else 'old' end,
    'scope_type', public.fdt_commission_scope(p_code),
    -- «مسجَّلة» إشارة عائديّة (وكيل مسنَد) لا إشارة منطقة.
    'registered', exists (select 1 from public.fdts f where f.code = p_code),
    'record', (
      select jsonb_build_object('code', f.code, 'label', f.label, 'zone', f.zone,
        'status', f.status, 'notes', f.notes, 'agent_id', f.agent_id,
        'agent_name', a.official_name, 'created_at', f.created_at, 'updated_at', f.updated_at)
      from public.fdts f left join public.agents a on a.id = f.agent_id
      where f.code = p_code),
    'volume', (
      select jsonb_build_object(
        'events', count(*), 'subscribers', count(distinct e.username_key),
        'first_seen', min(e.event_created_at), 'last_seen', max(e.event_created_at))
      from public.saas_activation_events e
      where e.fdt_code = p_code and coalesce(e.canceled, false) = false),
    -- الآباء الذين وردوا مع هذه الكابينة: شاهد النسبة لا حكمها.
    'parents', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select e.raw_parent as parent_name, count(*) as events,
               count(distinct e.username_key) as subscribers,
               public.parent_ownership_type(e.raw_parent) as ownership
        from public.saas_activation_events e
        where e.fdt_code = p_code and e.raw_parent is not null
          and coalesce(e.canceled, false) = false
        group by e.raw_parent order by count(*) desc limit 10) x), '[]'::jsonb),
    'samples', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select e.username, e.profile_name, e.event_created_at,
               e.raw_parent, e.fat_code, e.port_code, e.source_sheet, e.source_row
        from public.saas_activation_events e
        where e.fdt_code = p_code
        order by e.event_created_at desc limit 10) y), '[]'::jsonb),
    'audit', coalesce((
      select jsonb_agg(to_jsonb(z)) from (
        select l.created_at, l.action, l.old_value, l.new_value, l.extra, u.email as actor_email
        from public.audit_logs l
        left join public.profiles u on u.id = l.actor_id
        where l.action like 'fdt.%' and l.extra like '%' || p_code || '%'
        order by l.created_at desc limit 10) z), '[]'::jsonb))
  where public.has_capability('commission.view');
$fn$;

commit;
