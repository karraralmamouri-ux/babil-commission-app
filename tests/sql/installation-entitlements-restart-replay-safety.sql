-- 20261101090000: restart/resume replay safety (Blocker 1), mandatory
-- expected_rows on any non-final batch (Blocker 2), and file-identity
-- enforcement on continuation (Blocker 3) for
-- import_installation_entitlements.
--
-- معزول بملفه ومعاملته ونطاق تسمية RR-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail_code(p_sql text, p_label text, p_sqlstate text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  if p_sqlstate is not null and sqlstate <> p_sqlstate then
    return 'FAILED: ' || p_label || ' — الرمز ' || sqlstate || ' لا ' || p_sqlstate || ' (' || sqlerrm || ')';
  end if;
  return '   ok ' || p_label;
end;
$$;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_user::text, true); end;
$$;

begin;

select '   == installation entitlements restart/replay safety ==';

insert into auth.users (id, email) values
  ('ee000000-0000-0000-0000-0000000000a1', 'rr-admin-a@fixture.invalid'),
  ('ee000000-0000-0000-0000-0000000000a2', 'rr-admin-b@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ee000000-0000-0000-0000-0000000000a1','RR Admin A','rr-admin-a@fixture.invalid','admin',true),
  ('ee000000-0000-0000-0000-0000000000a2','RR Admin B','rr-admin-b@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

select pg_temp.act_as('ee000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------
-- Blocker 1 · السيناريو المطلوب حرفياً: صفوفٌ ١-٢، فقدان batchId، إعادة
-- تشغيلٍ من البداية بمعرّف طلبٍ جديد، ثم الصفّ الثالث والإنهاء.
-- ---------------------------------------------------------------------

-- 1-2: expected_rows=3، إرسال الصفّين الأول والثاني، p_finalize=false.
-- الموضع صريحٌ (p_row_offset=0) — تماماً ما يرسله import-run.ts فعلياً.
select (public.import_installation_entitlements('2026-12','rr-restart.xlsx','rr-sha-restart',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','RR-RESTART-1','reseller','RR','remaining',13000),
    jsonb_build_object('subscriber_id','RR-RESTART-2','reseller','RR','remaining',13000)
  ), gen_random_uuid(), null, 3, false, 0) -> 'batch') as rr_c1 \gset

select (:'rr_c1'::jsonb ->> 'batch_id') as rr_batch_id \gset

select pg_temp.ok(
  (:'rr_c1'::jsonb ->> 'source_rows')::int = 2
    and (select source_rows = 2 and status = 'in_progress'
         from public.installation_batches where id = (:'rr_batch_id')::uuid),
  'الجزء الأول (موضع 0، صفّان): source_rows=2، IN_PROGRESS');

-- 3: فقدان batchId محلياً — لا أثر خادميّ لهذه الخطوة، توضيحيّة فقط.

-- 4: إعادة تشغيلٍ من البداية — نفس الملف (بصمةٌ واسمٌ وexpected_rows
-- متطابقة)، معرّف طلبٍ جديدٌ تماماً، وp_batch_id فارغٌ (العميل لا يتذكّره).
-- الخادم يجد الدفعة عبر الاستئناف التلقائي بالبصمة، وp_row_offset=0 يُعلن
-- أن هذا بالضبط نفس مدى الملف الذي استُقبل سابقاً.
select (public.import_installation_entitlements('2026-12','rr-restart.xlsx','rr-sha-restart',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','RR-RESTART-1','reseller','RR','remaining',13000),
    jsonb_build_object('subscriber_id','RR-RESTART-2','reseller','RR','remaining',13000)
  ), gen_random_uuid(), null, 3, false, 0) -> 'batch') as rr_c2 \gset

-- 5: source_rows يبقى 2 — لا ازدواج، ولا صفّ إضافيّ في الجدول الفعليّ.
select pg_temp.ok(
  (:'rr_c2'::jsonb ->> 'source_rows')::int = 0
    and (:'rr_c2'::jsonb ->> 'accepted')::int = 0
    and (:'rr_c2'::jsonb ->> 'batch_id') = :'rr_batch_id'
    and (select source_rows = 2 and accepted_rows = 2 and status = 'in_progress'
         from public.installation_batches where id = (:'rr_batch_id')::uuid),
  'إعادة تشغيلٍ كاملة (نفس الموضع 0-2، معرّف طلبٍ جديد): source_rows يبقى 2 لا 4 — لا أثر إضافيّ إطلاقاً');

select pg_temp.ok(
  (select count(*) = 2 from public.installation_entitlements where reseller = 'RR'),
  'إعادة التشغيل لم تكتب صفوفاً إضافية في الجدول الفعليّ');

