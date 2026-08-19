-- نقل العائدية: مؤرَّخ، لا رجعي، ولا يجرّ أجور التنصيب معه.
--
-- الخطر الذي تحرسه هذه الاختبارات مالي بحت: نقلٌ يُكتب بأثر رجعي يُعيد
-- حساب مالٍ صُرف، ونقلٌ يجرّ التنصيب معه يمنح وكيلاً أجرَ عملٍ نفّذه غيره.
--
-- معزول بنطاق تسمية ST-.

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

select '           == subscriber transfer ==';

insert into auth.users (id, email) values ('60000000-0000-0000-0000-0000000000a1','st@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('60000000-0000-0000-0000-0000000000a1','ST','st@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.agents (id, code, official_name) values
  ('60000000-0000-0000-0000-0000000000a2','ST-A','وكيل النقل أ'),
  ('60000000-0000-0000-0000-0000000000a3','ST-B','وكيل النقل ب')
on conflict (code) do nothing;

-- دورة محسومة (مدفوعة) في كانون الأول، وأخرى مفتوحة في كانون الثاني.
insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, status,
   created_by, finalized_by, finalized_at)
values
  ('60000000-0000-0000-0000-0000000000a4','ST كانون الأول', date '2026-12-01', date '2026-12-31',
   'VNEXT','PAID','60000000-0000-0000-0000-0000000000a1',
   '60000000-0000-0000-0000-0000000000a1', now()),
  ('60000000-0000-0000-0000-0000000000a5','ST كانون الثاني', date '2027-01-01', date '2027-01-31',
   'VNEXT','UNDER_REVIEW','60000000-0000-0000-0000-0000000000a1', null, null)
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '60000000-0000-0000-0000-0000000000a1';

-- ---------------------------------------------------------------------------
-- 1. النقل يفتح فترةً ويغلق التي قبلها — ولا يحذف شيئاً
-- ---------------------------------------------------------------------------

select public.transfer_subscriber(
  'st-sub-1', 'DIRECT_COMPANY', null, timestamptz '2027-01-05 00:00+03',
  'FTTH_Users', 'أوّل تسجيل', '60000000-0000-0000-0000-00000000ab01');

select public.transfer_subscriber(
  'st-sub-1', 'RESELLER', '60000000-0000-0000-0000-0000000000a2',
  timestamptz '2027-01-20 00:00+03', null, 'انتقل إلى وكيل',
  '60000000-0000-0000-0000-00000000ab02');

select pg_temp.ok(
  (select count(*) from public.subscriber_ownership where username_key = 'st-sub-1') = 2,
  'الفترة السابقة تُغلق ولا تُحذف');

select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('st-sub-1', timestamptz '2027-01-10 12:00+03'))
    = 'DIRECT_COMPANY',
  'حدثٌ قبل الحدّ يبقى للمالك السابق');

select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('st-sub-1', timestamptz '2027-01-25 12:00+03'))
    = 'RESELLER',
  'وحدثٌ بعده يخصّ المالك الجديد');

-- الحدّ نفسه للمالك الجديد: المدى [from, to) — الأدنى داخلٌ والأعلى خارج.
select pg_temp.ok(
  (select ownership_type from public.subscriber_ownership_at('st-sub-1', timestamptz '2027-01-20 00:00+03'))
    = 'RESELLER',
  'لحظة الحدّ نفسها تخصّ المالك الجديد');

-- ---------------------------------------------------------------------------
-- 2. الاسم الأصلي يُحفظ كما ورد
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select company_parent from public.subscriber_ownership
   where username_key = 'st-sub-1' and ownership_type = 'DIRECT_COMPANY') = 'FTTH_Users',
  'اسم الأب يُحفظ بحروفه ولا يُستبدل بتسمية التصنيف');

-- ---------------------------------------------------------------------------
-- 3. لا كتابة داخل دورة محسومة
-- ---------------------------------------------------------------------------

select pg_temp.must_fail(
  'select public.transfer_subscriber(''st-sub-2'', ''RESELLER'',
     ''60000000-0000-0000-0000-0000000000a2'', timestamptz ''2026-12-15 00:00+03'',
     null, ''محاولة رجعية'', gen_random_uuid())',
  'النقل إلى داخل دورة مدفوعة مرفوض');

