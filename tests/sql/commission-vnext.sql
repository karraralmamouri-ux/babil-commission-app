-- ضمانات محرّك العمولة vNext على قاعدة حقيقية.
-- القيم كلها مُختلَقة. كل تجربة تُثبت قاعدة أو منعاً.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '  ok   ' || p_label;
end;
$$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '  ok   ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

insert into auth.users (id, email) values
  ('c1111111-1111-1111-1111-111111111111', 'adm@fixture.invalid'),
  ('c2222222-2222-2222-2222-222222222222', 'acc@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('c1111111-1111-1111-1111-111111111111', 'AD', 'adm@fixture.invalid', 'admin', true),
  ('c2222222-2222-2222-2222-222222222222', 'AC', 'acc@fixture.invalid', 'accountant', true)
on conflict (id) do update set role = excluded.role, is_active = true;

insert into public.packages (code, name, semantic_category) values
  ('P-35000','P-35000','PAID_PACKAGE'),
  ('P-45000','P-45000','PAID_PACKAGE'),
  ('P-65000','P-65000','PAID_PACKAGE'),
  ('Loan-3','Loan-3','DEBT_SERVICE'),
  ('Diamond','Diamond','UNKNOWN')
on conflict (code) do nothing;

-- ===========================================================================
-- 41. التهيئة
-- ===========================================================================
select '  == configuration ==';

select pg_temp.ok(
  (select tier_basis from public.commission_scheme_versions where version = 1)
    = 'UNIQUE_ACTIVATED_SUBSCRIBERS',
  'أساس الشريحة هو المشتركون المميّزون لا عدد الأحداث');

select pg_temp.ok(
  (select old_zone_scope from public.commission_scheme_versions where version = 1) = 'AGENT'
  and (select new_zone_scope from public.commission_scheme_versions where version = 1) = 'FDT',
  'المنطقة القديمة بالوكيل والجديدة بالكابينة');

-- V1 يطابق التهيئة المقبولة فعلاً في الإنتاج.
select pg_temp.ok(
  (select count(*) from public.commission_package_rates r
   join public.commission_tier_definitions t on t.id = r.tier_definition_id
   where (t.code,r.package_code,r.amount) in (
     ('t1','P-35000',4000),('t1','P-45000',5500),('t1','P-65000',8000),
     ('t2','P-35000',4750),('t2','P-45000',6000),('t2','P-65000',9000),
     ('t3','P-35000',6000),('t3','P-45000',8000),('t3','P-65000',11500))) = 9,
  'V1 يطابق التهيئة المعتمدة في الإنتاج قيمةً بقيمة');

select pg_temp.ok(
  (select min_subscribers from public.commission_tier_definitions where code='t2') = 201
  and (select max_subscribers from public.commission_tier_definitions where code='t3') is null,
  'حدود الشرائح كما هي معتمدة، والعليا مفتوحة');

-- المنشور لا يُعدَّل.
select pg_temp.must_fail(
  $$update public.commission_scheme_versions set tier_basis='QUALIFYING_EVENT_COUNT' where version=1$$,
  'تغيير أساس إصدار منشور مرفوض');
select pg_temp.must_fail(
  $$update public.commission_package_rates set amount=99999
    where tier_definition_id=(select id from public.commission_tier_definitions where code='t1')
      and package_code='P-35000'$$,
  'تغيير سعر في إصدار منشور مرفوض');
select pg_temp.must_fail(
  $$update public.commission_tier_definitions set max_subscribers=999 where code='t1'$$,
  'تغيير حد شريحة في إصدار منشور مرفوض');

-- الحارس المحمي: خدمة الدَّين لا تُعمَّل مهما قالت التهيئة.
select pg_temp.must_fail($$
  insert into public.commission_package_rates (tier_definition_id, package_code, amount, qualifies)
  select id, 'Loan-3', 5000, true from public.commission_tier_definitions where code='t1'
$$, 'خدمة الدَّين لا تُعمَّل ولو أُدخلت في التهيئة');

-- إصدار ثانٍ بحدود ومبالغ مختلفة، بلا سطر كود.
do $$
declare v_s uuid; v_v2 uuid; v_a uuid; v_b uuid;
begin
  select id into v_s from public.commission_schemes where code='COMMISSION_STANDARD';
  insert into public.commission_scheme_versions (scheme_id, version, status, notes)
  values (v_s, 2, 'DRAFT', 'different thresholds and amounts') returning id into v_v2;
  insert into public.commission_tier_definitions
    (scheme_version_id, sequence, code, label_ar, min_subscribers, max_subscribers)
  values (v_v2, 1, 'a', 'A', 0, 99), (v_v2, 2, 'b', 'B', 100, null);
  select id into v_a from public.commission_tier_definitions where scheme_version_id=v_v2 and code='a';
  select id into v_b from public.commission_tier_definitions where scheme_version_id=v_v2 and code='b';
  insert into public.commission_package_rates (tier_definition_id, package_code, amount)
  values (v_a,'P-35000',1111),(v_b,'P-35000',2222);
end;
$$;

select pg_temp.ok(
  (select count(*) from public.commission_tier_definitions t
   join public.commission_scheme_versions v on v.id=t.scheme_version_id where v.version=2) = 2,
  'إصدار ثانٍ بحدود مختلفة بلا تغيير كود');

select pg_temp.ok(
  (select amount from public.commission_package_rates r
   join public.commission_tier_definitions t on t.id=r.tier_definition_id
   join public.commission_scheme_versions v on v.id=t.scheme_version_id
   where v.version=1 and t.code='t1' and r.package_code='P-35000') = 4000,
  'الإصدار الأول لم يتأثر بوجود الثاني');

-- فجوة بين الشرائح تمنع النشر.
do $$
declare v_s uuid; v_v3 uuid; v_x uuid;
begin
  select id into v_s from public.commission_schemes where code='COMMISSION_STANDARD';
  insert into public.commission_scheme_versions (scheme_id, version, status)
  values (v_s, 3, 'DRAFT') returning id into v_v3;
  insert into public.commission_tier_definitions
    (scheme_version_id, sequence, code, label_ar, min_subscribers, max_subscribers)
  values (v_v3, 1, 'g1', 'G1', 0, 50), (v_v3, 2, 'g2', 'G2', 80, null);
  select id into v_x from public.commission_tier_definitions where scheme_version_id=v_v3 and code='g1';
  insert into public.commission_package_rates (tier_definition_id, package_code, amount)
  values (v_x, 'P-35000', 100);
end;
$$;

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select pg_temp.must_fail($$
  select public.publish_commission_version(
    (select id from public.commission_scheme_versions where version=3), current_date, gen_random_uuid())
$$, 'فجوة بين الشرائح تمنع النشر');
reset role;

-- ===========================================================================
-- 40. أساس الشريحة
-- ===========================================================================
select '  == tier basis ==';

-- بيانات مصدر: وكيل بمنطقة قديمة، وكابينة بمنطقة جديدة.
insert into public.agents (id, code, official_name) values
  ('a1111111-1111-1111-1111-111111111111','AG-OLD','وكيل قديم'),
  ('a2222222-2222-2222-2222-222222222222','AG-NEW','وكيل جديد')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution) values
  ('a1111111-1111-1111-1111-111111111111','r.old','mapped'),
  ('a2222222-2222-2222-2222-222222222222','r.new','mapped')
