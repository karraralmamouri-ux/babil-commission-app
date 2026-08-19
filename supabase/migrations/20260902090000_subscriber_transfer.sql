-- ---------------------------------------------------------------------------
-- نقل عائدية مشترك — من تاريخٍ فصاعداً، لا بأثر رجعي
--
-- النقل عمليةٌ مؤرَّخة لا استبدالُ حقل. المشترك الذي انتقل من الشركة إلى وكيل
-- في ١٦ آب كان للشركة في ١٠ آب ويبقى كذلك إلى الأبد: حدثُ العاشر يُحلّ
-- بعائدية العاشر. لهذا لا تكتب هذه المهاجرة على أيّ صفٍّ مالي قائم، ولا
-- تُغيّر عمولةً محسوبة، ولا تلمس تسجيل تنصيبٍ جارٍ.
--
-- وثلاثة أشياء يمتنع عنها النقل صراحةً:
--
--   ١. لا نقل إلى داخل دورةٍ محسومة. الدورة التي اعتُمدت أو دُفعت صارت
--      واقعاً محاسبياً؛ تحريك العائدية إلى داخلها يُعيد كتابة مالٍ مصروف.
--
--   ٢. لا نقل تلقائي لأجور التنصيب. المشترك في منتصف مراحل P1..P4 عند
--      وكيلٍ نفّذ بعضها بالفعل؛ من يستحق بقيّة المراحل سؤالٌ تجاري لا
--      تقني، فيُرفع NEEDS_BUSINESS_DECISION ولا يُخمَّن جواب.
--
--   ٣. لا تغيير لاسم الأب. النقل يُبدّل من يستحق، لا ما كُتب في المصدر.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. هل يقع هذا التاريخ داخل دورة محسومة؟
-- ---------------------------------------------------------------------------

create or replace function public.finalized_cycle_at(p_at timestamptz)
returns table (cycle_id uuid, cycle_name text, cycle_status text)
language sql
stable
security definer
set search_path = ''
as $fn$
  select c.id, c.name, c.status
  from public.commission_cycles c
  where c.status in ('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED')
    and p_at >= public.cycle_window_start(c.period_start)
    and p_at <  public.cycle_window_end(c.period_end)
  order by c.period_start desc
  limit 1;
$fn$;

