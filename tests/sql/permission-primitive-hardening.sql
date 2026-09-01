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

select '       == permission primitive hardening: done ==';

rollback;
