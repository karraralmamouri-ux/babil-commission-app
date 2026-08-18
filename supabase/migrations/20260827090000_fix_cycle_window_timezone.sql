-- إصلاح نافذة الدورة: حدودها بتوقيت العمل لا بـUTC.
--
-- العيب. الدورة تُحدَّد بتاريخين (period_start, period_end)، وكانت تُقارَن
-- مباشرةً بـevent_created_at وهو timestamptz. المقارنة تُحوِّل التاريخ بتوقيت
-- الجلسة، وتوقيت الجلسة في الإنتاج UTC. فصارت النافذة فعلياً:
--
--     [2026-07-01T00:00Z , 2026-08-01T00:00Z)
--
-- بينما الشهر التجاري في بغداد (UTC+3) هو:
--
--     [2026-06-30T21:00Z , 2026-07-31T21:00Z)
--
-- الفارق ثلاث ساعات في المقدّمة: أحداث أوّل ثلاث ساعات من ١ تموز بتوقيت بغداد
-- تقع خارج الحساب.
--
-- القياس على تموز الحقيقي:
--   أحداث الملف (شهر بغداد كاملاً)     : 29,289
--   داخل النافذة القديمة (UTC)         : 29,246
--   ساقطة صامتة                        :      43
--     منها باقة مدفوعة بنطاق محلول     :       8  ← مال يُستحق ولا يُحسب
--     منها باقة مدفوعة بكابينة مجهولة  :      30  ← حجب يجب أن يظهر ولا يظهر
--     منها Loan-3                      :       5
--
-- وخطورة العيب في صمته: الحدث الساقط لا يدخل الاستحقاقات ولا يدخل الاستثناءات.
-- لا هو محسوب ولا هو محجوب — بل غير موجود. والحاجز الذي بُني ليمنع اعتماد دورة
-- ناقصة لا يراه أصلاً، فتُعتمد الدورة وهي ناقصة وهي تبدو متّزنة.
--
-- وهو من عائلة العيب الذي عولج في المُحلِّل: القارئ كان يقرأ الطوابع الساذجة
-- بتوقيت الجهاز فثُبِّت على +03:00. ثُبِّتت لحظةُ الحدث ولم تُثبَّت حدودُ
-- الشهر، فبقي الشِّق الثاني مفتوحاً.
--
-- الإصلاح: نقطة واحدة تُعرِّف توقيت العمل، وتُشتق منها حدود كل نافذة.
-- forward-only. لا صف مالي يُمَس، ولا نتيجة معتمدة تتغيّر: تموز ما زالت
-- UNDER_REVIEW وإعادة الحساب لا تقع إلا بطلب صريح.

begin;

-- ---------------------------------------------------------------------------
-- 1. توقيت العمل — مصدر واحد
--
-- نظير SOURCE_UTC_OFFSET في assets/js/saas-import.js. الاسم المنطقي لا الإزاحة
-- الثابتة: لو عاد التوقيت الصيفي يوماً تتبعه القاعدة. وبغداد ألغته منذ 2015
-- فالقيمة اليوم +03:00 ثابتة.
-- ---------------------------------------------------------------------------

create or replace function public.business_timezone()
returns text
language sql
immutable
set search_path = ''
as $fn$ select 'Asia/Baghdad'::text $fn$;

comment on function public.business_timezone() is
  'المنطقة الزمنية التي تُفهم بها تواريخ الدورات. نظير SOURCE_UTC_OFFSET في المُحلِّل.';

-- بداية اليوم الأول من الدورة بتوقيت العمل.
create or replace function public.cycle_window_start(p_period_start date)
returns timestamptz
language sql
stable
set search_path = ''
as $fn$ select (p_period_start::timestamp at time zone public.business_timezone()) $fn$;

