-- IMP-001: هوية الفاتورة = SOURCE/SYSTEM + INVOICE REFERENCE/NUMBER — لا
-- تفتح استحقاقاً مرتين عبر أيّ مسارٍ يكتب على installation_invoices، لا
-- المراجعة الفردية (review_invoice) ولا الرفع الجماعي (apply_bulk_invoice_
-- upload) التي تستدعيها لكل صفٍّ مطابق.
--
-- ستة سيناريوهات مطلوبة صراحةً:
--   A. نفس الفاتورة تُرفَع مرتين لا تُنشئ استحقاقين.
--   B. نفس الفاتورة تحت تزامن حقيقي — مُختبَرة في ملفٍّ منفصل
--      (invoice-dedup-concurrency.sh) لأن هذا الملف جلسة psql واحدة، لا
--      عمليتان متوازيتان فعلاً؛ راجعه لسيناريو B.
--   C. نفس رقم الفاتورة يظهر في ملفٍّ آخر (رفعة جماعية ثانية منفصلة).
--   D. فاتورتان مختلفتان لنفس المشترك (بمرحلتين متتاليتين) تبقيان مسموحتين.
--   E. فاتورة مُستخدَمة/مدفوعة سلفاً تُرفض عند إعادة استخدام رقمها.
--   F. فشل صفٍّ واحد داخل رفعة جماعية لا يُفسد الصفوف الأخرى ولا يترك أثراً
--      جزئياً لنفسه.
--
-- معزول بنطاق تسمية imp-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '     ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '     ok ' || p_label;
end;
$$;

begin;

select '  == invoice identity dedup ==';

