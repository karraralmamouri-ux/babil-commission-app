begin;

-- ---------------------------------------------------------------------------
-- PR-B2 — جاهزية الحواجز المفتوحة (تجميعٌ إضافي فوق ما هو قائم، لا قاعدة مالية
-- جديدة ولا حسابٌ جديد)، ومسار Active/Resolved لطابور مهلة التفعيل المنقضية.
--
-- هذا الملف نُقِّح بعد مراجعةٍ مستقلة كشفت ثلاث علل معمارية في المسودة الأولى
-- — لم تُطبَّق هذه الهجرة على أي قاعدة بعد، فالتصحيح هنا تعديلٌ في مكانه، لا
-- هجرةٌ ثامنةٌ وسبعون:
--
--   1) نطاق الفترة: installation_cycle_pipeline(p_period) يستعمل v_period فقط
--      في عدّاد installation_entitlements. لا عمود فترة/شهر على أيٍّ من الجداول
--      الخمسة التي تُبنى منها الحواجز أدناه (saas_import_batches،
--      subscriber_identities، subscriber_classifications،
--      manual_exception_intakes، installation_payout_candidates() نفسها) —
--      تحقَّق من ذلك بقراءة تعريفاتها الفعلية، لا افتراضاً. وinstallation_
--      payout_candidates() القائمة أصلاً (تُستهلَك هنا لعدّاد الجاهز أيضاً)
--      عديمة نطاق الفترة بنفس الطريقة — فهذا نمطٌ مثبَّتٌ سلفاً في هذا الجزء
--      من النظام، لا اختراعاً. فلا يُخترَع نطاق فترة هنا. الحقل يحمل الآن
--      'scope':'ALL_TIME_BACKLOG' صراحةً، والعنوان في الواجهة لم يعد يُسمّى
--      «جاهزية الدورة» (توحي بفترة الشهر) بل «الحواجز المفتوحة حالياً»،
--      لتبقى القراءة صادقة عمّا تقيسه فعلاً: كل ما هو مفتوحٌ الآن، لا خاصّ
--      بفترة معيّنة. عدّاد الاستحقاق (installation_entitlements) يبقى هو
--      الحقل الوحيد المرتبط فعلاً بـ v_period، ولم يتغيّر.
--
--   2) التوفيق: v_blocking_categories كانت تُحسَب من متغيّراتٍ منفصلة عن
--      checklist نفسها — فصفٌّ واحدٌ يُنسى من القائمة (كما حدث فعلاً:
--      v_unclassified كان يُحتسَب في blocking_categories بلا ظهورٍ في
--      checklist، وv_unknown_pkg كان يُترك خارج الاثنين معاً رغم أنه يُصيّر
--      خطوة VALIDATE «جارية») يكسر التطابق المطلوب. والحاجز الأخطر: خطوة
--      READY نفسها مبنيّةٌ من installation_payout_candidates().blocked التي
--      تحمل خمس فئات (hold, invoice, source, identity, parent) — وكانت هذه
--      الهجرة تسحب فقط hold وinvoice، فتاركةً source/identity/parent غير
--      مرئيّين البتّة: مرشّحٌ يفشل فقط بحالته التاريخية (source) أو تعارض
--      هويته (identity) أو عائديته (parent) كان يمكن أن يُقرأ overall_state
--      «جاهزة للمراجعة» رغم عدم جهوزيته فعلياً. التصحيح: checklist تُبنى أولاً
--      بكل الحواجز الإحدى عشر المُدقَّقة (انظر أدناه)، وblocking_categories
--      تُشتَقّ حسابياً من checklist نفسها (count فوق jsonb_array_elements) —
--      فلا يمكن لصفٍّ أن يُحتسَب في الحالة الإجمالية بلا أن يظهر في القائمة
--      المرئية، ولا العكس، لأن المصدر واحدٌ الآن حرفياً.
--
--      خطوتا BATCH وPAID (v_batch_open، v_batch_paid) عمداً غير مُدرَجتين:
--      كلتاهما حالةٌ لاحقة لتحقّق الجاهزية بالفعل (دفعة صرفٍ مفتوحة تعني أن
--      مرشّحين قد صاروا جاهزين واستُحقّوا فعلاً) لا حاجزٌ يمنعها — إدراجهما
--      في blocking_categories كان يعني أن نجاح الدورة (فتح دفعة صرف) يُقرأ
--      كأنه فشلها. وخطوتا READY وENTITLEMENT كذلك: حالتا نجاحٍ، لا حاجز.
--
--   3) الازدواج: CLASSIFICATION_REVIEW/GRACE_EXPIRED_REVIEW/MANUAL_EXCEPTION_
--      REVIEW كانت محمولاتٍ منسوخة حرفياً من action_center() (نفس الاستعلام
--      نصّاً) — مصدرا حقيقة لنفس الحقيقة يعني انحرافاً مستقبلياً محتوماً إن
--      عُدِّل أحدهما بلا الآخر. الثلاثة الآن دالّة داخلية واحدة
--      (installation_review_backlog_facts) بلا EXECUTE لأي دورٍ — فقط
--      action_center() وinstallation_cycle_pipeline() (بصفتهما SECURITY
--      DEFINER يملكهما نفس الدور الذي يملك الدالة الداخلية) تستطيعان مناداتها
--      ضمنياً بصلاحية المالك، بصرف النظر عن صلاحية المستخدم المستدعي الفعلي —
--      فلا يصير هذا مساراً لتصعيد صلاحية: كل من الشاشتين تشترط قدرتها الخاصة
--      (report.view / installation.view) *قبل* الوصول إلى الحقائق المشتركة،
--      تماماً كما كانت تفعل من قبل.
-- ---------------------------------------------------------------------------

