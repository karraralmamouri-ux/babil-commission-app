-- صدفة الصفحة، وخطّ زمني بلا سقف صامت.
--
-- عيبان في عقد القراءة، كلاهما يكذب بصمت:
--
-- 1. الإجمالي كان يُحمَل في كل صفّ عبر count(*) over (). وحين تقع الإزاحة
--    خارج المدى لا تعود صفوف أصلاً، فلا يعود إجمالي كذلك — فتقرأ الشاشة
--    «صفر» بينما المجموعة فيها 22,727 صفاً. الرقم يختفي لأن الصفحة فارغة،
--    وهذا أسوأ من خطأ ظاهر: يبدو جواباً صحيحاً.
--
--    الحلّ: صدفة jsonb تحمل rows وtotal وlimit وoffset ومدى الصفحة، ويُحسب
--    الإجمالي في استعلامه المستقلّ فلا يعتمد على وجود صفوف.
--
-- 2. subscriber_timeline كان ينتهي بـ limit 300 ثابت. مشترك بتاريخ أطول
--    يفقد أقدمه بلا إشارة — والتاريخ الذي لا يُعرَف نقصُه لا يُوثق به.
--
--    الحلّ: تصفيح صريح بإجمالي، ولا سقف مخفيّ.
--
-- كل ما هنا للقراءة. لا جدول، ولا قاعدة مالية، ولا تغيير في أي رقم.

begin;

-- ---------------------------------------------------------------------------
-- 1. صدفة موحَّدة
-- ---------------------------------------------------------------------------

create or replace function public.page_envelope(
  p_rows jsonb, p_total bigint, p_limit integer, p_offset integer)
returns jsonb language sql immutable set search_path = ''
as $fn$
  select jsonb_build_object(
    'rows', coalesce(p_rows, '[]'::jsonb),
    'total', p_total,
    'limit', p_limit,
    'offset', p_offset,
    'returned', jsonb_array_length(coalesce(p_rows, '[]'::jsonb)),
    -- الإزاحة خارج المدى ليست خطأً بل صفحة فارغة، والإجمالي يبقى صادقاً.
    'out_of_range', (p_total > 0 and p_offset >= p_total)
  );
$fn$;