on conflict (alias_key) do nothing;

-- الكابينة 100 داخل مدى 94-119: نطاقها الكابينة بحكم الرقم وحده (LIVE-02)،
-- بصرف النظر عمّا يقوله عمود fdts.zone التشغيلي هنا.
insert into public.fdts (code, label, zone, agent_id)
values ('100','FDT-100','new','a2222222-2222-2222-2222-222222222222')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values ('b1111111-1111-1111-1111-111111111111','ACTIVATION_EVENTS','cycle.xlsx','ck-cycle','v1',
        'c1111111-1111-1111-1111-111111111111','COMPLETE')
on conflict do nothing;

-- المطلوب في §20: مشتركان، ثلاثة أحداث مؤهِّلة.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, event_created_at)
values
  ('b1111111-1111-1111-1111-111111111111','EV-X','sub1','P-35000',false,'r.old','2026-08-05'),
  ('b1111111-1111-1111-1111-111111111111','EV-Y','sub1','P-35000',false,'r.old','2026-08-12'),
  ('b1111111-1111-1111-1111-111111111111','EV-Z','sub2','P-45000',false,'r.old','2026-08-20'),
  -- §21: خدمة دَين مع باقة مدفوعة لمشترك واحد.
  ('b1111111-1111-1111-1111-111111111111','EV-L1','sub3','Loan-3',false,'r.old','2026-08-07'),
  ('b1111111-1111-1111-1111-111111111111','EV-L2','sub3','P-35000',false,'r.old','2026-08-09'),
  -- حدث ملغى، وباقة مجهولة.
  ('b1111111-1111-1111-1111-111111111111','EV-C','sub4','P-35000',true,'r.old','2026-08-10'),
  ('b1111111-1111-1111-1111-111111111111','EV-D','sub5','Diamond',false,'r.old','2026-08-11')
