-- ---------------------------------------------------------------------------
-- من مرشّح إلى استحقاق إلى دفعة
--
-- الحلقة الناقصة في السلسلة. المرشّح قراءةٌ من المتبقّي التاريخي، والاستحقاق
-- التزامٌ مسجَّل، والدفعة وحدة عمل. لم يكن ثمّة ما ينقل المرشّح إلى استحقاق،
-- فتقف السلسلة عند «جاهز» ولا تُكمل.
--
-- والتثبيت التزامٌ ماليّ لا قراءة: يُنشئ صفوفاً تقول «هذا مستحقّ». لذلك
-- يُشترط له ما يُشترط لقرارٍ مالي — صلاحية، ومعرّف طلب، وأثرٌ مُدقَّق — ولا
-- يُثبِّت إلا من اجتاز كل الفحوص. المحجوب بأيّ صنف يبقى خارجه.
--
-- ولا يُنشئ دفعاً: الاستحقاق يبقى غير مدفوع حتى يمرّ بالدفعة وتأكيدها.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.materialize_installation_entitlements(
  p_period text,
  p_reseller text default null,
  p_limit integer default 500,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_made  integer := 0;
  v_sum   bigint := 0;
begin
  perform public.require_capability('installation.enroll');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Period must be YYYY-MM' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id
               and action = 'installation.entitlements.materialized') then
    return jsonb_build_object('period', p_period, 'idempotent', true);
  end if;

  -- الجاهزون وحدهم: خلوٌّ من التعليق والفاتورة والحالة والهوية والعائدية.
  with ready as (
    select
      s.subscriber_id, s.reseller, s.fdt,
      st.remaining, st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      e.zone
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    left join public.installation_enrollments e on e.subscriber_id = s.subscriber_id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1','P2','P3','P4')
      and st.resolution = 'resolved'
      and st.payment_eligible
      and (p_reseller is null or s.reseller = p_reseller)
      and exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED')
      and not exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at))
      and not exists (
        select 1 from public.subscriber_identities si
        where si.username_key = lower(btrim(s.subscriber_id))
          and si.identity_status = 'CONFLICT')
      and public.subscriber_ownership_type(s.subscriber_id) = 'RESELLER'
      -- ولا استحقاق قائم لنفس (الفترة، المشترك، المرحلة).
      --
      -- الاستثناء كان يستبعد غير المدفوع وحده، فيصطدم بالمفتاح الفريد
      -- حين يكون القائم مدفوعاً — والمفتاح هو الثلاثي لا حالة الدفع.
      and not exists (
        select 1 from public.installation_entitlements t
        where t.period = p_period
          and t.subscriber_id = s.subscriber_id
          and t.stage = st.current_stage)
    order by s.subscriber_id
    limit least(greatest(coalesce(p_limit, 500), 1), 5000)
  )
  insert into public.installation_entitlements (
    period, subscriber_id, subscriber_name, reseller, zone, fdt,
    remaining, stage, amount, invoice_status, payment_status, created_by)
  select p_period, r.subscriber_id, r.subscriber_id, r.reseller, r.zone, r.fdt,
         r.remaining, r.stage, r.amount, 'approved', 'eligible', v_actor
  from ready r;

  get diagnostics v_made = row_count;

  select coalesce(sum(amount), 0) into v_sum
  from public.installation_entitlements
  where period = p_period and created_by = v_actor and payment_status = 'eligible';

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'installation.entitlements.materialized', 'count', '0', v_made::text,
    'installation_entitlement', p_request_id,
    'period=' || p_period || coalesce(' reseller=' || p_reseller, '')
      || ' created=' || v_made::text);

  return jsonb_build_object(
    'period', p_period, 'idempotent', false,
    'created', v_made, 'eligible_amount', v_sum);
end;
$fn$;

revoke execute on function public.materialize_installation_entitlements(text,text,integer,uuid)
  from public, anon;
