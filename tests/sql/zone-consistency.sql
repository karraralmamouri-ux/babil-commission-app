-- زون-005: نفس رقم الكابينة يُنتج نفس تصنيف النطاق في كل مسار يقرأ zone —
-- محرّك العمولة (fdt_commission_scope مباشرة)، والتسجيل الجديد
-- (enroll_new_installation)، والاسترجاع التاريخي (bootstrap_historical_
-- enrollments)، والتثبيت الذي ينسخ zone من التسجيل إلى الاستحقاق
-- (materialize_installation_entitlements)، والاستيراد المجمّع القديم
-- (import_installation_entitlements) — الأخير يُختبَر عمداً بقيمة zone خاطئة
-- في الملف الخام نفسه، لإثبات أنها لم تعد تُقرأ إطلاقاً بعد 20261023090000.
--
-- FDT '105' يقع داخل 94-119 (كابينة/new)، وFDT '50' يقع خارجه (وكيل/old) —
-- نفس الرقمين يُعادان في كل قسم أدناه، فتُثبَت المطابقة عبر المسارات كلها،
-- لا داخل مسار واحد فقط.
--
-- معزول بنطاق تسمية zc-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '               ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '              == zone consistency ==';

insert into auth.users (id, email) values
  ('ac000000-0000-0000-0000-0000000000a1', 'zc-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ac000000-0000-0000-0000-0000000000a1', 'ZC-AD', 'zc-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

-- ===========================================================================
-- 1. fdt_commission_scope — المصدر الوحيد الذي يقرأه محرّك العمولة.
-- ===========================================================================

select pg_temp.ok(public.fdt_commission_scope('93')  = 'AGENT', 'خارج النطاق أسفل: 93 وكيل');
select pg_temp.ok(public.fdt_commission_scope('94')  = 'FDT',   'الحد الأدنى: 94 كابينة');
select pg_temp.ok(public.fdt_commission_scope('119') = 'FDT',   'الحد الأعلى: 119 كابينة');
select pg_temp.ok(public.fdt_commission_scope('120') = 'AGENT', 'خارج النطاق أعلى: 120 وكيل');
select pg_temp.ok(public.fdt_commission_scope(null)  = 'AGENT', 'كابينة مجهولة تُصنَّف وكيلاً بأمان');
select pg_temp.ok(public.fdt_commission_scope('105') = 'FDT',   'FDT التجربة (داخل النطاق): 105 كابينة');
select pg_temp.ok(public.fdt_commission_scope('50')  = 'AGENT', 'FDT التجربة (خارج النطاق): 50 وكيل');

-- ===========================================================================
-- 2. enroll_new_installation — التسجيل الجديد.
-- ===========================================================================

insert into public.packages (code, name, semantic_category) values
  ('ZC-PKG', 'ZC-PKG', 'PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('ac000000-0000-0000-0000-0000000000b1', 'ACTIVATION_EVENTS', 'zc.xlsx',
        'ck-zc', 'v1', 'ac000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

insert into public.agents (id, code, official_name)
values ('ac000000-0000-0000-0000-0000000000a2', 'AGT-ZC', 'وكيل اختبار النطاق')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution)
values ('ac000000-0000-0000-0000-0000000000a2', 'zc.raw.agent', 'mapped')
on conflict (alias_key) do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent)
values ('ac000000-0000-0000-0000-0000000000b1', 'ZC-EV-NEW', 'zc-new-fdt', 'ZC-PKG',
        false, 'zc.raw.agent'),
       ('ac000000-0000-0000-0000-0000000000b1', 'ZC-EV-OLD', 'zc-old-fdt', 'ZC-PKG',
        false, 'zc.raw.agent')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values ('zc-new-fdt', 'MATCHED', 'EXACT_USERNAME', 'RESELLER',
        'ac000000-0000-0000-0000-0000000000a2', '105'),
       ('zc-old-fdt', 'MATCHED', 'EXACT_USERNAME', 'RESELLER',
        'ac000000-0000-0000-0000-0000000000a2', '50')
on conflict do nothing;

insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('zc-new-fdt', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE'),
       ('zc-old-fdt', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-0000000000a1';

select public.enroll_new_installation(
  'zc-new-fdt', 'ZC-EV-NEW', null, 'ac000000-0000-0000-0000-0000000000c1') as zc_new_enrolled \gset
select public.enroll_new_installation(
  'zc-old-fdt', 'ZC-EV-OLD', null, 'ac000000-0000-0000-0000-0000000000c2') as zc_old_enrolled \gset

select pg_temp.ok(
  (select zone from public.installation_enrollments where subscriber_id = 'zc-new-fdt') = 'new',
  'تسجيل جديد: FDT 105 يُصنَّف كابينة');
select pg_temp.ok(
  (select zone from public.installation_enrollments where subscriber_id = 'zc-old-fdt') = 'old',
  'تسجيل جديد: FDT 50 يُصنَّف وكيلاً');
select pg_temp.ok(
  (select zone from public.installation_enrollments where subscriber_id = 'zc-new-fdt')
    = (case when public.fdt_commission_scope('105') = 'FDT' then 'new' else 'old' end)
  and (select zone from public.installation_enrollments where subscriber_id = 'zc-old-fdt')
    = (case when public.fdt_commission_scope('50') = 'FDT' then 'new' else 'old' end),
  'زون-005: التسجيل الجديد يتّفق مع محرّك العمولة لنفس FDT');

-- ===========================================================================
-- 3. bootstrap_historical_enrollments + materialize_installation_entitlements
--    — نفس الـFDT (105 و50) عبر مسار الاسترجاع التاريخي ثم التثبيت.
-- ===========================================================================

reset role;

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('ac000000-0000-0000-0000-0000000000d1', 'zc-mat-new', 'وكيل اختبار النطاق', '105',
   date '2026-01-01', 13000, 'ac000000-0000-0000-0000-0000000000a1'),
  ('ac000000-0000-0000-0000-0000000000d2', 'zc-mat-old', 'وكيل اختبار النطاق', '50',
   date '2026-01-01', 13000, 'ac000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('ac000000-0000-0000-0000-0000000000d1', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ac000000-0000-0000-0000-0000000000d2', date '2026-08-31', 13000, 'P1', 'resolved', true)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution, payment_eligible = excluded.payment_eligible;

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values
  ('zc-mat-new', 'RESELLER', 'ac000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03', 'تثبيت اختبار', 'ac000000-0000-0000-0000-0000000000a1'),
  ('zc-mat-old', 'RESELLER', 'ac000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03', 'تثبيت اختبار', 'ac000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

select public.bootstrap_historical_enrollments() as zc_bootstrap \gset

select pg_temp.ok(
  (select zone from public.installation_enrollments where subscriber_id = 'zc-mat-new') = 'new',
  'استرجاع تاريخي: FDT 105 يُصنَّف كابينة');
select pg_temp.ok(
  (select zone from public.installation_enrollments where subscriber_id = 'zc-mat-old') = 'old',
  'استرجاع تاريخي: FDT 50 يُصنَّف وكيلاً');

select public.review_invoice('zc-mat-new', 'P1', 'VERIFIED', 'مطابقة اختبار', 'ZC-INV-1',
  'ac000000-0000-0000-0000-0000000000c3');
select public.review_invoice('zc-mat-old', 'P1', 'VERIFIED', 'مطابقة اختبار', 'ZC-INV-2',
  'ac000000-0000-0000-0000-0000000000c4');

select public.materialize_installation_entitlements(
  '2026-09', null, 500, 'ac000000-0000-0000-0000-0000000000c5') as zc_materialize \gset

select pg_temp.ok(
  (select zone from public.installation_entitlements
   where period = '2026-09' and subscriber_id = 'zc-mat-new' and stage = 'P1') = 'new',
  'تثبيت الاستحقاق: FDT 105 ينتقل بنطاق كابينة من التسجيل إلى الاستحقاق');
select pg_temp.ok(
  (select zone from public.installation_entitlements
   where period = '2026-09' and subscriber_id = 'zc-mat-old' and stage = 'P1') = 'old',
  'تثبيت الاستحقاق: FDT 50 ينتقل بنطاق وكيل من التسجيل إلى الاستحقاق');
select pg_temp.ok(
  (select zone from public.installation_entitlements
   where period = '2026-09' and subscriber_id = 'zc-mat-new' and stage = 'P1')
    = (case when public.fdt_commission_scope('105') = 'FDT' then 'new' else 'old' end)
  and (select zone from public.installation_entitlements
       where period = '2026-09' and subscriber_id = 'zc-mat-old' and stage = 'P1')
    = (case when public.fdt_commission_scope('50') = 'FDT' then 'new' else 'old' end),
  'زون-005: لوحة التنصيب (استحقاق مُثبَّت) تتّفق مع محرّك العمولة لنفس FDT');

reset role;

-- ===========================================================================
-- 4. import_installation_entitlements — الاستيراد المجمّع القديم، مع قيمة
--    zone خاطئة عمداً في الملف الخام نفسه: يجب ألا تُقرأ إطلاقاً بعد الإصلاح.
-- ===========================================================================

set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-0000000000a1';

select public.import_installation_entitlements(
  '2026-09', 'zc-import.xlsx', 'ck-zc-import',
  jsonb_build_array(
    jsonb_build_object('subscriber_id', 'zc-imp-new', 'reseller', 'وكيل اختبار النطاق',
                        'fdt', '105', 'zone', 'old', 'remaining', 13000),
    jsonb_build_object('subscriber_id', 'zc-imp-old', 'reseller', 'وكيل اختبار النطاق',
                        'fdt', '50', 'zone', 'new', 'remaining', 13000)
  ),
  'ac000000-0000-0000-0000-0000000000c6'
) as zc_import \gset

select pg_temp.ok(
  (select zone from public.installation_entitlements
   where period = '2026-09' and subscriber_id = 'zc-imp-new' and stage = 'P1') = 'new',
  'استيراد مجمّع: FDT 105 يتجاوز قيمة zone الخاطئة (old) في الملف الخام ويُصنَّف كابينة');
select pg_temp.ok(
  (select zone from public.installation_entitlements
   where period = '2026-09' and subscriber_id = 'zc-imp-old' and stage = 'P1') = 'old',
  'استيراد مجمّع: FDT 50 يتجاوز قيمة zone الخاطئة (new) في الملف الخام ويُصنَّف وكيلاً');
select pg_temp.ok(
  (select zone from public.installation_entitlements
   where period = '2026-09' and subscriber_id = 'zc-imp-new' and stage = 'P1')
    = (case when public.fdt_commission_scope('105') = 'FDT' then 'new' else 'old' end)
  and (select zone from public.installation_entitlements
       where period = '2026-09' and subscriber_id = 'zc-imp-old' and stage = 'P1')
    = (case when public.fdt_commission_scope('50') = 'FDT' then 'new' else 'old' end),
  'زون-005: الاستيراد المجمّع يتّفق مع محرّك العمولة لنفس FDT رغم قيمة الملف الخاطئة');

-- ===========================================================================
-- 5. النسخ الرجعي (backfill) — يصحّح بيانات قائمة قبل الإصلاح، بلا مالٍ،
--    وحتى على صفٍّ مدفوع. مثبَت idempotent (تشغيل ثانٍ لا يُغيّر شيئاً).
-- ===========================================================================

-- محاكاة صفٍّ قديم كتبته النسخة السابقة من import_installation_entitlements
-- (تثق بعمود zone الخام) بقيمة خاطئة، ومدفوع بالفعل — إثبات أن التصحيح
-- الرجعي لا يتوقّف عند صفٍّ مُسوّى مالياً، لأن zone ليس ضمن الأعمدة التي
-- يحميها protect_settled_installation_entitlement().
insert into public.installation_entitlements
  (period, subscriber_id, subscriber_name, reseller, zone, fdt, remaining, stage, amount,
   invoice_status, payment_status, paid_amount, paid_by, paid_at, created_by)
values (
  '2026-05', 'zc-backfill-paid', 'ZC Backfill', 'وكيل اختبار النطاق', 'old', '108',
  13000, 'P1', 3000, 'approved', 'paid', 3000,
  'ac000000-0000-0000-0000-0000000000a1', now(), 'ac000000-0000-0000-0000-0000000000a1'
);

select pg_temp.ok(
  (select zone from public.installation_entitlements where subscriber_id = 'zc-backfill-paid') = 'old',
  'صفٌّ يحاكي الخلل السابق: مُدرَج بنطاق خاطئ (old) لFDT 108 المدفوع بالفعل');

update public.installation_entitlements
set zone = case when public.fdt_commission_scope(fdt) = 'FDT' then 'new' else 'old' end
where zone is distinct from
      (case when public.fdt_commission_scope(fdt) = 'FDT' then 'new' else 'old' end);

select pg_temp.ok(
  (select zone from public.installation_entitlements where subscriber_id = 'zc-backfill-paid') = 'new',
  'النسخ الرجعي يصحّح الصفّ المدفوع سلفاً دون رفض المحفّز (zone خارج أعمدة الحماية)');

-- تشغيل ثانٍ: لا صفوف تتغيّر — idempotent فعلاً، لا اسمياً فقط.
with upd as (
  update public.installation_entitlements
  set zone = case when public.fdt_commission_scope(fdt) = 'FDT' then 'new' else 'old' end
  where zone is distinct from
        (case when public.fdt_commission_scope(fdt) = 'FDT' then 'new' else 'old' end)
  returning 1
)
select pg_temp.ok((select count(*) from upd) = 0, 'النسخ الرجعي: تشغيل ثانٍ لا يُغيّر أي صفّ');

select '              == zone consistency: done ==';

rollback;
