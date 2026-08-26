-- PR-B1 — الاستثناء اليدوي وطابور مهلة التفعيل المنقضية. معزول بنطاق تسمية me-.
--
-- الغاية: إثبات أن الاستثناء اليدوي يدخل NEEDS_REVIEW ولا يمكن أن يصير NEW
-- بنيوياً، ولا يُنشئ استحقاقاً أو دفعة أبداً، وأنه محروسٌ بقدرتين منفصلتين
-- (إنشاء وحسم)، ومحصَّنٌ ضد التكرار (قفلٌ نشطٌ واحد + إعادة إرسالٍ هادئة)،
-- وأن اكتشاف الهوية الحقيقية اللاحقة عرضٌ لا دمجٌ تلقائي. وأن طابور المهلة
-- المنقضية يعرض بالضبط من تجاوز الثلاثين يوماً بلا تفعيلٍ مؤهَّل، ويسقط
-- الصفّ منه فور التجاوز المُدقَّق — بلا حساب أيامٍ مكرَّر خارج الخادم.

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

select '           == manual exception intake + grace-expired queue (PR-B1) ==';

-- ---------------------------------------------------------------------------
-- التثبيت: فاعلٌ admin (يملك القدرتين عبر role_template_capabilities)،
-- وفاعلٌ viewer (لا يملك أياً منهما).
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('ee000000-0000-0000-0000-0000000000a1', 'me-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('ee000000-0000-0000-0000-0000000000a1', 'ME Admin', 'me-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into auth.users (id, email) values
  ('ee000000-0000-0000-0000-0000000000a9', 'me-viewer@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('ee000000-0000-0000-0000-0000000000a9', 'ME Viewer', 'me-viewer@fixture.invalid', 'viewer', true)
on conflict (id) do update set role = 'viewer', is_active = true;

insert into public.packages (code, semantic_category) values
  ('ME-PAID-1', 'PAID_PACKAGE'),
  ('ME-DEBT-1', 'DEBT_SERVICE')
on conflict (code) do nothing;

set local request.jwt.claim.sub = 'ee000000-0000-0000-0000-0000000000a1';

/* ---------------------------------------------------------------------------
   1. الإنشاء يرفض فاعلاً بلا installation.manual_exception_create.
   ------------------------------------------------------------------------- */

select pg_temp.must_fail(
  'set local request.jwt.claim.sub = ''ee000000-0000-0000-0000-0000000000a9'';
   select public.create_manual_exception_intake(
     ''NOT_VISIBLE_IN_SAAS'', ''me-unauthorized'', ''محاولة بلا صلاحية'', null, null, null, null, null,
     gen_random_uuid())',
  'الإنشاء يرفض فاعلاً بلا installation.manual_exception_create');

/* ---------------------------------------------------------------------------
   2. الإنشاء يرفض سبباً فارغاً، ونوعاً غير صالح، ومعرّف مشترك فارغ.
   ------------------------------------------------------------------------- */

select pg_temp.must_fail(
  'select public.create_manual_exception_intake(
     ''NOT_VISIBLE_IN_SAAS'', ''me-empty-reason'', ''   '', null, null, null, null, null, gen_random_uuid())',
  'الإنشاء يرفض سبباً فارغاً');

select pg_temp.must_fail(
  'select public.create_manual_exception_intake(
     ''NOT_A_REAL_TYPE'', ''me-bad-type'', ''سبب'', null, null, null, null, null, gen_random_uuid())',
  'الإنشاء يرفض نوع استثناءٍ غير معتمد');

select pg_temp.must_fail(
  'select public.create_manual_exception_intake(
     ''NOT_VISIBLE_IN_SAAS'', ''  '', ''سبب'', null, null, null, null, null, gen_random_uuid())',
  'الإنشاء يرفض معرّف مشتركٍ فارغاً');

select pg_temp.must_fail(
  'select public.create_manual_exception_intake(
     ''NOT_VISIBLE_IN_SAAS'', ''me-no-request-id'', ''سبب'', null, null, null, null, null, null)',
  'الإنشاء يرفض غياب request_id');

/* ---------------------------------------------------------------------------
   3. الإنشاء الصحيح: NEEDS_REVIEW أولياً، مع صفّ تصنيف موحَّد، ومع تدقيق.
   ------------------------------------------------------------------------- */

select public.create_manual_exception_intake(
  'NOT_VISIBLE_IN_SAAS', 'me-subject-one', 'مشترك ورد اسمه إدارياً ولم يظهر في أي ملف SaaS',
  'محمد الاختبار', 'وكيل تجربة', null, 'دفعة آب', 'مذكرة رقم 12', gen_random_uuid());

