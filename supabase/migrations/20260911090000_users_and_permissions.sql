-- ---------------------------------------------------------------------------
-- المستخدمون والصلاحيات — طبقة قراءة فوق محرّكٍ قائم
--
-- المحرّك موجود ويعمل: effective_permission تحسم، وexplain_permission تقول
-- من أين جاء الحكم، وset_user_permission تكتب بحارس قفلٍ يمنع إفراغ
-- الإداريين. الناقص كان القراءة: لا شاشة تعرض من يملك ماذا ولماذا.
--
-- والقاعدة التي تحكم العرض: كتالوج الصلاحيات في القاعدة هو المرجع. لا عدد
-- مثبَّت في الواجهة، ولا قائمة مكرّرة فيها. وقدرةٌ ممنوحة لا يعرفها
-- الكتالوج تُعرض بمفتاحها التقني مع «غير معرّفة في كتالوج الصلاحيات» —
-- لا «؟؟؟» ولا اختفاء صامت.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.page_users(
  p_search text default null,
  p_role text default null,
  p_active boolean default null,
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
  perform public.require_capability('permission.manage');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select
      p.id, p.email, p.full_name, p.role, p.is_active, p.created_at,
      rt.label_ar as role_label,
      (select count(*) from public.user_permission_overrides o
       where o.user_id = p.id
         and (o.expires_at is null or o.expires_at > now())) as override_count,
      (select count(*) from public.role_template_capabilities rc
       where rc.role_key = p.role) as role_capability_count,
      (select max(a.created_at) from public.audit_logs a where a.actor_id = p.id) as last_action_at
    from public.profiles p
    left join public.role_templates rt on rt.key = p.role
    where (p_role is null or p.role = p_role)
      and (p_active is null or p.is_active = p_active)
      and (p_search is null or btrim(p_search) = ''
           or p.email ilike '%' || p_search || '%'
           or p.full_name ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.is_active desc, k.email
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_users(text,text,boolean,integer,integer) from public, anon;
grant execute on function public.page_users(text,text,boolean,integer,integer) to authenticated;

-- ---------------------------------------------------------------------------
-- الصلاحيات الفعّالة لمستخدم — بمصدر كل حكم
--
-- كل قدرة في الكتالوج تُعرض ولو لم تُمنح: «لا يملكها» معلومة أيضاً. والمصدر
-- يُقال صراحةً — دور، أم منح صريح، أم منع صريح — فلا يُسأل «لماذا يستطيع؟».
-- ---------------------------------------------------------------------------

create or replace function public.user_effective_permissions(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_doc jsonb; v_role text;
begin
  perform public.require_capability('permission.manage');

  select role into v_role from public.profiles where id = p_user_id;
  if v_role is null then
    return jsonb_build_object('found', false, 'user_id', p_user_id);
  end if;

  select jsonb_build_object(
    'found', true,
    'user_id', p_user_id,
    'role', v_role,
    'role_label', (select label_ar from public.role_templates where key = v_role),
    'profile', (
      select jsonb_build_object('email', p.email, 'full_name', p.full_name,
                                'is_active', p.is_active, 'created_at', p.created_at)
      from public.profiles p where p.id = p_user_id),

    -- الكتالوج هو المرجع: تُعرض كل قدرة فيه بحكمها ومصدره.
    'capabilities', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.domain, x.capability) from (
        select
          c.key as capability,
          c.label_ar,
          c.description,
          c.domain,
          c.is_sensitive,
          c.scopeable,
          (rc.capability_key is not null) as from_role,
          o.effect as override_effect,
          o.scope_type as override_scope_type,
          o.scope_id as override_scope_id,
          o.reason as override_reason,
          o.expires_at as override_expires_at,
          -- الحكم النهائي كما يحسبه المحرّك نفسه لا كما تُعيد الواجهة حسابه.
          public.effective_permission(p_user_id, c.key, null, null) as effective,
          case
            when o.effect = 'DENY' then 'OVERRIDE_DENY'
            when o.effect = 'GRANT' then 'OVERRIDE_GRANT'
            when rc.capability_key is not null then 'ROLE'
            else 'NONE' end as source
        from public.permission_capabilities c
        left join public.role_template_capabilities rc
          on rc.capability_key = c.key and rc.role_key = v_role
        left join public.user_permission_overrides o
          on o.capability_key = c.key and o.user_id = p_user_id
         and (o.expires_at is null or o.expires_at > now())
      ) x), '[]'::jsonb),

    -- قدرةٌ ممنوحة لا يعرفها الكتالوج: تُعرض بمفتاحها لا تُخفى ولا تُسمّى «؟؟؟».
    'uncatalogued', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select o.capability_key, o.effect, o.scope_type, o.scope_id,
               o.reason, o.expires_at
        from public.user_permission_overrides o
        where o.user_id = p_user_id
          and not exists (select 1 from public.permission_capabilities c
                          where c.key = o.capability_key)
        union all
        select rc.capability_key, 'GRANT', null, null, null, null
        from public.role_template_capabilities rc
        where rc.role_key = v_role
          and not exists (select 1 from public.permission_capabilities c
                          where c.key = rc.capability_key)
      ) y), '[]'::jsonb),

    'catalogue_size', (select count(*) from public.permission_capabilities),
    'administrators_remaining', public.permission_administrators_remaining()
  ) into v_doc;

  return v_doc;
end;
$fn$;

revoke execute on function public.user_effective_permissions(uuid) from public, anon;
grant execute on function public.user_effective_permissions(uuid) to authenticated;

-- الأدوار وكتالوجها — لا قائمة مكرّرة في الواجهة.
create or replace function public.permission_catalogue()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'roles', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.key) from (
        select rt.key, rt.label_ar,
               (select count(*) from public.role_template_capabilities rc
                where rc.role_key = rt.key) as capability_count,
               (select count(*) from public.profiles p where p.role = rt.key) as user_count
        from public.role_templates rt) x), '[]'::jsonb),
    'domains', coalesce((
      select jsonb_agg(to_jsonb(y) order by y.domain) from (
        select c.domain, count(*) as n,
               count(*) filter (where c.is_sensitive) as sensitive
        from public.permission_capabilities c group by c.domain) y), '[]'::jsonb),
    'total', (select count(*) from public.permission_capabilities))
  where public.has_capability('permission.manage');
$fn$;

revoke execute on function public.permission_catalogue() from public, anon;
grant execute on function public.permission_catalogue() to authenticated;

commit;
