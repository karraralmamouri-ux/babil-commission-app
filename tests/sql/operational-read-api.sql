-- واجهة القراءة التشغيلية: الحراسة، والتصفيح، والإجمالي.
--
-- سبب وجود التوكيد الأول بالذات: الصياغة الأولى وضعت الحارس في CTE
--     with allowed as (select require_capability(...) is null as ok)
-- فأسقطه المخطِّط لأن مخرَجه غير مستعمل، ومرّت القائمة بلا فحص. الاختبار هنا
-- يُشغِّل كل دالة بهوية لا تملك القدرة ويتوقّع رفضاً — لا صفراً ولا قائمة
-- فارغة، لأن القائمة الفارغة هي بالضبط ما بدا صحيحاً وكان خطأً.
--
-- معزول بنطاق تسمية OA-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '          ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_refuse(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ بلا صلاحية';
exception
  when insufficient_privilege then return '          ok ' || p_label;
  when others then
    if sqlerrm like '%Capability%' then return '          ok ' || p_label; end if;
    raise;
end;
$$;

begin;

select '         == operational read api ==';

-- ---------------------------------------------------------------------------
-- تجهيز
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('0a000000-0000-0000-0000-0000000000e1', 'oa-admin@fixture.invalid'),
  ('0a000000-0000-0000-0000-0000000000e2', 'oa-nobody@fixture.invalid')
on conflict do nothing;

insert into public.profiles (id, full_name, email, role, is_active) values
  ('0a000000-0000-0000-0000-0000000000e1','OAA','oa-admin@fixture.invalid','admin',true),
  ('0a000000-0000-0000-0000-0000000000e2','OAN','oa-nobody@fixture.invalid','viewer',false)
on conflict (id) do update set role = excluded.role, is_active = excluded.is_active;

insert into public.installation_subscribers (subscriber_id, reseller, fdt, start_date, created_by)
select 'OA-SUB-' || g, 'وكيل OA', '77', date '2026-01-01', '0a000000-0000-0000-0000-0000000000e1'
from generate_series(1, 7) g
on conflict do nothing;

insert into public.installation_payment_history (subscriber_uuid, stage, amount, payment_date, created_by)
select s.id, 'P1', 3000, date '2026-02-01', '0a000000-0000-0000-0000-0000000000e1'
from public.installation_subscribers s where s.subscriber_id like 'OA-SUB-%'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 1. الحارس ينفَّذ دائماً — لا يُسقطه المخطِّط
--
-- الحساب معطَّل، فلا قدرة له مهما كان دوره.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = '0a000000-0000-0000-0000-0000000000e2';

select pg_temp.must_refuse(
  'select * from public.list_installation_subscribers()',
  'سجل المشتركين يرفض من لا يملك القدرة');
select pg_temp.must_refuse(
  'select * from public.list_commission_exceptions()',
  'طابور الاستثناءات يرفض');
select pg_temp.must_refuse(
  'select * from public.list_agents_financial()',
  'قائمة الوكلاء ترفض');
select pg_temp.must_refuse(
  'select * from public.list_installation_entitlements()',
  'استحقاقات التنصيب ترفض');
select pg_temp.must_refuse(
  'select * from public.list_installation_holds()',
  'الإيقافات ترفض');
select pg_temp.must_refuse(
  'select * from public.list_payment_batches()',
  'دفعات الصرف ترفض');
select pg_temp.must_refuse(
  'select * from public.list_audit_events()',
  'سجل التدقيق يرفض');
select pg_temp.must_refuse(
  'select public.installation_subscriber_case(''OA-SUB-1'')',
  'ملفّ المشترك يرفض');
select pg_temp.must_refuse(
  'select * from public.subscriber_timeline(''OA-SUB-1'')',
  'الخطّ الزمني يرفض');
select pg_temp.must_refuse(
  'select public.installation_cycle_state()',
  'حالة الدورة ترفض');
select pg_temp.must_refuse(
  'select * from public.commission_finalization_blockers(gen_random_uuid())',
  'موانع الاعتماد ترفض');

reset role;

-- ---------------------------------------------------------------------------
-- 2. التصفيح
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = '0a000000-0000-0000-0000-0000000000e1';

select pg_temp.ok(
  (select count(*) from public.list_installation_subscribers(p_limit => 3)) = 3,
  'الصفحة تحترم الحدّ المطلوب');

-- الإجمالي هو إجمالي المُصفّى كلِّه لا حجمَ الصفحة. بدونه لا تعرف الشاشة
-- كم بقي، وهو الخلل الذي جعل 300 من 22,727 تبدو كلَّ العمل.
select pg_temp.ok(
  (select max(total_count) from public.list_installation_subscribers(p_limit => 3)) >= 7,
  'الإجمالي يصف المجموعة كلها لا الصفحة');

select pg_temp.ok(
  (select count(*) from public.list_installation_subscribers(p_limit => 3, p_offset => 6)) >= 1,
  'الإزاحة تصل إلى ما بعد الصفحة الأولى');

