-- سلامة التسميات العربية، وتضييق حارس المراحل.
--
-- الخلفية: المستخدم كان يرى «؟؟؟» مكان اسم الصلاحية. لم يكن عيب عرض — كانت
-- البيانات نفسها فاسدة: 65 تسمية عربية زرعتها المهاجرات وصلت الإنتاج
-- مستبدَلةً بعلامات استفهام، لأن سكربت النشر مرّر النصّ عبر الصدفة.
--
-- الفحص هنا بالبايتات لا بالمظهر: العربية متعدّدة البايتات بالضرورة، فتساوي
-- المحارف والبايتات يعني أنها فُقدت. والمظهر يخدع: طرفيّة تعرض «؟» بهدوء.
--
-- ويُختبر معه تضييق trg_protect_published_stages: التسمية تُصحَّح، وكل شرط
-- مالي يبقى ممنوعاً.
--
-- معزول بنطاق تسمية AL-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '           ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then return '           ok ' || p_label;
end;
$$;

begin;

select '          == arabic label integrity ==';

-- ---------------------------------------------------------------------------
-- 1. لا تسمية مفقودة العربية
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.permission_capabilities
   where octet_length(label_ar) = length(label_ar)) = 0,
  'كل تسمية صلاحية نصٌّ عربي سليم');

select pg_temp.ok(
  (select count(*) from public.role_templates
   where octet_length(label_ar) = length(label_ar)) = 0,
  'كل تسمية دور سليمة');

select pg_temp.ok(
  (select count(*) from public.installation_hold_reasons
   where octet_length(label_ar) = length(label_ar)) = 0,
  'كل سبب إيقاف سليم');

select pg_temp.ok(
  (select count(*) from public.installation_stage_definitions
   where octet_length(display_name_ar) = length(display_name_ar)) = 0,
  'كل اسم مرحلة سليم');

-- ولا علامات استفهام متتالية في أي تسمية: هذا شكل الفساد بعينه.
select pg_temp.ok(
  (select count(*) from public.permission_capabilities where label_ar ~ '\?\?') = 0,
  'لا علامات استفهام مكان التسميات');

-- ---------------------------------------------------------------------------
-- 2. كل قدرة تملك تسمية — فلا تحتاج الواجهة قاموساً موازياً
--
-- الكتالوج في القاعدة هو المرجع. بناء قاموس ثانٍ في الواجهة يعني مصدرَي
-- حقيقة يفترقان بصمت عند إضافة قدرة جديدة.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.permission_capabilities
   where label_ar is null or btrim(label_ar) = '') = 0,
  'لا قدرة بلا تسمية في الكتالوج');

select pg_temp.ok(
  (select count(*) from public.permission_capabilities
   where domain is null or btrim(domain) = '') = 0,
  'كل قدرة تحمل نطاقها');

-- وكل قدرة يمنحها قالب دور موجودة في الكتالوج: منحةٌ لقدرة مجهولة تُعرَض
-- بلا اسم مهما أُصلحت التسميات.
select pg_temp.ok(
  (select count(*) from public.role_template_capabilities rc
   where not exists (select 1 from public.permission_capabilities c
                     where c.key = rc.capability_key)) = 0,
  'لا منحة لقدرة خارج الكتالوج');

-- ---------------------------------------------------------------------------
-- 3. الحارس ضُيِّق ولم يُضعَّف
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values ('a1000000-0000-0000-0000-0000000000f1', 'al@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('a1000000-0000-0000-0000-0000000000f1','AL','al@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

-- نسخة منشورة فعلاً، فالحارس عليها حيّ.
select pg_temp.ok(
  exists (select 1 from public.installation_scheme_versions where status <> 'DRAFT'),
  'توجد نسخة منشورة يُختبر عليها الحارس');

-- التسمية تُصحَّح.
update public.installation_stage_definitions
set display_name_ar = 'الدفعة الأولى — اختبار'
where code = 'P1'
  and scheme_version_id in (select id from public.installation_scheme_versions where status <> 'DRAFT');

select pg_temp.ok(
  (select count(*) from public.installation_stage_definitions
   where display_name_ar = 'الدفعة الأولى — اختبار') = 1,
  'اسم العرض قابل للتصحيح في نسخة منشورة');

-- وكل شرط مالي يبقى ممنوعاً.
select pg_temp.must_fail(
  'update public.installation_stage_definitions set amount = amount + 1
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'المبلغ في نسخة منشورة ممنوع');

select pg_temp.must_fail(
  'update public.installation_stage_definitions set expected_remaining = expected_remaining + 1
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'المتبقّي المتوقَّع ممنوع');

select pg_temp.must_fail(
  'update public.installation_stage_definitions set sequence = sequence + 10
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'الترتيب ممنوع');

select pg_temp.must_fail(
  'update public.installation_stage_definitions set code = ''PX''
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'الرمز ممنوع');

select pg_temp.must_fail(
  'update public.installation_stage_definitions set requires_invoice = not requires_invoice
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'اشتراط الفاتورة ممنوع');

select pg_temp.must_fail(
  'update public.installation_stage_definitions set is_terminal = not is_terminal
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'النهائية ممنوعة');

-- والإدراج والحذف ممنوعان كما كانا.
select pg_temp.must_fail(
  'delete from public.installation_stage_definitions
   where code = ''P1'' and scheme_version_id in
     (select id from public.installation_scheme_versions where status <> ''DRAFT'')',
  'حذف مرحلة منشورة ممنوع');

select pg_temp.must_fail(
  'insert into public.installation_stage_definitions
     (scheme_version_id, sequence, code, display_name_ar, amount, expected_remaining)
   select id, 99, ''PZ'', ''جديدة'', 1000, 0
   from public.installation_scheme_versions where status <> ''DRAFT'' limit 1',
  'إضافة مرحلة إلى نسخة منشورة ممنوعة');

-- ---------------------------------------------------------------------------
-- 4. لا أثر مالي من هذه المهاجرة
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select coalesce(sum(amount), 0) from public.installation_stage_definitions
   where code = 'P1') > 0,
  'مبالغ المراحل باقية كما هي');

rollback;
