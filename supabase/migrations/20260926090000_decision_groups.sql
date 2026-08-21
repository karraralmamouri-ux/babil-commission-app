-- ---------------------------------------------------------------------------
-- المرحلة ٣ — القرارات: الملكية المعلّقة والمشتركون بلا مرحلة
-- ---------------------------------------------------------------------------

begin;

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
  -- ١. أبٌ بلا حسم عائدية. وحدة القرار: الأب.
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
  -- ٢. فاتورة لم تُفحص. وحدة القرار: المشترك ومرحلته.
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
  -- ٣. كابينة غير معرّفة. وحدة القرار: الكابينة لا الصفّ.
  fdts as (
    select count(distinct e.fdt_code)::bigint as decisions,
           count(distinct x.subscriber_key)::bigint as subscribers,
           count(*)::bigint as events
    from public.commission_exceptions x
    left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    where x.status = 'OPEN' and x.reason_code = 'UNKNOWN_FDT'
  ),
  -- ٤. تعليق سارٍ. وحدة القرار: التعليق.
  holds as (
    select count(*)::bigint as decisions,
           count(distinct h.subscriber_id)::bigint as subscribers
    from public.installation_holds h
    where public.hold_is_effective(h.status, h.permanence, h.expires_at)
  ),
  -- ٥. تعارض هوية. وحدة القرار: المشترك.
  identities as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_identities i
    where i.identity_status = 'CONFLICT'
  ),
  -- ٦. تصنيف جِدّة يحتاج مراجعة. وحدة القرار: المشترك.
  classification as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_classifications c
    where c.classification = 'NEEDS_REVIEW'
  ),
  -- ٧. قرار تجاري معلّق بعد نقل عائدية. وحدة القرار: المشترك.
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
  -- ٩. ملكية تحتاج حسم. وحدة القرار: اسم المصدر لا الحدث.
  --
  -- أحداثٌ حُسبت في إجمالي الدورة ولا وكيل فعّال لها. المبلغ مستحقّ
  -- ومحسوب، ولا يظهر في مجموع أي وكيل — فيبدو الفرق بلا سبب. يُعرض قراراً
  -- قائماً بذاته بمبلغه، ولا يُوزَّع على أحد بلا دليل.
  ownership as (
    select count(distinct coalesce(x.raw_parent, '(بلا اسم مصدر)'))::bigint as decisions,
           count(distinct x.subscriber_key)::bigint as subscribers,
           count(*)::bigint as events,
           coalesce(sum(x.amount), 0)::bigint as amount
    from public.commission_event_entitlements x
    where x.cycle_id = v_cid and x.effective_agent_id is null
  ),
  -- ١٠. مشترك بلا مرحلة تاريخية. وحدة القرار: المشترك.
  --
  -- مشتركون لا يقعون في P1..P4 ولا DONE. لا يظهرون في أي مجموع مرحلة،
  -- فيختفون من الشاشة وهم قائمون في الجدول. يُعرضون ليُحسموا بدليل.
  historical as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.installation_subscribers s
    left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where st.current_stage is null
       or st.current_stage not in ('P1','P2','P3','P4','DONE')
  ),
  -- ٨. مصدر غير مكتمل. وحدة القرار: دفعة الاستيراد.
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
        'path', '/installation/subscribers'),

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

-- ---------------------------------------------------------------------------
-- أدلّة القرارين الجديدين
--
-- القرار لا يُتّخذ من عدد. يُعرض ما يكفي للحكم: من، وكم، وبأيّ دليل —
-- ولا يُقترح جواب.
-- ---------------------------------------------------------------------------

