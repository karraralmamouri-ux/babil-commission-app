-- ---------------------------------------------------------------------------
-- شواهد الأب — ما يحتاجه القرار قبل أن يُتَّخذ
--
-- تصنيفُ أبٍ قرارٌ ماليّ: يقرّر من يستحق العمولة ومن لا يستحق. وقد كان
-- يُتَّخذ حتى الآن بلا شاشة تعرض على أيّ أساس يُتَّخذ. هذه الدالة تجمع
-- الأساس: الحجم، والباقات، والمبلغ المؤشِّر في الدورة المفتوحة، وعيّنة من
-- الصفوف كما وردت من المصدر.
--
-- والشاهد الأقوى ليس تشابه الأسماء بل تداخل المشتركين: «hrins.office» يشترك
-- مع «hrins.oice» في 34 مشتركاً حقيقياً، و«FTTH_Users» مع «TTH_Users» في
-- 10,393. هذه واقعةٌ في البيانات لا تخمينٌ على الحروف. تُعرض شاهداً
-- للمشغّل — ولا يُصنَّف شيء تلقائياً بناءً عليها.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.parent_evidence(p_parent_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key    text := lower(btrim(coalesce(p_parent_name, '')));
  v_exact  text;
  v_cid    uuid;
  v_cname  text;
  v_cstat  text;
  v_cstart date;
  v_cend   date;
  v_own    text;
  v_doc    jsonb;
begin
  perform public.require_capability('agent.view');

  if v_key = '' then
    raise exception 'Parent name is required' using errcode = '22023';
  end if;

  -- المطابقة بالمفتاح، والعرض بالاسم الأصلي كما ورد. لا تسمية بديلة.
  select e.raw_parent into v_exact
  from public.saas_activation_events e
  where lower(btrim(e.raw_parent)) = v_key
  order by e.event_created_at desc
  limit 1;

  -- أبٌ صُنِّف قبل أن تصله أحداث يبقى قابلاً للفتح.
  if v_exact is null then
    select al.alias into v_exact
    from public.agent_aliases al
    where al.alias_key = v_key
    limit 1;
  end if;

  if v_exact is null then
    return jsonb_build_object('found', false, 'parent_name', p_parent_name);
  end if;

  select c.id, c.name, c.status, c.period_start, c.period_end
    into v_cid, v_cname, v_cstat, v_cstart, v_cend
  from public.commission_cycles c
  order by c.period_start desc
  limit 1;

  v_own := public.parent_ownership_type(v_exact);

  select jsonb_build_object(
    'found', true,
    'parent_name', v_exact,
    'alias_key', v_key,
    'ownership', v_own,

    'classification', (
      select jsonb_build_object(
        'has_alias', true,
        'resolution', al.resolution,
        'agent_id', al.agent_id,
        'agent_name', ag.official_name,
        'agent_code', ag.code,
        'notes', al.notes,
        'updated_at', al.updated_at)
      from public.agent_aliases al
      left join public.agents ag on ag.id = al.agent_id
      where al.alias_key = v_key and al.active
      limit 1),

    'volume', (
      select jsonb_build_object(
        'events', count(*),
        'subscribers', count(distinct e.username_key),
        'canceled_events', count(*) filter (where coalesce(e.canceled, false)),
        'first_seen', min(e.event_created_at),
        'last_seen', max(e.event_created_at))
      from public.saas_activation_events e
      where lower(btrim(e.raw_parent)) = v_key),

    'packages', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select e.profile_name as package, count(*)::bigint as events,
               count(distinct e.username_key)::bigint as subscribers
        from public.saas_activation_events e
        where lower(btrim(e.raw_parent)) = v_key
          and coalesce(e.canceled, false) = false
        group by e.profile_name
        order by 2 desc
        limit 12) x), '[]'::jsonb),

    -- التعرّض المالي في الدورة المفتوحة. مؤشِّرٌ لا مستحق: يقول كم من المال
    -- ينتظر هذا القرار، لا كم يُصرف.
    'exposure', (
      with rates as (
        select r.package_code, r.rate from public.indicative_rates(v_cid) r
      )
      select jsonb_build_object(
        'cycle_id', v_cid,
        'cycle_name', v_cname,
        'cycle_status', v_cstat,
        'events', count(*),
        'subscribers', count(distinct e.username_key),
        'indicative_amount', coalesce(sum(coalesce(rt.rate, 0)), 0),
        -- المعنى يختلف بالتصنيف، فيُقال صراحةً بدل أن يُخمَّن في الواجهة.
        'meaning', case v_own
          when 'NEEDS_REVIEW'   then 'AWAITING_DECISION'
          when 'DIRECT_COMPANY' then 'NO_RESELLER_COMMISSION'
          else 'AGENT_BASIS' end)
      from public.saas_activation_events e
      left join rates rt on rt.package_code = e.profile_name
      where lower(btrim(e.raw_parent)) = v_key
        and coalesce(e.canceled, false) = false
        and v_cid is not null
        and e.event_created_at >= public.cycle_window_start(v_cstart)
        and e.event_created_at <  public.cycle_window_end(v_cend)),

    -- آباء يتقاسمون مشتركين حقيقيين مع هذا الأب.
    'related_parents', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        with mine as (
          select distinct e.username_key as u
          from public.saas_activation_events e
          where lower(btrim(e.raw_parent)) = v_key
            and coalesce(e.canceled, false) = false
        )
        select o.raw_parent as parent_name,
               count(distinct o.username_key)::bigint as shared_subscribers,
               public.parent_ownership_type(o.raw_parent) as ownership
        from public.saas_activation_events o
        join mine m on m.u = o.username_key
        where o.raw_parent is not null
          and lower(btrim(o.raw_parent)) <> v_key
          and coalesce(o.canceled, false) = false
        group by o.raw_parent
        order by 2 desc
        limit 10) x), '[]'::jsonb),

    -- عيّنة خام: ما كُتب في المصدر، بالورقة والسطر، ليُراجَع عند الشك.
    'samples', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select e.username, e.username_key, e.profile_name, e.event_created_at,
               e.fdt_code, e.group_name, e.source_sheet, e.source_row,
               e.raw_parent, e.canceled
        from public.saas_activation_events e
        where lower(btrim(e.raw_parent)) = v_key
        order by e.event_created_at desc
        limit 10) x), '[]'::jsonb),

    'audit', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select a.created_at, a.old_value, a.new_value, a.extra, u.email as actor_email
        from public.audit_logs a
        left join public.profiles u on u.id = a.actor_id
        where a.action = 'master.parent.classified'
          and a.extra like 'parent=' || v_exact || '%'
        order by a.created_at desc
        limit 10) x), '[]'::jsonb)
  ) into v_doc;

  return v_doc;
end;
$fn$;

revoke execute on function public.parent_evidence(text) from public, anon;
grant execute on function public.parent_evidence(text) to authenticated;

-- ---------------------------------------------------------------------------
-- قائمة الوكلاء للاختيار — قرار «ربط بوكيل» يحتاج وكيلاً حقيقياً
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
      and a.status = 'ACTIVE'
      and (p_search is null or btrim(p_search) = ''
           or a.official_name ilike '%' || p_search || '%'
           or a.code ilike '%' || p_search || '%')
    order by a.official_name
    limit public.page_limit(p_limit)) x;
$fn$;

revoke execute on function public.list_agents_for_pick(text,integer) from public, anon;
grant execute on function public.list_agents_for_pick(text,integer) to authenticated;

-- الشاهد يُقرأ بالمفتاح المشتق في كل استدعاء.
create index if not exists saas_events_parent_key_idx
  on public.saas_activation_events (lower(btrim(raw_parent)));

commit;
