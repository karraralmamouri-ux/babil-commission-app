-- LIVE-04 / ARC-001: قيد عمولة حقيقي عبر مسار الدفع vNext يجب أن يظهر في
-- report_payment_history() كما يظهر في عدّاد archive_overview() — كلاهما
-- يجب أن يتحرك بنفس المقدار عند إضافة قيدٍ من أي نطاق، لا نطاق التنصيب فقط.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '    ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

insert into auth.users (id, email) values
  ('f1111111-1111-1111-1111-111111111111','adm-live04@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('f1111111-1111-1111-1111-111111111111','AD','adm-live04@fixture.invalid','admin',true)
on conflict (id) do update set role=excluded.role, is_active=true;

insert into public.packages (code, name, semantic_category) values
  ('P-35000','P-35000','PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.agents (id, code, official_name)
values ('f2222222-2222-2222-2222-222222222222','AG-LIVE04','وكيل ARC-001')
on conflict (code) do nothing;

insert into public.commission_cycles (id, name, period_start, period_end, engine_version,
  status, finalized_by, finalized_at, created_by)
values ('f3333333-3333-3333-3333-333333333333','دورة ARC-001', date '2026-09-01',
        date '2026-09-30','VNEXT','FINALIZED','f1111111-1111-1111-1111-111111111111',
        now(),'f1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.commission_cycle_snapshots (
  id, cycle_id, scheme_version_id, scope_type, scope_id, scope_label, zone,
  unique_activated_subscribers, qualifying_event_count, tier_code,
  package_breakdown, gross_commission, finalized_at)
select 'f4444444-4444-4444-4444-444444444444','f3333333-3333-3333-3333-333333333333',
  v.id,'AGENT','f2222222-2222-2222-2222-222222222222','وكيل ARC-001','old',
  1, 1, 't1', '{"P-35000": 1}'::jsonb, 5000, now()
from public.commission_scheme_versions v where v.version = 1
on conflict do nothing;

insert into public.commission_payment_batches (id, name, cycle_id, prepared_by)
values ('f5555555-5555-5555-5555-555555555555','دفعة ARC-001','f3333333-3333-3333-3333-333333333333',
        'f1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.commission_payment_batch_items
  (batch_id, snapshot_id, scope_type, scope_id, scope_label, zone, agent_name,
   tier_code, gross_amount, amount)
values ('f5555555-5555-5555-5555-555555555555','f4444444-4444-4444-4444-444444444444',
        'AGENT','f2222222-2222-2222-2222-222222222222','وكيل ARC-001','old','وكيل ARC-001',
        't1',5000,5000)
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'f1111111-1111-1111-1111-111111111111';

select (public.archive_overview() -> 'totals' ->> 'ledger_entries')::bigint as v_before_archive \gset
select (public.report_payment_history(null, null, 200, 0) -> 'summary' ->> 'entries')::bigint as v_before_report \gset

select public.revalidate_commission_batch('f5555555-5555-5555-5555-555555555555') as rv \gset
select public.post_commission_batch('f5555555-5555-5555-5555-555555555555','ARC-001-ref', gen_random_uuid()) as posted \gset

select id as v_ledger_id from public.financial_ledger
where domain = 'commission' and source_table = 'commission_cycle_snapshots'
  and source_id = 'f4444444-4444-4444-4444-444444444444' \gset

select (public.archive_overview() -> 'totals' ->> 'ledger_entries')::bigint as v_after_archive \gset
select (public.report_payment_history(null, null, 200, 0) -> 'summary' ->> 'entries')::bigint as v_after_report \gset

select public.report_payment_history(null, null, 200, 0) -> 'page' -> 'rows' as v_page_rows \gset

reset role;

select pg_temp.ok(:v_after_archive = :v_before_archive + 1,
  'قيد العمولة الجديد يُحتسب في KPI الأرشيف');

select pg_temp.ok(:v_after_report = :v_before_report + 1,
  'قيد العمولة نفسه يظهر الآن في تقرير الدفعات — لم يعد نطاق العمولة مستبعَداً');

select pg_temp.ok(:v_after_archive = :v_after_report,
  'عدّاد KPI وعدّاد رابط التفصيل متطابقان بعد الإصلاح — لا فجوة ARC-001');

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(:'v_page_rows'::jsonb) r
          where (r ->> 'id')::uuid = :'v_ledger_id'::uuid),
  'صف قيد العمولة نفسه — لا مجرد العدد — يظهر داخل صفحة التقرير');

rollback;