-- 6-7: إرسال الصفّ الثالث (موضع 2)، source_rows يصبح 3.
select (public.import_installation_entitlements('2026-12','rr-restart.xlsx','rr-sha-restart',
  jsonb_build_array(jsonb_build_object('subscriber_id','RR-RESTART-3','reseller','RR','remaining',13000)),
  gen_random_uuid(), (:'rr_batch_id')::uuid, 3, true, 2) -> 'batch') as rr_c3 \gset

-- 8-10: الإنهاء ينجح، الدفعة COMPLETED، والمقبول صحيح.
select pg_temp.ok(
  (:'rr_c3'::jsonb ->> 'status') = 'completed'
    and (:'rr_c3'::jsonb -> 'batch_totals' ->> 'source_rows')::int = 3
    and (:'rr_c3'::jsonb -> 'batch_totals' ->> 'accepted')::int = 3
    and (select status = 'completed' and source_rows = 3 and accepted_rows = 3
         from public.installation_batches where id = (:'rr_batch_id')::uuid),
  'الصفّ الثالث يكمل العدد (3 من 3) وينهي الدفعة بنجاح — COMPLETED');

select pg_temp.ok(
  (select count(*) = 3 from public.installation_entitlements where reseller = 'RR'),
  'الصفوف الثلاثة كلّها محفوظةٌ فعلياً، لا أكثر ولا أقلّ رغم إعادة التشغيل');

-- ---------------------------------------------------------------------
-- Blocker 1 · تراكبٌ جزئي: جزءٌ ثانٍ يعيد نصف ما سبق ويضيف نصفاً جديداً.
-- ---------------------------------------------------------------------

-- موضع 0-3 (3 صفوف)، غير نهائي، expected_rows=5.
select (public.import_installation_entitlements('2026-12','rr-overlap.xlsx','rr-sha-overlap',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','RR-OVERLAP-1','reseller','RR-OV','remaining',13000),
    jsonb_build_object('subscriber_id','RR-OVERLAP-2','reseller','RR-OV','remaining',13000),
    jsonb_build_object('subscriber_id','RR-OVERLAP-3','reseller','RR-OV','remaining',13000)
  ), gen_random_uuid(), null, 5, false, 0) -> 'batch') as rr_ov_c1 \gset

select (:'rr_ov_c1'::jsonb ->> 'batch_id') as rr_ov_batch_id \gset

-- موضع 1-5 (4 صفوف: الصف الثاني والثالث مُعادان، والرابع والخامس جديدان) —
-- تراكبٌ جزئيّ بين [0,3) المُستقبل سابقاً و[1,5) الوارد الآن. الجديد فعلياً
-- هو [3,5) فقط، طوله 2 — هذا ما يجب أن يُضاف إلى source_rows، لا طول
-- النداء الخام (4).
select (public.import_installation_entitlements('2026-12','rr-overlap.xlsx','rr-sha-overlap',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','RR-OVERLAP-2','reseller','RR-OV','remaining',13000),
    jsonb_build_object('subscriber_id','RR-OVERLAP-3','reseller','RR-OV','remaining',13000),
    jsonb_build_object('subscriber_id','RR-OVERLAP-4','reseller','RR-OV','remaining',13000),
    jsonb_build_object('subscriber_id','RR-OVERLAP-5','reseller','RR-OV','remaining',13000)
  ), gen_random_uuid(), (:'rr_ov_batch_id')::uuid, 5, true, 1) -> 'batch') as rr_ov_c2 \gset

select pg_temp.ok(
  (:'rr_ov_c2'::jsonb ->> 'source_rows')::int = 2
    and (:'rr_ov_c2'::jsonb ->> 'status') = 'completed'
    and (select source_rows = 5 and status = 'completed'
         from public.installation_batches where id = (:'rr_ov_batch_id')::uuid),
  'تراكبٌ جزئي (موضع 1-5 فوق 0-3 سابقة): الجديد فعلياً صفّان فقط — source_rows يصل 5 لا 7، وتُنهي بنجاح');

select pg_temp.ok(
  (select count(*) = 5 from public.installation_entitlements where reseller = 'RR-OV'),
  'خمسة صفوفٍ فقط محفوظة رغم التراكب — لا ازدواجٌ في installation_entitlements (on conflict do nothing)');

-- ---------------------------------------------------------------------
-- Blocker 2 · expected_rows إلزاميّة عند فتح دفعةٍ للإلحاق
-- ---------------------------------------------------------------------

