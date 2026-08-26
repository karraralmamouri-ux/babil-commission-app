-- LIVE-03 (PR-B3): قرارٌ يُحسَم لا يُعيد كتابة المال بصمت.
--
-- classify_parent كان يكتب اسم البديل ويُدقِّق، وينتهي هناك. أي دورة تستعمل
-- ذلك الاسم تبقى كما حُسبت آخر مرة — لا خطأ ولا تنبيه، حتى يتذكّر أحدٌ أن
-- يُعيد الحساب يدوياً. فالفجوة ليست في المال؛ هي في الوضوح: لا شيء يقول إن
-- الدورة صارت غير موثوقة.
--
-- الإصلاح الأدنى: علمٌ صريح على الدورة نفسها. القرار يُعلِم، لا يُعيد الحساب.
-- وإعادة الحساب تبقى فعلاً صريحاً منفصلاً — كما كانت أصلاً لتصنيف الكابينة
-- (recalculate_cycle_after_master_change) — يُطفئ العلم عند نجاحه فقط.
--
-- لا محرّك تصحيح مالي عام يُبنى هنا: الدورة المنتهية أو المدفوعة تبقى خارج
-- هذا الباب تماماً كما كانت، والتصحيح هناك أداته المنفصلة القائمة.

begin;

alter table public.commission_cycles
  add column if not exists needs_recalculation boolean not null default false,
  add column if not exists recalculation_reason text,
  add column if not exists recalculation_flagged_at timestamptz,
  add column if not exists recalculation_flagged_by uuid references public.profiles(id),
  add column if not exists recalculation_request_id uuid;

-- ---------------------------------------------------------------------------
-- 1. وسم الدورات المتأثّرة باسم أبٍ أُعيد تصنيفه.
--
-- المتأثّرة: دورةٌ لم تُنهَ ولم تُدفع، وتحوي حدثاً مؤهَّلاً بهذا الاسم داخل
-- نافذتها. الأداء غير مقصود هنا — عدد القرارات صغيرٌ مقارنةً بالأحداث.
-- ---------------------------------------------------------------------------

create or replace function public.flag_cycles_needs_recalculation_for_parent(
  p_raw_parent text, p_reason text, p_actor uuid, p_request_id uuid
) returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_key text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_raw_parent, '')));
  v_n integer;
begin
  if v_key = '' then
    return 0;
  end if;

  update public.commission_cycles c
  set needs_recalculation = true,
      recalculation_reason = p_reason,
      recalculation_flagged_at = now(),
      recalculation_flagged_by = p_actor,
      recalculation_request_id = p_request_id
  where c.engine_version = 'VNEXT'
    and c.status not in ('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED')
    and exists (
      select 1
      from public.saas_activation_events e
      where pg_catalog.lower(pg_catalog.btrim(coalesce(e.raw_parent, ''))) = v_key
        and coalesce(e.canceled, false) = false
        and e.event_created_at >= public.cycle_window_start(c.period_start)
        and e.event_created_at < public.cycle_window_end(c.period_end));
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;

