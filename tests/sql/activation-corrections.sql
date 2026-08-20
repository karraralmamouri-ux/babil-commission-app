-- تصحيح التفعيلات، وعدّ الكابينة بنافذة الدورة.
--
-- عيبان مختلفان جمعهما بلاغٌ واحد: مشغّل يعدّ 40 ويرى 41.
--
--   الأول أن شاشة الكابينة كانت تعدّ كل ما وصل منذ أوّل ملفّ وتعرضه إلى
--   جانب أرقام الدورة، فيُقرأ مجموعُ التاريخ على أنه تفعيلات الشهر.
--
--   والثاني أنه لم يكن للمشغّل طريق يصحّح به رقماً يعرف أنه خطأ إلا أن
--   يُعدّل الناتج المحسوب أو الصفّ المستورَد — وكلاهما يُفقد ما يُراجَع.
--
-- معزول بنطاق تسمية AC-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '               ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '               ok ' || p_label;
end;
$$;

begin;

select '              == activation corrections ==';

insert into auth.users (id, email) values
  ('ac000000-0000-0000-0000-0000000000a1', 'ac-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ac000000-0000-0000-0000-0000000000a1','ACA','ac-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by, status)
values ('ac000000-0000-0000-0000-0000000000a2','AC دورة',
        date '2027-05-01', date '2027-05-31','VNEXT',
        'ac000000-0000-0000-0000-0000000000a1','UNDER_REVIEW')
on conflict do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('ac000000-0000-0000-0000-0000000000a3','ACTIVATION_EVENTS','ac.xlsx',
        'ac-checksum','v1','ac000000-0000-0000-0000-0000000000a1','COMPLETE')
on conflict do nothing;

insert into public.packages (code, name, semantic_category) values
  ('P-35000','P-35000','PAID_PACKAGE'),
  ('Loan-3','Loan-3','DEBT_SERVICE')
on conflict (code) do nothing;

insert into public.agents (id, code, official_name)
values ('ac000000-0000-0000-0000-0000000000a4','AC-AG','وكيل AC')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution)
values ('ac000000-0000-0000-0000-0000000000a4','ac.parent','mapped')
on conflict (alias_key) do nothing;

-- كابينة في المنطقة الجديدة: نطاقها الكابينة نفسها.
insert into public.fdts (code, label, zone, agent_id)
values ('AC-115','FDT-AC-115','new','ac000000-0000-0000-0000-0000000000a4')
on conflict (code) do nothing;

-- ثلاثة أحداث داخل الدورة، وحدثان قبلها بشهر.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('ac000000-0000-0000-0000-0000000000a3','AC-IN-1','ac-sub1','P-35000',false,'ac.parent','2027-05-05','AC-115'),
  ('ac000000-0000-0000-0000-0000000000a3','AC-IN-2','ac-sub2','P-35000',false,'ac.parent','2027-05-06','AC-115'),
  ('ac000000-0000-0000-0000-0000000000a3','AC-IN-3','ac-sub3','P-35000',false,'ac.parent','2027-05-07','AC-115'),
  -- تاريخيّان: خارج نافذة الدورة تماماً
  ('ac000000-0000-0000-0000-0000000000a3','AC-OLD-1','ac-sub9','P-35000',false,'ac.parent','2027-04-05','AC-115'),
  ('ac000000-0000-0000-0000-0000000000a3','AC-OLD-2','ac-sub8','P-35000',false,'ac.parent','2027-04-06','AC-115'),
  -- مشترك مكرَّر: حدثان له داخل الدورة
  ('ac000000-0000-0000-0000-0000000000a3','AC-DUP','ac-sub1','P-35000',false,'ac.parent','2027-05-20','AC-115'),
  -- خدمة دين: لا تُحتسب
  ('ac000000-0000-0000-0000-0000000000a3','AC-DEBT','ac-sub4','Loan-3',false,'ac.parent','2027-05-08','AC-115'),
  -- تابع مباشر للشركة
  ('ac000000-0000-0000-0000-0000000000a3','AC-DC','ac-dc1','P-35000',false,'ac.parent','2027-05-09','AC-115')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('ac-sub1','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4'),
       ('ac-sub2','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4'),
       ('ac-sub3','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4'),
       ('ac-sub4','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4'),
       ('ac-sub8','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4'),
       ('ac-sub9','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4'),
       ('ac-dc1','MATCHED','EXACT_USERNAME','DIRECT_COMPANY',null),
       ('ac-new1','MATCHED','EXACT_USERNAME','RESELLER','ac000000-0000-0000-0000-0000000000a4')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-0000000000a1';

select public.calculate_commission_cycle('ac000000-0000-0000-0000-0000000000a2', false);

