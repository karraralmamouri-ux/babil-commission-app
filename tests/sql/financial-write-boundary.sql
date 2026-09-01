-- حدود الكتابة المالية: كل جدول مالي يجب أن يكون SELECT فقط لدور المتصفح،
-- والكتابة حصراً عبر الدوال المحمية.
--
-- ملاحظة على البيئة: Postgres المحلي لا يحمل امتيازات Supabase الافتراضية،
-- فثغرة TRUNCATE لا تظهر تلقائياً هنا. القسم 3 يصطنع الشرط نفسه (منح ALL
-- كما تفعل Supabase) ثم يثبت أن المهاجرة تغلقه — وإلا كان الاختبار يمر
-- على بيئة لا تحتوي العيب أصلاً، وهو ما جعل الثغرة الأولى تعبر إلى الإنتاج.

\set ON_ERROR_STOP on
begin;

create table if not exists public.boundary_results (check_name text, result text);
truncate public.boundary_results;
grant insert on public.boundary_results to authenticated;

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into public.boundary_results values (p_name, case when p_ok then 'pass' else 'FAIL ' || p_detail end);
  if not p_ok then
    raise exception 'FAILED: % %', p_name, p_detail;
  end if;
end;
$fn$;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@fixture.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'acct@fixture.invalid'),
  ('44444444-4444-4444-4444-444444444444', 'viewer@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Admin',  'admin@fixture.invalid',  'admin',      true),
  ('22222222-2222-2222-2222-222222222222', 'Acct',   'acct@fixture.invalid',   'accountant', true),
  ('44444444-4444-4444-4444-444444444444', 'Viewer', 'viewer@fixture.invalid', 'viewer',     true)
on conflict (id) do update set role = excluded.role, is_active = true;

-- الجدول فارغ على قاعدة محلية جديدة؛ الاختبار يحتاج صفاً ليثبت أنه ينجو.
insert into public.app_settings (key, value, updated_by)
values ('raw_import', '{"profiles":["P-35000"],"agents":[],"cabinetRanges":[]}'::jsonb,
        '11111111-1111-1111-1111-111111111111')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 1. كل جدول مالي: SELECT فقط لدور المتصفح، ولا شيء لـanon.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that(
  'every financial table grants only SELECT to authenticated',
  (select count(*) = 0 from information_schema.role_table_grants
   where grantee = 'authenticated'
     and table_schema = 'public'
     and (table_name like 'commission%' or table_name like 'installation%'
          or table_name in ('app_settings', 'audit_logs', 'profiles'))
     and privilege_type <> 'SELECT'),
  (select coalesce(string_agg(distinct table_name || ':' || privilege_type, ' '), '')
   from information_schema.role_table_grants
   where grantee = 'authenticated' and table_schema = 'public'
     and (table_name like 'commission%' or table_name like 'installation%'
          or table_name in ('app_settings', 'audit_logs', 'profiles'))
     and privilege_type <> 'SELECT'));

select pg_temp.assert_that(
  'PUBLIC holds nothing on any financial table',
  (select count(*) = 0 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   cross join lateral aclexplode(c.relacl) x
   where n.nspname = 'public' and c.relacl is not null
     and (c.relname like 'commission%' or c.relname like 'installation%'
          or c.relname in ('app_settings', 'audit_logs', 'profiles'))
     and x.grantee = 0));

select pg_temp.assert_that(
  'anon holds nothing on any financial table',
  (select count(*) = 0 from information_schema.role_table_grants
   where grantee = 'anon' and table_schema = 'public'
     and (table_name like 'commission%' or table_name like 'installation%'
          or table_name in ('app_settings', 'audit_logs', 'profiles'))));

-- ---------------------------------------------------------------------------
-- 2. الكتابة المباشرة مرفوضة لكل دور، حتى الإدارة: المسار هو الدالة.
-- ---------------------------------------------------------------------------

insert into public.commission_months (id, month_key, tiers, status, is_visible, created_by)
values ('aaaa0000-0000-0000-0000-000000000001', '2026-07',
  '[{"key":"t1","label":"T1","min":0,"max":200,"p35":4000,"p45":5500,"p65":8000}]'::jsonb,
  'draft', true, '11111111-1111-1111-1111-111111111111');

insert into public.commission_rows (id, month_id, zone, name, p35, p45, p65, custom_tier, paid, created_by)
values ('bbbb0000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001',
  'old', 'Boundary Agent', 10, 0, 0, 't1', 0, '11111111-1111-1111-1111-111111111111');