on conflict do nothing;

-- المنطقة الجديدة: كابينة 900، مشتركان وثلاثة أحداث.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('b1111111-1111-1111-1111-111111111111','EV-N1','nsub1','P-35000',false,'r.new','2026-08-03','100'),
  ('b1111111-1111-1111-1111-111111111111','EV-N2','nsub1','P-65000',false,'r.new','2026-08-15','100'),
  ('b1111111-1111-1111-1111-111111111111','EV-N3','nsub2','P-35000',false,'r.new','2026-08-18','100'),
  -- تابعٌ مباشر للشركة على الكابينة نفسها: لا يرفع أساس الشريحة ولا
  -- تنشأ عنه عمولة وكيل. وجوده هنا هو ما يجعل الرقمين أعلاه دليلاً.
  ('b1111111-1111-1111-1111-111111111111','EV-N4','nsub3','P-35000',false,'r.new','2026-08-19','100')
on conflict do nothing;

insert into public.subscriber_identities (username, identity_status, match_method, source_classification, effective_agent_id)
values ('sub1','MATCHED','EXACT_USERNAME','RESELLER','a1111111-1111-1111-1111-111111111111'),
       ('sub2','MATCHED','EXACT_USERNAME','RESELLER','a1111111-1111-1111-1111-111111111111'),
       ('sub3','MATCHED','EXACT_USERNAME','RESELLER','a1111111-1111-1111-1111-111111111111'),
       ('sub5','MATCHED','EXACT_USERNAME','RESELLER','a1111111-1111-1111-1111-111111111111'),
       ('nsub1','MATCHED','EXACT_USERNAME','RESELLER','a2222222-2222-2222-2222-222222222222'),
       ('nsub2','MATCHED','EXACT_USERNAME','RESELLER','a2222222-2222-2222-2222-222222222222'),
       ('nsub3','MATCHED','EXACT_USERNAME','DIRECT_COMPANY',null)
on conflict do nothing;

insert into public.commission_cycles (id, name, period_start, period_end, created_by)
values ('d1111111-1111-1111-1111-111111111111','آب 2026', date '2026-08-01', date '2026-08-31',
        'c1111111-1111-1111-1111-111111111111')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111') as projected \gset
reset role;

-- §20 المطلوب: مشتركان، ثلاثة أحداث — للوكيل القديم.
-- (sub1×2 + sub2×1 مؤهِّلة، وsub3 له حدث مدفوع واحد، وsub5 مجهول الباقة.)
select pg_temp.ok(
  (select unique_activated_subscribers from public.commission_cycle_snapshots
   where scope_type='AGENT' and scope_id='a1111111-1111-1111-1111-111111111111') = 3,
  'المشترك المتكرر يُحسب مرة واحدة في أساس الشريحة');

select pg_temp.ok(
  (select qualifying_event_count from public.commission_cycle_snapshots
   where scope_type='AGENT' and scope_id='a1111111-1111-1111-1111-111111111111') = 4,
  'كل حدث مؤهِّل يُحسب على حدة في الأحداث المُعمَّلة');

