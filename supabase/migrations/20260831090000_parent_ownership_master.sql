-- عائدية الأب: تصنيفٌ لا إعادةُ تسمية.
--
-- تصحيح لما بنيتُه في المرحلة السابقة. كنت قد جعلت FTTH_USER وOFFICE نوعَي
-- عائدية ماليَّين، وعرضتُ «FTTH User» مكان اسم الأب الأصلي. وهذا خطأ من وجهين:
--
--   ١. الاسم الأصلي هو الدليل. المشغّل يبحث في ملف SaaS عن `hrins.office`،
--      فإن عرضنا له «Office» فقد الجسر بين الشاشة والمصدر. الاسم لا يُترجَم
--      ولا يُوحَّد ولا يُجمَّل — يُعرض كما وصل.
--
--   ٢. التصنيف المالي ثلاثة لا خمسة:
--        RESELLER        تابع لوكيل
--        DIRECT_COMPANY  تابع للشركة مباشرةً
--        NEEDS_REVIEW    لم يُحسم بعد
--      و«FTTH» و«Office» ليسا صنفَين ماليَّين بل اسمان لآباء يقعان تحت
--      DIRECT_COMPANY. جعلُهما صنفَين يعني أن كل أبٍ شركاتيّ جديد يحتاج
--      نشرَ واجهة — وهذا ليس تصميماً بل عائق.
--
-- ما يبقى ثابتاً: القاعدة المالية DIRECT_COMPANY نفسها لم تتغيّر حرفاً. لا
-- عمولة، ولا مساهمة في شريحة، ولا استثناء «وكيل مجهول».
--
-- الآباء الفعليون في الإنتاج، مُحصَون لا مُقدَّرين: 61 أباً — 37 مربوطاً
-- بوكيل، واثنان شركةً، و22 بلا قرار.

begin;

-- ---------------------------------------------------------------------------
-- 1. التصنيف الثلاثي
--
-- القيم القديمة تُقبَل وتُترجَم، فلا ينكسر صفٌّ قائم. الجديد يُكتَب بالثلاثة.
-- ---------------------------------------------------------------------------

create or replace function public.normalize_ownership_type(p_type text)
returns text language sql immutable set search_path = ''
as $fn$
  select case upper(coalesce(p_type, ''))
    when 'RESELLER' then 'RESELLER'
    when 'DIRECT_COMPANY' then 'DIRECT_COMPANY'
    -- توافق خلفي: نوعان سابقان كانا تحت الشركة المباشرة.
    when 'FTTH_USER' then 'DIRECT_COMPANY'
    when 'OFFICE' then 'DIRECT_COMPANY'
    else 'NEEDS_REVIEW' end;
$fn$;

grant execute on function public.normalize_ownership_type(text) to authenticated;

update public.subscriber_ownership
set ownership_type = public.normalize_ownership_type(ownership_type)
where ownership_type not in ('RESELLER', 'DIRECT_COMPANY', 'NEEDS_REVIEW');

alter table public.subscriber_ownership
  drop constraint if exists subscriber_ownership_type_check;
alter table public.subscriber_ownership
  add constraint subscriber_ownership_type_check
  check (ownership_type in ('RESELLER', 'DIRECT_COMPANY', 'NEEDS_REVIEW'));

-- الأب الشركاتي يُذكر عند النقل إلى الشركة، فيبقى معروفاً بأيّ اسم انتقل.
alter table public.subscriber_ownership
  add column if not exists company_parent text;

alter table public.subscriber_ownership
  drop constraint if exists subscriber_ownership_agent_shape;
alter table public.subscriber_ownership
  add constraint subscriber_ownership_agent_shape
  check ((ownership_type = 'RESELLER' and agent_id is not null and company_parent is null)
      or (ownership_type = 'DIRECT_COMPANY' and agent_id is null)
      or (ownership_type = 'NEEDS_REVIEW' and agent_id is null and company_parent is null));

