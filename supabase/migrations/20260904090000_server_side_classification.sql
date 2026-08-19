-- ---------------------------------------------------------------------------
-- تصنيف الجِدّة على الخادم — نقلٌ حرفيّ لقواعد قائمة، لا قواعد جديدة
--
-- التصنيف كان يُحسب في المتصفّح أثناء الاستيراد ثم يضيع: جدول
-- subscriber_classifications موجودٌ بكامل حقول الشاهد وفارغ. فالنتيجة أن
-- ادعاءً مالياً — «هذا مشترك جديد» — لا أثر له يُراجَع بعد إغلاق التبويب.
--
-- ما هنا ترجمةٌ حرفية لـclassifyNewness في assets/js/saas-import.js. لم
-- تُضَف قاعدة ولا تُخفَّف: الترتيب نفسه، وأسماء الأسباب نفسها، والحارس نفسه.
-- ويؤكّده اختبارٌ يشغّل الاثنين على المدخلات ذاتها ويقارن.
--
-- والنتيجة المتوقَّعة من بيانات اليوم صفرُ NEW: كل دفعات الاستيراد
-- اكتمالها UNKNOWN، والقاعدة الخامسة لا تمنح الجِدّة إلا من مصدرٍ مكتمل.
-- هذا ليس عطلاً بل ما يقوله المصدر: الملفات الحالية لا تُثبت جِدّة أحد.
-- ---------------------------------------------------------------------------

begin;

-- الترقية تُصبح تحديثاً لا صفّاً ثانياً.
create unique index if not exists subscriber_classifications_username_uidx
  on public.subscriber_classifications (username_key);