select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements
   where cycle_id='d1111111-1111-1111-1111-111111111111'
     and subscriber_key=(select id::text from public.subscriber_identities where username='sub1')) = 2,
  'المشترك المتكرر يكسب عمولة عن كل حدث');

-- §21: خدمة الدَّين لا تُحسب في الأساس ولا في العمولة.
select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id='d1111111-1111-1111-1111-111111111111'
                and activation_event_id='EV-L1'),
  'حدث خدمة الدَّين لا يُنتج استحقاقاً');

select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id='d1111111-1111-1111-1111-111111111111'
            and activation_event_id='EV-L2'),
  'الباقة المدفوعة لصاحب الدَّين تُحتسب');

-- الملغى والمجهول لا يُحتسبان، ولا يُسقَطان بصمت.
select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id='d1111111-1111-1111-1111-111111111111'
                and activation_event_id='EV-C'),
  'الحدث الملغى لا يُحتسب');

select pg_temp.ok(
  exists (select 1 from public.commission_exceptions
          where cycle_id='d1111111-1111-1111-1111-111111111111'
            and activation_event_id='EV-D' and reason_code='UNKNOWN_PACKAGE'),
  'الباقة المجهولة تُسجَّل استثناءً ولا تُسقَط بصمت');

-- §7: نطاق المنطقة الجديدة هو الكابينة.
--
-- على الكابينة 900 ثلاثة مشتركين: nsub1 وnsub2 لوكيل، وnsub3 تابعٌ مباشر
-- للشركة. فالرقم 2 أدناه ليس عدّاً للصفوف بل حكم: التابع المباشر لا يرفع
-- أساس الشريحة. ولو احتُسب لصار 3، ولانتقل الوكيل إلى شريحةٍ أعلى بمشتركٍ
-- لا يعود عليه منه شيء.
select pg_temp.ok(
  (select unique_activated_subscribers from public.commission_cycle_snapshots
   where scope_type='FDT' and scope_id='100') = 2,
  'المنطقة الجديدة: الأساس يُحسب داخل الكابينة، والتابع المباشر لا يرفعه');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where subscriber_key = 'nsub3'),
  'التابع المباشر للشركة لا تنشأ عنه عمولة وكيل');

select pg_temp.ok(
  (select scope_type from public.commission_cycle_snapshots
   where scope_id = '100') = 'FDT',
  'نطاق المنطقة الجديدة يبقى الكابينة');

select pg_temp.ok(
  (select qualifying_event_count from public.commission_cycle_snapshots
   where scope_type='FDT' and scope_id='100') = 3,
  'المنطقة الجديدة: ثلاثة أحداث مُعمَّلة');

select pg_temp.ok(
  (select zone from public.commission_cycle_snapshots where scope_type='FDT' and scope_id='100') = 'new'
  and (select zone from public.commission_cycle_snapshots
       where scope_type='AGENT' and scope_id='a1111111-1111-1111-1111-111111111111') = 'old',
  'المنطقتان تُشتقّان من رقم الكابينة (94-119) لا من عمود fdts.zone اليدوي');

-- الشريحة من عدد المشتركين، والمبلغ من التهيئة.
select pg_temp.ok(
  (select tier_code from public.commission_cycle_snapshots
   where scope_type='AGENT' and scope_id='a1111111-1111-1111-1111-111111111111') = 't1',
  'ثلاثة مشتركين يقعون في الشريحة الأولى');

select pg_temp.ok(
  (select amount from public.commission_event_entitlements
   where cycle_id='d1111111-1111-1111-1111-111111111111' and activation_event_id='EV-Z') = 5500,
  'المبلغ يأتي من تهيئة الشريحة لا من ثابت');

-- §22: الحدث المكرر عبر استيراد متداخل.
select pg_temp.must_fail($$
  insert into public.saas_activation_events
    (import_batch_id, saas_event_id, username, profile_name, raw_parent, event_created_at)
  values ('b1111111-1111-1111-1111-111111111111','EV-X','sub1','P-35000','r.old','2026-08-05')
$$, 'الحدث نفسه لا يدخل مرتين في التاريخ الخام');