revoke execute on function public.finalized_cycle_at(timestamptz) from public, anon;
grant execute on function public.finalized_cycle_at(timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. ما الذي سيتغيّر — وما الذي لن يتغيّر
--
-- تُقرأ قبل النقل. تقول بالأرقام: كم حدثاً يبقى عند المالك السابق، وكم
-- ينتقل، وهل هناك تنصيبٌ جارٍ يجعل السؤال تجارياً.
-- ---------------------------------------------------------------------------

create or replace function public.transfer_preview(
  p_username_key text,
  p_ownership text,
  p_agent_id uuid default null,
  p_effective_from timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key   text := lower(btrim(coalesce(p_username_key, '')));
  v_at    timestamptz := coalesce(p_effective_from, now());
  v_cur   record;
  v_enr   record;
  v_fin   record;
  v_paid  bigint;
  v_block jsonb := 'null'::jsonb;
  v_decision jsonb := 'null'::jsonb;
begin
  perform public.require_capability('subscriber.correct_attribution');

  if v_key = '' then
    raise exception 'Subscriber key is required' using errcode = '22023';
  end if;

  select * into v_cur from public.subscriber_ownership_at(v_key, v_at);

  select * into v_fin from public.finalized_cycle_at(v_at);
  if v_fin.cycle_id is not null then
    v_block := jsonb_build_object(
      'code', 'FINALIZED_CYCLE',
      'cycle_id', v_fin.cycle_id,
      'cycle_name', v_fin.cycle_name,
      'cycle_status', v_fin.cycle_status);
  end if;

  -- تسجيل التنصيب: من نفّذ المراحل حتى الآن، وكم قُبض.
  select e.subscriber_id, e.current_stage_code, e.status, e.effective_agent_id,
         e.agent_name_at_enrollment
    into v_enr
  from public.installation_enrollments e
  join public.installation_subscribers s on s.subscriber_id = e.subscriber_id
  where lower(btrim(s.subscriber_key)) = v_key
     or lower(btrim(s.subscriber_id)) = v_key
  limit 1;

  if v_enr.subscriber_id is not null then
    select coalesce(sum(h.amount), 0)::bigint into v_paid
    from public.installation_payment_history h
    join public.installation_subscribers s on s.id = h.subscriber_uuid
    where s.subscriber_id = v_enr.subscriber_id;

    -- مرحلةٌ جارية عند وكيلٍ يختلف عن المالك الجديد: السؤال تجاري.
    if coalesce(v_enr.current_stage_code, 'UNKNOWN') <> 'DONE'
       and v_enr.effective_agent_id is distinct from p_agent_id then
      v_decision := jsonb_build_object(
        'code', 'NEEDS_BUSINESS_DECISION',
        'subject', 'INSTALLATION_ENTITLEMENT',
        'stage', v_enr.current_stage_code,
        'enrolled_agent_id', v_enr.effective_agent_id,
        'enrolled_agent_name', v_enr.agent_name_at_enrollment,
        'paid_so_far', coalesce(v_paid, 0),
        -- لا جواب مقترح. الاختيار بين طرفين حقيقيين، وكلاهما مسنود.
        'question', 'من يستحق مراحل التنصيب المتبقّية بعد النقل؟');
    end if;
  end if;

  return jsonb_build_object(
    'username_key', v_key,
    'effective_from', v_at,
    'current', case when v_cur.ownership_type is null then null else jsonb_build_object(
      'ownership_type', v_cur.ownership_type,
      'agent_id', v_cur.agent_id) end,
    'target', jsonb_build_object('ownership_type', p_ownership, 'agent_id', p_agent_id),

    -- ما قبل الحدّ يبقى كما هو. هذا هو معنى «لا أثر رجعي».
    'events_before', (
      select count(*) from public.saas_activation_events e
      where e.username_key = v_key and e.event_created_at < v_at),
    'events_after', (
      select count(*) from public.saas_activation_events e
      where e.username_key = v_key and e.event_created_at >= v_at),

    'installation', case when v_enr.subscriber_id is null then null else jsonb_build_object(
      'subscriber_id', v_enr.subscriber_id,
      'stage', v_enr.current_stage_code,
      'status', v_enr.status,
      'enrolled_agent_id', v_enr.effective_agent_id,
      'enrolled_agent_name', v_enr.agent_name_at_enrollment,
      'paid_so_far', coalesce(v_paid, 0),
      -- صريحة: النقل لا يحرّك هذا الصفّ.
      'moves_with_transfer', false) end,

    'blocked_by', v_block,
    'business_decision', v_decision);
end;
$fn$;

revoke execute on function public.transfer_preview(text,text,uuid,timestamptz) from public, anon;
grant execute on function public.transfer_preview(text,text,uuid,timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. تنفيذ النقل
-- ---------------------------------------------------------------------------

create or replace function public.transfer_subscriber(
  p_username_key text,
  p_ownership text,
  p_agent_id uuid default null,
  p_effective_from timestamptz default null,
  p_company_parent text default null,
  p_reason text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_key   text := lower(btrim(coalesce(p_username_key, '')));
  v_at    timestamptz := coalesce(p_effective_from, now());
  v_own   text := public.normalize_ownership_type(p_ownership);
  v_fin   record;
  v_prev  record;
  v_pre   jsonb;
begin
  perform public.require_capability('subscriber.correct_attribution');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if v_key = '' then
    raise exception 'Subscriber key is required' using errcode = '22023';
  end if;
  if p_ownership not in ('RESELLER', 'DIRECT_COMPANY', 'NEEDS_REVIEW') then
    raise exception 'Ownership must be RESELLER, DIRECT_COMPANY or NEEDS_REVIEW'
      using errcode = '22023';
  end if;
  if p_ownership = 'RESELLER' and p_agent_id is null then
    raise exception 'A reseller transfer needs an agent' using errcode = '22023';
  end if;
  if p_ownership <> 'RESELLER' and p_agent_id is not null then
    raise exception 'Only a reseller transfer carries an agent' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A transfer must state its reason' using errcode = '22023';
  end if;

  -- تكرار الطلب نفسه لا يفتح فترةً ثانية.
  if exists (select 1 from public.subscriber_ownership where request_id = p_request_id) then
    return jsonb_build_object('username_key', v_key, 'idempotent', true);
  end if;

  -- لا كتابة داخل دورة محسومة: المال المصروف لا يُعاد حسابه.
  select * into v_fin from public.finalized_cycle_at(v_at);
  if v_fin.cycle_id is not null then
    raise exception 'Cannot transfer into finalized cycle % (%)', v_fin.cycle_name, v_fin.cycle_status
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('subscriber:' || v_key));

  -- فترةٌ لاحقة موجودة أصلاً تجعل الترتيب ملتبساً؛ يُرفض بدل أن يُخمَّن.
  if exists (
    select 1 from public.subscriber_ownership o
    where o.username_key = v_key and o.effective_from >= v_at) then
    raise exception 'A later ownership period already exists for this subscriber'
      using errcode = '22023';
  end if;

  select * into v_prev
  from public.subscriber_ownership o
  where o.username_key = v_key and o.effective_to is null
  order by o.effective_from desc
  limit 1;

  if v_prev.id is not null then
    if v_prev.effective_from >= v_at then
      raise exception 'Transfer must start after the current period begins'
        using errcode = '22023';
    end if;
    -- الفترة السابقة تُغلق عند الحدّ، ولا تُحذف: التاريخ يبقى مقروءاً.
    update public.subscriber_ownership set effective_to = v_at where id = v_prev.id;
  end if;

  insert into public.subscriber_ownership
    (username_key, ownership_type, agent_id, effective_from, effective_to,
     reason, performed_by, request_id, company_parent)
  values
    (v_key, v_own, p_agent_id, v_at, null,
     btrim(p_reason), v_actor, p_request_id,
     -- الاسم كما ورد. النقل لا يعيد التسمية.
     nullif(btrim(coalesce(p_company_parent, '')), ''));

  -- entity_id هنا uuid، ومفتاح المشترك نصّ؛ فيُحمل في extra بدل أن يُقحَم.
  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (
    v_actor, 'subscriber.ownership.transferred', 'ownership_type',
    coalesce(v_prev.ownership_type, 'NONE'), v_own, 'subscriber', p_request_id,
    'subscriber=' || v_key || ' from=' || v_at::text
      || coalesce(' agent=' || p_agent_id::text, '')
      || ' reason=' || btrim(p_reason));

  -- أجور التنصيب لا تُنقل هنا بحال. إن كان هناك ما يُحسم، يُرفع سؤالاً.
  v_pre := public.transfer_preview(v_key, p_ownership, p_agent_id, v_at);

  return jsonb_build_object(
    'username_key', v_key,
    'idempotent', false,
    'ownership_before', coalesce(v_prev.ownership_type, null),
    'ownership_after', v_own,
    'effective_from', v_at,
    'installation_moved', false,
    'business_decision', v_pre -> 'business_decision');
end;
$fn$;

revoke execute on function public.transfer_subscriber(text,text,uuid,timestamptz,text,text,uuid) from public, anon;
grant execute on function public.transfer_subscriber(text,text,uuid,timestamptz,text,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. القرارات التجارية المعلّقة
--
-- مشتركٌ نُقل وتنصيبُه ما زال جارياً عند وكيلٍ آخر. لا يُحسم آلياً، ويُعرض
-- في مركز العمل حتى يحسمه إنسان.
-- ---------------------------------------------------------------------------

create or replace function public.pending_business_decisions(
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
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with current_owner as (
    select distinct on (o.username_key)
      o.username_key, o.ownership_type, o.agent_id, o.effective_from
    from public.subscriber_ownership o
    where o.effective_to is null
    order by o.username_key, o.effective_from desc
  ),
  open_install as (
    select s.subscriber_id, s.subscriber_key, e.current_stage_code, e.status,
           e.effective_agent_id, e.agent_name_at_enrollment
    from public.installation_enrollments e
    join public.installation_subscribers s on s.subscriber_id = e.subscriber_id
    where coalesce(e.current_stage_code, 'UNKNOWN') <> 'DONE'
  ),
  conflicted as (
    select
      oi.subscriber_id,
      oi.current_stage_code as stage,
      oi.effective_agent_id as enrolled_agent_id,
      oi.agent_name_at_enrollment as enrolled_agent_name,
      co.ownership_type as owner_type,
      co.agent_id as owner_agent_id,
      ag.official_name as owner_agent_name,
      co.effective_from as owned_since,
      coalesce((
        select sum(h.amount)::bigint from public.installation_payment_history h
        join public.installation_subscribers s2 on s2.id = h.subscriber_uuid
        where s2.subscriber_id = oi.subscriber_id), 0) as paid_so_far
    from open_install oi
    join current_owner co
      on co.username_key = lower(btrim(oi.subscriber_key))
      or co.username_key = lower(btrim(oi.subscriber_id))
    left join public.agents ag on ag.id = co.agent_id
    where oi.effective_agent_id is distinct from co.agent_id
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select c.* from conflicted c
      order by c.paid_so_far desc, c.subscriber_id
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from conflicted;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.pending_business_decisions(integer,integer) from public, anon;
grant execute on function public.pending_business_decisions(integer,integer) to authenticated;

-- القراءة بالمفتاح والفترة المفتوحة معاً في كل استدعاء.
create index if not exists subscriber_ownership_open_idx
  on public.subscriber_ownership (username_key, effective_from desc)
  where effective_to is null;

commit;
