-- 20261031090000: partial-batch lifecycle (Codex Blocker 2) and cross-admin
-- batch IDOR (Codex Blocker 3) for import_installation_entitlements.
--
-- معزول بملفه ومعاملته ونطاق تسمية LC-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '     ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail_code(p_sql text, p_label text, p_sqlstate text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  if p_sqlstate is not null and sqlstate <> p_sqlstate then
    return 'FAILED: ' || p_label || ' — الرمز ' || sqlstate || ' لا ' || p_sqlstate || ' (' || sqlerrm || ')';
  end if;
  return '     ok ' || p_label;
end;
$$;

create or replace function pg_temp.rows_at(p_reseller text, p_remaining bigint, p_count integer, p_tag text)
returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'subscriber_id', p_reseller || '-' || p_tag || '-' || g,
    'subscriber_name', 'subscriber ' || g,
    'reseller', p_reseller,
    'remaining', p_remaining
  )), '[]'::jsonb)
  from generate_series(1, p_count) g;
$$;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_user::text, true); end;
$$;

begin;

select '     == installation entitlements lifecycle + ownership ==';

insert into auth.users (id, email) values
  ('bc000000-0000-0000-0000-0000000000a1', 'lc-admin-a@fixture.invalid'),
  ('bc000000-0000-0000-0000-0000000000a2', 'lc-admin-b@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('bc000000-0000-0000-0000-0000000000a1','LC Admin A','lc-admin-a@fixture.invalid','admin',true),
  ('bc000000-0000-0000-0000-0000000000a2','LC Admin B','lc-admin-b@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

-- ---------------------------------------------------------------------
-- Blocker 2 · دورة الحياة: IN_PROGRESS -> فشل جزءٍ -> إعادة محاولة -> إنهاء
-- ---------------------------------------------------------------------

select pg_temp.act_as('bc000000-0000-0000-0000-0000000000a1');

select (public.import_installation_entitlements('2026-11','lc-lifecycle.xlsx','lc-sha-lifecycle',
  pg_temp.rows_at('LC-LIFE', 13000, 2, 'a'), gen_random_uuid(),
  null, 3, false) -> 'batch') as lc_c1 \gset

select pg_temp.ok(
  (:'lc_c1'::jsonb ->> 'status') = 'in_progress'
    and (:'lc_c1'::jsonb ->> 'accepted')::int = 2,
  'الجزء الأول غير النهائيّ (2 من 3 مصرَّح بها) يترك الدفعة IN_PROGRESS');

select (:'lc_c1'::jsonb ->> 'batch_id') as lc_batch_id \gset

select pg_temp.ok(
  (select status = 'in_progress' and expected_rows = 3 and finalized_at is null
   from public.installation_batches where id = (:'lc_batch_id')::uuid),
  'صفّ الدفعة يعكس IN_PROGRESS و expected_rows المعلَنة وبلا وقت إنهاء');

-- جزءٌ لاحقٌ يفشل (فترة خاطئة) — لا يُفسد ما أنجزه الجزء الناجح.
select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','lc-lifecycle.xlsx','lc-sha-lifecycle',
      '[{"subscriber_id":"LC-LIFE-b-1","reseller":"LC-LIFE","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 3, false)$q$, :'lc_batch_id'),
  'جزءٌ لاحقٌ بفترةٍ خاطئة يُرفض ولا يُفسد الدفعة',
  '22023');

select pg_temp.ok(
  (select status = 'in_progress' and source_rows = 2 and accepted_rows = 2
   from public.installation_batches where id = (:'lc_batch_id')::uuid),
  'إعادة المحاولة: بعد فشل الجزء، الإجماليّات لم تتغيّر — لا فقدان ولا ازدواج');

-- إعادة محاولةٍ صحيحة بنفس الدفعة (نفس الفترة والبصمة): تنجح وتُنهي.
select (public.import_installation_entitlements('2026-11','lc-lifecycle.xlsx','lc-sha-lifecycle',
  pg_temp.rows_at('LC-LIFE', 13000, 1, 'b'), gen_random_uuid(),
  (:'lc_batch_id')::uuid, 3, true) -> 'batch') as lc_c2 \gset

select pg_temp.ok(
  (:'lc_c2'::jsonb ->> 'status') = 'completed'
    and (:'lc_c2'::jsonb -> 'batch_totals' ->> 'accepted')::int = 3,
  'إعادة المحاولة الصحيحة تُلحَق وتُنهي الدفعة بإجماليّ 3 صفوفٍ مقبولة');

select pg_temp.ok(
  (select status = 'completed' and finalized_at is not null
      and finalized_by = 'bc000000-0000-0000-0000-0000000000a1'
   from public.installation_batches where id = (:'lc_batch_id')::uuid),
  'صفّ الدفعة يسجّل الإنهاء الصريح: وقتاً وفاعلاً');

-- دفعةٌ مكتملة لا تقبل إلحاقاً آخر إطلاقاً، حتى من مالكها الأصلي.
select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-11','lc-lifecycle.xlsx','lc-sha-lifecycle',
      '[{"subscriber_id":"LC-LIFE-c-1","reseller":"LC-LIFE","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'lc_batch_id'),
  'دفعةٌ مكتملة ترفض أيّ إلحاقٍ لاحقٍ — ولو من نفس المالك',
  '22023');

-- ---------------------------------------------------------------------
-- Blocker 2 · الإنهاء قبل اكتمال الصفوف المصرَّح بها يفشل صراحةً
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-11','lc-early-finalize.xlsx','lc-sha-early',
  pg_temp.rows_at('LC-EARLY', 13000, 2, 'a'), gen_random_uuid(),
  null, 5, false) -> 'batch') as lc_early_c1 \gset