create or replace function public.classify_newness(p_username_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key        text := lower(btrim(coalesce(p_username_key, '')));
  v_pre        boolean;
  v_identity   text;
  v_complete   text;
  v_batch      uuid;
  v_lifetime   bigint;
  v_observed   bigint;
  v_qualifying bigint;
  v_canceled   bigint;
  v_debt       bigint;
  v_unknown    bigint;
  v_all_cxl    boolean;
begin
  perform public.require_capability('saas.review');

  if v_key = '' then
    raise exception 'Subscriber key is required' using errcode = '22023';
  end if;

  -- وجودٌ سابق في سجلّ التنصيب: الشاهد الأقوى، ويحسم قبل كل شيء.
  select exists (
    select 1 from public.installation_subscribers s
    where lower(btrim(s.subscriber_id)) = v_key) into v_pre;

  select i.identity_status into v_identity
  from public.subscriber_identities i
  where i.username_key = v_key
  limit 1;

  -- اكتمال المصدر يُؤخذ من أضعف دفعةٍ ساهمت بأحداث هذا المشترك: دفعةٌ
  -- ناقصة تكفي لإسقاط الادعاء ولو كانت الأخرى مكتملة.
  select case
           when bool_or(b.completeness_status = 'UNKNOWN') then 'UNKNOWN'
           when bool_or(b.completeness_status = 'PARTIAL') then 'PARTIAL'
           when count(*) > 0 then 'COMPLETE'
           else 'UNKNOWN' end,
         max(b.id::text)::uuid
    into v_complete, v_batch
  from public.saas_activation_events e
  join public.saas_import_batches b on b.id = e.import_batch_id
  where e.username_key = v_key;

  select
    coalesce(max(e.activations_count), 0),
    count(*),
    count(*) filter (
      where coalesce(e.canceled, false) = false
        and coalesce(pk.semantic_category, 'UNKNOWN') = 'PAID_PACKAGE'),
    count(*) filter (where coalesce(e.canceled, false)),
    count(*) filter (where coalesce(pk.semantic_category, 'UNKNOWN') = 'DEBT_SERVICE'),
    count(*) filter (where coalesce(pk.semantic_category, 'UNKNOWN') = 'UNKNOWN'),
    coalesce(bool_and(coalesce(e.canceled, false)), false)
    into v_lifetime, v_observed, v_qualifying, v_canceled, v_debt, v_unknown, v_all_cxl
  from public.saas_activation_events e
  left join public.packages pk on pk.code = e.profile_name
  where e.username_key = v_key;

  return jsonb_build_object(
    'username_key', v_key,
    'import_batch_id', v_batch,
    'lifetime_activations_count', nullif(v_lifetime, 0),
    'observed_event_count', v_observed,
    'qualifying_paid_event_count', v_qualifying,
    'registry_preexisting', v_pre,
    'source_completeness', coalesce(v_complete, 'UNKNOWN'),
    'evidence', jsonb_build_object(
      'canceled_events', v_canceled,
      'debt_service_events', v_debt,
      'unknown_package_events', v_unknown))

  -- ١. وجود سابق في السجل يحسم الأمر مهما قال الملف.
  || case when v_pre then
       jsonb_build_object('classification', 'EXISTING', 'reason_code', 'REGISTRY_PREEXISTING')
  -- ٢. تعارض هوية لا يُصنَّف.
     when v_identity = 'CONFLICT' then
       jsonb_build_object('classification', 'NEEDS_REVIEW', 'reason_code', 'IDENTITY_CONFLICT')
  -- ٣. عدّاد العمر يتجاوز ما رُصد ⇒ تاريخٌ خارج الملف ⇒ قديم قطعاً.
     when v_lifetime > v_observed then
       jsonb_build_object('classification', 'EXISTING', 'reason_code', 'LIFETIME_COUNT_EXCEEDS_OBSERVED')
  -- ٤. لا حدث مدفوع مؤهل ⇒ لا أساس لادعاء اشتراك جديد.
     when v_qualifying = 0 then
       jsonb_build_object('classification', 'NEEDS_REVIEW', 'reason_code',
         case when v_observed > 0 and v_all_cxl
              then 'CANCELED_ONLY_HISTORY' else 'NO_QUALIFYING_PAID_EVENT' end)
  -- ٥. الحارس: التساوي يوحي بالجِدّة ولا يُثبتها إلا من مصدرٍ مكتمل.
     when coalesce(v_complete, 'UNKNOWN') = 'COMPLETE'
          and v_lifetime > 0 and v_lifetime = v_observed then
       jsonb_build_object('classification', 'NEW', 'reason_code', 'COMPLETE_LIFETIME_HISTORY_OBSERVED')
     else
       jsonb_build_object('classification', 'NEEDS_REVIEW', 'reason_code',
         case when coalesce(v_complete, 'UNKNOWN') = 'PARTIAL'
              then 'PARTIAL_SOURCE' else 'UNKNOWN_SOURCE_COMPLETENESS' end)
     end;
end;
$fn$;

revoke execute on function public.classify_newness(text) from public, anon;
grant execute on function public.classify_newness(text) to authenticated;

-- ---------------------------------------------------------------------------
-- التثبيت — يكتب التصنيف وشواهده، ولا يمسّ صفّاً مالياً
--
-- لا استحقاق يُنشأ هنا، ولا مبلغ يُحسب. التصنيف مُدخَلٌ للقرار المالي لا
-- قرارٌ مالي، ويبقى إنشاء الاستحقاق حيث هو.
-- ---------------------------------------------------------------------------

create or replace function public.refresh_subscriber_classifications(
  p_limit integer default 500,
  p_only_missing boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_key   text;
  v_doc   jsonb;
  v_done  integer := 0;
  v_new   integer := 0;
  v_exist integer := 0;
  v_rev   integer := 0;
  v_lim   integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
begin
  perform public.require_capability('saas.review');

  for v_key in
    select distinct e.username_key
    from public.saas_activation_events e
    where e.username_key is not null and btrim(e.username_key) <> ''
      and (not p_only_missing
           or not exists (select 1 from public.subscriber_classifications c
                          where c.username_key = e.username_key))
    order by e.username_key
    limit v_lim
  loop
    v_doc := public.classify_newness(v_key);

    insert into public.subscriber_classifications (
      subscriber_identity_id, username_key, saas_user_id, classification, reason_code,
      lifetime_activations_count, observed_event_count, registry_preexisting,
      source_completeness, qualifying_paid_event_count, evidence, evaluated_at,
      import_batch_id)
    values (
      (select i.id from public.subscriber_identities i where i.username_key = v_key limit 1),
      v_key,
      (select e.saas_user_id from public.saas_activation_events e
       where e.username_key = v_key and e.saas_user_id is not null limit 1),
      v_doc ->> 'classification',
      v_doc ->> 'reason_code',
      (v_doc ->> 'lifetime_activations_count')::integer,
      (v_doc ->> 'observed_event_count')::integer,
      (v_doc ->> 'registry_preexisting')::boolean,
      v_doc ->> 'source_completeness',
      (v_doc ->> 'qualifying_paid_event_count')::integer,
      v_doc -> 'evidence',
      now(),
      (v_doc ->> 'import_batch_id')::uuid)
    on conflict (username_key) do update set
      classification = excluded.classification,
      reason_code = excluded.reason_code,
      lifetime_activations_count = excluded.lifetime_activations_count,
      observed_event_count = excluded.observed_event_count,
      registry_preexisting = excluded.registry_preexisting,
      source_completeness = excluded.source_completeness,
      qualifying_paid_event_count = excluded.qualifying_paid_event_count,
      evidence = excluded.evidence,
      evaluated_at = excluded.evaluated_at,
      import_batch_id = excluded.import_batch_id;

    v_done := v_done + 1;
    if v_doc ->> 'classification' = 'NEW' then v_new := v_new + 1;
    elsif v_doc ->> 'classification' = 'EXISTING' then v_exist := v_exist + 1;
    else v_rev := v_rev + 1; end if;
  end loop;

  return jsonb_build_object(
    'evaluated', v_done, 'new', v_new, 'existing', v_exist, 'needs_review', v_rev,
    'remaining', (
      select count(distinct e.username_key)
      from public.saas_activation_events e
      where e.username_key is not null and btrim(e.username_key) <> ''
        and not exists (select 1 from public.subscriber_classifications c
                        where c.username_key = e.username_key)));
end;
$fn$;

revoke execute on function public.refresh_subscriber_classifications(integer,boolean) from public, anon;
grant execute on function public.refresh_subscriber_classifications(integer,boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- القراءة التشغيلية: كم صُنِّف، وبأيّ سبب، وكم بقي
-- ---------------------------------------------------------------------------

create or replace function public.classification_state()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'by_class', coalesce((
      select jsonb_object_agg(x.k, x.n) from (
        select classification as k, count(*) as n
        from public.subscriber_classifications group by 1) x), '{}'::jsonb),
    'by_reason', coalesce((
      select jsonb_object_agg(x.k, x.n) from (
        select reason_code as k, count(*) as n
        from public.subscriber_classifications group by 1) x), '{}'::jsonb),
    'by_completeness', coalesce((
      select jsonb_object_agg(x.k, x.n) from (
        select source_completeness as k, count(*) as n
        from public.subscriber_classifications group by 1) x), '{}'::jsonb),
    'classified', (select count(*) from public.subscriber_classifications),
    'total_subscribers', (
      select count(distinct e.username_key) from public.saas_activation_events e
      where e.username_key is not null and btrim(e.username_key) <> ''),
    'last_evaluated_at', (select max(evaluated_at) from public.subscriber_classifications))
  where public.has_capability('installation.view');
$fn$;

revoke execute on function public.classification_state() from public, anon;
grant execute on function public.classification_state() to authenticated;

commit;
