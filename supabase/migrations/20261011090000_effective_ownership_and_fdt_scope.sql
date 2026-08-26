-- LIVE-01 + LIVE-02 (PR-B3): عائدية مؤرَّخة بالحدث، ونطاق FDT بالرقم.
--
-- LIVE-01. محرّك العمولة لم يقرأ subscriber_ownership قط منذ إضافته
-- (20260830080000): effective_agent_id ظلّ يُشتقّ من subscriber_identities/
-- agent_aliases — الحاضر لا لحظة الحدث. فنقل عائدية اليوم كان يُعيد كتابة
-- استحقاق أمسٍ عند أي إعادة حساب. الإصلاح: فترة صريحة تغطّي توقيت الحدث
-- نفسه تسود؛ وما لا تغطّيه فترة يبقى على نفس الاشتقاق القديم — فالأرقام
-- القائمة لا تتحرّك بحرف (الجدول فارغ اليوم إلا لما نُقل صراحةً).
--
-- LIVE-02. لا مكان في القاعدة يشتق نطاق العمولة من رقم الكابينة؛ الاشتقاق
-- القائم كله من fdts.zone اليدوي. القرار المعتمد الآن: نطاق العمولة
-- (وكيل/كابينة) محسوم برقم الكابينة 94–119 وحده — لا من التصنيف اليدوي،
-- ولا يُكتب فوقه. fdts.zone يبقى بيانات تشغيلية كما هي، ويُعرض كما كان في
-- عمود fdt_zone المنفصل. وحدها أعمدة النطاق المشتقّة (zone/scope_type/
-- scope_id) التي يقرأها محرّك الحساب تتبع الرقم الآن.
--
-- والأثر التابع: كابينة غير مسجَّلة خارج 94–119 لم تعد تُحجَب — نطاقها وكيل
-- بالتعريف، لا حاجة لتسجيلها لتحديد ذلك. وداخل 94–119 السجلّ نفسه هو
-- النطاق، فلا حالة «غير محسومة» تبقى ممكنة؛ UNKNOWN_FDT يسقط بلا بديل.
--
-- forward-only. لا صف مالي يُمَس، ولا دورة تُعاد حسابها هنا.

begin;

-- ---------------------------------------------------------------------------
-- 1. نطاق العمولة من رقم الكابينة وحده.
-- ---------------------------------------------------------------------------

create or replace function public.fdt_commission_scope(p_fdt_code text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select case
    when p_fdt_code ~ '^[0-9]+$' and p_fdt_code::integer between 94 and 119 then 'FDT'
    else 'AGENT'
  end;
$fn$;

revoke execute on function public.fdt_commission_scope(text) from public, anon;
grant execute on function public.fdt_commission_scope(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. عرض الاستحقاق: عائدية مؤرَّخة، ونطاق بالرقم.
-- ---------------------------------------------------------------------------

create or replace view public.commission_qualifying_events as
select
  e.saas_event_id,
  e.event_created_at,
  e.username_key,
  e.saas_user_id,
  e.profile_name as package_code,
  e.raw_parent,
  e.fdt_code,
  e.import_batch_id,
  coalesce(si.id::text, e.saas_user_id, e.username_key) as subscriber_key,
  si.id as subscriber_identity_id,
  si.identity_status,
  -- فترة صريحة تغطّي توقيت الحدث تسود؛ غيابها يُبقي الاشتقاق كما كان.
  coalesce(
    case eo.ownership_type
      when 'RESELLER' then 'RESELLER'
      when 'FTTH_USER' then 'DIRECT_COMPANY'
      when 'OFFICE' then 'DIRECT_COMPANY'
      when 'NEEDS_REVIEW' then 'UNKNOWN_PARENT'
    end,
    si.source_classification) as source_classification,
  coalesce(
    case when eo.ownership_type = 'RESELLER' then eo.agent_id end,
    si.effective_agent_id, al.agent_id) as effective_agent_id,
  ag.official_name as agent_name,
  f.zone as fdt_zone,
  case when public.fdt_commission_scope(e.fdt_code) = 'FDT' then 'new' else 'old' end as zone,
  public.fdt_commission_scope(e.fdt_code) as scope_type,
  case
    when public.fdt_commission_scope(e.fdt_code) = 'FDT' then e.fdt_code
    else coalesce(
      case when eo.ownership_type = 'RESELLER' then eo.agent_id end,
      si.effective_agent_id, al.agent_id)::text
  end as scope_id,
  p.semantic_category as package_category,
  al.resolution as parent_resolution
from public.saas_activation_events e
left join public.subscriber_identities si on si.username_key = e.username_key
left join public.agent_aliases al
  on al.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(e.raw_parent, '')))
 and al.active
