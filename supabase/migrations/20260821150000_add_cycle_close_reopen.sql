-- إقفال الدورات وإعادة فتحها — للمجالين المالِيَّين.
--
-- الجداول ودوراتها موجودة منذ المرحلة السابقة، والمفقود كان مسار الكتابة:
-- الدورة تُنشأ وتُقرأ ولا تُقفل. هذه المهاجرة تُكمله.
--
-- السياسة المعتمدة، وهي واحدة في المجالين:
--   • الإقفال يُنتج لقطة تشرح النتيجة، ويُسجَّل فاعله وسببه.
--   • دورة أُقفلت بلا مال مُرحَّل: يجوز فتحها بتصريح وسبب وتدقيق.
--   • دورة فيها مال مُرحَّل: لا تُفتح. المال المُرحَّل لا يُعاد كتابته؛ التصحيح
--     والعكس هما الطريق، وهما موجودان منذ 0b.
--
-- forward-only.

begin;

-- ---------------------------------------------------------------------------
-- 1. هل في الدورة مال مُرحَّل؟
--
-- الإجابة تُقاس من الدفتر ومن الحالة معاً: الدفتر هو المرجع منذ 0b، والحالة
-- تُمسك ما دُفع قبل وجوده.
-- ---------------------------------------------------------------------------

create or replace function public.installation_cycle_posted_amount(p_cycle_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select sum(i.amount)
    from public.installation_payment_batch_items i
    join public.installation_payment_batches b on b.id = i.batch_id
    where b.cycle_id = p_cycle_id and i.status = 'PAID'), 0)::bigint;
$$;

create or replace function public.commission_cycle_posted_amount(p_cycle_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select sum(l.amount * l.direction)
    from public.financial_ledger l
    where l.domain = 'commission'
      and l.original_cycle_key = (select name from public.commission_cycles where id = p_cycle_id)
  ), 0)::bigint;
$$;

-- ---------------------------------------------------------------------------
-- 2. إقفال دورة أجور التنصيب.
-- ---------------------------------------------------------------------------

create or replace function public.close_installation_cycle(
  p_cycle_id uuid, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_cycle public.installation_cycles%rowtype;
  v_open_holds integer;
  v_pending integer;
  v_snapshot jsonb;
begin
  perform public.require_capability('cycle.close');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.installation_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Installation cycle was not found' using errcode = 'P0002';
  end if;
  if v_cycle.status = 'CLOSED' then
    raise exception 'The cycle is already closed' using errcode = '42501';
  end if;

  -- بند ينتظر الدفع في دفعة غير مُرحَّلة يعني عملاً لم ينتهِ.
  select count(*) into v_pending
  from public.installation_payment_batch_items i
  join public.installation_payment_batches b on b.id = i.batch_id
  where b.cycle_id = p_cycle_id and i.status = 'PENDING';
  if v_pending > 0 then
    raise exception 'The cycle still has % pending payment item(s)', v_pending
      using errcode = '42501';
  end if;

  select count(*) into v_open_holds
  from public.installation_holds where status = 'ACTIVE';

  -- اللقطة تُفسِّر النتيجة لاحقاً بلا الاعتماد على تهيئة ذلك اليوم.
  v_snapshot := jsonb_build_object(
    'closed_at', now(),
    'scheme_version_id', v_cycle.scheme_version_id,
    'enrollments', (select count(*) from public.installation_enrollments),
    'entitlements', (select count(*) from public.installation_entitlements),
    'paid_items', (select count(*) from public.installation_payment_batch_items i
                   join public.installation_payment_batches b on b.id = i.batch_id
                   where b.cycle_id = p_cycle_id and i.status = 'PAID'),
    'posted_amount', public.installation_cycle_posted_amount(p_cycle_id),
    'active_holds', v_open_holds,
    'stage_distribution', coalesce((
      select jsonb_object_agg(x.stage, x.n) from (
        select current_stage_code as stage, count(*) as n
        from public.installation_enrollments group by current_stage_code) x), '{}'::jsonb)
  );

  update public.installation_cycles
  set status = 'CLOSED', closed_by = v_actor, closed_at = now(), snapshot = v_snapshot
  where id = p_cycle_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id,
    after_data, request_id, extra)
  values (v_actor, 'installation.cycle.closed', 'status', v_cycle.status, 'CLOSED',
    'installation_cycle', p_cycle_id, v_snapshot, p_request_id, coalesce(p_reason, ''));

  return jsonb_build_object('replayed', false, 'cycle_id', p_cycle_id, 'snapshot', v_snapshot);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. إعادة فتح دورة أجور التنصيب.
