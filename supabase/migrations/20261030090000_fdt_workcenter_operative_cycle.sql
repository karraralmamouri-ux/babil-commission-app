-- Codex review of PR #95: page_unknown_fdts / unknown_fdt_summary
-- (20261026090000) select their cycle window with a bare
-- "order by period_start desc limit 1" — the exact naive-newest-cycle
-- pattern that 20260929090000 already banned everywhere else, including a
-- CANCELLED cycle if it happens to be the newest by period_start. That
-- misattributes the indicative-amount window (and every other screen using
-- current_commission_cycle_id() disagrees with these two about which cycle
-- is "current"). Route both through current_commission_cycle_id() instead
-- of duplicating "latest cycle" logic; when no cycle is operative, fall
-- back to no window (v_cid null) exactly like indicative_rates(null)
-- already handles it — the cabinet listing itself is cycle-independent
-- (it just loses its indicative-amount context, mirroring current_unknown_
-- fdt_decisions' own null-cycle behaviour). fdt_detail is untouched: it
-- never selected a cycle in the first place.
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

  v_cid := public.current_commission_cycle_id();
  select c.period_start, c.period_end into v_start, v_end
  from public.commission_cycles c where c.id = v_cid;

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
      -- المبلغ المؤشِّر داخل نافذة الدورة العاملة وحدها؛ بلا دورةٍ عاملة لا
      -- نافذة له (صفر)، لا نافذة أحدث دورةٍ ولو ملغاة.
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

  return public.page_envelope(v_rows, v_total, v_lim, v_off) || jsonb_build_object('cycle_id', v_cid);
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

  v_cid := public.current_commission_cycle_id();
  select c.period_start, c.period_end into v_start, v_end
  from public.commission_cycles c where c.id = v_cid;

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

  return v_doc || jsonb_build_object('cycle_id', v_cid);
end;
$fn$;

commit;
