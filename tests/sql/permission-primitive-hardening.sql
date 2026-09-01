-- SEC-004: يثبت نموذج الصلاحيات النهائي فعلياً — لا قائمة اليوم فقط. الفحص
-- الأول يعيد بناء ما تعنيه "بلا سطر grant/revoke صريح" بمعادلة Postgres
-- نفسها (aclexplode(coalesce(proacl, acldefault('f', proowner)))) عبر كل
-- دالّة SECURITY DEFINER في public — فيرصد أي دالّة مستقبلية بلا إغلاق
-- صريح تلقائياً، لا فقط الدوال المفحوصة يدوياً اليوم.
--
-- معزول بنطاق تسمية pph-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '        ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '        ok ' || p_label;
end;
$$;

begin;

select '       == permission primitive hardening ==';

-- ===========================================================================
-- 1. النموذج النهائي: لا دالّة SECURITY DEFINER واحدة في public تمنح
--    EXECUTE لـanon أو PUBLIC — لا بسطر صريح، ولا بغياب أي سطر (الحالة
--    التي تعني الاعتماد على الافتراضي الحقيقي، لا "بلا صلاحية ضمناً").
-- ===========================================================================

select pg_temp.ok(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and (
       exists (
         select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE')
       or exists (
         select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         join pg_roles r on r.oid = a.grantee
         where r.rolname = 'anon' and a.privilege_type = 'EXECUTE')
     )) = 0,
  'زون-004: لا دالّة SECURITY DEFINER واحدة قابلة للاستدعاء من anon أو PUBLIC');

-- ضبط الفحص نفسه: يجب ألا يكون صحيحاً بلا شرط (لولا ذلك لكان الفحص عديم
-- الفائدة). fdt_commission_scope مثال معروف: authenticated نعم، anon لا.
select pg_temp.ok(
  has_function_privilege('authenticated', 'public.fdt_commission_scope(text)', 'EXECUTE'),
  'ضبط الفحص: authenticated يبقى مخوَّلاً لدوال القراءة العادية');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.fdt_commission_scope(text)', 'EXECUTE'),
  'ضبط الفحص: anon ممنوع من نفس الدالّة');

-- ===========================================================================
-- 2. effective_permission / explain_permission — سُحب التفويض المباشر من
--    authenticated (كانتا تسمحان بالاستعلام عن قدرات أي مستخدم آخر بمعرّفه
--    التعسفي)، وتبقيان تعملان داخلياً عبر has_capability.
-- ===========================================================================

select pg_temp.ok(
  not has_function_privilege('authenticated', 'public.effective_permission(uuid,text,text,text)', 'EXECUTE'),
  'effective_permission: authenticated لم يعد يستدعيها مباشرة');
select pg_temp.ok(
  not has_function_privilege('anon', 'public.effective_permission(uuid,text,text,text)', 'EXECUTE'),
  'effective_permission: anon ممنوعة كما كانت');
select pg_temp.ok(
  not has_function_privilege('authenticated', 'public.explain_permission(uuid,text,text,text)', 'EXECUTE'),
  'explain_permission: authenticated لم يعد يستدعيها مباشرة');

insert into auth.users (id, email) values
  ('ac000000-0000-0000-0000-00000000ea01', 'pph-viewer@fixture.invalid'),
  ('ac000000-0000-0000-0000-00000000ea02', 'pph-target@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ac000000-0000-0000-0000-00000000ea01', 'PPH-VI', 'pph-viewer@fixture.invalid', 'viewer', true),
  ('ac000000-0000-0000-0000-00000000ea02', 'PPH-TG', 'pph-target@fixture.invalid', 'viewer', true)
on conflict (id) do update set role = 'viewer', is_active = true;

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-00000000ea01';

-- مستخدم عادٍ لم يعد يستطيع الاستعلام عن قدرات مستخدم آخر مباشرة.
select pg_temp.must_fail(
  $q$select public.effective_permission(
    'ac000000-0000-0000-0000-00000000ea02', 'permission.manage')$q$,
  'viewer لا يستعلم عن قدرة مستخدم آخر عبر effective_permission مباشرة');
