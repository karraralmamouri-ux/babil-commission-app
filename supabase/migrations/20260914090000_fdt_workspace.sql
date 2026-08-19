-- ---------------------------------------------------------------------------
-- الكابينات — الطابور والسجلّ
--
-- التسجيل موجود ويعمل (register_fdt / register_fdt_bulk) ويرفض استنتاج
-- المنطقة: تُذكر صراحةً old أو new وإلّا رُفض. الناقص كان القراءة — لا شاشة
-- تقول أيّ كابينة مجهولة، ولا كم تحجب.
--
-- و«مجهولة» هنا واقعة: رمزٌ ورد في أحداث المصدر ولا صفَّ له في السجلّ. هذه
-- هي الـ119 التي تُحسم فتُطلق 22,724 صفَّ استثناء.
--
-- ولا يُشتقّ شيء من رقم الكابينة. الترقيم لا يحمل معنى المنطقة، واستنتاجه
-- منه يخترع تصنيفاً مالياً من محارف.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. طابور الكابينات المجهولة
-- ---------------------------------------------------------------------------

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

revoke execute on function public.page_unknown_fdts(text,integer,integer) from public, anon;
grant execute on function public.page_unknown_fdts(text,integer,integer) to authenticated;

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
               and e.event_created_at <  public.cycle_window_end(v_end)), 0) as amt
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
    'registered', (select count(*) from public.fdts),
    'registered_old', (select count(*) from public.fdts where zone = 'old'),
    'registered_new', (select count(*) from public.fdts where zone = 'new'))
  into v_doc from u;

  return v_doc;
end;
$fn$;

revoke execute on function public.unknown_fdt_summary() from public, anon;
grant execute on function public.unknown_fdt_summary() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. سجلّ الكابينات المعرَّفة
-- ---------------------------------------------------------------------------

create or replace function public.page_fdts(
  p_zone text default null,
  p_status text default null,
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
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select f.code, f.label, f.zone, f.status, f.notes,
           f.agent_id, a.official_name as agent_name, a.code as agent_code,
           f.created_at, f.updated_at,
           (select count(*) from public.saas_activation_events e
            where e.fdt_code = f.code and coalesce(e.canceled, false) = false) as events,
           (select count(distinct e.username_key) from public.saas_activation_events e
            where e.fdt_code = f.code and coalesce(e.canceled, false) = false) as subscribers
    from public.fdts f
    left join public.agents a on a.id = f.agent_id
    where (p_zone is null or f.zone = p_zone)
      and (p_status is null or f.status = p_status)
      and (p_search is null or btrim(p_search) = ''
           or f.code ilike '%' || p_search || '%'
           or f.label ilike '%' || p_search || '%'
           or a.official_name ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.code
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_fdts(text,text,text,integer,integer) from public, anon;
grant execute on function public.page_fdts(text,text,text,integer,integer) to authenticated;

-- تفصيل كابينة: شواهدها وتاريخ قراراتها.
create or replace function public.fdt_detail(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'code', p_code,
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

revoke execute on function public.fdt_detail(text) from public, anon;
grant execute on function public.fdt_detail(text) to authenticated;

create index if not exists saas_events_fdt_idx
  on public.saas_activation_events (fdt_code) where fdt_code is not null;

commit;
