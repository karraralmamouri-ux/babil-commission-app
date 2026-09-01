-- INS-009: مطابقة مؤشّرات التنصيب — لا رقمٌ على الشاشة يُصدَّق بلا برهانٍ
-- من قاعدة البيانات نفسها.
--
-- installation_payout_candidates() هو المصدر الوحيد فعلاً لأرقام المرشّح
-- والجاهز (installation_cycle_pipeline يستدعيه هو نفسه، لا يعيد حسابه —
-- 20261010090000:412)، فلا ازدواج مصدرٍ بين شاشتي /installation
-- و/installation/cycle. هذا الملف يُثبت ما لا يثبته وجود مصدرٍ واحد وحده:
-- أن ذلك المصدر نفسه صحيحٌ مقابل الحقيقة الخام، لا مجرّد متّسقٍ مع نفسه.
--
-- ثلاث مطابقات:
--
--   1. الأساس الخام: مجموع (subscribers, amount) الذي تُعيده الدالّة يطابق
--      SUM/COUNT مستقلّاً مباشرة على installation_subscribers +
--      installation_subscriber_state بلا أي حاجزٍ مطبَّق — يثبت أن مجموعة
--      "المرشّحين قبل الفحص" لم تفلت من عدّها.
--
--   2. تناسق داخلي: by_stage تُجمَع فتساوي الإجمالي، وready+blocked.any
--      تساوي subscribers، وready_amount+blocked_amount.any تساوي amount —
--      يثبت أن التقسيم شاملٌ ومتنافٍ، لا صفّاً يضيع بين الفئتين ولا يُحسب
--      في كلتيهما.
--
--   3. ازدواج منطقٍ حقيقي مكتوب عمداً لأسباب أداء (تعليق 20260920090000:
--      66-71 يدّعي "الحكم نفسه حرفاً بحرف" — الادّعاء هنا يُختبَر لا يُصدَّق):
--      installation_payout_candidates() يُضمِّن نسخة inline من منطق
--      subscriber_ownership_type() تفادياً لنداء الدالّة 5,693 مرّة.
--      materialize_installation_entitlements() ما زالت تستدعي الدالّة
--      الأصلية مباشرة. لا رابط بنيوي بين النسختين — فقط تطابقٌ يُفترَض. هذا
--      الملف يقارن الحكمين لكل نوع عائدية (RESELLER عبر صفّ، DIRECT_COMPANY
--      عبر صفّ، NEEDS_REVIEW بلا صفّ عبر كلا فرعي الاحتياط)، ثم يثبت أن
--      المادّية (materialize) لا تُنشئ استحقاقاً إلا لمن يحكم عليه المرشّح
--      الحيّ بأنه جاهزٌ فعلاً — لا فقط بالمقارنة النظرية، بل بتشغيل الدالّتين
--      الحقيقيّتين معاً على نفس البيانات.
--
-- معزول بنطاق تسمية kpi-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '    ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select ' == installation kpi reconciliation ==';

