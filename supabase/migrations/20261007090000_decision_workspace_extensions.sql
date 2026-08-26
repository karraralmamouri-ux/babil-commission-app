begin;

-- ---------------------------------------------------------------------------
-- PR-B1: مركز القرار يكتسب مجموعة الاستثناء اليدوي، ويُصحَّح مساران قائمان.
-- لا تغيير في أي حساب مالي أو صلاحية هنا — إعادة تعريف قراءة فقط.
-- ---------------------------------------------------------------------------

create or replace function public.action_center()
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $function$
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
  -- PR-B1: صفّ NEEDS_REVIEW/MANUAL_EXCEPTION يدخل CLASSIFICATION_REVIEW كما
  -- يشترط docs/product/manual-exception-intake-design.md صراحةً ("لا مسار
  -- أقل تدقيقاً")، ويبقى محسوباً هنا ما دام الاستثناء قيد المراجعة؛ يسقط من
  -- هذا العدّ فور حسمه عبر resolve_manual_exception_intake (التي لا تُعدِّل
  -- subscriber_classifications نفسها — سجلٌّ تراكميٌّ كغيره لا يُصحَّح بأثرٍ
  -- رجعي)، فلا يبقى شبحاً مُحتسَباً بعد إغلاقه.
  classification as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_classifications c
    where c.classification = 'NEEDS_REVIEW'
      and (
        c.reason_code is distinct from 'MANUAL_EXCEPTION'
        or exists (
          select 1 from public.manual_exception_intakes m
          where m.username_key = c.username_key and m.status = 'NEEDS_REVIEW')
      )
  ),
  -- الاستثناء اليدوي يكتسب أيضاً مجموعته المخصّصة في مركز القرار (مطلوبة
  -- صراحةً ضمن فئات Decision Workspace) لأن مراجعته تحتاج حقولاً لا تحملها
  -- CLASSIFICATION_REVIEW (نوع الاستثناء، فعل الحسم) — لا ازدواج سلطة، بل
  -- واجهتان لحقيقةٍ واحدة.
  manual_exception as (
    select count(*)::bigint as decisions,
           count(distinct username_key)::bigint as subscribers
    from public.manual_exception_intakes
    where status = 'NEEDS_REVIEW'
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
  ),
  -- D-14: دفعات دخلت مراجعةً بعد بياناتٍ متأخرة على فترةٍ كانت مكتملة.
  revalidation as (
    select count(*)::bigint as decisions,
           coalesce(sum(b.imported_row_count), 0)::bigint as events
    from public.saas_import_batches b
    where b.completeness_status = 'NEEDS_REVALIDATION'
  ),
  -- D-12/D-13: مرشّحون بانتظار تفعيلٍ مؤهّل انقضت مهلتهم بلا تجاوزٍ مدقَّق.
  -- المصدر الوحيد للتاريخ والحالة: installation_reference_dates() +
  -- grace_status_from_dates()، نفس الزوج الذي يستعمله installation_grace_status().
  -- لا يُعاد تنفيذ حساب اليوم الثلاثين هنا بأي شكل.
  grace_expired as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_classifications c
    cross join lateral public.installation_reference_dates(c.username_key) d
    where c.classification = 'NEEDS_REVIEW'
      and c.reason_code = 'NO_QUALIFYING_PAID_EVENT'
      and public.grace_status_from_dates(
            d.reference_at, d.qualifying_at,
            exists (select 1 from public.grace_period_overrides o where o.username_key = c.username_key))
          = 'GRACE_EXPIRED_REVIEW'
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
        'path', '/system/imports'),

      jsonb_build_object(
        'key', 'SOURCE_NEEDS_REVALIDATION', 'label', 'مصدر يحتاج إعادة تحقّق',
        'unit', 'دفعة الاستيراد', 'role', 'العمليات',
        'decisions', (select decisions from revalidation),
        'subscribers', null,
        'events', (select events from revalidation),
        'amount', null,
        'next_action', 'راجِع البيانات المتأخرة وأعد التصريح',
        'path', '/system/imports?completeness=NEEDS_REVALIDATION'),

      jsonb_build_object(
        'key', 'GRACE_EXPIRED_REVIEW', 'label', 'مهلة تفعيل منقضية',
        'unit', 'المشترك', 'role', 'العمليات',
        'decisions', (select decisions from grace_expired),
        'subscribers', (select subscribers from grace_expired),
        'events', null, 'amount', null,
        'next_action', 'راجِع أو جاوِز بسببٍ مُدقَّق',
        'path', '/installation/grace-queue'),

      jsonb_build_object(
        'key', 'MANUAL_EXCEPTION_REVIEW', 'label', 'مراجعة استثناء يدوي',
        'unit', 'المشترك', 'role', 'العمليات',
        'decisions', (select decisions from manual_exception),
        'subscribers', (select subscribers from manual_exception),
        'events', null, 'amount', null,
        'next_action', 'راجِع الاستثناء اليدوي',
        'path', '/installation/manual-exception')
    ))
  into v_doc;

  return v_doc;
