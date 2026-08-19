-- العائدية المؤرَّخة، والصدفة، والخطّ الزمني.
--
-- الخطر في هذا العمل أنه مالي: تغيير العائدية اليوم يجب ألّا يُعيد كتابة
-- الأمس، وإضافة النموذج يجب ألّا تُحرّك رقماً قائماً واحداً.
--
-- معزول بنطاق تسمية SO-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '            ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then return '            ok ' || p_label;
end;
$$;

begin;

select '           == subscriber ownership ==';

insert into auth.users (id, email) values ('50000000-0000-0000-0000-0000000000b1','so@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('50000000-0000-0000-0000-0000000000b1','SO','so@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.agents (id, code, official_name) values
  ('50000000-0000-0000-0000-0000000000b2','SO-A','وكيل أ'),
  ('50000000-0000-0000-0000-0000000000b3','SO-B','وكيل ب')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 1. الحلّ عند لحظة الحدث
--
-- مثال المستخدم حرفياً: شركة حتى ١٥ آب، ثم وكيل بعدها.
-- ---------------------------------------------------------------------------

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('so-sub-1','DIRECT_COMPANY', null,
   timestamptz '2026-08-01 00:00+03', timestamptz '2026-08-16 00:00+03',
   'اختبار', '50000000-0000-0000-0000-0000000000b1'),
  ('so-sub-1','RESELLER','50000000-0000-0000-0000-0000000000b2',
   timestamptz '2026-08-16 00:00+03', null,
   'اختبار', '50000000-0000-0000-0000-0000000000b1');

select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('so-sub-1', timestamptz '2026-08-10 12:00+03'))
    = 'DIRECT_COMPANY',
  'حدث ١٠ آب يخصّ الشركة');

select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('so-sub-1', timestamptz '2026-08-20 12:00+03'))
    = 'RESELLER',
  'حدث ٢٠ آب يخصّ الوكيل');

select pg_temp.ok(
  (select agent_id from public.subscriber_ownership_at('so-sub-1', timestamptz '2026-08-20 12:00+03'))
    = '50000000-0000-0000-0000-0000000000b2',
  'الوكيل المالك هو المحدَّد في الفترة');

-- الحدّ نفسه: البداية شاملة والنهاية حصرية، فلا لحظة تخصّ مالكَين.
select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('so-sub-1', timestamptz '2026-08-16 00:00+03'))
    = 'RESELLER',
  'لحظة الحدّ تخصّ الفترة الجديدة — الحدّ الأدنى شامل');

select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('so-sub-1', timestamptz '2026-08-15 23:59:59+03'))
    = 'DIRECT_COMPANY',
  'ما قبل الحدّ بثانية يخصّ الفترة السابقة');

-- ما قبل أوّل فترة لا تغطّيه فترة صريحة، فيعود إلى الاشتقاق.
select pg_temp.ok(
  not exists (select 1 from public.subscriber_ownership_at('so-sub-1', timestamptz '2026-07-01 00:00+03')),
  'ما قبل أوّل فترة لا يُنسب صراحةً بل يعود للاشتقاق');

-- ---------------------------------------------------------------------------
-- 2. لا فترتان متناقضتان
-- ---------------------------------------------------------------------------

select pg_temp.must_fail(
  'insert into public.subscriber_ownership
     (username_key, ownership_type, agent_id, effective_from, effective_to, reason)
   values (''so-sub-1'',''RESELLER'',''50000000-0000-0000-0000-0000000000b3'',
     timestamptz ''2026-08-05 00:00+03'', timestamptz ''2026-08-10 00:00+03'', ''تداخل'')',
  'الفترة المتداخلة مرفوضة');

-- ---------------------------------------------------------------------------
-- 3. شكل النوع
-- ---------------------------------------------------------------------------

select pg_temp.must_fail(
  'insert into public.subscriber_ownership (username_key, ownership_type, effective_from, reason)
   values (''so-sub-9'',''RESELLER'', now(), ''بلا وكيل'')',
  'الوكالة بلا وكيل مرفوضة');