-- ---------------------------------------------------------------------------
-- 2. عائدية الأب — التصنيف وحده، والاسم كما هو
-- ---------------------------------------------------------------------------

alter table public.agent_aliases drop constraint if exists agent_aliases_resolution_check;
alter table public.agent_aliases add constraint agent_aliases_resolution_check
  check (resolution in ('mapped', 'direct_company', 'office', 'needs_review'));

create or replace function public.parent_ownership_type(p_raw_parent text)
returns text
language sql stable set search_path = ''
as $fn$
  -- 'office' القديمة تُقرأ شركةً مباشرة: هي اسمُ أبٍ لا صنفٌ مالي.
  select coalesce(
    (select case
       when al.agent_id is not null then 'RESELLER'
       when al.resolution in ('direct_company', 'office') then 'DIRECT_COMPANY'
       else 'NEEDS_REVIEW' end
     from public.agent_aliases al
     where al.alias_key = lower(btrim(coalesce(p_raw_parent, '')))
       and al.active
     limit 1),
    'NEEDS_REVIEW');
$fn$;

grant execute on function public.parent_ownership_type(text) to authenticated;

create or replace function public.subscriber_ownership_type(p_subscriber_id text)
returns text
language sql stable set search_path = ''
as $fn$
  select coalesce(
    (select public.normalize_ownership_type(o.ownership_type)
     from public.subscriber_ownership o
     join public.installation_subscribers s on s.subscriber_key = o.username_key
     where s.subscriber_id = p_subscriber_id
       and o.effective_from <= now()
       and (o.effective_to is null or o.effective_to > now())
     order by o.effective_from desc limit 1),
    (select case
       when si.source_classification = 'DIRECT_COMPANY' then 'DIRECT_COMPANY'
       when si.source_classification = 'RESELLER' then 'RESELLER'
       else 'NEEDS_REVIEW' end
     from public.subscriber_identities si
     join public.installation_subscribers s2 on s2.subscriber_key = si.username_key
     where s2.subscriber_id = p_subscriber_id limit 1),
    'NEEDS_REVIEW');
$fn$;