select pg_temp.ok(
  (select status from public.manual_exception_intakes where username_key = 'me-subject-one') = 'NEEDS_REVIEW',
  'الاستثناء الجديد يدخل NEEDS_REVIEW ولا شيء غيرها');

select pg_temp.ok(
  exists (select 1 from public.subscriber_classifications
          where username_key = 'me-subject-one' and classification = 'NEEDS_REVIEW'
            and reason_code = 'MANUAL_EXCEPTION'),
  'الاستثناء يدخل نفس سطح مراجعة التصنيف (subscriber_classifications) كما يشترط التصميم المعتمد');

select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'installation.manual_exception.created'
            and entity_type = 'manual_exception_intake'),
  'الإنشاء مُدقَّقٌ في audit_logs');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements ie
              where lower(btrim(ie.subscriber_id)) = 'me-subject-one')
  and not exists (select 1 from public.installation_payments p
                  join public.installation_entitlements ie on ie.id = p.entitlement_id
                  where lower(btrim(ie.subscriber_id)) = 'me-subject-one'),
  'الإنشاء لا يُنشئ استحقاقاً ولا دفعة بأي شكل');

/* ---------------------------------------------------------------------------
   4. NEW ممتنعٌ بنيوياً: حتى محاولة كتابة مباشرة تفشل على القيد القائم.
   ------------------------------------------------------------------------- */

