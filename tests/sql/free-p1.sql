-- Free P1: NEW ZONE لكل FDT مستقلاً، OLD ZONE بإجمالي الموزّع، بلا ازدواج.
--
-- كل صفوف commission_cycle_snapshots هنا تُدرَج مباشرة (finalized) بدل توليدها من
-- أحداث تفعيل حقيقية بالآلاف — عزل مقصود لمنطق Free P1 نفسه عن تجميع المحرّك
-- الأصلي (زون قديم يُجمَع بالوكيل، جديد بالكابينة)، وهو تجميعٌ مُغطًّى فعلاً في
-- tests/sql/commission-vnext.sql وtests/sql/activation-corrections.sql — لا يُعاد
-- اختباره هنا، بل يُفترَض صحيحاً وتُدرَج نتيجته المتوقَّعة مباشرة (صفٌّ واحد لكل
-- موزّع في OLD ZONE، صفٌّ واحد لكل كابينة في NEW ZONE — وهذا بالضبط ما تنتجه
-- commission_scheme_versions.old_zone_scope='AGENT' / new_zone_scope='FDT' اليوم).
--
-- معزول بنطاق تسمية FB1-.

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

select '              == free p1 ==';

insert into auth.users (id, email) values
  ('fb100000-0000-0000-0000-0000000000a1','fb1-admin@fixture.invalid'),
  ('fb100000-0000-0000-0000-0000000000a2','fb1-viewer@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('fb100000-0000-0000-0000-0000000000a1','FB1-AD','fb1-admin@fixture.invalid','admin',true),
  ('fb100000-0000-0000-0000-0000000000a2','FB1-VI','fb1-viewer@fixture.invalid','viewer',true)
on conflict (id) do update set role = excluded.role, is_active = true;

-- الدورة الأساسية: معتمدة، تشير إلى إصدار المخطط المنشور نفسه الذي بُذرت له
-- عتبة 350 في المهاجرة.
insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, scheme_version_id,
   status, finalized_by, finalized_at, created_by)
select 'fb100000-0000-0000-0000-0000000000c1','FB1 دورة معتمدة',
       date '2027-06-01', date '2027-06-30','VNEXT', v.id,
       'FINALIZED','fb100000-0000-0000-0000-0000000000a1', now(),
       'fb100000-0000-0000-0000-0000000000a1'
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

-- دورة غير معتمَدة، لاختبار الرفض قبل الاعتماد.
insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, scheme_version_id,
   status, created_by)
select 'fb100000-0000-0000-0000-0000000000c2','FB1 دورة غير معتمدة',
       date '2027-07-01', date '2027-07-31','VNEXT', v.id,
       'UNDER_REVIEW', 'fb100000-0000-0000-0000-0000000000a1'
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

-- مخطط وإصدار منفصلان تماماً، بلا عتبة Free P1 مهيَّأة له — لاختبار الفشل
-- الصريح حين لا يوجد قرار مُهيَّأ، لا افتراضاً مخترعاً.
insert into public.commission_schemes (id, code, name_ar)
values ('fb100000-0000-0000-0000-0000000000e1','FB1_NO_RULE','مخطط بلا قاعدة Free P1')
on conflict (code) do nothing;
insert into public.commission_scheme_versions
  (id, scheme_id, version, status, published_at)
values ('fb100000-0000-0000-0000-0000000000e2','fb100000-0000-0000-0000-0000000000e1',
        1, 'PUBLISHED', now())
on conflict (scheme_id, version) do nothing;
insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, scheme_version_id,
   status, finalized_by, finalized_at, created_by)
