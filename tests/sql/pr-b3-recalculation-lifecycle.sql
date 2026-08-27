-- PR-B3: LIVE-03 — قرار محلول لا يُعيد كتابة المال بصمت.
--
-- classify_parent يُعلِم بعلمٍ على الدورة، ولا يحسب. وإعادة الحساب المُخوَّلة
-- وحدها تُطفئه. معزول بنطاق تسمية B3L-/b3l-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '            ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '           == pr-b3: live-03 recalculation lifecycle ==';

insert into auth.users (id, email) values ('64000000-0000-0000-0000-0000000000d1','b3l@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('64000000-0000-0000-0000-0000000000d1','B3L','b3l@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.agents (id, code, official_name) values
  ('64000000-0000-0000-0000-0000000000d2','B3L-A','وكيل ل')
on conflict (code) do nothing;

insert into public.packages (code, name, semantic_category)
values ('P-35000','P-35000','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values ('64000000-0000-0000-0000-0000000000d3','ACTIVATION_EVENTS','b3l.xlsx','b3l-sum','v1',
        '64000000-0000-0000-0000-0000000000d1','COMPLETE')
on conflict do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, event_created_at)
values
  ('64000000-0000-0000-0000-0000000000d3','B3L-EV-1','b3l-sub-1','P-35000',false,'B3L.Parent.X',
   timestamptz '2026-12-05 10:00+03')
on conflict do nothing;

insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('64000000-0000-0000-0000-0000000000d4','B3L كانون', date '2026-12-01', date '2026-12-31',
        'VNEXT','64000000-0000-0000-0000-0000000000d1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '64000000-0000-0000-0000-0000000000d1';
select public.calculate_commission_cycle('64000000-0000-0000-0000-0000000000d4') is not null as ran;

-- المُصادَق عليه لا يقرأ commission_cycles مباشرة؛ عقده العام الوحيد هو
-- commission_cycle_result. كل تحقق عن needs_recalculation/recalculation_reason
-- أدناه يمرّ من خلاله، لا من الجدول.
select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d4')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'الدورة قبل أي قرار لا تحمل علم إعادة حساب');

-- ---------------------------------------------------------------------------
-- القرار يَسِم، ولا يحسب.
-- ---------------------------------------------------------------------------

select (public.classify_parent('B3L.Parent.X', 'RESELLER', '64000000-0000-0000-0000-0000000000d2',
   'اختبار', gen_random_uuid()) ->> 'cycles_flagged_for_recalculation')::int as flagged;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d4')
    -> 'cycle') ->> 'needs_recalculation')::boolean = true,
  'تصنيف الأب يَسِم الدورة المتأثّرة بحاجتها لإعادة الحساب');

select pg_temp.ok(
  (public.commission_cycle_result('64000000-0000-0000-0000-0000000000d4')
    -> 'cycle') ->> 'recalculation_reason' is not null,
  'سبب الوسم مسجَّل');

-- والمال لم يتغيّر بعد — القرار لم يحسب شيئاً. هذا فحص داخلي لا يعرضه عقد
-- commission_cycle_result (لا يفحص استحقاق حدثٍ بعينه)، فيُنفَّذ بصلاحية
-- المالك بعد إعادة الدور — لا يجوز لـ authenticated قراءة الجدول مباشرة.
reset role;
select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where activation_event_id = 'B3L-EV-1'),
  'القرار وحده لم يُنتج استحقاقاً — لا حساب صامت');

-- ---------------------------------------------------------------------------
-- إعادة الحساب المُخوَّلة تُطفئ العلم وتُحدِّث المال.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = '64000000-0000-0000-0000-0000000000d1';

select public.recalculate_cycle_after_master_change(
  '64000000-0000-0000-0000-0000000000d4', gen_random_uuid(), 'اختبار تصنيف') is not null as recalculated;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d4')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'إعادة الحساب المُخوَّلة تُطفئ العلم');

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d4')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'الشاشة تقرأ العلم من commission_cycle_result');

-- فحص داخلي آخر — نفس السبب أعلاه: الاستحقاق نُسِب فعلاً للوكيل المُصنَّف.
reset role;
select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where activation_event_id = 'B3L-EV-1'
            and effective_agent_id = '64000000-0000-0000-0000-0000000000d2'),
  'وتُنتج الآن استحقاقاً للوكيل المُصنَّف');

-- ---------------------------------------------------------------------------
-- الدورة المنتهية لا تُوسَم إطلاقاً.
-- ---------------------------------------------------------------------------

-- تجهيز فرضية الاختبار (اعتماد الدورة)، لا فعل تطبيق — يُنفَّذ بصلاحية
-- المالك. authenticated لا يملك ولا يجوز أن يملك كتابة مباشرة على الجدول.
update public.commission_cycles
set status = 'FINALIZED',
    finalized_by = '64000000-0000-0000-0000-0000000000d1',
    finalized_at = now()
where id = '64000000-0000-0000-0000-0000000000d4';

set local role authenticated;
set local request.jwt.claim.sub = '64000000-0000-0000-0000-0000000000d1';

select (public.classify_parent('B3L.Parent.X', 'DIRECT_COMPANY', null,
   'إعادة تصنيف بعد الاعتماد', gen_random_uuid()) ->> 'cycles_flagged_for_recalculation')::int
  as flagged_after_finalize;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d4')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'الدورة المعتمدة لا تُوسَم — تصحيحها أداةٌ أخرى');