select pg_temp.must_fail(
  'insert into public.subscriber_ownership
     (username_key, ownership_type, agent_id, effective_from, reason)
   values (''so-sub-9'',''DIRECT_COMPANY'',''50000000-0000-0000-0000-0000000000b2'', now(), ''شركة بوكيل'')',
  'النوع الشركاتي بوكيل مرفوض — بابُ عمولة لا تُستحقّ');

select pg_temp.must_fail(
  'insert into public.subscriber_ownership (username_key, ownership_type, effective_from, reason)
   values (''so-sub-9'',''SOMETHING'', now(), ''نوع مخترَع'')',
  'نوع خارج القائمة مرفوض');

select pg_temp.must_fail(
  'insert into public.subscriber_ownership
     (username_key, ownership_type, effective_from, effective_to, reason)
   values (''so-sub-9'',''DIRECT_COMPANY'', now(), now() - interval ''1 day'', ''نهاية قبل بداية'')',
  'نهاية قبل البداية مرفوضة');

-- ---------------------------------------------------------------------------
-- 4. الشركة لا تُنتج عمولة ولا شريحة ولا استثناء «وكيل مجهول»
-- ---------------------------------------------------------------------------

insert into public.packages (code, name, semantic_category)
values ('P-35000','P-35000','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution) values
  (null, 'so.ftth', 'direct_company'),
  (null, 'so.office', 'office'),
  ('50000000-0000-0000-0000-0000000000b2', 'so.reseller', 'mapped')
on conflict (alias_key) do nothing;

select pg_temp.ok(
  public.parent_ownership_type('so.ftth') = 'DIRECT_COMPANY',
  'الأب المعروف شركةً يُقرأ FTTH User');

select pg_temp.ok(
  public.parent_ownership_type('so.office') = 'DIRECT_COMPANY',
  'الأب المعروف مكتباً يُقرأ Office');

select pg_temp.ok(
  public.parent_ownership_type('so.reseller') = 'RESELLER',
  'الأب المرتبط بوكيل يُقرأ وكالة');

select pg_temp.ok(
  public.parent_ownership_type('so.unknown') = 'NEEDS_REVIEW',
  'الأب المجهول لا يُصنَّف شركةً بالخطأ');

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values ('50000000-0000-0000-0000-0000000000b4','ACTIVATION_EVENTS','so.xlsx','so-sum','v1',
        '50000000-0000-0000-0000-0000000000b1','COMPLETE')
on conflict do nothing;

insert into public.fdts (code, label, zone, agent_id)
values ('SO-FDT','FDT-SO','new','50000000-0000-0000-0000-0000000000b2')
on conflict (code) do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, event_created_at, fdt_code)
values
  ('50000000-0000-0000-0000-0000000000b4','SO-EV-F','so-ftth-1','P-35000',false,'so.ftth',
   timestamptz '2026-12-05 10:00+03','SO-FDT'),
  ('50000000-0000-0000-0000-0000000000b4','SO-EV-O','so-office-1','P-35000',false,'so.office',
   timestamptz '2026-12-06 10:00+03','SO-FDT'),
  ('50000000-0000-0000-0000-0000000000b4','SO-EV-R','so-res-1','P-35000',false,'so.reseller',
   timestamptz '2026-12-07 10:00+03','SO-FDT')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values
  ('so-ftth-1','MATCHED','EXACT_USERNAME','DIRECT_COMPANY', null),
  ('so-office-1','MATCHED','EXACT_USERNAME','DIRECT_COMPANY', null),
  ('so-res-1','MATCHED','EXACT_USERNAME','RESELLER','50000000-0000-0000-0000-0000000000b2')
on conflict do nothing;

insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('50000000-0000-0000-0000-0000000000b5','SO كانون', date '2026-12-01', date '2026-12-31',
        'VNEXT','50000000-0000-0000-0000-0000000000b1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '50000000-0000-0000-0000-0000000000b1';
select public.calculate_commission_cycle('50000000-0000-0000-0000-0000000000b5') is not null as ran;
reset role;

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id='50000000-0000-0000-0000-0000000000b5'
                and activation_event_id in ('SO-EV-F','SO-EV-O')),
  'الشركة — FTTH وOffice — لا تُنتج عمولة وكيل');