-- أوّل لحظة بعد الدورة: بداية اليوم التالي لآخر يوم، بتوقيت العمل. الحد الأعلى
-- مفتوح دائماً، فلا حدث على الحدّ يُحسب مرتين ولا يسقط بين دورتين.
create or replace function public.cycle_window_end(p_period_end date)
returns timestamptz
language sql
stable
set search_path = ''
as $fn$ select ((p_period_end + 1)::timestamp at time zone public.business_timezone()) $fn$;

grant execute on function public.business_timezone() to authenticated;
grant execute on function public.cycle_window_start(date) to authenticated;
grant execute on function public.cycle_window_end(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. حساب الدورة — النافذة وحدها تتغيّر
--
-- الجسد منقول حرفياً عن 20260825090000 عدا سطرَي النافذة، حتى يبقى الفرق بين
-- النسختين مقروءاً ومحصوراً في السبب المذكور أعلاه.
-- ---------------------------------------------------------------------------

create or replace function public.calculate_commission_cycle(
  p_cycle_id uuid,
  p_finalize boolean default false,
  p_request_id uuid default null,
  p_completeness_override_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_version uuid;
  v_blocking integer := 0;
  v_incomplete integer := 0;
  v_events integer := 0;
  v_subscribers integer := 0;
  v_gross bigint := 0;
  v_scopes integer := 0;
  v_from timestamptz;
  v_to timestamptz;
begin
  perform public.require_capability(
    case when p_finalize then 'commission.finalize' else 'commission.view' end);

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;

  if v_cycle.status in ('FINALIZED','PARTIALLY_PAID','PAID','CLOSED') then
    raise exception 'A finalized commission cycle is not recalculated' using errcode = '42501';
  end if;
  if v_cycle.engine_version <> 'VNEXT' then
    raise exception 'This cycle is not a vNext cycle' using errcode = '42501';
  end if;

  v_version := v_cycle.scheme_version_id;
  if v_version is null then
    select v.id into v_version
    from public.commission_scheme_versions v
    join public.commission_schemes s on s.id = v.scheme_id
    where v.status = 'PUBLISHED' and s.is_active
      and (v.effective_from is null or v.effective_from <= v_cycle.period_start)
    order by v.effective_from desc nulls last, v.version desc
    limit 1;
  end if;
  if v_version is null then
    raise exception 'No published commission scheme version applies' using errcode = 'P0002';
  end if;

  delete from public.commission_event_entitlements where cycle_id = p_cycle_id;
  delete from public.commission_cycle_snapshots where cycle_id = p_cycle_id and finalized_at is null;
  delete from public.commission_exceptions where cycle_id = p_cycle_id and status = 'OPEN';

  -- النافذة بتوقيت العمل، لا بتوقيت جلسة القاعدة.
  v_from := public.cycle_window_start(v_cycle.period_start);
  v_to := public.cycle_window_end(v_cycle.period_end);

  drop table if exists tmp_cycle_events;
  drop table if exists tmp_billable;
  drop table if exists tmp_scope;
  create temporary table tmp_cycle_events on commit drop as
  select q.*
  from public.commission_qualifying_events q
  where q.event_created_at >= v_from
    and q.event_created_at < v_to;

  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_PACKAGE',
         'package not in the master list', true
  from tmp_cycle_events t
  where (t.package_category is null or t.package_category = 'UNKNOWN')
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_PACKAGE'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'IDENTITY_CONFLICT',
         'subscriber identity is in conflict', true
  from tmp_cycle_events t where t.identity_status = 'CONFLICT'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'IDENTITY_CONFLICT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  -- الأب المجهول: من لم يُحَلّ إلى وكيل ولم يُعرَف شركةً مباشرة.
  -- الشركة المباشرة محلولة ومستبعدة عن عمد، فليست مجهولة.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_AGENT',
         'the raw parent does not resolve to an agent', true
  from tmp_cycle_events t
  where t.zone = 'old' and t.effective_agent_id is null
    and coalesce(t.parent_resolution, 'needs_review') <> 'direct_company'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_AGENT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  -- الكابينة تُشترط في المنطقة الجديدة وحدها؛ القديمة شريحتها بالوكيل.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_FDT',
         case when t.zone = 'unresolved'
              then 'cabinet ' || coalesce(t.fdt_code, '?') || ' is not in the FDT master, so its zone is undecided'
              else 'the event is in the new zone but carries no usable cabinet' end,
         true
  from tmp_cycle_events t
  where (t.zone = 'unresolved' or (t.zone = 'new' and t.scope_id is null))
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_FDT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  select count(*) into v_incomplete
  from public.saas_import_batches b
  where b.id in (select distinct import_batch_id from tmp_cycle_events)
    and b.completeness_status <> 'COMPLETE';
  if v_incomplete > 0
     and not exists (select 1 from public.commission_exceptions x
                     where x.cycle_id = p_cycle_id and x.reason_code = 'SOURCE_INCOMPLETE'
                       and x.status <> 'OPEN') then
    insert into public.commission_exceptions
      (cycle_id, reason_code, detail, blocks_finalization)
    values (p_cycle_id, 'SOURCE_INCOMPLETE',
            v_incomplete::text || ' source batch(es) are not proven complete', true)
    on conflict do nothing;
  end if;

  create temporary table tmp_billable on commit drop as
  select t.*
  from tmp_cycle_events t
  where t.package_category = 'PAID_PACKAGE'
    and t.scope_id is not null
    and coalesce(t.identity_status, 'UNMATCHED') <> 'CONFLICT'
    and coalesce(t.source_classification, 'RESELLER') <> 'DIRECT_COMPANY'
    and exists (
      select 1 from public.commission_package_rates r
      join public.commission_tier_definitions d on d.id = r.tier_definition_id
      where d.scheme_version_id = v_version and r.package_code = t.package_code and r.qualifies);

  create temporary table tmp_scope on commit drop as
  select
    b.scope_type, b.scope_id, b.zone,
    count(distinct b.subscriber_key)::integer as unique_subscribers,
    count(distinct b.saas_event_id)::integer as qualifying_events,
    max(b.agent_name) as scope_label
  from tmp_billable b
  group by b.scope_type, b.scope_id, b.zone;

  insert into public.commission_event_entitlements (
    cycle_id, activation_event_id, subscriber_key, subscriber_identity_id, saas_user_id,
    scope_type, scope_id, zone, effective_agent_id, agent_name, fdt_code, raw_parent,
    package_code, scheme_version_id, tier_code, amount, status, event_at)
  select
    p_cycle_id, b.saas_event_id, b.subscriber_key, b.subscriber_identity_id, b.saas_user_id,
    b.scope_type, b.scope_id, b.zone, b.effective_agent_id, b.agent_name, b.fdt_code,
    b.raw_parent, b.package_code, v_version,
    (public.commission_tier_for_subscribers(v_version, b.zone, s.unique_subscribers)).code,
    coalesce(public.commission_rate_for(v_version, b.zone, s.unique_subscribers, b.package_code), 0),
    case when p_finalize then 'FINAL' else 'PROJECTED' end,
    b.event_created_at
  from tmp_billable b
  join tmp_scope s on s.scope_type = b.scope_type and s.scope_id = b.scope_id;

  insert into public.commission_cycle_snapshots (
    cycle_id, scheme_version_id, scope_type, scope_id, scope_label, zone,
    unique_activated_subscribers, qualifying_event_count, tier_code,
    package_breakdown, gross_commission, source_batch_ids,
    measurement_start, measurement_end, finalized_at)
  select
    p_cycle_id, v_version, s.scope_type, s.scope_id, s.scope_label, s.zone,
    s.unique_subscribers, s.qualifying_events,
    (public.commission_tier_for_subscribers(v_version, s.zone, s.unique_subscribers)).code,
    coalesce((select jsonb_object_agg(x.package_code, x.n)
              from (select e.package_code, count(*) as n
                    from public.commission_event_entitlements e
                    where e.cycle_id = p_cycle_id and e.scope_type = s.scope_type
                      and e.scope_id = s.scope_id
                    group by e.package_code) x), '{}'::jsonb),
    coalesce((select sum(e.amount) from public.commission_event_entitlements e
              where e.cycle_id = p_cycle_id and e.scope_type = s.scope_type
                and e.scope_id = s.scope_id), 0),
    coalesce((select array_agg(distinct t.import_batch_id) from tmp_cycle_events t), '{}'),
    v_cycle.period_start, v_cycle.period_end,
    case when p_finalize then now() else null end
  from tmp_scope s;

  select count(*) into v_blocking from public.commission_exceptions
  where cycle_id = p_cycle_id and status = 'OPEN' and blocks_finalization;
  select count(*), coalesce(sum(amount), 0) into v_events, v_gross
  from public.commission_event_entitlements where cycle_id = p_cycle_id;
  select count(*), coalesce(sum(unique_activated_subscribers), 0)
  into v_scopes, v_subscribers
  from public.commission_cycle_snapshots where cycle_id = p_cycle_id;

  if p_finalize then
    if p_request_id is null then
      raise exception 'request_id is required to finalize' using errcode = '22023';
    end if;
    if v_blocking > 0 and btrim(coalesce(p_completeness_override_reason, '')) = '' then
      raise exception 'Finalization is blocked by % open exception(s)', v_blocking
        using errcode = '42501';
    end if;

    update public.commission_cycles
    set status = 'FINALIZED', scheme_version_id = v_version,
        finalized_by = v_actor, finalized_at = now(), calculated_at = now()
    where id = p_cycle_id;

    insert into public.audit_logs (
      actor_id, action, field, new_value, entity_type, entity_id, request_id, extra)
    values (v_actor, 'commission.cycle.finalized', 'status', 'FINALIZED',
      'commission_cycle', p_cycle_id, p_request_id,
      'events=' || v_events::text || ' subscribers=' || v_subscribers::text
      || ' gross=' || v_gross::text
      || coalesce(' override=' || nullif(btrim(coalesce(p_completeness_override_reason,'')),''), ''));
  else
    update public.commission_cycles
    set calculated_at = now(),
        status = case when status = 'DRAFT' then 'UNDER_REVIEW' else status end
    where id = p_cycle_id;
  end if;

  return jsonb_build_object(
    'cycle_id', p_cycle_id,
    'scheme_version_id', v_version,
    'finalized', p_finalize,
    'scopes', v_scopes,
    'unique_activated_subscribers', v_subscribers,
    'qualifying_events', v_events,
    'gross_commission', v_gross,
    'blocking_exceptions', v_blocking,
    'window_start', v_from,
    'window_end', v_to
  );
end;
$fn$;

revoke execute on function public.calculate_commission_cycle(uuid, boolean, uuid, text)
  from public, anon;
grant execute on function public.calculate_commission_cycle(uuid, boolean, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. نسخة المخطَّط السارية على دورة
--
-- عيب ثانٍ من العائلة نفسها. commission_cycles.scheme_version_id لا يُملأ إلا
-- عند الاعتماد؛ وقبله يبقى فارغاً بينما الحساب يشتقّ النسخة المنشورة اشتقاقاً.
-- فكل من قرأ العمود مباشرةً حصل على NULL، وcommission_rate_for أعادت NULL،
-- وcoalesce حوّلتها صفراً. النتيجة: «المبلغ المحجوب = 0» في كل شاشة تعرضه،
-- لدورة تحجب عشرات الملايين.
--
-- والصفر أخطر من الخطأ الظاهر: الرقم الخاطئ يُستجوَب، أما الصفر فيُقرأ
-- «لا شيء محجوب» فيُغلَق الطابور دون أن يُفتح.
--
-- الاشتقاق يُوضَع هنا مرة واحدة ويُستدعى من كل قارئ، فلا يتفرّق التعريف.
-- ---------------------------------------------------------------------------

create or replace function public.commission_version_for_cycle(p_cycle_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $fn$
  select coalesce(
    c.scheme_version_id,
    (select v.id
     from public.commission_scheme_versions v
     join public.commission_schemes s on s.id = v.scheme_id
     where v.status = 'PUBLISHED' and s.is_active
       and (v.effective_from is null or v.effective_from <= c.period_start)
     order by v.effective_from desc nulls last, v.version desc
     limit 1))
  from public.commission_cycles c
  where c.id = p_cycle_id;
$fn$;

grant execute on function public.commission_version_for_cycle(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. المبلغ المحجوب بكابينة — النافذة نفسها والنسخة نفسها
--
-- لو بقيت هذه على UTC لاختلف الرقم المعروض في شاشة الكابينات عن الرقم الذي
-- يُنتجه الحساب. ورقمان متعارضان عن الشيء ذاته أسوأ من رقم خاطئ واحد.
-- ---------------------------------------------------------------------------

create or replace function public.fdt_blocked_amount(p_cycle_id uuid, p_fdt_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'fdt_code', p_fdt_code,
    'blocked_events', count(*),
    'blocked_subscribers', count(distinct e.username_key),
    -- المبلغ يُقدَّر بسعر الشريحة الأولى: الشريحة الحقيقية لا تُعرف قبل أن
    -- تُحسَم المنطقة، فالرقم مؤشِّر حجم لا التزام.
    'indicative_amount', coalesce(sum(
      coalesce(public.commission_rate_for(
        public.commission_version_for_cycle(p_cycle_id),
        'new', 1, e.profile_name), 0)), 0)
  )
  from public.saas_activation_events e
  join public.commission_cycles c on c.id = p_cycle_id
  left join public.fdts f on f.code = e.fdt_code
  where e.fdt_code = p_fdt_code
    and f.code is null
    and coalesce(e.canceled, false) = false
    and e.event_created_at >= public.cycle_window_start(c.period_start)
    and e.event_created_at < public.cycle_window_end(c.period_end);
$fn$;

revoke execute on function public.fdt_blocked_amount(uuid, text) from public, anon;
grant execute on function public.fdt_blocked_amount(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. الأثر المالي للاستثناءات، مُجمَّعاً بالسبب
--
-- الاستثناء بلا رقم لا يُرتَّب. «22,691 كابينة مجهولة» و«2 وكيل مجهول» يبدوان
-- متساويين في قائمة أسباب، بينما الأول يحجب أضعاف ما يحجبه الثاني. الترتيب
-- بالمال هو ما يجعل الطابور قابلاً للعمل.
--
-- والمبلغ مؤشِّر حجم لا التزام: الشريحة الحقيقية لا تُعرف قبل أن يُحسَم سبب
-- الحجب، فيُقدَّر بسعر الشريحة الأولى — وهو الحدّ الأدنى دائماً. يُسمّى
-- indicative صراحةً حتى لا يُقرأ رقماً مستحقاً.
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
  select
    x.reason_code,
    bool_or(x.blocks_finalization),
    count(*)::integer,
    count(distinct x.activation_event_id)::integer,
    count(distinct x.subscriber_key)::integer,
    coalesce(sum(
      coalesce(public.commission_rate_for(
        public.commission_version_for_cycle(x.cycle_id),
        'new', 1, e.profile_name), 0)), 0)::bigint
  from public.commission_exceptions x
  join public.commission_cycles c on c.id = x.cycle_id
  left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
  where x.cycle_id = p_cycle_id
    and x.status = 'OPEN'
    and public.has_capability('report.view')
  group by x.reason_code
  order by 6 desc, 3 desc;
$fn$;

revoke execute on function public.report_commission_exception_impact(uuid) from public, anon;
grant execute on function public.report_commission_exception_impact(uuid) to authenticated;

commit;
