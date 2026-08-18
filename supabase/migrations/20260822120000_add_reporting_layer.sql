-- طبقة التقارير: أرقام مُشتقّة من المصدر المعتمد، لا مُعاد بناؤها في المتصفح.
--
-- كل دالة هنا تُرجع ما يمكن تفسيره: الإجمالي، والمدفوع من الدفتر، والمتبقي
-- بينهما. لا رقم يُجمَّع في الواجهة ثم يُقدَّم على أنه حقيقة مالية.
--
-- القدرات: العرض يستلزم report.view، والتصدير report.export. والتصدير ليس
-- نسخة أوسع من العرض — هو إخراج بيانات إلى خارج النظام، ولذلك إذنه منفصل.
--
-- forward-only. قراءات فقط: لا جدول يُنشأ ولا صف يُكتب.

begin;

-- ---------------------------------------------------------------------------
-- 1. الوضع المالي لدورة عمولة كاملة.
-- ---------------------------------------------------------------------------

create or replace function public.commission_cycle_financials(p_cycle_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with snaps as (
    select s.*,
           coalesce((
             select sum(l.amount * l.direction) from public.financial_ledger l
             where l.domain = 'commission'
               and l.source_table = 'commission_cycle_snapshots'
               and l.source_id = s.id), 0)::bigint as net_paid
    from public.commission_cycle_snapshots s
    where s.cycle_id = p_cycle_id
  )
  select jsonb_build_object(
    'cycle', (select jsonb_build_object(
        'id', c.id, 'name', c.name, 'status', c.status,
        'engine_version', c.engine_version,
        'period_start', c.period_start, 'period_end', c.period_end,
        'finalized_at', c.finalized_at, 'scheme_version_id', c.scheme_version_id)
      from public.commission_cycles c where c.id = p_cycle_id),
    'totals', (select jsonb_build_object(
        'scopes', count(*),
        'unique_activated_subscribers', coalesce(sum(unique_activated_subscribers), 0),
        'qualifying_events', coalesce(sum(qualifying_event_count), 0),
        'gross', coalesce(sum(gross_commission), 0),
        'net_paid', coalesce(sum(net_paid), 0),
        'remaining', coalesce(sum(greatest(gross_commission - net_paid, 0)), 0))
      from snaps),
    'by_zone', coalesce((select jsonb_agg(z) from (
        select jsonb_build_object(
          'zone', zone, 'scopes', count(*),
          'unique_activated_subscribers', sum(unique_activated_subscribers),
          'qualifying_events', sum(qualifying_event_count),
          'gross', sum(gross_commission), 'net_paid', sum(net_paid),
          'remaining', sum(greatest(gross_commission - net_paid, 0))) as z
        from snaps group by zone) t), '[]'::jsonb),
    'exceptions', (select jsonb_build_object(
        'open', count(*) filter (where status = 'OPEN'),
        'blocking', count(*) filter (where status = 'OPEN' and blocks_finalization))
      from public.commission_exceptions where cycle_id = p_cycle_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. تفصيل دورة العمولة — صف لكل نطاق.
-- ---------------------------------------------------------------------------

create or replace function public.report_commission_cycle_detail(p_cycle_id uuid)
returns table (
  cycle_name text, scope_type text, scope_id text, scope_label text, zone text,
  tier_code text, unique_activated_subscribers integer, qualifying_event_count integer,
  p35_count integer, p45_count integer, p65_count integer,
  gross bigint, net_paid bigint, remaining bigint,
  scheme_version_id uuid, finalized_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.name, s.scope_type, s.scope_id, s.scope_label, s.zone, s.tier_code,
    s.unique_activated_subscribers, s.qualifying_event_count,
    coalesce((s.package_breakdown ->> 'P-35000')::integer, 0),
    coalesce((s.package_breakdown ->> 'P-45000')::integer, 0),
    coalesce((s.package_breakdown ->> 'P-65000')::integer, 0),
    s.gross_commission,
    coalesce((select sum(l.amount * l.direction) from public.financial_ledger l
              where l.domain = 'commission'
                and l.source_table = 'commission_cycle_snapshots'
                and l.source_id = s.id), 0)::bigint,
    greatest(s.gross_commission - coalesce((
      select sum(l.amount * l.direction) from public.financial_ledger l
      where l.domain = 'commission'
        and l.source_table = 'commission_cycle_snapshots'
        and l.source_id = s.id), 0), 0)::bigint,
    s.scheme_version_id, s.finalized_at
  from public.commission_cycle_snapshots s
  join public.commission_cycles c on c.id = s.cycle_id
  where s.cycle_id = p_cycle_id
    and public.has_capability('report.view')
  order by s.zone, s.scope_label nulls last, s.scope_id;
$$;

-- ---------------------------------------------------------------------------
-- 3. أجور التنصيب — الوضع الحالي.
-- ---------------------------------------------------------------------------

create or replace function public.installation_financials()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'subscribers', (select count(*) from public.installation_subscribers),
    'enrollments', (select count(*) from public.installation_enrollments),
    'stage_distribution', coalesce((
      select jsonb_object_agg(x.stage, x.n) from (
        select current_stage_code as stage, count(*) as n
        from public.installation_enrollments group by current_stage_code) x), '{}'::jsonb),
    'entitlements', (select count(*) from public.installation_entitlements),
    'due', (select coalesce(sum(amount), 0) from public.installation_entitlements
            where payment_status <> 'paid'),
    'paid', (select coalesce(sum(amount * direction), 0) from public.financial_ledger
             where domain = 'installation')::bigint,
    'historical_paid', (select coalesce(sum(amount), 0)
                        from public.installation_payment_history),
    'ready', (select count(*) from public.installation_entitlements
              where payment_status = 'eligible'),
    'awaiting_invoice', (select count(*) from public.installation_entitlements
                         where payment_status = 'awaiting_invoice'),
    'held', (select count(*) from public.installation_holds where status = 'ACTIVE'),
    'unresolved', (select count(*) from public.installation_subscriber_state
                   where resolution <> 'resolved')
  );
$$;

-- ---------------------------------------------------------------------------
-- 4. الملخص التنفيذي — المجالان معاً بلا دمج قاعدتيهما.
-- ---------------------------------------------------------------------------

create or replace function public.report_management_summary(p_cycle_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cycle uuid := p_cycle_id;
  v_comm jsonb;
  v_inst jsonb;
  v_comm_gross bigint;
  v_comm_paid bigint;
  v_inst_due bigint;
  v_inst_paid bigint;
begin
  perform public.require_capability('report.view');

  if v_cycle is null then
    select id into v_cycle from public.commission_cycles
    where engine_version = 'VNEXT'
    order by period_start desc limit 1;
  end if;

  v_comm := case when v_cycle is null then null
                 else public.commission_cycle_financials(v_cycle) end;
  v_inst := public.installation_financials();

  v_comm_gross := coalesce((v_comm -> 'totals' ->> 'gross')::bigint, 0);
  v_comm_paid := coalesce((v_comm -> 'totals' ->> 'net_paid')::bigint, 0);
  v_inst_due := coalesce((v_inst ->> 'due')::bigint, 0);
  v_inst_paid := coalesce((v_inst ->> 'paid')::bigint, 0);

  return jsonb_build_object(
    'commission', v_comm,
    'installation', v_inst,
    'global', jsonb_build_object(
      -- الالتزام الكلي = عمولة الدورة الحالية + أجور تنصيب مستحقة غير مدفوعة.
      -- لا يُجمَع تاريخ مدفوع سلفاً في «الالتزامات»، فذلك يضخّم الرقم بلا معنى.
      'total_obligations', v_comm_gross + v_inst_due,
      'total_paid', v_comm_paid + v_inst_paid,
      'total_remaining', greatest(v_comm_gross - v_comm_paid, 0)
                       + greatest(v_inst_due - v_inst_paid, 0),
      'unresolved_cases',
        coalesce((v_comm -> 'exceptions' ->> 'open')::integer, 0)
        + coalesce((v_inst ->> 'held')::integer, 0)
        + coalesce((v_inst ->> 'unresolved')::integer, 0),
      'current_cycle', coalesce(v_comm -> 'cycle' ->> 'name', '—'),
      'current_cycle_status', coalesce(v_comm -> 'cycle' ->> 'status', '—')
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. كشف حساب الوكيل.
-- ---------------------------------------------------------------------------

create or replace function public.report_agent_statement(p_agent_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_agent public.agents%rowtype;
begin
  perform public.require_capability('report.view');
  select * into v_agent from public.agents where id = p_agent_id;
  if not found then
    raise exception 'Agent was not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'agent', jsonb_build_object('id', v_agent.id, 'code', v_agent.code,
                                'name', v_agent.official_name, 'status', v_agent.status),
    'aliases', coalesce((select jsonb_agg(alias order by alias)
                         from public.agent_aliases where agent_id = p_agent_id), '[]'::jsonb),
    'fdts', coalesce((select jsonb_agg(code order by code)
                      from public.fdts where agent_id = p_agent_id), '[]'::jsonb),
    'commission', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cycle', c.name, 'status', c.status, 'zone', s.zone,
        'scope_type', s.scope_type, 'scope_id', s.scope_id, 'tier', s.tier_code,
        'unique_activated_subscribers', s.unique_activated_subscribers,
        'qualifying_events', s.qualifying_event_count,
        'p35', coalesce((s.package_breakdown ->> 'P-35000')::integer, 0),
        'p45', coalesce((s.package_breakdown ->> 'P-45000')::integer, 0),
        'p65', coalesce((s.package_breakdown ->> 'P-65000')::integer, 0),
        'gross', s.gross_commission,
        'net_paid', coalesce((select sum(l.amount * l.direction) from public.financial_ledger l
                              where l.domain = 'commission'
                                and l.source_table = 'commission_cycle_snapshots'
                                and l.source_id = s.id), 0),
        'remaining', greatest(s.gross_commission - coalesce((
          select sum(l.amount * l.direction) from public.financial_ledger l
          where l.domain = 'commission'
            and l.source_table = 'commission_cycle_snapshots'
            and l.source_id = s.id), 0), 0),
        'finalized_at', s.finalized_at)
        order by c.period_start desc)
      from public.commission_cycle_snapshots s
      join public.commission_cycles c on c.id = s.cycle_id
      where s.scope_id = p_agent_id::text
         or s.scope_id in (select code from public.fdts where agent_id = p_agent_id)
    ), '[]'::jsonb),
    'installation', jsonb_build_object(
      'subscribers', (select count(*) from public.installation_enrollments
                      where effective_agent_id = p_agent_id),
      'stage_distribution', coalesce((
        select jsonb_object_agg(x.stage, x.n) from (
          select current_stage_code as stage, count(*) as n
          from public.installation_enrollments
          where effective_agent_id = p_agent_id
          group by current_stage_code) x), '{}'::jsonb)),
    -- الخط الزمني المالي: الدفع والتصحيح والعكس كما وقعت، بترتيبها.
    'timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
        'at', l.created_at, 'domain', l.domain, 'type', l.txn_type,
        'origin', l.source_origin, 'amount', l.amount, 'direction', l.direction,
        'cycle', l.original_cycle_key, 'reason', l.reason)
        order by l.created_at desc)
      from public.financial_ledger l
      where l.agent_name = v_agent.official_name), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. الاستثناءات من المجالين في مكان واحد.