select pg_temp.must_fail(
  $q$select public.explain_permission(
    'ac000000-0000-0000-0000-00000000ea02', 'permission.manage')$q$,
  'viewer لا يفصّل صلاحيات مستخدم آخر عبر explain_permission مباشرة');

-- لكن الغلاف الشرعي (has_capability) يبقى يعمل، لأنه يستدعيها داخلياً
-- بامتياز المالك — الإغلاق لم يكسر المسار الشرعي.
select pg_temp.ok(
  (public.has_capability('installation.enroll') is not null),
  'has_capability يبقى يعمل عبر الاستدعاء الداخلي رغم سحب المنحة المباشرة');

reset role;

-- ===========================================================================
-- 3. دالّتا trigger اللتان لم تُمنَحا/تُسحَبا قط — أُغلقتا الآن صراحة
--    توثيقياً، مطابقةً لكل نظير آخر لهما.
-- ===========================================================================

select pg_temp.ok(
  not has_function_privilege('authenticated', 'public.protect_activation_correction()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.protect_activation_correction()', 'EXECUTE'),
  'protect_activation_correction: مُغلَقة صراحة الآن لـanon وauthenticated');
select pg_temp.ok(
  not has_function_privilege('authenticated', 'public.protect_voided_import_batch()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.protect_voided_import_batch()', 'EXECUTE'),
  'protect_voided_import_batch: مُغلَقة صراحة الآن لـanon وauthenticated');

-- ===========================================================================
-- 4. مساحة العمل الكاملة (تدقيق QA 2026-09-01، طلب #7): legacy.workspace
--    مقصورةٌ على admin وحده — لا accountant ولا monitor ولا viewer يرثها
--    (لم تُدرَج في القائمة المشتركة لهم في 20260820090000)، والمدير يرثها
--    ضمناً من قالب admin (الذي يملك كل قدرة) بلا صفٍّ إضافي.
-- ===========================================================================

insert into auth.users (id, email) values
  ('ac000000-0000-0000-0000-00000000ea03', 'pph-admin@fixture.invalid'),
  ('ac000000-0000-0000-0000-00000000ea04', 'pph-accountant@fixture.invalid'),
  ('ac000000-0000-0000-0000-00000000ea05', 'pph-monitor@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ac000000-0000-0000-0000-00000000ea03', 'PPH-AD', 'pph-admin@fixture.invalid', 'admin', true),
  ('ac000000-0000-0000-0000-00000000ea04', 'PPH-AC', 'pph-accountant@fixture.invalid', 'accountant', true),
  ('ac000000-0000-0000-0000-00000000ea05', 'PPH-MO', 'pph-monitor@fixture.invalid', 'monitor', true)
on conflict (id) do update set role = excluded.role, is_active = true;

select pg_temp.ok(
  exists (select 1 from public.permission_capabilities where key = 'legacy.workspace'),
  'مساحة العمل: قدرة legacy.workspace مُعرَّفة في الكتالوج');
select pg_temp.ok(
  exists (select 1 from public.role_template_capabilities
          where role_key = 'admin' and capability_key = 'legacy.workspace'),
  'مساحة العمل: قالب admin يملكها');
select pg_temp.ok(
  not exists (select 1 from public.role_template_capabilities
              where role_key in ('accountant', 'monitor', 'viewer')
                and capability_key = 'legacy.workspace'),
  'مساحة العمل: لا accountant ولا monitor ولا viewer يملكها');

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-00000000ea03';
select pg_temp.ok(
  public.has_capability('legacy.workspace'),
  'مساحة العمل: admin مخوَّل فعلياً عبر has_capability');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-00000000ea04';
select pg_temp.ok(
  not public.has_capability('legacy.workspace'),
  'مساحة العمل: accountant غير مخوَّل فعلياً عبر has_capability');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-00000000ea05';
select pg_temp.ok(
  not public.has_capability('legacy.workspace'),
  'مساحة العمل: monitor غير مخوَّل فعلياً عبر has_capability');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-00000000ea01';
select pg_temp.ok(
  not public.has_capability('legacy.workspace'),
  'مساحة العمل: viewer غير مخوَّل فعلياً عبر has_capability');
reset role;

select '       == permission primitive hardening: done ==';

rollback;
