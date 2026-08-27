-- إدخال الكابينات الجديدة: من الاكتشاف إلى التصنيف إلى إعادة الحساب.
--
-- معزول بملفه ومعاملته ونطاق تسمية FO- خاص به.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '       ok ' || p_label;
end;
$$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '       ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '      == fdt onboarding ==';

insert into auth.users (id, email) values
  ('f0000000-0000-0000-0000-0000000000a1', 'fo-admin@fixture.invalid'),
  ('f0000000-0000-0000-0000-0000000000a2', 'fo-viewer@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('f0000000-0000-0000-0000-0000000000a1','FOA','fo-admin@fixture.invalid','admin',true),
  ('f0000000-0000-0000-0000-0000000000a2','FOV','fo-viewer@fixture.invalid','viewer',true)
on conflict (id) do update set role = excluded.role, is_active = true;

insert into public.packages (code, name, semantic_category)
values ('P-35000','P-35000','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.agents (id, code, official_name)
values ('f0000000-0000-0000-0000-0000000000a3','FO-AG','وكيل إدخال الكابينات')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution)
values ('f0000000-0000-0000-0000-0000000000a3','fo.parent','mapped')
on conflict (alias_key) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('f0000000-0000-0000-0000-0000000000a4','ACTIVATION_EVENTS','fo.xlsx','fo-checksum',
        'v1','f0000000-0000-0000-0000-0000000000a1','COMPLETE')
on conflict do nothing;

-- كابينة مسجَّلة مسبقاً (لا تتأثر)، وأخرى غير مسجَّلة (محلّ الاختبار).
insert into public.fdts (code, label, zone, agent_id)
values ('FO-KNOWN','FDT-FO-KNOWN','new','f0000000-0000-0000-0000-0000000000a3')
on conflict (code) do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('f0000000-0000-0000-0000-0000000000a4','FO-EV-1','fo-sub-1','P-35000',false,'fo.parent',
   '2026-09-05','FO-NEW'),
  ('f0000000-0000-0000-0000-0000000000a4','FO-EV-2','fo-sub-2','P-35000',false,'fo.parent',
   '2026-09-06','FO-NEW'),
  ('f0000000-0000-0000-0000-0000000000a4','FO-EV-3','fo-sub-3','P-35000',false,'fo.parent',
   '2026-09-07','FO-KNOWN')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('fo-sub-1','MATCHED','EXACT_USERNAME','RESELLER','f0000000-0000-0000-0000-0000000000a3'),
       ('fo-sub-2','MATCHED','EXACT_USERNAME','RESELLER','f0000000-0000-0000-0000-0000000000a3'),
       ('fo-sub-3','MATCHED','EXACT_USERNAME','RESELLER','f0000000-0000-0000-0000-0000000000a3')
on conflict do nothing;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by)
values ('f0000000-0000-0000-0000-0000000000a5','FO أيلول', date '2026-09-01', date '2026-09-30',
        'VNEXT','f0000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- الاكتشاف
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  exists (select 1 from public.unregistered_fdt_candidates where fdt_code = 'FO-NEW'),
  'الكابينة غير المسجَّلة تظهر في قائمة الاكتشاف');

select pg_temp.ok(
  not exists (select 1 from public.unregistered_fdt_candidates where fdt_code = 'FO-KNOWN'),
  'المسجَّلة لا تظهر في قائمة الاكتشاف');

select pg_temp.ok(
  (select event_count from public.unregistered_fdt_candidates where fdt_code='FO-NEW') = 2
  and (select subscriber_count from public.unregistered_fdt_candidates where fdt_code='FO-NEW') = 2,
  'الاكتشاف يعرض عدد الأحداث والمشتركين');

select pg_temp.ok(
  (select observed_parents from public.unregistered_fdt_candidates where fdt_code='FO-NEW')
    @> array['fo.parent'],
  'الاكتشاف يعرض الآباء المرصودين دليلاً');