select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements
   where cycle_id='d1111111-1111-1111-1111-111111111111' and activation_event_id='EV-X') = 1,
  'الحدث الواحد يُنتج استحقاقاً واحداً');

-- §17: العميل لا يفرض أساس الشريحة.
select pg_temp.ok(
  (select count(*) from information_schema.columns
   where table_name='commission_event_entitlements' and column_name like '%tier_basis%') = 0,
  'الاستحقاق لا يحمل أساساً مُرسَلاً من العميل');

-- الشركة المباشرة ليست أباً مجهولاً — مُكتشَف من بيانات تموز الحقيقية،
-- حيث كانت 18,484 حركة شركة مباشرة تُطلق UNKNOWN_AGENT حاجباً، فتُغرق
-- 52 أباً مجهولاً حقيقياً في ضجيج يمنع الاعتماد إلى الأبد.
insert into public.agent_aliases (agent_id, alias, resolution)
values (null, 'DIRECT_CO_TEST', 'direct_company')
on conflict (alias_key) do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, event_created_at)
values ('b1111111-1111-1111-1111-111111111111','EV-DIRECT2','u-direct2','P-35000',false,
        'DIRECT_CO_TEST','2026-08-06')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111') is not null
  as recalculated;
reset role;

select pg_temp.ok(
  not exists (select 1 from public.commission_exceptions
              where cycle_id='d1111111-1111-1111-1111-111111111111'
                and activation_event_id='EV-DIRECT2' and reason_code='UNKNOWN_AGENT'),
  'الشركة المباشرة لا تُعَدّ أباً مجهولاً');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id='d1111111-1111-1111-1111-111111111111'
                and activation_event_id='EV-DIRECT2'),
  'الشركة المباشرة تبقى مستبعَدة من العمولة');

select pg_temp.ok(
  not exists (select 1 from public.commission_exceptions e
              join public.saas_activation_events s on s.saas_event_id=e.activation_event_id
              where e.cycle_id='d1111111-1111-1111-1111-111111111111'
                and e.reason_code='UNKNOWN_FDT' and s.fdt_code is null),
  'المنطقة القديمة لا تُطالَب بكابينة');

-- LIVE-02: كابينة خارج 94-119 (مسجَّلة أو لا، سيّان) نطاقها وكيل بالتعريف —
-- لا حالة "غير محسومة"، ولا استثناء UNKNOWN_FDT يحجب الاعتماد. القياس على
-- تموز أظهر 2,977 حدثاً على 92 كابينة غير مسجَّلة تحمل 40.8% من الإجمالي،
-- وكانت تُحجَب بالكامل بلا سبب تجاري: النطاق محسوم بالرقم وحده، فلا حاجة
-- لتسجيل الكابينة لتحديده.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values ('b1111111-1111-1111-1111-111111111111','EV-UNREG','u-unreg','P-35000',false,
        'r.old','2026-08-07','99999')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('u-unreg','MATCHED','EXACT_USERNAME','RESELLER',
        'a1111111-1111-1111-1111-111111111111')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111') is not null
  as recalc_unreg;
reset role;

select pg_temp.ok(
  (select zone from public.commission_qualifying_events
   where saas_event_id='EV-UNREG') = 'old',
  'كابينة خارج 94-119 تعطي منطقة وكيل محسومة، لا حالة معلَّقة');

select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id='d1111111-1111-1111-1111-111111111111'
            and activation_event_id='EV-UNREG'),
  'كابينة خارج السجل لم تعد تُحجَب — تُعمَّل بنطاق الوكيل مباشرة');

select pg_temp.ok(
  not exists (select 1 from public.commission_exceptions
              where cycle_id='d1111111-1111-1111-1111-111111111111'
                and activation_event_id='EV-UNREG' and reason_code='UNKNOWN_FDT'),
  'لا استثناء UNKNOWN_FDT بعد اليوم — سقط بلا بديل');

