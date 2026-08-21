-- ---------------------------------------------------------------------------
-- المرحلة ١ — صحّة الأرقام والعقود المكسورة
--
-- ثلاثة عيوب مؤكَّدة من الإنتاج، لا من وثيقة:
--
--   ١ · قائمة الوكلاء تعود فارغة رغم وجود أحد عشر وكيلاً فعّالاً.
--   ٢ · التابع للشركة يُخرَج من المال ويبقى في الحواجب.
--   ٣ · شاشة الدورة تقرأ عقداً لا تُنتجه الدالّة، فتعرض شرطات.
--
-- ولا شيء منها يمسّ محرّك الحساب نفسه: الأرقام قبل هذه المهاجرة وبعدها
-- واحدة، والذي يتغيّر ما يُعرَض وما يُحجَب.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. قائمة اختيار الوكلاء
--
-- الدالّة ترشّح `a.status = 'ACTIVE'` بحروف كبيرة، وقيد الجدول لا يقبل إلا
-- `'active'` و`'inactive'` بحروف صغيرة. فالشرط لا يطابق صفاً واحداً:
--
--   إجمالي الوكلاء            11
--   يجتاز فحص القدرة          11
--   يطابق 'ACTIVE'             0     ← الشرط الساقط
--   يطابق 'active'            11
--   ما تُعيده الدالّة           0
--
-- ولا خطأ يُلتقط من الشبكة: الدالّة تنجح وتعيد مصفوفةً فارغة. ولهذا لم
-- يكن الحلّ في الواجهة — إزالة سقوطها الصامت وحدها كانت ستُبقي القائمة
-- فارغة، وتُسمّي الفراغ نجاحاً.
--
-- والمقارنة تصير غير حسّاسة لحالة الأحرف: تغييرُ نطاقٍ في القيد لاحقاً
-- يجب ألّا يُفرغ القائمة صامتاً مرّةً أخرى.
-- ---------------------------------------------------------------------------

create or replace function public.list_agents_for_pick(
  p_search text default null,
  p_limit integer default 50
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
    select a.id, a.code, a.official_name, a.status
    from public.agents a
    where public.has_capability('agent.view')
      and lower(a.status) = 'active'
      and (p_search is null or btrim(p_search) = ''
           or a.official_name ilike '%' || p_search || '%'
           or a.code ilike '%' || p_search || '%')
    order by a.official_name
    limit public.page_limit(p_limit)) x;
$fn$;