select pg_temp.ok(
  (select count(*) from public.subscriber_ownership where username_key = 'st-sub-2') = 0,
  'ولا يُترك أثرٌ جزئي بعد الرفض');

-- والمعاينة تقول السبب قبل المحاولة.
select pg_temp.ok(
  (public.transfer_preview('st-sub-2', 'RESELLER', '60000000-0000-0000-0000-0000000000a2',
     timestamptz '2026-12-15 00:00+03') -> 'blocked_by' ->> 'code') = 'FINALIZED_CYCLE',
  'المعاينة تُعلن الحاجب قبل المحاولة');

-- ---------------------------------------------------------------------------
-- 4. شروط القرار
-- ---------------------------------------------------------------------------

select pg_temp.must_fail(
  'select public.transfer_subscriber(''st-sub-3'', ''RESELLER'', null,
     timestamptz ''2027-01-10 00:00+03'', null, ''بلا وكيل'', gen_random_uuid())',
  'وكالة بلا وكيل مرفوضة');

select pg_temp.must_fail(
  'select public.transfer_subscriber(''st-sub-3'', ''DIRECT_COMPANY'',
     ''60000000-0000-0000-0000-0000000000a2'', timestamptz ''2027-01-10 00:00+03'',
     null, ''شركة بوكيل'', gen_random_uuid())',
  'شركة بوكيل مرفوضة');

select pg_temp.must_fail(
  'select public.transfer_subscriber(''st-sub-3'', ''RESELLER'',
     ''60000000-0000-0000-0000-0000000000a2'', timestamptz ''2027-01-10 00:00+03'',
     null, ''  '', gen_random_uuid())',
  'نقل بلا سبب مرفوض');

select pg_temp.must_fail(
  'select public.transfer_subscriber(''st-sub-3'', ''RESELLER'',
     ''60000000-0000-0000-0000-0000000000a2'', timestamptz ''2027-01-10 00:00+03'',
     null, ''بلا معرّف طلب'', null)',
  'نقل بلا معرّف طلب مرفوض');

-- تكرار الطلب نفسه لا يفتح فترةً ثانية.
select public.transfer_subscriber(
  'st-sub-4', 'DIRECT_COMPANY', null, timestamptz '2027-01-08 00:00+03',
  null, 'أوّل', '60000000-0000-0000-0000-00000000ab04');

select pg_temp.ok(
  (public.transfer_subscriber('st-sub-4', 'DIRECT_COMPANY', null,
     timestamptz '2027-01-08 00:00+03', null, 'أوّل',
     '60000000-0000-0000-0000-00000000ab04') ->> 'idempotent')::boolean = true,
  'إعادة الطلب نفسه لا تفتح فترة ثانية');

select pg_temp.ok(
  (select count(*) from public.subscriber_ownership where username_key = 'st-sub-4') = 1,
  'وعدد الفترات يبقى واحداً');

-- ونقلٌ قبل بداية الفترة الجارية يُرفض بدل أن يُخمَّن ترتيبه.
select pg_temp.must_fail(
  'select public.transfer_subscriber(''st-sub-4'', ''RESELLER'',
     ''60000000-0000-0000-0000-0000000000a2'', timestamptz ''2027-01-02 00:00+03'',
     null, ''قبل الجارية'', gen_random_uuid())',
  'نقل يبدأ قبل الفترة الجارية مرفوض');

-- ---------------------------------------------------------------------------
-- 5. أجور التنصيب لا تُنقل — والسؤال يُرفع بدل أن يُخمَّن
-- ---------------------------------------------------------------------------

