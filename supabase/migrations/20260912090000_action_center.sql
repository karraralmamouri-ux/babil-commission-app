-- ---------------------------------------------------------------------------
-- مركز العمل — كل ما ينتظر قراراً، بوحدة قراره
--
-- الشاشة السابقة كانت تجمع ثلاثة مصادر في الواجهة، فكل مصدرٍ يُقرأ وحده ولا
-- يُقارَن بغيره. هنا مصدرٌ واحد يقول لكل مجموعة: كم قراراً، وكم مشتركاً
-- يتأثّر، وكم حدثاً، وكم مالاً، ومن يحسمه، وأين.
--
-- والترتيب بالمال المتأثّر لا بعدد الصفوف: 22 أباً بلا حسم أثقل من 22,724
-- صفّ استثناء تحسمها كابيناتٌ معدودة. عرضُها بعدد الصفوف يقلب الأولوية.
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

revoke execute on function public.action_center() from public, anon;
grant execute on function public.action_center() to authenticated;

commit;
