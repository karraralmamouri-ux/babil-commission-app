-- VOID لدفعة استيراد SaaS: دلالة منطقية لا حذف، رفض صريح أمام أي أثر مالي
-- معتمَد/مدفوع، وإغلاق محافظ لمسار التنصيب الموازي (DEC-005).
--
-- معزول بنطاق تسمية fb2-.

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

select '              == void import batch ==';

insert into auth.users (id, email) values
  ('fb200000-0000-0000-0000-0000000000a1','fb2-admin@fixture.invalid'),
  ('fb200000-0000-0000-0000-0000000000a2','fb2-viewer@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('fb200000-0000-0000-0000-0000000000a1','FB2-AD','fb2-admin@fixture.invalid','admin',true),
  ('fb200000-0000-0000-0000-0000000000a2','FB2-VI','fb2-viewer@fixture.invalid','viewer',true)
on conflict (id) do update set role = excluded.role, is_active = true;

-- ---------------------------------------------------------------------------
-- الدفعات: b1 نظيفة تماماً، b2 أثّرت على دورة FINALIZED، b3 أثّرت على دورة
-- PAID، b4 أثّرت فقط على دورة غير معتمدة بعد، b5 أنتجت تسجيل تنصيب، b6 لم
-- تُستورَد أصلاً (draft).
-- ---------------------------------------------------------------------------

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, status, imported_by)
values
  ('fb200000-0000-0000-0000-0000000000b1','ACTIVATION_EVENTS','b1.xlsx','fb2-checksum-b1','v1','imported','fb200000-0000-0000-0000-0000000000a1'),
  ('fb200000-0000-0000-0000-0000000000b2','ACTIVATION_EVENTS','b2.xlsx','fb2-checksum-b2','v1','imported','fb200000-0000-0000-0000-0000000000a1'),
  ('fb200000-0000-0000-0000-0000000000b3','ACTIVATION_EVENTS','b3.xlsx','fb2-checksum-b3','v1','imported','fb200000-0000-0000-0000-0000000000a1'),
  ('fb200000-0000-0000-0000-0000000000b4','ACTIVATION_EVENTS','b4.xlsx','fb2-checksum-b4','v1','imported','fb200000-0000-0000-0000-0000000000a1'),
  ('fb200000-0000-0000-0000-0000000000b5','ACTIVATION_EVENTS','b5.xlsx','fb2-checksum-b5','v1','imported','fb200000-0000-0000-0000-0000000000a1'),
  ('fb200000-0000-0000-0000-0000000000b6','ACTIVATION_EVENTS','b6.xlsx','fb2-checksum-b6','v1','draft','fb200000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.saas_activation_events (id, import_batch_id, saas_event_id, username, canceled)
values
  ('fb200000-0000-0000-0000-00000000e0b1','fb200000-0000-0000-0000-0000000000b1','fb2-event-b1','fb2-user-b1', false),
  ('fb200000-0000-0000-0000-00000000e0b2','fb200000-0000-0000-0000-0000000000b2','fb2-event-b2','fb2-user-b2', false),
  ('fb200000-0000-0000-0000-00000000e0b3','fb200000-0000-0000-0000-0000000000b3','fb2-event-b3','fb2-user-b3', false),
  ('fb200000-0000-0000-0000-00000000e0b4','fb200000-0000-0000-0000-0000000000b4','fb2-event-b4','fb2-user-b4', false),
  ('fb200000-0000-0000-0000-00000000e0b5','fb200000-0000-0000-0000-0000000000b5','fb2-event-b5','fb2-user-b5', false)
on conflict do nothing;

-- دورات: FINALIZED (b2)، PAID (b3)، UNDER_REVIEW غير معتمدة (b4).
insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, scheme_version_id,
   status, finalized_by, finalized_at, created_by)
select 'fb200000-0000-0000-0000-00000000c0f1','FB2 دورة معتمدة',
       date '2027-09-01', date '2027-09-30','VNEXT', v.id,
       'FINALIZED','fb200000-0000-0000-0000-0000000000a1', now(),
       'fb200000-0000-0000-0000-0000000000a1'
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, scheme_version_id,
   status, finalized_by, finalized_at, created_by)
select 'fb200000-0000-0000-0000-00000000c0f2','FB2 دورة مدفوعة',
       date '2027-10-01', date '2027-10-31','VNEXT', v.id,
       'PAID','fb200000-0000-0000-0000-0000000000a1', now(),
       'fb200000-0000-0000-0000-0000000000a1'
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, scheme_version_id,
   status, created_by)
