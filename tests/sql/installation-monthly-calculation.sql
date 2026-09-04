-- الحساب الشهري لأجور التنصيب: أقساطٌ متتابعة، وحسابٌ ليس دفعاً (ADR-034).
--
-- الانحدارات التي يحرسها هذا الملف، وكلّها قواعدُ مالٍ لا تفاصيلَ تنفيذ:
--
--   • المشترك القائم يبدأ من مرحلته الملتزَمة، لا من P1. ولو تغيّر الـPrint.
--   • كل حدثٍ صالحٍ يستهلك القسط التالي وحده. حدثان ⇒ قسطان، لا «تعارض».
--   • لا يُمنَح قسطٌ مرّتين، ولا يُتجاوَز DONE، ولو توالت الأحداث.
--   • المعاينة لا تلمس حالة مشتركٍ واحد. الاعتماد وحده يُقدّم المرحلة.
--   • ولا الاثنان يُنشئان دفعةً ولا قيداً ولا صفَّ دفعٍ تاريخياً.
--   • اسمُ Print غير محسوم يوقف اعتماد الشهر كلّه، ولا يُخمَّن مالكه.
--   • تجميع الفرع وتجميع الأب يتطابقان — من نفس الأسطر لا من حسابَين.
--
-- كل شيء داخل معاملةٍ تُلغى. معزول بنطاق تسمية mc-. لا قاعدة إنتاج.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.raises(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' (لم تُرفَض)';
exception when others then
  return '   ok ' || p_label;
end;
$$;

begin;

select '   == installation monthly calculation ==';

-- ===========================================================================
-- التهيئة
-- ===========================================================================

insert into auth.users (id, email) values
  ('fc000000-0000-0000-0000-0000000000a1', 'mc-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('fc000000-0000-0000-0000-0000000000a1', 'MC-AD', 'mc-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

-- الهرمية: أبٌ واحد وفرعان تحته. الأسماء بيانات، والمعرّفات هي الهوية.
insert into public.agents (id, code, official_name) values
  ('fc000000-0000-0000-0000-0000000000a2', 'AGT-MC-P', 'الوكيل الأب')
on conflict (code) do nothing;
insert into public.agents (id, code, official_name, parent_agent_id) values
  ('fc000000-0000-0000-0000-0000000000a3', 'AGT-MC-B1', 'فرع أول',
   'fc000000-0000-0000-0000-0000000000a2'),
  ('fc000000-0000-0000-0000-0000000000a4', 'AGT-MC-B2', 'فرع ثانٍ',
   'fc000000-0000-0000-0000-0000000000a2')
on conflict (code) do nothing;

-- كنيتان لفرعٍ واحد: الاسمان مختلفان والمعرّف واحد.
insert into public.agent_aliases (agent_id, alias, resolution) values
  ('fc000000-0000-0000-0000-0000000000a3', 'mc.print.a',     'mapped'),
  ('fc000000-0000-0000-0000-0000000000a3', 'mc.print.a.alt', 'mapped'),
  ('fc000000-0000-0000-0000-0000000000a4', 'mc.print.b',     'mapped')
on conflict (alias_key) do nothing;

insert into public.packages (code, name, semantic_category) values
  ('MC-PKG', 'MC-PKG', 'PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values
  ('fc000000-0000-0000-0000-0000000000b1', 'ACTIVATION_EVENTS', 'mc-july.xlsx',
   'ck-mc-1', 'v1', 'fc000000-0000-0000-0000-0000000000a1', 'COMPLETE'),
  ('fc000000-0000-0000-0000-0000000000b2', 'ACTIVATION_EVENTS', 'mc-aug.xlsx',
   'ck-mc-2', 'v1', 'fc000000-0000-0000-0000-0000000000a1', 'COMPLETE'),
  -- ملفُ شهرٍ سابق. لا يُحسَب هنا، لكنه يُبقي تاريخ الإسناد القديم قائماً
  -- لمن انقضت مهلته: الملفّ الشهري لا يحمل شهرَين (20261108090000)، فلا
  -- يجوز أن يسكن حدثُ كانون في ملف تمّوز.
  ('fc000000-0000-0000-0000-0000000000b3', 'ACTIVATION_EVENTS', 'mc-jan.xlsx',
   'ck-mc-3', 'v1', 'fc000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

-- الملف الشهري الواحد: هو نفسه مصدر العمولات ومصدر أجور التنصيب.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   fdt_code, event_created_at)
values
  -- (أ) قائمٌ عند P3 وحدثٌ واحد
  ('fc000000-0000-0000-0000-0000000000b1','MC-A1','mc-p3-one','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-03 09:00+03'),
  -- (ب) قائمٌ عند P3 وحدثان
  ('fc000000-0000-0000-0000-0000000000b1','MC-B1','mc-p3-two','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-04 09:00+03'),
  ('fc000000-0000-0000-0000-0000000000b1','MC-B2','mc-p3-two','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-18 09:00+03'),
  -- (ج) قائمٌ عند P1 وأربعة أحداث
  ('fc000000-0000-0000-0000-0000000000b1','MC-C1','mc-p1-four','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-05 09:00+03'),
  ('fc000000-0000-0000-0000-0000000000b1','MC-C2','mc-p1-four','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-11 09:00+03'),
  ('fc000000-0000-0000-0000-0000000000b1','MC-C3','mc-p1-four','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-19 09:00+03'),
  ('fc000000-0000-0000-0000-0000000000b1','MC-C4','mc-p1-four','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-25 09:00+03'),
  -- (د) قائمٌ عند P4 وحدثان — القسط الأخير مرّةً واحدة
  ('fc000000-0000-0000-0000-0000000000b1','MC-D1','mc-p4-two','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-06 09:00+03'),
  ('fc000000-0000-0000-0000-0000000000b1','MC-D2','mc-p4-two','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-20 09:00+03'),
  -- (هـ) منتهٍ عند DONE
  ('fc000000-0000-0000-0000-0000000000b1','MC-E1','mc-done','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-07 09:00+03'),
  -- (و) قائمٌ انتقل إلى فرعٍ آخر
  ('fc000000-0000-0000-0000-0000000000b1','MC-F1','mc-moved','MC-PKG',false,'mc.print.b','105', timestamptz '2026-07-08 09:00+03'),
  -- (ز) جديدٌ مؤهَّل
  ('fc000000-0000-0000-0000-0000000000b1','MC-G1','mc-new','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-09 09:00+03'),
  -- (ح) جديدٌ تحت المراجعة
  ('fc000000-0000-0000-0000-0000000000b1','MC-H1','mc-review','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-10 09:00+03'),
  -- (ط) قائمٌ معلَّق
  ('fc000000-0000-0000-0000-0000000000b1','MC-I1','mc-held','MC-PKG',false,'mc.print.a','105', timestamptz '2026-07-12 09:00+03'),
  -- (ط٢) لا تفعيلَ مؤهِّلاً قط، وحدثه القديم ملغى ⇒ مهلةٌ منقضية.
  -- إسنادُه القديم في ملف كانون، وحدثُ تمّوز الملغى هو ما يُظهره في نتيجة
  -- الشهر — فيبقى السيناريو كما هو بلا ملفٍّ يحمل شهرَين.
  ('fc000000-0000-0000-0000-0000000000b3','MC-I2','mc-lapsed','MC-PKG',true,'mc.print.a','105', timestamptz '2026-01-02 09:00+03'),
  ('fc000000-0000-0000-0000-0000000000b1','MC-I3','mc-lapsed','MC-PKG',true,'mc.print.a','105', timestamptz '2026-07-14 09:00+03'),
  -- (ك) الكنية الثانية لنفس الفرع
  ('fc000000-0000-0000-0000-0000000000b1','MC-K1','mc-alias','MC-PKG',false,'mc.print.a.alt','105', timestamptz '2026-07-13 09:00+03'),
  -- (ي) اسمُ Print غير محسوم — في ملفٍ منفصل كي لا يوقف بقيّة الاختبار
  ('fc000000-0000-0000-0000-0000000000b2','MC-J1','mc-unknown','MC-PKG',false,'mc.print.ghost','105', timestamptz '2026-08-03 09:00+03')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values
  ('mc-p3-one', 'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-p3-two', 'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-p1-four','MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-p4-two', 'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-done',   'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-moved',  'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a4','105'),
  ('mc-new',    'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-review', 'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-held',   'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-lapsed', 'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-alias',  'MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105'),
  ('mc-unknown','MATCHED','EXACT_USERNAME','RESELLER','fc000000-0000-0000-0000-0000000000a3','105')
on conflict do nothing;

insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values
  ('mc-new',     'NEW',          'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE'),
  ('mc-review',  'NEEDS_REVIEW', 'PARTIAL_SOURCE',                     'PARTIAL'),
  ('mc-lapsed',  'NEW',          'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE'),
  ('mc-unknown', 'NEW',          'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE')
on conflict do nothing;

-- الأساس التاريخي: هو وحده السلطة الافتتاحية التي تحمل «المتبقي».
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('fc000000-0000-0000-0000-0000000000c1','mc-p3-one', 'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c2','mc-p3-two', 'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c3','mc-p1-four','الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c4','mc-p4-two', 'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c5','mc-done',   'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c6','mc-moved',  'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c7','mc-held',   'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1'),
  ('fc000000-0000-0000-0000-0000000000c8','mc-alias',  'الوكيل الأب','105',date '2026-01-01',13000,'fc000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible)
values
  ('fc000000-0000-0000-0000-0000000000c1', date '2026-06-30',  7000,  6000, 13000, 'P3',  'resolved', true),
  ('fc000000-0000-0000-0000-0000000000c2', date '2026-06-30',  7000,  6000, 13000, 'P3',  'resolved', true),
  ('fc000000-0000-0000-0000-0000000000c3', date '2026-06-30', 13000,     0, 13000, 'P1',  'resolved', true),
  ('fc000000-0000-0000-0000-0000000000c4', date '2026-06-30',  4000,  9000, 13000, 'P4',  'resolved', true),
  ('fc000000-0000-0000-0000-0000000000c5', date '2026-06-30',     0, 13000, 13000, 'DONE','resolved', false),
  ('fc000000-0000-0000-0000-0000000000c6', date '2026-06-30',  7000,  6000, 13000, 'P3',  'resolved', true),
  ('fc000000-0000-0000-0000-0000000000c7', date '2026-06-30', 13000,     0, 13000, 'P1',  'resolved', true),
  ('fc000000-0000-0000-0000-0000000000c8', date '2026-06-30',  7000,  6000, 13000, 'P3',  'resolved', true)
on conflict (subscriber_uuid) do nothing;

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
select u, 'RESELLER', 'fc000000-0000-0000-0000-0000000000a3',
       timestamptz '2026-01-01 00:00+03', 'تثبيت', 'fc000000-0000-0000-0000-0000000000a1'
from unnest(array['mc-p3-one','mc-p3-two','mc-p1-four','mc-p4-two','mc-done','mc-new',
                  'mc-review','mc-held','mc-lapsed','mc-alias','mc-unknown']) u
on conflict do nothing;
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values ('mc-moved','RESELLER','fc000000-0000-0000-0000-0000000000a4',
        timestamptz '2026-01-01 00:00+03','تثبيت','fc000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- تعليقٌ فعّال على مشتركٍ قائم: لا مال بالصمت.
insert into public.installation_holds (subscriber_id, reason_code, hold_type, status)
values ('mc-held', 'FINANCIAL_MISMATCH', 'MANUAL', 'ACTIVE')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'fc000000-0000-0000-0000-0000000000a1';

-- لقطةُ ما قبل الحساب: تُقارَن بها كل دعاوى «لم يتغيّر شيء».
create temporary table mc_before on commit drop as
select
  (select count(*) from public.installation_payments)             as payments,
  (select count(*) from public.installation_payment_history)      as payment_history,
  (select count(*) from public.installation_payment_batches)      as payment_batches,
  (select count(*) from public.installation_payment_batch_items)  as payment_batch_items,
  (select count(*) from public.installation_batches)              as batches,
  (select count(*) from public.installation_entitlements)         as entitlements,
  (select count(*) from public.financial_ledger)                  as ledger,
  (select count(*) from public.commission_rows)                   as commission_rows,
  (select count(*) from public.commission_event_entitlements)     as commission_entitlements,
  (select count(*) from public.commission_cycles)                 as commission_cycles,
  (select md5(coalesce(string_agg(e.saas_event_id || ':' || e.username_key ||
                                  ':' || coalesce(e.raw_parent, ''), '|' order by e.saas_event_id), ''))
   from public.saas_activation_events e
   where e.import_batch_id = 'fc000000-0000-0000-0000-0000000000b1')  as source_digest,
  (select md5(coalesce(string_agg(s.subscriber_id || ':' || coalesce(st.current_stage, '-') ||
                                  ':' || coalesce(st.remaining::text, '-'), '|' order by s.subscriber_id), ''))
   from public.installation_subscribers s
   join public.installation_subscriber_state st on st.subscriber_uuid = s.id
   where s.subscriber_id like 'mc-%')                                 as state_digest;

-- ===========================================================================
-- ١ · المعاينة تحسب ولا تُغيّر شيئاً (اختبار P)
-- ===========================================================================

select public.preview_installation_calculation(
  '2026-07', 'fc000000-0000-0000-0000-0000000000b1',
  'fc000000-0000-0000-0000-00000000f001');

create temporary table mc_run on commit drop as
select id from public.installation_calculation_runs
where period = '2026-07' and source_batch_id = 'fc000000-0000-0000-0000-0000000000b1';

select pg_temp.ok(
  (select md5(coalesce(string_agg(s.subscriber_id || ':' || coalesce(st.current_stage, '-') ||
                                  ':' || coalesce(st.remaining::text, '-'), '|' order by s.subscriber_id), ''))
   from public.installation_subscribers s
   join public.installation_subscriber_state st on st.subscriber_uuid = s.id
   where s.subscriber_id like 'mc-%')
  = (select state_digest from mc_before),
  'P · المعاينة لا تُغيّر مرحلةَ مشتركٍ واحد ولا متبقّيه');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = (select payments from mc_before)
  and (select count(*) from public.installation_payment_history) = (select payment_history from mc_before)
  and (select count(*) from public.installation_payment_batches) = (select payment_batches from mc_before)
  and (select count(*) from public.installation_payment_batch_items) = (select payment_batch_items from mc_before)
  and (select count(*) from public.installation_batches) = (select batches from mc_before)
  and (select count(*) from public.installation_entitlements) = (select entitlements from mc_before)
  and (select count(*) from public.financial_ledger) = (select ledger from mc_before),
  'R · ولا تُنشئ دفعةً ولا دفعةَ سدادٍ ولا استحقاقاً ولا قيدَ دفتر');

-- ===========================================================================
-- ٢ · التسلسل: كل حدثٍ صالحٍ يستهلك القسط التالي وحده
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-p3-one'
     and outcome = 'AWARDED' and awarded_stage = 'P3' and amount = 3000
     and opening_stage = 'P3' and closing_stage = 'P4') = 1
  and (select count(*) from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p3-one') = 1,
  'A · قائمٌ عند P3 وحدثٌ واحد ⇒ P3 وحدها بـ3000، ويُغلق عند P4');

select pg_temp.ok(
  (select string_agg(awarded_stage, ',' order by sequence_in_subscriber)
   from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-p3-two'
     and outcome = 'AWARDED') = 'P3,P4'
  and (select sum(amount) from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p3-two') = 7000
  and (select closing_stage from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p3-two'
       order by sequence_in_subscriber desc limit 1) = 'DONE',
  'B · قائمٌ عند P3 وحدثان ⇒ P3 ثم P4 = 7000، وينتهي عند DONE — لا «تعارض»');

select pg_temp.ok(
  (select string_agg(awarded_stage, ',' order by sequence_in_subscriber)
   from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-p1-four'
     and outcome = 'AWARDED') = 'P1,P2,P3,P4'
  and (select sum(amount) from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p1-four') = 13000
  and (select closing_stage from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p1-four'
       order by sequence_in_subscriber desc limit 1) = 'DONE',
  'C · قائمٌ عند P1 وأربعة أحداث ⇒ السلّم كاملاً 13000 وينتهي عند DONE');

select pg_temp.ok(
  (select count(*) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-p4-two'
     and outcome = 'AWARDED' and awarded_stage = 'P4' and amount = 4000) = 1
  and (select count(*) from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p4-two'
         and outcome = 'NO_STAGE_REMAINING' and amount = 0) = 1
  and (select sum(amount) from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-p4-two') = 4000,
  'D · قائمٌ عند P4 وحدثان ⇒ P4 مرّةً واحدة، والحدث الثاني لا يُنشئ مالاً');

select pg_temp.ok(
  (select coalesce(sum(amount), 0) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-done') = 0
  and (select count(*) from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-done'
         and outcome = 'NO_STAGE_REMAINING') = 1,
  'E · منتهٍ عند DONE ⇒ صفر، ولا يُتجاوَز السلّم');

-- ===========================================================================
-- ٣ · الهوية: المرحلة للمشترك، والـPrint للحدث
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-moved'
     and outcome = 'AWARDED' and opening_stage = 'P3' and awarded_stage = 'P3'
     and agent_id_at_calculation = 'fc000000-0000-0000-0000-0000000000a4') = 1
  and (select reseller from public.installation_subscribers
       where subscriber_id = 'mc-moved') = 'الوكيل الأب',
  'F · تغيّرُ الـPrint لا يُعيد المشترك إلى P1، والعائدية التاريخية تبقى كما هي');

select pg_temp.ok(
  (select agent_id_at_calculation from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-alias')
  = 'fc000000-0000-0000-0000-0000000000a3'
  and (select parent_agent_id_at_calculation from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-alias')
  = 'fc000000-0000-0000-0000-0000000000a2',
  'K · الكنيةُ الثانية تُفضي إلى معرّف الفرع نفسه، وأبوه فوقه');

-- ===========================================================================
-- ٤ · الجديد المؤهَّل، ومن لا يُمنَح صامتاً
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-new'
     and outcome = 'AWARDED' and awarded_stage = 'P1' and amount = 3000
     and registry_hit = false) = 1,
  'G · جديدٌ مؤهَّلٌ فعلاً يدخل عند P1 حسب المخطّط النافذ');

select pg_temp.ok(
  (select coalesce(sum(amount), 0) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key = 'mc-review') = 0
  and (select outcome from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-review') = 'BLOCKED'
  and (select reason_code from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-review')
      like '%CLASSIFICATION_NEEDS_REVIEW%',
  'H · جديدٌ تحت المراجعة لا يُولّد مالاً، ويحمل سببه صريحاً');

select pg_temp.ok(
  (select coalesce(sum(amount), 0) from public.installation_calculation_lines
   where run_id = (select id from mc_run) and subscriber_key in ('mc-held', 'mc-lapsed')) = 0
  and (select reason_code from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-held')
      like '%SUBSCRIBER_ON_HOLD%'
  and (select reason_code from public.installation_calculation_lines
       where run_id = (select id from mc_run) and subscriber_key = 'mc-lapsed')
      like '%GRACE_EXPIRED_REVIEW%',
  'I · المعلَّق ومنقضي المهلة: صفرٌ لكلٍّ منهما، وسببٌ صريحٌ لكلٍّ منهما');

select pg_temp.ok(
  not exists (select 1 from public.installation_calculation_lines
              where run_id = (select id from mc_run)
                and outcome <> 'AWARDED'
                and btrim(coalesce(reason_code, '')) = ''),
  '  · ولا سطرَ مستبعَدٍ بلا سببٍ مقروء');

-- ===========================================================================
-- ٥ · الحدث يُحسَب مرّةً واحدة (اختبار M)
-- ===========================================================================

select pg_temp.raises(
  $q$insert into public.saas_activation_events
       (import_batch_id, saas_event_id, username, profile_name, canceled)
     values ('fc000000-0000-0000-0000-0000000000b1','MC-A1','mc-p3-one','MC-PKG',false)$q$,
  'M · معرّف الحدث فريدٌ في المصدر — لا يدخل مرّتين أصلاً');

select pg_temp.ok(
  (select count(*) from public.installation_calculation_lines
   where run_id = (select id from mc_run))
  = (select count(distinct saas_event_id) from public.saas_activation_events
     where import_batch_id = 'fc000000-0000-0000-0000-0000000000b1'),
  '  · وسطرٌ واحدٌ لكل حدث، لا أكثر');

-- ===========================================================================
-- ٦ · تجميع الفرع وتجميع الأب يتطابقان (اختبار L)
-- ===========================================================================

select pg_temp.ok(
  (select sum((p ->> 'amount')::bigint)
   from jsonb_array_elements(
     public.installation_calculation_run_summary((select id from mc_run)) -> 'by_print') p)
  = (select total_amount from public.installation_calculation_runs
     where id = (select id from mc_run))
  and (select sum((p ->> 'amount')::bigint)
       from jsonb_array_elements(
         public.installation_calculation_run_summary((select id from mc_run)) -> 'by_parent') p)
  = (select total_amount from public.installation_calculation_runs
     where id = (select id from mc_run)),
  'L · مجموع الفروع ومجموع الآباء يساويان نتيجة الشهر — كلاهما من نفس الأسطر');

select pg_temp.ok(
  (select (p ->> 'amount')::bigint
   from jsonb_array_elements(
     public.installation_calculation_run_summary((select id from mc_run)) -> 'by_parent') p
   where (p ->> 'parent_agent_id') = 'fc000000-0000-0000-0000-0000000000a2')
  = (select sum(amount) from public.installation_calculation_lines
     where run_id = (select id from mc_run) and outcome = 'AWARDED'
       and parent_agent_id_at_calculation = 'fc000000-0000-0000-0000-0000000000a2'),
  '  · والأب يجمع فرعيه بالضبط، لا بالتقريب');

-- ===========================================================================
-- ٧ · إعادة الحساب على المصدر نفسه لا تُضاعف شيئاً (اختبار N)
-- ===========================================================================

create temporary table mc_first on commit drop as
select awarded_count, total_amount, subscribers_count, events_count
from public.installation_calculation_runs where id = (select id from mc_run);

select public.preview_installation_calculation(
  '2026-07', 'fc000000-0000-0000-0000-0000000000b1',
  'fc000000-0000-0000-0000-00000000f002');

select pg_temp.ok(
  (select count(*) from public.installation_calculation_runs
   where period = '2026-07' and source_batch_id = 'fc000000-0000-0000-0000-0000000000b1') = 1
  and (select awarded_count from public.installation_calculation_runs
       where id = (select id from mc_run)) = (select awarded_count from mc_first)
  and (select total_amount from public.installation_calculation_runs
       where id = (select id from mc_run)) = (select total_amount from mc_first),
  'N · إعادة حساب المصدر نفسه تُعيد النتيجة ذاتها في التشغيلة ذاتها');

-- ===========================================================================
-- ٨ · الاعتماد: يُقدّم المرحلة مرّةً واحدة، ولا يدفع (اختبارات Q · O · R)
-- ===========================================================================

select public.approve_installation_calculation(
  (select id from mc_run), 'fc000000-0000-0000-0000-00000000f003');

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'mc-p3-one') = 'P4'
  and (select st.remaining from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'mc-p3-one') = 4000
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'mc-p3-two') = 'DONE'
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'mc-p1-four') = 'DONE',
  'Q · الاعتماد يُثبّت مرحلة كل مشترك للشهر القادم، مرّةً واحدة');

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'mc-held') = 'P1'
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'mc-done') = 'DONE',
  '  · ومن لم يُمنَح لم تتحرّك مرحلته قيدَ أنملة');

select pg_temp.ok(
  (select count(*) from public.installation_calculation_awards
   where subscriber_key = 'mc-p1-four') = 4
  and (select sum(amount) from public.installation_calculation_awards
       where subscriber_key like 'mc-%')
      = (select total_amount from public.installation_calculation_runs
         where id = (select id from mc_run)),
  '  · وسجلّ المُعتمَد يطابق نتيجة الشهر قسطاً بقسط');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = (select payments from mc_before)
  and (select count(*) from public.installation_payment_history) = (select payment_history from mc_before)
  and (select count(*) from public.installation_payment_batches) = (select payment_batches from mc_before)
  and (select count(*) from public.installation_payment_batch_items) = (select payment_batch_items from mc_before)
  and (select count(*) from public.installation_batches) = (select batches from mc_before)
  and (select count(*) from public.installation_entitlements) = (select entitlements from mc_before)
  and (select count(*) from public.financial_ledger) = (select ledger from mc_before),
  'R · والاعتماد نفسه لا يدفع: لا دفعة ولا صفَّ دفعٍ تاريخيّ ولا قيدَ دفتر');

