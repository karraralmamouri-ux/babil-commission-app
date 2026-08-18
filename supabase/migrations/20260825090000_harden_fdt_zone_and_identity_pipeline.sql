-- تقسية المنطقة، وبناء مسار الهوية المفقود.
--
-- (1) المنطقة. الكابينة غير المسجَّلة كانت تسقط إلى المنطقة القديمة بصمت:
--     case when f.zone = 'new' then 'new' else 'old' end
-- وغياب الصف من السجل يعطي NULL فيذهب إلى else. والمنطقة تُحدِّد نطاق الشريحة
-- (وكيل يجمع الآلاف، وكابينة تجمع العشرات)، فالسقوط الصامت يُعيد تسعير الحدث.
--
-- القياس على تموز: 2,977 من 7,520 حدثاً مُعمَّلاً على 92 كابينة غير مسجَّلة،
-- تحمل 15,116,500 من 37,059,000 — أي 40.8% مبنية على افتراض لم يخترْه أحد.
--
-- بعد هذا التغيير: كابينة مذكورة وغير مسجَّلة ⇒ منطقة «غير محسومة»، فلا نطاق
-- ولا عمولة، ويُرفع استثناء حاجب. وغيابُ الكابينة أصلاً يبقى منطقةً قديمة —
-- وهي الحالة المشروعة: لا طوبولوجيا يعني تسعيراً بالوكيل.
--
-- (2) الهوية. subscriber_identities فارغ في الإنتاج لأن مسار التعبئة لم يُكتب
--     قط: الجداول والدوال النقية موجودة، ولا RPC يكتب فيها. تُبنى هنا.
--
-- forward-only. لا صف مالي يُمَس، ولا دفعة تُنشأ، ولا تاريخ يُعاد بناؤه.

begin;

-- ---------------------------------------------------------------------------
-- 1. المنطقة لا تُخمَّن.
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
  si.source_classification,
  coalesce(si.effective_agent_id, al.agent_id) as effective_agent_id,
  ag.official_name as agent_name,
  f.zone as fdt_zone,
  -- كابينة مذكورة وغير مسجَّلة: منطقتها غير محسومة، ولا تُفترض قديمة.
  case
    when e.fdt_code is not null and f.code is null then 'unresolved'
    when f.zone = 'new' then 'new'
    else 'old'
  end as zone,
  case
    when e.fdt_code is not null and f.code is null then 'UNRESOLVED'
    when f.zone = 'new' then 'FDT'
    else 'AGENT'
  end as scope_type,
  -- بلا نطاق ⇒ لا يدخل الحساب أصلاً.
  case
    when e.fdt_code is not null and f.code is null then null
    when f.zone = 'new' then e.fdt_code
    else coalesce(si.effective_agent_id, al.agent_id)::text
  end as scope_id,
  p.semantic_category as package_category,
  al.resolution as parent_resolution
from public.saas_activation_events e
left join public.subscriber_identities si on si.username_key = e.username_key
left join public.agent_aliases al
  on al.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(e.raw_parent, '')))
 and al.active
left join public.agents ag on ag.id = coalesce(si.effective_agent_id, al.agent_id)
left join public.fdts f on f.code = e.fdt_code
left join public.packages p on p.code = e.profile_name
where coalesce(e.canceled, false) = false;

revoke all on table public.commission_qualifying_events from authenticated, anon, public;
grant select on table public.commission_qualifying_events to authenticated;

-- ---------------------------------------------------------------------------
-- 2. مسار الهوية — يُبنى الآن لأنه لم يُكتب قط.
--
-- الهوية من معرّف SaaS المستقر. اسم المستخدم دليل ثانوي مضبوط، والاسم المعروض
-- لا يدخل إطلاقاً. لا أثر مالي: صفوف هوية ودليل فقط.
-- ---------------------------------------------------------------------------

create or replace function public.bootstrap_subscriber_identities()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created integer := 0;
  v_matched integer := 0;
  v_conflicts integer := 0;
begin
  -- أحدث لقطة لكل معرّف SaaS. اللقطات غير قابلة للتعديل، فالأحدث هو الحاضر.
  with latest as (
    select distinct on (s.saas_user_id)
      s.saas_user_id, s.username, s.username_key, s.parent_name,
      s.fdt_code, s.fat_code, s.port_code
    from public.saas_user_snapshots s
    order by s.saas_user_id, s.snapshot_at desc, s.created_at desc
  ),
  -- اسم مستخدم يقود إلى أكثر من مشترك تاريخي: تعارض يُعلَن ولا يُرجَّح.
  registry as (
    select pg_catalog.lower(pg_catalog.btrim(sub.subscriber_id)) as key,
           count(*) as hits, min(sub.id) as one
    from public.installation_subscribers sub
    group by 1
  )
  insert into public.subscriber_identities (
    installation_subscriber_id, saas_user_id, username, display_name,
    identity_status, match_method, match_evidence,
    source_classification, raw_parent, normalized_agent_id, effective_agent_id,
    fdt_code, fat_code, port_code
  )
  select
    case when r.hits = 1 then r.one else null end,
    l.saas_user_id,
    l.username,
    null,
    case
      when r.hits > 1 then 'CONFLICT'
      when r.hits = 1 then 'MATCHED'
      else 'UNMATCHED'
    end,
    case when r.hits = 1 then 'EXACT_USERNAME' else null end,
    jsonb_build_object('saas_user_id', l.saas_user_id, 'username_key', l.username_key,
                       'registry_hits', coalesce(r.hits, 0)),
    case
      when al.resolution = 'direct_company' then 'DIRECT_COMPANY'
      when al.agent_id is not null then 'RESELLER'
      else 'UNKNOWN_PARENT'
    end,
    l.parent_name,
    al.agent_id,
    al.agent_id,
    l.fdt_code, l.fat_code, l.port_code
  from latest l
  left join registry r on r.key = l.username_key
  left join public.agent_aliases al
    on al.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(l.parent_name, '')))
   and al.active
  on conflict (saas_user_id) do nothing;

  get diagnostics v_created = row_count;
  select count(*) filter (where identity_status = 'MATCHED'),
         count(*) filter (where identity_status = 'CONFLICT')
  into v_matched, v_conflicts
  from public.subscriber_identities;

  return jsonb_build_object(
    'identities_created', v_created,
    'identities_total', (select count(*) from public.subscriber_identities),
    'matched_to_registry', v_matched,
    'conflicts', v_conflicts,
    'unmatched', (select count(*) from public.subscriber_identities
                  where identity_status = 'UNMATCHED'),
    'direct_company', (select count(*) from public.subscriber_identities
                       where source_classification = 'DIRECT_COMPANY'),
    'unknown_parent', (select count(*) from public.subscriber_identities
                       where source_classification = 'UNKNOWN_PARENT')
  );
end;
$$;

revoke execute on function public.bootstrap_subscriber_identities()
  from public, anon, authenticated;

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
as $$
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

  drop table if exists tmp_cycle_events;
  drop table if exists tmp_billable;
  drop table if exists tmp_scope;
  create temporary table tmp_cycle_events on commit drop as
  select q.*
  from public.commission_qualifying_events q
  where q.event_created_at >= v_cycle.period_start
    and q.event_created_at < (v_cycle.period_end + 1);

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
    'blocking_exceptions', v_blocking
  );
end;
$$;

revoke execute on function public.calculate_commission_cycle(uuid, boolean, uuid, text)
  from public, anon;
grant execute on function public.calculate_commission_cycle(uuid, boolean, uuid, text)
  to authenticated;

commit;