--
-- المال المُرحَّل يمنع الفتح. هذا ليس تشدّداً: الفتح يعني إمكان تغيير نتيجة
-- بُنِي عليها دفع، وذلك إعادة كتابة لتاريخ مالي. التصحيح والعكس يفعلان
-- المطلوب دون هذا الضرر.
-- ---------------------------------------------------------------------------

create or replace function public.reopen_installation_cycle(
  p_cycle_id uuid, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_cycle public.installation_cycles%rowtype;
  v_posted bigint;
begin
  perform public.require_capability('cycle.reopen');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A reopen reason is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.installation_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Installation cycle was not found' using errcode = 'P0002';
  end if;
  if v_cycle.status <> 'CLOSED' then
    raise exception 'Only a closed cycle can be reopened' using errcode = '42501';
  end if;

  v_posted := public.installation_cycle_posted_amount(p_cycle_id);
  if v_posted <> 0 then
    raise exception 'The cycle carries posted money (%); use correction or reversal instead',
      v_posted using errcode = '42501';
  end if;

  update public.installation_cycles
  set status = 'UNDER_REVIEW', reopened_by = v_actor, reopened_at = now(),
      reopen_reason = p_reason
  where id = p_cycle_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id,
    before_data, request_id, extra)
  values (v_actor, 'installation.cycle.reopened', 'status', 'CLOSED', 'UNDER_REVIEW',
    'installation_cycle', p_cycle_id, v_cycle.snapshot, p_request_id, p_reason);

  -- اللقطة تبقى: هي دليل ما كانت عليه الدورة عند الإقفال.
  return jsonb_build_object('replayed', false, 'cycle_id', p_cycle_id,
                            'previous_snapshot_retained', v_cycle.snapshot is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. إقفال دورة العمولة وإعادة فتحها.
-- ---------------------------------------------------------------------------

create or replace function public.close_commission_cycle(
  p_cycle_id uuid, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
begin
  perform public.require_capability('commission.manage_cycle');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  if v_cycle.status = 'CLOSED' then
    raise exception 'The cycle is already closed' using errcode = '42501';
  end if;
  -- لا تُقفل دورة لم تُعتمد: الإقفال يفترض نتيجة نهائية.
  if v_cycle.finalized_at is null then
    raise exception 'Only a finalized cycle can be closed' using errcode = '42501';
  end if;

  update public.commission_cycles
  set status = 'CLOSED', closed_by = v_actor, closed_at = now()
  where id = p_cycle_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.cycle.closed', 'status', v_cycle.status, 'CLOSED',
    'commission_cycle', p_cycle_id, p_request_id, coalesce(p_reason, ''));

  return jsonb_build_object('replayed', false, 'cycle_id', p_cycle_id,
    'posted_amount', public.commission_cycle_posted_amount(p_cycle_id));
end;
$$;

create or replace function public.reopen_commission_cycle(
  p_cycle_id uuid, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_posted bigint;
begin
  perform public.require_capability('commission.reopen');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A reopen reason is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  if v_cycle.status not in ('FINALIZED', 'CLOSED') then
    raise exception 'Only a finalized or closed cycle can be reopened' using errcode = '42501';
  end if;

  v_posted := public.commission_cycle_posted_amount(p_cycle_id);
  if v_posted <> 0 then
    raise exception 'The cycle carries posted money (%); use correction or reversal instead',
      v_posted using errcode = '42501';
  end if;

  -- اللقطات المعتمدة تبقى كما هي؛ الفتح يسمح بحساب جديد ولا يمحو القديم.
  -- ولهذا تُفصل اللقطة عن الدورة: الدليل يبقى ولو تغيّر ما بُني عليه.
  update public.commission_cycles
  set status = 'UNDER_REVIEW', reopened_by = v_actor, reopened_at = now(),
      reopen_reason = p_reason, finalized_by = null, finalized_at = null
  where id = p_cycle_id;

  update public.commission_event_entitlements
  set status = 'PROJECTED' where cycle_id = p_cycle_id and status = 'FINAL';

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.cycle.reopened', 'status', v_cycle.status, 'UNDER_REVIEW',
    'commission_cycle', p_cycle_id, p_request_id, p_reason);

  return jsonb_build_object('replayed', false, 'cycle_id', p_cycle_id,
    'finalized_snapshots_retained',
    (select count(*) from public.commission_cycle_snapshots
     where cycle_id = p_cycle_id and finalized_at is not null));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. مراجعة استثناء العمولة.
-- ---------------------------------------------------------------------------

create or replace function public.resolve_commission_exception(
  p_exception_id uuid, p_status text, p_note text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.commission_exceptions%rowtype;
begin
  perform public.require_capability('commission.review_exception');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_status not in ('RESOLVED', 'WAIVED') then
    raise exception 'status must be RESOLVED or WAIVED' using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'A resolution note is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true);
  end if;

  update public.commission_exceptions
  set status = p_status, resolved_by = v_actor, resolved_at = now(), resolution_note = p_note
  where id = p_exception_id and status = 'OPEN'
  returning * into v_row;
  if not found then
    raise exception 'No open exception was found' using errcode = 'P0002';
  end if;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id,
    after_data, request_id, extra)
  values (v_actor, 'commission.exception.resolved', v_row.reason_code, 'OPEN', p_status,
    'commission_exception', p_exception_id, to_jsonb(v_row), p_request_id, p_note);

  return jsonb_build_object('replayed', false, 'exception_id', p_exception_id,
                            'status', p_status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. الملف المالي للوكيل — قراءة موحّدة للمجالين دون دمج قاعدتيهما.
-- ---------------------------------------------------------------------------

create or replace function public.agent_financial_profile(p_agent_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'agent', (select jsonb_build_object('id', a.id, 'code', a.code, 'name', a.official_name,
                                        'status', a.status, 'zone', a.zone)
              from public.agents a where a.id = p_agent_id),
    'aliases', coalesce((select jsonb_agg(al.alias order by al.alias)
                         from public.agent_aliases al where al.agent_id = p_agent_id), '[]'::jsonb),
    'fdts', coalesce((select jsonb_agg(f.code order by f.code)
                      from public.fdts f where f.agent_id = p_agent_id), '[]'::jsonb),
    'commission_cycles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cycle', c.name, 'status', c.status, 'scope_type', s.scope_type,
        'scope_id', s.scope_id, 'zone', s.zone, 'tier', s.tier_code,
        'unique_activated_subscribers', s.unique_activated_subscribers,
        'qualifying_events', s.qualifying_event_count,
        'package_breakdown', s.package_breakdown,
        'gross_commission', s.gross_commission,
        'finalized_at', s.finalized_at)
        order by c.period_start desc)
      from public.commission_cycle_snapshots s
      join public.commission_cycles c on c.id = s.cycle_id
      where s.scope_id = p_agent_id::text
         or s.scope_id in (select f.code from public.fdts f where f.agent_id = p_agent_id)
    ), '[]'::jsonb),
    -- عدد المشتركين يُقرأ من الصفوف نفسها؛ وتجميعه من المجموعات كان سيعطي
    -- عدد المراحل المميّزة لا عدد المشتركين.
    'installation', jsonb_build_object(
      'subscribers', (select count(*) from public.installation_enrollments
                      where effective_agent_id = p_agent_id),
      'stage_distribution', coalesce((
        select jsonb_object_agg(e.current_stage_code, e.n)
        from (select current_stage_code, count(*) as n
              from public.installation_enrollments
              where effective_agent_id = p_agent_id
              group by current_stage_code) e), '{}'::jsonb)),
    'ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'domain', l.domain, 'type', l.txn_type, 'amount', l.amount,
        'direction', l.direction, 'month', l.month_key, 'reason', l.reason)
        order by l.created_at desc)
      from public.financial_ledger l
      where l.agent_name = (select official_name from public.agents where id = p_agent_id)
    ), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------------
-- 7. الصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.installation_cycle_posted_amount(uuid)',
    'public.commission_cycle_posted_amount(uuid)',
    'public.close_installation_cycle(uuid, text, uuid)',
    'public.reopen_installation_cycle(uuid, text, uuid)',
    'public.close_commission_cycle(uuid, text, uuid)',
    'public.reopen_commission_cycle(uuid, text, uuid)',
    'public.resolve_commission_exception(uuid, text, text, uuid)',
    'public.agent_financial_profile(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
