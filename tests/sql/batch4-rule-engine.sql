-- Batch 4 — D-01 / D-12 / D-13 / D-14: قواعد اعتُمِدت، تُختبَر قبل أن يُعتمَد
-- عليها. معزول بنطاق تسمية b4-.
--
-- الغاية: إثبات منعٍ كان ممكن الحدوث لولا الحارس الجديد (UNMATCHED → NEW)،
-- وحتمية موعد المهلة (+30 يوماً تقويمياً بالضبط، لا تقريب شهري)، وأن انقضاء
-- المهلة لا يُنشئ استحقاقاً ولا حجباً تلقائياً، وأن الرفع/التصريح كلاهما
-- فعلٌ مُدقَّق لا نتيجة رفع ملف.

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

select '           == batch 4 rule engine (D-01 / D-12 / D-13 / D-14) ==';

-- ---------------------------------------------------------------------------
-- التثبيت: فاعلٌ مدير وفاعلٌ ضعيف الصلاحية.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('b4000000-0000-0000-0000-0000000000a1', 'b4-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('b4000000-0000-0000-0000-0000000000a1', 'B4 Admin', 'b4-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into auth.users (id, email) values
  ('b4000000-0000-0000-0000-0000000000a9', 'b4-viewer@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('b4000000-0000-0000-0000-0000000000a9', 'B4 Viewer', 'b4-viewer@fixture.invalid', 'viewer', true)
on conflict (id) do update set role = 'viewer', is_active = true;

insert into public.packages (code, semantic_category) values
  ('B4-PAID-1', 'PAID_PACKAGE'),
  ('B4-DEBT-1', 'DEBT_SERVICE')
on conflict (code) do nothing;

set local request.jwt.claim.sub = 'b4000000-0000-0000-0000-0000000000a1';

-- دفعات استيراد: مجهولة، ناقصة، مكتملة.
insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values
  ('ACTIVATION_EVENTS', 'b4-unknown.xlsx', 'b4-checksum-unknown', 'v1',
   'b4000000-0000-0000-0000-0000000000a1', 'UNKNOWN'),
  ('ACTIVATION_EVENTS', 'b4-partial.xlsx', 'b4-checksum-partial', 'v1',
   'b4000000-0000-0000-0000-0000000000a1', 'PARTIAL'),
  ('ACTIVATION_EVENTS', 'b4-complete.xlsx', 'b4-checksum-complete', 'v1',
   'b4000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- D-01 — سجلٌّ تاريخي، ثم كل حراس classify_newness واحداً واحداً.
-- ---------------------------------------------------------------------------

-- 1. الوجود التاريخي يحسم EXISTING مهما قال الملف — حتى لو بدا مؤهَّلاً للجدّة.
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values ('b4100000-0000-0000-0000-000000000001', 'b4-registry', 'وكيل تجربة', 'B4-FDT',
        date '2026-01-01', 13000, 'b4000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-registry', 'MATCHED', 'EXACT_USERNAME', 'B4-S-REGISTRY');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-REGISTRY', 'b4-registry', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-registry') ->> 'classification') = 'EXISTING'
  and (public.classify_newness('b4-registry') ->> 'reason_code') = 'REGISTRY_PREEXISTING',
  'D-01: سجلّ تاريخي حاسمٌ حتى مع كل شروط الجِدّة الأخرى محقَّقة');

-- 2. تعارض هوية لا يُصنَّف NEW مهما تحقّق غيره.
insert into public.subscriber_identities (username, identity_status)
values ('b4-conflict', 'CONFLICT');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-CONFLICT', 'b4-conflict', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-conflict') ->> 'classification') = 'NEEDS_REVIEW'
  and (public.classify_newness('b4-conflict') ->> 'reason_code') = 'IDENTITY_CONFLICT',
  'D-01: تعارض الهوية لا يصير NEW');

-- 3. UNMATCHED بلا صفّ هوية أصلاً — الحارس الجديد وحده يمنعها من NEW.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-UNMATCHED-ABSENT', 'b4-unmatched-absent', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-unmatched-absent') ->> 'classification') = 'NEEDS_REVIEW'
  and (public.classify_newness('b4-unmatched-absent') ->> 'reason_code') = 'IDENTITY_UNRESOLVED',
  'D-01: هويةٌ بلا صفّ (UNMATCHED ضمناً) لا تصير NEW ولو تساوى العدّادان من مصدرٍ مكتمل');

