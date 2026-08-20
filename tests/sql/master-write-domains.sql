-- كتابات البيانات الرئيسية وإدارة المستخدمين.
--
-- أهمّ ما هنا ليس أن الدالّة تعمل، بل أن قائمة القيم التي تقبلها لم تنفصل عن
-- قيد الجدول. لو أضاف أحدهم قيمةً إلى القيد ونسي الدالّة، لصار للنظام قيمة
-- شرعية لا تستطيع الشاشة كتابتها؛ ولو حدث العكس لصارت رسالة الرفض من القيد
-- بدل الرسالة المفهومة. فالاختبار يقارن الاثنين قيمةً قيمة.
--
-- معزول بنطاق تسمية MW-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '             ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '             ok ' || p_label;
end;
$$;

-- قيم قيدٍ نصّي مستخرجةً واحدةً واحدة. القيد يكتبها بصيغة
--   ARRAY['active'::text, 'inactive'::text]
-- فلا يكفي نزع علامات الاقتباس: يجب أخذ ما بينها دون لاحقة التحويل.
create or replace function pg_temp.constraint_values(p_constraint text)
returns setof text language sql as $$
  select (regexp_match(v, '''(.*)'''))[1]
  from pg_constraint c,
       lateral regexp_split_to_table(
         (regexp_match(pg_get_constraintdef(c.oid), 'ARRAY\[(.*?)\]'))[1], ',\s*') v
  where c.conname = p_constraint;
$$;

create or replace function pg_temp.body(p_fn text)
returns text language sql as $$
  select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = p_fn limit 1;
$$;

begin;

select '            == master write domains ==';

insert into auth.users (id, email) values
  ('30000000-0000-0000-0000-0000000000a1', 'mw-admin@fixture.invalid'),
  ('30000000-0000-0000-0000-0000000000a2', 'mw-viewer@fixture.invalid'),
  ('30000000-0000-0000-0000-0000000000a3', 'mw-admin2@fixture.invalid')
on conflict do nothing;

insert into public.profiles (id, full_name, email, role, is_active) values
  ('30000000-0000-0000-0000-0000000000a1','MWA','mw-admin@fixture.invalid','admin',true),
  ('30000000-0000-0000-0000-0000000000a2','MWV','mw-viewer@fixture.invalid','viewer',true),
  ('30000000-0000-0000-0000-0000000000a3','MWB','mw-admin2@fixture.invalid','admin',false)
on conflict (id) do update set role = excluded.role, is_active = excluded.is_active;

-- ------------------------------------------------------------------
-- ١ · القائمة في الدالّة = القائمة في القيد
-- ------------------------------------------------------------------