select pg_temp.ok(
  ((select public.approve_installation_calculation(
      (select id from mc_run), 'fc000000-0000-0000-0000-00000000f004')) ->> 'replayed')::boolean
  and (select count(*) from public.installation_calculation_awards
       where subscriber_key = 'mc-p1-four') = 4,
  'O · اعتمادٌ ثانٍ للتشغيلة نفسها لا يفعل شيئاً ولا يفشل');

select pg_temp.raises(
  $q$select public.preview_installation_calculation(
       '2026-07', 'fc000000-0000-0000-0000-0000000000b1',
       'fc000000-0000-0000-0000-00000000f005')$q$,
  '  · ولا يُعاد حساب شهرٍ اعتُمِد');

select pg_temp.raises(
  $q$update public.installation_calculation_lines set amount = 999
     where run_id = (select id from public.installation_calculation_runs
                     where period = '2026-07'
                       and source_batch_id = 'fc000000-0000-0000-0000-0000000000b1')$q$,
  '  · ودليل الشهر المعتمَد لا يُعدَّل بعدها');

-- ===========================================================================
-- ٩ · العمولات لم تُمَسّ (اختبار S)
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.commission_rows) = (select commission_rows from mc_before)
  and (select count(*) from public.commission_event_entitlements) = (select commission_entitlements from mc_before)
  and (select count(*) from public.commission_cycles) = (select commission_cycles from mc_before)
  and (select md5(coalesce(string_agg(e.saas_event_id || ':' || e.username_key ||
                                      ':' || coalesce(e.raw_parent, ''), '|' order by e.saas_event_id), ''))
       from public.saas_activation_events e
       where e.import_batch_id = 'fc000000-0000-0000-0000-0000000000b1')
      = (select source_digest from mc_before),
  'S · حساب التنصيب واعتمادُه لا يمسّان العمولات ولا يغيّران المصدر المشترك');