-- 3b. UNMATCHED بصفّ هوية صريح — لا فرق عن الغياب.
insert into public.subscriber_identities (username, identity_status)
values ('b4-unmatched-explicit', 'UNMATCHED');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-UNMATCHED-EXPLICIT', 'b4-unmatched-explicit', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-unmatched-explicit') ->> 'classification') = 'NEEDS_REVIEW'
  and (public.classify_newness('b4-unmatched-explicit') ->> 'reason_code') = 'IDENTITY_UNRESOLVED',
  'D-01: صفّ هوية UNMATCHED صريح لا يصير NEW');

-- 4. مصدرٌ مجهول الاكتمال — activations_count=1 وحده لا يكفي لمنح NEW.
insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-source-unknown', 'MATCHED', 'EXACT_USERNAME', 'B4-S-UNKNOWN');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-SRC-UNKNOWN', 'b4-source-unknown', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-unknown';

select pg_temp.ok(
  (public.classify_newness('b4-source-unknown') ->> 'classification') = 'NEEDS_REVIEW'
  and (public.classify_newness('b4-source-unknown') ->> 'reason_code') = 'UNKNOWN_SOURCE_COMPLETENESS',
  'D-01: هويةٌ مطابَقة وعدّادٌ متساوٍ لا يكفيان من مصدرٍ مجهول الاكتمال');

-- 5. مصدرٌ ناقص — نفس المنطق.
insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-source-partial', 'MATCHED', 'EXACT_USERNAME', 'B4-S-PARTIAL');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-SRC-PARTIAL', 'b4-source-partial', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-partial';

select pg_temp.ok(
  (public.classify_newness('b4-source-partial') ->> 'classification') = 'NEEDS_REVIEW'
  and (public.classify_newness('b4-source-partial') ->> 'reason_code') = 'PARTIAL_SOURCE',
  'D-01: مصدرٌ ناقص لا يمنح NEW ولو تساوى العدّادان');

-- 6. الاجتماع الكامل للشروط الأربعة — وعندها فقط NEW.
insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-matched-new', 'MATCHED', 'EXACT_USERNAME', 'B4-S-MATCHED-NEW');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-MATCHED-NEW', 'b4-matched-new', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-matched-new') ->> 'classification') = 'NEW'
  and (public.classify_newness('b4-matched-new') ->> 'reason_code') = 'COMPLETE_LIFETIME_HISTORY_OBSERVED',
  'D-01: هويةٌ مطابَقة + مصدرٌ مكتمل + لا سجلّ تاريخي + تفعيلٌ مؤهّل ⇒ NEW');

-- 7. activations_count > 1 وحده لا يفرض EXISTING إن كان العدّادان متساويين.
insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-multi-activation', 'MATCHED', 'EXACT_USERNAME', 'B4-S-MULTI');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-MULTI-1', 'b4-multi-activation', 'B4-PAID-1', 2, false, now() - interval '2 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-MULTI-2', 'b4-multi-activation', 'B4-PAID-1', 2, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-multi-activation') ->> 'classification') = 'NEW',
  'D-01: activations_count=2 وحده لا يفرض EXISTING طالما العدّادان متساويان');

-- 8. العدّاد التاريخي يتجاوز المرصود ⇒ EXISTING حتماً (سجلٌّ خارج الملف).
insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-lifetime-exceeds', 'MATCHED', 'EXACT_USERNAME', 'B4-S-EXCEEDS');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-EXCEEDS', 'b4-lifetime-exceeds', 'B4-PAID-1', 5, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-lifetime-exceeds') ->> 'classification') = 'EXISTING'
  and (public.classify_newness('b4-lifetime-exceeds') ->> 'reason_code') = 'LIFETIME_COUNT_EXCEEDS_OBSERVED',
  'D-01: عدّاد عمر يتجاوز المرصود يحسم EXISTING');

-- 9. تاريخٌ من باقة دين فقط (Loan-3) لا يُنشئ جِدّة — لا حدث مدفوع مؤهَّل.
insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('b4-debt-only', 'MATCHED', 'EXACT_USERNAME', 'B4-S-DEBT');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-DEBT', 'b4-debt-only', 'B4-DEBT-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-complete';

