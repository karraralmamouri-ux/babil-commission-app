\set ON_ERROR_STOP on
\pset tuples_only on
create or replace function pg_temp.ok(p_cond boolean,p_label text) returns text language sql as $$
 select case when p_cond then '                ok '||p_label else 'FAILED: '||p_label end $$;

select '               == product acceptance read contracts ==';
select pg_temp.ok(to_regprocedure('public.commission_cycle_product_result(uuid)') is not null,'cycle product result exists');
select pg_temp.ok(to_regprocedure('public.page_commission_cycle_events_product(uuid,uuid,text,text,text,text,integer,integer)') is not null,'event evidence page exists');
select pg_temp.ok(to_regprocedure('public.current_unknown_fdt_decisions(uuid,text,integer,integer)') is not null,'current FDT decisions exist');
select pg_temp.ok(to_regprocedure('public.current_unknown_fdt_events(text,uuid,integer,integer)') is not null,'current FDT evidence exists');
select pg_temp.ok(to_regprocedure('public.commission_report_product(uuid)') is not null,'commission report exists');
select pg_temp.ok(to_regprocedure('public.agent_financial_profile_product(uuid,uuid)') is not null,'agent product profile exists');
select pg_temp.ok(to_regprocedure('public.page_commission_cycle_audit_product(uuid,integer,integer)') is not null,'cycle audit page exists');
select pg_temp.ok(to_regprocedure('public.product_action_center()') is not null,'action destinations exist');
select pg_temp.ok(to_regprocedure('public.product_classification_decisions(integer,integer)') is not null,'classification decisions exist');
select pg_temp.ok(to_regprocedure('public.product_business_decisions(integer,integer)') is not null,'business decisions exist');
select pg_temp.ok(not has_function_privilege('anon','public.commission_cycle_product_result(uuid)','EXECUTE'),'anonymous cannot execute product result');

begin;

insert into auth.users (id, email)
values ('ac000000-0000-0000-0000-000000000001', 'acceptance-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('ac000000-0000-0000-0000-000000000001', 'Acceptance Admin',
        'acceptance-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

-- indicative_rates intentionally starts from the package catalogue.  A clean
-- database has no operational import configuration to seed that catalogue,
-- so this isolated fixture declares the two established paid packages it uses.
insert into public.packages (code, name, semantic_category)
values ('P-35000', 'P-35000', 'PAID_PACKAGE'),
       ('P-45000', 'P-45000', 'PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('ac000000-0000-0000-0000-000000000002', 'ACTIVATION_EVENTS',
        'acceptance.xlsx', 'acceptance-fdt-read-contract', 'v1',
        'ac000000-0000-0000-0000-000000000001', 'COMPLETE');

insert into public.commission_cycles
  (id, name, period_start, period_end, scheme_version_id, engine_version, created_by)
select 'ac000000-0000-0000-0000-000000000003', 'Acceptance FDT read contract',
       date '2026-07-01', date '2026-07-31', v.id, 'VNEXT',
       'ac000000-0000-0000-0000-000000000001'
from public.commission_scheme_versions v
join public.commission_schemes s on s.id = v.scheme_id
where s.code = 'COMMISSION_STANDARD' and v.version = 1;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, saas_user_id, username, profile_name,
   canceled, raw_parent, event_created_at, fdt_code, source_sheet, source_row)
values
  ('ac000000-0000-0000-0000-000000000002', 'AC-FDT-EV-1', 'AC-U-1',
   'ac-sub-1', 'P-35000', false, 'ac.source', '2026-07-10 09:00+03',
   'AC-UNKNOWN', 'July', 10),
  ('ac000000-0000-0000-0000-000000000002', 'AC-FDT-EV-2', 'AC-U-2',
   'ac-sub-2', 'P-45000', false, 'ac.source', '2026-07-11 09:00+03',
   'AC-UNKNOWN', 'July', 11);

insert into public.commission_exceptions
  (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
values
  ('ac000000-0000-0000-0000-000000000003', 'AC-FDT-EV-1', 'ac-sub-1',
   'UNKNOWN_FDT', 'acceptance fixture', true),
  ('ac000000-0000-0000-0000-000000000003', 'AC-FDT-EV-2', 'ac-sub-2',
   'UNKNOWN_FDT', 'acceptance fixture', true);

set local role authenticated;
set local request.jwt.claim.sub = 'ac000000-0000-0000-0000-000000000001';

select pg_temp.ok(
  (public.current_unknown_fdt_decisions(
     'ac000000-0000-0000-0000-000000000003', null, 50, 0)->>'total')::integer = 1,
  'current FDT decisions execute and group the unknown cabinet');

select pg_temp.ok(
  (public.current_unknown_fdt_decisions(
     'ac000000-0000-0000-0000-000000000003', null, 50, 0)
       ->'rows'->0->>'indicative_amount')::bigint = 9500,
  'current FDT decisions derive the indicative amount from package rates');

select pg_temp.ok(
  (public.current_unknown_fdt_events(
     'AC-UNKNOWN', 'ac000000-0000-0000-0000-000000000003', 50, 0)->>'total')::integer = 2,
  'current FDT evidence executes and returns both events');

select pg_temp.ok(
  (select count(*) = 2 and sum(r.indicative_amount) = 9500
   from jsonb_to_recordset(public.current_unknown_fdt_events(
     'AC-UNKNOWN', 'ac000000-0000-0000-0000-000000000003', 50, 0)->'rows')
     as r(package text, indicative_amount bigint)
   where (r.package = 'P-35000' and r.indicative_amount = 4000)
      or (r.package = 'P-45000' and r.indicative_amount = 5500)),
  'current FDT evidence exposes the established rate for each package');

reset role;
rollback;