-- صفحتان متتاليتان لا تشتركان في صفّ.
select pg_temp.ok(
  not exists (
    select 1
    from public.list_installation_subscribers(p_limit => 3, p_offset => 0) a
    join public.list_installation_subscribers(p_limit => 3, p_offset => 3) b
      on b.subscriber_id = a.subscriber_id),
  'الصفحات لا تتداخل');

-- الحدّ الأعلى مقيَّد: طلبٌ ضخم لا يسحب الجدول كله.
select pg_temp.ok(
  public.page_limit(100000) = 200 and public.page_limit(null) = 50 and public.page_limit(0) = 1,
  'حدّ الصفحة مقيَّد بسقف');

select pg_temp.ok(
  public.page_offset(-5) = 0,
  'الإزاحة السالبة تُعامَل صفراً');

-- ---------------------------------------------------------------------------
-- 3. التصفية على الخادم
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.list_installation_subscribers(p_search => 'OA-SUB-1')) >= 1,
  'البحث يُصفّي على الخادم');

select pg_temp.ok(
  (select count(*) from public.list_installation_subscribers(p_search => 'لا-يوجد-أبداً')) = 0,
  'البحث بلا نتيجة يُعيد فراغاً لا خطأً');

select pg_temp.ok(
  (select count(*) from public.list_installation_subscribers(p_fdt => '77')) >= 7,
  'التصفية بالكابينة تعمل');

-- ---------------------------------------------------------------------------
-- 4. ملفّ المشترك
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select public.installation_subscriber_case('OA-SUB-1')) ? 'subscriber'
  and (select public.installation_subscriber_case('OA-SUB-1')) ? 'entitlements'
  and (select public.installation_subscriber_case('OA-SUB-1')) ? 'invoices'
  and (select public.installation_subscriber_case('OA-SUB-1')) ? 'holds'
  and (select public.installation_subscriber_case('OA-SUB-1')) ? 'payments'
  and (select public.installation_subscriber_case('OA-SUB-1')) ? 'totals',
  'الملفّ وثيقة واحدة تضمّ كل أقسام الحالة');

select pg_temp.ok(
  ((select public.installation_subscriber_case('OA-SUB-1')) -> 'totals' ->> 'paid')::bigint = 3000,
  'مجموع المدفوع يأتي من التاريخ لا من حساب في المتصفح');

-- المشترك غير الموجود يُعيد وثيقة فارغة لا خطأً: الشاشة تعرض «غير موجود».
select pg_temp.ok(
  (select public.installation_subscriber_case('OA-NOPE')) ? 'totals',
  'المشترك المجهول يُعيد وثيقة لا انهياراً');

-- ---------------------------------------------------------------------------
-- 5. الخطّ الزمني مُشتَقّ
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.subscriber_timeline('OA-SUB-1')
   where kind = 'PAYMENT' and amount = 3000) = 1,
  'الدفعة تظهر في الخطّ الزمني من مصدرها');

-- لا جدول خطٍّ زمني: لو وُجد لصار حقيقةً ثانية تنحرف عن الدفتر.
select pg_temp.ok(
  not exists (select 1 from information_schema.tables
              where table_schema = 'public' and table_name like '%timeline%'),
  'لا جدول خطّ زمني مخزَّن');

-- ---------------------------------------------------------------------------
-- 6. الحدّ الأعلى لا يُخفي
-- ---------------------------------------------------------------------------

-- تُزرع ثلاثة استثناءات وتُطلب صفحة من واحد: الإجمالي يجب أن يقول ثلاثة.
-- هذا هو الفرق الذي غاب في الشاشة القديمة — 300 صفاً معروضة من 22,727 بلا
-- أي إشارة إلى الباقي.
reset role;
insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('0a000000-0000-0000-0000-0000000000e3', 'OA دورة', date '2026-11-01', date '2026-11-30',
        'VNEXT', '0a000000-0000-0000-0000-0000000000e1')
on conflict do nothing;
insert into public.commission_exceptions
  (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
select '0a000000-0000-0000-0000-0000000000e3', 'OA-EV-' || g, 'oa-sub-' || g,
       'UNKNOWN_FDT', 'oa', true
from generate_series(1, 3) g
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '0a000000-0000-0000-0000-0000000000e1';

select pg_temp.ok(
  (select count(*) from public.list_commission_exceptions(
     p_cycle_id => '0a000000-0000-0000-0000-0000000000e3', p_limit => 1)) = 1,
  'الطابور يعرض صفحة واحدة');

select pg_temp.ok(
  (select max(total_count) from public.list_commission_exceptions(
     p_cycle_id => '0a000000-0000-0000-0000-0000000000e3', p_limit => 1)) = 3,
  'الطابور يُعلن إجماليه كاملاً مع صفحة من صفّ واحد');

-- والمجموعة الفارغة لا تنهار: لا صفوف، ولا خطأ.
select pg_temp.ok(
  (select count(*) from public.list_commission_exceptions(
     p_cycle_id => '0a000000-0000-0000-0000-0000000000e3', p_reason => 'NO_SUCH_REASON')) = 0,
  'السبب غير الموجود يُعيد فراغاً لا خطأً');

reset role;

rollback;
