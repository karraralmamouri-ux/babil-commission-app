-- ---------------------------------------------------------------------------
-- دورة التنصيب الشهرية — الخطوات وحالتها
--
-- عشر خطوات، كلٌّ منها تُقاس من البيانات لا تُعلَن يدوياً: الخطوة «مكتملة»
-- حين لا يبقى فيها ما ينتظر، و«جارية» حين فيها عمل، و«لم تبدأ» حين لا مدخل
-- لها بعد.
--
-- والقاعدة التي تحكم العرض: مالُ المرشّح لا يظهر جاهزاً إلا بعد اجتياز كل
-- الفحوص. الخطوة تعرف عددها ومبلغها، ولا تُرقّي مبلغاً من مرحلةٍ إلى التي
-- بعدها قبل أوانه.
-- ---------------------------------------------------------------------------

begin;

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
      'rows', (select count(*) from public.installation_payment_history)));
end;
$fn$;

revoke execute on function public.installation_cycle_pipeline(text) from public, anon;
grant execute on function public.installation_cycle_pipeline(text) to authenticated;

commit;