select pg_temp.ok(
  (public.classify_newness('b4-debt-only') ->> 'classification') = 'NEEDS_REVIEW'
  and (public.classify_newness('b4-debt-only') ->> 'reason_code') = 'NO_QUALIFYING_PAID_EVENT',
  'D-01: تاريخ باقة دين وحدها (Loan-3) لا يُنشئ استحقاق جِدّة');

-- ---------------------------------------------------------------------------
-- D-12 — عقد قراءة المهلة: +30 يوماً تقويمياً بالضبط من saas_created_at.
-- ---------------------------------------------------------------------------

insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by)
values ('USERS_SNAPSHOT', 'b4-snapshots.xlsx', 'b4-checksum-snapshots', 'v1',
        'b4000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- 10. لا لقطة SaaS إطلاقاً ⇒ لا مرساة تاريخ ⇒ UNKNOWN، لا تخمين.
select pg_temp.ok(
  (public.installation_grace_status('b4-grace-unknown') ->> 'status') = 'UNKNOWN',
  'D-12: بلا تاريخ تركيب معروف، القراءة UNKNOWN لا تخمين');

-- 11. عشرة أيام منذ التركيب، بلا تفعيل مؤهّل ⇒ انتظارٌ، ومتبقٍّ 20 يوماً بالضبط.
insert into public.saas_user_snapshots (import_batch_id, snapshot_at, saas_user_id, username, saas_created_at)
select id, now(), 'B4-SU-PENDING', 'b4-grace-pending', now() - interval '10 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-snapshots';

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-pending') ->> 'status') = 'PENDING_ACTIVATION'
  and (public.installation_grace_status('b4-grace-pending') ->> 'days_remaining')::int = 20,
  'D-12: عشرة أيام من التركيب بلا تفعيل ⇒ انتظار، ومتبقٍّ 20 يوماً بالضبط');

-- 12. اليوم الثلاثون بالضبط لا يزال داخل المهلة — الحد الأدنى للانقضاء.
insert into public.saas_user_snapshots (import_batch_id, snapshot_at, saas_user_id, username, saas_created_at)
select id, now(), 'B4-SU-B30', 'b4-grace-boundary30', now() - interval '30 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-snapshots';

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-boundary30') ->> 'status') = 'PENDING_ACTIVATION',
  'D-12: اليوم الثلاثون تماماً لا يزال ضمن المهلة، لا منقضياً');

-- 13. اليوم الحادي والثلاثون: انقضت المهلة فعلاً — لا تقريبٌ شهري، تقويمٌ صرف.
insert into public.saas_user_snapshots (import_batch_id, snapshot_at, saas_user_id, username, saas_created_at)
select id, now(), 'B4-SU-B31', 'b4-grace-boundary31', now() - interval '31 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-snapshots';

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-boundary31') ->> 'status') = 'GRACE_EXPIRED_REVIEW'
  and (public.installation_grace_status('b4-grace-boundary31') ->> 'days_remaining')::int = -1,
  'D-12: اليوم الحادي والثلاثون منقضٍ بالضبط (+30 يوماً تقويمياً، لا تقريب)');

-- 14. تفعيلٌ مؤهّل داخل المهلة يُنهي الانتظار فوراً، ولو لم يُحدَّث التصنيف بعد.
insert into public.saas_user_snapshots (import_batch_id, snapshot_at, saas_user_id, username, saas_created_at)
select id, now(), 'B4-SU-QUAL', 'b4-grace-qualified', now() - interval '5 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-snapshots';

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, activations_count, canceled, event_created_at)
select id, 'B4-EVT-GRACE-QUAL', 'b4-grace-qualified', 'B4-PAID-1', 1, false, now() - interval '1 day'
from public.saas_import_batches where source_checksum = 'b4-checksum-unknown';

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-qualified') ->> 'status') = 'QUALIFIED',
  'D-12: تفعيلٌ مؤهّل داخل المهلة ⇒ QUALIFIED فوراً بالقراءة الحيّة');