left join lateral public.subscriber_ownership_at(e.username_key, e.event_created_at) eo on true
left join public.agents ag on ag.id = coalesce(
    case when eo.ownership_type = 'RESELLER' then eo.agent_id end,
    si.effective_agent_id, al.agent_id)
left join public.fdts f on f.code = e.fdt_code
left join public.packages p on p.code = e.profile_name
where coalesce(e.canceled, false) = false;

revoke all on table public.commission_qualifying_events from authenticated, anon, public;
grant select on table public.commission_qualifying_events to authenticated;

-- ---------------------------------------------------------------------------
-- 3. المحرّك: نفس الاشتقاقات للحدث الوارد وللإضافة اليدوية.
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

  v_from := public.cycle_window_start(v_cycle.period_start);
  v_to := public.cycle_window_end(v_cycle.period_end);

  drop table if exists tmp_cycle_events;
  drop table if exists tmp_billable;
  drop table if exists tmp_scope;
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

  -- الحدث المُضاف يمرّ بنفس الاشتقاقات: العائدية المؤرَّخة، ثم النطاق بالرقم.
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
    coalesce(
      case eo.ownership_type
        when 'RESELLER' then 'RESELLER'
        when 'FTTH_USER' then 'DIRECT_COMPANY'
        when 'OFFICE' then 'DIRECT_COMPANY'
        when 'NEEDS_REVIEW' then 'UNKNOWN_PARENT'
      end,
      si.source_classification),
    coalesce(
      case when eo.ownership_type = 'RESELLER' then eo.agent_id end,
      si.effective_agent_id, al.agent_id),
    ag.official_name,
    f.zone,
    case when public.fdt_commission_scope(c.fdt_code) = 'FDT' then 'new' else 'old' end,
    public.fdt_commission_scope(c.fdt_code),
    case
      when public.fdt_commission_scope(c.fdt_code) = 'FDT' then c.fdt_code
      else coalesce(
        case when eo.ownership_type = 'RESELLER' then eo.agent_id end,
        si.effective_agent_id, al.agent_id)::text
    end,
    p.semantic_category,
    al.resolution
  from public.activation_corrections c
  left join public.subscriber_identities si
    on si.username_key = lower(btrim(c.subscriber_username))
  left join public.agent_aliases al
    on al.alias_key = lower(btrim(coalesce(c.raw_parent, ''))) and al.active
  left join lateral public.subscriber_ownership_at(
    lower(btrim(c.subscriber_username)), c.event_at) eo on true
  left join public.agents ag on ag.id = coalesce(
      case when eo.ownership_type = 'RESELLER' then eo.agent_id end,
      si.effective_agent_id, al.agent_id)
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

  -- الأب المجهول: نطاق وكيل بلا وكيل محلول، وليس تابعاً للشركة عن عمد.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_AGENT',
         'the raw parent does not resolve to an agent', true
  from tmp_cycle_events t
  where t.scope_type = 'AGENT' and t.effective_agent_id is null
    and coalesce(t.source_classification, 'RESELLER') <> 'DIRECT_COMPANY'
    and coalesce(t.parent_resolution, 'needs_review') <> 'direct_company'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_AGENT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  -- لا UNKNOWN_FDT بعد اليوم: النطاق محسوم بالرقم وحده، فscope_id لنطاق
  -- الكابينة هو رقمها نفسه — لا يمكن أن يغيب. راجع LIVE-02 أعلاه.

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

commit;