grant execute on function public.page_envelope(jsonb, bigint, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. سجل المشتركين — صدفة
-- ---------------------------------------------------------------------------

create or replace function public.page_installation_subscribers(
  p_search text default null, p_agent text default null, p_fdt text default null,
  p_zone text default null, p_stage text default null, p_status text default null,
  p_has_hold boolean default null, p_ownership text default null,
  p_limit integer default 50, p_offset integer default 0, p_sort text default 'subscriber_id'
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select
      s.subscriber_id as sid, s.id as suuid, s.reseller as res, s.fdt as fdtc,
      e.zone as zn,
      coalesce(e.current_stage_code, 'UNKNOWN') as stage,
      coalesce(e.status, 'UNENROLLED') as est,
      public.subscriber_ownership_type(s.subscriber_id) as own,
      coalesce((select sum(h.amount)::bigint from public.installation_payment_history h
                where h.subscriber_uuid = s.id), 0) as paid,
      coalesce((select count(*)::integer from public.installation_payment_history h
                where h.subscriber_uuid = s.id), 0) as pcount,
      coalesce((select count(*)::integer from public.installation_holds ih
                where ih.subscriber_id = s.subscriber_id and ih.status = 'ACTIVE'), 0) as hcount,
      s.start_date as sdate
    from public.installation_subscribers s
    left join public.installation_enrollments e on e.subscriber_id = s.subscriber_id
    where (p_search is null or s.subscriber_id ilike '%' || p_search || '%'
           or s.reseller ilike '%' || p_search || '%')
      and (p_agent is null or s.reseller = p_agent)
      and (p_fdt   is null or s.fdt = p_fdt)
      and (p_zone  is null or e.zone = p_zone)
      and (p_stage is null or coalesce(e.current_stage_code, 'UNKNOWN') = p_stage)
      and (p_status is null or coalesce(e.status, 'UNENROLLED') = p_status)
  ),
  kept as (
    select * from base b
    where (p_has_hold is null or (p_has_hold and b.hcount > 0) or (not p_has_hold and b.hcount = 0))
      and (p_ownership is null or b.own = p_ownership)
  )
  -- الإجمالي يُحسب على المجموعة كلها، فلا تُخفيه صفحةٌ فارغة.
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.sid as subscriber_id, k.suuid as subscriber_uuid, k.res as reseller,
             k.fdtc as fdt, k.zn as zone, k.stage as stage_code, k.est as enrollment_status,
             k.own as ownership_type, k.paid as paid_total, k.pcount as payment_count,
             k.hcount as hold_count, k.sdate as start_date
      from kept k
      order by case when p_sort = 'paid_desc' then k.paid end desc nulls last,
               case when p_sort = 'stage' then k.stage end asc nulls last,
               k.sid asc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_installation_subscribers(text,text,text,text,text,text,boolean,text,integer,integer,text) from public, anon;
grant execute on function public.page_installation_subscribers(text,text,text,text,text,text,boolean,text,integer,integer,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. طابور الاستثناءات — صدفة
-- ---------------------------------------------------------------------------

create or replace function public.page_commission_exceptions(
  p_cycle_id uuid default null, p_reason text default null,
  p_blocking boolean default null, p_status text default 'OPEN',
  p_search text default null, p_limit integer default 50, p_offset integer default 0
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  select count(*) into v_total
  from public.commission_exceptions x
  left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
  where (p_cycle_id is null or x.cycle_id = p_cycle_id)
    and (p_reason is null or x.reason_code = p_reason)
    and (p_status is null or x.status = p_status)
    and (p_blocking is null or x.blocks_finalization = p_blocking)
    and (p_search is null or x.activation_event_id ilike '%' || p_search || '%'
         or x.subscriber_key ilike '%' || p_search || '%'
         or e.fdt_code ilike '%' || p_search || '%');

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_rows from (
    select xx.id, xx.cycle_id, xx.activation_event_id, xx.subscriber_key,
           xx.reason_code, xx.detail, xx.blocks_finalization, xx.status, xx.created_at,
           e.fdt_code, e.raw_parent, e.profile_name as package_code,
           coalesce(public.commission_rate_for(
             public.commission_version_for_cycle(xx.cycle_id), 'new', 1, e.profile_name), 0)::bigint
             as indicative_amount
    from public.commission_exceptions xx
    left join public.saas_activation_events e on e.saas_event_id = xx.activation_event_id
    where (p_cycle_id is null or xx.cycle_id = p_cycle_id)
      and (p_reason is null or xx.reason_code = p_reason)
      and (p_status is null or xx.status = p_status)
      and (p_blocking is null or xx.blocks_finalization = p_blocking)
      and (p_search is null or xx.activation_event_id ilike '%' || p_search || '%'
           or xx.subscriber_key ilike '%' || p_search || '%'
           or e.fdt_code ilike '%' || p_search || '%')
    order by xx.blocks_finalization desc, xx.created_at desc
    limit v_lim offset v_off) x;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_commission_exceptions(uuid,text,boolean,text,text,integer,integer) from public, anon;
grant execute on function public.page_commission_exceptions(uuid,text,boolean,text,text,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. الخطّ الزمني — بلا سقف صامت
-- ---------------------------------------------------------------------------

create or replace function public.page_subscriber_timeline(
  p_subscriber_id text, p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with sub as (select s.id as sid, s.subscriber_id as scode, s.subscriber_key as skey
               from public.installation_subscribers s where s.subscriber_id = p_subscriber_id),
  events as (
    select h.payment_date::timestamptz as occurred_at, 'PAYMENT'::text as kind,
           ('دفعة ' || h.stage)::text as title, 'دفعة تنصيب مسجَّلة'::text as detail,
           h.amount::bigint as amount
    from public.installation_payment_history h join sub on sub.sid = h.subscriber_uuid
    union all
    select e.event_created_at, 'ACTIVATION',
           ('تفعيل ' || coalesce(e.profile_name, '—'))::text,
           coalesce('الأب: ' || e.raw_parent, '')::text, null::bigint
    from public.saas_activation_events e join sub on sub.skey = e.username_key
    where coalesce(e.canceled, false) = false
    union all
    select hd.created_at, 'HOLD', ('إيقاف — ' || hd.reason_code)::text,
           coalesce(hd.note, '')::text, null::bigint
    from public.installation_holds hd join sub on sub.scode = hd.subscriber_id
    union all
    select i.created_at, 'INVOICE',
           ('فاتورة ' || coalesce(i.invoice_number, '—'))::text, i.status::text, i.amount::bigint
    from public.installation_invoices i join sub on sub.scode = i.subscriber_id
    union all
    select a.created_at, 'AUDIT', a.action::text, coalesce(a.field, '')::text, null::bigint
    from public.audit_logs a join sub on a.entity_id = sub.sid
  )
  -- لا سقف مخفيّ: الإجمالي كامل، والصفحة صريحة.
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select * from events order by occurred_at desc limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from events;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_subscriber_timeline(text,integer,integer) from public, anon;
grant execute on function public.page_subscriber_timeline(text,integer,integer) to authenticated;

commit;