insert into auth.users (id, email) values
  ('ad000000-0000-0000-0000-0000000000a1', 'imp-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('ad000000-0000-0000-0000-0000000000a1', 'IMP-AD', 'imp-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('ad000000-0000-0000-0000-00000000b001', 'imp-a1', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b002', 'imp-a2', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b003', 'imp-c1', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b004', 'imp-c2', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b005', 'imp-d1', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b006', 'imp-e1', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b007', 'imp-e2', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1'),
  ('ad000000-0000-0000-0000-00000000b008', 'imp-f1', 'وكيل IMP', 'IMP-FDT', date '2026-01-01', 13000, 'ad000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('ad000000-0000-0000-0000-00000000b001', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b002', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b003', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b004', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b005', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b006', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b007', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('ad000000-0000-0000-0000-00000000b008', date '2026-08-31', 13000, 'P1', 'resolved', true)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution, payment_eligible = excluded.payment_eligible;

set local role authenticated;
set local request.jwt.claim.sub = 'ad000000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- A. نفس الفاتورة تُرفَع مرتين — لا تُنشئ استحقاقين، سواءً لنفس المشترك
--    (تحديثٌ ذريّ على نفس الصفّ، لا صفٌّ ثانٍ) أو لمشتركٍ آخر (يُرفض).
-- ===========================================================================

select public.review_invoice('imp-a1', 'P1', 'VERIFIED', 'مراجعة أولى', 'IMP-A-1',
  gen_random_uuid());
select public.review_invoice('imp-a1', 'P1', 'VERIFIED', 'إعادة رفع نفس الفاتورة', 'IMP-A-1',
  gen_random_uuid());

select pg_temp.ok(
  (select count(*) from public.installation_invoices
   where subscriber_id = 'imp-a1' and invoice_number = 'IMP-A-1') = 1,
  'A: رفع نفس الفاتورة مرتين لنفس المشترك يبقى صفّاً واحداً، لا يتضاعف');

select pg_temp.must_fail(
  $q$select public.review_invoice('imp-a2', 'P1', 'VERIFIED', 'محاولة إعادة استخدام',
    'IMP-A-1', gen_random_uuid())$q$,
  'A: نفس رقم الفاتورة يُرفَض لمشتركٍ مختلف — الهوية لا تُستنسَخ');

select pg_temp.ok(
  not exists (select 1 from public.installation_invoices where subscriber_id = 'imp-a2'),
  'A: المحاولة المرفوضة لم تترك أيّ صفّ لـimp-a2');

-- ===========================================================================
-- C. نفس رقم الفاتورة يظهر في رفعةٍ جماعية ثانية منفصلة (ملفٌّ آخر) — يُصنَّف
--    already_used ويُتخطّى، لا يُطبَّق.
-- ===========================================================================

select public.apply_bulk_invoice_upload(
  jsonb_build_array(jsonb_build_object(
    'subscriber_id', 'imp-c1', 'invoice_number', 'IMP-C-1', 'invoice_date', '2026-08-01')),
  'imp-c-file-1.xlsx', 'رفعة أولى', gen_random_uuid()
) as imp_c_first \gset

select pg_temp.ok((:'imp_c_first'::jsonb ->> 'applied')::int = 1,
  'C: الرفعة الأولى تُطبَّق فاتورتها بنجاح');

select public.apply_bulk_invoice_upload(
  jsonb_build_array(jsonb_build_object(
    'subscriber_id', 'imp-c2', 'invoice_number', 'IMP-C-1', 'invoice_date', '2026-08-02')),
  'imp-c-file-2.xlsx', 'رفعة ثانية — ملفّ مختلف', gen_random_uuid()
) as imp_c_second \gset

select pg_temp.ok(
  (:'imp_c_second'::jsonb ->> 'applied')::int = 0
  and (:'imp_c_second'::jsonb ->> 'skipped')::int = 1,
  'C: نفس الرقم في ملفٍّ آخر يُتخطّى (already_used)، لا يُطبَّق');
select pg_temp.ok(
  not exists (select 1 from public.installation_invoices where subscriber_id = 'imp-c2'),
  'C: imp-c2 لا تملك أيّ صفّ فاتورة — لم تُفتَح له');

-- ===========================================================================
-- D. فاتورتان مختلفتان (رقمان مختلفان) لنفس المشترك عبر مرحلتين متتاليتين —
--    تبقيان مسموحتين، لا تعارض بينهما.
-- ===========================================================================

select public.review_invoice('imp-d1', 'P1', 'VERIFIED', 'القسط الأول', 'IMP-D-1',
  gen_random_uuid());

-- تقدّم المرحلة الحالية مصدره الوحيد استيراد "المتبقي" الخارجي (موثَّق في
-- 20261019090000) — نحاكيه هنا كما تفعله عملية الاستيراد الحقيقية. التحديث
-- الخام على الجدول يتطلّب postgres مباشرةً (RLS تمنع authenticated).
reset role;
update public.installation_subscriber_state
set current_stage = 'P2', remaining = 10000
where subscriber_uuid = 'ad000000-0000-0000-0000-00000000b005';
set local role authenticated;
set local request.jwt.claim.sub = 'ad000000-0000-0000-0000-0000000000a1';

select public.review_invoice('imp-d1', 'P2', 'VERIFIED', 'القسط الثاني', 'IMP-D-2',
  gen_random_uuid());

select pg_temp.ok(
  (select count(*) from public.installation_invoices
   where subscriber_id = 'imp-d1' and status = 'VERIFIED') = 2,
  'D: فاتورتان مختلفتان لنفس المشترك بمرحلتين تتعايشان بلا تعارض');

-- ===========================================================================
-- E. فاتورة مُدقَّقة (ومن ثمّ مؤهَّلة للدفع) لا يُعاد استخدام رقمها لمشتركٍ
--    آخر — حتى لو تقدَّم مسارها المالي لاحقاً. الحارس شرطه status='VERIFIED'
--    فقط، فلا يفرّق بين مدفوعة بالفعل أو لم تُدفَع بعد؛ الدفع لا "يُحرِّر"
--    الرقم أبداً — لذا لا حاجة لمحاكاة دفعة كاملة هنا لإثبات الحارس.
-- ===========================================================================

select public.review_invoice('imp-e1', 'P1', 'VERIFIED', 'فاتورة سابقة', 'IMP-E-1',
  gen_random_uuid());

select pg_temp.must_fail(
  $q$select public.review_invoice('imp-e2', 'P1', 'VERIFIED', 'إعادة استخدام فاتورة مُدقَّقة',
    'IMP-E-1', gen_random_uuid())$q$,
  'E: فاتورة مُدقَّقة سلفاً تُرفض لمشتركٍ آخر بلا شرط دفع');
select pg_temp.ok(
  not exists (select 1 from public.installation_invoices where subscriber_id = 'imp-e2'),
  'E: imp-e2 لا تملك أيّ صفّ فاتورة');

-- ===========================================================================
-- F. صفٌّ فاشل داخل رفعة جماعية (مشترك مجهول) لا يُفسد الصفوف الأخرى ولا
--    يترك أثراً جزئياً لنفسه — الحلقة في apply_bulk_invoice_upload تلتقط كل
--    صفٍّ ضمن begin/exception خاصّ به (نقطة استرجاع ضمنية)، فيُتخطّى وحده.
--    (سباق الهوية تحت تزامنٍ حقيقي مغطًّى في invoice-dedup-concurrency.sh —
--    B، لا هنا؛ فشل التصنيف داخل الرفعة نفسها لا يُنتج تعارض هوية، لأن
--    "duplicate" ضمن نفس الملف مضبوطة أصلاً قبل هذا الإصلاح.)
-- ===========================================================================

select public.apply_bulk_invoice_upload(
  jsonb_build_array(
    jsonb_build_object('subscriber_id', 'imp-f1', 'invoice_number', 'IMP-F-1',
                        'invoice_date', '2026-08-01'),
    jsonb_build_object('subscriber_id', 'imp-f-ghost', 'invoice_number', 'IMP-F-2',
                        'invoice_date', '2026-08-01')),
  'imp-f-file.xlsx', 'دفعة فيها صفّ فاشل', gen_random_uuid()
) as imp_f \gset

select pg_temp.ok(
  (:'imp_f'::jsonb ->> 'applied')::int = 1 and (:'imp_f'::jsonb ->> 'skipped')::int = 1,
  'F: صفّ صالح يُطبَّق وصفّ فاشل يُتخطّى في نفس الدفعة — لا رفضٌ جماعي');
select pg_temp.ok(
  exists (select 1 from public.installation_invoices
          where subscriber_id = 'imp-f1' and invoice_number = 'IMP-F-1' and status = 'VERIFIED'),
  'F: الصفّ الصالح فعلاً مُطبَّق');
select pg_temp.ok(
  not exists (select 1 from public.installation_invoices where subscriber_id = 'imp-f-ghost'),
  'F: الصفّ الفاشل لم يترك أيّ أثر جزئي (لا صفّ فاتورة)');
select pg_temp.ok(
  not exists (select 1 from public.audit_logs
              where entity_type = 'installation_invoice'
                and extra like '%imp-f-ghost%'),
  'F: الصفّ الفاشل لم يترك أثراً في سجلّ التدقيق أيضاً');

reset role;

select '  == invoice identity dedup: done ==';

rollback;