end;
$function$;

-- ---------------------------------------------------------------------------
-- طابور مهلة التفعيل المنقضية — نسخة سطرية مُرقّمة من GRACE_EXPIRED_REVIEW،
-- بلا واجهة استهلاك حتى الآن. المصدر الوحيد للحالة يبقى installation_reference_dates()
-- + grace_status_from_dates()، ولا يُعاد حساب اليوم الثلاثين هنا بأي شكل.
-- تُصفَّى المرشّحون أولاً (classification + reason_code) قبل استدعاء الدالة
-- اللاحقة لكل صف، تماماً كما يفعل action_center() اليوم — لا استعلام غير مُصفّى
-- على كامل جدول التصنيفات.
-- ---------------------------------------------------------------------------

create or replace function public.page_installation_grace_queue(
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
declare
  v_rows jsonb;
  v_total bigint;
  v_lim   integer;
  v_off   integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with candidates as (
    select c.username_key
    from public.subscriber_classifications c
    where c.classification = 'NEEDS_REVIEW'
      and c.reason_code = 'NO_QUALIFYING_PAID_EVENT'
      and (btrim(coalesce(p_search, '')) = ''
           or c.username_key ilike '%' || btrim(p_search) || '%')
  ),
  dated as (
    select cd.username_key, d.reference_at, d.qualifying_at,
           exists (
             select 1 from public.grace_period_overrides o
             where o.username_key = cd.username_key
           ) as overridden
    from candidates cd
    cross join lateral public.installation_reference_dates(cd.username_key) d
  ),
  -- overridden يُستهلَك هنا فقط ليحدِّد الحالة — صفٌّ نجا إلى expired هو
  -- بالتعريف غير مُتجاوَز (لو كان لصار NEW_PENDING_ACTIVATION لا
  -- GRACE_EXPIRED_REVIEW)، فلا داعي لحمله عموداً في المخرَج النهائي.
  expired as (
    select dt.username_key, dt.reference_at, dt.qualifying_at
    from dated dt
    where public.grace_status_from_dates(dt.reference_at, dt.qualifying_at, dt.overridden)
          = 'GRACE_EXPIRED_REVIEW'
  ),
  total as (
    select count(*)::bigint as n from expired
  ),
  paged as (
    select
      e.username_key,
      i.installation_subscriber_id,
      i.display_name,
      i.username,
      e.reference_at,
      (e.reference_at::date + 30) as grace_deadline,
      (now()::date - (e.reference_at::date + 30))::integer as days_overdue
    from expired e
    -- username_key ليس فريداً على subscriber_identities (الفريد فعلاً saas_user_id
    -- و installation_subscriber_id فقط) — انضمامٌ مباشر قد يُكرّر المشترك في
    -- الصفحة. تُختار هويةٌ واحدة حتمياً: المطابقة أولاً ثم الأحدث تحديثاً.
    left join lateral (
      select ii.installation_subscriber_id, ii.display_name, ii.username
      from public.subscriber_identities ii
      where ii.username_key = e.username_key
      order by (ii.identity_status = 'MATCHED') desc, ii.updated_at desc, ii.id
      limit 1
    ) i on true
    order by e.reference_at asc, e.username_key asc
    limit v_lim offset v_off
  )
  select (select n from total),
         coalesce((select jsonb_agg(to_jsonb(p)) from paged p), '[]'::jsonb)
  into v_total, v_rows;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_installation_grace_queue(text, integer, integer) from public, anon;
grant execute on function public.page_installation_grace_queue(text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- نفس التصحيح على شاشة الاستهلاك الفعلية: استثناءٌ يدويٌّ محسوم لا يبقى
-- شبحاً في /work/classification. reason_code وحده لا يُستبعد — الاستثناء
-- الذي ما زال NEEDS_REVIEW في جدوله الخاص يبقى ظاهراً هنا كما يشترط التصميم.
-- ---------------------------------------------------------------------------

create or replace function public.product_classification_decisions(p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit); v_off := public.page_offset(p_offset);
  with kept as (
    select c.username_key, c.saas_user_id, c.reason_code, c.source_completeness,
      c.lifetime_activations_count, c.observed_event_count, c.qualifying_paid_event_count,
      c.evidence, c.evaluated_at, i.installation_subscriber_id
    from public.subscriber_classifications c
    left join public.subscriber_identities i on i.id = c.subscriber_identity_id
    where c.classification = 'NEEDS_REVIEW'
      and (
        c.reason_code is distinct from 'MANUAL_EXCEPTION'
        or exists (
          select 1 from public.manual_exception_intakes m
          where m.username_key = c.username_key and m.status = 'NEEDS_REVIEW')
      )
  )
  select count(*), coalesce((select jsonb_agg(to_jsonb(x)) from (select * from kept order by evaluated_at desc limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows from kept;
  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end $fn$;

commit;