-- ---------------------------------------------------------------------------
-- الإضافة اليدوية (Manual ADD) تخضع لنفس آلية الوسم — لا أحداث SaaS وحدها.
-- calculate_commission_cycle() يستهلك مالياً كل تصحيح ACTIVE من نوع ADD، فأيّ
-- تصنيف أبٍ يغيّر عائديته يجب أن يَسِم دورته أيضاً.
-- ---------------------------------------------------------------------------

reset role;

insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('64000000-0000-0000-0000-0000000000d5','B3L إضافة يدوية', date '2027-01-01', date '2027-01-31',
        'VNEXT','64000000-0000-0000-0000-0000000000d1')
on conflict do nothing;

insert into public.activation_corrections
  (cycle_id, correction_type, subscriber_username, package_code, event_at,
   fdt_code, raw_parent, reason, request_id, created_by, status)
values
  ('64000000-0000-0000-0000-0000000000d5','ADD','b3l-manual-sub','P-35000',
   timestamptz '2027-01-10 10:00+03','93','B3L.ManualAdd.Parent','اختبار إضافة يدوية',
   '64000000-0000-0000-0000-000000000e01','64000000-0000-0000-0000-0000000000d1','ACTIVE')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '64000000-0000-0000-0000-0000000000d1';

select public.calculate_commission_cycle('64000000-0000-0000-0000-0000000000d5') is not null as manual_ran;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d5')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'دورة الإضافة اليدوية قبل أي قرار لا تحمل علم إعادة حساب');

select (public.classify_parent('B3L.ManualAdd.Parent', 'RESELLER',
   '64000000-0000-0000-0000-0000000000d2', 'اختبار', gen_random_uuid())
   ->> 'cycles_flagged_for_recalculation')::int as manual_flagged;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d5')
    -> 'cycle') ->> 'needs_recalculation')::boolean = true,
  'تصنيف أبٍ لإضافة يدوية فعّالة يَسِم دورتها — لا SaaS فقط');

-- فحص داخلي: القرار وحده لم يُنتج بعد استحقاقاً — لا حساب صامت.
reset role;
select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id = '64000000-0000-0000-0000-0000000000d5'
                and effective_agent_id = '64000000-0000-0000-0000-0000000000d2'),
  'القرار وحده لم يُنتج استحقاقاً للإضافة اليدوية — لا حساب صامت');

set local role authenticated;
set local request.jwt.claim.sub = '64000000-0000-0000-0000-0000000000d1';

select public.recalculate_cycle_after_master_change(
  '64000000-0000-0000-0000-0000000000d5', gen_random_uuid(), 'اختبار') is not null as manual_recalculated;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d5')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'إعادة الحساب المُخوَّلة تُطفئ علم الإضافة اليدوية');

reset role;
select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id = '64000000-0000-0000-0000-0000000000d5'
            and activation_event_id like 'MANUAL-%'
            and effective_agent_id = '64000000-0000-0000-0000-0000000000d2'),
  'وتُنتج الآن استحقاقاً صحيحاً للوكيل المُصنَّف على الإضافة اليدوية');

-- إضافة يدوية مُلغاة وحدها في دورةٍ مستقلّة: تصنيف نفس الأب يجب ألّا يَسِمها.
insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('64000000-0000-0000-0000-0000000000d6','B3L إضافة ملغاة', date '2027-02-01', date '2027-02-28',
        'VNEXT','64000000-0000-0000-0000-0000000000d1')
on conflict do nothing;

insert into public.activation_corrections
  (cycle_id, correction_type, subscriber_username, package_code, event_at,
   fdt_code, raw_parent, reason, request_id, created_by, status)
values
  ('64000000-0000-0000-0000-0000000000d6','ADD','b3l-manual-sub-revoked','P-35000',
   timestamptz '2027-02-12 10:00+03','93','B3L.ManualAdd.Revoked','مُلغاة عمداً للاختبار',
   '64000000-0000-0000-0000-000000000e02','64000000-0000-0000-0000-0000000000d1','ACTIVE')
on conflict do nothing;

-- انتقال ACTIVE -> REVOKED منسوب بالكامل دفعة واحدة، لا إدراج REVOKED مباشرة
-- (activation_corrections_revoked_is_attributed يرفض REVOKED بلا انتساب).
update public.activation_corrections
set status = 'REVOKED',
    revoked_by = '64000000-0000-0000-0000-0000000000d1',
    revoked_at = now(),
    revoke_reason = 'اختبار'
where request_id = '64000000-0000-0000-0000-000000000e02';

set local role authenticated;
set local request.jwt.claim.sub = '64000000-0000-0000-0000-0000000000d1';

select (public.classify_parent('B3L.ManualAdd.Revoked', 'RESELLER',
   '64000000-0000-0000-0000-0000000000d2', 'اختبار', gen_random_uuid())
   ->> 'cycles_flagged_for_recalculation')::int as revoked_flagged;

select pg_temp.ok(
  ((public.commission_cycle_result('64000000-0000-0000-0000-0000000000d6')
    -> 'cycle') ->> 'needs_recalculation')::boolean = false,
  'إضافة يدوية مُلغاة وحدها لا تَسِم دورتها عند تصنيف أبيها');

reset role;
rollback;