-- 15. مشتركٌ محسومٌ NEW فعلاً: جِدّته لم تعد قيد الانتظار مهما تأخر تاريخه.
insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('b4-grace-resolved-new', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE');
insert into public.saas_user_snapshots (import_batch_id, snapshot_at, saas_user_id, username, saas_created_at)
select id, now(), 'B4-SU-RESOLVED', 'b4-grace-resolved-new', now() - interval '90 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-snapshots';

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-resolved-new') ->> 'status') = 'NOT_APPLICABLE',
  'D-12: تصنيفٌ محسوم NEW ⇒ ليس بانتظار تفعيل، بصرف النظر عن قِدَم التاريخ');

-- 16. مسدودٌ لسببٍ غير نقص التفعيل (تعارض هوية) ⇒ ليس ضمن قراءة المهلة أصلاً.
insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('b4-grace-blocked-identity', 'NEEDS_REVIEW', 'IDENTITY_CONFLICT', 'UNKNOWN');
insert into public.saas_user_snapshots (import_batch_id, snapshot_at, saas_user_id, username, saas_created_at)
select id, now(), 'B4-SU-BLOCKED', 'b4-grace-blocked-identity', now() - interval '90 days'
from public.saas_import_batches where source_checksum = 'b4-checksum-snapshots';

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-blocked-identity') ->> 'status') = 'NOT_APPLICABLE',
  'D-12: مسدودٌ بتعارض هوية ⇒ ليس بانتظار تفعيل ولا مهلة منقضية');

-- ---------------------------------------------------------------------------
-- D-13 — بعد انقضاء المهلة: لا استحقاق تلقائي، لا حجب دائم تلقائي، تجاوزٌ
-- مدقَّق وحيد يتطلَّب سبباً وطلباً مميَّزاً ويُدقَّق.
-- ---------------------------------------------------------------------------

-- 17. لا صفّ استحقاقٍ ولا دفعةٍ نشأ من مجرّد انقضاء المهلة.
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where subscriber_id in ('b4-grace-boundary31', 'b4-grace-blocked-identity')),
  'D-13: انقضاء المهلة لم يُنشئ أي استحقاق تلقائياً');

-- 18. لا حجبٌ دائم أُنشئ تلقائياً لمن انقضت مهلته.
select pg_temp.ok(
  not exists (select 1 from public.installation_holds where subscriber_id = 'b4-grace-boundary31'),
  'D-13: انقضاء المهلة لم يُنشئ حجباً دائماً تلقائياً');

-- 19. التجاوز يرفض من لا يملك installation.grace_override.
select pg_temp.must_fail(
  'set local request.jwt.claim.sub = ''b4000000-0000-0000-0000-0000000000a9'';
   select public.override_grace_expired_review(
     ''b4-grace-boundary31'', ''محاولة بلا صلاحية'', gen_random_uuid())',
  'D-13: التجاوز يرفض فاعلاً بلا installation.grace_override');

-- 20. التجاوز يرفض سبباً فارغاً.
select pg_temp.must_fail(
  'select public.override_grace_expired_review(''b4-grace-boundary31'', ''  '', gen_random_uuid())',
  'D-13: التجاوز يرفض سبباً فارغاً');

-- 21. التجاوز يرفض مشتركاً ليس في حالة GRACE_EXPIRED_REVIEW فعلاً (يعيد التحقق خادمياً).
select pg_temp.must_fail(
  'select public.override_grace_expired_review(''b4-grace-pending'', ''سببٌ ما'', gen_random_uuid())',
  'D-13: التجاوز يرفض مشتركاً لم تنقضِ مهلته فعلاً');

-- 22. التجاوز المصرَّح يقع، وسببه محفوظ، وحالته تصير PENDING_ACTIVATION (لا NEW ولا EXISTING).
select public.override_grace_expired_review(
  'b4-grace-boundary31', 'موافقة إدارية بعد مراجعة السجل', 'b4a00000-0000-0000-0000-00000000ab01');

select pg_temp.ok(
  exists (select 1 from public.grace_period_overrides
          where username_key = 'b4-grace-boundary31'
            and reason = 'موافقة إدارية بعد مراجعة السجل'
            and overridden_by = 'b4000000-0000-0000-0000-0000000000a1'
            and request_id = 'b4a00000-0000-0000-0000-00000000ab01'),
  'D-13: التجاوز المصرَّح محفوظٌ بسببه وفاعله وطلبه');

