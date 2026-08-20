-- ---------------------------------------------------------------------------
-- كتابات البيانات الرئيسية وإدارة المستخدمين
--
-- آخر ما كان يُكتب من الشاشات السابقة وحدها. الجداول مقروءة عبر PostgREST
-- ومغلقة للكتابة، وهذا صحيح: الكتابة تمرّ بدوالّ تفحص القدرة وتُسجّل الأثر.
--
-- وقواعد المال المنشورة لا تُعدَّل هنا. نسخة المخطّط المنشورة تبقى كما هي،
-- والتغيير يكون بنسخةٍ جديدة — تعديل قاعدةٍ منشورة يُعيد كتابة ما حُسب بها.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. الوكلاء
-- ---------------------------------------------------------------------------

create or replace function public.upsert_agent(
  p_code text,
  p_official_name text,
  p_status text default 'active',
  p_zone text default null,
  p_notes text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_before text;
begin
  perform public.require_capability('agent.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_code, '')) = '' then
    raise exception 'An agent code is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_official_name, '')) = '' then
    raise exception 'An agent name is required' using errcode = '22023';
  end if;
  -- القيم المقبولة هنا نسخةٌ من قيد الجدول، والقيد هو المرجع لا هذه القائمة.
  -- الغرض من تكرارها رسالةٌ مفهومة قبل أن يصطدم المستخدم بالقيد؛ ويحرس
  -- تطابقهما اختبار master-write-domains.sql.
  if p_status not in ('active', 'inactive') then
    raise exception 'Status must be active or inactive' using errcode = '22023';
  end if;
  if p_zone is not null and btrim(p_zone) <> ''
     and btrim(p_zone) not in ('old', 'new', 'both', 'direct') then
    raise exception 'Zone must be old, new, both or direct' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'master.agent.saved') then
    return jsonb_build_object('code', p_code, 'idempotent', true);
  end if;

  select id, official_name into v_id, v_before
  from public.agents where code = btrim(p_code);

  if v_id is null then
    insert into public.agents (code, official_name, status, zone, notes, created_by)
    values (btrim(p_code), btrim(p_official_name), p_status,
            nullif(btrim(coalesce(p_zone, '')), ''),
            nullif(btrim(coalesce(p_notes, '')), ''), v_actor)
    returning id into v_id;
    v_before := 'NONE';
  else
    update public.agents
    set official_name = btrim(p_official_name),
        status = p_status,
        zone = nullif(btrim(coalesce(p_zone, '')), ''),
        notes = nullif(btrim(coalesce(p_notes, '')), ''),
        updated_by = v_actor,
        updated_at = now()
    where id = v_id;
  end if;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'master.agent.saved', 'official_name', v_before, btrim(p_official_name),
    'agent', v_id, p_request_id,
    'code=' || btrim(p_code) || ' status=' || p_status);

  return jsonb_build_object('agent_id', v_id, 'code', btrim(p_code), 'idempotent', false);
end;
$fn$;

revoke execute on function public.upsert_agent(text,text,text,text,text,uuid) from public, anon;
grant execute on function public.upsert_agent(text,text,text,text,text,uuid) to authenticated;