do $$
declare v_role text; v_uid uuid; v_blocked int := 0; v_total int := 0;
begin
  foreach v_role in array array['admin', 'accountant', 'viewer'] loop
    select id into v_uid from public.profiles where role = v_role limit 1;
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    set local role authenticated;

    -- المال: تعديل مباشر لقيمة paid يتخطى فحص التجاوز والتكرار والتدقيق.
    v_total := v_total + 1;
    begin
      update public.commission_rows set paid = 999999
      where id = 'bbbb0000-0000-0000-0000-000000000001';
      if not found then v_blocked := v_blocked + 1; end if;
    exception when others then v_blocked := v_blocked + 1;
    end;

    -- الإعدادات: تفريغها يُسقط ربط الوكلاء ونطاقات الكابينات.
    v_total := v_total + 1;
    begin
      execute 'truncate table public.app_settings';
    exception when others then v_blocked := v_blocked + 1;
    end;

    reset role;
  end loop;

  perform pg_temp.assert_that(
    'no role can write money or settings directly',
    v_blocked = v_total,
    v_blocked || '/' || v_total || ' blocked');
end;
$$;

select pg_temp.assert_that(
  'the direct attempts left the amount untouched',
  (select paid = 0 from public.commission_rows
   where id = 'bbbb0000-0000-0000-0000-000000000001'));

select pg_temp.assert_that(
  'the settings row survived every truncate attempt',
  (select count(*) >= 1 from public.app_settings));

-- ---------------------------------------------------------------------------
-- 3. محاكاة امتيازات Supabase الافتراضية: الثغرة تُصطنع ثم تُغلق.
-- ---------------------------------------------------------------------------

do $$
declare v_uid uuid; v_truncated boolean := false;
begin
  -- هذا ما تفعله Supabase عند إنشاء جدول جديد.
  grant all on table public.app_settings to authenticated;

  select id into v_uid from public.profiles where role = 'viewer' limit 1;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  set local role authenticated;
  begin
    execute 'truncate table public.app_settings';
    v_truncated := true;
  exception when others then v_truncated := false;
  end;
  reset role;

  perform pg_temp.assert_that(
    'the hole is real when default privileges are present',
    v_truncated,
    'a viewer should have been able to truncate before the fix');
end;
$$;

-- إعادة تعبئة ما أفرغته المحاكاة، ثم تطبيق نفس ما تفعله المهاجرة.
insert into public.app_settings (key, value, updated_by)
values ('raw_import', '{"probe":true}'::jsonb, '11111111-1111-1111-1111-111111111111')
on conflict (key) do nothing;

revoke all on table public.app_settings from authenticated;
grant select on table public.app_settings to authenticated;
revoke all on table public.app_settings from anon;
revoke all on table public.app_settings from public;

do $$
declare v_uid uuid; v_truncated boolean := false;
begin
  select id into v_uid from public.profiles where role = 'viewer' limit 1;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  set local role authenticated;
  begin
    execute 'truncate table public.app_settings';
    v_truncated := true;
  exception when others then v_truncated := false;
  end;
  reset role;

  perform pg_temp.assert_that(
    'revoke all then grant select closes it',
    not v_truncated);
end;
$$;

select pg_temp.assert_that(
  'the privileged write path survives the revoke',
  (select p.prosecdef and coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=%'
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_import_settings'),
  'save_import_settings must stay SECURITY DEFINER with a pinned search_path');

select pg_temp.assert_that(
  'app_settings ends SELECT-only for authenticated',
  (select count(*) = 0 from information_schema.role_table_grants
   where grantee = 'authenticated' and table_name = 'app_settings'
     and privilege_type <> 'SELECT'));

-- ---------------------------------------------------------------------------
-- 4. الدوال المالية تبقى محمية.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that(
  'every financial RPC is SECURITY DEFINER with a pinned search_path',
  (select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('record_commission_payment', 'update_commission_row',
                       'publish_commission_month', 'save_import_settings',
                       'import_installation_entitlements', 'import_installation_history',
                       'audit_installation_invoice', 'record_installation_payment')
     and (p.prosecdef = false
          or coalesce(array_to_string(p.proconfig, ','), '') not like '%search_path=%')));

select pg_temp.assert_that(
  'no financial RPC is executable by anon or public',
  (select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   cross join lateral aclexplode(p.proacl) x
   where n.nspname = 'public'
     and p.proname in ('record_commission_payment', 'update_commission_row',
                       'publish_commission_month', 'save_import_settings',
                       'import_installation_entitlements', 'import_installation_history',
                       'audit_installation_invoice', 'record_installation_payment')
     and coalesce(pg_get_userbyid(x.grantee), 'PUBLIC') in ('anon', 'PUBLIC')));

-- ---------------------------------------------------------------------------
-- 5. المسار القديم المُتقاعد: لا صلاحية تنفيذ لأحد على publish_commission_month.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that(
  'legacy publish_commission_month has no execute grant for anyone',
  (select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   cross join lateral aclexplode(p.proacl) x
   where n.nspname = 'public' and p.proname = 'publish_commission_month'
     and coalesce(pg_get_userbyid(x.grantee), 'PUBLIC') in ('authenticated', 'anon', 'PUBLIC')));

select check_name, result from public.boundary_results order by check_name;
drop table public.boundary_results;

rollback;
