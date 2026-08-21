-- Product-acceptance read contracts.  This migration is deliberately additive:
-- it does not alter calculation, ownership, payment, finalisation, or RLS.
begin;

create or replace function public.commission_cycle_product_result(p_cycle_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_id uuid; v_doc jsonb; v_ready bigint;
begin
  perform public.require_capability('commission.view');
  v_id := coalesce(p_cycle_id, public.current_commission_cycle_id());
  v_doc := public.commission_cycle_result(v_id);
  if coalesce((v_doc->>'found')::boolean, false) = false then return v_doc; end if;

  select coalesce(sum((p.state->>'remaining')::bigint)
           filter (where (p.state->>'payable')::boolean), 0)
    into v_ready
  from public.commission_cycle_snapshots s
  cross join lateral (select public.commission_scope_payable(s.id) as state) p
  where s.cycle_id = v_id;

  return jsonb_set(v_doc, '{totals,ready}', to_jsonb(v_ready), true);
end $fn$;

create or replace function public.page_commission_cycle_events_product(
  p_cycle_id uuid, p_agent_id uuid default null, p_fdt_code text default null,
  p_source text default null, p_package_code text default null,
  p_search text default null, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit); v_off := public.page_offset(p_offset);
  with kept as (
    select e.activation_event_id, e.subscriber_identity_id,
      coalesce(nullif(si.display_name,''), nullif(si.username,''), nullif(e.saas_user_id,''), e.subscriber_key) subscriber,
      e.saas_user_id, e.subscriber_key, e.effective_agent_id agent_id,
      coalesce(a.official_name,e.agent_name) agent_name, e.fdt_code, e.raw_parent source,
      e.package_code, e.tier_code, e.amount, e.event_at, e.status
    from public.commission_event_entitlements e
    left join public.subscriber_identities si on si.id=e.subscriber_identity_id
    left join public.agents a on a.id=e.effective_agent_id
    where e.cycle_id=p_cycle_id
      and (p_agent_id is null or e.effective_agent_id=p_agent_id)
      and (p_fdt_code is null or e.fdt_code=p_fdt_code)
      and (p_source is null or e.raw_parent=p_source)
      and (p_package_code is null or e.package_code=p_package_code)
      and (p_search is null or btrim(p_search)='' or coalesce(si.display_name,si.username,e.saas_user_id,e.subscriber_key) ilike '%'||p_search||'%')
  )
  select count(*), coalesce((select jsonb_agg(to_jsonb(x)) from
    (select * from kept order by event_at desc nulls last,activation_event_id limit v_lim offset v_off)x),'[]'::jsonb)
  into v_total,v_rows from kept;
  return public.page_envelope(v_rows,v_total,v_lim,v_off);
end $fn$;

create or replace function public.current_unknown_fdt_decisions(
  p_cycle_id uuid default null, p_search text default null,
  p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_cycle uuid; v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_cycle:=coalesce(p_cycle_id,public.current_commission_cycle_id());
  v_lim:=public.page_limit(p_limit); v_off:=public.page_offset(p_offset);
  with grouped as (
    select coalesce(e.fdt_code,'(بلا رمز)') fdt_code, count(*) events,
      count(distinct x.subscriber_key) subscribers, coalesce(sum(x.indicative_amount),0) indicative_amount,
      min(e.event_created_at) first_event_at, max(e.event_created_at) last_event_at,
      jsonb_agg(distinct e.raw_parent) filter(where e.raw_parent is not null) sources
    from public.commission_exceptions x
    left join public.saas_activation_events e on e.saas_event_id=x.activation_event_id
    where x.cycle_id=v_cycle and x.status='OPEN' and x.reason_code='UNKNOWN_FDT'
    group by coalesce(e.fdt_code,'(بلا رمز)')
  ), kept as (select * from grouped where p_search is null or btrim(p_search)='' or fdt_code ilike '%'||p_search||'%')
  select count(*),coalesce((select jsonb_agg(to_jsonb(x)) from
    (select *, '/master/fdts/'||fdt_code destination, 'الكابينة' decision_unit
     from kept order by events desc,fdt_code limit v_lim offset v_off)x),'[]'::jsonb)
  into v_total,v_rows from kept;
  return public.page_envelope(v_rows,v_total,v_lim,v_off)||jsonb_build_object('cycle_id',v_cycle);
end $fn$;

create or replace function public.current_unknown_fdt_events(
 p_fdt_code text,p_cycle_id uuid default null,p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_cycle uuid;v_rows jsonb;v_total bigint;v_lim integer;v_off integer;
begin
 perform public.require_capability('commission.view');v_cycle:=coalesce(p_cycle_id,public.current_commission_cycle_id());
 v_lim:=public.page_limit(p_limit);v_off:=public.page_offset(p_offset);
 with kept as(
  select x.id exception_id,x.activation_event_id,x.subscriber_key,x.indicative_amount,x.status,
    e.saas_user_id,coalesce(si.display_name,si.username,e.username,e.saas_user_id,x.subscriber_key) subscriber,
    e.fdt_code,e.raw_parent source,e.profile_name package,e.event_created_at,b.source_filename,e.source_sheet,e.source_row
  from public.commission_exceptions x join public.saas_activation_events e on e.saas_event_id=x.activation_event_id
  join public.saas_import_batches b on b.id=e.import_batch_id
  left join public.subscriber_identities si on si.username_key=e.username_key
  where x.cycle_id=v_cycle and x.status='OPEN' and x.reason_code='UNKNOWN_FDT' and coalesce(e.fdt_code,'(بلا رمز)')=p_fdt_code)
 select count(*),coalesce((select jsonb_agg(to_jsonb(x)) from(select * from kept order by event_created_at desc,activation_event_id limit v_lim offset v_off)x),'[]'::jsonb)
 into v_total,v_rows from kept;
 return public.page_envelope(v_rows,v_total,v_lim,v_off)||jsonb_build_object('cycle_id',v_cycle,'fdt_code',p_fdt_code);
end $fn$;

create or replace function public.commission_report_product(p_cycle_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_result jsonb; v_rows jsonb;
begin
  perform public.require_capability('report.view');
  v_result:=public.commission_cycle_product_result(p_cycle_id);
  select coalesce(jsonb_agg(to_jsonb(r) order by r.calculated desc),'[]'::jsonb) into v_rows
  from (
    select coalesce(a.id,f.agent_id) agent_id,
      coalesce(a.official_name,fa.official_name,d.scope_label,d.scope_id) agent_name,
      d.zone,d.scope_id fdt_code,d.tier_code,d.p35_count,d.p45_count,d.p65_count,
      d.qualifying_event_count qualifying_events,d.unique_activated_subscribers tier_basis,
      d.gross calculated,case when d.finalized_at is not null then d.gross else 0 end approved,
      case when (s.pay->>'payable')::boolean then (s.pay->>'remaining')::bigint else 0 end ready,
      d.net_paid paid,d.remaining
    from public.report_commission_cycle_detail(p_cycle_id)d
    join public.commission_cycle_snapshots cs on cs.cycle_id=p_cycle_id and cs.scope_type=d.scope_type and cs.scope_id=d.scope_id
    cross join lateral(select public.commission_scope_payable(cs.id) pay)s
    left join public.agents a on d.scope_type='AGENT' and a.id::text=d.scope_id
    left join public.fdts f on d.scope_type='FDT' and f.code=d.scope_id
    left join public.agents fa on fa.id=f.agent_id
  )r;
  return jsonb_build_object('summary',v_result,'rows',v_rows);
end $fn$;

create or replace function public.agent_financial_profile_product(p_agent_id uuid,p_cycle_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_cycle uuid; v_base jsonb; v_rows jsonb; v_summary jsonb;
begin
  perform public.require_capability('commission.view');
  v_cycle:=coalesce(p_cycle_id,public.current_commission_cycle_id());
  v_base:=public.agent_financial_profile(p_agent_id);
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb),jsonb_build_object(
    'calculated',coalesce(sum(calculated),0),'approved',coalesce(sum(approved),0),
    'ready',coalesce(sum(ready),0),'paid',coalesce(sum(paid),0),'remaining',coalesce(sum(remaining),0))
  into v_rows,v_summary from (
    select x.* from jsonb_to_recordset(public.commission_report_product(v_cycle)->'rows')
      as x(agent_id uuid,agent_name text,zone text,fdt_code text,tier_code text,
           p35_count int,p45_count int,p65_count int,qualifying_events int,tier_basis int,
           calculated bigint,approved bigint,ready bigint,paid bigint,remaining bigint)
    where x.agent_id=p_agent_id)r;
  return v_base||jsonb_build_object('cycle_id',v_cycle,'commission_summary',v_summary,
    'commission_scopes',v_rows,
    'unresolved_ownership',(public.commission_cycle_product_result(v_cycle)->'unresolved_ownership'));
end $fn$;

create or replace function public.page_commission_cycle_audit_product(
  p_cycle_id uuid,p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_rows jsonb;v_total bigint;v_lim integer;v_off integer;
begin
  perform public.require_capability('audit.view');
  v_lim:=public.page_limit(p_limit);v_off:=public.page_offset(p_offset);
  with kept as (
    select a.id,a.created_at,coalesce(p.full_name,p.email,'—') actor,a.action,a.entity_type,a.entity_id,
      a.field,a.old_value,a.new_value,a.before_data,a.after_data,a.extra
    from public.audit_logs a left join public.profiles p on p.id=a.actor_id
    where a.entity_id=p_cycle_id
       or exists(select 1 from public.commission_exceptions x where x.cycle_id=p_cycle_id and x.id=a.entity_id)
       or exists(select 1 from public.commission_payment_batches b where b.cycle_id=p_cycle_id and b.id=a.entity_id)
  )
  select count(*),coalesce((select jsonb_agg(to_jsonb(x)) from
    (select * from kept order by created_at desc,id desc limit v_lim offset v_off)x),'[]'::jsonb)
  into v_total,v_rows from kept;
  return public.page_envelope(v_rows,v_total,v_lim,v_off);
end $fn$;

create or replace function public.product_action_center()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare d jsonb;
begin
  perform public.require_capability('report.view'); d:=public.action_center();
  return jsonb_set(d,'{groups}',coalesce((select jsonb_agg(g||jsonb_build_object('path',case g->>'key'
    when 'UNKNOWN_FDT' then '/work/fdts' when 'SOURCE_INCOMPLETE' then '/system/imports?completeness=UNKNOWN'
    when 'CLASSIFICATION_REVIEW' then '/work/classification' when 'NEEDS_BUSINESS_DECISION' then '/work/business'
    else g->>'path' end)) from jsonb_array_elements(d->'groups')g),'[]'::jsonb));
end $fn$;

create or replace function public.product_classification_decisions(p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_rows jsonb;v_total bigint;v_lim integer;v_off integer;
begin
 perform public.require_capability('installation.view');v_lim:=public.page_limit(p_limit);v_off:=public.page_offset(p_offset);
 with kept as(select c.username_key,c.saas_user_id,c.reason_code,c.source_completeness,
   c.lifetime_activations_count,c.observed_event_count,c.qualifying_paid_event_count,c.evidence,c.evaluated_at,
   i.installation_subscriber_id
   from public.subscriber_classifications c left join public.subscriber_identities i on i.id=c.subscriber_identity_id
   where c.classification='NEEDS_REVIEW')
 select count(*),coalesce((select jsonb_agg(to_jsonb(x)) from(select * from kept order by evaluated_at desc limit v_lim offset v_off)x),'[]'::jsonb)
 into v_total,v_rows from kept;
 return public.page_envelope(v_rows,v_total,v_lim,v_off);
end $fn$;

create or replace function public.product_business_decisions(p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_rows jsonb;v_total bigint;v_lim integer;v_off integer;
begin
 perform public.require_capability('installation.view');v_lim:=public.page_limit(p_limit);v_off:=public.page_offset(p_offset);
 with current_owner as(select distinct on(o.username_key)o.username_key,o.agent_id from public.subscriber_ownership o
   where o.effective_to is null order by o.username_key,o.effective_from desc), kept as(
   select s.subscriber_id,s.subscriber_key,e.current_stage_code,e.effective_agent_id previous_agent_id,
     co.agent_id current_agent_id,pa.official_name previous_agent,ca.official_name current_agent
   from public.installation_enrollments e join public.installation_subscribers s on s.subscriber_id=e.subscriber_id
   join current_owner co on co.username_key=lower(btrim(s.subscriber_key))
   left join public.agents pa on pa.id=e.effective_agent_id left join public.agents ca on ca.id=co.agent_id
   where coalesce(e.current_stage_code,'UNKNOWN')<>'DONE' and e.effective_agent_id is distinct from co.agent_id)
 select count(*),coalesce((select jsonb_agg(to_jsonb(x)) from(select * from kept order by subscriber_id limit v_lim offset v_off)x),'[]'::jsonb)
 into v_total,v_rows from kept;
 return public.page_envelope(v_rows,v_total,v_lim,v_off);
end $fn$;

do $grant$ declare f text; begin foreach f in array array[
 'public.commission_cycle_product_result(uuid)',
 'public.page_commission_cycle_events_product(uuid,uuid,text,text,text,text,integer,integer)',
 'public.current_unknown_fdt_decisions(uuid,text,integer,integer)',
 'public.current_unknown_fdt_events(text,uuid,integer,integer)',
 'public.commission_report_product(uuid)',
 'public.agent_financial_profile_product(uuid,uuid)',
 'public.page_commission_cycle_audit_product(uuid,integer,integer)',
 'public.product_action_center()',
 'public.product_classification_decisions(integer,integer)',
 'public.product_business_decisions(integer,integer)'] loop
 execute format('revoke execute on function %s from public, anon',f);
 execute format('grant execute on function %s to authenticated',f);
end loop;end $grant$;
commit;