revoke execute on function public.list_agents_for_pick(text,integer) from public, anon;
grant execute on function public.list_agents_for_pick(text,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. المحرّك: العائدية تُحسم قبل قواعد الوكيل
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
  -- تصحيحات التفعيلات تُطبَّق هنا، على مدخل المحرّك لا على مصدره.
  --
  -- المصدر المستورَد لا يُمسّ أبداً: صفّ الملفّ يبقى كما ورد. والتصحيح
  -- طبقةٌ فوقه تُقرأ عند كل حساب، فيبقى الأصل قابلاً للمراجعة ويبقى الفرق
  -- بين «ما ورد» و«ما اعتُمد» مرئياً ومُدقَّقاً.
  --
  -- والإضافة اليدوية تلزمها هوية مشترك: أساس الشريحة عددُ المشتركين
  -- الفريدين، فزيادةٌ بلا مشترك تُفسد الشريحة بصمت.
  create temporary table tmp_cycle_events on commit drop as
  select q.*
  from public.commission_qualifying_events q
  where q.event_created_at >= v_from
    and q.event_created_at < v_to
    and not exists (
      select 1 from public.activation_corrections c
      where c.cycle_id = p_cycle_id
        and c.correction_type = 'EXCLUDE'
        and c.status = 'ACTIVE'
        and c.source_event_id = q.saas_event_id)

  union all

  -- الحدث المُضاف يمرّ بنفس الاشتقاقات التي يمرّ بها الوارد: الهوية،
  -- والاسم البديل، والكابينة، والنطاق. لا مسارَ ثانٍ لحساب النطاق.
  select
    'MANUAL-' || c.id::text,
    c.event_at,
    lower(btrim(c.subscriber_username)),
    null::text,
    c.package_code,
    c.raw_parent,
    c.fdt_code,
    null::uuid,
    coalesce(si.id::text, lower(btrim(c.subscriber_username))),
    si.id,
    si.identity_status,
    si.source_classification,
    coalesce(si.effective_agent_id, al.agent_id),
    ag.official_name,
    f.zone,
    case when c.fdt_code is not null and f.code is null then 'unresolved'
         when f.zone = 'new' then 'new' else 'old' end,
    case when c.fdt_code is not null and f.code is null then 'UNRESOLVED'
         when f.zone = 'new' then 'FDT' else 'AGENT' end,
    case when c.fdt_code is not null and f.code is null then null
         when f.zone = 'new' then c.fdt_code
         else coalesce(si.effective_agent_id, al.agent_id)::text end,
    p.semantic_category,
    al.resolution
  from public.activation_corrections c
  left join public.subscriber_identities si
    on si.username_key = lower(btrim(c.subscriber_username))
  left join public.agent_aliases al
    on al.alias_key = lower(btrim(coalesce(c.raw_parent, ''))) and al.active
  left join public.agents ag on ag.id = coalesce(si.effective_agent_id, al.agent_id)
  left join public.fdts f on f.code = c.fdt_code
  left join public.packages p on p.code = c.package_code
  where c.cycle_id = p_cycle_id
    and c.correction_type = 'ADD'
    and c.status = 'ACTIVE'
    and c.event_at >= v_from
    and c.event_at < v_to;

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
  --
  -- العائدية تُحسم قبل قواعد الوكيل، لا بعدها. وكان الحسم هنا يقرأ حلّ
  -- الاسم البديل وحده (`parent_resolution`)، بينما المال يقرأ تصنيف المشترك
  -- (`source_classification`). مصدران لحقيقةٍ واحدة يفترقان: المشترك يخرج
  -- من الحساب لأنه تابع للشركة، ويبقى في الحواجب لأن اسمه البديل لم يُصنَّف.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_AGENT',
         'the raw parent does not resolve to an agent', true
  from tmp_cycle_events t
  where t.zone = 'old' and t.effective_agent_id is null
    and coalesce(t.source_classification, 'RESELLER') <> 'DIRECT_COMPANY'
    and coalesce(t.parent_resolution, 'needs_review') <> 'direct_company'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_AGENT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  -- الكابينة تُشترط في المنطقة الجديدة وحدها؛ القديمة شريحتها بالوكيل.
  --
  -- والتابع للشركة لا يُشترط له تصنيف كابينة: هو خارج عمولة الوكيل أصلاً،
  -- لا يُسهم في شريحة ولا ينشأ عنه مبلغ. فحجبُ الاعتماد لأجله حجبٌ بلا أثر
  -- مالي — و18,508 من 22,723 حاجباً كانت من هذا النوع، أي أربعة أخماس
  -- الطابور «العاجل» لا يخصّ الوكلاء في شيء.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_FDT',
         case when t.zone = 'unresolved'
              then 'cabinet ' || coalesce(t.fdt_code, '?') || ' is not in the FDT master, so its zone is undecided'
              else 'the event is in the new zone but carries no usable cabinet' end,
         true
  from tmp_cycle_events t
  where (t.zone = 'unresolved' or (t.zone = 'new' and t.scope_id is null))
    and coalesce(t.source_classification, 'RESELLER') <> 'DIRECT_COMPANY'
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

-- ---------------------------------------------------------------------------
-- 3. نتيجة الدورة — عقد قراءة واحد
--
-- `report_commission_cycle_detail` تُعيد جدولاً: صفٌّ لكل نطاق. والواجهة
-- تقرأ منه `detail['totals']` كأنه كائن، فتحصل دائماً على `undefined` —
-- ولهذا كانت كل مؤشّرات الدورة شرطات. ولم يكن ذلك عطلاً في الخادم: العقد
-- الذي تقرأه الواجهة لم يوجد قطّ.
--
-- ولا يُغيَّر المحرّك لإرضاء الواجهة. تُضاف قراءةٌ واحدة تُعيد ما تحتاجه
-- الشاشة كائناً واحداً: الإجماليات، والمناطق، والوكلاء، وما لم تُحسم
-- عائديته، والحواجب. تُقرأ مرّةً وتُعاد قسمتها في الشاشة — بدل ثلاث
-- قراءاتٍ لنفس الدالّة يسقط كلٌّ منها صامتاً.
--
-- والمصالحة معروضة لا مُستنتَجة:
--
--   المنسوب لوكلاء معروفين + ما لم تُحسم عائديته = إجمالي الدورة
--
-- فلا يبدو مجموع الوكلاء ناقصاً بلا سبب، ولا يُنسب المبلغ المعلّق إلى أحد.
-- ---------------------------------------------------------------------------

create or replace function public.commission_cycle_result(
  p_cycle_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id    uuid;
  v_cycle public.commission_cycles%rowtype;
  v_doc   jsonb;
begin
  perform public.require_capability('commission.view');

  v_id := coalesce(p_cycle_id, public.current_commission_cycle_id());
  if v_id is null then
    return jsonb_build_object('found', false);
  end if;

  select * into v_cycle from public.commission_cycles where id = v_id;
  if not found then
    return jsonb_build_object('found', false);
  end if;

  select jsonb_build_object(
    'found', true,
    'cycle', jsonb_build_object(
      'id', v_cycle.id,
      'name', v_cycle.name,
      'status', v_cycle.status,
      'period_start', v_cycle.period_start,
      'period_end', v_cycle.period_end,
      'window_start', public.cycle_window_start(v_cycle.period_start),
      'window_end', public.cycle_window_end(v_cycle.period_end),
      'finalized_at', v_cycle.finalized_at,
      'closed_at', v_cycle.closed_at),

    -- النتيجة المالية: محسوب، معتمد، جاهز، مدفوع.
    -- المدفوع لا يُقرأ من اللقطة: اللقطة تحسب ولا تدفع. يُقرأ ممّا رُحِّل
    -- فعلاً في دفعات الصرف، وهو وحده ما يعني أن مالاً خرج.
    'totals', (
      select jsonb_build_object(
        'gross', coalesce(sum(s.gross_commission), 0),
        'scopes', count(*),
        -- المعتمد ليس المحسوب: لا يصير معتمداً إلا بلقطةٍ مثبَّتة.
        'approved', coalesce(sum(s.gross_commission) filter (where s.finalized_at is not null), 0),
        'paid', public.commission_cycle_posted_amount(v_id),
        'remaining', coalesce(sum(s.gross_commission), 0)
                     - public.commission_cycle_posted_amount(v_id))
      from public.commission_cycle_snapshots s where s.cycle_id = v_id),

    'volumes', (
      select jsonb_build_object(
        'qualifying_events', count(*),
        'tier_basis', count(distinct x.subscriber_key))
      from public.commission_event_entitlements x where x.cycle_id = v_id),

    -- القديمة بالوكيل والجديدة بالكابينة: تُعرضان منفصلتين لأن قاعدتيهما مختلفتان.
    'zones', (
      select coalesce(jsonb_agg(to_jsonb(z) order by z.zone), '[]'::jsonb)
      from (
        select s.zone,
               count(*) as scopes,
               sum(s.unique_activated_subscribers) as tier_basis,
               sum(s.qualifying_event_count) as events,
               sum(s.gross_commission) as gross
        from public.commission_cycle_snapshots s
        where s.cycle_id = v_id group by s.zone) z),

    -- المنسوب لوكلاء معروفين، وما لم تُحسم عائديته — كلٌّ على حدة.
    'agents', (
      select coalesce(jsonb_agg(to_jsonb(a) order by a.gross desc), '[]'::jsonb)
      from (
        select ag.id as agent_id, ag.official_name as agent_name, ag.code as agent_code,
               count(*) as events,
               count(distinct x.subscriber_key) as subscribers,
               sum(x.amount) as gross
        from public.commission_event_entitlements x
        join public.agents ag on ag.id = x.effective_agent_id
        where x.cycle_id = v_id
        group by ag.id, ag.official_name, ag.code) a),

    'unresolved_ownership', (
      select jsonb_build_object(
        'events', count(*),
        'subscribers', count(distinct x.subscriber_key),
        'amount', coalesce(sum(x.amount), 0),
        'parents', coalesce(jsonb_agg(distinct x.raw_parent)
                            filter (where x.raw_parent is not null), '[]'::jsonb))
      from public.commission_event_entitlements x
      where x.cycle_id = v_id and x.effective_agent_id is null),

    'blockers', (
      select coalesce(jsonb_agg(to_jsonb(b) order by b.events desc), '[]'::jsonb)
      from (
        select x.reason_code,
               count(*) as events,
               count(distinct x.subscriber_key) as subscribers
        from public.commission_exceptions x
        where x.cycle_id = v_id and x.status = 'OPEN' and x.blocks_finalization
        group by x.reason_code) b)
  ) into v_doc;

  return v_doc;
end;
$fn$;

revoke execute on function public.commission_cycle_result(uuid) from public, anon;
grant execute on function public.commission_cycle_result(uuid) to authenticated;

commit;