reset role;

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values ('60000000-0000-0000-0000-0000000000a6','st-inst-1','وكيل النقل أ',
        'ST-FDT', date '2026-11-01', 150000, '60000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- النسخة المنشورة تُقرأ لا تُثبَّت: معرّفها يتغيّر مع إعادة بناء القاعدة.
insert into public.installation_enrollments
  (subscriber_id, scheme_version_id, origin, effective_agent_id, agent_name_at_enrollment,
   fdt_code, zone, current_stage_code, status, enrolled_by)
select 'st-inst-1', v.id, 'HISTORICAL_BASELINE','60000000-0000-0000-0000-0000000000a2','وكيل النقل أ',
       'ST-FDT','new','P2','ACTIVE','60000000-0000-0000-0000-0000000000a1'
from public.installation_scheme_versions v
where v.status = 'PUBLISHED'
order by v.created_at
limit 1
on conflict do nothing;

insert into public.installation_payment_history
  (subscriber_uuid, stage, amount, payment_date, created_by)
values ('60000000-0000-0000-0000-0000000000a6','P1', 50000, date '2026-11-15',
        '60000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '60000000-0000-0000-0000-0000000000a1';

-- المعاينة تقول صراحةً إن التنصيب لا ينتقل، وترفع السؤال التجاري.
select pg_temp.ok(
  (public.transfer_preview('st-inst-1', 'RESELLER',
     '60000000-0000-0000-0000-0000000000a3', timestamptz '2027-01-10 00:00+03')
   -> 'installation' ->> 'moves_with_transfer')::boolean = false,
  'المعاينة تقول إن التنصيب لا ينتقل مع العائدية');

select pg_temp.ok(
  (public.transfer_preview('st-inst-1', 'RESELLER',
     '60000000-0000-0000-0000-0000000000a3', timestamptz '2027-01-10 00:00+03')
   -> 'business_decision' ->> 'code') = 'NEEDS_BUSINESS_DECISION',
  'ومرحلةٌ جارية عند وكيل آخر تُرفع قراراً تجارياً');

select pg_temp.ok(
  (public.transfer_preview('st-inst-1', 'RESELLER',
     '60000000-0000-0000-0000-0000000000a3', timestamptz '2027-01-10 00:00+03')
   -> 'business_decision' ->> 'paid_so_far')::bigint = 50000,
  'والسؤال يحمل ما قُبض فعلاً حتى الآن');

-- النقل يقع، ولا يلمس تسجيل التنصيب.
select public.transfer_subscriber(
  'st-inst-1', 'RESELLER', '60000000-0000-0000-0000-0000000000a3',
  timestamptz '2027-01-10 00:00+03', null, 'نقل مع تنصيب جارٍ',
  '60000000-0000-0000-0000-00000000ab05');

select pg_temp.ok(
  (select effective_agent_id from public.installation_enrollments where subscriber_id = 'st-inst-1')
    = '60000000-0000-0000-0000-0000000000a2',
  'وكيل التنصيب يبقى من نفّذ المراحل، لا من استلم العائدية');

select pg_temp.ok(
  (select agent_name_at_enrollment from public.installation_enrollments where subscriber_id = 'st-inst-1')
    = 'وكيل النقل أ',
  'واسمه وقت التسجيل يبقى كما هو');

select pg_temp.ok(
  (select current_stage_code from public.installation_enrollments where subscriber_id = 'st-inst-1') = 'P2',
  'والمرحلة لا تُحرَّك بالنقل');

select pg_temp.ok(
  (select sum(amount) from public.installation_payment_history
   where subscriber_uuid = '60000000-0000-0000-0000-0000000000a6') = 50000,
  'وما دُفع لا يُعاد حسابه');

-- والقرار المعلّق يظهر في القائمة التي يقرأها مركز العمل.
select pg_temp.ok(
  exists (
    select 1 from jsonb_array_elements(public.pending_business_decisions(50, 0) -> 'rows') r
    where r ->> 'subscriber_id' = 'st-inst-1'
      and (r ->> 'paid_so_far')::bigint = 50000),
  'القرار المعلّق يظهر في قائمة مركز العمل');

-- ---------------------------------------------------------------------------
-- 6. الحارس
-- ---------------------------------------------------------------------------

reset role;

insert into auth.users (id, email) values ('60000000-0000-0000-0000-0000000000a9','st-weak@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('60000000-0000-0000-0000-0000000000a9','ST ضعيف','st-weak@fixture.invalid','viewer',true)
on conflict (id) do update set role='viewer', is_active=true;

select pg_temp.must_fail(
  'set local role authenticated;
   set local request.jwt.claim.sub = ''60000000-0000-0000-0000-0000000000a9'';
   select public.transfer_subscriber(''st-sub-9'', ''DIRECT_COMPANY'', null,
     timestamptz ''2027-01-10 00:00+03'', null, ''بلا صلاحية'', gen_random_uuid())',
  'النقل يرفض من لا يملك subscriber.correct_attribution');

rollback;