create or replace function public.installation_review_backlog_facts()
returns table (
  classification_review_decisions bigint,
  classification_review_subscribers bigint,
  grace_expired_decisions bigint,
  grace_expired_subscribers bigint,
  manual_exception_decisions bigint,
  manual_exception_subscribers bigint
)
language sql
stable
security definer
set search_path = ''
as $fn$
  with classification as (
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
  ),
  manual_exception as (
    select count(*)::bigint as decisions,
           count(distinct username_key)::bigint as subscribers
    from public.manual_exception_intakes
    where status = 'NEEDS_REVIEW'
  )
  select
    (select decisions from classification),   (select subscribers from classification),
    (select decisions from grace_expired),    (select subscribers from grace_expired),
    (select decisions from manual_exception), (select subscribers from manual_exception);
$fn$;

revoke execute on function public.installation_review_backlog_facts() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- action_center(): نفس المخرَج حرفاً بحرف — فقط مصدر ثلاثة حقول صار الدالة
-- المشتركة أعلاه بدل نسخٍ محليّ. لا تغيير في report.view ولا في أي فئة أخرى.
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
  facts as (select * from public.installation_review_backlog_facts()),
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
  revalidation as (
    select count(*)::bigint as decisions,
           coalesce(sum(b.imported_row_count), 0)::bigint as events
    from public.saas_import_batches b
    where b.completeness_status = 'NEEDS_REVALIDATION'
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
        'decisions', (select classification_review_decisions from facts),
        'subscribers', (select classification_review_subscribers from facts),
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
        'decisions', (select grace_expired_decisions from facts),
        'subscribers', (select grace_expired_subscribers from facts),
        'events', null, 'amount', null,
        'next_action', 'راجِع أو جاوِز بسببٍ مُدقَّق',
        'path', '/installation/grace-queue'),

      jsonb_build_object(
        'key', 'MANUAL_EXCEPTION_REVIEW', 'label', 'مراجعة استثناء يدوي',
        'unit', 'المشترك', 'role', 'العمليات',
        'decisions', (select manual_exception_decisions from facts),
        'subscribers', (select manual_exception_subscribers from facts),
        'events', null, 'amount', null,
        'next_action', 'راجِع الاستثناء اليدوي',
        'path', '/installation/manual-exception')
    ))
  into v_doc;

  return v_doc;