-- ---------------------------------------------------------------------------
-- ما بعد LIVE-02: لا حجب على الإطلاق.
--
-- fdt_commission_scope لا تنظر إلى جدول fdts إطلاقاً — فقط إلى الرقم
-- (94-119). ورموز هذا الملف كلّها نصّية غير رقمية (FO-NEW، FO-KNOWN)، فنطاقها
-- وكيل محسوم فوراً، سواءٌ سُجِّلت في fdts أم لا. التسجيل أدناه يبقى ذا قيمة
-- تشغيلية (تسمية، ربط بوكيل) لا يمسّ حساب العمولة إطلاقاً — وهذا يعني عملياً
-- أن «الحجب حتى التصنيف» الذي صُمِّم له هذا الملف لم يعد له أثر مالي على أي
-- رمز غير رقمي؛ يبقى أثره محصوراً بما لا يزال دون LIVE-02: رموز رقمية خارج
-- 94-119 أو داخله، لا تحتاج تسجيلاً لتحديد نطاقها أصلاً. هذه فجوة عمل تستحق
-- قراراً صريحاً: هل ما زالت شاشة «إدخال الكابينات» ذات غرض غير مالي (خرائط
-- تشغيلية) يستحق الإبقاء عليها، أم أصبحت زائدة؟ BUSINESS DECISION REQUIRED.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';
select public.calculate_commission_cycle('f0000000-0000-0000-0000-0000000000a5') is not null as c1;
reset role;

select pg_temp.ok(
  (select zone from public.commission_qualifying_events where saas_event_id='FO-EV-1') = 'old',
  'رمزٌ غير رقمي نطاقه وكيل محسوم فوراً — لا حالة معلَّقة');

select pg_temp.ok(
  not exists (select 1 from public.commission_exceptions
              where cycle_id='f0000000-0000-0000-0000-0000000000a5'
                and reason_code='UNKNOWN_FDT'),
  'لا استثناء UNKNOWN_FDT بعد اليوم — لا حجب على الإطلاق');

select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id='f0000000-0000-0000-0000-0000000000a5'
            and activation_event_id='FO-EV-3'),
  'الكابينة المسجَّلة مسبقاً تبقى عاملة');

select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id='f0000000-0000-0000-0000-0000000000a5'
            and activation_event_id in ('FO-EV-1','FO-EV-2')),
  'غير المسجَّلة تُعمَّل فوراً أيضاً — لا حجب انتظاراً للتصنيف');

-- ---------------------------------------------------------------------------
-- الصلاحية
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a2';
select pg_temp.must_fail(
  $$select public.register_fdt('FO-NEW','new',null,null,null,false, gen_random_uuid())$$,
  'المشاهد لا يُصنّف كابينة');
select pg_temp.must_fail(
  $$select public.register_fdt_bulk('[{"code":"FO-X","zone":"new"}]'::jsonb, false, gen_random_uuid())$$,
  'المشاهد لا يُصنّف دفعةً');
select pg_temp.must_fail(
  $$select public.recalculate_cycle_after_master_change(
      'f0000000-0000-0000-0000-0000000000a5', gen_random_uuid())$$,
  'المشاهد لا يُعيد الحساب');
reset role;

-- ---------------------------------------------------------------------------
-- التصنيف الفردي
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';

select pg_temp.must_fail(
  $$select public.register_fdt('FO-NEW',null,null,null,null,false, gen_random_uuid())$$,
  'المنطقة لا تُترك فارغة');
select pg_temp.must_fail(
  $$select public.register_fdt('FO-NEW','somewhere',null,null,null,false, gen_random_uuid())$$,
  'قيمة منطقة غير معروفة مرفوضة');
select pg_temp.must_fail(
  $$select public.register_fdt('','new',null,null,null,false, gen_random_uuid())$$,
  'رمز كابينة فارغ مرفوض');

select public.register_fdt('FO-NEW','new','f0000000-0000-0000-0000-0000000000a3',
  null,'مُصنَّفة في الاختبار',false, gen_random_uuid()) is not null as reg;
reset role;

select pg_temp.ok(
  (select zone from public.fdts where code='FO-NEW') = 'new',
  'المسؤول المخوَّل يُصنّف الكابينة');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='master.fdt.classified'),
  'التصنيف مُدقَّق');

select pg_temp.ok(
  (select old_value from public.audit_logs where action='master.fdt.classified'
   order by created_at desc limit 1) = '(unregistered)',
  'التدقيق يحفظ الحالة قبل التصنيف');

-- إعادة تصنيف تُغيّر مالاً: لا تمرّ بلا إقرار صريح.
set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';
select pg_temp.must_fail(
  $$select public.register_fdt('FO-NEW','old',null,null,null,false, gen_random_uuid())$$,
  'تغيير منطقة مصنَّفة يستلزم إقراراً صريحاً');
reset role;

select pg_temp.ok(
  (select zone from public.fdts where code='FO-NEW') = 'new',
  'المحاولة المرفوضة لم تُغيّر شيئاً');