values ('fb100000-0000-0000-0000-0000000000c3','FB1 دورة بلا عتبة',
        date '2027-08-01', date '2027-08-31','VNEXT','fb100000-0000-0000-0000-0000000000e2',
        'FINALIZED','fb100000-0000-0000-0000-0000000000a1', now(),
        'fb100000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- مخطط ثالث معزول، لاختبار set_free_p1_threshold وحدها دون مسّ عتبة الإنتاج
-- المبذورة (350) التي تعتمد عليها بقية السيناريوهات في هذا الملف.
insert into public.commission_schemes (id, code, name_ar)
values ('fb100000-0000-0000-0000-0000000000e3','FB1_CFG_TEST','مخطط لاختبار التهيئة فقط')
on conflict (code) do nothing;
insert into public.commission_scheme_versions
  (id, scheme_id, version, status, published_at)
values ('fb100000-0000-0000-0000-0000000000e4','fb100000-0000-0000-0000-0000000000e3',
        1, 'PUBLISHED', now())
on conflict (scheme_id, version) do nothing;

-- ---------------------------------------------------------------------------
-- لقطات NEW ZONE: كل صفّ كابينة مستقلة (scope_type='FDT'، zone='new').
-- ---------------------------------------------------------------------------
insert into public.commission_cycle_snapshots (
  id, cycle_id, scheme_version_id, scope_type, scope_id, scope_label, zone,
  unique_activated_subscribers, qualifying_event_count, finalized_at)
select x.id::uuid, 'fb100000-0000-0000-0000-0000000000c1', v.id, 'FDT', x.scope_id, x.scope_id, 'new',
       x.n, x.n, now()
from public.commission_scheme_versions v,
     (values
       ('fb100000-0000-0000-0000-00000000f100','100', 420),  -- فوق العتبة بوضوح
       ('fb100000-0000-0000-0000-00000000f101','101', 370),  -- فوق العتبة، كابينة ثانية مستقلة
       ('fb100000-0000-0000-0000-00000000f102','102', 300),  -- دون العتبة
       ('fb100000-0000-0000-0000-00000000f103','103', 349),  -- حدّياً تحت العتبة بواحد
       ('fb100000-0000-0000-0000-00000000f104','104', 350)   -- حدّياً عند العتبة تماماً
     ) as x(id, scope_id, n)
where v.version = 1
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- لقطات OLD ZONE: صفّ واحد لكل موزّع (scope_type='AGENT'، zone='old') يحمل
-- إجمالي مشتركيه المميّزين عبر كل كابيناته معاً — وهذا ما ينتجه المحرّك فعلاً،
-- لا تجميعاً منفصلاً يخترعه هذا الاختبار.
-- ---------------------------------------------------------------------------
insert into public.commission_cycle_snapshots (
  id, cycle_id, scheme_version_id, scope_type, scope_id, scope_label, zone,
  unique_activated_subscribers, qualifying_event_count, finalized_at)
select x.id::uuid, 'fb100000-0000-0000-0000-0000000000c1', v.id, 'AGENT', x.scope_id, x.scope_id, 'old',
       x.n, x.n, now()
from public.commission_scheme_versions v,
     (values
       -- مثال صاحب القرار حرفياً: FDT A=200 + FDT B=180 = 380، منح واحد لا اثنين.
       ('fb100000-0000-0000-0000-00000000a200','reseller-1', 380),
       ('fb100000-0000-0000-0000-00000000a201','reseller-2', 300)  -- دون العتبة إجمالاً
     ) as x(id, scope_id, n)
where v.version = 1
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'fb100000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- 1. الرفض الصريح قبل أي منح.
-- ===========================================================================

select pg_temp.must_fail(
  $$select public.grant_free_p1('fb100000-0000-0000-0000-0000000000c2', gen_random_uuid())$$,
  'دورة غير معتمدة: رفض صريح، لا منح على بيانات متوقَّعة');

select pg_temp.must_fail(
  $$select public.grant_free_p1('fb100000-0000-0000-0000-0000000000c3', gen_random_uuid())$$,
  'دورة معتمدة بلا عتبة Free P1 مُهيَّأة: رفض صريح، لا عتبة افتراضية مخترعة');

select pg_temp.must_fail(
  $$insert into public.free_p1_grants
      (cycle_id, scheme_version_id, rule_threshold, zone, scope_type, scope_id, unique_activated_subscribers)
    select 'fb100000-0000-0000-0000-0000000000c1', v.id, 350, 'old', 'FDT', 'x', 400
    from public.commission_scheme_versions v where v.version = 1$$,
  'قيد free_p1_grants_zone_scope_match يرفض OLD ZONE مع scope_type=FDT مباشرة');

select pg_temp.must_fail(
  $$insert into public.free_p1_grants
      (cycle_id, scheme_version_id, rule_threshold, zone, scope_type, scope_id, unique_activated_subscribers)
    select 'fb100000-0000-0000-0000-0000000000c1', v.id, 350, 'new', 'FDT', 'x', 100
    from public.commission_scheme_versions v where v.version = 1$$,
  'قيد free_p1_grants_meets_threshold يرفض منحاً دون العتبة مباشرة حتى بتجاوز الدالة');

-- ===========================================================================
-- 2. المنح الفعلي — أول استدعاء.
-- ===========================================================================

select public.grant_free_p1('fb100000-0000-0000-0000-0000000000c1',
  'fb1a0000-0000-0000-0000-000000000001') as g1 \gset

select pg_temp.ok((:'g1' is not null), 'أول استدعاء يعيد نتيجة');

select pg_temp.ok(
  ((:'g1')::jsonb ->> 'eligible_scopes')::int = 4,
  'أربعة نطاقات مؤهَّلة: FDT 100/101/104 وreseller-1');
select pg_temp.ok(
  ((:'g1')::jsonb ->> 'newly_granted')::int = 4,
  'كلها مُنحت حديثاً في الاستدعاء الأول');
select pg_temp.ok(
  ((:'g1')::jsonb ->> 'already_granted')::int = 0,
  'لا شيء كان ممنوحاً قبله');

-- --- NEW ZONE: كل كابينة مستقلة، لا تجميع بينها ---------------------------

select pg_temp.ok(
  exists(select 1 from public.free_p1_grants
         where cycle_id='fb100000-0000-0000-0000-0000000000c1'
           and scope_type='FDT' and scope_id='100'),
  'FDT 100 (420) فوق العتبة: مُنح');
select pg_temp.ok(
  exists(select 1 from public.free_p1_grants
         where cycle_id='fb100000-0000-0000-0000-0000000000c1'
           and scope_type='FDT' and scope_id='101'),
  'FDT 101 (370) فوق العتبة: كابينة ثانية مستقلة مُنحت أيضاً');
select pg_temp.ok(
  not exists(select 1 from public.free_p1_grants
             where cycle_id='fb100000-0000-0000-0000-0000000000c1'
               and scope_type='FDT' and scope_id='102'),
  'FDT 102 (300) دون العتبة: لا منح');
select pg_temp.ok(
  not exists(select 1 from public.free_p1_grants
             where cycle_id='fb100000-0000-0000-0000-0000000000c1'
               and scope_type='FDT' and scope_id='103'),
  'FDT 103 (349) حدّياً دون العتبة بواحد: لا منح');
select pg_temp.ok(
  exists(select 1 from public.free_p1_grants
         where cycle_id='fb100000-0000-0000-0000-0000000000c1'
           and scope_type='FDT' and scope_id='104'),
  'FDT 104 (350) عند العتبة تماماً: يُمنح — الحد الأدنى شامل');

-- --- OLD ZONE: إجمالي الموزّع، لا ضرب بعدد الكابينات ------------------------

select pg_temp.ok(
  (select count(*) from public.free_p1_grants
   where cycle_id='fb100000-0000-0000-0000-0000000000c1'
     and zone='old' and scope_id='reseller-1') = 1,
  'reseller-1 (200+180=380 إجمالاً): منح واحد بالضبط، لا اثنان');
select pg_temp.ok(
  not exists(select 1 from public.free_p1_grants
             where cycle_id='fb100000-0000-0000-0000-0000000000c1'
               and zone='old' and scope_id='reseller-2'),
  'reseller-2 (300 إجمالاً): دون العتبة، لا منح');
select pg_temp.ok(
  not exists(select 1 from public.free_p1_grants
             where cycle_id='fb100000-0000-0000-0000-0000000000c1'
               and zone='old' and scope_type='FDT'),
  'لا صفّ OLD ZONE بمستوى الكابينة إطلاقاً — القيد نفسه يمنعه بنيوياً');

select pg_temp.ok(
  (select count(*) from public.free_p1_grants
   where cycle_id='fb100000-0000-0000-0000-0000000000c1') = 4,
  'إجمالي المنح بعد الاستدعاء الأول أربعة بالضبط');

-- ===========================================================================
-- 3. التكرار — لا ازدواج، لا بإعادة الحساب ولا بإعادة الإرسال.
-- ===========================================================================

-- نفس request_id: استرجاع (replay)، لا كتابة جديدة إطلاقاً.
select public.grant_free_p1('fb100000-0000-0000-0000-0000000000c1',
  'fb1a0000-0000-0000-0000-000000000001') as g2 \gset
select pg_temp.ok(
  ((:'g2')::jsonb ->> 'replayed')::boolean = true,
  'نفس request_id: استرجاع صريح لا إعادة تنفيذ');

-- request_id مختلف، نفس الدورة: الضمانة الأقوى — قيد قاعدة البيانات نفسه
-- (unique cycle_id+scope_type+scope_id) يمنع الازدواج بغضّ النظر عن request_id.
select public.grant_free_p1('fb100000-0000-0000-0000-0000000000c1',
  'fb1a0000-0000-0000-0000-000000000002') as g3 \gset
select pg_temp.ok(
  ((:'g3')::jsonb ->> 'newly_granted')::int = 0,
  'استدعاء ثانٍ بـrequest_id مختلف: صفر منح جديد');
select pg_temp.ok(
  ((:'g3')::jsonb ->> 'already_granted')::int = 4,
  'كل الأربعة تظهر ممنوحة سلفاً، لا مُعاد إنشاؤها');

select pg_temp.ok(
  (select count(*) from public.free_p1_grants
   where cycle_id='fb100000-0000-0000-0000-0000000000c1') = 4,
  'الإجمالي يبقى أربعة تماماً بعد ثلاثة استدعاءات — إعادة الحساب/الإرسال لا تضاعف الاستحقاق');

-- ===========================================================================
-- 4. القدرة مفروضة فعلاً، لا معلَنة فقط.
-- ===========================================================================

reset role;
set local role authenticated;
set local request.jwt.claim.sub = 'fb100000-0000-0000-0000-0000000000a2';

select pg_temp.must_fail(
  $$select public.grant_free_p1('fb100000-0000-0000-0000-0000000000c1', gen_random_uuid())$$,
  'viewer بلا commission.grant_free_bonus: يُرفض');

reset role;
set local role authenticated;
set local request.jwt.claim.sub = 'fb100000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- 5. تهيئة العتبة: قابلة للتعديل، مدقَّقة، لا تمسّ عتبة الإنتاج المبذورة.
-- ===========================================================================

select pg_temp.must_fail(
  $$select public.set_free_p1_threshold('fb100000-0000-0000-0000-0000000000e4', 0, gen_random_uuid())$$,
  'عتبة صفر أو أقل: رفض');
select pg_temp.must_fail(
  $$select public.set_free_p1_threshold(gen_random_uuid(), 300, gen_random_uuid())$$,
  'إصدار مخطط غير موجود: رفض');

select public.set_free_p1_threshold('fb100000-0000-0000-0000-0000000000e4', 500,
  'fb1a0000-0000-0000-0000-000000000010') as t1 \gset
select pg_temp.ok(
  (select threshold from public.commission_free_p1_rules
   where scheme_version_id='fb100000-0000-0000-0000-0000000000e4') = 500,
  'العتبة الجديدة محفوظة');

select public.set_free_p1_threshold('fb100000-0000-0000-0000-0000000000e4', 600,
  'fb1a0000-0000-0000-0000-000000000011') as t2 \gset
select pg_temp.ok(
  (select threshold from public.commission_free_p1_rules
   where scheme_version_id='fb100000-0000-0000-0000-0000000000e4') = 600,
  'تعديل لاحق يستبدل القيمة (on conflict do update)، لا يكرّر الصفّ');
select pg_temp.ok(
  (select count(*) from public.commission_free_p1_rules
   where scheme_version_id='fb100000-0000-0000-0000-0000000000e4') = 1,
  'صفّ واحد فقط لهذا الإصدار رغم تعديلين');

select public.set_free_p1_threshold('fb100000-0000-0000-0000-0000000000e4', 999,
  'fb1a0000-0000-0000-0000-000000000011') as t3 \gset
select pg_temp.ok(
  ((:'t3')::jsonb ->> 'replayed')::boolean = true,
  'نفس request_id لتحديث العتبة: استرجاع، لا تعديل ثانٍ');
select pg_temp.ok(
  (select threshold from public.commission_free_p1_rules
   where scheme_version_id='fb100000-0000-0000-0000-0000000000e4') = 600,
  'القيمة تبقى 600 (الاسترجاع لم يُعِد التنفيذ بقيمة 999)');

select pg_temp.ok(
  (select threshold from public.commission_free_p1_rules v
   join public.commission_scheme_versions sv on sv.id = v.scheme_version_id
   where sv.version = 1 and sv.id in (select scheme_version_id from public.commission_cycles
                                       where id='fb100000-0000-0000-0000-0000000000c1')) = 350,
  'عتبة الإنتاج المبذورة (350) لم تتأثر بأي تعديل في هذا الملف');

select '              == free p1: done ==';

rollback;
