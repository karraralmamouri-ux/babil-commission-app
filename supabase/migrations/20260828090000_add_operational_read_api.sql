-- واجهة القراءة التشغيلية.
--
-- الشاشات الجديدة تحتاج قوائم مُصفّحة وملفات سجلّ. الموجود اليوم يقرأ بحدٍّ
-- أعلى ثابت: طابور الاستثناءات يقرأ 300 صفاً من 22,727 — أي 1.3% من العمل،
-- بلا صفحة تالية وبلا إجمالي. والحدّ لم يُختَر مقاسَ صفحة بل صمّامَ أمان.
--
-- كل ما هنا للقراءة فقط:
--   • لا جدول جديد. كل رقم يأتي من مصدره المعتمد.
--   • لا قاعدة مالية جديدة ولا إعادة تسعير: الدوال تعرض ما حسبه المحرّك.
--   • كل دالة تفحص القدرة صراحةً، فلا تصير باب التفافٍ على RLS.
--   • كل قائمة تُعيد total_count مع صفحتها، فالشاشة تعرف حدّها وتقوله.
--
-- SECURITY DEFINER هنا ضرورة لا اختصار: الدوال تجمع من جداول تحكمها سياسات
-- مختلفة (بعضها للمدير وحده)، فتُفحص القدرة داخل الدالة بدل الاتّكال على
-- تقاطع السياسات — والنتيجة أضيق لا أوسع.
--
-- والحارس في plpgsql لا في CTE. أوّل صياغة وضعته في
--     with allowed as (select public.require_capability(...) is null as ok)
-- فمرّت القائمة بلا فحص: المخطِّط يُسقط CTE لا يُستعمل مخرَجه، فيختفي الفحص
-- صامتاً ويعود الصفّ لمن لا يملكه. حارسٌ يجوز للمخطِّط تخطّيه ليس حارساً،
-- و perform في أوّل الجسد يُنفَّذ دائماً.

begin;

-- ---------------------------------------------------------------------------
-- 1. حدود الصفحة
--
-- الحدّ الأقصى 200: صفحة أكبر تعني نقل عشرات الآلاف من الصفوف إلى المتصفح،
-- وهو بالضبط ما نخرج منه.
-- ---------------------------------------------------------------------------

create or replace function public.page_limit(p_limit integer)
returns integer language sql immutable set search_path = ''
as $fn$ select least(greatest(coalesce(p_limit, 50), 1), 200) $fn$;

create or replace function public.page_offset(p_offset integer)
returns integer language sql immutable set search_path = ''
as $fn$ select greatest(coalesce(p_offset, 0), 0) $fn$;