-- ---------------------------------------------------------------------------
-- إعادة الحساب
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';
select public.recalculate_cycle_after_master_change(
  'f0000000-0000-0000-0000-0000000000a5', gen_random_uuid()) is not null as rc;
reset role;

select pg_temp.ok(
  (select count(*) from public.commission_exceptions
   where cycle_id='f0000000-0000-0000-0000-0000000000a5'
     and reason_code='UNKNOWN_FDT' and status='OPEN') = 0,
  'لا استثناء UNKNOWN_FDT قبل إعادة الحساب ولا بعدها');

select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements
   where cycle_id='f0000000-0000-0000-0000-0000000000a5'
     and activation_event_id in ('FO-EV-1','FO-EV-2')) = 2,
  'المال ظلّ عاملاً طوال الوقت — إعادة الحساب لا تُضاعفه ولا تُسقطه');

-- 'FO-NEW' نصّ لا رقم: نطاقه وكيل قبل التصنيف وبعده سيّان. التصنيف هنا
-- (register_fdt) لا يملك سلطة تغيير النطاق المالي بعد LIVE-02 — يُسجِّل
-- تسميةً تشغيلية فقط في fdts.zone.
select pg_temp.ok(
  (select scope_type from public.commission_event_entitlements
   where cycle_id='f0000000-0000-0000-0000-0000000000a5'
     and activation_event_id='FO-EV-1') = 'AGENT',
  'التصنيف لا يُغيّر نطاقاً مالياً لرمزٍ غير رقمي');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='commission.cycle.recalculated'),
  'إعادة الحساب مُدقَّقة');

-- إعادة التشغيل حتمية.
set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';
select public.recalculate_cycle_after_master_change(
  'f0000000-0000-0000-0000-0000000000a5', gen_random_uuid()) is not null as rc2;
reset role;

select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements
   where cycle_id='f0000000-0000-0000-0000-0000000000a5') = 3,
  'إعادة التشغيل لا تُضاعف الاستحقاقات');

-- ---------------------------------------------------------------------------
-- التصنيف الجماعي
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';

select pg_temp.must_fail(
  $$select public.register_fdt_bulk(
      '[{"code":"FO-B1","zone":"new"},{"code":"FO-B2"}]'::jsonb, false, gen_random_uuid())$$,
  'صف بلا منطقة يُبطل الدفعة كلها');

select pg_temp.must_fail(
  $$select public.register_fdt_bulk(
      '[{"code":"FO-B1","zone":"new"},{"code":"FO-B1","zone":"old"}]'::jsonb,
      false, gen_random_uuid())$$,
  'رمز مكرر داخل الدفعة مرفوض');

select public.register_fdt_bulk(
  '[{"code":"FO-B1","zone":"new"},{"code":"FO-B2","zone":"old"},{"code":"FO-B3","zone":"new"}]'::jsonb,
  false, gen_random_uuid()) is not null as bulk;
reset role;

select pg_temp.ok(
  (select count(*) from public.fdts where code in ('FO-B1','FO-B2','FO-B3')) = 3,
  'الدفعة الصحيحة تُسجَّل كاملة');

select pg_temp.ok(
  (select zone from public.fdts where code='FO-B2') = 'old',
  'كل صف يأخذ منطقته المعلنة لا منطقة الأغلبية');

select pg_temp.ok(
  not exists (select 1 from public.fdts where code in ('FO-B4','FO-B5')),
  'الدفعة المرفوضة لم تكتب شيئاً');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='master.fdt.bulk_classified'),
  'التصنيف الجماعي مُدقَّق');

-- ---------------------------------------------------------------------------
-- المال المُرحَّل لا يُعاد حسابه
-- ---------------------------------------------------------------------------

update public.commission_cycles
set status='FINALIZED', finalized_by='f0000000-0000-0000-0000-0000000000a1', finalized_at=now()
where id='f0000000-0000-0000-0000-0000000000a5';

set local role authenticated;
set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-0000000000a1';
select pg_temp.must_fail(
  $$select public.recalculate_cycle_after_master_change(
      'f0000000-0000-0000-0000-0000000000a5', gen_random_uuid())$$,
  'الدورة المعتمدة لا يُعاد حسابها بتغيير بيانات رئيسية');
reset role;

select pg_temp.ok(
  (select coalesce(sum(paid),0) from public.commission_rows) = 0,
  'لا عمولة دُفعت أثناء إدخال الكابينات');

rollback;