select pg_temp.ok(
  not exists (
    select 1 from pg_temp.constraint_values('agents_status_check') v
    where position('''' || v || '''' in pg_temp.body('upsert_agent')) = 0),
  'كل حالة يقبلها القيد تقبلها الدالّة');

select pg_temp.ok(
  not exists (
    select 1 from pg_temp.constraint_values('agents_zone_check') v
    where position('''' || v || '''' in pg_temp.body('upsert_agent')) = 0),
  'كل منطقة يقبلها القيد تقبلها الدالّة');

select pg_temp.ok(
  not exists (
    select 1 from pg_temp.constraint_values('packages_category_check') v
    where position('''' || v || '''' in pg_temp.body('upsert_package')) = 0),
  'كل تصنيف باقة يقبله القيد تقبله الدالّة');

set local role authenticated;
set local request.jwt.claim.sub = '30000000-0000-0000-0000-0000000000a1';

-- والعكس: كل قيمة تمرّ من الدالّة تمرّ من القيد فعلاً.
do $$
declare v text; n integer := 0;
begin
  for v in select unnest(array['active','inactive']) loop
    perform public.upsert_agent('MW-S-' || v, 'وكيل ' || v, v, null, null, gen_random_uuid());
    n := n + 1;
  end loop;
  for v in select unnest(array['old','new','both','direct']) loop
    perform public.upsert_agent('MW-Z-' || v, 'وكيل ' || v, 'active', v, null, gen_random_uuid());
    n := n + 1;
  end loop;
  for v in select unnest(array['PAID_PACKAGE','DEBT_SERVICE','OTHER','UNKNOWN','DEPRECATED']) loop
    perform public.upsert_package('MW-P-' || v, v, v, null, gen_random_uuid());
    n := n + 1;
  end loop;
  raise notice '             ok كل قيمة تقبلها الدالّة يقبلها القيد (%)', n;
end $$;

-- ------------------------------------------------------------------
-- ٢ · الوكلاء: إنشاء، تعديل، وإعادة الطلب نفسه
-- ------------------------------------------------------------------

select pg_temp.ok(
  (public.upsert_agent('MW-AG', 'وكيل بابل', 'active', 'new', 'ملاحظة',
    '30000000-0000-0000-0000-0000000000b1')->>'idempotent') = 'false',
  'الوكيل يُنشأ');

select pg_temp.ok(
  (select official_name from public.agents where code = 'MW-AG') = 'وكيل بابل',
  'الاسم يُحفظ كما أُدخل');

select pg_temp.ok(
  (public.upsert_agent('MW-AG', 'وكيل بابل المعدَّل', 'inactive', 'both', null,
    '30000000-0000-0000-0000-0000000000b2')->>'idempotent') = 'false',
  'الوكيل يُعدَّل');

select pg_temp.ok(
  (select status from public.agents where code = 'MW-AG') = 'inactive',
  'التعطيل يُحفظ');

-- معرّف الطلب نفسه مرّتين: لا كتابة ثانية.
select pg_temp.ok(
  (public.upsert_agent('MW-AG', 'اسم ثالث', 'active', null, null,
    '30000000-0000-0000-0000-0000000000b2')->>'idempotent') = 'true',
  'إعادة الطلب نفسه لا تكتب مرّتين');

select pg_temp.ok(
  (select official_name from public.agents where code = 'MW-AG') = 'وكيل بابل المعدَّل',
  'الاسم لم يتغيّر بإعادة الطلب');

select pg_temp.ok(
  (select count(*) from public.audit_logs
   where action = 'master.agent.saved' and extra like 'code=MW-AG%') = 2,
  'كل حفظٍ فعليّ له قيد تدقيق واحد');

select pg_temp.must_fail(
  $q$ select public.upsert_agent('MW-X', 'اسم', 'active', null, null, null) $q$,
  'الوكيل يُرفض بلا معرّف طلب');

select pg_temp.must_fail(
  $q$ select public.upsert_agent('   ', 'اسم', 'active', null, null, gen_random_uuid()) $q$,
  'الوكيل يُرفض بلا رمز');

select pg_temp.must_fail(
  $q$ select public.upsert_agent('MW-Y', 'اسم', 'suspended', null, null, gen_random_uuid()) $q$,
  'حالة خارج القيد تُرفض');

select pg_temp.must_fail(
  $q$ select public.upsert_agent('MW-Y', 'اسم', 'active', 'north', null, gen_random_uuid()) $q$,
  'منطقة خارج القيد تُرفض');

-- ------------------------------------------------------------------
-- ٣ · الباقات: التصنيف مُدخَل مالي
-- ------------------------------------------------------------------

select pg_temp.ok(
  (public.upsert_package('MW-PK', 'باقة', 'PAID_PACKAGE', null,
    '30000000-0000-0000-0000-0000000000b3')->>'category') = 'PAID_PACKAGE',
  'الباقة تُسجَّل بتصنيفها');

select pg_temp.ok(
  (select semantic_category from public.packages where code = 'MW-PK') = 'PAID_PACKAGE',
  'التصنيف يصل إلى الجدول');

select pg_temp.ok(
  (select old_value from public.audit_logs
   where action = 'master.package.saved' and extra = 'code=MW-PK') = 'NONE',
  'أول تسجيلٍ للباقة يقول إنه لم يكن لها تصنيف');

select pg_temp.must_fail(
  $q$ select public.upsert_package('MW-PK', 'باقة', 'FREE', null, gen_random_uuid()) $q$,
  'تصنيف مجهول يُرفض');

-- ------------------------------------------------------------------
-- ٤ · المستخدمون: السبب، والدور المعروف، وحارس القفل
-- ------------------------------------------------------------------

select pg_temp.must_fail(
  $q$ select public.update_user_profile('30000000-0000-0000-0000-0000000000a2',
        null, 'viewer', null, '  ', gen_random_uuid()) $q$,
  'تغيير المستخدم يُرفض بلا سبب');

select pg_temp.must_fail(
  $q$ select public.update_user_profile('30000000-0000-0000-0000-0000000000a2',
        null, 'sultan', null, 'سبب', gen_random_uuid()) $q$,
  'دور غير معرَّف يُرفض');

select pg_temp.must_fail(
  $q$ select public.update_user_profile('30000000-0000-0000-0000-0000000000ff',
        null, null, false, 'سبب', gen_random_uuid()) $q$,
  'مستخدم غير موجود يُرفض');

-- الإداريّ الآخر معطَّل، فهذا آخر إداريّ فعّال.
select pg_temp.must_fail(
  $q$ select public.update_user_profile('30000000-0000-0000-0000-0000000000a1',
        null, null, false, 'سبب', gen_random_uuid()) $q$,
  'تعطيل آخر إداريّ فعّال يُرفض');

select pg_temp.must_fail(
  $q$ select public.update_user_profile('30000000-0000-0000-0000-0000000000a1',
        null, 'viewer', null, 'سبب', gen_random_uuid()) $q$,
  'نزع دور آخر إداريّ فعّال يُرفض');

select pg_temp.ok(
  (select is_active from public.profiles
   where id = '30000000-0000-0000-0000-0000000000a1'),
  'الإداريّ بقي فعّالاً بعد الرفض');

-- ومع إداريٍّ فعّالٍ ثانٍ يصير التعطيل مسموحاً.
select pg_temp.ok(
  (public.update_user_profile('30000000-0000-0000-0000-0000000000a3',
    null, null, true, 'تفعيل الثاني', '30000000-0000-0000-0000-0000000000c1')
   ->>'is_active') = 'true',
  'تفعيل إداريٍّ ثانٍ يمرّ');

select pg_temp.ok(
  (public.update_user_profile('30000000-0000-0000-0000-0000000000a1',
    null, null, false, 'صار غيره', '30000000-0000-0000-0000-0000000000c2')
   ->>'is_active') = 'false',
  'التعطيل يمرّ حين يبقى إداريٌّ غيره');

-- الأول عُطِّل للتوّ، فلم يعد يقرأ سجلّ التدقيق — وهذا في ذاته دليل أن
-- التعطيل نفذ. فالسؤال يُطرح بهوية الإداريّ الفعّال الباقي.
set local request.jwt.claim.sub = '30000000-0000-0000-0000-0000000000a3';

select pg_temp.ok(
  (select count(*) from public.audit_logs
   where action = 'admin.user.updated' and extra like '%reason=صار غيره%') = 1,
  'تغيير الصلاحية مُدقَّق بسببه');

-- ------------------------------------------------------------------
-- ٥ · القدرة شرطٌ لا تزيّن
-- ------------------------------------------------------------------

set local request.jwt.claim.sub = '30000000-0000-0000-0000-0000000000a2';

select pg_temp.must_fail(
  $q$ select public.upsert_agent('MW-V', 'اسم', 'active', null, null, gen_random_uuid()) $q$,
  'من لا يملك agent.manage لا يكتب وكيلاً');

select pg_temp.must_fail(
  $q$ select public.upsert_package('MW-V', 'باقة', 'OTHER', null, gen_random_uuid()) $q$,
  'من لا يملك package.manage لا يكتب باقة');

select pg_temp.must_fail(
  $q$ select public.update_user_profile('30000000-0000-0000-0000-0000000000a3',
        null, 'viewer', null, 'سبب', gen_random_uuid()) $q$,
  'من لا يملك permission.manage لا يغيّر دوراً');

rollback;