select pg_temp.ok(
  not exists (select 1 from public.commission_exceptions
              where reason_code='UNKNOWN_FDT'),
  'UNKNOWN_FDT لا يُنشأ إطلاقاً بعد LIVE-02');

select pg_temp.ok(
  (select count(*) from public.commission_qualifying_events
   where fdt_code is null and zone = 'old') > 0,
  'غياب الكابينة يبقى منطقةً قديمة مشروعة');

-- ===========================================================================
-- 42. الاعتماد واللقطة
-- ===========================================================================
select '  == snapshot and cycle ==';

-- المصدر غير المُثبت يمنع الاعتماد.
update public.saas_import_batches set completeness_status='UNKNOWN'
where id='b1111111-1111-1111-1111-111111111111';

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111') as reproj \gset
select pg_temp.must_fail($$
  select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111', true, gen_random_uuid())
$$, 'مصدر غير مُثبت الاكتمال يمنع الاعتماد');

select pg_temp.ok(
  exists (select 1 from public.commission_exceptions
          where cycle_id='d1111111-1111-1111-1111-111111111111'
            and reason_code='SOURCE_INCOMPLETE' and blocks_finalization),
  'نقص المصدر يُسجَّل استثناءً حاجباً');
reset role;

-- الاعتماد بعد إثبات الاكتمال ومعالجة الاستثناءات.
update public.saas_import_batches set completeness_status='COMPLETE'
where id='b1111111-1111-1111-1111-111111111111';

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111') as reproj2 \gset

-- الباقة المجهولة تبقى حاجبة حتى تُراجَع صراحةً. هذا هو المقصود: الاعتماد
-- لا يمرّ فوق غموض، ولو ثبت اكتمال المصدر.
select pg_temp.must_fail($$
  select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111', true, gen_random_uuid())
$$, 'الباقة المجهولة تحجب الاعتماد ولو اكتمل المصدر');

select public.resolve_commission_exception(
  (select id from public.commission_exceptions
   where cycle_id='d1111111-1111-1111-1111-111111111111'
     and reason_code='UNKNOWN_PACKAGE' and status='OPEN' limit 1),
  'WAIVED', 'باقة قيد التصنيف، لا تُعمَّل هذه الدورة', gen_random_uuid()) as waived \gset

select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111', true, gen_random_uuid()) as finalv \gset
reset role;

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='commission.exception.resolved'),
  'مراجعة الاستثناء مُدقَّقة');

select pg_temp.ok(
  (select status from public.commission_cycles where id='d1111111-1111-1111-1111-111111111111')='FINALIZED',
  'الدورة تُعتمد بمصدر مُثبت');

select pg_temp.ok(
  (select count(*) from public.commission_cycle_snapshots
   where cycle_id='d1111111-1111-1111-1111-111111111111' and finalized_at is not null) >= 2,
  'اللقطات المعتمدة محفوظة لكل نطاق');

-- اللقطة المعتمدة لا تتغيّر.
select pg_temp.must_fail($$
  update public.commission_cycle_snapshots set unique_activated_subscribers=999
  where cycle_id='d1111111-1111-1111-1111-111111111111'
$$, 'اللقطة المعتمدة غير قابلة للتعديل');

-- المعتمدة لا يُعاد حسابها.
set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select pg_temp.must_fail(
  $$select public.calculate_commission_cycle('d1111111-1111-1111-1111-111111111111')$$,
  'الدورة المعتمدة لا يُعاد حسابها');
reset role;

-- تغيّر التهيئة أو المصدر لاحقاً لا يمسّ اللقطة.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, raw_parent, event_created_at)
values ('b1111111-1111-1111-1111-111111111111','EV-LATE','sub9','P-35000','r.old','2026-08-25')
on conflict do nothing;