grant execute on function public.page_limit(integer) to authenticated;
grant execute on function public.page_offset(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. سجل المشتركين — مُصفّح ومُصفّى على الخادم
-- ---------------------------------------------------------------------------

create or replace function public.list_installation_subscribers(
  p_search text default null,
  p_agent text default null,
  p_fdt text default null,
  p_zone text default null,
  p_stage text default null,
  p_status text default null,
  p_has_hold boolean default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_sort text default 'subscriber_id'
)
returns table (
  subscriber_id text, subscriber_uuid uuid, reseller text, fdt text, zone text,
  stage_code text, enrollment_status text, paid_total bigint,
  payment_count integer, hold_count integer, start_date date, total_count bigint
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('installation.view');
  return query
  with base as (
    select
      s.subscriber_id as sid, s.id as suuid, s.reseller as res, s.fdt as fdtc,
      e.zone as zn,
      coalesce(e.current_stage_code, 'UNKNOWN') as stage,
      coalesce(e.status, 'UNENROLLED') as est,
      coalesce((select sum(h.amount)::bigint from public.installation_payment_history h
                where h.subscriber_uuid = s.id), 0) as paid,
      coalesce((select count(*)::integer from public.installation_payment_history h
                where h.subscriber_uuid = s.id), 0) as pcount,
      coalesce((select count(*)::integer from public.installation_holds ih
                where ih.subscriber_id = s.subscriber_id and ih.status = 'ACTIVE'), 0) as hcount,
      s.start_date as sdate
    from public.installation_subscribers s
    left join public.installation_enrollments e on e.subscriber_id = s.subscriber_id
  ),
  filtered as (
    select * from base b
    where (p_search is null or b.sid ilike '%' || p_search || '%')
      and (p_agent  is null or b.res = p_agent)
      and (p_fdt    is null or b.fdtc = p_fdt)
      and (p_zone   is null or b.zn = p_zone)
      and (p_stage  is null or b.stage = p_stage)
      and (p_status is null or b.est = p_status)
      and (p_has_hold is null
           or (p_has_hold and b.hcount > 0)
           or (not p_has_hold and b.hcount = 0))
  )
  select f.sid, f.suuid, f.res, f.fdtc, f.zn, f.stage, f.est, f.paid,
         f.pcount, f.hcount, f.sdate, count(*) over ()
  from filtered f
  order by
    case when p_sort = 'paid_desc' then f.paid end desc nulls last,
    case when p_sort = 'stage' then f.stage end asc nulls last,
    f.sid asc
  limit public.page_limit(p_limit) offset public.page_offset(p_offset);
end;
$fn$;

revoke execute on function public.list_installation_subscribers(text,text,text,text,text,text,boolean,integer,integer,text) from public, anon;
grant execute on function public.list_installation_subscribers(text,text,text,text,text,text,boolean,integer,integer,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. ملفّ المشترك — وثيقة واحدة
--
-- تجميعه في المتصفح يعني ستّ رحلات لكل صفّ. يُجمَّع هنا مرة.
-- ---------------------------------------------------------------------------

create or replace function public.installation_subscriber_case(p_subscriber_id text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v jsonb;
begin
  perform public.require_capability('installation.view');
  select jsonb_build_object(
    'subscriber', (select jsonb_build_object(
        'subscriber_id', s.subscriber_id, 'uuid', s.id, 'reseller', s.reseller,
        'fdt', s.fdt, 'start_date', s.start_date, 'notes', s.notes)
      from public.installation_subscribers s where s.subscriber_id = p_subscriber_id),
    'enrollment', (select jsonb_build_object(
        'stage', e.current_stage_code, 'status', e.status, 'zone', e.zone,
        'origin', e.origin, 'fdt_code', e.fdt_code,
        'agent_name', e.agent_name_at_enrollment,
        'effective_agent_id', e.effective_agent_id,
        'scheme_version_id', e.scheme_version_id, 'enrolled_at', e.enrolled_at)
      from public.installation_enrollments e where e.subscriber_id = p_subscriber_id),
    'identity', (select jsonb_build_object(
        'saas_user_id', si.saas_user_id, 'identity_status', si.identity_status,
        'match_method', si.match_method, 'source_classification', si.source_classification,
        'effective_agent_id', si.effective_agent_id)
      from public.subscriber_identities si
      join public.installation_subscribers s2 on s2.id = si.installation_subscriber_id
      where s2.subscriber_id = p_subscriber_id limit 1),
    'entitlements', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'period', t.period, 'stage', t.stage, 'amount', t.amount,
        'remaining', t.remaining, 'invoice_status', t.invoice_status,
        'payment_status', t.payment_status, 'paid_amount', t.paid_amount,
        'paid_at', t.paid_at) order by t.period desc)
      from public.installation_entitlements t where t.subscriber_id = p_subscriber_id), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object(
        'id', i.id, 'stage', i.stage_code, 'number', i.invoice_number,
        'amount', i.amount, 'status', i.status, 'invoice_date', i.invoice_date,
        'source', i.invoice_source) order by i.created_at desc)
      from public.installation_invoices i where i.subscriber_id = p_subscriber_id), '[]'::jsonb),
    'holds', coalesce((select jsonb_agg(jsonb_build_object(
        'id', h.id, 'stage', h.stage_code, 'reason', h.reason_code,
        'type', h.hold_type, 'status', h.status, 'note', h.note,
        'created_at', h.created_at, 'released_at', h.released_at) order by h.created_at desc)
      from public.installation_holds h where h.subscriber_id = p_subscriber_id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', ph.id, 'stage', ph.stage, 'amount', ph.amount,
        'payment_date', ph.payment_date) order by ph.payment_date desc, ph.stage)
      from public.installation_payment_history ph
      join public.installation_subscribers s3 on s3.id = ph.subscriber_uuid
      where s3.subscriber_id = p_subscriber_id), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'paid', coalesce(sum(ph.amount), 0), 'payment_count', count(*))
      from public.installation_payment_history ph
      join public.installation_subscribers s4 on s4.id = ph.subscriber_uuid
      where s4.subscriber_id = p_subscriber_id)
  ) into v;
  return v;
