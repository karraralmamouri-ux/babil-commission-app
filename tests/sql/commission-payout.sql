-- ضمانات مسار دفع العمولة vNext والتقارير.
-- القيم كلها مُختلَقة.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '    ok ' || p_label;
end;
$$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '    ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

insert into auth.users (id, email) values
  ('e1111111-1111-1111-1111-111111111111','adm@fixture.invalid'),
  ('e2222222-2222-2222-2222-222222222222','acc@fixture.invalid'),
  ('e3333333-3333-3333-3333-333333333333','vie@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('e1111111-1111-1111-1111-111111111111','AD','adm@fixture.invalid','admin',true),
  ('e2222222-2222-2222-2222-222222222222','AC','acc@fixture.invalid','accountant',true),
  ('e3333333-3333-3333-3333-333333333333','VI','vie@fixture.invalid','viewer',true)
on conflict (id) do update set role=excluded.role, is_active=true;

insert into public.packages (code, name, semantic_category) values
  ('P-35000','P-35000','PAID_PACKAGE'), ('Loan-3','Loan-3','DEBT_SERVICE')
on conflict (code) do nothing;

insert into public.agents (id, code, official_name)
values ('a9999999-9999-9999-9999-999999999999','AG-PAY','وكيل الدفع')
on conflict (code) do nothing;

-- دورة vNext معتمدة بلقطة واحدة.
insert into public.commission_cycles (id, name, period_start, period_end, engine_version,
  status, finalized_by, finalized_at, created_by)
values ('c9999999-9999-9999-9999-999999999999','دورة الدفع', date '2026-09-01',
        date '2026-09-30','VNEXT','FINALIZED','e1111111-1111-1111-1111-111111111111',
        now(),'e1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.commission_cycle_snapshots (
  id, cycle_id, scheme_version_id, scope_type, scope_id, scope_label, zone,
  unique_activated_subscribers, qualifying_event_count, tier_code,
  package_breakdown, gross_commission, finalized_at)
select 'd9999999-9999-9999-9999-999999999999','c9999999-9999-9999-9999-999999999999',
  v.id,'AGENT','a9999999-9999-9999-9999-999999999999','وكيل الدفع','old',
  2, 3, 't1', '{"P-35000": 3}'::jsonb, 12000, now()
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

-- ===========================================================================
-- 20. الدفع vNext
-- ===========================================================================
select '  == vNext payout ==';

select pg_temp.ok(
  (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'gross')::bigint = 12000
  and (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'net_paid')::bigint = 0
  and (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'remaining')::bigint = 12000,
  'الوضع المالي يُقرأ من اللقطة والدفتر لا من commission_rows');

select pg_temp.ok(
  (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'payable')::boolean,
  'لقطة معتمدة في دورة vNext قابلة للدفع');

insert into public.commission_payment_batches (id, name, cycle_id, prepared_by)
values ('b9999999-9999-9999-9999-999999999999','دفعة أيلول','c9999999-9999-9999-9999-999999999999',
        'e1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.commission_payment_batch_items
  (batch_id, snapshot_id, scope_type, scope_id, scope_label, zone, agent_name,
   tier_code, gross_amount, amount)
values ('b9999999-9999-9999-9999-999999999999','d9999999-9999-9999-9999-999999999999',
        'AGENT','a9999999-9999-9999-9999-999999999999','وكيل الدفع','old','وكيل الدفع',
        't1',12000,12000)
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'e1111111-1111-1111-1111-111111111111';
select public.revalidate_commission_batch('b9999999-9999-9999-9999-999999999999') as rv \gset
select public.post_commission_batch('b9999999-9999-9999-9999-999999999999','حوالة-1', gen_random_uuid()) as posted \gset
reset role;

select pg_temp.ok(
  (select status from public.commission_payment_batch_items
   where batch_id='b9999999-9999-9999-9999-999999999999') = 'PAID',
  'الاستحقاق المعتمد يُدفَع عبر مسار vNext');

select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where domain='commission' and source_table='commission_cycle_snapshots'
     and source_id='d9999999-9999-9999-9999-999999999999') = 1,
  'الدفع يكتب قيداً واحداً في الدفتر نفسه');

select pg_temp.ok(
  (select ledger_entry_id from public.commission_payment_batch_items
   where batch_id='b9999999-9999-9999-9999-999999999999') is not null,
  'البند المدفوع يحمل قيده');

select pg_temp.ok(
  (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'remaining')::bigint = 0,
  'المتبقي صفر بعد الدفع الكامل');

-- لا اعتماد على commission_rows.
select pg_temp.ok(
  (select coalesce(sum(paid),0) from public.commission_rows) = 0,
  'الدفع vNext لم يمسّ commission_rows');

-- تكرار الطلب لا يدفع مرتين.
set local role authenticated;
set local request.jwt.claim.sub = 'e1111111-1111-1111-1111-111111111111';
select pg_temp.must_fail(
  $$select public.post_commission_batch('b9999999-9999-9999-9999-999999999999','x', gen_random_uuid())$$,
  'الدفعة المُرحَّلة لا تُرحَّل ثانية');