-- ===========================================================================
-- ١٠ · اسمُ Print غير محسوم يوقف اعتماد الشهر (اختبار J)
-- ===========================================================================

select public.preview_installation_calculation(
  '2026-08', 'fc000000-0000-0000-0000-0000000000b2',
  'fc000000-0000-0000-0000-00000000f006');

select pg_temp.ok(
  (select status from public.installation_calculation_runs
   where period = '2026-08' and source_batch_id = 'fc000000-0000-0000-0000-0000000000b2')
  = 'NEEDS_REVIEW'
  and (select unresolved_print_count from public.installation_calculation_runs
       where period = '2026-08' and source_batch_id = 'fc000000-0000-0000-0000-0000000000b2') > 0
  and (select coalesce(sum(amount), 0) from public.installation_calculation_lines l
       join public.installation_calculation_runs r on r.id = l.run_id
       where r.period = '2026-08') = 0,
  'J · اسمُ Print غير معروف ⇒ الشهر تحت المراجعة، ولا مالَ لصفوفه');

select pg_temp.raises(
  $q$select public.approve_installation_calculation(
       (select id from public.installation_calculation_runs
        where period = '2026-08'
          and source_batch_id = 'fc000000-0000-0000-0000-0000000000b2'),
       'fc000000-0000-0000-0000-00000000f007')$q$,
  '  · والاعتماد مرفوضٌ حتى يُحسَم الاسم — لا تخمينَ مالكٍ صامتاً');