-- الأربعة لا الثلاثة: منذ LIVE-02 تُحتسب EV-UNREG أيضاً ضمن نطاق الوكيل
-- (كابينتها 99999 خارج 94-119)، فالأساس المجمَّد هنا أربعة لا ثلاثة —
-- والمقصود يبقى نفسه: EV-LATE الوارد بعد الاعتماد لا يغيّر هذا الرقم.
select pg_temp.ok(
  (select unique_activated_subscribers from public.commission_cycle_snapshots
   where scope_type='AGENT' and scope_id='a1111111-1111-1111-1111-111111111111') = 4,
  'حدث ورد بعد الاعتماد لا يُغيّر اللقطة');

-- إعادة الفتح بلا مال مُرحَّل مسموحة ومُدقَّقة.
set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.reopen_commission_cycle('d1111111-1111-1111-1111-111111111111','مراجعة مصدر', gen_random_uuid()) as reop \gset
reset role;

select pg_temp.ok(
  (select status from public.commission_cycles where id='d1111111-1111-1111-1111-111111111111')='UNDER_REVIEW',
  'دورة معتمدة بلا مال مُرحَّل يجوز فتحها');

select pg_temp.ok(
  (select count(*) from public.commission_cycle_snapshots
   where cycle_id='d1111111-1111-1111-1111-111111111111' and finalized_at is not null) >= 2,
  'إعادة الفتح تُبقي اللقطات المعتمدة دليلاً');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='commission.cycle.reopened'),
  'إعادة الفتح مُدقَّقة');

-- ===========================================================================
-- 25/26. إقفال دورة أجور التنصيب وإعادة فتحها
-- ===========================================================================
select '  == installation cycle ==';

insert into public.installation_cycles (id, name, start_date, end_date, created_by)
values ('e1111111-1111-1111-1111-111111111111','تنصيب آب', date '2026-08-01', date '2026-08-31',
        'c1111111-1111-1111-1111-111111111111')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select public.close_installation_cycle('e1111111-1111-1111-1111-111111111111','إقفال شهري', gen_random_uuid()) as closed \gset
reset role;

select pg_temp.ok(
  (select status from public.installation_cycles where id='e1111111-1111-1111-1111-111111111111')='CLOSED',
  'دورة أجور التنصيب تُقفل');

select pg_temp.ok(
  (select snapshot from public.installation_cycles
   where id='e1111111-1111-1111-1111-111111111111') is not null,
  'الإقفال يُنتج لقطة تشرح النتيجة');

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select pg_temp.must_fail(
  $$select public.reopen_installation_cycle('e1111111-1111-1111-1111-111111111111','', gen_random_uuid())$$,
  'إعادة الفتح بلا سبب مرفوضة');
select public.reopen_installation_cycle('e1111111-1111-1111-1111-111111111111','تصحيح إدخال', gen_random_uuid()) as reop2 \gset
reset role;

select pg_temp.ok(
  (select status from public.installation_cycles where id='e1111111-1111-1111-1111-111111111111')='UNDER_REVIEW',
  'دورة مقفلة بلا مال مُرحَّل يجوز فتحها');

-- مع مال مُرحَّل: الفتح مرفوض.
insert into public.installation_batches (id, period, created_by, file_name, file_checksum)
values ('f1111111-1111-1111-1111-111111111111','2026-08','c1111111-1111-1111-1111-111111111111','x.xlsx','ck-x')
on conflict do nothing;
insert into public.installation_entitlements
  (id, batch_id, period, subscriber_id, reseller, remaining, stage, amount, created_by)
values ('f2222222-2222-2222-2222-222222222222','f1111111-1111-1111-1111-111111111111','2026-08',
        'sx','وكيل',7000,'P3',3000,'c1111111-1111-1111-1111-111111111111')
on conflict do nothing;
insert into public.installation_payment_batches (id, name, cycle_id, prepared_by)
values ('f3333333-3333-3333-3333-333333333333','دفعة','e1111111-1111-1111-1111-111111111111',
        'c1111111-1111-1111-1111-111111111111')
on conflict do nothing;
insert into public.installation_payment_batch_items
  (batch_id, entitlement_id, subscriber_id, stage_code, amount, status)
values ('f3333333-3333-3333-3333-333333333333','f2222222-2222-2222-2222-222222222222',
        'sx','P3',3000,'PAID')