/** ملكية تحتاج حسم: الأحداث المحسوبة بلا وكيل فعّال، مجموعةً باسم المصدر. */
create or replace function public.unresolved_ownership_decisions(
  p_cycle_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_cycle uuid;
begin
  perform public.require_capability('commission.view');
  v_cycle := coalesce(p_cycle_id, public.current_commission_cycle_id());

  return jsonb_build_object(
    'cycle_id', v_cycle,
    'total_amount', (
      select coalesce(sum(amount), 0) from public.commission_event_entitlements
      where cycle_id = v_cycle and effective_agent_id is null),
    'groups', coalesce((
      select jsonb_agg(to_jsonb(g) order by g.amount desc)
      from (
        select coalesce(x.raw_parent, '(بلا اسم مصدر)') as source_name,
               count(*) as events,
               count(distinct x.subscriber_key) as subscribers,
               sum(x.amount) as amount,
               -- الدليل المتاح: هل لهذا الاسم اسمٌ بديل مسجَّل؟ وبأيّ حكم؟
               (select al.resolution from public.agent_aliases al
                where al.alias_key = lower(btrim(coalesce(x.raw_parent, '')))
                limit 1) as alias_resolution,
               (select ag.official_name from public.agent_aliases al
                join public.agents ag on ag.id = al.agent_id
                where al.alias_key = lower(btrim(coalesce(x.raw_parent, '')))
                limit 1) as alias_agent,
               -- أسماء مشابهة في المصدر: دليلٌ على خطأ إملائي محتمل، لا حكم.
               (select coalesce(jsonb_agg(distinct e2.raw_parent), '[]'::jsonb)
                from public.saas_activation_events e2
                where e2.raw_parent is not null
                  and e2.raw_parent <> x.raw_parent
                  and lower(btrim(e2.raw_parent)) like
                      '%' || substring(lower(btrim(coalesce(x.raw_parent,''))) from 1 for 5) || '%'
               ) as similar_source_names,
               jsonb_agg(jsonb_build_object(
                 'event_id', x.activation_event_id,
                 'subscriber', x.subscriber_key,
                 'package', x.package_code,
                 'fdt', x.fdt_code,
                 'zone', x.zone,
                 'event_at', x.event_at,
                 'amount', x.amount)) as events_detail
        from public.commission_event_entitlements x
        where x.cycle_id = v_cycle and x.effective_agent_id is null
        group by coalesce(x.raw_parent, '(بلا اسم مصدر)'), x.raw_parent) g), '[]'::jsonb));
end;
$fn$;

revoke execute on function public.unresolved_ownership_decisions(uuid) from public, anon;
grant execute on function public.unresolved_ownership_decisions(uuid) to authenticated;

/** مشتركون بلا مرحلة تاريخية، بأدلّتهم. */
create or replace function public.historical_unresolved_subscribers()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  perform public.require_capability('installation.view');

  return jsonb_build_object(
    'total', (
      select count(*) from public.installation_subscribers s
      left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
      where st.current_stage is null
         or st.current_stage not in ('P1','P2','P3','P4','DONE')),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.subscriber_id)
      from (
        select s.subscriber_id, s.reseller,
               st.remaining, st.received_total, st.total_amount,
               st.current_stage, st.resolution, st.payment_eligible,
               st.as_of_date, st.warnings,
               (select count(*) from public.installation_payment_history h
                where h.subscriber_uuid = s.id) as history_rows,
               (select coalesce(sum(h.amount), 0) from public.installation_payment_history h
                where h.subscriber_uuid = s.id) as history_paid,
               (select coalesce(jsonb_agg(jsonb_build_object(
                          'stage', h.stage, 'amount', h.amount, 'paid_at', h.payment_date)
                        order by h.stage), '[]'::jsonb)
                from public.installation_payment_history h
                where h.subscriber_uuid = s.id) as history
        from public.installation_subscribers s
        left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
        where st.current_stage is null
           or st.current_stage not in ('P1','P2','P3','P4','DONE')) r), '[]'::jsonb));
end;
$fn$;

revoke execute on function public.historical_unresolved_subscribers() from public, anon;
grant execute on function public.historical_unresolved_subscribers() to authenticated;

commit;
