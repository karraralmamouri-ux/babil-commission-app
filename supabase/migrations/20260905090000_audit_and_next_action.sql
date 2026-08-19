-- ---------------------------------------------------------------------------
-- سجلّ التدقيق، والإجراء التالي
--
-- التدقيق: الجدول موجود ويُكتب فيه، وليس له شاشة تُقرأ. سجلٌّ لا يُقرأ لا
-- يردع ولا يُطمئن. هنا صفحةٌ مُصفّاة عليه، بأسماء الفاعلين لا بمعرّفاتهم.
--
-- الإجراء التالي: ليس قاعدةً مالية جديدة بل قراءةٌ لحالةٍ قائمة. يقول أين
-- يقف هذا المشترك الآن وأيّ شاشةٍ تحسمه — ولا يحسب مبلغاً ولا يقرّر استحقاقاً.
-- ترتيبه بالحجب: ما يمنع الصرف أوّلاً، ثم ما ينتظر تدقيقاً، ثم ما هو جاهز.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.page_audit_logs(
  p_action text default null,
  p_actor uuid default null,
  p_entity text default null,
  p_search text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
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
  perform public.require_capability('audit.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select a.id, a.created_at, a.action, a.field, a.old_value, a.new_value,
           a.entity_type, a.entity_id, a.extra, a.actor_id, a.request_id,
           p.email as actor_email, p.full_name as actor_name
    from public.audit_logs a
    left join public.profiles p on p.id = a.actor_id
    where (p_action is null or a.action = p_action)
      and (p_actor  is null or a.actor_id = p_actor)
      and (p_entity is null or a.entity_type = p_entity)
      and (p_from   is null or a.created_at >= p_from)
      and (p_to     is null or a.created_at <  p_to)
      and (p_search is null or btrim(p_search) = ''
           or a.extra ilike '%' || p_search || '%'
           or a.action ilike '%' || p_search || '%'
           or a.new_value ilike '%' || p_search || '%'
           or p.email ilike '%' || p_search || '%')
  )
  -- الإجمالي على المجموعة كلها فلا تُخفيه صفحةٌ فارغة.
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k
      order by k.created_at desc, k.id
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_audit_logs(text,uuid,text,text,timestamptz,timestamptz,integer,integer)
  from public, anon;
grant execute on function public.page_audit_logs(text,uuid,text,text,timestamptz,timestamptz,integer,integer)
  to authenticated;

-- الأفعال المتاحة للتصفية تُقرأ من السجلّ نفسه، فلا قائمة مثبَّتة تتقادم.
create or replace function public.audit_facets()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'actions', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select a.action as value, count(*) as n
        from public.audit_logs a group by 1 order by 2 desc limit 40) x), '[]'::jsonb),
    'actors', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select a.actor_id as value, coalesce(p.email, '—') as label, count(*) as n
        from public.audit_logs a
        left join public.profiles p on p.id = a.actor_id
        where a.actor_id is not null
        group by 1, 2 order by 3 desc limit 40) x), '[]'::jsonb),
    'total', (select count(*) from public.audit_logs))
  where public.has_capability('audit.view');
$fn$;

revoke execute on function public.audit_facets() from public, anon;
grant execute on function public.audit_facets() to authenticated;

create index if not exists audit_logs_created_idx on public.audit_logs (created_at desc);
create index if not exists audit_logs_action_idx on public.audit_logs (action);

-- ---------------------------------------------------------------------------
-- الإجراء التالي لمشترك
--
-- قراءةٌ لا حكم. ترتيب الأولوية هو ترتيب الحجب المالي: ما يمنع الصرف قبل ما
-- ينتظره.
-- ---------------------------------------------------------------------------

create or replace function public.subscriber_next_action(p_subscriber_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p_subscriber_id, ''));
  v_key    text := lower(v_id);
  v_holds  integer;
  v_own    text;
  v_parent text;
  v_stage  text;
  v_status text;
  v_agent  uuid;
  v_enr_agent uuid;
  v_due    bigint;
  v_pending integer;
