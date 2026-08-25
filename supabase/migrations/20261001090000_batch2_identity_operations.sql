-- ---------------------------------------------------------------------------
-- الدفعة ٢ — عمليات الهوية: تشغيل المطابقة ومراجعتها من الواجهة.
--
-- bootstrap_subscriber_identities() كانت موجودة، صحيحة، ومسحوبة الصلاحية من
-- كل الأدوار — لا واجهة تناديها. هذه مهاجرة قراءة وتشغيل، لا محرّك جديد:
--
--   run_identity_bootstrap        غلافٌ يستدعي المحرّك القائم، بقدرة
--                                 subscriber.match الموجودة أصلاً وغير
--                                 المُستخدَمة من أي RPC، وبنفس نمط الإعادة
--                                 الآمنة (request_id) المتّبع في كل كتابة
--                                 مالية أخرى في هذا المشروع.
--   page_subscriber_identities    قراءةٌ مُصفَّحة لِما ينتجه المحرّك —
--                                 خصوصاً MATCHED/CONFLICT/UNMATCHED —
--                                 لمراجعة العملية لا لتخمين حالتها.
--
-- لا تعارض هوية يُحسم هنا تلقائياً. الحسم قرارٌ بشري خارج نطاق هذه الدفعة؛
-- هذه الشاشة تُظهر التعارض بدليله فقط.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.run_identity_bootstrap(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_result jsonb;
begin
  perform public.require_capability('subscriber.match');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;

  if found then
    if v_existing.action <> 'identity.bootstrap.run' then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;
    return jsonb_build_object('result', v_existing.after_data, 'replayed', true);
  end if;

  -- المحرّك نفسه بلا تعديل: يُدرج بـ on conflict do nothing، فتكرار
  -- الاستدعاء آمن من ناحيته هو أيضاً، لا فقط من ناحية غلاف request_id.
  v_result := public.bootstrap_subscriber_identities();

  insert into public.audit_logs (
    actor_id, action, entity_type, after_data, request_id
  ) values (
    v_actor, 'identity.bootstrap.run', 'subscriber_identities', v_result, p_request_id
  );

  return jsonb_build_object('result', v_result, 'replayed', false);
end;
$fn$;

revoke execute on function public.run_identity_bootstrap(uuid) from public, anon;
grant execute on function public.run_identity_bootstrap(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- مراجعة نتيجة المطابقة — مُصفَّحة، بقدرة القراءة نفسها.
-- ---------------------------------------------------------------------------

create or replace function public.page_subscriber_identities(
  p_status text default null,
  p_source_classification text default null,
  p_search text default null,
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
  perform public.require_capability('subscriber.match');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select
      i.id, i.installation_subscriber_id, i.saas_user_id, i.username, i.display_name,
      i.identity_status, i.match_method, i.match_evidence,
      i.source_classification, i.raw_parent, i.effective_agent_id,
      i.fdt_code, i.fat_code, i.port_code, i.created_at,
      ag.official_name as effective_agent_name,
      s.subscriber_id as installation_subscriber_key
    from public.subscriber_identities i
    left join public.agents ag on ag.id = i.effective_agent_id
    left join public.installation_subscribers s on s.id = i.installation_subscriber_id
    where (p_status is null or i.identity_status = p_status)
      and (p_source_classification is null or i.source_classification = p_source_classification)
      and (p_search is null or btrim(p_search) = ''
           or i.username ilike '%' || p_search || '%'
           or i.saas_user_id ilike '%' || p_search || '%'
           or i.raw_parent ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k
      -- التعارض أولاً: هو ما يحتاج قراراً بشرياً، لا الفرز الزمني وحده.
      order by (k.identity_status = 'CONFLICT') desc, k.created_at desc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_subscriber_identities(text,text,text,integer,integer)
  from public, anon;
grant execute on function public.page_subscriber_identities(text,text,text,integer,integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- مركز القرار: «تعارض هوية» كان يُشير إلى سجلّ المشتركين العام، لا إلى
-- التعارضات نفسها. تصحيحٌ لمسارٍ واحد فقط — بقية الدالّة حرفاً بحرف من
-- 20260926090000_decision_groups.sql.
-- ---------------------------------------------------------------------------

create or replace function public.action_center()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_cid   uuid;
  v_start date;
  v_end   date;
  v_doc   jsonb;
begin
  perform public.require_capability('report.view');

  select c.id, c.period_start, c.period_end into v_cid, v_start, v_end
  from public.commission_cycles c
  order by c.period_start desc
  limit 1;

  with
  parents as (
    select
      count(*)::bigint as decisions,
      coalesce(sum(p.subs), 0)::bigint as subscribers,
      coalesce(sum(p.events), 0)::bigint as events
    from (
      select e.raw_parent,
             count(distinct e.username_key) as subs,
             count(*) as events
      from public.saas_activation_events e
      where e.raw_parent is not null and btrim(e.raw_parent) <> ''
        and coalesce(e.canceled, false) = false
        and public.parent_ownership_type(e.raw_parent) = 'NEEDS_REVIEW'
      group by e.raw_parent) p
  ),
  invoices as (
    select count(*)::bigint as decisions,
           count(*)::bigint as subscribers,
           coalesce(sum(public.installation_amount_for_stage(st.current_stage)), 0)::bigint as amount
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1','P2','P3','P4')
      and not exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED')
  ),
  fdts as (
    select count(distinct e.fdt_code)::bigint as decisions,
           count(distinct x.subscriber_key)::bigint as subscribers,
           count(*)::bigint as events
    from public.commission_exceptions x
    left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    where x.status = 'OPEN' and x.reason_code = 'UNKNOWN_FDT'
  ),
  holds as (
    select count(*)::bigint as decisions,
           count(distinct h.subscriber_id)::bigint as subscribers
    from public.installation_holds h
    where public.hold_is_effective(h.status, h.permanence, h.expires_at)
  ),
  identities as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_identities i
    where i.identity_status = 'CONFLICT'
  ),
  classification as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_classifications c
    where c.classification = 'NEEDS_REVIEW'
  ),
  business as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.installation_enrollments e
    join public.installation_subscribers s on s.subscriber_id = e.subscriber_id
    join (
      select distinct on (o.username_key) o.username_key, o.agent_id
      from public.subscriber_ownership o
      where o.effective_to is null
      order by o.username_key, o.effective_from desc) co
      on co.username_key = lower(btrim(s.subscriber_key))
    where coalesce(e.current_stage_code, 'UNKNOWN') <> 'DONE'
      and e.effective_agent_id is distinct from co.agent_id
  ),
  ownership as (
    select count(distinct coalesce(x.raw_parent, '(بلا اسم مصدر)'))::bigint as decisions,
           count(distinct x.subscriber_key)::bigint as subscribers,
           count(*)::bigint as events,
           coalesce(sum(x.amount), 0)::bigint as amount
    from public.commission_event_entitlements x
    where x.cycle_id = v_cid and x.effective_agent_id is null
  ),
  historical as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.installation_subscribers s
    left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where st.current_stage is null
       or st.current_stage not in ('P1','P2','P3','P4','DONE')
  ),
  sources as (
    select count(*)::bigint as decisions,
           coalesce(sum(b.imported_row_count), 0)::bigint as events
    from public.saas_import_batches b
    where b.completeness_status = 'UNKNOWN'
  )
  select jsonb_build_object(
    'cycle_id', v_cid,
    'groups', jsonb_build_array(
      jsonb_build_object(
        'key', 'UNRESOLVED_OWNERSHIP', 'label', 'ملكية تحتاج حسم',
        'unit', 'اسم المصدر', 'role', 'إدارة البيانات المرجعية',
        'decisions', (select decisions from ownership),
        'subscribers', (select subscribers from ownership),
        'events', (select events from ownership),
        'amount', (select amount from ownership),
        'next_action', 'احسم عائدية اسم المصدر',
        'path', '/work/ownership'),

      jsonb_build_object(
        'key', 'HISTORICAL_UNRESOLVED', 'label', 'تحتاج حسم تاريخي',
        'unit', 'المشترك', 'role', 'المحاسبة',
        'decisions', (select decisions from historical),
        'subscribers', (select subscribers from historical),
        'events', null,
        'amount', null,
        'next_action', 'راجع سجلّه التاريخي',
        'path', '/work/historical'),

      jsonb_build_object(
        'key', 'UNKNOWN_PARENT', 'label', 'أب بلا حسم عائدية',
        'unit', 'الأب', 'role', 'إدارة البيانات المرجعية',
        'decisions', (select decisions from parents),
        'subscribers', (select subscribers from parents),
        'events', (select events from parents),
        'amount', null,
        'next_action', 'حدّد العائدية',
        'path', '/master/parents?ownership=NEEDS_REVIEW'),

      jsonb_build_object(
        'key', 'MISSING_INVOICE', 'label', 'فاتورة لم تُفحص',
        'unit', 'المشترك ومرحلته', 'role', 'المحاسبة',
        'decisions', (select decisions from invoices),
        'subscribers', (select subscribers from invoices),
        'events', null,
        'amount', (select amount from invoices),
        'next_action', 'دقّق الفاتورة',
        'path', '/installation/invoices?status=NOT_CHECKED'),

      jsonb_build_object(
        'key', 'UNKNOWN_FDT', 'label', 'كابينة غير معرّفة',
        'unit', 'الكابينة', 'role', 'العمليات',
        'decisions', (select decisions from fdts),
        'subscribers', (select subscribers from fdts),
        'events', (select events from fdts),
        'amount', null,
        'next_action', 'صنّف الكابينة',
        'path', '/exceptions?reason=UNKNOWN_FDT'),

      jsonb_build_object(
        'key', 'ACTIVE_HOLD', 'label', 'تعليق سارٍ',
        'unit', 'التعليق', 'role', 'العمليات',
        'decisions', (select decisions from holds),
        'subscribers', (select subscribers from holds),
        'events', null, 'amount', null,
        'next_action', 'راجِع الحجب',
        'path', '/installation/holds?status=EFFECTIVE'),

      jsonb_build_object(
        'key', 'IDENTITY_CONFLICT', 'label', 'تعارض هوية',
        'unit', 'المشترك', 'role', 'العمليات',
        'decisions', (select decisions from identities),
        'subscribers', (select subscribers from identities),
        'events', null, 'amount', null,
        'next_action', 'احسم المطابقة',
        -- الفارق الوحيد عن الأصل: كان يُشير إلى سجلّ المشتركين العام، وهو
        -- لا يُظهر التعارض نفسه ولا دليله. الآن يفتح المراجعة مباشرةً.
        'path', '/system/identities?status=CONFLICT'),

      jsonb_build_object(
        'key', 'CLASSIFICATION_REVIEW', 'label', 'تصنيف جِدّة يحتاج مراجعة',
        'unit', 'المشترك', 'role', 'العمليات',
        'decisions', (select decisions from classification),
        'subscribers', (select subscribers from classification),
        'events', null, 'amount', null,
        'next_action', 'راجِع شواهد التصنيف',
        'path', '/installation'),

      jsonb_build_object(
        'key', 'NEEDS_BUSINESS_DECISION', 'label', 'قرار تجاري معلّق',
        'unit', 'المشترك', 'role', 'الإدارة',
        'decisions', (select decisions from business),
        'subscribers', (select subscribers from business),
        'events', null, 'amount', null,
        'next_action', 'احسم استحقاق المراحل الباقية',
        'path', '/work'),

      jsonb_build_object(
        'key', 'SOURCE_INCOMPLETE', 'label', 'مصدر غير مكتمل',
        'unit', 'دفعة الاستيراد', 'role', 'العمليات',
        'decisions', (select decisions from sources),
        'subscribers', null,
        'events', (select events from sources),
        'amount', null,
        'next_action', 'أثبت تغطية الملف',
        'path', '/legacy')
    ))
  into v_doc;

  return v_doc;
end;
$fn$;

commit;