select 'fb200000-0000-0000-0000-00000000c0f4','FB2 دورة غير معتمدة',
       date '2027-11-01', date '2027-11-30','VNEXT', v.id,
       'UNDER_REVIEW', 'fb200000-0000-0000-0000-0000000000a1'
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

-- استحقاقات مباشرة (نفس اصطلاح الإدراج المباشر في tests/sql/free-p1.sql —
-- يفترض صحة تجميع المحرّك نفسه بدل إعادة اختباره هنا).
insert into public.commission_event_entitlements
  (cycle_id, activation_event_id, subscriber_key, scope_type, scope_id, zone, scheme_version_id)
select 'fb200000-0000-0000-0000-00000000c0f1','fb2-event-b2','fb2-user-b2','FDT','999','new', v.id
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

insert into public.commission_event_entitlements
  (cycle_id, activation_event_id, subscriber_key, scope_type, scope_id, zone, scheme_version_id)
select 'fb200000-0000-0000-0000-00000000c0f2','fb2-event-b3','fb2-user-b3','FDT','999','new', v.id
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

insert into public.commission_event_entitlements
  (cycle_id, activation_event_id, subscriber_key, scope_type, scope_id, zone, scheme_version_id)
select 'fb200000-0000-0000-0000-00000000c0f4','fb2-event-b4','fb2-user-b4','FDT','999','new', v.id
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

-- تسجيل تنصيب مستند إلى حدث b5 — يمنع VOID رغم عدم وجود رابط مفتاحي مباشر
-- بدفعة الاستيراد.
insert into public.installation_enrollments
  (subscriber_id, scheme_version_id, origin, first_qualifying_event_id)
select 'fb2-user-b5', v.id, 'NEW_INSTALLATION', 'fb2-event-b5'
from public.installation_scheme_versions v where v.version = 1
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'fb200000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- 1. الرفض الصريح: تحقق مدخلات.
-- ===========================================================================

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b1', '', gen_random_uuid())$$,
  'سبب فارغ: رفض');
select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b1', 'سبب صالح', null)$$,
  'request_id مفقود: رفض');

-- ===========================================================================
-- 2. الرفض الصريح: القدرة غير ممنوحة.
-- ===========================================================================

reset role;
set local role authenticated;
set local request.jwt.claim.sub = 'fb200000-0000-0000-0000-0000000000a2';

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b1', 'محاولة viewer', gen_random_uuid())$$,
  'viewer بلا saas.void_import: يُرفض');

reset role;
set local role authenticated;
set local request.jwt.claim.sub = 'fb200000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- 3. الرفض الصريح: الحالة لا تسمح.
-- ===========================================================================

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b6', 'دفعة لم تُستورد', gen_random_uuid())$$,
  'دفعة بحالة draft: رفض، لا صفوف ملتزمة لتُلغى');

-- ===========================================================================
-- 4. الرفض الصريح: أثّرت الدفعة فعلاً على دورة معتمدة أو مدفوعة.
-- ===========================================================================

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b2', 'محاولة إلغاء دفعة أثّرت على دورة معتمدة', gen_random_uuid())$$,
  'دفعة أثّرت على دورة FINALIZED: رفض صريح، لا حذف/إعادة حساب صامتة');

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b3', 'محاولة إلغاء دفعة أثّرت على دورة مدفوعة', gen_random_uuid())$$,
  'دفعة أثّرت على دورة PAID: رفض صريح');

select pg_temp.ok(
  (select status from public.saas_import_batches where id = 'fb200000-0000-0000-0000-0000000000b2') = 'imported',
  'الدفعة b2 بقيت imported — محاولة الرفض لم تُغيّر شيئاً');

-- ===========================================================================
-- 5. الرفض الصريح: أنتجت الدفعة تسجيل تنصيب — إغلاق محافظ.
-- ===========================================================================

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b5', 'محاولة إلغاء دفعة أنتجت تسجيل تنصيب', gen_random_uuid())$$,
  'دفعة أنتجت تسجيل تنصيب: رفض — لا رابط مؤكَّد فيُفترض الأمان صامتاً');

-- ===========================================================================
-- 6. النجاح: أثر على دورة غير معتمدة فقط — لا يُعدّ "أثّر على نتيجة معتمدة".
-- ===========================================================================