insert into auth.users (id, email) values
  ('ae000000-0000-0000-0000-0000000000a1', 'kpi-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ae000000-0000-0000-0000-0000000000a1', 'KPI-AD', 'kpi-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.agents (id, code, official_name)
values ('ae000000-0000-0000-0000-00000000ac01', 'KPI-AGT', 'وكيل KPI')
on conflict (code) do nothing;

-- سبعة مشتركين: واحدٌ جاهزٌ تماماً، وستّة كلٌّ منهم محجوبٌ بسببٍ واحد فقط
-- (معزول عمداً عن بقية الأسباب) كي تُحسَب فئات الحجب بدقّة.
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('ae000000-0000-0000-0000-00000000b001', 'kpi-ready',      'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1'),
  ('ae000000-0000-0000-0000-00000000b002', 'kpi-hold',       'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1'),
  ('ae000000-0000-0000-0000-00000000b003', 'kpi-noinv',      'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1'),
  ('ae000000-0000-0000-0000-00000000b004', 'kpi-unresolved', 'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1'),
  ('ae000000-0000-0000-0000-00000000b005', 'kpi-conflict',   'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1'),
  ('ae000000-0000-0000-0000-00000000b006', 'kpi-direct',     'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1'),
  ('ae000000-0000-0000-0000-00000000b007', 'kpi-review',     'وكيل KPI', 'KPI-FDT', date '2026-01-01', 13000, 'ae000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('ae000000-0000-0000-0000-00000000b001', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ae000000-0000-0000-0000-00000000b002', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ae000000-0000-0000-0000-00000000b003', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ae000000-0000-0000-0000-00000000b004', date '2026-08-31', 13000, 'P1', 'unresolved', false),
  ('ae000000-0000-0000-0000-00000000b005', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ae000000-0000-0000-0000-00000000b006', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ae000000-0000-0000-0000-00000000b007', date '2026-08-31', 13000, 'P1', 'resolved', true)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution, payment_eligible = excluded.payment_eligible;

-- العائدية: ready/hold/noinv/unresolved/conflict كلّها RESELLER عبر صفّ
-- صريح (كي لا يحجبها شيءٌ غير المقصود)؛ direct عبر صفّ DIRECT_COMPANY
-- صريح؛ review بلا صفّ إطلاقاً، فيسقط على فرع الاحتياط subscriber_identities
-- (المُختبَر بلا تصنيفٍ حاسم، فيؤول إلى NEEDS_REVIEW).
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values
  ('kpi-ready',      'RESELLER', 'ae000000-0000-0000-0000-00000000ac01', timestamptz '2026-01-01 00:00+03', 'اختبار', 'ae000000-0000-0000-0000-0000000000a1'),
  ('kpi-hold',       'RESELLER', 'ae000000-0000-0000-0000-00000000ac01', timestamptz '2026-01-01 00:00+03', 'اختبار', 'ae000000-0000-0000-0000-0000000000a1'),
  ('kpi-noinv',      'RESELLER', 'ae000000-0000-0000-0000-00000000ac01', timestamptz '2026-01-01 00:00+03', 'اختبار', 'ae000000-0000-0000-0000-0000000000a1'),
  ('kpi-unresolved', 'RESELLER', 'ae000000-0000-0000-0000-00000000ac01', timestamptz '2026-01-01 00:00+03', 'اختبار', 'ae000000-0000-0000-0000-0000000000a1'),
  ('kpi-conflict',   'RESELLER', 'ae000000-0000-0000-0000-00000000ac01', timestamptz '2026-01-01 00:00+03', 'اختبار', 'ae000000-0000-0000-0000-0000000000a1'),
  ('kpi-direct',     'DIRECT_COMPANY', null, timestamptz '2026-01-01 00:00+03', 'اختبار', 'ae000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- kpi-review بلا صفّ ownership: يسقط على subscriber_identities — تُدرَج
-- بلا source_classification حاسم فتؤول NEEDS_REVIEW عبر فرع الاحتياط.
insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values
  ('kpi-conflict', 'CONFLICT', 'EXACT_USERNAME', 'RESELLER', 'ae000000-0000-0000-0000-00000000ac01', 'KPI-FDT'),
  ('kpi-review', 'MATCHED', 'EXACT_USERNAME', 'UNKNOWN_PARENT', null, 'KPI-FDT')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'ae000000-0000-0000-0000-0000000000a1';

-- فاتورةٌ مُدقَّقة للجميع عدا kpi-noinv (يبقى محجوباً بالفاتورة وحدها) —
-- بلا رقم فاتورة (null) كي لا تتقاطع مع حارس IMP-001 لهوية الفاتورة، فهذا
-- الاختبار عن مطابقة KPI لا عن ذلك الحارس.
select public.review_invoice('kpi-ready',      'P1', 'VERIFIED', 'اختبار KPI', null, gen_random_uuid());
select public.review_invoice('kpi-hold',       'P1', 'VERIFIED', 'اختبار KPI', null, gen_random_uuid());
select public.review_invoice('kpi-unresolved', 'P1', 'VERIFIED', 'اختبار KPI', null, gen_random_uuid());
select public.review_invoice('kpi-conflict',   'P1', 'VERIFIED', 'اختبار KPI', null, gen_random_uuid());
select public.review_invoice('kpi-direct',     'P1', 'VERIFIED', 'اختبار KPI', null, gen_random_uuid());
select public.review_invoice('kpi-review',     'P1', 'VERIFIED', 'اختبار KPI', null, gen_random_uuid());

-- تعليقٌ فعّال دائم على kpi-hold وحده.
select public.place_hold_v2('kpi-hold', 'PERMANENT', 'MANUAL_REVIEW', 'اختبار KPI',
  null, null, gen_random_uuid());

select public.installation_payout_candidates() as doc \gset

reset role;

-- ===========================================================================
-- 1. الأساس الخام: نفس السبعة، بلا أي حاجزٍ مطبَّق، تُحسب مباشرةً من
--    الجدولين — يجب أن تساوي subscribers/amount في أعلى الوثيقة تماماً.
--    (بدور postgres مباشرةً: هذا استعلامٌ خامٌّ للمقارنة، لا اختبار منحةٍ
--    لدالّة — ذلك مُثبَتٌ أصلاً بنجاح نداء installation_payout_candidates()
--    أعلاه بدور authenticated.)
-- ===========================================================================

select count(*) as n,
       coalesce(sum(public.installation_amount_for_stage(st.current_stage)), 0) as amt
into temp pg_temp_kpi_raw
from public.installation_subscribers s
join public.installation_subscriber_state st on st.subscriber_uuid = s.id
where s.subscriber_id like 'kpi-%'
  and coalesce(st.remaining, 0) > 0
  and st.current_stage in ('P1','P2','P3','P4');

select pg_temp.ok(
  (:'doc'::jsonb ->> 'subscribers')::int = (select n from pg_temp_kpi_raw),
  'الأساس: عدد المرشّحين من الدالّة يطابق COUNT خاماً على الجدولين');
select pg_temp.ok(
  (:'doc'::jsonb ->> 'amount')::bigint = (select amt from pg_temp_kpi_raw),
  'الأساس: مبلغ المرشّحين من الدالّة يطابق SUM خاماً على الجدولين');

-- ===========================================================================
-- 2. تناسق داخلي: الفئات تُغطّي كل صفٍّ مرّة واحدة بالضبط.
-- ===========================================================================

select pg_temp.ok(
  (:'doc'::jsonb ->> 'subscribers')::int
    = (:'doc'::jsonb ->> 'ready')::int + (:'doc'::jsonb -> 'blocked' ->> 'any')::int,
  'تناسق: الجاهز + المحجوب(أيّ سبب) = الإجمالي، بلا فجوة ولا ازدواج');
select pg_temp.ok(
  (:'doc'::jsonb ->> 'amount')::bigint
    = (:'doc'::jsonb ->> 'ready_amount')::bigint + (:'doc'::jsonb -> 'blocked_amount' ->> 'any')::bigint,
  'تناسق: مبلغ الجاهز + مبلغ المحجوب(أيّ سبب) = مبلغ الإجمالي');
select pg_temp.ok(
  (:'doc'::jsonb ->> 'subscribers')::int = (
    select coalesce(sum((v ->> 'subscribers')::int), 0)
    from jsonb_each(:'doc'::jsonb -> 'by_stage') e(k, v)),
  'تناسق: مجموع by_stage.subscribers عبر كل مرحلة يساوي الإجمالي');
select pg_temp.ok(
  (:'doc'::jsonb ->> 'amount')::bigint = (
    select coalesce(sum((v ->> 'amount')::bigint), 0)
    from jsonb_each(:'doc'::jsonb -> 'by_stage') e(k, v)),
  'تناسق: مجموع by_stage.amount عبر كل مرحلة يساوي الإجمالي');

-- ===========================================================================
-- 3. ازدواج منطق العائدية: النسخة inline (داخل هذه الدالّة) يجب أن تحكم
--    بالضبط كما تحكم subscriber_ownership_type() الأصلية، لكل مسارٍ ممكن.
-- ===========================================================================

select pg_temp.ok(
  public.subscriber_ownership_type('kpi-ready') = 'RESELLER',
  'عائدية: صفٌّ صريح RESELLER يُقرأ RESELLER من الدالّة الأصلية');
select pg_temp.ok(
  public.subscriber_ownership_type('kpi-direct') = 'DIRECT_COMPANY',
  'عائدية: صفٌّ صريح DIRECT_COMPANY يُقرأ DIRECT_COMPANY من الدالّة الأصلية');
select pg_temp.ok(
  public.subscriber_ownership_type('kpi-review') = 'NEEDS_REVIEW',
  'عائدية: بلا صفٍّ وبلا تصنيفٍ حاسم يؤول NEEDS_REVIEW من الدالّة الأصلية');

-- المرشّح لا يُرجع حكم العائدية لكل مشترك على حدة في وثيقته (فقط أثره
-- المجمَّع ضمن blocked.parent) — فالفحص الحاسم للمطابقة بين النسختين هو
-- تشغيل materialize (تستدعي الدالّة الأصلية) ومقارنة نتيجتها بما يقوله
-- المرشّح الحيّ (يُضمِّن النسخة inline) عن نفس المشتركين، أدناه.
set local role authenticated;
set local request.jwt.claim.sub = 'ae000000-0000-0000-0000-0000000000a1';

select public.materialize_installation_entitlements(
  '2026-09', null, 500, gen_random_uuid()) as mat \gset

select pg_temp.ok(
  exists (select 1 from public.installation_entitlements
          where period = '2026-09' and subscriber_id = 'kpi-ready'),
  'مادّية: kpi-ready (جاهزٌ فعلاً) يُثبَّت استحقاقه');
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where period = '2026-09' and subscriber_id = 'kpi-hold'),
  'مادّية: kpi-hold (محجوبٌ بتعليق) لا يُثبَّت له استحقاق');
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where period = '2026-09' and subscriber_id = 'kpi-noinv'),
  'مادّية: kpi-noinv (بلا فاتورة) لا يُثبَّت له استحقاق');
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where period = '2026-09' and subscriber_id = 'kpi-unresolved'),
  'مادّية: kpi-unresolved (حالة تاريخية غير محسومة) لا يُثبَّت له استحقاق');
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where period = '2026-09' and subscriber_id = 'kpi-conflict'),
  'مادّية: kpi-conflict (تعارض هوية) لا يُثبَّت له استحقاق');
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where period = '2026-09' and subscriber_id = 'kpi-direct'),
  'مادّية: kpi-direct (شركة مباشرة، ليست وكيلاً) لا يُثبَّت له استحقاق — إثبات مطابقة نسخة inline بالتشغيل الفعلي');