select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id='50000000-0000-0000-0000-0000000000b5' and activation_event_id='SO-EV-R'),
  'الوكيل يُنتج عمولته كالمعتاد');

select pg_temp.ok(
  (select coalesce(sum(unique_activated_subscribers),0) from public.commission_cycle_snapshots
   where cycle_id='50000000-0000-0000-0000-0000000000b5') = 1,
  'الشركة لا تُساهم في أساس الشريحة');

select pg_temp.ok(
  not exists (select 1 from public.commission_exceptions
              where cycle_id='50000000-0000-0000-0000-0000000000b5'
                and reason_code='UNKNOWN_AGENT'
                and activation_event_id in ('SO-EV-F','SO-EV-O')),
  'الشركة لا تُنتج استثناء «وكيل مجهول»');

-- ---------------------------------------------------------------------------
-- 5. الصدفة تقول الحقيقة خارج المدى
--
-- العيب الذي تُصلحه: الإجمالي كان محمولاً في الصفوف، فتُخفيه الصفحةُ الفارغة
-- ويظهر 22,727 صفراً.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = '50000000-0000-0000-0000-0000000000b1';

select pg_temp.ok(
  (public.page_commission_exceptions(
     p_cycle_id => '50000000-0000-0000-0000-0000000000b5', p_limit => 1) ? 'total'),
  'الصدفة تحمل حقل الإجمالي دائماً');

select pg_temp.ok(
  (public.page_commission_exceptions(
     p_cycle_id => '50000000-0000-0000-0000-0000000000b5',
     p_limit => 1, p_offset => 99999) ->> 'total')::bigint
  = (public.page_commission_exceptions(
     p_cycle_id => '50000000-0000-0000-0000-0000000000b5', p_limit => 1) ->> 'total')::bigint,
  'الإزاحة خارج المدى لا تُصفّر الإجمالي');

select pg_temp.ok(
  (public.page_commission_exceptions(
     p_cycle_id => '50000000-0000-0000-0000-0000000000b5',
     p_limit => 1, p_offset => 99999) ? 'out_of_range'),
  'الصدفة تُعلن إن كانت الصفحة خارج المدى');

select pg_temp.ok(
  jsonb_array_length(public.page_commission_exceptions(
     p_cycle_id => '50000000-0000-0000-0000-0000000000b5',
     p_limit => 1, p_offset => 99999) -> 'rows') = 0,
  'الصفحة خارج المدى فارغة الصفوف');

reset role;
insert into public.installation_subscribers (subscriber_id, reseller, fdt, start_date, created_by)
select 'SO-SUB-' || g, 'وكيل أ', 'SO-FDT', date '2026-01-01', '50000000-0000-0000-0000-0000000000b1'
from generate_series(1, 4) g on conflict do nothing;
set local role authenticated;
set local request.jwt.claim.sub = '50000000-0000-0000-0000-0000000000b1';

-- المقياس الحقيقي: مجموعة فيها صفوف، وصفحة خارج مداها.
select pg_temp.ok(
  (public.page_installation_subscribers(p_limit => 1) ->> 'total')::bigint
  = (public.page_installation_subscribers(p_limit => 1, p_offset => 999999) ->> 'total')::bigint,
  'إجمالي المشتركين لا يتغيّر بإزاحة خارج المدى');

select pg_temp.ok(
  jsonb_array_length(public.page_installation_subscribers(p_limit => 1, p_offset => 999999) -> 'rows') = 0
  and (public.page_installation_subscribers(p_limit => 1, p_offset => 999999) ->> 'out_of_range')::boolean,
  'الصفحة خارج المدى فارغة ومُعلَنة كذلك');

-- والخطّ الزمني بلا سقف صامت.
select pg_temp.ok(
  (public.page_subscriber_timeline('nope') ->> 'total')::bigint = 0,
  'خطّ زمني بلا أحداث إجماليه صفر لا خطأ');

select pg_temp.ok(
  (public.page_subscriber_timeline('nope') ? 'out_of_range'),
  'الخطّ الزمني يستعمل الصدفة نفسها');

reset role;