select pg_temp.ok(
  (public.installation_grace_status('b4-grace-boundary31') ->> 'status') = 'PENDING_ACTIVATION',
  'D-13: بعد التجاوز، الحالة تصير انتظاراً — لا استحقاقاً ولا حجباً دائماً');

select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'installation.grace.overridden'
            and actor_id = 'b4000000-0000-0000-0000-0000000000a1'
            and request_id = 'b4a00000-0000-0000-0000-00000000ab01'
            and old_value = 'GRACE_EXPIRED_REVIEW'
            and extra = 'موافقة إدارية بعد مراجعة السجل'),
  'D-13: التجاوز مدقَّقٌ — فاعله ووقته وسببه وطلبه في audit_logs');

-- 23. إعادة الطلب نفسه لا تُكرِّر التجاوز (أمان الاستبدال).
select (select count(*) from public.grace_period_overrides
        where request_id = 'b4a00000-0000-0000-0000-00000000ab01') as _b4_override_count_before \gset

select public.override_grace_expired_review(
  'b4-grace-boundary31', 'محاولة إعادة إرسال', 'b4a00000-0000-0000-0000-00000000ab01');

select pg_temp.ok(
  (select count(*) from public.grace_period_overrides
   where request_id = 'b4a00000-0000-0000-0000-00000000ab01') = :_b4_override_count_before,
  'D-13: إعادة الطلب نفسه بلا أثرٍ ثانٍ — أمانٌ عند التكرار');

-- ---------------------------------------------------------------------------
-- D-14 — رفع الملف لا يعني الاكتمال؛ الاكتمال تصريحٌ مُدقَّق؛ بياناتٌ متأخرة
-- بعد COMPLETE تُعيد الدفعة السابقة NEEDS_REVALIDATION بلا حذفٍ ولا صمت.
-- ---------------------------------------------------------------------------

-- 24. الرفع وحده لا يعني COMPLETE — الحالة الافتراضية UNKNOWN.
insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by)
values ('ACTIVATION_EVENTS', 'b4-just-uploaded.xlsx', 'b4-checksum-just-uploaded', 'v1',
        'b4000000-0000-0000-0000-0000000000a1');

select pg_temp.ok(
  (select completeness_status from public.saas_import_batches
   where source_checksum = 'b4-checksum-just-uploaded') = 'UNKNOWN',
  'D-14: رفع ملف وحده لا يجعله COMPLETE — الحالة الافتراضية UNKNOWN');

-- 25. التصريح باكتمالٍ يرفض فاعلاً بلا صلاحية saas.import.
-- تغطيةٌ في حزيران، بعيدة عمداً عن نطاق آب أدناه (فقرة 27) كي لا يتقاطعا.
select pg_temp.must_fail(
  'set local request.jwt.claim.sub = ''b4000000-0000-0000-0000-0000000000a9'';
   select public.declare_import_completeness(
     (select id from public.saas_import_batches
      where source_checksum = ''b4-checksum-just-uploaded''),
     ''COMPLETE'', date ''2026-06-01'', date ''2026-06-30'', ''دليل'', gen_random_uuid())',
  'D-14: التصريح بالاكتمال يرفض فاعلاً بلا صلاحية saas.import');

-- 26. التصريح الصريح المصرَّح يعمل، ويترك أثراً مدقَّقاً.
select public.declare_import_completeness(
  (select id from public.saas_import_batches where source_checksum = 'b4-checksum-just-uploaded'),
  'COMPLETE', date '2026-06-01', date '2026-06-30', 'مطابقة العدّ والتكرار والفواتير',
  'b4a00000-0000-0000-0000-00000000ab10');

select pg_temp.ok(
  (select completeness_status from public.saas_import_batches
   where source_checksum = 'b4-checksum-just-uploaded') = 'COMPLETE'
  and exists (select 1 from public.import_completeness_declarations
              where evidence = 'مطابقة العدّ والتكرار والفواتير'
                and declared_by = 'b4000000-0000-0000-0000-0000000000a1'),
  'D-14: التصريح الصريح المُدقَّق ينقل الدفعة COMPLETE ويُسجَّل بفاعله ودليله');