-- ===========================================================================
-- ١١ · حسمُ الاسم يفتح الطريق، بقرارٍ مسجَّل لا بمطابقةٍ تقريبية
-- ===========================================================================

select public.resolve_print_name(
  'mc.print.ghost', 'NEW_BRANCH', null, 'AGT-MC-B3', 'فرع ثالث',
  'fc000000-0000-0000-0000-0000000000a2', 'حُسم بقرار الإدارة',
  'fc000000-0000-0000-0000-00000000f008');

select public.preview_installation_calculation(
  '2026-08', 'fc000000-0000-0000-0000-0000000000b2',
  'fc000000-0000-0000-0000-00000000f009');

select pg_temp.ok(
  (select status from public.installation_calculation_runs
   where period = '2026-08' and source_batch_id = 'fc000000-0000-0000-0000-0000000000b2')
  = 'READY_TO_APPROVE'
  and (select parent_agent_id_at_calculation from public.installation_calculation_lines l
       join public.installation_calculation_runs r on r.id = l.run_id
       where r.period = '2026-08' and l.subscriber_key = 'mc-unknown')
      = 'fc000000-0000-0000-0000-0000000000a2',
  '  · وبعد الحسم يصير الشهر قابلاً للاعتماد، والفرع الجديد تحت أبيه');