select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b4', 'استيراد خاطئ، لم يُعتمد بعد', gen_random_uuid()) as v_b4result \gset

select pg_temp.ok(
  (:'v_b4result')::jsonb ->> 'status' = 'voided',
  'دفعة أثّرت فقط على دورة غير معتمدة: يُقبل الإلغاء');
select pg_temp.ok(
  (select status from public.saas_import_batches where id = 'fb200000-0000-0000-0000-0000000000b4') = 'voided',
  'حالة b4 أصبحت voided فعلاً');

-- ===========================================================================
-- 7. النجاح الأساسي: دفعة نظيفة تماماً، بلا أثر مالي إطلاقاً.
-- ===========================================================================

select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b1', 'ملف خاطئ رُفع بالخطأ', 'fb200000-0000-0000-0000-0000000000ff') as v_b1result \gset

select pg_temp.ok(
  (:'v_b1result')::jsonb ->> 'replayed' = 'false',
  'أول استدعاء لإلغاء b1: تنفيذ حقيقي لا استرجاع');
select pg_temp.ok(
  (select status from public.saas_import_batches where id = 'fb200000-0000-0000-0000-0000000000b1') = 'voided',
  'حالة b1 أصبحت voided');
select pg_temp.ok(
  (select voided_by from public.saas_import_batches where id = 'fb200000-0000-0000-0000-0000000000b1')
    = 'fb200000-0000-0000-0000-0000000000a1',
  'الفاعل مسجَّل');
select pg_temp.ok(
  (select voided_at from public.saas_import_batches where id = 'fb200000-0000-0000-0000-0000000000b1') is not null,
  'الوقت مسجَّل');
select pg_temp.ok(
  (select void_reason from public.saas_import_batches where id = 'fb200000-0000-0000-0000-0000000000b1') = 'ملف خاطئ رُفع بالخطأ',
  'السبب محفوظ حرفياً');
select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'saas.import_batch.voided'
            and entity_id = 'fb200000-0000-0000-0000-0000000000b1'),
  'صفّ تدقيق مكتوب');

-- ===========================================================================
-- 8. الاسترجاع: نفس request_id لا يُعيد التنفيذ، request_id مختلف يُرفض
--    (الدفعة ممنوعة الآن أصلاً بحالتها voided).
-- ===========================================================================

select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b1', 'محاولة ثانية بنفس المعرّف', 'fb200000-0000-0000-0000-0000000000ff') as v_b1replay \gset

select pg_temp.ok(
  (:'v_b1replay')::jsonb ->> 'replayed' = 'true',
  'نفس request_id: استرجاع صريح لا إعادة تنفيذ');

select pg_temp.must_fail(
  $$select public.void_saas_import_batch('fb200000-0000-0000-0000-0000000000b1', 'محاولة بمعرّف مختلف', gen_random_uuid())$$,
  'request_id مختلف على دفعة مُلغاة أصلاً: رفض — "already voided"');

-- ===========================================================================
-- 9. الثبات: دفعة مُلغاة لا تُعدَّل حتى مباشرة، حتى بصلاحية المالك.
-- ===========================================================================

reset role;

select pg_temp.must_fail(
  $$update public.saas_import_batches set completeness_status = 'PARTIAL'
    where id = 'fb200000-0000-0000-0000-0000000000b1'$$,
  'دفعة voided ثابتة تماماً — القيد trg_protect_voided_import_batch يرفض حتى تعديلاً مباشراً');

-- ===========================================================================
-- 10. الأثر الفعلي: البيانات المُلغاة تتوقف عن أي حساب مستقبلي.
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.commission_qualifying_events
   where saas_event_id = 'fb2-event-b1') = 0,
  'حدث الدفعة المُلغاة لم يعد يظهر في commission_qualifying_events');

select
  (select 'BATCH_VOIDED' = any(
     array(select jsonb_array_elements_text(
       public.evaluate_enrollment_gate('fb2-user-b1', 'fb2-event-b1') -> 'blockers'))))
  as v_gate_has_blocker \gset

select pg_temp.ok(
  (:'v_gate_has_blocker')::boolean,
  'بوابة تسجيل التنصيب تُبلغ BATCH_VOIDED لحدث من دفعة مُلغاة');

select '              == void import batch: done ==';

rollback;
