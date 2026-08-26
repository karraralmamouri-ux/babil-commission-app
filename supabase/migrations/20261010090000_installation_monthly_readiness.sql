begin;

-- ---------------------------------------------------------------------------
-- PR-B2 — جاهزية الدورة الشهرية: قراءةٌ إضافية فوق ما هو قائم، لا قاعدة مالية
-- جديدة ولا حسابٌ جديد.
--
-- installation_cycle_pipeline() (منذ 2026-09-17) يقيس عشر خطوات الدورة، لكنه
-- سبق PR-B1 (طابور المهلة المنقضية والاستثناء اليدوي، 2026-10-06/07). فصار
-- عنده عمًى عن ثلاثة حواجز صارت مصادرها المعتمدة موجودة الآن: تصنيفٌ ما زال
-- NEEDS_REVIEW، مهلة تفعيل منقضية بانتظار مراجعة، واستثناءٌ يدويٌّ معلَّق.
-- هذا الملف يُضيف حقل 'readiness' فقط إلى مخرَج الدالة نفسها — لا تغيير على
-- 'steps'/'candidate'/'ready'/'historical' ولا على ترتيبها ولا على أي مستهلكٍ
-- قائم لها.
--
-- القيم الثلاث معدودةٌ هنا بنفس محمولات action_center() تماماً (المجموعات
-- CLASSIFICATION_REVIEW وGRACE_EXPIRED_REVIEW وMANUAL_EXCEPTION_REVIEW)، لا
-- باستدعائها: action_center() تشترط report.view، بينما هذه الدالة تشترط
-- installation.view فقط — استدعاؤها هنا كان يرفع سقف الصلاحية المطلوبة لفتح
-- شاشة الدورة الشهرية بصمت. فالمحمول يُعاد كتابته حرفياً، لا يُختلَق حساب جديد.
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
  v_class_review int;
  v_grace_expired int;
  v_manual_exception int;
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

  -- المرشّحون والحجب: من المصدر الواحد كي لا يفترق رقمٌ عن آخر.
  with c as (select public.installation_payout_candidates() d)
  select (d ->> 'subscribers')::int, (d ->> 'amount')::bigint,
         (d -> 'blocked' ->> 'invoice')::int,
         (d -> 'blocked_amount' ->> 'invoice')::bigint,
         (d ->> 'ready')::int, (d ->> 'ready_amount')::bigint,
         (d -> 'blocked' ->> 'hold')::int
    into v_cand, v_cand_amt, v_inv_pending, v_inv_amt, v_ready, v_ready_amt, v_held
  from c;

  select count(*), coalesce(sum(amount), 0) into v_ents, v_ents_amt
  from public.installation_entitlements where period = v_period;

  select count(*) filter (where status in ('DRAFT','VALIDATED','READY')),
         count(*) filter (where status = 'PAID'),
         coalesce(sum(total_amount) filter (where status = 'PAID'), 0)
    into v_batch_open, v_batch_paid, v_paid_amt
  from public.installation_payment_batches;

  -- نفس محمول تصنيف action_center(): NEEDS_REVIEW يُحتسَب إلا إذا كان سببه
  -- استثناءً يدوياً محسوماً بالفعل (فلا يبقى شبحاً بعد حسمه).
  select count(*) into v_class_review
  from public.subscriber_classifications c
  where c.classification = 'NEEDS_REVIEW'
    and (
      c.reason_code is distinct from 'MANUAL_EXCEPTION'
      or exists (
        select 1 from public.manual_exception_intakes m
        where m.username_key = c.username_key and m.status = 'NEEDS_REVIEW')
    );

  -- نفس محمول grace_expired في action_center(): المصدر الوحيد للحالة يبقى
  -- installation_reference_dates() + grace_status_from_dates().
  select count(*) into v_grace_expired
  from public.subscriber_classifications c
  cross join lateral public.installation_reference_dates(c.username_key) d
  where c.classification = 'NEEDS_REVIEW'
    and c.reason_code = 'NO_QUALIFYING_PAID_EVENT'
    and public.grace_status_from_dates(
          d.reference_at, d.qualifying_at,
          exists (select 1 from public.grace_period_overrides o where o.username_key = c.username_key))
        = 'GRACE_EXPIRED_REVIEW';

  select count(distinct username_key) into v_manual_exception
  from public.manual_exception_intakes where status = 'NEEDS_REVIEW';

  -- تنبيه: CLASSIFICATION_REVIEW (محمول action_center() نفسه) يحتسب أصلاً كل
  -- صفّ NEEDS_REVIEW — بما فيه المهلة المنقضية وحتى الاستثناء اليدوي المفتوح.
  -- فجمع الأصناف الثلاثة رقماً واحداً كان يُكرِّر نفس المشترك أكثر من مرة. لا
  -- "إجمالي مشتركين محجوبين" هنا إذن — فقط عدد الأصناف التي فيها ما ينتظر،
  -- وهذا عددٌ لا يتكرّر بتعريفه (صنفٌ واحدٌ يُحتسَب مرّة، بصرف النظر عن كم
  -- مشتركاً بداخله).
  v_blocking_categories := (case when v_unmatched > 0 then 1 else 0 end)
    + (case when v_unclassified > 0 then 1 else 0 end)
    + (case when v_class_review > 0 then 1 else 0 end)
    + (case when v_grace_expired > 0 then 1 else 0 end)
    + (case when v_manual_exception > 0 then 1 else 0 end)
    + (case when v_inv_pending > 0 then 1 else 0 end)
    + (case when v_held > 0 then 1 else 0 end);

  -- تعريف الحالة الإجمالية: تجميعٌ عرضيٌّ للأرقام أعلاه، لا قاعدة مالية جديدة.
  -- NOT_READY تقتصر على غياب استيراد الشهر أصلاً؛ وإلا فالحالة تُقرأ من وجود
  -- صنفٍ واحدٍ على الأقل فيه ما ينتظر قراراً.
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

    -- PR-B2: جاهزية الدورة — تجميعٌ عرضيٌّ فقط فوق أرقامٍ محسوبةٍ أعلاه.
    'readiness', jsonb_build_object(
      'overall_state', v_overall,
      'blocking_categories', v_blocking_categories,
      'checklist', jsonb_build_array(
        jsonb_build_object('key','IDENTITY_UNMATCHED','label','هويات غير مطابَقة',
          'count', v_unmatched, 'path', '/installation/subscribers', 'next_action','احسم المطابقة'),
        jsonb_build_object('key','CLASSIFICATION_REVIEW','label','تصنيف يحتاج مراجعة',
          'count', v_class_review, 'path', '/installation', 'next_action','راجِع شواهد التصنيف'),
        jsonb_build_object('key','GRACE_EXPIRED_REVIEW','label','مهلة تفعيل منقضية',
          'count', v_grace_expired, 'path', '/installation/grace-queue', 'next_action','راجِع أو جاوِز بسببٍ مُدقَّق'),
        jsonb_build_object('key','MANUAL_EXCEPTION_REVIEW','label','استثناء يدوي معلَّق',
          'count', v_manual_exception, 'path', '/installation/manual-exception', 'next_action','راجِع الاستثناء اليدوي'),
        jsonb_build_object('key','MISSING_INVOICE','label','فاتورة لم تُفحص',
          'count', v_inv_pending, 'path', '/installation/invoices?status=NOT_CHECKED', 'next_action','دقّق الفاتورة'),
        jsonb_build_object('key','ACTIVE_HOLD','label','تعليق سارٍ',
          'count', v_held, 'path', '/installation/holds?status=EFFECTIVE', 'next_action','راجِع الحجب')
      )
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
-- افتراضية تحفظ السلوك القائم بالضبط لأي استدعاءٍ لا يمرّره.
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