end;
$fn$;

revoke execute on function public.installation_subscriber_case(text) from public, anon;
grant execute on function public.installation_subscriber_case(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. الخطّ الزمني — مُشتَقّ لا مُخزَّن
--
-- نسخة مخزَّنة من التاريخ تصير حقيقةً ثانية تنحرف عن الدفتر. يُبنى عند القراءة
-- من المصادر المعتمدة وحدها.
-- ---------------------------------------------------------------------------

create or replace function public.subscriber_timeline(p_subscriber_id text)
returns table (occurred_at timestamptz, kind text, title text, detail text, amount bigint)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('installation.view');
  return query
  with sub as (select s.id as sid, s.subscriber_id as scode, s.subscriber_key as skey
               from public.installation_subscribers s where s.subscriber_id = p_subscriber_id)
  select h.payment_date::timestamptz, 'PAYMENT'::text,
         ('دفعة ' || h.stage)::text, 'دفعة تنصيب مسجَّلة'::text, h.amount::bigint
  from public.installation_payment_history h join sub on sub.sid = h.subscriber_uuid
  union all
  select e.event_created_at, 'ACTIVATION'::text,
         ('تفعيل ' || coalesce(e.profile_name, '—'))::text,
         coalesce('الأب: ' || e.raw_parent, '')::text, null::bigint
  from public.saas_activation_events e join sub on sub.skey = e.username_key
  where coalesce(e.canceled, false) = false
  union all
  select hd.created_at, 'HOLD'::text, ('إيقاف — ' || hd.reason_code)::text,
         coalesce(hd.note, '')::text, null::bigint
  from public.installation_holds hd join sub on sub.scode = hd.subscriber_id
  union all
  select i.created_at, 'INVOICE'::text,
         ('فاتورة ' || coalesce(i.invoice_number, '—'))::text, i.status::text, i.amount::bigint
  from public.installation_invoices i join sub on sub.scode = i.subscriber_id
  union all
  select a.created_at, 'AUDIT'::text, a.action::text, coalesce(a.field, '')::text, null::bigint
  from public.audit_logs a join sub on a.entity_id = sub.sid
  order by 1 desc
  limit 300;
end;
$fn$;

revoke execute on function public.subscriber_timeline(text) from public, anon;
grant execute on function public.subscriber_timeline(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. طابور الاستثناءات — مُصفّح ومُسعَّر
--
-- المبلغ مؤشِّر حجم لا التزام، ويُقال ذلك في اسم العمود.
-- ---------------------------------------------------------------------------

create or replace function public.list_commission_exceptions(
  p_cycle_id uuid default null,
  p_reason text default null,
  p_blocking boolean default null,
  p_status text default 'OPEN',
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid, cycle_id uuid, activation_event_id text, subscriber_key text,
  reason_code text, detail text, blocks_finalization boolean, status text,
  created_at timestamptz, fdt_code text, raw_parent text, package_code text,
  indicative_amount bigint, total_count bigint
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('commission.view');
  return query
  with filtered as (
    select x.id as xid, x.cycle_id as xcyc, x.activation_event_id as xev,
           x.subscriber_key as xsub, x.reason_code as xreason, x.detail as xdetail,
           x.blocks_finalization as xblock, x.status as xstatus, x.created_at as xcreated,
           e.fdt_code as efdt, e.raw_parent as eparent, e.profile_name as epkg,
           coalesce(public.commission_rate_for(
             public.commission_version_for_cycle(x.cycle_id), 'new', 1, e.profile_name), 0)::bigint as eamt
    from public.commission_exceptions x
    left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    where (p_cycle_id is null or x.cycle_id = p_cycle_id)
      and (p_reason   is null or x.reason_code = p_reason)
      and (p_status   is null or x.status = p_status)
      and (p_blocking is null or x.blocks_finalization = p_blocking)
      and (p_search   is null
           or x.activation_event_id ilike '%' || p_search || '%'
           or x.subscriber_key ilike '%' || p_search || '%'
           or e.fdt_code ilike '%' || p_search || '%')
  )
  select f.xid, f.xcyc, f.xev, f.xsub, f.xreason, f.xdetail, f.xblock, f.xstatus,
         f.xcreated, f.efdt, f.eparent, f.epkg, f.eamt, count(*) over ()
  from filtered f
  order by f.xblock desc, f.xcreated desc
  limit public.page_limit(p_limit) offset public.page_offset(p_offset);
end;
$fn$;

revoke execute on function public.list_commission_exceptions(uuid,text,boolean,text,text,integer,integer) from public, anon;
grant execute on function public.list_commission_exceptions(uuid,text,boolean,text,text,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. موانع الاعتماد
--
-- calculate_commission_cycle يعرف سبب المنع ويرفع عدده وحده. شاشة المراجعة
-- تحتاج القائمة لتقول للمستخدم ما يُصلحه — دون تشغيل حساب لمعرفة ذلك.
-- ---------------------------------------------------------------------------

create or replace function public.commission_finalization_blockers(p_cycle_id uuid)
returns table (
  reason_code text, events integer, subscribers integer,
  indicative_amount bigint, owner_hint text, action_hint text
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('commission.view');
  return query
  select x.reason_code::text,
    count(*)::integer,
    count(distinct x.subscriber_key)::integer,
    coalesce(sum(coalesce(public.commission_rate_for(
      public.commission_version_for_cycle(p_cycle_id), 'new', 1, e.profile_name), 0)), 0)::bigint,
    (case x.reason_code
      when 'UNKNOWN_FDT'       then 'إدارة البيانات الرئيسية'
      when 'UNKNOWN_AGENT'     then 'إدارة البيانات الرئيسية'
      when 'UNKNOWN_PACKAGE'   then 'إدارة البيانات الرئيسية'
      when 'SOURCE_INCOMPLETE' then 'استيراد SaaS'
      when 'IDENTITY_CONFLICT' then 'مراجعة المشتركين'
      else 'مراجعة تشغيلية' end)::text,
    (case x.reason_code
      when 'UNKNOWN_FDT'       then 'صنِّف الكابينة ثم أعد حساب الدورة'
      when 'UNKNOWN_AGENT'     then 'اربط الاسم البديل بوكيل أو عرِّفه حساباً مباشراً'
      when 'UNKNOWN_PACKAGE'   then 'أضف الباقة وحدِّد صنفها'
      when 'SOURCE_INCOMPLETE' then 'أثبت اكتمال الملف أو استورد التغطية الناقصة'
      when 'IDENTITY_CONFLICT' then 'احسم الهوية المتعارضة'
      else 'راجع تفصيل الاستثناء' end)::text
  from public.commission_exceptions x
  left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
  where x.cycle_id = p_cycle_id and x.status = 'OPEN' and x.blocks_finalization
  group by x.reason_code
  order by 4 desc, 2 desc;
end;
$fn$;

revoke execute on function public.commission_finalization_blockers(uuid) from public, anon;
grant execute on function public.commission_finalization_blockers(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. الوكلاء مع أرقامهم
--
-- المحجوب يُنسَب عبر الاسم البديل للأب، لأن الحدث المحجوب لا نطاق له بعد.
-- ---------------------------------------------------------------------------

create or replace function public.list_agents_financial(p_cycle_id uuid default null)
returns table (
  agent_id uuid, code text, official_name text, status text, fdt_count integer,
  calc_events integer, calc_subscribers integer, calc_gross bigint,
  blocked_events integer, blocked_indicative bigint, installation_subscribers integer
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('commission.view');
  return query
  with calc as (
    select t.effective_agent_id as aid,
           count(distinct t.activation_event_id)::integer as ev,
           count(distinct t.subscriber_key)::integer as subs,
           coalesce(sum(t.amount), 0)::bigint as gross
    from public.commission_event_entitlements t
    where (p_cycle_id is null or t.cycle_id = p_cycle_id)
    group by 1
  ),
  blocked as (
    select al.agent_id as aid, count(*)::integer as ev,
           coalesce(sum(coalesce(public.commission_rate_for(
             public.commission_version_for_cycle(x.cycle_id), 'new', 1, e.profile_name), 0)), 0)::bigint as amt
    from public.commission_exceptions x
    join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    join public.agent_aliases al on al.alias_key = lower(btrim(coalesce(e.raw_parent, '')))
    where x.status = 'OPEN' and al.agent_id is not null
      and (p_cycle_id is null or x.cycle_id = p_cycle_id)
    group by 1
  )
  select a.id, a.code::text, a.official_name::text, a.status::text,
         (select count(*)::integer from public.fdts f where f.agent_id = a.id),
         coalesce(c.ev, 0), coalesce(c.subs, 0), coalesce(c.gross, 0),
         coalesce(b.ev, 0), coalesce(b.amt, 0),
         (select count(*)::integer from public.installation_enrollments en where en.effective_agent_id = a.id)
  from public.agents a
  left join calc c on c.aid = a.id
  left join blocked b on b.aid = a.id
  order by coalesce(c.gross, 0) desc, coalesce(b.amt, 0) desc, a.code;
end;
$fn$;

revoke execute on function public.list_agents_financial(uuid) from public, anon;
grant execute on function public.list_agents_financial(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. طوابير التنصيب والدفع والتدقيق
-- ---------------------------------------------------------------------------

create or replace function public.list_installation_entitlements(
  p_period text default null,
  p_stage text default null,
  p_invoice_status text default null,
  p_payment_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid, period text, subscriber_id text, subscriber_name text, reseller text,
  zone text, fdt text, stage text, amount bigint, invoice_status text,
  payment_status text, paid_amount bigint, total_count bigint
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('installation.view');
  return query
  with filtered as (
    select t.* from public.installation_entitlements t
    where (p_period is null or t.period = p_period)
      and (p_stage is null or t.stage = p_stage)
      and (p_invoice_status is null or t.invoice_status = p_invoice_status)
      and (p_payment_status is null or t.payment_status = p_payment_status)
  )
  select f.id, f.period::text, f.subscriber_id::text, f.subscriber_name::text,
         f.reseller::text, f.zone::text, f.fdt::text, f.stage::text,
         f.amount::bigint, f.invoice_status::text, f.payment_status::text,
         coalesce(f.paid_amount, 0)::bigint, count(*) over ()
  from filtered f
  order by f.period desc, f.subscriber_id
  limit public.page_limit(p_limit) offset public.page_offset(p_offset);
end;
$fn$;

revoke execute on function public.list_installation_entitlements(text,text,text,text,integer,integer) from public, anon;
grant execute on function public.list_installation_entitlements(text,text,text,text,integer,integer) to authenticated;

create or replace function public.list_installation_holds(
  p_status text default 'ACTIVE',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid, subscriber_id text, stage_code text, reason_code text, reason_label text,
  hold_type text, status text, note text, created_at timestamptz,
  blocks_payment boolean, total_count bigint
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('installation.view');
  return query
  with filtered as (
    select h.id as hid, h.subscriber_id as hsub, h.stage_code as hstage,
           h.reason_code as hreason, r.label_ar as hlabel, h.hold_type as htype,
           h.status as hstatus, h.note as hnote, h.created_at as hcreated,
           r.blocks_payment as hblocks
    from public.installation_holds h
    left join public.installation_hold_reasons r on r.code = h.reason_code
    where (p_status is null or h.status = p_status)
  )
  select f.hid, f.hsub::text, f.hstage::text, f.hreason::text, f.hlabel::text,
         f.htype::text, f.hstatus::text, f.hnote::text, f.hcreated,
         coalesce(f.hblocks, true), count(*) over ()
  from filtered f order by f.hcreated desc
  limit public.page_limit(p_limit) offset public.page_offset(p_offset);
end;
$fn$;

revoke execute on function public.list_installation_holds(text,integer,integer) from public, anon;
grant execute on function public.list_installation_holds(text,integer,integer) to authenticated;

create or replace function public.list_payment_batches(
  p_domain text default 'commission',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid, name text, cycle_id uuid, status text, total_amount bigint,
  item_count integer, prepared_at timestamptz, posted_at timestamptz,
  payment_reference text, total_count bigint
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('payment.view');
  return query
  select b.id, b.name::text, b.cycle_id, b.status::text,
         coalesce(b.total_amount, 0)::bigint, coalesce(b.item_count, 0),
         b.prepared_at, b.posted_at, b.payment_reference::text, count(*) over ()
  from public.commission_payment_batches b
  order by b.prepared_at desc nulls last
  limit public.page_limit(p_limit) offset public.page_offset(p_offset);
end;
$fn$;

revoke execute on function public.list_payment_batches(text,integer,integer) from public, anon;
grant execute on function public.list_payment_batches(text,integer,integer) to authenticated;

create or replace function public.list_audit_events(
  p_action_prefix text default null,
  p_entity_type text default null,
  p_actor uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id bigint, created_at timestamptz, actor_id uuid, action text, field text,
  old_value text, new_value text, entity_type text, entity_id uuid,
  request_id uuid, extra text, total_count bigint
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('audit.view');
  return query
  select a.id, a.created_at, a.actor_id, a.action::text, a.field::text,
         a.old_value::text, a.new_value::text, a.entity_type::text, a.entity_id,
         a.request_id, a.extra::text, count(*) over ()
  from public.audit_logs a
  where (p_action_prefix is null or a.action like p_action_prefix || '%')
    and (p_entity_type is null or a.entity_type = p_entity_type)
    and (p_actor is null or a.actor_id = p_actor)
    and (p_from is null or a.created_at >= p_from)
    and (p_to is null or a.created_at < p_to)
  order by a.created_at desc
  limit public.page_limit(p_limit) offset public.page_offset(p_offset);
end;
$fn$;

revoke execute on function public.list_audit_events(text,text,uuid,timestamptz,timestamptz,integer,integer) from public, anon;
grant execute on function public.list_audit_events(text,text,uuid,timestamptz,timestamptz,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. حالة دورة التنصيب
-- ---------------------------------------------------------------------------

create or replace function public.installation_cycle_state(p_cycle_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v jsonb;
begin
  perform public.require_capability('installation.view');
  select jsonb_build_object(
    'cycle', (select jsonb_build_object('id', c.id, 'name', c.name, 'status', c.status,
                'start_date', c.start_date, 'end_date', c.end_date, 'closed_at', c.closed_at)
              from public.installation_cycles c where p_cycle_id is not null and c.id = p_cycle_id),
    'enrollments', coalesce((select jsonb_object_agg(x.k, x.n) from (
        select coalesce(current_stage_code, 'UNKNOWN') as k, count(*) as n
        from public.installation_enrollments group by 1) x), '{}'::jsonb),
    'classification', coalesce((select jsonb_object_agg(x.k, x.n) from (
        select classification as k, count(*) as n
        from public.subscriber_classifications group by 1) x), '{}'::jsonb),
    'entitlements', (select jsonb_build_object(
        'total', count(*),
        'due', coalesce(sum(amount) filter (where payment_status <> 'paid'), 0),
        'paid', coalesce(sum(paid_amount), 0),
        'awaiting_invoice', count(*) filter (where invoice_status = 'pending'))
      from public.installation_entitlements),
    'holds', (select count(*) from public.installation_holds where status = 'ACTIVE'),
    'historical', (select jsonb_build_object(
        'subscribers', (select count(*) from public.installation_subscribers),
        'payment_rows', count(*), 'paid', coalesce(sum(amount), 0))
      from public.installation_payment_history)
  ) into v;
  return v;
end;
$fn$;

revoke execute on function public.installation_cycle_state(uuid) from public, anon;
grant execute on function public.installation_cycle_state(uuid) to authenticated;

commit;