-- ------------------------------------------------------------------
-- ١ · العدّ محصورٌ بنافذة الدورة
-- ------------------------------------------------------------------
--
-- ثمانية أحداث للكابينة في الجدول، منها اثنان قبل الدورة وواحد خدمة دين
-- وواحد لتابعٍ مباشر. فالمؤهَّل أربعة: sub1 مرّتين، وsub2، وsub3.

select pg_temp.ok(
  (public.fdt_cycle_events('AC-115', 'ac000000-0000-0000-0000-0000000000a2')->>'lifetime_events')::int = 8,
  'الإجمالي التاريخي ثمانية أحداث');

select pg_temp.ok(
  (public.fdt_cycle_events('AC-115', 'ac000000-0000-0000-0000-0000000000a2')->>'total')::int = 4,
  'تفعيلات الدورة أربعة — والتاريخي لا يُضخّمها');

select pg_temp.ok(
  (public.fdt_cycle_events('AC-115', 'ac000000-0000-0000-0000-0000000000a2')->>'unique_subscribers')::int = 3,
  'المشتركون الفريدون ثلاثة — المكرَّر يزيد الأحداث لا أساس الشريحة');

select pg_temp.ok(
  (select unique_activated_subscribers from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 3
  and (select qualifying_event_count from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 4,
  'اللقطة تطابق الشاشة: 3 مشتركين و4 أحداث');

select pg_temp.ok(
  (select r->>'cycle_events' from jsonb_array_elements(
     public.page_fdt_mapping('AC-115',null,null,null,50,0,
       'ac000000-0000-0000-0000-0000000000a2')->'rows') r) = '4',
  'شاشة الربط تعرض تفعيلات الدورة لا مجموع التاريخ');

select pg_temp.ok(
  (select r->>'lifetime_events' from jsonb_array_elements(
     public.page_fdt_mapping('AC-115',null,null,null,50,0,
       'ac000000-0000-0000-0000-0000000000a2')->'rows') r) = '8',
  'والتاريخي معروضٌ باسمه إلى جانبه');

-- ------------------------------------------------------------------
-- ٢ · التابع المباشر لا يدخل شريحة الوكيل
-- ------------------------------------------------------------------

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id='ac000000-0000-0000-0000-0000000000a2'
                and subscriber_key = 'ac-dc1'),
  'التابع المباشر للشركة لا تنشأ عنه عمولة وكيل');

select pg_temp.ok(
  (select scope_type from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 'FDT',
  'نطاق المنطقة الجديدة يبقى الكابينة');

-- ------------------------------------------------------------------
-- ٣ · الاستبعاد
-- ------------------------------------------------------------------

select public.exclude_activation_event('ac000000-0000-0000-0000-0000000000a2',
  'AC-IN-2', 'اختبار الاستبعاد', 'ac000000-0000-0000-0000-0000000000c1');
select public.calculate_commission_cycle('ac000000-0000-0000-0000-0000000000a2', false);

select pg_temp.ok(
  (select qualifying_event_count from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 3
  and (select unique_activated_subscribers from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 2,
  'الحدث المُستبعَد لم يعد يُحتسب بعد إعادة الحساب');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id='ac000000-0000-0000-0000-0000000000a2'
                and activation_event_id = 'AC-IN-2'),
  'ولا أثر له في استحقاقات الدورة');

-- والمصدر لم يُمسّ.
select pg_temp.ok(
  exists (select 1 from public.saas_activation_events
          where saas_event_id = 'AC-IN-2' and username = 'ac-sub2'
            and coalesce(canceled,false) = false),
  'الصفّ المستورَد باقٍ كما ورد');

select pg_temp.ok(
  (select count(*) from public.saas_activation_events where fdt_code='AC-115') = 8,
  'عدد صفوف المصدر لم يتغيّر');

-- ------------------------------------------------------------------
-- ٤ · الإضافة
-- ------------------------------------------------------------------

select public.add_activation_correction('ac000000-0000-0000-0000-0000000000a2',
  'ac-new1', 'P-35000', timestamptz '2027-05-15 12:00:00+03', 'AC-115',
  'اختبار الإضافة', 'ac000000-0000-0000-0000-0000000000c2', 'ac.parent');
select public.calculate_commission_cycle('ac000000-0000-0000-0000-0000000000a2', false);

select pg_temp.ok(
  (select qualifying_event_count from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 4
  and (select unique_activated_subscribers from public.commission_cycle_snapshots
   where cycle_id='ac000000-0000-0000-0000-0000000000a2' and scope_id='AC-115') = 3,
  'الحدث المُضاف يُحتسب مرّةً واحدة، ويرفع أساس الشريحة بمشتركه');

select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements x
   where x.cycle_id='ac000000-0000-0000-0000-0000000000a2'
     and x.activation_event_id like 'MANUAL-%') = 1,
  'مرّةً واحدة لا أكثر');

