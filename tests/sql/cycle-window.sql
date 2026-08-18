-- حدود الدورة بتوقيت العمل.
--
-- سبب وجود هذا الملف: الدورة تُوصَف بتاريخين، والحدث يحمل لحظةً بتوقيت عالمي.
-- الترجمة بينهما كانت تقع بتوقيت جلسة القاعدة (UTC في الإنتاج) لا بتوقيت
-- بغداد، فسقطت أوّل ثلاث ساعات من كل شهر خارج الحساب: 43 حدثاً حقيقياً في
-- تموز، لا محسوبة ولا محجوبة — غير موجودة.
--
-- كل توكيد هنا يُثبَّت على لحظة على الحدّ تماماً، لأن الحدّ وحده هو ما يكشف
-- الفرق بين التوقيتين. اختبار بمنتصف الشهر يمرّ في الحالتين ولا يُثبت شيئاً.
--
-- معزول بنطاق تسمية CW- خاص به.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '        ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '       == cycle window ==';

-- ---------------------------------------------------------------------------
-- توقيت العمل نفسه
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  public.business_timezone() = 'Asia/Baghdad',
  'توقيت العمل معلن في مكان واحد');

select pg_temp.ok(
  public.cycle_window_start(date '2026-07-01') = timestamptz '2026-06-30 21:00:00+00',
  'بداية الدورة هي منتصف ليل بغداد لا منتصف ليل UTC');

select pg_temp.ok(
  public.cycle_window_end(date '2026-07-31') = timestamptz '2026-07-31 21:00:00+00',
  'نهاية الدورة هي منتصف ليل بغداد التالي');

-- الحدّ الأعلى لدورة يساوي الحدّ الأدنى للتي تليها: لا ثغرة ولا تداخل.
select pg_temp.ok(
  public.cycle_window_end(date '2026-07-31') = public.cycle_window_start(date '2026-08-01'),
  'نهاية دورة تساوي بداية التالية تماماً');

-- ---------------------------------------------------------------------------
-- استقلال النتيجة عن توقيت الجلسة
--
-- هذا هو جوهر العيب: النافذة كانت تُترجَم بتوقيت الجلسة، فتغيُّر إعداد واحد
-- في الخادم كان يُزيح حدود الشهر المالي. تُقاس هنا تحت ثلاث مناطق مختلفة
-- عمداً، ومنها واحدة غربية الإشارة لتكشف أي خلط في اتجاه الإزاحة.
-- ---------------------------------------------------------------------------

set local timezone = 'UTC';
select pg_temp.ok(
  public.cycle_window_start(date '2026-07-01') = timestamptz '2026-06-30 21:00:00+00'
  and public.cycle_window_end(date '2026-07-31') = timestamptz '2026-07-31 21:00:00+00',
  'النافذة ثابتة وجلسة الخادم UTC');

set local timezone = 'Asia/Baghdad';
select pg_temp.ok(
  public.cycle_window_start(date '2026-07-01') = timestamptz '2026-06-30 21:00:00+00'
  and public.cycle_window_end(date '2026-07-31') = timestamptz '2026-07-31 21:00:00+00',
  'النافذة ثابتة وجلسة الخادم بغداد');

set local timezone = 'America/New_York';
select pg_temp.ok(
  public.cycle_window_start(date '2026-07-01') = timestamptz '2026-06-30 21:00:00+00'
  and public.cycle_window_end(date '2026-07-31') = timestamptz '2026-07-31 21:00:00+00',
  'النافذة ثابتة وجلسة الخادم بإزاحة سالبة');

set local timezone = 'UTC';

