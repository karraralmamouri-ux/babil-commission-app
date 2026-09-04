-- شهرُ النتيجة صفةُ مصدرها (20261108090000)، وLoan-3 لا تؤهِّل بأيّ هجاء.
--
-- الانحدارات التي يحرسها هذا الملف:
--
--   • الشهر يُشتقّ من أحداث الدفعة، بتوقيت العمل لا بـUTC.
--   • الاقتران الخاطئ يُرفض: ملفُ تمّوز لا يُحسب على أنه آب.
--   • المصدر المختلط يُرفض: ملفٌ يحمل شهرَين ليس ملفَ شهر.
--   • الشهر غير القابل للبرهان يُرفض: حدثٌ بلا تاريخ يُسقط البرهان.
--   • الدفعة الفارغة ومصدرٌ ليس ACTIVATION_EVENTS يُرفضان كذلك.
--   • دفعةٌ تصير مختلطةً بعد الحساب لا تُعتمَد — يُعاد البرهان عند كل كتابة.
--   • Loan-3 وLONA 3: تُخزَّنان في الأحداث الخام، وصفراً في القسط، وصفراً
--     في تقدّم المرحلة — والسببُ المعروض «خدمة دَين» لا «باقة مجهولة».
--   • الأحداث المدفوعة المتعدّدة تبقى متتابعة P1→P2→P3→P4 ولو تخلّلها دَين.
--   • ولا شيء ممّا سبق يمسّ العمولات.
--
-- كل شيء داخل معاملةٍ تُلغى. معزول بنطاق تسمية mp-. لا قاعدة إنتاج.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.raises_like(p_sql text, p_needle text, p_label text)
returns text language plpgsql as $$
declare v_msg text;
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' (لم تُرفَض)';
exception when others then
  get stacked diagnostics v_msg = message_text;
  if pg_catalog.strpos(v_msg, p_needle) > 0 then
    return '   ok ' || p_label;
  end if;
  return 'FAILED: ' || p_label || ' (رُفضت بسببٍ آخر: ' || v_msg || ')';
end;
$$;

begin;

select '   == installation month provenance ==';

-- ===========================================================================
-- التهيئة
-- ===========================================================================

insert into auth.users (id, email) values
  ('fd000000-0000-0000-0000-0000000000a1', 'mp-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('fd000000-0000-0000-0000-0000000000a1', 'MP-AD', 'mp-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.agents (id, code, official_name) values
  ('fd000000-0000-0000-0000-0000000000a2', 'AGT-MP-P', 'وكيل البرهان الأب')
on conflict (code) do nothing;
insert into public.agents (id, code, official_name, parent_agent_id) values
  ('fd000000-0000-0000-0000-0000000000a3', 'AGT-MP-B1', 'فرع البرهان',
   'fd000000-0000-0000-0000-0000000000a2')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution) values
  ('fd000000-0000-0000-0000-0000000000a3', 'mp.print', 'mapped')
on conflict (alias_key) do nothing;

insert into public.packages (code, name, semantic_category) values
  ('MP-PKG', 'MP-PKG', 'PAID_PACKAGE')
on conflict (code) do nothing;

