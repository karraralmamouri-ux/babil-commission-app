-- صلاحيات ديناميكية: القدرة هي وحدة الإذن، والدور قالب لا حقيقة نهائية.
--
-- اليوم الإذن مصفوفة ثابتة في الواجهة وستة أفعال فقط، والدور يُقرأ مباشرة في
-- كل RPC. هذا يمنع منح صلاحية واحدة لشخص واحد دون ترقيته دوراً كاملاً، وهو
-- ما يجعل الترقية أسهل من الضبط — اتجاه خطر في نظام مالي.
--
-- البديل: قدرات مُعرَّفة، قوالب أدوار تمنحها، وتجاوزات صريحة على مستوى
-- المستخدم بمنح أو منع. المنع يغلب المنح دائماً.
--
-- التوافق. الأدوار الأربعة الحالية تُبذَر بقوالب تعطي سلوك اليوم حرفياً، فلا
-- يتغيّر ما يقدر عليه أي مستخدم قائم لحظة الترقية. التوسعة تأتي بالتهيئة.
--
-- forward-only. لا صف موجود يُعدَّل ولا عمود يُحذف.

begin;

-- ---------------------------------------------------------------------------
-- 1. كتالوج القدرات.
-- ---------------------------------------------------------------------------

create table if not exists public.permission_capabilities (
  key text primary key,
  domain text not null,
  label_ar text not null,
  description text,
  -- القدرة الحسّاسة لا تُمنح ضمناً ولا تُورَّث من قالب عام.
  is_sensitive boolean not null default false,
  -- القدرة التي تحمي نفسها: نزعها الكامل يُقفل النظام.
  is_self_protecting boolean not null default false,
  scopeable boolean not null default false,
  created_at timestamptz not null default now(),
  constraint permission_capabilities_key_check check (key ~ '^[a-z_]+[.][a-z_]+$')
);

-- ---------------------------------------------------------------------------
-- 2. قوالب الأدوار.
-- ---------------------------------------------------------------------------