create or replace function public.page_agents(
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('agent.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select a.id, a.code, a.official_name, a.status, a.zone, a.notes,
           a.created_at, a.updated_at,
           (select count(*) from public.agent_aliases al
            where al.agent_id = a.id and al.active) as aliases,
           (select count(*) from public.fdts f where f.agent_id = a.id) as cabinets,
           (select count(*) from public.subscriber_ownership o
            where o.agent_id = a.id and o.effective_to is null) as subscribers
    from public.agents a
    where (p_status is null or a.status = p_status)
      and (p_search is null or btrim(p_search) = ''
           or a.code ilike '%' || p_search || '%'
           or a.official_name ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.official_name
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_agents(text,text,integer,integer) from public, anon;
grant execute on function public.page_agents(text,text,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. الباقات
--
-- تصنيف الباقة يقرّر أهي حدثٌ مدفوع مؤهِّل أم لا، فهو مُدخَل مالي.
-- ---------------------------------------------------------------------------

create or replace function public.upsert_package(
  p_code text,
  p_name text,
  p_semantic_category text,
  p_notes text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_actor uuid := auth.uid(); v_before text;
begin
  perform public.require_capability('package.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_code, '')) = '' then
    raise exception 'A package code is required' using errcode = '22023';
  end if;
  -- كما في الوكلاء: القيد هو المرجع، والقائمة هنا للرسالة.
  if p_semantic_category not in
     ('PAID_PACKAGE', 'DEBT_SERVICE', 'OTHER', 'UNKNOWN', 'DEPRECATED') then
    raise exception 'Unknown package category %', p_semantic_category
      using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'master.package.saved') then
    return jsonb_build_object('code', p_code, 'idempotent', true);
  end if;

  select semantic_category into v_before from public.packages where code = btrim(p_code);

  insert into public.packages (code, name, semantic_category, notes, created_by)
  values (btrim(p_code), btrim(coalesce(p_name, p_code)), p_semantic_category,
          nullif(btrim(coalesce(p_notes, '')), ''), v_actor)
  on conflict (code) do update
    set name = excluded.name,
        semantic_category = excluded.semantic_category,
        notes = excluded.notes,
        updated_at = now();

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'master.package.saved', 'semantic_category',
    coalesce(v_before, 'NONE'), p_semantic_category, 'package', p_request_id,
    'code=' || btrim(p_code));

  return jsonb_build_object('code', btrim(p_code), 'category', p_semantic_category,
                            'idempotent', false);
end;
$fn$;

revoke execute on function public.upsert_package(text,text,text,text,uuid) from public, anon;
grant execute on function public.upsert_package(text,text,text,text,uuid) to authenticated;

create or replace function public.page_packages(
  p_search text default null,
  p_category text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('agent.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with known as (
    select p.code, p.name, p.semantic_category, p.notes, p.created_at,
           (select count(*) from public.saas_activation_events e
            where e.profile_name = p.code) as events,
           true as registered
    from public.packages p
  ),
  -- الباقات الواردة في المصدر وغير المعرَّفة: تمنع تسعير أحداثها.
  unknown as (
    select e.profile_name as code, e.profile_name as name,
           'UNKNOWN'::text as semantic_category, null::text as notes,
           null::timestamptz as created_at, count(*) as events, false as registered
    from public.saas_activation_events e
    where e.profile_name is not null and btrim(e.profile_name) <> ''
      and not exists (select 1 from public.packages p where p.code = e.profile_name)
    group by e.profile_name
  ),
  kept as (
    select * from (select * from known union all select * from unknown) t
    where (p_category is null or t.semantic_category = p_category)
      and (p_search is null or btrim(p_search) = ''
           or t.code ilike '%' || p_search || '%'
           or t.name ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.registered, k.events desc, k.code
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_packages(text,text,integer,integer) from public, anon;
grant execute on function public.page_packages(text,text,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. إدارة المستخدمين
--
-- إنشاء الحساب نفسه يبقى خارج المتصفّح: يحتاج صلاحية خدمة لا تُسلَّم لصفحة.
-- ما هنا هو ما يجوز فعله بأمان — الدور والتفعيل والاسم — وكلّه مُدقَّق،
-- ومحروسٌ بحارس القفل القائم.
-- ---------------------------------------------------------------------------

create or replace function public.update_user_profile(
  p_user_id uuid,
  p_full_name text default null,
  p_role text default null,
  p_is_active boolean default null,
  p_reason text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  uuid := auth.uid();
  v_before public.profiles%rowtype;
  v_admins integer;
begin
  perform public.require_capability('permission.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A profile change must state its reason' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'admin.user.updated') then
    return jsonb_build_object('user_id', p_user_id, 'idempotent', true);
  end if;

  select * into v_before from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'User was not found' using errcode = 'P0002';
  end if;

  if p_role is not null
     and not exists (select 1 from public.role_templates where key = p_role) then
    raise exception 'Unknown role %', p_role using errcode = '22023';
  end if;

  -- حارس القفل: آخر إداريّ فعّال لا يُنزع دوره ولا يُعطَّل.
  if v_before.role = 'admin' and v_before.is_active then
    if (p_role is not null and p_role <> 'admin') or p_is_active = false then
      select count(*) into v_admins from public.profiles
      where role = 'admin' and is_active and id <> p_user_id;
      if v_admins = 0 then
        raise exception 'This is the last active administrator; the system would lock out'
          using errcode = '23514';
      end if;
    end if;
  end if;

  update public.profiles
  set full_name = coalesce(nullif(btrim(coalesce(p_full_name, '')), ''), full_name),
      role      = coalesce(p_role, role),
      is_active = coalesce(p_is_active, is_active),
      updated_at = now()
  where id = p_user_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'admin.user.updated', 'role',
    v_before.role || '/' || v_before.is_active::text,
    coalesce(p_role, v_before.role) || '/' || coalesce(p_is_active, v_before.is_active)::text,
    'profile', p_request_id,
    'user=' || coalesce(v_before.email, p_user_id::text) || ' reason=' || btrim(p_reason));

  return jsonb_build_object(
    'user_id', p_user_id, 'idempotent', false,
    'role', coalesce(p_role, v_before.role),
    'is_active', coalesce(p_is_active, v_before.is_active));
end;
$fn$;

revoke execute on function public.update_user_profile(uuid,text,text,boolean,text,uuid)
  from public, anon;
grant execute on function public.update_user_profile(uuid,text,text,boolean,text,uuid)
  to authenticated;

commit;
