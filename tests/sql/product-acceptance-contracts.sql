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