grant execute on function public.subscriber_ownership_type(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. سجلّ الآباء — البيانات الرئيسية
--
-- الاسم الأصلي عمودٌ أول، والتصنيف عمودٌ بجانبه. لا يحلّ أحدهما محلّ الآخر.
-- ---------------------------------------------------------------------------

create or replace function public.list_parents(
  p_ownership text default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('agent.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with parents as (
    select
      e.raw_parent as parent_name,
      count(*)::bigint as events,
      count(distinct e.username_key)::bigint as subscribers,
      min(e.event_created_at) as first_seen,
      max(e.event_created_at) as last_seen
    from public.saas_activation_events e
    where e.raw_parent is not null and btrim(e.raw_parent) <> ''
      and coalesce(e.canceled, false) = false
    group by e.raw_parent
  ),
  classified as (
    select p.*,
      public.parent_ownership_type(p.parent_name) as ownership,
      al.agent_id,
      ag.official_name as agent_name,
      ag.code as agent_code,
      (al.id is not null) as has_alias
    from parents p
    left join public.agent_aliases al
      on al.alias_key = lower(btrim(p.parent_name)) and al.active
    left join public.agents ag on ag.id = al.agent_id
  ),
  kept as (
    select * from classified c
    where (p_ownership is null or c.ownership = p_ownership)
      and (p_search is null or c.parent_name ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.parent_name, k.ownership, k.agent_id, k.agent_name, k.agent_code,
             k.has_alias, k.events, k.subscribers, k.first_seen, k.last_seen
      from kept k
      order by k.subscribers desc, k.parent_name
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.list_parents(text,text,integer,integer) from public, anon;
grant execute on function public.list_parents(text,text,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. تصنيف أبٍ — قرار إداري مُدقَّق
--
-- ثلاثة قرارات فقط. والاسم لا يتغيّر في أيٍّ منها.
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

  -- تكرار الطلب نفسه لا يُنتج أثراً ثانياً.
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

  -- الاسم يُخزَّن كما ورد. alias_key مشتقّ للمطابقة فقط.
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

  return jsonb_build_object(
    'parent', p_parent_name,
    'ownership_before', v_before,
    'ownership_after', p_ownership,
    'idempotent', false);
end;
$fn$;

revoke execute on function public.classify_parent(text,text,uuid,text,uuid) from public, anon;
grant execute on function public.classify_parent(text,text,uuid,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. مشتركو الشركة — تفصيل بالأسماء الحقيقية
--
-- لا أسماء مثبَّتة في الواجهة. أبٌ شركاتيّ جديد يظهر تلقائياً بلا نشر.
-- ---------------------------------------------------------------------------

create or replace function public.company_parent_breakdown()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v jsonb; v_total bigint;
begin
  perform public.require_capability('subscriber.view');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.subscribers desc), '[]'::jsonb)
  into v
  from (
    select e.raw_parent as parent_name,
           count(distinct e.username_key)::bigint as subscribers,
           count(*)::bigint as events
    from public.saas_activation_events e
    where coalesce(e.canceled, false) = false
      and e.raw_parent is not null
      and public.parent_ownership_type(e.raw_parent) = 'DIRECT_COMPANY'
    group by e.raw_parent) x;

  -- الإجمالي مشتركون متمايزون لا مجموع الصفوف.
  --
  -- الجمع كان يعدّ المشترك مرّتين حين يظهر تحت اسمَي أبٍ (مثل TTH_Users في
  -- أيار وFTTH_Users في تموز — وهما الاسم نفسه فقد حرفاً في تصدير أيار).
  -- فكان التفصيل يقول 26,371 والعدّاد يقول 15,978 عن الشيء نفسه، ورقمان
  -- متعارضان عن شيء واحد أسوأ من رقم خاطئ.
  select count(distinct e.username_key) into v_total
  from public.saas_activation_events e
  where coalesce(e.canceled, false) = false
    and e.raw_parent is not null
    and public.parent_ownership_type(e.raw_parent) = 'DIRECT_COMPANY';

  return jsonb_build_object('total_subscribers', v_total, 'parents', v);
end;
$fn$;

revoke execute on function public.company_parent_breakdown() from public, anon;
grant execute on function public.company_parent_breakdown() to authenticated;

create or replace function public.company_subscriber_counts()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v jsonb;
begin
  perform public.require_capability('subscriber.view');
  select jsonb_object_agg(t, n) into v from (
    select public.parent_ownership_type(e.raw_parent) as t,
           count(distinct e.username_key) as n
    from public.saas_activation_events e
    where coalesce(e.canceled, false) = false
    group by 1) x;
  return coalesce(v, '{}'::jsonb);
end;
$fn$;

revoke execute on function public.company_subscriber_counts() from public, anon;
grant execute on function public.company_subscriber_counts() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. عرض العائدية للحدث — الاسم الأصلي محفوظ
-- ---------------------------------------------------------------------------

create or replace view public.subscriber_event_ownership as
select
  q.saas_event_id,
  q.username_key,
  q.event_created_at,
  q.raw_parent,
  q.effective_agent_id,
  q.source_classification,
  coalesce(
    (select public.normalize_ownership_type(ownership_type)
     from public.subscriber_ownership_at(q.username_key, q.event_created_at)),
    public.parent_ownership_type(q.raw_parent),
    'NEEDS_REVIEW') as ownership_type,
  coalesce(
    (select agent_id from public.subscriber_ownership_at(q.username_key, q.event_created_at)),
    q.effective_agent_id) as owning_agent_id
from public.commission_qualifying_events q;

revoke all on public.subscriber_event_ownership from public, anon;
grant select on public.subscriber_event_ownership to authenticated;

commit;