select (:'lc_early_c1'::jsonb ->> 'batch_id') as lc_early_batch_id \gset

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-11','lc-early-finalize.xlsx','lc-sha-early',
      '[{"subscriber_id":"LC-EARLY-b-1","reseller":"LC-EARLY","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 5, true)$q$, :'lc_early_batch_id'),
  'إنهاءٌ صريح قبل اكتمال الصفوف المصرَّح بها (3 من 5) يُرفض صراحةً',
  '22023');

-- الرفض ذرّي: صفّ الدفعة يبقى بالضبط كما كان قبل المحاولة الفاشلة (2/2 من
-- الجزء الأول) — لا 3/3 كما لو أن الصفّ الإضافي "سُجِّل جزئياً" قبل الرفض؛
-- فحص expected_rows يسبق UPDATE في الدالة، فلا تُنفَّذ UPDATE أصلاً عند
-- الرفض، وإدراج الصفّ في installation_entitlements يتراجع بالكامل مع فشل
-- الاستدعاء (نفس دلالة نقطة الحفظ الضمنية المثبَتة في السيناريو الأول أعلاه).
select pg_temp.ok(
  (select status = 'in_progress' and source_rows = 2 and accepted_rows = 2
   from public.installation_batches where id = (:'lc_early_batch_id')::uuid),
  'الإنهاء المبكِّر المرفوض ترك الدفعة IN_PROGRESS بإجماليّاتٍ لم تتغيّر عن ما قبل المحاولة — لا إكمالٌ صامت ولا تسجيلٌ جزئي');

-- إلحاقٌ صحيحٌ لاحقٌ يكمل العدد (2 + 3 = 5) وينهي فعلياً.
select (public.import_installation_entitlements('2026-11','lc-early-finalize.xlsx','lc-sha-early',
  pg_temp.rows_at('LC-EARLY', 13000, 3, 'c'), gen_random_uuid(),
  (:'lc_early_batch_id')::uuid, 5, true) -> 'batch') as lc_early_c2 \gset

select pg_temp.ok(
  (:'lc_early_c2'::jsonb ->> 'status') = 'completed'
    and (:'lc_early_c2'::jsonb -> 'batch_totals' ->> 'accepted')::int = 5,
  'اكتمال الصفوف المصرَّح بها (5 من 5) يُنهي الدفعة بنجاح');

-- ---------------------------------------------------------------------
-- Blocker 3 · IDOR عابر المسؤولين: لا إلحاق بدفعة مسؤولٍ آخر
-- ---------------------------------------------------------------------

select pg_temp.act_as('bc000000-0000-0000-0000-0000000000a1');
select (public.import_installation_entitlements('2026-11','lc-owned-by-a.xlsx','lc-sha-owned-a',
  pg_temp.rows_at('LC-OWNED-A', 13000, 1, 'a'), gen_random_uuid(),
  null, 2, false) -> 'batch') as lc_owned_c1 \gset

select (:'lc_owned_c1'::jsonb ->> 'batch_id') as lc_owned_batch_id \gset

select pg_temp.ok(
  (:'lc_owned_c1'::jsonb ->> 'status') = 'in_progress',
  'ضبط: دفعة المسؤول A تبقى IN_PROGRESS بانتظار الإلحاق');

-- المسؤول B يعرف batch_id والفترة والبصمة تماماً — ويُرفض رغم ذلك.
select pg_temp.act_as('bc000000-0000-0000-0000-0000000000a2');
select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-11','lc-owned-by-a.xlsx','lc-sha-owned-a',
      '[{"subscriber_id":"LC-OWNED-A-b-1","reseller":"LC-OWNED-A","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'lc_owned_batch_id'),
  'المسؤول B لا يُلحِق بدفعة المسؤول A ولو طابق batch_id والفترة والبصمة تماماً',
  '42501');

select pg_temp.ok(
  (select status = 'in_progress' and source_rows = 1 and accepted_rows = 1
      and created_by = 'bc000000-0000-0000-0000-0000000000a1'
   from public.installation_batches where id = (:'lc_owned_batch_id')::uuid),
  'محاولة المسؤول B لم تغيّر شيئاً في دفعة المسؤول A — لا صفّ إضافيّ ولا تغيير حالة');

select pg_temp.ok(
  (select count(*) = 1 from public.installation_entitlements where reseller = 'LC-OWNED-A'),
  'لا صفّ من محاولة المسؤول B وصل الجدول الفعليّ');

-- المسؤول A نفسه يُلحِق بنجاح — يثبت أن الرفض كان عائديّةً لا عطلاً عاماً.
select pg_temp.act_as('bc000000-0000-0000-0000-0000000000a1');
select (public.import_installation_entitlements('2026-11','lc-owned-by-a.xlsx','lc-sha-owned-a',
  pg_temp.rows_at('LC-OWNED-A', 13000, 1, 'b'), gen_random_uuid(),
  (:'lc_owned_batch_id')::uuid, 2) -> 'batch') as lc_owned_c2 \gset

select pg_temp.ok(
  (:'lc_owned_c2'::jsonb ->> 'status') = 'completed'
    and (:'lc_owned_c2'::jsonb -> 'batch_totals' ->> 'accepted')::int = 2,
  'المالك الأصلي (المسؤول A) يُلحِق بدفعته بنجاح — الرفض كان مقصوراً على B');

rollback;