begin
  perform public.require_capability('installation.view');

  if v_id = '' then
    raise exception 'Subscriber id is required' using errcode = '22023';
  end if;

  select count(*) into v_holds
  from public.installation_holds h
  where h.subscriber_id = v_id and h.status = 'ACTIVE';

  select e.current_stage_code, e.status, e.effective_agent_id
    into v_stage, v_status, v_enr_agent
  from public.installation_enrollments e
  where e.subscriber_id = v_id
  limit 1;

  select o.ownership_type, o.agent_id into v_own, v_agent
  from public.subscriber_ownership_at(v_key, now()) o;

  -- بلا فترةٍ مسجّلة تُقرأ العائدية من أب المصدر.
  if v_own is null then
    select e.raw_parent into v_parent
    from public.saas_activation_events e
    where e.username_key = v_key and e.raw_parent is not null
    order by e.event_created_at desc
    limit 1;
    v_own := public.parent_ownership_type(v_parent);
  end if;

  select coalesce(sum(t.amount) filter (where t.payment_status <> 'paid'), 0),
         count(*) filter (where t.invoice_status = 'pending')
    into v_due, v_pending
  from public.installation_entitlements t
  where t.subscriber_id = v_id;

  return jsonb_build_object(
    'subscriber_id', v_id,
    'ownership', v_own,
    'stage', v_stage,
    'active_holds', v_holds,
    'due', v_due,
    'pending_invoices', v_pending,
    'action', case
      -- ١. الإيقاف يمنع كل ما بعده.
      when v_holds > 0 then jsonb_build_object(
        'code', 'RESOLVE_HOLD', 'label', 'عالِج الإيقاف الفعّال',
        'why', 'لا يُصرف شيء لهذا المشترك ما دام الإيقاف قائماً',
        'path', '/installation/holds', 'tone', 'critical')
      -- ٢. عائدية غير محسومة تمنع نسبة المال إلى أحد.
      when v_own = 'NEEDS_REVIEW' then jsonb_build_object(
        'code', 'RESOLVE_OWNERSHIP', 'label', 'احسم العائدية',
        'why', 'لا يُعرف من يستحق قبل حسم عائدية الأب',
        'path', '/master/parents', 'tone', 'warning')
      -- ٣. نقلٌ وتنصيبٌ جارٍ عند وكيلٍ آخر: سؤال تجاري لا تقني.
      when v_stage is not null and coalesce(v_stage, 'UNKNOWN') <> 'DONE'
           and v_enr_agent is distinct from v_agent then jsonb_build_object(
        'code', 'NEEDS_BUSINESS_DECISION', 'label', 'قرار تجاري معلّق',
        'why', 'التنصيب جارٍ عند وكيل غير المالك الحالي',
        'path', '/work', 'tone', 'warning')
      -- ٤. فاتورة تنتظر تدقيقاً.
      when v_pending > 0 then jsonb_build_object(
        'code', 'VERIFY_INVOICE', 'label', 'دقّق الفاتورة',
        'why', 'الاستحقاق لا يُصرف قبل تدقيق فاتورته',
        'path', '/installation/invoices', 'tone', 'info')
      -- ٥. مستحقٌّ جاهز.
      when v_due > 0 then jsonb_build_object(
        'code', 'READY_TO_PAY', 'label', 'جاهز للصرف',
        'why', 'لا حاجب قائم على هذا المشترك',
        'path', '/installation/ready', 'tone', 'success')
      else jsonb_build_object(
        'code', 'NONE', 'label', 'لا إجراء مطلوب',
        'why', 'لا حاجب ولا مستحق قائم', 'path', null, 'tone', 'neutral')
      end);
end;
$fn$;

revoke execute on function public.subscriber_next_action(text) from public, anon;
grant execute on function public.subscriber_next_action(text) to authenticated;

commit;