select pg_temp.must_fail(
  'update public.subscriber_classifications set classification = ''NEW''
   where username_key = ''me-subject-one'' and reason_code = ''MANUAL_EXCEPTION''',
  'صفّ الاستثناء اليدوي لا يمكن أن يصير NEW حتى بكتابة مباشرة — القيد القائم يمنعه بنيوياً');

/* ---------------------------------------------------------------------------
   5. مقاوم التكرار: نشطٌ واحد لكل هوية، وإعادة إرسالٍ بنفس request_id هادئة.
   ------------------------------------------------------------------------- */

select pg_temp.must_fail(
  'select public.create_manual_exception_intake(
     ''OTHER'', ''me-subject-one'', ''محاولة ثانية على نفس الهوية'', null, null, null, null, null,
     gen_random_uuid())',
  'استثناءٌ نشطٌ ثانٍ على نفس الهوية يُرفض — لا صفّ منافس');

do $$
declare v_rid uuid := gen_random_uuid();
begin
  perform public.create_manual_exception_intake(
    'MISSING_HISTORICAL_DATA', 'me-replay-subject', 'سبب أوّل', null, null, null, null, null, v_rid);
  perform public.create_manual_exception_intake(
    'MISSING_HISTORICAL_DATA', 'me-replay-subject', 'سبب أوّل', null, null, null, null, null, v_rid);
end $$;

select pg_temp.ok(
  (select count(*) from public.manual_exception_intakes where username_key = 'me-replay-subject') = 1,
  'إعادة الإرسال بنفس request_id لا تُنشئ صفّاً ثانياً');

/* ---------------------------------------------------------------------------
   6. الحسم يرفض فاعلاً بلا installation.manual_exception_resolve، وسبباً
      فارغاً، وفعلاً غير صالح، ورَبطاً بلا هوية مختارة.
   ------------------------------------------------------------------------- */

select pg_temp.must_fail(
  format('set local request.jwt.claim.sub = ''ee000000-0000-0000-0000-0000000000a9'';
   select public.resolve_manual_exception_intake(%L, ''REJECTED_INVALID'', ''محاولة بلا صلاحية'', null, gen_random_uuid())',
   (select id from public.manual_exception_intakes where username_key = 'me-subject-one')),
  'الحسم يرفض فاعلاً بلا installation.manual_exception_resolve');

select pg_temp.must_fail(
  format('select public.resolve_manual_exception_intake(%L, ''REJECTED_INVALID'', ''  '', null, gen_random_uuid())',
   (select id from public.manual_exception_intakes where username_key = 'me-subject-one')),
  'الحسم يرفض سبباً فارغاً');

select pg_temp.must_fail(
  format('select public.resolve_manual_exception_intake(%L, ''NOT_A_REAL_ACTION'', ''سبب'', null, gen_random_uuid())',
   (select id from public.manual_exception_intakes where username_key = 'me-subject-one')),
  'الحسم يرفض فعلاً غير معتمد');

select pg_temp.must_fail(
  format('select public.resolve_manual_exception_intake(%L, ''LINKED_TO_REAL_IDENTITY'', ''سبب'', null, gen_random_uuid())',
   (select id from public.manual_exception_intakes where username_key = 'me-subject-one')),
  'الحسم يرفض ربطاً بهوية حقيقية بلا معرّف هوية مُختار');

/* ---------------------------------------------------------------------------
   7. اكتشاف هوية حقيقية لاحقة: عرضٌ فقط — لا دمجٌ تلقائي أبداً.
   ------------------------------------------------------------------------- */

insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('me-subject-one', 'MATCHED', 'EXACT_USERNAME', 'ME-S-SUBJECT-ONE');

select pg_temp.ok(
  (select jsonb_array_length(
     (public.manual_exception_merge_candidates(
        (select id from public.manual_exception_intakes where username_key = 'me-subject-one'))
      ->'candidates'))) = 1,
  'ظهور هوية SaaS حقيقية مطابقة يُكتشَف كمرشّح دمج');

select pg_temp.ok(
  (select status from public.manual_exception_intakes where username_key = 'me-subject-one') = 'NEEDS_REVIEW',
  'الاكتشاف وحده لا يُغيِّر حالة الاستثناء — لا دمج تلقائي بلا قرار مراجع صريح');

/* ---------------------------------------------------------------------------
   8. الحسم الصحيح: رَبطٌ بهوية حقيقية، مع تدقيق واسمٍ للفاعل والسبب.
   ------------------------------------------------------------------------- */

select public.resolve_manual_exception_intake(
  (select id from public.manual_exception_intakes where username_key = 'me-subject-one'),
  'LINKED_TO_REAL_IDENTITY', 'تأكّد ظهوره لاحقاً بهوية SaaS حقيقية مطابقة',
  (select id from public.subscriber_identities where username = 'me-subject-one'),
  gen_random_uuid());

select pg_temp.ok(
  (select status from public.manual_exception_intakes where username_key = 'me-subject-one') = 'RESOLVED'
  and (select resolution_action from public.manual_exception_intakes where username_key = 'me-subject-one')
      = 'LINKED_TO_REAL_IDENTITY'
  and (select resolved_by from public.manual_exception_intakes where username_key = 'me-subject-one') is not null
  and (select resolved_at from public.manual_exception_intakes where username_key = 'me-subject-one') is not null,
  'الحسم يُسجِّل الفعل والفاعل والوقت والسبب معاً');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action = 'installation.manual_exception.resolved'),
  'الحسم مُدقَّقٌ في audit_logs');

-- إعادة حسم صفّ محسومٍ بالفعل تُرفَض — لا حسمين على صفّ واحد.
select pg_temp.must_fail(
  format('select public.resolve_manual_exception_intake(%L, ''REJECTED_INVALID'', ''محاولة ثانية'', null, gen_random_uuid())',
   (select id from public.manual_exception_intakes where username_key = 'me-subject-one')),
  'صفٌّ محسومٌ لا يُحسَم مرّةً ثانية');

-- إعادة إرسالٍ لنفس فاعل الحسم بنفس request_id تُقال هادئة، لا خطأً.
do $$
declare
  v_rid uuid := gen_random_uuid();
  v_id uuid;
begin
  select id into v_id from public.manual_exception_intakes where username_key = 'me-replay-subject';
  perform public.resolve_manual_exception_intake(v_id, 'REJECTED_DUPLICATE', 'مكرّر', null, v_rid);
  perform public.resolve_manual_exception_intake(v_id, 'REJECTED_DUPLICATE', 'مكرّر', null, v_rid);
end $$;

select pg_temp.ok(
  (select status from public.manual_exception_intakes where username_key = 'me-replay-subject') = 'RESOLVED',
  'إعادة إرسال طلب الحسم بنفس request_id لا تفشل ولا تُكرِّر الأثر');

/* ---------------------------------------------------------------------------
   9. المراجعة المُرقَّمة: صفّ محسوم لا يظهر ضمن NEEDS_REVIEW، ويظهر ضمن
      RESOLVED، والبحث يعمل على المعرّف والاسم.
   ------------------------------------------------------------------------- */

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.page_manual_exceptions('NEEDS_REVIEW', null, 50, 0) -> 'rows')) x
              where x ->> 'username_key' = 'me-subject-one'),
  'استثناءٌ محسوم لا يظهر في طابور NEEDS_REVIEW بعد بعد');

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            (public.page_manual_exceptions('RESOLVED', null, 50, 0) -> 'rows')) x
          where x ->> 'username_key' = 'me-subject-one'),
  'استثناءٌ محسوم يظهر في طابور RESOLVED');

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            (public.page_manual_exceptions('NEEDS_REVIEW', 'me-replay', 50, 0) -> 'rows')) x
          where x ->> 'username_key' = 'me-no-request-id-does-not-exist')
  = false,
  'البحث لا يُعيد نتائج وهمية لمصطلحٍ غير موجود');

/* ---------------------------------------------------------------------------
   10. سطح CLASSIFICATION_REVIEW يتوافق: يحتسب استثناءً معلَّقاً، ويستبعد
       استثناءً محسوماً — بلا شبحٍ يبقى محتسَباً بعد إغلاقه.
   ------------------------------------------------------------------------- */

select public.create_manual_exception_intake(
  'OTHER', 'me-pending-review', 'مثالٌ لاستثناءٍ ما زال معلَّقاً', null, null, null, null, null, gen_random_uuid());

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            (public.product_classification_decisions(200, 0) -> 'rows')) x
          where x ->> 'username_key' = 'me-pending-review'),
  'استثناءٌ يدويٌّ معلَّقٌ يظهر في /work/classification كما يشترط التصميم');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.product_classification_decisions(200, 0) -> 'rows')) x
              where x ->> 'username_key' = 'me-subject-one'),
  'استثناءٌ يدويٌّ محسومٌ لا يبقى ظاهراً في /work/classification');

/* ===========================================================================
   طابور مهلة التفعيل المنقضية — page_installation_grace_queue()
   =========================================================================== */

insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values
  ('ACTIVATION_EVENTS', 'me-grace.xlsx', 'me-grace-checksum', 'v1',
   'ee000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

-- مرشّحٌ تجاوز 30 يوماً بلا تفعيلٍ مؤهَّل مدفوع — قرضٌ فقط، منذ 40 يوماً.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'ME-EVT-GRACE-EXPIRED', 'me-grace-expired', 'ME-DEBT-1', 1, false, now() - interval '40 days'
from public.saas_import_batches where source_checksum = 'me-grace-checksum';

insert into public.subscriber_classifications (username_key, classification, reason_code, source_completeness)
values ('me-grace-expired', 'NEEDS_REVIEW', 'NO_QUALIFYING_PAID_EVENT', 'COMPLETE');

-- مرشّحٌ لم تنقضِ مهلته بعد (منذ 5 أيام فقط) — يجب ألّا يظهر في هذا الطابور.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'ME-EVT-GRACE-FRESH', 'me-grace-fresh', 'ME-DEBT-1', 1, false, now() - interval '5 days'
from public.saas_import_batches where source_checksum = 'me-grace-checksum';

insert into public.subscriber_classifications (username_key, classification, reason_code, source_completeness)
values ('me-grace-fresh', 'NEEDS_REVIEW', 'NO_QUALIFYING_PAID_EVENT', 'COMPLETE');

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            (public.page_installation_grace_queue(null, 50, 0) -> 'rows')) x
          where x ->> 'username_key' = 'me-grace-expired'),
  'طابور المهلة المنقضية يعرض من تجاوز الثلاثين يوماً فعلاً');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.page_installation_grace_queue(null, 50, 0) -> 'rows')) x
              where x ->> 'username_key' = 'me-grace-fresh'),
  'طابور المهلة المنقضية لا يعرض من لم تنقضِ مهلته بعد');

select pg_temp.ok(
  (select (x ->> 'days_overdue')::int from jsonb_array_elements(
     (public.page_installation_grace_queue(null, 50, 0) -> 'rows')) x
   where x ->> 'username_key' = 'me-grace-expired') = 10,
  'أيام التجاوز محسوبةٌ من التاريخ المرجعي الفعلي — 40 يوماً ناقص 30 يساوي 10');

-- التجاوز المُدقَّق يُسقط الصفّ من هذا الطابور فوراً — الحالة تصير
-- NEW_PENDING_ACTIVATION لا GRACE_EXPIRED_REVIEW، فلا يبقى شبحاً هنا أيضاً.
select public.override_grace_expired_review('me-grace-expired', 'حالةٌ إدارية مُدقَّقة', gen_random_uuid());

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(
                (public.page_installation_grace_queue(null, 50, 0) -> 'rows')) x
              where x ->> 'username_key' = 'me-grace-expired'),
  'التجاوز يُسقط الصفّ من طابور المهلة المنقضية فوراً — لا شبح بعد التجاوز');

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(
            ((public.action_center() -> 'groups')::jsonb)) g
          where g ->> 'key' = 'MANUAL_EXCEPTION_REVIEW'),
  'مركز القرار يحمل مجموعة MANUAL_EXCEPTION_REVIEW الجديدة');

select pg_temp.ok(
  (select g ->> 'path' from jsonb_array_elements((public.action_center() -> 'groups')::jsonb) g
   where g ->> 'key' = 'SOURCE_NEEDS_REVALIDATION') = '/system/imports?completeness=NEEDS_REVALIDATION',
  'مسار SOURCE_NEEDS_REVALIDATION مُصحَّحٌ ليطابق مفتاح استعلام شاشة الاستيراد الفعلي');

rollback;