-- 27. بياناتٌ متأخرة تتقاطع تغطيتها مع دفعة COMPLETE سابقة ⇒ تلك الدفعة
--     تتحوّل NEEDS_REVALIDATION تلقائياً بمجرّد اكتمال استيراد الدفعة المتأخرة.
insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status, declared_coverage_start, declared_coverage_end,
   observed_min_created_at, observed_max_created_at, status)
values ('ACTIVATION_EVENTS', 'b4-august-original.xlsx', 'b4-checksum-august-original', 'v1',
        'b4000000-0000-0000-0000-0000000000a1', 'COMPLETE',
        date '2026-08-01', date '2026-08-31',
        timestamptz '2026-08-01', timestamptz '2026-08-30', 'draft');
update public.saas_import_batches set status = 'imported'
where source_checksum = 'b4-checksum-august-original';

select pg_temp.ok(
  (select completeness_status from public.saas_import_batches
   where source_checksum = 'b4-checksum-august-original') = 'COMPLETE',
  'D-14: الدفعة الأصلية تبقى COMPLETE قبل وصول أي بيانات متأخرة');

insert into public.saas_import_batches
  (source_kind, source_filename, source_checksum, parser_version, imported_by,
   observed_min_created_at, observed_max_created_at, status)
values ('ACTIVATION_EVENTS', 'b4-august-late.xlsx', 'b4-checksum-august-late', 'v1',
        'b4000000-0000-0000-0000-0000000000a1',
        timestamptz '2026-08-31', timestamptz '2026-08-31 23:00', 'draft');
update public.saas_import_batches set status = 'imported'
where source_checksum = 'b4-checksum-august-late';

select pg_temp.ok(
  (select completeness_status from public.saas_import_batches
   where source_checksum = 'b4-checksum-august-original') = 'NEEDS_REVALIDATION',
  'D-14: بيانات متأخرة متقاطعة التغطية تعيد الدفعة المكتملة سابقاً NEEDS_REVALIDATION تلقائياً');

select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'import.completeness.needs_revalidation'
            and entity_type = 'saas_import_batch'
            and old_value = 'COMPLETE' and new_value = 'NEEDS_REVALIDATION'
            and entity_id = (select id from public.saas_import_batches
                              where source_checksum = 'b4-checksum-august-original')),
  'D-14: إعادة التصنيف مدقَّقةٌ في audit_logs بلا أي تدخّل يدوي');

-- 28. البيانات المالية التاريخية (لا يوجد شيءٌ منها هنا أصلاً) لم تُحذَف ولم تُعاد كتابتها،
--     ولا شيء أعاد الدفعة COMPLETE تلقائياً — الانتقال يبقى معلَّقاً بانتظار مراجعةٍ صريحة.
select pg_temp.ok(
  (select completeness_status from public.saas_import_batches
   where source_checksum = 'b4-checksum-august-original') = 'NEEDS_REVALIDATION',
  'D-14: لا شيء أعاد الدفعة COMPLETE صمتاً — تبقى NEEDS_REVALIDATION بانتظار فعلٍ صريح');

-- 29. الخروج من NEEDS_REVALIDATION يتطلَّب تصريحاً صريحاً جديداً — لا يحدث تلقائياً.
select public.declare_import_completeness(
  (select id from public.saas_import_batches where source_checksum = 'b4-checksum-august-original'),
  'COMPLETE', date '2026-08-01', date '2026-08-31',
  'روجعت البيانات المتأخرة وتأكّد عدم تعارضها مع الدفعة الأصلية',
  'b4a00000-0000-0000-0000-00000000ab11');

select pg_temp.ok(
  (select completeness_status from public.saas_import_batches
   where source_checksum = 'b4-checksum-august-original') = 'COMPLETE'
  and exists (select 1 from public.import_completeness_declarations
              where previous_status = 'NEEDS_REVALIDATION' and declared_status = 'COMPLETE'
                and import_batch_id = (select id from public.saas_import_batches
                                        where source_checksum = 'b4-checksum-august-original')),
  'D-14: العودة إلى COMPLETE من NEEDS_REVALIDATION فعلٌ صريحٌ مُدقَّق، لا تلقائي');

rollback;