--
-- لا تُدمَج القاعدتان: يبقى لكل استثناء مجاله وسببه ومعرّفه، ويُجمَع العرض
-- وحده. الدمج المالي كان سيُخفي أن القواعد مختلفة.
-- ---------------------------------------------------------------------------

create or replace function public.report_open_exceptions(p_limit integer default 500)
returns table (
  domain text, reference_id uuid, subject text, reason_code text,
  detail text, blocking boolean, created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select 'commission'::text, e.id, coalesce(e.activation_event_id, e.subscriber_key, '—'),
         e.reason_code, e.detail, e.blocks_finalization, e.created_at
  from public.commission_exceptions e
  where e.status = 'OPEN' and public.has_capability('report.view')
  union all
  select 'installation'::text, h.id, h.subscriber_id, h.reason_code, h.note,
         (select r.blocks_payment from public.installation_hold_reasons r
          where r.code = h.reason_code), h.created_at
  from public.installation_holds h
  where h.status = 'ACTIVE' and public.has_capability('report.view')
  -- في UNION لا تُقرأ أسماء أعمدة RETURNS TABLE، فالترتيب بالمواضع.
  order by 6 desc nulls last, 7 desc
  limit greatest(coalesce(p_limit, 500), 1);
$$;

-- ---------------------------------------------------------------------------
-- 7. سجل التدقيق المالي.
-- ---------------------------------------------------------------------------

create or replace function public.report_audit_trail(
  p_limit integer default 200, p_action_prefix text default null)
returns table (
  at timestamptz, actor text, action text, entity_type text,
  entity_id uuid, field text, old_value text, new_value text, extra text
)
language sql
stable
security definer
set search_path = ''
as $$
  select a.created_at, coalesce(p.full_name, p.email, a.actor_id::text),
         a.action, a.entity_type, a.entity_id, a.field,
         a.old_value, a.new_value, a.extra
  from public.audit_logs a
  left join public.profiles p on p.id = a.actor_id
  where public.has_capability('audit.view')
    and (p_action_prefix is null or a.action like p_action_prefix || '%')
  order by a.created_at desc
  limit greatest(coalesce(p_limit, 200), 1);
$$;

-- ---------------------------------------------------------------------------
-- 8. التصدير — إذن منفصل.
--
-- التصدير يُخرِج البيانات من النظام، فلا يكفيه إذن العرض. الدالة تتحقق من
-- report.export صراحةً وتُدقَّق، فيبقى أثر لمن أخرج ماذا ومتى.
-- ---------------------------------------------------------------------------

create or replace function public.export_commission_cycle(p_cycle_id uuid, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_rows jsonb;
begin
  perform public.require_capability('report.export');

  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb) into v_rows
  from public.report_commission_cycle_detail(p_cycle_id) d;

  if p_request_id is not null
     and not exists (select 1 from public.audit_logs
                     where actor_id = v_actor and request_id = p_request_id) then
    insert into public.audit_logs (
      actor_id, action, field, new_value, entity_type, entity_id, request_id, extra)
    values (v_actor, 'report.exported', 'commission_cycle',
      jsonb_array_length(v_rows)::text, 'commission_cycle', p_cycle_id, p_request_id,
      'rows=' || jsonb_array_length(v_rows)::text);
  end if;

  return jsonb_build_object('cycle_id', p_cycle_id,
                            'row_count', jsonb_array_length(v_rows), 'rows', v_rows);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. الصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.commission_cycle_financials(uuid)',
    'public.report_commission_cycle_detail(uuid)',
    'public.installation_financials()',
    'public.report_management_summary(uuid)',
    'public.report_agent_statement(uuid)',
    'public.report_open_exceptions(integer)',
    'public.report_audit_trail(integer, text)',
    'public.export_commission_cycle(uuid, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