-- خمس دفعات، كلٌّ منها حالةُ برهانٍ واحدة.
insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values
  ('fd000000-0000-0000-0000-0000000000b1', 'ACTIVATION_EVENTS', 'mp-july.xlsx',
   'ck-mp-1', 'v1', 'fd000000-0000-0000-0000-0000000000a1', 'COMPLETE'),
  ('fd000000-0000-0000-0000-0000000000b2', 'ACTIVATION_EVENTS', 'mp-mixed.xlsx',
   'ck-mp-2', 'v1', 'fd000000-0000-0000-0000-0000000000a1', 'COMPLETE'),
  ('fd000000-0000-0000-0000-0000000000b3', 'ACTIVATION_EVENTS', 'mp-undated.xlsx',
   'ck-mp-3', 'v1', 'fd000000-0000-0000-0000-0000000000a1', 'COMPLETE'),
  ('fd000000-0000-0000-0000-0000000000b4', 'ACTIVATION_EVENTS', 'mp-empty.xlsx',
   'ck-mp-4', 'v1', 'fd000000-0000-0000-0000-0000000000a1', 'COMPLETE'),
  ('fd000000-0000-0000-0000-0000000000b5', 'USERS_SNAPSHOT', 'mp-users.xlsx',
   'ck-mp-5', 'v1', 'fd000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

-- ب١: ملفُ تمّوز النظيف. مشتركٌ عند P1 بأربعة أحداثٍ مدفوعة يتخلّلها دَين،
-- وحَدَّان زمنيّان يُثبتان أن الاشتقاق بتوقيت بغداد لا بـUTC:
-- 2026-07-01 00:30+03 هو تمّوز (وهو 30 حزيران بـUTC)،
-- و2026-07-31 23:30+03 هو تمّوز أيضاً (وهو 31 تمّوز 20:30 بـUTC).
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   fdt_code, event_created_at)
values
  ('fd000000-0000-0000-0000-0000000000b1','MP-A1','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-07-01 00:30+03'),
  ('fd000000-0000-0000-0000-0000000000b1','MP-A2','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-07-10 09:00+03'),
  -- خدمةُ دَينٍ في وسط السلّم: لا تستهلك مرحلةً ولا تُزحزح ترتيب ما بعدها.
  ('fd000000-0000-0000-0000-0000000000b1','MP-A3','mp-ladder','Loan-3',false,'mp.print','105', timestamptz '2026-07-12 09:00+03'),
  ('fd000000-0000-0000-0000-0000000000b1','MP-A4','mp-ladder','LONA 3',false,'mp.print','105', timestamptz '2026-07-13 09:00+03'),
  ('fd000000-0000-0000-0000-0000000000b1','MP-A5','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-07-20 09:00+03'),
  ('fd000000-0000-0000-0000-0000000000b1','MP-A6','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-07-31 23:30+03'),
  -- مشتركٌ لا يملك إلا دَيناً: لا سطرَ مالٍ له إطلاقاً.
  ('fd000000-0000-0000-0000-0000000000b1','MP-B1','mp-debt','Loan-3',false,'mp.print','105', timestamptz '2026-07-05 09:00+03'),
  ('fd000000-0000-0000-0000-0000000000b1','MP-B2','mp-debt','LONA 3',false,'mp.print','105', timestamptz '2026-07-06 09:00+03')
on conflict do nothing;

-- ب٢: شهران في ملفٍ واحد. الحدّ بتوقيت بغداد: 2026-08-01 00:30+03 هو آب.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   fdt_code, event_created_at)
values
  ('fd000000-0000-0000-0000-0000000000b2','MP-M1','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-07-31 23:30+03'),
  ('fd000000-0000-0000-0000-0000000000b2','MP-M2','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-08-01 00:30+03')
on conflict do nothing;

-- ب٣: حدثٌ واحدٌ بلا تاريخ يكفي لإسقاط البرهان، ولو كان الباقي كلّه تمّوز.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   fdt_code, event_created_at)
values
  ('fd000000-0000-0000-0000-0000000000b3','MP-U1','mp-ladder','MP-PKG',false,'mp.print','105', timestamptz '2026-07-08 09:00+03'),
  ('fd000000-0000-0000-0000-0000000000b3','MP-U2','mp-ladder','MP-PKG',false,'mp.print','105', null)
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values
  ('mp-ladder','MATCHED','EXACT_USERNAME','RESELLER','fd000000-0000-0000-0000-0000000000a3','105'),
  ('mp-debt',  'MATCHED','EXACT_USERNAME','RESELLER','fd000000-0000-0000-0000-0000000000a3','105')