-- ---------------------------------------------------------------------------
-- 8. الاسم الأصلي لا يُعاد تسميته أبداً
--
-- التصنيف يقول ما هو الأب مالياً؛ ولا يغيّر ما اسمه. المشغّل يبحث في ملف
-- SaaS عن 'hrins.office' بعينه، فإن عرضنا له 'Office' انقطع الجسر بين
-- الشاشة والمصدر.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = '50000000-0000-0000-0000-0000000000b1';

select pg_temp.ok(
  (public.classify_parent('SO.Company.Parent', 'DIRECT_COMPANY', null, 'اختبار',
     gen_random_uuid()) ->> 'ownership_after') = 'DIRECT_COMPANY',
  'التصنيف شركةً ينجح');

select pg_temp.ok(
  (select alias from public.agent_aliases
   where alias_key = 'so.company.parent') = 'SO.Company.Parent',
  'الاسم يُحفَظ بحروفه كما ورد — لا توحيد ولا ترجمة');

select pg_temp.ok(
  public.parent_ownership_type('SO.Company.Parent') = 'DIRECT_COMPANY',
  'وتصنيفه يُقرأ شركةً مباشرة');

-- والتفصيل يعرض الاسم الأصلي لا تسميةً مخترعة.
select pg_temp.ok(
  not exists (
    select 1 from jsonb_array_elements(public.company_parent_breakdown() -> 'parents') p
    where p ->> 'parent_name' in ('Office', 'FTTH User', 'Direct Company')),
  'التفصيل لا يخترع أسماء عرض');

-- التصنيف الثلاثي وحده مقبول.
select pg_temp.must_fail(
  'select public.classify_parent(''X'', ''FTTH_USER'', null, ''ن'', gen_random_uuid())',
  'صنف خارج الثلاثة مرفوض');

select pg_temp.must_fail(
  'select public.classify_parent(''X'', ''RESELLER'', null, ''ن'', gen_random_uuid())',
  'وكالة بلا وكيل مرفوضة');

select pg_temp.must_fail(
  'select public.classify_parent(''X'', ''DIRECT_COMPANY'',
     ''50000000-0000-0000-0000-0000000000b2'', ''ن'', gen_random_uuid())',
  'شركة بوكيل مرفوضة');

-- والقيم القديمة تُترجَم ولا تنكسر.
select pg_temp.ok(
  public.normalize_ownership_type('FTTH_USER') = 'DIRECT_COMPANY'
  and public.normalize_ownership_type('OFFICE') = 'DIRECT_COMPANY'
  and public.normalize_ownership_type('RESELLER') = 'RESELLER'
  and public.normalize_ownership_type('nonsense') = 'NEEDS_REVIEW',
  'القيم السابقة تُترجَم إلى الثلاثية');

-- تكرار الطلب لا يُنتج أثراً ثانياً.
select pg_temp.ok(
  (select (public.classify_parent('SO.Idem', 'NEEDS_REVIEW', null, 'ن',
     '50000000-0000-0000-0000-00000000cafe') ->> 'idempotent')::boolean) = false,
  'أوّل تصنيف ليس مكرَّراً');

select pg_temp.ok(
  (select (public.classify_parent('SO.Idem', 'NEEDS_REVIEW', null, 'ن',
     '50000000-0000-0000-0000-00000000cafe') ->> 'idempotent')::boolean) = true,
  'إعادة الطلب نفسه لا تُكرّر الأثر');

-- الشاشتان تقولان الرقم نفسه.
--
-- أوّل صياغة جمعت المشتركين لكل أبٍ، فعُدّ من ظهر تحت اسمَي أبٍ مرّتين
-- (TTH_Users في أيار وFTTH_Users في تموز — الاسم نفسه فقد حرفاً في تصدير
-- أيار). فقال التفصيل 26,371 وقال العدّاد 15,978 عن الشيء ذاته.
select pg_temp.ok(
  (public.company_parent_breakdown() ->> 'total_subscribers')::bigint
  = coalesce((public.company_subscriber_counts() ->> 'DIRECT_COMPANY')::bigint, 0),
  'إجمالي التفصيل يساوي عدّاد الشركة — لا ازدواج');

reset role;

rollback;