reset role;

select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where source_id='d9999999-9999-9999-9999-999999999999') = 1,
  'لا قيد ثانٍ من محاولة الترحيل المكررة');

-- التجاوز مستحيل: بند جديد على لقطة استُوفيت.
insert into public.commission_payment_batches (id, name, cycle_id, prepared_by)
values ('b8888888-8888-8888-8888-888888888888','دفعة ثانية','c9999999-9999-9999-9999-999999999999',
        'e1111111-1111-1111-1111-111111111111')
on conflict do nothing;

select pg_temp.must_fail($$
  insert into public.commission_payment_batch_items
    (batch_id, snapshot_id, scope_type, scope_id, zone, gross_amount, amount)
  values ('b8888888-8888-8888-8888-888888888888','d9999999-9999-9999-9999-999999999999',
          'AGENT','a9999999-9999-9999-9999-999999999999','old',12000,12000)
$$, 'اللقطة المدفوعة لا تدخل دفعة أخرى حيّة');

-- ===========================================================================
-- 5. فصل السلطتين
-- ===========================================================================
select '  == authority separation ==';

insert into public.commission_months (id, month_key, tiers, created_by)
values ('f9999999-9999-9999-9999-999999999999','دورة الدفع','[]'::jsonb,
        'e1111111-1111-1111-1111-111111111111')
on conflict do nothing;
insert into public.commission_rows (id, month_id, zone, name, p35, p45, p65, created_by)
values ('f8888888-8888-8888-8888-888888888888','f9999999-9999-9999-9999-999999999999',
        'old','وكيل الدفع',3,0,0,'e1111111-1111-1111-1111-111111111111')
on conflict do nothing;

select pg_temp.must_fail($$
  update public.commission_rows set paid = 1000
  where id='f8888888-8888-8888-8888-888888888888'
$$, 'الفترة التي تحكمها دورة vNext لا تُدفع عبر الصفوف القديمة');

select pg_temp.ok(
  (select paid from public.commission_rows where id='f8888888-8888-8888-8888-888888888888') = 0,
  'الصف القديم بقي بلا دفع');

-- ===========================================================================
-- 4. التصحيح والعكس على نتائج vNext
-- ===========================================================================
select '  == correction on vNext ==';

set local role authenticated;
set local request.jwt.claim.sub = 'e1111111-1111-1111-1111-111111111111';
-- دالة العكس القائمة تعمل على (المجال، المصدر) لا على معرّف القيد. وهذا هو
-- سبب اختيار اللقطة مصدراً: مسار vNext يصير مفهوماً لها بلا أي تعديل فيها.
select public.reverse_financial_entry(
  'commission', 'd9999999-9999-9999-9999-999999999999',
  'دفعة إلى الوكيل الخطأ', gen_random_uuid()) as rev \gset
reset role;

select pg_temp.ok(
  (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'net_paid')::bigint = 0,
  'العكس يُعيد الصافي إلى الصفر');

select pg_temp.ok(
  (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'reversed')::bigint = 12000,
  'المبلغ المعكوس يُعرَض صراحةً');

select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where source_id='d9999999-9999-9999-9999-999999999999') = 2,
  'العكس يُضيف قيداً ولا يمحو الأصل');

select pg_temp.ok(
  (public.commission_scope_payable('d9999999-9999-9999-9999-999999999999') ->> 'remaining')::bigint = 12000,
  'المتبقي يعود بعد العكس');

-- ===========================================================================
-- 21. التقارير تتصالح مع المصدر
-- ===========================================================================
select '  == reporting reconciliation ==';

set local role authenticated;
set local request.jwt.claim.sub = 'e1111111-1111-1111-1111-111111111111';

select pg_temp.ok(
  (public.commission_cycle_financials('c9999999-9999-9999-9999-999999999999')
    -> 'totals' ->> 'gross')::bigint = 12000,
  'إجمالي التقرير يطابق اللقطات');

select pg_temp.ok(
  (public.commission_cycle_financials('c9999999-9999-9999-9999-999999999999')
    -> 'totals' ->> 'unique_activated_subscribers')::integer = 2
  and (public.commission_cycle_financials('c9999999-9999-9999-9999-999999999999')
    -> 'totals' ->> 'qualifying_events')::integer = 3,
  'التقرير يفصل المقياسين كما في اللقطة');

select pg_temp.ok(
  (select sum(gross) from public.report_commission_cycle_detail('c9999999-9999-9999-9999-999999999999'))
  = (public.commission_cycle_financials('c9999999-9999-9999-9999-999999999999')
     -> 'totals' ->> 'gross')::bigint,
  'مجموع التفصيل يساوي مجموع الملخّص');

select pg_temp.ok(
  (select net_paid from public.report_commission_cycle_detail('c9999999-9999-9999-9999-999999999999') limit 1) = 0,
  'المدفوع في التفصيل يعكس العكس المسجَّل');