on conflict do nothing;

update public.installation_cycles
set status='CLOSED', closed_by='c1111111-1111-1111-1111-111111111111', closed_at=now()
where id='e1111111-1111-1111-1111-111111111111';

select pg_temp.ok(
  public.installation_cycle_posted_amount('e1111111-1111-1111-1111-111111111111') = 3000,
  'المال المُرحَّل يُقاس من بنود الدفعات');

set local role authenticated;
set local request.jwt.claim.sub = 'c1111111-1111-1111-1111-111111111111';
select pg_temp.must_fail(
  $$select public.reopen_installation_cycle('e1111111-1111-1111-1111-111111111111','محاولة', gen_random_uuid())$$,
  'دورة فيها مال مُرحَّل لا تُفتح');
reset role;

select pg_temp.ok(
  (select status from public.installation_cycles where id='e1111111-1111-1111-1111-111111111111')='CLOSED',
  'الدورة المدفوعة بقيت مقفلة');

-- ===========================================================================
-- 37. الصلاحيات
-- ===========================================================================
select '  == permissions ==';

select pg_temp.ok(
  public.effective_permission('c2222222-2222-2222-2222-222222222222','commission.execute_payment'),
  'المحاسب يرث تنفيذ دفع العمولة');

select pg_temp.ok(
  not public.effective_permission('c2222222-2222-2222-2222-222222222222','commission.finalize'),
  'المحاسب لا يعتمد دورة');

select pg_temp.ok(
  not public.effective_permission('c2222222-2222-2222-2222-222222222222','commission.configure'),
  'المحاسب لا يهيّئ المخطط');

select pg_temp.ok(
  not public.effective_permission('c2222222-2222-2222-2222-222222222222','commission.reopen'),
  'المحاسب لا يعيد فتح دورة');

-- منح قدرة واحدة بلا ترقية دور.
insert into public.user_permission_overrides
  (user_id, capability_key, effect, granted_by, reason)
values ('c2222222-2222-2222-2222-222222222222','commission.finalize','GRANT',
        'c1111111-1111-1111-1111-111111111111','تفويض صريح');
select pg_temp.ok(
  public.effective_permission('c2222222-2222-2222-2222-222222222222','commission.finalize')
  and (select role from public.profiles where id='c2222222-2222-2222-2222-222222222222')='accountant',
  'قدرة واحدة تُمنح بلا ترقية إلى مدير');

set local role authenticated;
set local request.jwt.claim.sub = 'c2222222-2222-2222-2222-222222222222';
select pg_temp.must_fail(
  $$select public.publish_commission_version(
      (select id from public.commission_scheme_versions where version=2), current_date, gen_random_uuid())$$,
  'المحاسب لا ينشر إصداراً عبر RPC');
reset role;

-- ===========================================================================
-- 43/49. سلامة مالية
-- ===========================================================================
select '  == financial integrity ==';

select pg_temp.ok(
  (select coalesce(sum(paid),0) from public.commission_rows) = 0,
  'لا عمولة قديمة دُفعت أثناء التجارب');

select pg_temp.ok(
  (select count(*) from public.commission_rows) = (select count(*) from public.commission_rows),
  'صفوف العمولة القديمة لم تُحذف');

select pg_temp.ok(
  (select count(*) from public.commission_cycles where engine_version='LEGACY') = 0
  and (select count(*) from public.commission_cycles where engine_version='VNEXT') >= 1,
  'كل دورة تحمل محرّكها، فلا يختلط قديم بجديد');

select pg_temp.ok(
  (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
   where c.relnamespace='public'::regnamespace
     and c.relname in ('commission_cycles','commission_event_entitlements',
       'commission_cycle_snapshots','commission_exceptions','commission_schemes',
       'commission_scheme_versions','commission_tier_definitions','commission_package_rates')
     and a.privilege_type <> 'SELECT'
     and a.grantee::regrole::text in ('authenticated','anon','public')) = 0,
  'لا صلاحية كتابة لأي دور تطبيقي على جداول العمولة');

rollback;