grant execute on function public.materialize_installation_entitlements(text,text,integer,uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- إنشاء دفعة من استحقاقات جاهزة
--
-- إنشاءٌ لا دفع. الدفعة تولد DRAFT، وتحتاج تحقّقاً ثم تأكيداً بتاريخٍ وإشعار.
-- ---------------------------------------------------------------------------

create or replace function public.create_installation_batch(
  p_name text,
  p_reseller text default null,
  p_period text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_items integer := 0;
  v_sum   bigint := 0;
begin
  perform public.require_capability('payment.prepare');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A batch must be named' using errcode = '22023';
  end if;

  select id into v_id from public.installation_payment_batches
  where request_id = p_request_id;
  if found then
    return jsonb_build_object('batch_id', v_id, 'idempotent', true);
  end if;

  insert into public.installation_payment_batches (
    name, status, prepared_by, prepared_at, request_id)
  values (btrim(p_name), 'DRAFT', v_actor, now(), p_request_id)
  returning id into v_id;

  -- يُدرَج ما يجتاز التعريف المشترك للقابلية، لا ما يبدو جاهزاً في شاشة.
  with candidates as (
    select t.id, t.subscriber_id, t.reseller, t.stage, t.amount
    from public.installation_entitlements t
    where t.payment_status <> 'paid'
      and (p_reseller is null or t.reseller = p_reseller)
      and (p_period is null or t.period = p_period)
      and (public.installation_line_payable(t.id) ->> 'payable')::boolean
      and not exists (
        select 1 from public.installation_payment_batch_items i
        join public.installation_payment_batches b on b.id = i.batch_id
        where i.entitlement_id = t.id
          and b.status in ('DRAFT','VALIDATED','READY','PAID')
          and i.status <> 'SKIPPED')
    order by t.reseller, t.subscriber_id
  )
  insert into public.installation_payment_batch_items (
    batch_id, entitlement_id, subscriber_id, agent_name, stage_code, amount, status)
  select v_id, c.id, c.subscriber_id, c.reseller, c.stage, c.amount, 'PENDING'
  from candidates c;

  get diagnostics v_items = row_count;

  select coalesce(sum(amount), 0) into v_sum
  from public.installation_payment_batch_items where batch_id = v_id;

  update public.installation_payment_batches
  set item_count = v_items, total_amount = v_sum
  where id = v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.batch.created', 'item_count', '0', v_items::text,
    'installation_payment_batch', v_id, p_request_id,
    'name=' || btrim(p_name) || coalesce(' reseller=' || p_reseller, '')
      || ' amount=' || v_sum::text);

  return jsonb_build_object(
    'batch_id', v_id, 'idempotent', false,
    'items', v_items, 'amount', v_sum, 'status', 'DRAFT');
end;
$fn$;

revoke execute on function public.create_installation_batch(text,text,text,uuid) from public, anon;
grant execute on function public.create_installation_batch(text,text,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- قراءة الدفعات وتفصيلها
-- ---------------------------------------------------------------------------

create or replace function public.page_installation_batches(
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('payment.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select b.id, b.name, b.status, b.total_amount, b.item_count, b.blocked_count,
           b.prepared_at, pb.email as prepared_by_email,
           b.validated_at, b.posted_at, po.email as posted_by_email,
           b.payment_date, b.payment_ref, b.payment_note,
           b.cancelled_at, b.cancel_reason
    from public.installation_payment_batches b
    left join public.profiles pb on pb.id = b.prepared_by
    left join public.profiles po on po.id = b.posted_by
    where (p_status is null or b.status = p_status)
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.prepared_at desc nulls last
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_installation_batches(text,integer,integer) from public, anon;
grant execute on function public.page_installation_batches(text,integer,integer) to authenticated;

create or replace function public.installation_batch_detail(p_batch_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'batch', (
      select jsonb_build_object(
        'id', b.id, 'name', b.name, 'status', b.status,
        'total_amount', b.total_amount, 'item_count', b.item_count,
        'blocked_count', b.blocked_count,
        'prepared_at', b.prepared_at, 'prepared_by', pb.email,
        'validated_at', b.validated_at,
        'posted_at', b.posted_at, 'posted_by', po.email,
        'payment_date', b.payment_date, 'payment_ref', b.payment_ref,
        'payment_note', b.payment_note,
        'cancelled_at', b.cancelled_at, 'cancel_reason', b.cancel_reason)
      from public.installation_payment_batches b
      left join public.profiles pb on pb.id = b.prepared_by
      left join public.profiles po on po.id = b.posted_by
      where b.id = p_batch_id),

    -- السطر وحدة الحقيقة: مشترك + مرحلة + مبلغ، بحالته وسبب حجبه.
    'lines', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.status, x.subscriber_id) from (
        select i.id, i.subscriber_id, i.agent_name, i.stage_code, i.amount,
               i.status, i.blocked_reason, i.paid_at
        from public.installation_payment_batch_items i
        where i.batch_id = p_batch_id) x), '[]'::jsonb),

    'by_stage', coalesce((
      select jsonb_object_agg(y.stage_code, jsonb_build_object('n', y.n, 'amount', y.amt))
      from (select i.stage_code, count(*) as n, sum(i.amount) as amt
            from public.installation_payment_batch_items i
            where i.batch_id = p_batch_id group by i.stage_code) y), '{}'::jsonb),

    'by_reseller', coalesce((
      select jsonb_agg(to_jsonb(z)) from (
        select i.agent_name as reseller, count(*) as n, sum(i.amount) as amount,
               count(*) filter (where i.status = 'BLOCKED') as blocked
        from public.installation_payment_batch_items i
        where i.batch_id = p_batch_id
        group by i.agent_name order by sum(i.amount) desc) z), '[]'::jsonb))
  where public.has_capability('payment.view');
$fn$;

revoke execute on function public.installation_batch_detail(uuid) from public, anon;
grant execute on function public.installation_batch_detail(uuid) to authenticated;

-- إلغاء دفعة لم تُدفع.
create or replace function public.cancel_installation_batch(
  p_batch_id uuid,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_actor uuid := auth.uid(); v_status text;
begin
  perform public.require_capability('payment.prepare');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A cancellation must state its reason' using errcode = '22023';
  end if;

  select status into v_status from public.installation_payment_batches
  where id = p_batch_id for update;
  if not found then
    raise exception 'Batch not found' using errcode = '22023';
  end if;
  -- المدفوعة لا تُلغى: عكسُ المال يمرّ بالدفتر لا بحالة الدفعة.
  if v_status = 'PAID' then
    raise exception 'A paid batch cannot be cancelled; reverse it in the ledger'
      using errcode = '22023';
  end if;
  if v_status = 'CANCELLED' then
    return jsonb_build_object('batch_id', p_batch_id, 'idempotent', true);
  end if;

  update public.installation_payment_batches
  set status = 'CANCELLED', cancelled_by = v_actor, cancelled_at = now(),
      cancel_reason = btrim(p_reason)
  where id = p_batch_id;

  update public.installation_payment_batch_items
  set status = 'SKIPPED'
  where batch_id = p_batch_id and status <> 'PAID';

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.batch.cancelled', 'status', v_status, 'CANCELLED',
    'installation_payment_batch', p_batch_id, p_request_id, 'reason=' || btrim(p_reason));

  return jsonb_build_object('batch_id', p_batch_id, 'idempotent', false);
end;
$fn$;

revoke execute on function public.cancel_installation_batch(uuid,text,uuid) from public, anon;
grant execute on function public.cancel_installation_batch(uuid,text,uuid) to authenticated;

commit;
