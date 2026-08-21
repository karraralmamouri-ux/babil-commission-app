-- Repair the product unknown-FDT read contracts.
--
-- Migration 66 treated indicative_amount as a stored commission_exceptions
-- column.  It is deliberately not stored: the established read model derives
-- it from the cycle's indicative package rates.  Keep that single source of
-- truth and replace only the two affected read functions.
--
-- Forward-only and read-only: no business rows, calculation results, RLS,
-- ownership, payment, or finalisation state are changed.
begin;

create or replace function public.current_unknown_fdt_decisions(
  p_cycle_id uuid default null, p_search text default null,
  p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_cycle uuid; v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_cycle := coalesce(p_cycle_id, public.current_commission_cycle_id());
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with rates as materialized (
    select r.package_code, r.rate
    from public.indicative_rates(v_cycle) r
  ), grouped as (
    select coalesce(e.fdt_code, '(بلا رمز)') fdt_code,
      count(*) events,
      count(distinct x.subscriber_key) subscribers,
      coalesce(sum(coalesce(rt.rate, 0)), 0)::bigint indicative_amount,
      min(e.event_created_at) first_event_at,
      max(e.event_created_at) last_event_at,
      jsonb_agg(distinct e.raw_parent) filter (where e.raw_parent is not null) sources
    from public.commission_exceptions x
    left join public.saas_activation_events e
      on e.saas_event_id = x.activation_event_id
    left join rates rt on rt.package_code = e.profile_name
    where x.cycle_id = v_cycle
      and x.status = 'OPEN'
      and x.reason_code = 'UNKNOWN_FDT'
    group by coalesce(e.fdt_code, '(بلا رمز)')
  ), kept as (
    select * from grouped
    where p_search is null or btrim(p_search) = ''
       or fdt_code ilike '%' || p_search || '%'
  )
  select count(*), coalesce((select jsonb_agg(to_jsonb(x)) from (
    select *, '/master/fdts/' || fdt_code destination, 'الكابينة' decision_unit
    from kept order by events desc, fdt_code limit v_lim offset v_off
  ) x), '[]'::jsonb)
  into v_total, v_rows from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off)
    || jsonb_build_object('cycle_id', v_cycle);
end $fn$;

create or replace function public.current_unknown_fdt_events(
  p_fdt_code text, p_cycle_id uuid default null,
  p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_cycle uuid; v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_cycle := coalesce(p_cycle_id, public.current_commission_cycle_id());
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with rates as materialized (
    select r.package_code, r.rate
    from public.indicative_rates(v_cycle) r
  ), kept as (
    select x.id exception_id, x.activation_event_id, x.subscriber_key,
      coalesce(rt.rate, 0)::bigint indicative_amount, x.status,
      e.saas_user_id,
      coalesce(si.display_name, si.username, e.username, e.saas_user_id, x.subscriber_key) subscriber,
      e.fdt_code, e.raw_parent source, e.profile_name package,
      e.event_created_at, b.source_filename, e.source_sheet, e.source_row
    from public.commission_exceptions x
    join public.saas_activation_events e
      on e.saas_event_id = x.activation_event_id
    join public.saas_import_batches b on b.id = e.import_batch_id
    left join public.subscriber_identities si on si.username_key = e.username_key
    left join rates rt on rt.package_code = e.profile_name
    where x.cycle_id = v_cycle
      and x.status = 'OPEN'
      and x.reason_code = 'UNKNOWN_FDT'
      and coalesce(e.fdt_code, '(بلا رمز)') = p_fdt_code
  )
  select count(*), coalesce((select jsonb_agg(to_jsonb(x)) from (
    select * from kept
    order by event_created_at desc, activation_event_id
    limit v_lim offset v_off
  ) x), '[]'::jsonb)
  into v_total, v_rows from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off)
    || jsonb_build_object('cycle_id', v_cycle, 'fdt_code', p_fdt_code);
end $fn$;

revoke execute on function public.current_unknown_fdt_decisions(uuid,text,integer,integer)
  from public, anon;
grant execute on function public.current_unknown_fdt_decisions(uuid,text,integer,integer)
  to authenticated;
revoke execute on function public.current_unknown_fdt_events(text,uuid,integer,integer)
  from public, anon;
grant execute on function public.current_unknown_fdt_events(text,uuid,integer,integer)
  to authenticated;

commit;