revoke execute on function public.flag_cycles_needs_recalculation_for_parent(text, text, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. classify_parent يُعلِم، لا يُعيد الحساب.
-- ---------------------------------------------------------------------------

create or replace function public.classify_parent(
  p_parent_name text,
  p_ownership text,
  p_agent_id uuid default null,
  p_reason text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_key text := lower(btrim(coalesce(p_parent_name, '')));
  v_before text;
  v_resolution text;
  v_flagged integer := 0;
begin
  perform public.require_capability('agent.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if v_key = '' then
    raise exception 'Parent name is required' using errcode = '22023';
  end if;
  if p_ownership not in ('RESELLER', 'DIRECT_COMPANY', 'NEEDS_REVIEW') then
    raise exception 'Ownership must be RESELLER, DIRECT_COMPANY or NEEDS_REVIEW'
      using errcode = '22023';
  end if;
  if p_ownership = 'RESELLER' and p_agent_id is null then
    raise exception 'A reseller classification needs an agent' using errcode = '22023';
  end if;
  if p_ownership <> 'RESELLER' and p_agent_id is not null then
    raise exception 'Only a reseller classification carries an agent' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'master.parent.classified') then
    return jsonb_build_object('parent', p_parent_name, 'idempotent', true);
  end if;

  perform pg_advisory_xact_lock(hashtext('parent:' || v_key));

  v_before := public.parent_ownership_type(p_parent_name);

  v_resolution := case p_ownership
    when 'RESELLER' then 'mapped'
    when 'DIRECT_COMPANY' then 'direct_company'
    else 'needs_review' end;

  insert into public.agent_aliases (agent_id, alias, resolution, active)
  values (p_agent_id, p_parent_name, v_resolution, true)
  on conflict (alias_key) do update
    set agent_id = excluded.agent_id,
        resolution = excluded.resolution,
        active = true;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'master.parent.classified', 'ownership', v_before, p_ownership,
    'agent_alias', p_request_id,
    'parent=' || p_parent_name
    || coalesce(' agent=' || p_agent_id::text, '')
    || coalesce(' reason=' || nullif(btrim(coalesce(p_reason, '')), ''), ''));

  -- العلم بعد التدقيق، لا قبله: فشلٌ في الوسم لا يُسقط قراراً موثَّقاً بالفعل.
  if v_before is distinct from p_ownership then
    v_flagged := public.flag_cycles_needs_recalculation_for_parent(
      p_parent_name,
      'الأب "' || p_parent_name || '" أُعيد تصنيفه من ' || coalesce(v_before, '؟')
        || ' إلى ' || p_ownership,
      v_actor, p_request_id);
  end if;

  return jsonb_build_object(
    'parent', p_parent_name,
    'ownership_before', v_before,
    'ownership_after', p_ownership,
    'cycles_flagged_for_recalculation', v_flagged,
    'idempotent', false);
end;
$fn$;

revoke execute on function public.classify_parent(text,text,uuid,text,uuid) from public, anon;
grant execute on function public.classify_parent(text,text,uuid,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. إعادة الحساب المُخوَّلة تُطفئ العلم عند نجاحها فقط.
-- ---------------------------------------------------------------------------

create or replace function public.recalculate_cycle_after_master_change(
  p_cycle_id uuid, p_request_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_before_gross bigint;
  v_before_blocking integer;
  v_result jsonb;
  v_after_blocking integer;
begin
  perform public.require_capability('fdt.manage');

  select * into v_cycle from public.commission_cycles where id = p_cycle_id;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  if v_cycle.status in ('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED') then
    raise exception
      'This cycle is finalized or paid; master-data changes cannot rewrite it. Use correction instead'
      using errcode = '42501';
  end if;

  select coalesce(sum(gross_commission), 0) into v_before_gross
  from public.commission_cycle_snapshots where cycle_id = p_cycle_id;
  select count(*) into v_before_blocking from public.commission_exceptions
  where cycle_id = p_cycle_id and status = 'OPEN' and blocks_finalization;

  v_result := public.calculate_commission_cycle(p_cycle_id, false);

  select count(*) into v_after_blocking from public.commission_exceptions
  where cycle_id = p_cycle_id and status = 'OPEN' and blocks_finalization;

  update public.commission_cycles
  set needs_recalculation = false,
      recalculation_reason = null,
      recalculation_flagged_at = null,
      recalculation_flagged_by = null,
      recalculation_request_id = null
  where id = p_cycle_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra
  ) values (
    v_actor, 'commission.cycle.recalculated', 'gross_commission',
    v_before_gross::text, (v_result ->> 'gross_commission'),
    'commission_cycle', p_cycle_id, p_request_id,
    'blocking ' || v_before_blocking::text || ' -> ' || v_after_blocking::text
    || ' (after master data change)'
    || coalesce(' reason=' || nullif(btrim(coalesce(p_reason, '')), ''), '')
  );

  return jsonb_build_object(
    'cycle_id', p_cycle_id,
    'gross_before', v_before_gross,
    'gross_after', (v_result ->> 'gross_commission')::bigint,
    'blocking_before', v_before_blocking,
    'blocking_after', v_after_blocking,
    'calculation', v_result
  );
end;
$fn$;

revoke execute on function public.recalculate_cycle_after_master_change(uuid, uuid, text)
  from public, anon;
grant execute on function public.recalculate_cycle_after_master_change(uuid, uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. الشاشة ترى العلم: commission_cycle_result يحمله كما يحمل الحالة.
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
      'closed_at', v_cycle.closed_at,
      'needs_recalculation', v_cycle.needs_recalculation,
      'recalculation_reason', v_cycle.recalculation_reason,
      'recalculation_flagged_at', v_cycle.recalculation_flagged_at),

    'totals', (
      select jsonb_build_object(
        'gross', coalesce(sum(s.gross_commission), 0),
        'scopes', count(*),
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