select pg_temp.must_fail_code(
  $q$select public.import_installation_entitlements('2026-12','rr-noexp.xlsx','rr-sha-noexp',
      '[{"subscriber_id":"RR-NOEXP-1","reseller":"RR-NOEXP","remaining":13000}]'::jsonb,
      gen_random_uuid(), null, null, false)$q$,
  'إنشاء دفعةٍ غير نهائية (p_finalize=false) بلا expected_rows يُرفض',
  '22023');

select pg_temp.must_fail_code(
  $q$select public.import_installation_entitlements('2026-12','rr-noexp.xlsx','rr-sha-noexp',
      '[{"subscriber_id":"RR-NOEXP-1","reseller":"RR-NOEXP","remaining":13000}]'::jsonb,
      gen_random_uuid(), null, 0, false)$q$,
  'إنشاء دفعةٍ غير نهائية بـ expected_rows=0 (غير موجَب) يُرفض',
  '22023');

select pg_temp.must_fail_code(
  $q$select public.import_installation_entitlements('2026-12','rr-noexp.xlsx','rr-sha-noexp',
      '[{"subscriber_id":"RR-NOEXP-1","reseller":"RR-NOEXP","remaining":13000}]'::jsonb,
      gen_random_uuid(), null, -1, false)$q$,
  'إنشاء دفعةٍ غير نهائية بـ expected_rows سالبة يُرفض',
  '22023');

select pg_temp.ok(
  (select count(*) = 0 from public.installation_batches where file_name = 'rr-noexp.xlsx'),
  'كل محاولات إنشاء دفعةٍ بلا expected_rows صالحة رُفضت قبل أن تترك أثراً — لا دفعة أُنشئت أصلاً');

-- إنشاءٌ نهائيّ (single-shot، p_finalize الافتراضي true) يبقى معفياً — يكتمل
-- ذرّياً في نفس النداء فلا حاجة تفرض expected_rows.
select pg_temp.ok(
  ((public.import_installation_entitlements('2026-12','rr-singleshot.xlsx','rr-sha-singleshot',
    '[{"subscriber_id":"RR-SS-1","reseller":"RR-SS","remaining":13000}]'::jsonb,
    gen_random_uuid()) -> 'batch') ->> 'status') = 'completed',
  'نداءٌ نهائيٌّ منفردٌ (single-shot) يبقى معفياً من إلزام expected_rows — يكتمل بنجاح بلا إعلانه');

-- استئنافٌ بدون expected_rows على دفعةٍ تحمله فعلاً يُرفض.
select (public.import_installation_entitlements('2026-12','rr-mismatch.xlsx','rr-sha-mismatch',
  '[{"subscriber_id":"RR-MM-1","reseller":"RR-MM","remaining":13000}]'::jsonb,
  gen_random_uuid(), null, 2, false) -> 'batch' ->> 'batch_id') as rr_mismatch_batch_id \gset

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','rr-mismatch.xlsx','rr-sha-mismatch',
      '[{"subscriber_id":"RR-MM-2","reseller":"RR-MM","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'rr_mismatch_batch_id'),
  'إلحاقٌ بدفعةٍ تحمل expected_rows فعلياً، لكن بلا إعلانه في نداء الإلحاق، يُرفض',
  '22023');

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','rr-mismatch.xlsx','rr-sha-mismatch',
      '[{"subscriber_id":"RR-MM-2","reseller":"RR-MM","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 999, true)$q$, :'rr_mismatch_batch_id'),
  'إلحاقٌ بـ expected_rows مختلفة عن المخزَّنة في الدفعة يُرفض',
  '22023');

select pg_temp.ok(
  (select status = 'in_progress' and source_rows = 1 and accepted_rows = 1
   from public.installation_batches where id = (:'rr_mismatch_batch_id')::uuid),
  'محاولتا expected_rows الخاطئتان لم تُغيّرا شيئاً في الدفعة');

select pg_temp.ok(
  ((public.import_installation_entitlements('2026-12','rr-mismatch.xlsx','rr-sha-mismatch',
    '[{"subscriber_id":"RR-MM-2","reseller":"RR-MM","remaining":13000}]'::jsonb,
    gen_random_uuid(), (:'rr_mismatch_batch_id')::uuid, 2, true) -> 'batch') ->> 'status') = 'completed',
  'إلحاقٌ بـ expected_rows المطابقة تماماً (2) ينجح ويُنهي الدفعة');

-- ---------------------------------------------------------------------
-- Blocker 3 · هوية الملف صارمة على الإلحاق الصريح
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','rr-identity-a.xlsx','rr-sha-identity',
  '[{"subscriber_id":"RR-ID-1","reseller":"RR-ID","remaining":13000}]'::jsonb,
  gen_random_uuid(), null, 2, false) -> 'batch' ->> 'batch_id') as rr_id_batch_id \gset