select pg_temp.ok(
  (select count(*) from public.saas_activation_events where username_key='ac-new1') = 0,
  'ولم يُكتب في المصدر صفٌّ للمشترك المُضاف');

-- ------------------------------------------------------------------
-- ٥ · الحراسة
-- ------------------------------------------------------------------

select pg_temp.must_fail(
  $q$ select public.add_activation_correction('ac000000-0000-0000-0000-0000000000a2',
        '   ', 'P-35000', timestamptz '2027-05-15 12:00:00+03', 'AC-115',
        'سبب', gen_random_uuid()) $q$,
  'الإضافة المجهولة تُرفض — الشريحة تُحسب بالمشتركين الفريدين');

select pg_temp.must_fail(
  $q$ select public.add_activation_correction('ac000000-0000-0000-0000-0000000000a2',
        'ac-new2', 'P-35000', timestamptz '2027-08-15 12:00:00+03', 'AC-115',
        'سبب', gen_random_uuid()) $q$,
  'حدثٌ خارج نافذة الدورة يُرفض');

select pg_temp.must_fail(
  $q$ select public.exclude_activation_event('ac000000-0000-0000-0000-0000000000a2',
        'AC-OLD-1', 'سبب', gen_random_uuid()) $q$,
  'استبعاد حدثٍ خارج النافذة يُرفض — تصحيحٌ بلا أثر يُربك');

select pg_temp.must_fail(
  $q$ select public.exclude_activation_event('ac000000-0000-0000-0000-0000000000a2',
        'AC-IN-3', '   ', gen_random_uuid()) $q$,
  'الاستبعاد بلا سبب يُرفض');

-- ------------------------------------------------------------------
-- ٦ · التكرار والإلغاء
-- ------------------------------------------------------------------

select pg_temp.ok(
  (public.exclude_activation_event('ac000000-0000-0000-0000-0000000000a2',
    'AC-IN-2', 'إعادة', 'ac000000-0000-0000-0000-0000000000c1')->>'replayed') = 'true',
  'إعادة الطلب نفسه لا تُنشئ تصحيحاً ثانياً');

select pg_temp.ok(
  (select count(*) from public.activation_corrections
   where cycle_id='ac000000-0000-0000-0000-0000000000a2'
     and correction_type='EXCLUDE' and status='ACTIVE') = 1,
  'استبعادٌ واحد فعّال لا اثنان');

select pg_temp.ok(
  (select count(*) from public.audit_logs
   where action in ('commission.activation.excluded','commission.activation.added')) >= 2,
  'كل تصحيح مُدقَّق بفاعله وسببه');

rollback;

-- ------------------------------------------------------------------
-- ٧ · حصانة التصحيح
-- ------------------------------------------------------------------
--
-- تُفحص بصلاحية المالك قصداً: المستخدم لا يصل إلى الجدول أصلاً (لا سياسة
-- كتابة له)، فلو فُحصت بهويته لمرّ الاختبار دون أن يلمس المُشغِّل.

begin;

insert into auth.users (id, email)
values ('ac000000-0000-0000-0000-0000000000b1','ac2@fixture.invalid')
on conflict do nothing;
insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by, status)
values ('ac000000-0000-0000-0000-0000000000b2','AC2 دورة',
        date '2027-06-01', date '2027-06-30','VNEXT',
        'ac000000-0000-0000-0000-0000000000b1','UNDER_REVIEW')
on conflict do nothing;

insert into public.activation_corrections
  (id, cycle_id, correction_type, source_event_id, reason, request_id, created_by)
values ('ac000000-0000-0000-0000-0000000000b3',
        'ac000000-0000-0000-0000-0000000000b2','EXCLUDE','AC-ANY','الأصل',
        'ac000000-0000-0000-0000-0000000000b4','ac000000-0000-0000-0000-0000000000b1');

select pg_temp.must_fail(
  $q$ update public.activation_corrections set reason='تبديل'
       where id='ac000000-0000-0000-0000-0000000000b3' $q$,
  'مضمون التصحيح لا يُعدَّل بعد كتابته');

select pg_temp.must_fail(
  $q$ update public.activation_corrections set source_event_id='AC-OTHER'
       where id='ac000000-0000-0000-0000-0000000000b3' $q$,
  'ولا يُغيَّر الحدث الذي يشير إليه');

select pg_temp.must_fail(
  $q$ delete from public.activation_corrections
       where id='ac000000-0000-0000-0000-0000000000b3' $q$,
  'ولا يُحذف — يُلغى ويبقى أثره');

select pg_temp.ok(
  (select reason from public.activation_corrections
   where id='ac000000-0000-0000-0000-0000000000b3') = 'الأصل',
  'والسبب المكتوب أوّلاً هو الباقي');

rollback;