create table if not exists public.role_templates (
  key text primary key,
  label_ar text not null,
  description text,
  -- القالب المدمج لا يُحذف؛ سلوك المستخدمين القائمين معلّق عليه.
  is_builtin boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.role_template_capabilities (
  role_key text not null references public.role_templates(key) on delete cascade,
  capability_key text not null references public.permission_capabilities(key) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (role_key, capability_key)
);

-- ---------------------------------------------------------------------------
-- 3. تجاوزات المستخدم.
--
-- الأثر ثلاثي: منح صريح، منع صريح، أو وراثة (وهي غياب الصف). المنع يغلب
-- المنح، والنطاق الأضيق لا ينقض منعاً أوسع — المنع هو الحاكم دائماً.
-- ---------------------------------------------------------------------------

create table if not exists public.user_permission_overrides (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  capability_key text not null references public.permission_capabilities(key) on delete cascade,
  effect text not null,
  scope_type text not null default 'GLOBAL',
  scope_id text,
  reason text,
  granted_by uuid not null references auth.users(id),
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  constraint user_permission_overrides_effect_check check (effect in ('GRANT', 'DENY')),
  constraint user_permission_overrides_scope_check
    check (scope_type in ('GLOBAL', 'AGENT', 'FDT', 'ZONE')),
  -- النطاق العام بلا معرّف، وغيره يلزمه معرّف. بلا هذا يصير «وكيل غير محدّد»
  -- مساوياً لـ«كل الوكلاء» بالصدفة.
  constraint user_permission_overrides_scope_shape
    check ((scope_type = 'GLOBAL' and scope_id is null)
        or (scope_type <> 'GLOBAL' and scope_id is not null)),
  constraint user_permission_overrides_identity
    unique (user_id, capability_key, scope_type, scope_id)
);

create index if not exists user_permission_overrides_user_idx
  on public.user_permission_overrides (user_id, capability_key);

-- ---------------------------------------------------------------------------
-- 4. بذر القدرات.
-- ---------------------------------------------------------------------------

insert into public.permission_capabilities (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable) values
  ('subscriber.view',                'subscriber',  'عرض المشتركين',        false, false, true),
  ('subscriber.edit',                'subscriber',  'تعديل المشتركين',      false, false, true),
  ('subscriber.match',               'subscriber',  'مطابقة الهوية',        false, false, true),
  ('subscriber.correct_attribution', 'subscriber',  'تصحيح العائدية',       true,  false, true),
  ('subscriber.transfer',            'subscriber',  'نقل المشترك',          true,  false, true),
  ('saas.import',                    'saas',        'استيراد ملفات SaaS',   true,  false, false),
  ('saas.review',                    'saas',        'مراجعة الاستيراد',     false, false, false),
  ('installation.view',              'installation','عرض أجور التنصيب',     false, false, true),
  ('installation.enroll',            'installation','تسجيل تنصيب جديد',     true,  false, true),
  ('installation.hold',              'installation','وضع تعليق',            false, false, true),
  ('installation.release_hold',      'installation','رفع تعليق',            true,  false, true),
  ('installation.review',            'installation','مراجعة التنصيب',       false, false, true),
  ('invoice.view',                   'invoice',     'عرض الفواتير',         false, false, true),
  ('invoice.verify',                 'invoice',     'تدقيق فاتورة',         true,  false, true),
  ('invoice.reject',                 'invoice',     'رفض فاتورة',           true,  false, true),
  ('payment.view',                   'payment',     'عرض الدفعات',          false, false, true),
  ('payment.prepare',                'payment',     'تحضير دفعة',           true,  false, true),
  ('payment.execute',                'payment',     'تنفيذ الدفع',          true,  false, true),
  ('payment.correct',                'payment',     'تصحيح مالي',           true,  false, false),
  ('payment.reverse',                'payment',     'عكس حركة مالية',       true,  false, false),
  ('cycle.view',                     'cycle',       'عرض الدورات',          false, false, false),
  ('cycle.manage',                   'cycle',       'إدارة الدورات',        true,  false, false),
  ('cycle.close',                    'cycle',       'إقفال دورة',           true,  false, false),
  ('cycle.reopen',                   'cycle',       'إعادة فتح دورة',       true,  false, false),
  ('agent.view',                     'master',      'عرض الوكلاء',          false, false, false),
  ('agent.manage',                   'master',      'إدارة الوكلاء',        true,  false, false),
  ('fdt.manage',                     'master',      'إدارة الكابينات',      true,  false, false),
  ('package.manage',                 'master',      'إدارة الباقات',        true,  false, false),
  ('scheme.manage',                  'master',      'إدارة مخططات الأجور',  true,  false, false),
  ('report.view',                    'report',      'عرض التقارير',         false, false, true),
  ('report.export',                  'report',      'تصدير التقارير',       false, false, true),
  ('audit.view',                     'audit',       'عرض سجل التدقيق',      false, false, false),
  ('user.view',                      'admin',       'عرض المستخدمين',       false, false, false),
  ('user.manage',                    'admin',       'إدارة المستخدمين',     true,  false, false),
  ('permission.manage',              'admin',       'إدارة الصلاحيات',      true,  true,  false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 5. بذر القوالب بسلوك اليوم حرفياً.
--
-- المصفوفة الحالية ستة أفعال: edit / payment / rates / users / delete / backup.
--   admin      = الكل
--   accountant = payment فقط
--   monitor    = لا شيء
--   viewer     = لا شيء
-- والقراءة كانت مسموحة للجميع ضمناً، فقدرات العرض تُمنح للأربعة.
-- ---------------------------------------------------------------------------

insert into public.role_templates (key, label_ar, is_builtin) values
  ('admin',      'مدير',   true),
  ('accountant', 'محاسب',  true),
  ('monitor',    'مراقب',  true),
  ('viewer',     'مشاهد',  true)
on conflict (key) do nothing;

-- المدير: كل قدرة.
insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', key from public.permission_capabilities
on conflict do nothing;

-- قدرات العرض للجميع — وهي حال النظام فعلاً قبل هذه المهاجرة.
insert into public.role_template_capabilities (role_key, capability_key)
select r.key, c.key
from (values ('accountant'), ('monitor'), ('viewer')) as r(key)
cross join public.permission_capabilities c
where c.key in ('subscriber.view','installation.view','invoice.view','payment.view',
                'cycle.view','agent.view','report.view')
on conflict do nothing;

-- المحاسب: يملك payment اليوم. يُترجَم إلى تحضير وتنفيذ وتدقيق فاتورة وتصدير.
-- التصحيح والعكس ليسا منه: تسجيل الدفع لا يمنح سلطة نقض الدفع.
insert into public.role_template_capabilities (role_key, capability_key)
select 'accountant', c.key from public.permission_capabilities c
where c.key in ('payment.prepare','payment.execute','invoice.verify','invoice.reject',
                'installation.review','installation.hold','report.export','saas.review')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 6. الصلاحية الفعلية.
--
-- الترتيب: منع صريح ⇐ ممنوع مهما كان القالب. ثم منح صريح. ثم القالب.
-- ---------------------------------------------------------------------------

create or replace function public.effective_permission(
  p_user_id uuid,
  p_capability text,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with actor as (
    select role from public.profiles where id = p_user_id and is_active = true
  ),
  denied as (
    select 1 from public.user_permission_overrides o
    where o.user_id = p_user_id and o.capability_key = p_capability
      and o.effect = 'DENY'
      and (o.expires_at is null or o.expires_at > now())
      -- منع عام يشمل كل نطاق؛ ومنع مُقيَّد يشمل نطاقه وحده.
      and (o.scope_type = 'GLOBAL'
           or (o.scope_type = p_scope_type and o.scope_id is not distinct from p_scope_id))
  ),
  granted as (
    select 1 from public.user_permission_overrides o
    where o.user_id = p_user_id and o.capability_key = p_capability
      and o.effect = 'GRANT'
      and (o.expires_at is null or o.expires_at > now())
      and (o.scope_type = 'GLOBAL'
           or (o.scope_type = p_scope_type and o.scope_id is not distinct from p_scope_id))
  ),
  inherited as (
    select 1 from actor a
    join public.role_templates t on t.key = a.role and t.is_active
    join public.role_template_capabilities rc on rc.role_key = t.key
    where rc.capability_key = p_capability
  )
  select case
    when not exists (select 1 from actor) then false
    when exists (select 1 from denied) then false
    when exists (select 1 from granted) then true
    else exists (select 1 from inherited)
  end;
$$;

-- الحارس الذي تستدعيه الـRPC. يقيس على المستخدم الحالي دائماً.
create or replace function public.has_capability(
  p_capability text,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.effective_permission(auth.uid(), p_capability, p_scope_type, p_scope_id);
$$;

-- يرفع خطأ بدل أن يعيد false، ليكون سطراً واحداً في كل RPC.
create or replace function public.require_capability(
  p_capability text,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default null
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.has_capability(p_capability, p_scope_type, p_scope_id) then
    raise exception 'Capability % is required', p_capability using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. التفسير. لماذا يملك هذا المستخدم هذه القدرة أو لا يملكها.
-- ---------------------------------------------------------------------------

create or replace function public.explain_permission(
  p_user_id uuid,
  p_capability text,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', p_user_id,
    'capability', p_capability,
    'scope_type', p_scope_type,
    'scope_id', p_scope_id,
    'role_template', (select role from public.profiles where id = p_user_id and is_active),
    'inherited', exists (
      select 1 from public.profiles p
      join public.role_template_capabilities rc on rc.role_key = p.role
      where p.id = p_user_id and p.is_active and rc.capability_key = p_capability),
    'explicit_grant', exists (
      select 1 from public.user_permission_overrides o
      where o.user_id = p_user_id and o.capability_key = p_capability and o.effect = 'GRANT'
        and (o.expires_at is null or o.expires_at > now())),
    'explicit_deny', exists (
      select 1 from public.user_permission_overrides o
      where o.user_id = p_user_id and o.capability_key = p_capability and o.effect = 'DENY'
        and (o.expires_at is null or o.expires_at > now())),
    'overrides', coalesce((
      select jsonb_agg(jsonb_build_object(
        'effect', o.effect, 'scope_type', o.scope_type, 'scope_id', o.scope_id,
        'reason', o.reason, 'expires_at', o.expires_at))
      from public.user_permission_overrides o
      where o.user_id = p_user_id and o.capability_key = p_capability), '[]'::jsonb),
    'effective', public.effective_permission(p_user_id, p_capability, p_scope_type, p_scope_id)
  );
$$;

-- كل قدرات المستخدم دفعة واحدة — تستهلكها الواجهة لبناء القوائم.
create or replace function public.my_capabilities()
returns table (capability_key text, effective boolean, source text)
language sql
stable
security definer
set search_path = ''
as $$
  select c.key,
         public.effective_permission(auth.uid(), c.key),
         case
           when exists (select 1 from public.user_permission_overrides o
                        where o.user_id = auth.uid() and o.capability_key = c.key
                          and o.effect = 'DENY'
                          and (o.expires_at is null or o.expires_at > now())) then 'DENY'
           when exists (select 1 from public.user_permission_overrides o
                        where o.user_id = auth.uid() and o.capability_key = c.key
                          and o.effect = 'GRANT'
                          and (o.expires_at is null or o.expires_at > now())) then 'GRANT'
           when exists (select 1 from public.profiles p
                        join public.role_template_capabilities rc on rc.role_key = p.role
                        where p.id = auth.uid() and p.is_active
                          and rc.capability_key = c.key) then 'TEMPLATE'
           else 'NONE'
         end
  from public.permission_capabilities c;
$$;

-- ---------------------------------------------------------------------------
-- 8. الحماية من الإقفال.
--
-- لا بد أن يبقى مدير صلاحيات فعّال واحد على الأقل. بدون هذا يستطيع مدير أن
-- يمنع نفسه، فيصير النظام بلا من يعيد فتحه.
-- ---------------------------------------------------------------------------

create or replace function public.permission_administrators_remaining()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.profiles p
  where p.is_active
    and public.effective_permission(p.id, 'permission.manage');
$$;

create or replace function public.guard_permission_lockout()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.permission_administrators_remaining() < 1 then
    raise exception 'At least one active permission administrator must remain'
      using errcode = '23514';
  end if;
  return null;
end;
$$;

-- مؤجَّل إلى نهاية المعاملة: خطوة وسيطة قد تُنقص العدد مؤقتاً، والمهم هو
-- الحصيلة عند الالتزام.
drop trigger if exists trg_guard_permission_lockout on public.user_permission_overrides;
create constraint trigger trg_guard_permission_lockout
  after insert or update or delete on public.user_permission_overrides
  deferrable initially deferred
  for each row execute function public.guard_permission_lockout();

drop trigger if exists trg_guard_lockout_template on public.role_template_capabilities;
create constraint trigger trg_guard_lockout_template
  after delete or update on public.role_template_capabilities
  deferrable initially deferred
  for each row execute function public.guard_permission_lockout();

-- ---------------------------------------------------------------------------
-- 9. إدارة الصلاحيات عبر RPC مُدقَّق. لا كتابة مباشرة على الجدول.
-- ---------------------------------------------------------------------------

create or replace function public.set_user_permission(
  p_user_id uuid,
  p_capability text,
  p_effect text,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default null,
  p_reason text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_before jsonb;
  v_after jsonb;
  v_existing public.audit_logs%rowtype;
begin
  perform public.require_capability('permission.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_effect not in ('GRANT', 'DENY', 'INHERIT') then
    raise exception 'effect must be GRANT, DENY or INHERIT' using errcode = '22023';
  end if;
  if not exists (select 1 from public.permission_capabilities where key = p_capability) then
    raise exception 'Unknown capability %', p_capability using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0));

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select to_jsonb(o) into v_before from public.user_permission_overrides o
  where o.user_id = p_user_id and o.capability_key = p_capability
    and o.scope_type = p_scope_type and o.scope_id is not distinct from p_scope_id;

  -- الوراثة تعني إزالة التجاوز، لا كتابة أثر ثالث.
  if p_effect = 'INHERIT' then
    delete from public.user_permission_overrides o
    where o.user_id = p_user_id and o.capability_key = p_capability
      and o.scope_type = p_scope_type and o.scope_id is not distinct from p_scope_id;
    v_after := null;
  else
    insert into public.user_permission_overrides
      (user_id, capability_key, effect, scope_type, scope_id, reason, granted_by)
    values (p_user_id, p_capability, p_effect, p_scope_type, p_scope_id, p_reason, v_actor)
    on conflict (user_id, capability_key, scope_type, scope_id)
    do update set effect = excluded.effect, reason = excluded.reason,
                  granted_by = excluded.granted_by, granted_at = now()
    returning to_jsonb(user_permission_overrides) into v_after;
  end if;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, before_data, after_data, request_id, extra
  ) values (
    v_actor, 'permission.changed', p_capability,
    coalesce(v_before ->> 'effect', 'INHERIT'), p_effect,
    'user_permission', p_user_id, v_before, v_after, p_request_id,
    p_scope_type || coalesce(':' || p_scope_id, '')
  );

  return jsonb_build_object(
    'replayed', false, 'request_id', p_request_id,
    'effective', public.effective_permission(p_user_id, p_capability, p_scope_type, p_scope_id),
    'administrators_remaining', public.permission_administrators_remaining()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['permission_capabilities','role_templates',
                           'role_template_capabilities','user_permission_overrides'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format('grant select on table public.%I to authenticated', t);
  end loop;
end;
$$;

-- الكتالوج والقوالب مقروءة للجميع: الواجهة تحتاجها لتفسير ما يملكه المستخدم.
drop policy if exists permission_capabilities_select on public.permission_capabilities;
create policy permission_capabilities_select on public.permission_capabilities
  for select to authenticated using (true);

drop policy if exists role_templates_select on public.role_templates;
create policy role_templates_select on public.role_templates
  for select to authenticated using (true);

drop policy if exists role_template_capabilities_select on public.role_template_capabilities;
create policy role_template_capabilities_select on public.role_template_capabilities
  for select to authenticated using (true);

-- التجاوزات: كل مستخدم يرى تجاوزاته، ومدير الصلاحيات يرى الجميع.
drop policy if exists user_permission_overrides_select on public.user_permission_overrides;
create policy user_permission_overrides_select on public.user_permission_overrides
  for select to authenticated
  using (user_id = auth.uid() or public.has_capability('permission.manage'));

revoke execute on function public.guard_permission_lockout() from public, anon, authenticated;
revoke execute on function public.set_user_permission(uuid, text, text, text, text, text, uuid)
  from public, anon;
grant execute on function public.set_user_permission(uuid, text, text, text, text, text, uuid)
  to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.effective_permission(uuid, text, text, text)',
    'public.has_capability(text, text, text)',
    'public.require_capability(text, text, text)',
    'public.explain_permission(uuid, text, text, text)',
    'public.my_capabilities()',
    'public.permission_administrators_remaining()'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