-- نفس اسم الملف: الإلحاق ينجح.
select pg_temp.ok(
  ((public.import_installation_entitlements('2026-12','rr-identity-a.xlsx','rr-sha-identity',
    '[{"subscriber_id":"RR-ID-2","reseller":"RR-ID","remaining":13000}]'::jsonb,
    gen_random_uuid(), (:'rr_id_batch_id')::uuid, 2, false, 1) -> 'batch') ->> 'status') = 'in_progress',
  'إلحاقٌ بنفس اسم الملف تماماً ينجح');

-- اسمٌ مختلف (نفس البصمة والفترة وexpected_rows) يُرفض.
select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','rr-identity-DIFFERENT.xlsx','rr-sha-identity',
      '[{"subscriber_id":"RR-ID-3","reseller":"RR-ID","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 2, true)$q$, :'rr_id_batch_id'),
  'إلحاقٌ باسم ملفٍّ مختلفٍ عن الدفعة (رغم تطابق البصمة) يُرفض',
  '22023');

select pg_temp.ok(
  (select status = 'in_progress' and source_rows = 2 and accepted_rows = 2
   from public.installation_batches where id = (:'rr_id_batch_id')::uuid),
  'محاولة اسم الملف المختلف لم تُغيّر شيئاً في الدفعة');

-- استئنافٌ تلقائيٌّ (بلا batch_id) بنفس البصمة لكن باسم ملفٍّ مختلف: لا
-- يُستأنَف — يفتح دفعةً جديدةً منفصلة بدل الرفض (طريقٌ ضمنيٌّ أفضل-جهد).
select (public.import_installation_entitlements('2026-12','rr-identity-OTHER.xlsx','rr-sha-identity',
  '[{"subscriber_id":"RR-ID-4","reseller":"RR-ID-OTHER","remaining":13000}]'::jsonb,
  gen_random_uuid(), null, 1, false) -> 'batch' ->> 'batch_id') as rr_id_other_batch_id \gset

select pg_temp.ok(
  :'rr_id_other_batch_id' <> :'rr_id_batch_id',
  'استئنافٌ تلقائيٌّ باسم ملفٍّ مختلف عن الدفعة القائمة يفتح دفعةً جديدةً منفصلة، لا يُلحَق بالقديمة');

-- إنهاءٌ صريح: الدفعة عند expected_rows بالضبط بالفعل (صفّان)، فهذا النداء
-- يعيد موضع الجزء الثاني (لا جديد فيه) ويطلب الإنهاء — ينجح ويُقفل الدفعة.
select ((public.import_installation_entitlements('2026-12','rr-identity-a.xlsx','rr-sha-identity',
  '[{"subscriber_id":"RR-ID-2","reseller":"RR-ID","remaining":13000}]'::jsonb,
  gen_random_uuid(), (:'rr_id_batch_id')::uuid, 2, true, 1) -> 'batch') ->> 'status') as rr_id_final \gset

select pg_temp.ok(:'rr_id_final' = 'completed', 'إنهاءٌ صريحٌ بعد اكتمال العدد ينجح — الدفعة COMPLETED');

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','rr-identity-a.xlsx','rr-sha-identity',
      '[{"subscriber_id":"RR-ID-6","reseller":"RR-ID","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'rr_id_batch_id'),
  'دفعةٌ مكتملة ترفض أيّ استئنافٍ — ولو باسم الملف الصحيح تماماً',
  '22023');

-- ---------------------------------------------------------------------
-- سلوكٌ سابقٌ يجب ألا ينكسر: أمان إعادة الطلب بمعرّف request_id نفسه (لا
-- محاولة إعادة تشغيلٍ بمعرّفٍ جديد) يبقى كما كان — لا استيرادٍ مضاعف.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','rr-samereq.xlsx','rr-sha-samereq',
  '[{"subscriber_id":"RR-SAMEREQ-1","reseller":"RR-SAMEREQ","remaining":13000}]'::jsonb,
  '99999999-9999-9999-9999-999999999911'::uuid) -> 'batch' ->> 'accepted') as rr_samereq_c1 \gset

select ((public.import_installation_entitlements('2026-12','rr-samereq.xlsx','rr-sha-samereq',
  '[{"subscriber_id":"RR-SAMEREQ-1","reseller":"RR-SAMEREQ","remaining":13000}]'::jsonb,
  '99999999-9999-9999-9999-999999999911'::uuid)) ->> 'replayed') as rr_samereq_replayed \gset

select pg_temp.ok(
  :'rr_samereq_c1' = '1' and :'rr_samereq_replayed' = 'true',
  'أمان إعادة الطلب بنفس request_id ما يزال يعمل بلا استيرادٍ مضاعف بعد هذه الهجرة');

rollback;