select pg_temp.ok(
  (public.report_management_summary('c9999999-9999-9999-9999-999999999999')
    -> 'global' ->> 'total_obligations') is not null,
  'الملخص التنفيذي يُنتج التزامات');

select pg_temp.ok(
  (public.report_agent_statement('a9999999-9999-9999-9999-999999999999')
    -> 'commission' -> 0 ->> 'gross')::bigint = 12000,
  'كشف الوكيل يطابق اللقطة');

select pg_temp.ok(
  jsonb_array_length(public.report_agent_statement('a9999999-9999-9999-9999-999999999999')
    -> 'timeline') >= 2,
  'الخط الزمني يحمل الدفع والعكس معاً');
reset role;

-- ===========================================================================
-- 22. الصلاحيات والتصدير
-- ===========================================================================
select '  == permissions and export ==';

-- المشاهد يملك report.view (كما كان قبل هذه المرحلة) ولا يملك التصدير.
select pg_temp.ok(
  public.effective_permission('e3333333-3333-3333-3333-333333333333','report.view'),
  'المشاهد يقرأ التقارير');

select pg_temp.ok(
  not public.effective_permission('e3333333-3333-3333-3333-333333333333','report.export'),
  'المشاهد لا يُصدِّر');

select pg_temp.ok(
  public.effective_permission('e2222222-2222-2222-2222-222222222222','report.export'),
  'المحاسب يُصدِّر');

set local role authenticated;
set local request.jwt.claim.sub = 'e3333333-3333-3333-3333-333333333333';
select pg_temp.must_fail(
  $$select public.export_commission_cycle('c9999999-9999-9999-9999-999999999999', gen_random_uuid())$$,
  'التصدير مرفوض لمن لا يملك إذنه');
select pg_temp.must_fail(
  $$select public.post_commission_batch('b8888888-8888-8888-8888-888888888888','x', gen_random_uuid())$$,
  'المشاهد لا يُرحّل دفعة');
reset role;

-- المحاسب يُصدِّر ويُدقَّق تصديره.
set local role authenticated;
set local request.jwt.claim.sub = 'e2222222-2222-2222-2222-222222222222';
select public.export_commission_cycle('c9999999-9999-9999-9999-999999999999', gen_random_uuid()) as exp \gset
reset role;

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='report.exported'),
  'التصدير مُدقَّق');

-- المحاسب لا يعتمد ولا يهيّئ.
select pg_temp.ok(
  not public.effective_permission('e2222222-2222-2222-2222-222222222222','commission.finalize')
  and not public.effective_permission('e2222222-2222-2222-2222-222222222222','commission.configure'),
  'إذن الدفع منفصل عن إذن التهيئة والاعتماد');

-- ===========================================================================
-- 23. حدود النتائج
-- ===========================================================================
select '  == bounded results ==';

set local role authenticated;
set local request.jwt.claim.sub = 'e1111111-1111-1111-1111-111111111111';
select pg_temp.ok(
  (select count(*) from public.report_open_exceptions(5)) <= 5,
  'تقرير الاستثناءات محدود بحدّه');
select pg_temp.ok(
  (select count(*) from public.report_audit_trail(3)) <= 3,
  'سجل التدقيق محدود بحدّه');
select pg_temp.ok(
  (select count(*) from public.report_audit_trail(0)) <= 1,
  'حدّ غير صالح يُعامَل حدّاً أدنى لا حدّاً مفتوحاً');
reset role;

-- ===========================================================================
-- 19. التدقيق
-- ===========================================================================
select '  == audit ==';

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='commission.batch.posted'),
  'ترحيل الدفعة مُدقَّق');

select pg_temp.ok(
  (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
   where c.relnamespace='public'::regnamespace
     and c.relname in ('commission_payment_batches','commission_payment_batch_items')
     and a.privilege_type <> 'SELECT'
     and a.grantee::regrole::text in ('authenticated','anon','public')) = 0,
  'لا صلاحية كتابة لأي دور تطبيقي على دفعات العمولة');

-- ===========================================================================
-- 6. legacy_month_id
-- ===========================================================================
select '  == legacy month link ==';

select pg_temp.ok(
  (select count(*) from pg_description d
   join pg_class c on c.oid = d.objoid
   where c.relname='commission_cycles' and d.description like '%reporting only%') = 1,
  'العمود المعلّق صار موصوفاً لا غامضاً');

update public.commission_cycles set legacy_month_id='f9999999-9999-9999-9999-999999999999'
where id='c9999999-9999-9999-9999-999999999999';

insert into public.commission_cycles (name, period_start, period_end, created_by)
values ('دورة أخرى', date '2026-10-01', date '2026-10-31','e1111111-1111-1111-1111-111111111111');

select pg_temp.must_fail($$
  update public.commission_cycles set legacy_month_id='f9999999-9999-9999-9999-999999999999'
  where name='دورة أخرى'
$$, 'شهر قديم لا يُشار إليه من دورتين');

rollback;