select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where period = '2026-09' and subscriber_id = 'kpi-review'),
  'مادّية: kpi-review (عائدية تحتاج مراجعة) لا يُثبَّت له استحقاق — إثبات فرع الاحتياط بالتشغيل الفعلي');

-- والمبلغ نفسه: المُثبَّت فعلياً لهذه الدفعة يساوي ready_amount من المرشّح
-- الحيّ تماماً (لا سبعة صفوفٍ محتملة، بل واحدٌ فقط جاهز).
select pg_temp.ok(
  (:'doc'::jsonb ->> 'ready_amount')::bigint = (
    select coalesce(sum(amount), 0) from public.installation_entitlements
    where period = '2026-09' and subscriber_id like 'kpi-%'),
  'مادّية: مبلغ المُثبَّت فعلياً لمجموعة الاختبار يطابق ready_amount من المرشّح الحيّ تماماً');

reset role;

-- ===========================================================================
-- 4. تقرير أجور التنصيب (/reports/installation) مقابل خطوة «تثبيت الاستحقاق»
--    في دورة التنصيب (/installation/cycle) — تدقيق QA ما بعد الإطلاق
--    (2026-09-01، طلب #6): الشاشتان تُبلَّغان بأن أرقامهما «تتضارب».
--
--    الحقيقة: كلتاهما تقرآن installation_entitlements بمعيار الفترة نفسه
--    حرفاً بحرف (period = p_period). فحين تُمرَّر نفس الفترة صراحةً لكلتيهما
--    يجب أن يتطابق العدد والمبلغ تماماً — وهذا ما يُثبته القسم الأول أدناه.
--    التضارب الحقيقي المُبلَّغ ليس خطأ حسابٍ بل اختلاف افتراضٍ: التقرير بلا
--    فلترة فترة يجمع كل الفترات المستوردة، بينما لوحة الدورة بلا فترة تفترض
--    الشهر الحالي (business_timezone) — القسم الثاني يُثبت هذا الفارق صراحةً
--    حتى لا يُقرأ ثانيةً كخطأ حساب. المعالجة على الواجهة توضيحية (راجع
--    src/features/reports/index.ts) لا تُغيّر افتراض أيّ دالّةٍ من الاثنتين.
-- ===========================================================================

-- صفٌّ إضافي في فترةٍ مختلفة (٢٠٢٦-٠٨) كي يكون الفارق بين «فترة واحدة» و
-- «كل الفترات» فارقاً حقيقياً قابلاً للقياس، لا فارقاً صفرياً بالمصادفة.
insert into public.installation_entitlements
  (batch_id, period, subscriber_id, subscriber_name, reseller, zone, remaining,
   stage, amount, payment_status, created_by)
select null, '2026-08', 'kpi-other-period', 'اختبار فترة أخرى', 'وكيل KPI', 'old',
       13000, 'P1', 3000, 'awaiting_invoice', 'ae000000-0000-0000-0000-0000000000a1'
where not exists (
  select 1 from public.installation_entitlements
  where period = '2026-08' and subscriber_id = 'kpi-other-period');

set local role authenticated;
set local request.jwt.claim.sub = 'ae000000-0000-0000-0000-0000000000a1';

select public.report_installation_fees('2026-09', null, null, 1, 0) as rep0906 \gset
select public.installation_cycle_pipeline('2026-09') as pipe0906 \gset

select pg_temp.ok(
  ((:'rep0906'::jsonb -> 'summary' ->> 'entitlements')::int
    = (select (elem ->> 'count')::int from jsonb_array_elements(:'pipe0906'::jsonb -> 'steps') elem
       where elem ->> 'key' = 'ENTITLEMENT')),
  'مطابقة #6: عدد استحقاقات ٢٠٢٦-٠٩ في التقرير = عدّاد خطوة تثبيت الاستحقاق في الدورة، لنفس الفترة الصريحة');
select pg_temp.ok(
  ((:'rep0906'::jsonb -> 'summary' ->> 'total_amount')::bigint
    = (select (elem ->> 'amount')::bigint from jsonb_array_elements(:'pipe0906'::jsonb -> 'steps') elem
       where elem ->> 'key' = 'ENTITLEMENT')),
  'مطابقة #6: مبلغ استحقاقات ٢٠٢٦-٠٩ في التقرير = مبلغ خطوة تثبيت الاستحقاق في الدورة، لنفس الفترة الصريحة');
select pg_temp.ok(
  (:'pipe0906'::jsonb ->> 'period') = '2026-09',
  'مطابقة #6: تمرير p_period صراحةً للدورة يُلزمها تلك الفترة، لا الشهر الحالي');

-- جذر التضارب المُبلَّغ: التقرير بلا فلترة فترة يجمع كل الفترات — لا يقتصر
-- على فترةٍ واحدة كما تفعل لوحة الدورة حين تفترض الشهر الحالي بلا تمرير فترة.
select public.report_installation_fees(null, null, null, 1, 0) as repall \gset

select pg_temp.ok(
  (:'repall'::jsonb -> 'summary' ->> 'entitlements')::int
    = (:'rep0906'::jsonb -> 'summary' ->> 'entitlements')::int + 1,
  'جذر التضارب #6: بلا فلترة فترة، التقرير يضمّ صفّ فترة٢٠٢٦-٠٨ الإضافي أيضاً — يجمع كل الفترات لا فترة الدورة الحالية وحدها');
select pg_temp.ok(
  (:'repall'::jsonb -> 'summary' ->> 'total_amount')::bigint
    = (:'rep0906'::jsonb -> 'summary' ->> 'total_amount')::bigint + 3000,
  'جذر التضارب #6: مبلغ التقرير بلا فلترة يشمل مبلغ الفترة الأخرى أيضاً — 3000 زيادة');

reset role;

select ' == installation kpi reconciliation: done ==';

rollback;