on conflict do nothing;

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('fd000000-0000-0000-0000-0000000000c1','mp-ladder','وكيل البرهان الأب','105',date '2026-01-01',13000,'fd000000-0000-0000-0000-0000000000a1'),
  ('fd000000-0000-0000-0000-0000000000c2','mp-debt',  'وكيل البرهان الأب','105',date '2026-01-01',13000,'fd000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible)
values
  ('fd000000-0000-0000-0000-0000000000c1', date '2026-06-30', 13000, 0, 13000, 'P1', 'resolved', true),
  ('fd000000-0000-0000-0000-0000000000c2', date '2026-06-30', 13000, 0, 13000, 'P1', 'resolved', true)
on conflict (subscriber_uuid) do nothing;

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
select u, 'RESELLER', 'fd000000-0000-0000-0000-0000000000a3',
       timestamptz '2026-01-01 00:00+03', 'تثبيت', 'fd000000-0000-0000-0000-0000000000a1'
from unnest(array['mp-ladder','mp-debt']) u
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'fd000000-0000-0000-0000-0000000000a1';

create temporary table mp_before on commit drop as
select
  (select count(*) from public.installation_payments)            as payments,
  (select count(*) from public.installation_payment_history)     as payment_history,
  (select count(*) from public.financial_ledger)                 as ledger,
  (select count(*) from public.commission_rows)                  as commission_rows,
  (select count(*) from public.commission_event_entitlements)    as commission_entitlements;

-- ===========================================================================
-- ١ · الاشتقاق: الشهر صفةُ الملف، وبتوقيت العمل
-- ===========================================================================

select pg_temp.ok(
  (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b1') ->> 'status') = 'OK'
  and (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b1') ->> 'period') = '2026-07'
  and (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b1') ->> 'events')::int = 8,
  '١ · شهرُ الملف يُشتقّ من أحداثه: تمّوز، وحدّاه ببغداد داخله لا خارجه');

select pg_temp.ok(
  (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b2') ->> 'status')
    = 'MIXED_MONTH_SOURCE'
  and (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b2') ->> 'period') is null,
  '٢ · 23:30 تمّوز و00:30 آب ببغداد شهران — والاشتقاق يقولها ولا يخمّن');

select pg_temp.ok(
  (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b3') ->> 'status')
    = 'PERIOD_NOT_PROVABLE',
  '٣ · حدثٌ واحدٌ بلا تاريخ يُسقط البرهان ولو كان الباقي شهراً واحداً');

select pg_temp.ok(
  (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b4') ->> 'status') = 'NO_EVENTS'
  and (public.saas_batch_period('fd000000-0000-0000-0000-0000000000b5') ->> 'status')
    = 'NOT_ACTIVATION_EVENTS',
  '٤ · الدفعة الفارغة ومصدرٌ ليس أحداثَ تفعيل: لا شهرَ يُشتقّ من أيٍّ منهما');

-- ===========================================================================
-- ٢ · الإنفاذ: الحارس يرفض ما لا يُبرهَن
-- ===========================================================================

select pg_temp.raises_like($q$
  select public.preview_installation_calculation(
    '2026-08', 'fd000000-0000-0000-0000-0000000000b1',
    'fd000000-0000-0000-0000-00000000e001')$q$,
  'WRONG_MONTH_PAIRING',
  '٥ · ملفُ تمّوز محسوباً على أنه آب يُرفض — الاقتران الخاطئ لا يمرّ');

select pg_temp.raises_like($q$
  select public.preview_installation_calculation(
    '2026-07', 'fd000000-0000-0000-0000-0000000000b2',
    'fd000000-0000-0000-0000-00000000e002')$q$,
  'MIXED_MONTH_SOURCE',
  '٦ · المصدر المختلط يُرفض، ولا يُحسب على أحد شهرَيه');

select pg_temp.raises_like($q$
  select public.preview_installation_calculation(
    '2026-07', 'fd000000-0000-0000-0000-0000000000b3',
    'fd000000-0000-0000-0000-00000000e003')$q$,
  'PERIOD_NOT_PROVABLE',
  '٧ · الشهر غير القابل للبرهان يُرفض بدل أن يُخمَّن');

select pg_temp.raises_like($q$
  select public.preview_installation_calculation(
    '2026-07', 'fd000000-0000-0000-0000-0000000000b4',
    'fd000000-0000-0000-0000-00000000e004')$q$,
  'no activation event',
  '٨ · الدفعة الفارغة لا شهرَ لها، فلا تشغيلةَ لها');

select pg_temp.ok(
  not exists (select 1 from public.installation_calculation_runs
              where source_batch_id in (
                'fd000000-0000-0000-0000-0000000000b1',
                'fd000000-0000-0000-0000-0000000000b2',
                'fd000000-0000-0000-0000-0000000000b3',
                'fd000000-0000-0000-0000-0000000000b4')),
  '٩ · ولا تشغيلةَ واحدة بقيت من كل تلك المحاولات المرفوضة');

-- ===========================================================================
-- ٣ · الشهر الصحيح يمرّ، والدَّين لا يُنتج مالاً ولا يُقدّم مرحلة
-- ===========================================================================

select public.preview_installation_calculation(
  '2026-07', 'fd000000-0000-0000-0000-0000000000b1',
  'fd000000-0000-0000-0000-00000000e010');

create temporary table mp_run on commit drop as
select id from public.installation_calculation_runs
where period = '2026-07' and source_batch_id = 'fd000000-0000-0000-0000-0000000000b1';

select pg_temp.ok(
  (select count(*) from mp_run) = 1,
  '١٠ · الشهر المبرهَن يُحسب، وتشغيلةٌ واحدة له');

-- Loan-3 وLONA 3 مخزَّنتان في الأحداث الخام: الاستيراد يحفظ ما ورد.
select pg_temp.ok(
  (select count(*) from public.saas_activation_events
   where import_batch_id = 'fd000000-0000-0000-0000-0000000000b1'
     and profile_name in ('Loan-3', 'LONA 3')) = 4,
  '١١ · Loan-3 وLONA 3 محفوظتان في الأحداث الخام كما وردتا — لا تُسقَط');

select pg_temp.ok(
  (select coalesce(sum(l.amount), 0) from public.installation_calculation_lines l
   where l.run_id = (select id from mp_run)
     and l.activation_event_id in ('MP-A3', 'MP-A4', 'MP-B1', 'MP-B2')) = 0
  and not exists (
    select 1 from public.installation_calculation_lines l
    where l.run_id = (select id from mp_run)
      and l.activation_event_id in ('MP-A3', 'MP-A4', 'MP-B1', 'MP-B2')
      and l.awarded_stage is not null),
  '١٢ · خدمةُ الدَّين: صفرٌ في القسط وصفرٌ في المرحلة، بكلا الهجاءين');

select pg_temp.ok(
  (select bool_and(l.reason_code like '%DEBT_SERVICE_NEVER_QUALIFIES%')
   from public.installation_calculation_lines l
   where l.run_id = (select id from mp_run)
     and l.activation_event_id in ('MP-A3', 'MP-A4', 'MP-B1', 'MP-B2')),
  '١٣ · والسببُ «خدمة دَين» في الهجاءين معاً — لا «باقة مجهولة» عن معلومة');

select pg_temp.ok(
  (select count(*) from public.installation_calculation_lines l
   where l.run_id = (select id from mp_run) and l.subscriber_key = 'mp-debt'
     and l.outcome = 'AWARDED') = 0
  and (select opening_stage = closing_stage
       from public.installation_calculation_lines l
       where l.run_id = (select id from mp_run) and l.subscriber_key = 'mp-debt'
       order by l.sequence_in_subscriber desc limit 1),
  '١٤ · من لا يملك إلا دَيناً: لا قسطَ له، ومرحلتُه تُغلق كما فُتحت');

-- ===========================================================================
-- ٤ · والأحداث المدفوعة تبقى متتابعة، والدَّين بينها لا يكسر التتابع
-- ===========================================================================

select pg_temp.ok(
  (select string_agg(l.awarded_stage, '→' order by l.sequence_in_subscriber)
   from public.installation_calculation_lines l
   where l.run_id = (select id from mp_run) and l.subscriber_key = 'mp-ladder'
     and l.outcome = 'AWARDED') = 'P1→P2→P3→P4',
  '١٥ · أربعةُ أحداثٍ مدفوعة ⇒ P1→P2→P3→P4 بالترتيب، والدَّين بينها لا يزحزحها');

select pg_temp.ok(
  (select coalesce(sum(l.amount), 0) from public.installation_calculation_lines l
   where l.run_id = (select id from mp_run) and l.subscriber_key = 'mp-ladder') = 13000
  and (select l.closing_stage from public.installation_calculation_lines l
       where l.run_id = (select id from mp_run) and l.subscriber_key = 'mp-ladder'
       order by l.sequence_in_subscriber desc limit 1) = 'DONE',
  '١٦ · ومجموعُه 13,000 وإغلاقُه DONE — ولا تجاوزَ بعده');

-- ===========================================================================
-- ٥ · الدفعة تصير مختلطةً بعد الحساب ⇒ لا تُعتمَد
-- ===========================================================================

reset role;
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   fdt_code, event_created_at)
values
  ('fd000000-0000-0000-0000-0000000000b1','MP-LATE','mp-ladder','MP-PKG',false,'mp.print','105',
   timestamptz '2026-08-02 09:00+03');
set local role authenticated;
set local request.jwt.claim.sub = 'fd000000-0000-0000-0000-0000000000a1';

select pg_temp.raises_like(
  'select public.approve_installation_calculation((select id from mp_run),'
  || ' ''fd000000-0000-0000-0000-00000000e020'')',
  'MIXED_MONTH_SOURCE',
  '١٧ · دفعةٌ نمت فصارت شهرَين لا يُعتمَد شهرُها — البرهان يُعاد عند كل كتابة');

select pg_temp.ok(
  (select status from public.installation_calculation_runs
   where id = (select id from mp_run)) <> 'APPROVED',
  '١٨ · والتشغيلة بقيت غير معتمَدة، لا نصفَ معتمَدة');

-- ===========================================================================
-- ٦ · ولا شيء ممّا سبق مسّ مالاً قائماً ولا عمولةً
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.installation_payments)         = (select payments from mp_before)
  and (select count(*) from public.installation_payment_history) = (select payment_history from mp_before)
  and (select count(*) from public.financial_ledger)             = (select ledger from mp_before),
  '١٩ · لا صفَّ دفعٍ ولا تاريخَ دفعٍ ولا قيدَ دفترٍ أنشأه أيٌّ من هذا');

select pg_temp.ok(
  (select count(*) from public.commission_rows) = (select commission_rows from mp_before)
  and (select count(*) from public.commission_event_entitlements)
      = (select commission_entitlements from mp_before),
  '٢٠ · والعمولات لم تُمَسّ: لا صفَّ ولا استحقاقَ تغيّر');

-- تسجيلُ هجاءٍ لخدمة الدَّين يُشدِّد ولا يُرخي: إسنادُ سعرٍ مؤهِّلٍ له مستحيل.
reset role;
select pg_temp.raises_like($q$
  insert into public.commission_package_rates (tier_definition_id, package_code, amount, qualifies)
  select t.id, 'LONA 3', 1000, true from public.commission_tier_definitions t limit 1$q$,
  'debt service',
  '٢١ · و«LONA 3» صارت خدمةَ دَين، فلا يُسنَد لها سعرٌ مؤهِّلٌ أبداً');

rollback;