-- ---------------------------------------------------------------------------
-- تجهيز معزول
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values ('c0000000-0000-0000-0000-0000000000c1', 'cw-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('c0000000-0000-0000-0000-0000000000c1','CWA','cw-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.packages (code, name, semantic_category)
values ('P-35000','P-35000','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.agents (id, code, official_name)
values ('c0000000-0000-0000-0000-0000000000c2','CW-AG','وكيل اختبار الحدود')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution)
values ('c0000000-0000-0000-0000-0000000000c2','cw.parent','mapped')
on conflict (alias_key) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('c0000000-0000-0000-0000-0000000000c3','ACTIVATION_EVENTS','cw.xlsx','cw-checksum',
        'v1','c0000000-0000-0000-0000-0000000000c1','COMPLETE')
on conflict do nothing;

insert into public.fdts (code, label, zone, agent_id)
values ('CW-FDT','FDT-CW','new','c0000000-0000-0000-0000-0000000000c2')
on conflict (code) do nothing;

-- ست لحظات تغطي الحدّ من الجهتين، بما فيها اللحظتان الواقعتان عليه تماماً:
--   CW-BEFORE     30 حزيران 23:30 بغداد = 20:30Z  → قبل النافذة
--   CW-AT-START    1 تموز   00:00 بغداد = 21:00Z  → على الحدّ الأدنى، داخل
--   CW-FIRST       1 تموز   00:30 بغداد = 21:30Z  → داخل، وهذه التي كانت تسقط
--   CW-LAST       31 تموز   23:30 بغداد = 20:30Z  → داخل، قبيل الحدّ الأعلى
--   CW-AT-END      1 آب     00:00 بغداد = 21:00Z  → على الحدّ الأعلى، خارج
--   CW-AFTER       1 آب     00:30 بغداد = 21:30Z  → بعد النافذة
--
-- الحدّ الأدنى مغلق والأعلى مفتوح. هذا ليس تفصيلاً شكلياً: لو انعكسا لَحُسِبت
-- لحظة منتصف الليل في دورتين، أو سقطت من كلتيهما.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('c0000000-0000-0000-0000-0000000000c3','CW-BEFORE','cw-sub-b','P-35000',false,'cw.parent',
   timestamptz '2026-06-30 20:30:00+00','CW-FDT'),
  ('c0000000-0000-0000-0000-0000000000c3','CW-AT-START','cw-sub-s','P-35000',false,'cw.parent',
   timestamptz '2026-06-30 21:00:00+00','CW-FDT'),
  ('c0000000-0000-0000-0000-0000000000c3','CW-FIRST','cw-sub-1','P-35000',false,'cw.parent',
   timestamptz '2026-06-30 21:30:00+00','CW-FDT'),
  ('c0000000-0000-0000-0000-0000000000c3','CW-LAST','cw-sub-2','P-35000',false,'cw.parent',
   timestamptz '2026-07-31 20:30:00+00','CW-FDT'),
  ('c0000000-0000-0000-0000-0000000000c3','CW-AT-END','cw-sub-e','P-35000',false,'cw.parent',
   timestamptz '2026-07-31 21:00:00+00','CW-FDT'),
  ('c0000000-0000-0000-0000-0000000000c3','CW-AFTER','cw-sub-a','P-35000',false,'cw.parent',
   timestamptz '2026-07-31 21:30:00+00','CW-FDT')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('cw-sub-b','MATCHED','EXACT_USERNAME','RESELLER','c0000000-0000-0000-0000-0000000000c2'),
       ('cw-sub-s','MATCHED','EXACT_USERNAME','RESELLER','c0000000-0000-0000-0000-0000000000c2'),
       ('cw-sub-1','MATCHED','EXACT_USERNAME','RESELLER','c0000000-0000-0000-0000-0000000000c2'),
       ('cw-sub-2','MATCHED','EXACT_USERNAME','RESELLER','c0000000-0000-0000-0000-0000000000c2'),
       ('cw-sub-e','MATCHED','EXACT_USERNAME','RESELLER','c0000000-0000-0000-0000-0000000000c2'),
       ('cw-sub-a','MATCHED','EXACT_USERNAME','RESELLER','c0000000-0000-0000-0000-0000000000c2')
on conflict do nothing;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by)
values ('c0000000-0000-0000-0000-0000000000c4','CW تموز', date '2026-07-01', date '2026-07-31',
        'VNEXT','c0000000-0000-0000-0000-0000000000c1'),
       ('c0000000-0000-0000-0000-0000000000c5','CW آب', date '2026-08-01', date '2026-08-31',
        'VNEXT','c0000000-0000-0000-0000-0000000000c1')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- الحساب على الحدّ
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-0000000000c1';
select public.calculate_commission_cycle('c0000000-0000-0000-0000-0000000000c4') is not null as ran;
select public.calculate_commission_cycle('c0000000-0000-0000-0000-0000000000c5') is not null as ran2;
reset role;

-- التوكيد الذي كان يسقط. أول نصف ساعة من تموز بتوقيت بغداد تُحسب في تموز.
select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id = 'c0000000-0000-0000-0000-0000000000c4'
            and activation_event_id = 'CW-FIRST'),
  'أوّل ساعات الشهر بتوقيت بغداد تدخل الدورة');

select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id = 'c0000000-0000-0000-0000-0000000000c4'
            and activation_event_id = 'CW-LAST'),
  'آخر ساعات الشهر بتوقيت بغداد تدخل الدورة');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id = 'c0000000-0000-0000-0000-0000000000c4'
                and activation_event_id = 'CW-BEFORE'),
  'ما قبل الشهر لا يدخل');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id = 'c0000000-0000-0000-0000-0000000000c4'
                and activation_event_id = 'CW-AFTER'),
  'ما بعد الشهر لا يدخل');

-- اللحظتان الواقعتان على الحدّ تماماً.
select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id = 'c0000000-0000-0000-0000-0000000000c4'
            and activation_event_id = 'CW-AT-START'),
  'اللحظة على الحدّ الأدنى داخل الدورة — الحدّ مغلق');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id = 'c0000000-0000-0000-0000-0000000000c4'
                and activation_event_id = 'CW-AT-END'),
  'اللحظة على الحدّ الأعلى خارج الدورة — الحدّ مفتوح');