end;
$function$;

-- ---------------------------------------------------------------------------
-- installation_cycle_pipeline(): steps/candidate/ready/historical دون تغيير.
-- 'readiness' الآن مبنيّةٌ من checklist واحدةٍ شاملة (أحد عشر حاجزاً مُدقَّقاً
-- من الاستعلامات القائمة نفسها)، وblocking_categories/overall_state يُشتقّان
-- حسابياً منها — لا مصدرين لحقيقةٍ واحدة.
-- ---------------------------------------------------------------------------

create or replace function public.installation_cycle_pipeline(p_period text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_period text := coalesce(p_period, to_char(now() at time zone public.business_timezone(), 'YYYY-MM'));
  v_imports int; v_unknown_pkg int; v_unmatched int; v_unclassified int;
  v_cand int; v_cand_amt bigint;
  v_inv_pending int; v_inv_amt bigint;
  v_ready int; v_ready_amt bigint;
  v_ents int; v_ents_amt bigint;
  v_batch_open int; v_batch_paid int; v_paid_amt bigint;
  v_held int;
  v_source int; v_identity_conflict int; v_parent int;
  v_class_review int;
  v_grace_expired int;
  v_manual_exception int;
  v_checklist jsonb;
  v_blocking_categories int;
  v_overall text;
begin
  perform public.require_capability('installation.view');

  select count(*) into v_imports from public.saas_import_batches;

  select count(distinct e.profile_name) into v_unknown_pkg
  from public.saas_activation_events e
  where e.profile_name is not null
    and not exists (select 1 from public.packages p where p.code = e.profile_name);

  select count(*) into v_unmatched
  from public.subscriber_identities where identity_status = 'UNMATCHED';

  select count(*) into v_unclassified
  from public.saas_activation_events e
  where e.username_key is not null
    and not exists (select 1 from public.subscriber_classifications c
                    where c.username_key = e.username_key);

  -- المرشّحون والحجب: من المصدر الواحد كي لا يفترق رقمٌ عن آخر. الخمسة كلّها
  -- (hold/invoice/source/identity/parent) تُسحَب الآن — لا فقط hold/invoice —
  -- فمرشّحٌ يفشل بحالته التاريخية أو تعارض هويته أو عائديته غير المحسومة كان
  -- يبقى غير مرئيٍّ تماماً في القائمة أدناه، فيقرأ overall_state جاهزاً وهو
  -- ليس كذلك.
  with c as (select public.installation_payout_candidates() d)
  select (d ->> 'subscribers')::int, (d ->> 'amount')::bigint,
         (d -> 'blocked' ->> 'invoice')::int,
         (d -> 'blocked_amount' ->> 'invoice')::bigint,
         (d ->> 'ready')::int, (d ->> 'ready_amount')::bigint,
         (d -> 'blocked' ->> 'hold')::int,
         (d -> 'blocked' ->> 'source')::int,
         (d -> 'blocked' ->> 'identity')::int,
         (d -> 'blocked' ->> 'parent')::int
    into v_cand, v_cand_amt, v_inv_pending, v_inv_amt, v_ready, v_ready_amt, v_held,
         v_source, v_identity_conflict, v_parent
  from c;

  select count(*), coalesce(sum(amount), 0) into v_ents, v_ents_amt
  from public.installation_entitlements where period = v_period;

  select count(*) filter (where status in ('DRAFT','VALIDATED','READY')),
         count(*) filter (where status = 'PAID'),
         coalesce(sum(total_amount) filter (where status = 'PAID'), 0)
    into v_batch_open, v_batch_paid, v_paid_amt
  from public.installation_payment_batches;

  -- ثلاثة الحقائق المشتركة مع action_center() — دالّةٌ واحدة، لا نسخ.
  select f.classification_review_subscribers, f.grace_expired_subscribers, f.manual_exception_subscribers
    into v_class_review, v_grace_expired, v_manual_exception
  from public.installation_review_backlog_facts() f;

  -- القائمة الشاملة أولاً: كل حاجزٍ يُحرّك أي خطوةٍ من العشر (عدا READY
  -- وENTITLEMENT وBATCH وPAID — حالات نجاحٍ لاحقة، لا حواجز) يظهر هنا حرفاً
  -- بحرف. blocking_categories/overall_state تُشتقّان من هذه القائمة نفسها في
  -- الأسطر التالية مباشرةً — لا من متغيّراتٍ منفصلة يمكن أن تنحرف عنها.
  v_checklist := jsonb_build_array(
    jsonb_build_object('key','UNKNOWN_PACKAGE','label','باقات غير معروفة',
      'count', v_unknown_pkg, 'path', '/system/imports', 'next_action','عرّف الباقات الناقصة'),
    jsonb_build_object('key','IDENTITY_UNMATCHED','label','هويات غير مطابَقة',
      'count', v_unmatched, 'path', '/installation/subscribers', 'next_action','احسم المطابقة'),
    jsonb_build_object('key','ACTIVATION_UNCLASSIFIED','label','مشتركون بلا تصنيف جِدّة',
      'count', v_unclassified, 'path', '/installation', 'next_action','شغّل التصنيف'),
    jsonb_build_object('key','CLASSIFICATION_REVIEW','label','تصنيف يحتاج مراجعة',
      'count', v_class_review, 'path', '/installation', 'next_action','راجِع شواهد التصنيف'),
    jsonb_build_object('key','GRACE_EXPIRED_REVIEW','label','مهلة تفعيل منقضية',
      'count', v_grace_expired, 'path', '/installation/grace-queue', 'next_action','راجِع أو جاوِز بسببٍ مُدقَّق'),
    jsonb_build_object('key','MANUAL_EXCEPTION_REVIEW','label','استثناء يدوي معلَّق',
      'count', v_manual_exception, 'path', '/installation/manual-exception', 'next_action','راجِع الاستثناء اليدوي'),
    jsonb_build_object('key','CANDIDATE_SOURCE_INCOMPLETE','label','حالة تاريخية غير محسومة',
      'count', v_source, 'path', '/installation/subscribers', 'next_action','راجِع الحالة التاريخية'),
    jsonb_build_object('key','CANDIDATE_IDENTITY_CONFLICT','label','تعارض هوية',
      'count', v_identity_conflict, 'path', '/installation/subscribers', 'next_action','احسم تعارض الهوية'),
    jsonb_build_object('key','CANDIDATE_PARENT_UNRESOLVED','label','عائدية غير محسومة',
      'count', v_parent, 'path', '/master/parents', 'next_action','حدّد العائدية'),
    jsonb_build_object('key','MISSING_INVOICE','label','فاتورة لم تُفحص',
      'count', v_inv_pending, 'path', '/installation/invoices?status=NOT_CHECKED', 'next_action','دقّق الفاتورة'),
    jsonb_build_object('key','ACTIVE_HOLD','label','تعليق سارٍ',
      'count', v_held, 'path', '/installation/holds?status=EFFECTIVE', 'next_action','راجِع الحجب')
  );

  select count(*) into v_blocking_categories
  from jsonb_array_elements(v_checklist) x
  where coalesce((x ->> 'count')::int, 0) > 0;

  v_overall := case
    when v_imports = 0 then 'NOT_READY'
    when v_blocking_categories > 0 then 'NEEDS_REVIEW'
    else 'READY_FOR_REVIEW'
  end;

  return jsonb_build_object(
    'period', v_period,
    'steps', jsonb_build_array(
      jsonb_build_object('key','IMPORT','label','الاستيراد','order',1,
        'state', case when v_imports > 0 then 'DONE' else 'PENDING' end,
        'count', v_imports, 'amount', null,
        'blocker', null, 'path', '/system/imports',
        'next_action', case when v_imports = 0 then 'استورد ملف الشهر' else 'مراجعة الدفعات' end),

      jsonb_build_object('key','VALIDATE','label','التحقّق','order',2,
        'state', case when v_imports = 0 then 'PENDING'
                      when v_unknown_pkg > 0 then 'ACTIVE' else 'DONE' end,
        'count', v_unknown_pkg, 'amount', null,
        'blocker', case when v_unknown_pkg > 0 then 'باقات غير معروفة' end,
        'path', '/system/imports', 'next_action','عرّف الباقات الناقصة'),

      jsonb_build_object('key','MATCH','label','المطابقة','order',3,
        'state', case when v_imports = 0 then 'PENDING'
                      when v_unmatched > 0 then 'ACTIVE' else 'DONE' end,
        'count', v_unmatched, 'amount', null,
        'blocker', case when v_unmatched > 0 then 'هويات غير مطابَقة' end,
        'path', '/installation/subscribers', 'next_action','احسم المطابقة'),

      jsonb_build_object('key','CLASSIFY','label','التصنيف','order',4,
        'state', case when v_imports = 0 then 'PENDING'
                      when v_unclassified > 0 then 'ACTIVE' else 'DONE' end,
        'count', v_unclassified, 'amount', null,
        'blocker', case when v_unclassified > 0 then 'مشتركون بلا تصنيف جِدّة' end,
        'path', '/installation', 'next_action','شغّل التصنيف'),

      jsonb_build_object('key','INVOICE','label','مراجعة الفواتير','order',5,
        'state', case when v_cand = 0 then 'PENDING'
                      when v_inv_pending > 0 then 'ACTIVE' else 'DONE' end,
        'count', v_inv_pending, 'amount', v_inv_amt,
        'blocker', case when v_inv_pending > 0 then 'فواتير لم تُدقَّق' end,
        'path', '/installation/invoices?status=NOT_CHECKED', 'next_action','دقّق الفواتير'),

      jsonb_build_object('key','ELIGIBILITY','label','الأهلية','order',6,
        'state', case when v_cand = 0 then 'PENDING'
                      when v_held > 0 then 'ACTIVE' else 'DONE' end,
        'count', v_held, 'amount', null,
        'blocker', case when v_held > 0 then 'تعليقات سارية' end,
        'path', '/installation/holds?status=EFFECTIVE', 'next_action','راجِع التعليقات'),

      jsonb_build_object('key','READY','label','جاهز للصرف','order',7,
        'state', case when v_ready > 0 then 'ACTIVE' else 'PENDING' end,
        'count', v_ready, 'amount', v_ready_amt,
        'blocker', case when v_ready = 0 and v_cand > 0
                        then 'لا أحد اجتاز كل الفحوص' end,
        'path', '/installation/ready', 'next_action','راجِع الجاهزين'),

      jsonb_build_object('key','ENTITLEMENT','label','تثبيت الاستحقاق','order',8,
        'state', case when v_ents > 0 then 'ACTIVE' else 'PENDING' end,
        'count', v_ents, 'amount', v_ents_amt,
        'blocker', case when v_ents = 0 and v_ready > 0 then 'لم يُثبَّت شيء بعد' end,
        'path', '/installation/ready', 'next_action','ثبِّت الجاهزين'),

      jsonb_build_object('key','BATCH','label','دفعة الصرف','order',9,
        'state', case when v_batch_open > 0 then 'ACTIVE'
                      when v_batch_paid > 0 then 'DONE' else 'PENDING' end,
        'count', v_batch_open, 'amount', null,
        'blocker', null,
        'path', '/finance/installation-batches', 'next_action','أنشئ دفعة أو أكّدها'),

      jsonb_build_object('key','PAID','label','الدفع والإقفال','order',10,
        'state', case when v_batch_paid > 0 then 'DONE' else 'PENDING' end,
        'count', v_batch_paid, 'amount', v_paid_amt,
        'blocker', null,
        'path', '/reports/payments', 'next_action','راجِع الدفتر')
    ),

    -- المرشّح والجاهز منفصلان دائماً: أحدهما قراءة والآخر حكم.
    'candidate', jsonb_build_object('subscribers', v_cand, 'amount', v_cand_amt),
    'ready', jsonb_build_object('subscribers', v_ready, 'amount', v_ready_amt),
    'historical', jsonb_build_object(
      'paid', (select coalesce(sum(amount), 0) from public.installation_payment_history),
      'rows', (select count(*) from public.installation_payment_history)),

    -- PR-B2: الحواجز المفتوحة حالياً — تجميعٌ عرضيٌّ فقط فوق أرقامٍ محسوبةٍ
    -- أعلاه، عبر كل الوقت (scope) لا خاصّاً بـ v_period أعلاه. عدّاد
    -- الاستحقاق (candidate/ready/'ENTITLEMENT' في steps) يبقى وحده المرتبط
    -- فعلياً بالفترة.
    'readiness', jsonb_build_object(
      'scope', 'ALL_TIME_BACKLOG',
      'overall_state', v_overall,
      'blocking_categories', v_blocking_categories,
      'checklist', v_checklist
    ));
end;
$fn$;

revoke execute on function public.installation_cycle_pipeline(text) from public, anon;
grant execute on function public.installation_cycle_pipeline(text) to authenticated;

-- ---------------------------------------------------------------------------
-- PR-B2 — Active/Resolved لطابور مهلة التفعيل المنقضية.
--
-- page_manual_exceptions يحمل p_status('NEEDS_REVIEW'|'RESOLVED') أصلاً؛
-- page_installation_grace_queue لا تحمل مقابله رغم أن grace_period_overrides
-- (سجلّ التجاوز نفسه، من 20261005090000_batch4_rule_engine.sql) موجودٌ
-- ومُغذًّى فعلاً من override_grace_expired_review — لا صفّ جديد يُضاف هنا،
-- قراءةٌ فقط على ما هو مخزَّنٌ أصلاً. p_status يُضاف كمعامل رابعٍ بقيمةٍ
-- افتراضية تحفظ السلوك القائم بالضبط لأي استدعاءٍ لا يمرّره — وأي قيمةٍ غير
-- 'EXPIRED'/'OVERRIDDEN' تُرفَض صراحةً بدل أن تُعامَل صمتاً كـ EXPIRED.
-- ---------------------------------------------------------------------------

drop function if exists public.page_installation_grace_queue(text, integer, integer);

create or replace function public.page_installation_grace_queue(
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_status text default 'EXPIRED'
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

  if p_status is distinct from 'EXPIRED' and p_status is distinct from 'OVERRIDDEN' then
    raise exception 'page_installation_grace_queue: invalid p_status % — expected EXPIRED or OVERRIDDEN', p_status
      using errcode = '22023';
  end if;

  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  if p_status = 'OVERRIDDEN' then
    with base as (
      select o.username_key, o.reason, o.overridden_at, o.overridden_by
      from public.grace_period_overrides o
      where (btrim(coalesce(p_search, '')) = ''
             or o.username_key ilike '%' || btrim(p_search) || '%')
    ),
    total as (select count(*)::bigint as n from base),
    paged as (
      select
        b.username_key, i.installation_subscriber_id, i.display_name, i.username,
        b.reason, b.overridden_at, p.email as overridden_by_email
      from base b
      left join lateral (
        select ii.installation_subscriber_id, ii.display_name, ii.username
        from public.subscriber_identities ii
        where ii.username_key = b.username_key
        order by (ii.identity_status = 'MATCHED') desc, ii.updated_at desc, ii.id
        limit 1
      ) i on true
      left join public.profiles p on p.id = b.overridden_by
      order by b.overridden_at desc, b.username_key asc
      limit v_lim offset v_off
    )
    select (select n from total),
           coalesce((select jsonb_agg(to_jsonb(p)) from paged p), '[]'::jsonb)
    into v_total, v_rows;

    return public.page_envelope(v_rows, v_total, v_lim, v_off);
  end if;

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

revoke execute on function public.page_installation_grace_queue(text, integer, integer, text) from public, anon;
grant execute on function public.page_installation_grace_queue(text, integer, integer, text) to authenticated;

create index if not exists grace_period_overrides_overridden_at_idx
  on public.grace_period_overrides (overridden_at desc);

commit;