-- ===========================================================================
-- ١٢ · حارس الهرمية: مستويان لا ثالث لهما، والدورةُ مستحيلةٌ بنيةً
--
-- «أبٌ ← فرع» عمقٌ مقصود لا نقص. فتجميعُ الأب يبقى GROUP BY واحداً بلا
-- تعاودٍ، ولا يُتصوَّر أن يبتلع فرعٌ أباه.
-- ===========================================================================

reset role;

select pg_temp.raises(
  $q$update public.agents set parent_agent_id = id where code = 'AGT-MC-B1'$q$,
  '  · ولا يكون الوكيل أبَ نفسه');

select pg_temp.raises(
  $q$update public.agents
     set parent_agent_id = 'fc000000-0000-0000-0000-0000000000a3'
     where code = 'AGT-MC-B2'$q$,
  '  · ولا فرعَ تحت فرع');

select pg_temp.raises(
  $q$update public.agents
     set parent_agent_id = 'fc000000-0000-0000-0000-0000000000a3'
     where code = 'AGT-MC-P'$q$,
  '  · ولا يصير أبٌ له فروعٌ فرعاً لأحدها');

select pg_temp.ok(
  public.agent_root_id('fc000000-0000-0000-0000-0000000000a3')
    = 'fc000000-0000-0000-0000-0000000000a2'
  and public.agent_root_id('fc000000-0000-0000-0000-0000000000a2')
    = 'fc000000-0000-0000-0000-0000000000a2',
  '  · وجذرُ الفرع أبوه، وجذرُ الأب نفسه');

rollback;
