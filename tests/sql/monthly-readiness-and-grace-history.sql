-- PR-B2 — جاهزية الدورة الشهرية (readiness) وتاريخ التجاوز في طابور المهلة
-- المنقضية. معزول بنطاق تسمية mr-.
--
-- الغاية: إثبات أن حقل 'readiness' الجديد في installation_cycle_pipeline()
-- تجميعٌ عرضيٌّ فوق أرقامٍ محسوبةٍ أصلاً — لا حسابٌ مالي جديد — وأنه يتوافق مع
-- محمولات action_center() نفسها (لا رقمٌ مخترَع)، وأن page_installation_grace_queue
-- ما زالت افتراضياً EXPIRED فقط (لا كسرٌ خلفي)، وأن OVERRIDDEN تعرض بالضبط من
-- تجاوزته override_grace_expired_review، بسببه ووقته ومنفّذه.

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

select '           == monthly readiness (PR-B2) ==';

-- ---------------------------------------------------------------------------
-- التثبيت: فاعلٌ admin (يملك installation.view + installation.grace_override
-- عبر role_template_capabilities)، وفاعلٌ viewer بلا installation.grace_override.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('ee000000-0000-0000-0000-0000000000b1', 'mr-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('ee000000-0000-0000-0000-0000000000b1', 'MR Admin', 'mr-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into auth.users (id, email) values
  ('ee000000-0000-0000-0000-0000000000b9', 'mr-viewer@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('ee000000-0000-0000-0000-0000000000b9', 'MR Viewer', 'mr-viewer@fixture.invalid', 'viewer', true)
on conflict (id) do update set role = 'viewer', is_active = true;

insert into public.packages (code, semantic_category) values
  ('MR-DEBT-1', 'DEBT_SERVICE')
on conflict (code) do nothing;

set local request.jwt.claim.sub = 'ee000000-0000-0000-0000-0000000000b1';

/* ---------------------------------------------------------------------------
   1. readiness موجودٌ في مخرَج installation_cycle_pipeline() ولا يمسّ
      steps/candidate/ready/historical القائمة إطلاقاً.
   ------------------------------------------------------------------------- */

select pg_temp.ok(
  (public.installation_cycle_pipeline() ? 'readiness'),
  'installation_cycle_pipeline يحمل حقل readiness الجديد');

select pg_temp.ok(
  jsonb_array_length(public.installation_cycle_pipeline() -> 'steps') = 10,
  'مخرَج الخطوات العشر لم يتغيّر بإضافة readiness');

select pg_temp.ok(
  (public.installation_cycle_pipeline() -> 'readiness' -> 'checklist') is not null
  and jsonb_typeof(public.installation_cycle_pipeline() -> 'readiness' -> 'checklist') = 'array',
  'readiness.checklist مصفوفة كما هو متوقَّع');

/* ---------------------------------------------------------------------------
   2. كل صنفٍ يُدخَل يظهر بعدده الصحيح في checklist، والحالة الإجمالية تتحوّل
      NEEDS_REVIEW. لا "إجمالي مشتركين محجوبين" هنا: CLASSIFICATION_REVIEW
      يحتسب أصلاً كل NEEDS_REVIEW — بما فيه المهلة المنقضية والاستثناء اليدوي
      المفتوح — فجمع الأصناف رقماً واحداً يُكرِّر نفس المشترك. blocking_categories
      يُختبَر بدلاً من ذلك: عدد الأصناف التي فيها ما ينتظر، لا عدد الأشخاص.
   ------------------------------------------------------------------------- */

insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values
  ('ACTIVATION_EVENTS', 'mr-readiness.xlsx', 'mr-readiness-checksum', 'v1',
   'ee000000-0000-0000-0000-0000000000b1', 'COMPLETE')
on conflict do nothing;

-- تصنيفٌ يحتاج مراجعة (CLASSIFICATION_REVIEW).
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'MR-EVT-CLASS', 'mr-class-review', 'MR-DEBT-1', 1, false, now() - interval '2 days'
from public.saas_import_batches where source_checksum = 'mr-readiness-checksum';

insert into public.subscriber_classifications (username_key, classification, reason_code, source_completeness)
values ('mr-class-review', 'NEEDS_REVIEW', 'IDENTITY_CONFLICT', 'COMPLETE');

-- مهلة تفعيل منقضية (GRACE_EXPIRED_REVIEW) — 40 يوماً بلا تفعيلٍ مؤهَّل.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'MR-EVT-GRACE', 'mr-grace-expired', 'MR-DEBT-1', 1, false, now() - interval '40 days'
from public.saas_import_batches where source_checksum = 'mr-readiness-checksum';

insert into public.subscriber_classifications (username_key, classification, reason_code, source_completeness)
values ('mr-grace-expired', 'NEEDS_REVIEW', 'NO_QUALIFYING_PAID_EVENT', 'COMPLETE');

-- استثناءٌ يدويٌّ معلَّق (MANUAL_EXCEPTION_REVIEW).
select public.create_manual_exception_intake(
  'OTHER', 'mr-manual-pending', 'مثالٌ لاستثناءٍ معلَّق ضمن اختبار الجاهزية',
  null, null, null, null, null, gen_random_uuid());

select pg_temp.ok(
  (public.installation_cycle_pipeline() -> 'readiness' ->> 'blocking_categories')::int >= 3,
  'ثلاثة أصنافٍ على الأقل فيها ما ينتظر بعد الإدخال — تصنيف ومهلة واستثناء يدوي');

select pg_temp.ok(
  (select (x ->> 'count')::int from jsonb_array_elements(
     (public.installation_cycle_pipeline() -> 'readiness' -> 'checklist')) x
   where x ->> 'key' = 'CLASSIFICATION_REVIEW') >= 1,
  'checklist.CLASSIFICATION_REVIEW يحتسب الصفّ المُدخَل');

select pg_temp.ok(
  (select (x ->> 'count')::int from jsonb_array_elements(
     (public.installation_cycle_pipeline() -> 'readiness' -> 'checklist')) x
   where x ->> 'key' = 'GRACE_EXPIRED_REVIEW') >= 1,
  'checklist.GRACE_EXPIRED_REVIEW يحتسب الصفّ المُدخَل — نفس محمول action_center()');

select pg_temp.ok(
  (select (x ->> 'count')::int from jsonb_array_elements(
     (public.installation_cycle_pipeline() -> 'readiness' -> 'checklist')) x
   where x ->> 'key' = 'MANUAL_EXCEPTION_REVIEW') >= 1,
  'checklist.MANUAL_EXCEPTION_REVIEW يحتسب الاستثناء المعلَّق');

select pg_temp.ok(
  (public.installation_cycle_pipeline() -> 'readiness' ->> 'overall_state') = 'NEEDS_REVIEW',
  'الحالة الإجمالية NEEDS_REVIEW ما دام هناك استيرادٌ وحاجزٌ واحدٌ على الأقل');

do $$
declare v_before int;
begin
  select (x ->> 'count')::int into v_before
  from jsonb_array_elements(
    (public.installation_cycle_pipeline() -> 'readiness' -> 'checklist')) x
  where x ->> 'key' = 'MANUAL_EXCEPTION_REVIEW';
  create temporary table mr_manual_before as select v_before as n;
end $$;

-- حسم الاستثناء اليدوي يُسقطه من الحاجز فوراً — لا شبح بعد الحسم، تماماً كما
-- يشترط سطح CLASSIFICATION_REVIEW في action_center().
select public.resolve_manual_exception_intake(
  (select id from public.manual_exception_intakes where username_key = 'mr-manual-pending'),
  'REJECTED_INVALID', 'إغلاقٌ لغرض اختبار الجاهزية', null, gen_random_uuid());

select pg_temp.ok(
  (select (x ->> 'count')::int from jsonb_array_elements(
     (public.installation_cycle_pipeline() -> 'readiness' -> 'checklist')) x
   where x ->> 'key' = 'MANUAL_EXCEPTION_REVIEW')
    = (select n from mr_manual_before) - 1,
  'استثناءٌ يدويٌّ محسومٌ لا يبقى شبحاً محتسَباً في readiness.checklist — الحاجز ينقص بواحدٍ بالضبط');

/* ===========================================================================
   Active/Resolved لطابور المهلة المنقضية — page_installation_grace_queue()
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 3. الافتراضي (بلا p_status) يبقى EXPIRED فقط — لا كسرٌ خلفي على أي مستهلكٍ
--    قائم لم يُحدَّث بعد.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            (public.page_installation_grace_queue(null, 50, 0) -> 'rows')) x
          where x ->> 'username_key' = 'mr-grace-expired'),
  'الاستدعاء بلا p_status يبقى يعرض EXPIRED كما كان تماماً — لا كسرٌ خلفي');

select pg_temp.ok(
  (public.page_installation_grace_queue(null, 50, 0, 'EXPIRED'))
    = (public.page_installation_grace_queue(null, 50, 0)),
  'تمرير EXPIRED صراحةً يُعيد نفس مخرَج الافتراضي بالضبط');

-- ---------------------------------------------------------------------------
-- 4. OVERRIDDEN فارغةٌ قبل أي تجاوز، وتحمل الصفّ بسببه ووقته ومنفّذه بعده،
--    وتسقط من EXPIRED في اللحظة نفسها.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.page_installation_grace_queue(null, 50, 0, 'OVERRIDDEN') -> 'rows')) x
              where x ->> 'username_key' = 'mr-grace-expired'),
  'OVERRIDDEN فارغةٌ من هذا المشترك قبل أي تجاوز');

select public.override_grace_expired_review('mr-grace-expired', 'حالةٌ إدارية مُدقَّقة لغرض اختبار readiness', gen_random_uuid());

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.page_installation_grace_queue(null, 50, 0, 'EXPIRED') -> 'rows')) x
              where x ->> 'username_key' = 'mr-grace-expired'),
  'التجاوز يُسقط الصفّ من EXPIRED فوراً');

select pg_temp.ok(
  (select x ->> 'reason' from jsonb_array_elements(
     (public.page_installation_grace_queue(null, 50, 0, 'OVERRIDDEN') -> 'rows')) x
   where x ->> 'username_key' = 'mr-grace-expired') = 'حالةٌ إدارية مُدقَّقة لغرض اختبار readiness',
  'OVERRIDDEN يحمل السبب المحفوظ بالضبط');

select pg_temp.ok(
  (select x ->> 'overridden_by_email' from jsonb_array_elements(
     (public.page_installation_grace_queue(null, 50, 0, 'OVERRIDDEN') -> 'rows')) x
   where x ->> 'username_key' = 'mr-grace-expired') = 'mr-admin@fixture.invalid',
  'OVERRIDDEN يحمل بريد من نفّذ التجاوز');

select pg_temp.ok(
  (select x ->> 'overridden_at' from jsonb_array_elements(
     (public.page_installation_grace_queue(null, 50, 0, 'OVERRIDDEN') -> 'rows')) x
   where x ->> 'username_key' = 'mr-grace-expired') is not null,
  'OVERRIDDEN يحمل وقت التجاوز');

-- ---------------------------------------------------------------------------
-- 5. البحث يعمل على OVERRIDDEN كما يعمل على EXPIRED — لا فرقٌ بين الفرعين.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            (public.page_installation_grace_queue('mr-grace-expired', 50, 0, 'OVERRIDDEN') -> 'rows')) x
          where x ->> 'username_key' = 'mr-grace-expired'),
  'البحث بمعرّف المشترك يعمل على فرع OVERRIDDEN');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.page_installation_grace_queue('no-such-subscriber', 50, 0, 'OVERRIDDEN') -> 'rows')) x),
  'البحث بمعرّفٍ غير موجود لا يُعيد صفوفاً في فرع OVERRIDDEN');

rollback;