select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements
   where cycle_id = 'c0000000-0000-0000-0000-0000000000c4') = 3,
  'ثلاثة أحداث لا غير داخل تموز');

-- الحدث الذي يلي تموز مباشرةً يقع في آب: لا يضيع بين الدورتين.
select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id = 'c0000000-0000-0000-0000-0000000000c5'
            and activation_event_id = 'CW-AFTER'),
  'الحدث التالي للحدّ يقع في الدورة التالية لا في العدم');

-- واللحظة الواقعة على الحدّ تماماً تُحسب في آب: خرجت من تموز ولم تسقط.
select pg_temp.ok(
  exists (select 1 from public.commission_event_entitlements
          where cycle_id = 'c0000000-0000-0000-0000-0000000000c5'
            and activation_event_id = 'CW-AT-END'),
  'لحظة الحدّ نفسها تُحسب في الدورة التالية');

select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id = 'c0000000-0000-0000-0000-0000000000c5'
                and activation_event_id = 'CW-LAST'),
  'لا حدث يُحسب في دورتين');

-- ---------------------------------------------------------------------------
-- النافذة معلنة في مخرَج الحساب، فلا تُخمَّن من خارج
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-0000000000c1';
select pg_temp.ok(
  (public.calculate_commission_cycle('c0000000-0000-0000-0000-0000000000c4')
     ->> 'window_start')::timestamptz = timestamptz '2026-06-30 21:00:00+00',
  'الحساب يُعلن نافذته المستعملة');
reset role;

-- ---------------------------------------------------------------------------
-- الكابينة المحجوبة تُقاس بالنافذة نفسها
--
-- رقمان متعارضان عن الشيء ذاته أسوأ من رقم خاطئ واحد.
-- ---------------------------------------------------------------------------

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('c0000000-0000-0000-0000-0000000000c3','CW-U-FIRST','cw-u-1','P-35000',false,'cw.parent',
   timestamptz '2026-06-30 21:30:00+00','CW-UNREG'),
  ('c0000000-0000-0000-0000-0000000000c3','CW-U-BEFORE','cw-u-b','P-35000',false,'cw.parent',
   timestamptz '2026-06-30 20:30:00+00','CW-UNREG')
on conflict do nothing;

-- تُعاد الحسبة بعد ظهور الكابينة المجهولة، وإلا فلا استثناء يُسعَّر.
set local role authenticated;
set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-0000000000c1';
select public.calculate_commission_cycle('c0000000-0000-0000-0000-0000000000c4') is not null as ran3;
reset role;

select pg_temp.ok(
  (public.fdt_blocked_amount('c0000000-0000-0000-0000-0000000000c4','CW-UNREG')
     ->> 'blocked_events')::integer = 1,
  'المبلغ المحجوب يُقاس بنافذة الحساب نفسها');

-- ---------------------------------------------------------------------------
-- الصفر الصامت
--
-- الدورة لا تحمل نسخة مخطَّط قبل اعتمادها، والحساب يشتقّها. فمن قرأ العمود
-- مباشرةً حصل على NULL ثم على صفر بعد coalesce. والصفر يُقرأ «لا شيء محجوب»
-- فيُغلَق الطابور دون أن يُفتح — وهو أخطر من رقم خاطئ يُستجوَب.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select scheme_version_id from public.commission_cycles
   where id = 'c0000000-0000-0000-0000-0000000000c4') is null,
  'الدورة غير المعتمدة لا تحمل نسخة مخطَّط — شرط الاختبار قائم');

select pg_temp.ok(
  public.commission_version_for_cycle('c0000000-0000-0000-0000-0000000000c4') is not null,
  'النسخة تُشتقّ للدورة التي لا تحملها');

select pg_temp.ok(
  (public.fdt_blocked_amount('c0000000-0000-0000-0000-0000000000c4','CW-UNREG')
     ->> 'indicative_amount')::bigint > 0,
  'المبلغ المحجوب رقم حقيقي لا صفر صامت');

set local role authenticated;
set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-0000000000c1';

select pg_temp.ok(
  exists (select 1 from public.report_commission_exception_impact(
            'c0000000-0000-0000-0000-0000000000c4')
          where reason_code = 'UNKNOWN_FDT' and indicative_amount > 0),
  'أثر الاستثناء المالي رقم حقيقي لا صفر صامت');

select pg_temp.ok(
  (select blocked_subscribers from public.report_commission_exception_impact(
     'c0000000-0000-0000-0000-0000000000c4') where reason_code = 'UNKNOWN_FDT') >= 1,
  'الأثر يعدّ المشتركين لا الأحداث وحدها');

reset role;

rollback;
