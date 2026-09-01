-- ZON-005: توحيد مصدر النطاق بين محرّك العمولة ولوحة التنصيب.
--
-- fdt_commission_scope(fdt_code) هو المصدر الوحيد لحدود 94–119 منذ
-- 20261011090000. محرّك العمولة يقرأ منه دوماً؛ جانب التنصيب لم يكن يقرأ
-- منه إطلاقاً:
--
--   1. installation_enrollments.zone لم يُملأ قط — enroll_new_installation
--      وbootstrap_historical_enrollments كانا يكتبان NULL أو لا يكتبان العمود
--      إطلاقاً. materialize_installation_entitlements ينسخ هذا العمود
--      حرفياً إلى installation_entitlements.zone — فـNULL ينتشر معه.
--   2. import_installation_entitlements (الاستيراد المجمّع القديم) كان
--      يثق بعمود "zone" الخام من ملف الرفع نفسه، بلا أي تحقق مقابل رقم
--      الكابينة — فقد يخالف قاعدة 94–119 المعتمدة (DEC-002) دون أن يُكتشف.
--
-- الإصلاح: كلا المسارين يشتقّان zone من fdt_commission_scope() الآن، لا من
-- قيمة مُدخَلة يدوياً ولا بإعادة كتابة نطاق 94–119 محلياً. تصنيف يدوي متاح
-- سابقاً (عمود zone في ملف الاستيراد) لم يعد يُقرأ للتصنيف — تماماً كما
-- fdts.zone بقي بيانات تشغيلية منفصلة لا تُستخدم للحساب (20261011090000).
--
-- zone بيانات تصنيف عرض فقط: لا migration سابقة تقرأه لحساب أي مبلغ أو
-- نسبة (تأكَّد بالبحث عبر كل الهجرات) — فالنسخ الرجعي (backfill) أدناه
-- يصحّح تصنيفاً معروضاً، ولا يُعيد كتابة مالاً ولا يمسّ أي صفّ مدفوع مالياً.
--
-- لا نطاق قابل للتهيئة يُضاف هنا — الحدّ يبقى 94–119 الثابت المعتمد، فقط
-- عبر الدالة الوحيدة القائمة بدل نسخها.

begin;

-- ---------------------------------------------------------------------------
-- 1. enroll_new_installation: zone من fdt_commission_scope، لا NULL.
-- ---------------------------------------------------------------------------

create or replace function public.enroll_new_installation(
  p_username_key text,
  p_event_id text,
  p_cycle_id uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_gate jsonb;
  v_identity public.subscriber_identities%rowtype;
  v_event public.saas_activation_events%rowtype;
  v_version uuid;
  v_first_stage text;
  v_fdt text;
  v_zone text;
  v_row public.installation_enrollments%rowtype;
begin
  perform public.require_capability('installation.enroll');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('enroll:' || p_username_key, 0));

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  -- البوابة تُقيَّم هنا داخل المعاملة، لا في الواجهة.
  v_gate := public.evaluate_enrollment_gate(p_username_key, p_event_id);
  if not (v_gate ->> 'allowed')::boolean then
    raise exception 'Enrollment is not permitted: %', v_gate ->> 'blockers'
      using errcode = '42501';
  end if;

  select * into v_identity from public.subscriber_identities
  where username_key = p_username_key limit 1;
  select * into v_event from public.saas_activation_events where saas_event_id = p_event_id;

  -- الإصدار المنشور الساري. لا تسجيل على مسودّة.
  select v.id into v_version
  from public.installation_scheme_versions v
  join public.installation_fee_schemes s on s.id = v.scheme_id
  where v.status = 'PUBLISHED' and s.is_active
    and (v.effective_from is null or v.effective_from <= current_date)
    and (v.effective_to is null or v.effective_to >= current_date)
  order by v.effective_from desc nulls last, v.version desc
  limit 1;

  if v_version is null then
    raise exception 'No published scheme version is effective today' using errcode = 'P0002';
  end if;

  select code into v_first_stage from public.installation_stage_definitions
  where scheme_version_id = v_version and not is_terminal
  order by sequence limit 1;

  v_fdt := coalesce(v_identity.fdt_code, v_event.fdt_code);
  v_zone := case when public.fdt_commission_scope(v_fdt) = 'FDT' then 'new' else 'old' end;

  insert into public.installation_enrollments (
    subscriber_id, subscriber_identity_id, scheme_version_id, origin,
    effective_agent_id, fdt_code, zone, current_stage_code, status,
    newness_evidence, first_qualifying_event_id, source_cycle_id, enrolled_by
  ) values (
    p_username_key, v_identity.id, v_version, 'NEW_INSTALLATION',
    v_identity.effective_agent_id, v_fdt, v_zone,
    v_first_stage, 'ACTIVE', v_gate, p_event_id, p_cycle_id, v_actor
  )
  returning * into v_row;

  insert into public.audit_logs (
    actor_id, action, field, new_value, entity_type, entity_id,
    after_data, request_id, extra
  ) values (
    v_actor, 'installation.enrollment.created', 'current_stage_code', v_first_stage,
    'installation_enrollment', v_row.id, to_jsonb(v_row), p_request_id, p_event_id
  );

  return jsonb_build_object('replayed', false, 'enrollment', to_jsonb(v_row));
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. bootstrap_historical_enrollments: zone من fdt_commission_scope، لا NULL
--    ثابت.
-- ---------------------------------------------------------------------------

create or replace function public.bootstrap_historical_enrollments()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version uuid;
  v_created integer := 0;
  v_skipped_unknown integer := 0;
  v_existing integer := 0;
  v_total integer;
begin
  select v.id into v_version
  from public.installation_scheme_versions v
  join public.installation_fee_schemes s on s.id = v.scheme_id
  where s.code = 'INSTALLATION_STANDARD' and v.version = 1 and v.status = 'PUBLISHED';

  if v_version is null then
    raise exception 'Scheme V1 is not published' using errcode = 'P0002';
  end if;

  select count(*) into v_total from public.installation_subscribers;
  select count(*) into v_existing from public.installation_enrollments
  where origin = 'HISTORICAL_BASELINE';

  -- المرحلة غير المعروفة لا تُخمَّن. تُعَدّ وتُترك.
  select count(*) into v_skipped_unknown
  from public.installation_subscribers sub
  left join public.installation_subscriber_state st on st.subscriber_uuid = sub.id
  where st.current_stage is null
     or st.current_stage not in (
       select code from public.installation_stage_definitions where scheme_version_id = v_version);

  insert into public.installation_enrollments (
    subscriber_id, scheme_version_id, origin, current_stage_code, status,
    fdt_code, zone, agent_name_at_enrollment, enrolled_at, newness_evidence
  )
  select
    sub.subscriber_id, v_version, 'HISTORICAL_BASELINE', st.current_stage,
    case when st.current_stage = 'DONE' then 'COMPLETED' else 'ACTIVE' end,
    sub.fdt,
    case when public.fdt_commission_scope(sub.fdt) = 'FDT' then 'new' else 'old' end,
    sub.reseller, now(),
    jsonb_build_object('source', 'historical_baseline',
                       'as_of_date', st.as_of_date,
                       'remaining', st.remaining,
                       'resolution', st.resolution)
  from public.installation_subscribers sub
  join public.installation_subscriber_state st on st.subscriber_uuid = sub.id
  where st.current_stage in (
      select code from public.installation_stage_definitions where scheme_version_id = v_version)
  on conflict (subscriber_id) do nothing;

  get diagnostics v_created = row_count;

  return jsonb_build_object(
    'scheme_version_id', v_version,
    'subscribers_total', v_total,
    'enrollments_created', v_created,
    'enrollments_pre_existing', v_existing,
    'skipped_unknown_stage', v_skipped_unknown,
    'enrollments_now', (select count(*) from public.installation_enrollments)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. import_installation_entitlements: zone من fdt_commission_scope، لا من
--    عمود "zone" الخام في ملف الرفع. عمود fdt الخام يبقى مصدر التصنيف
--    الوحيد؛ حقل zone من الملف لم يعد يُقرأ إطلاقاً (لا للتخزين ولا للتحقق) —
--    قراءته كانت هي الثغرة نفسها.
-- ---------------------------------------------------------------------------

create or replace function public.import_installation_entitlements(
  p_period text,
  p_file_name text,
  p_file_checksum text,
  p_rows jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_batch_id uuid;
  v_item jsonb;
  v_subscriber text;
  v_reseller text;
  v_fdt text;
  v_zone text;
  v_remaining bigint;
  v_stage text;
  v_amount bigint;
  v_key text;
  v_seen text[] := array[]::text[];
  v_source integer := 0;
  v_accepted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_status text;
  v_result jsonb;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Period must use YYYY-MM' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 20000 then
    raise exception 'Rows must contain between 1 and 20000 entries' using errcode = '22023';
  end if;

  -- Replaying the same request returns the original outcome instead of importing twice.
  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.batch.imported' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('batch', v_existing.after_data, 'replayed', true);
  end if;

  -- One import per period at a time, so two uploads cannot interleave.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('installation-import:' || p_period, 0)
  );

  insert into public.installation_batches (period, file_name, file_checksum, created_by)
  values (p_period, coalesce(btrim(p_file_name), ''), nullif(btrim(coalesce(p_file_checksum, '')), ''), v_actor)
  returning id into v_batch_id;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_source := v_source + 1;
    v_subscriber := btrim(coalesce(v_item ->> 'subscriber_id', ''));
    v_reseller := btrim(coalesce(v_item ->> 'reseller', ''));
    v_fdt := nullif(btrim(coalesce(v_item ->> 'fdt', '')), '');
    v_zone := case when public.fdt_commission_scope(v_fdt) = 'FDT' then 'new' else 'old' end;

    if v_subscriber = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'missing_subscriber');
      continue;
    end if;
    if v_reseller = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'missing_reseller');
      continue;
    end if;

    -- Remaining must be an exact integer; anything else has no stage.
    begin
      v_remaining := (v_item ->> 'remaining')::bigint;
    exception when others then
      v_remaining := null;
    end;
    v_stage := case when v_remaining is null then null
                    else public.installation_stage_for_remaining(v_remaining) end;
    if v_stage is null then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'unknown_remaining');
      continue;
    end if;
    v_amount := public.installation_amount_for_stage(v_stage);

    v_key := lower(v_subscriber) || chr(31) || v_stage;
    if v_key = any(v_seen) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;
    v_seen := array_append(v_seen, v_key);

    if exists (
      select 1 from public.installation_entitlements
      where period = p_period and subscriber_id = v_subscriber and stage = v_stage
    ) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;

    insert into public.installation_entitlements (
      batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
      remaining, stage, amount, payment_status, created_by
    ) values (
      v_batch_id, p_period, v_subscriber,
      btrim(coalesce(v_item ->> 'subscriber_name', '')), v_reseller, v_zone, v_fdt,
      v_remaining, v_stage, v_amount,
      case when v_stage = 'DONE' then 'not_eligible' else 'awaiting_invoice' end,
      v_actor
    );
    v_accepted := v_accepted + 1;
  end loop;

  v_status := case when v_accepted = 0 then 'no_new_rows' else 'completed' end;
  update public.installation_batches
  set source_rows = v_source,
      accepted_rows = v_accepted,
      duplicate_rows = v_duplicate,
      rejected_rows = v_rejected,
      status = v_status
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'id', v_batch_id, 'period', p_period, 'file_name', coalesce(btrim(p_file_name), ''),
    'source_rows', v_source, 'accepted', v_accepted, 'duplicates', v_duplicate,
    'rejected', v_rejected, 'status', v_status,
    'rejections', case when jsonb_array_length(v_rejects) > 50
                       then jsonb_build_object('truncated', true)
                       else v_rejects end
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, extra, before_data, after_data, request_id
  ) values (
    v_actor, 'installation.batch.imported', 'installation_batch', v_batch_id, 'entitlements',
    '0', v_accepted::text, p_period,
    jsonb_build_object('period', p_period, 'file_name', coalesce(btrim(p_file_name), '')),
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. النسخ الرجعي — تصحيح الصفوف القائمة، لا مالاً، تصنيفاً معروضاً فقط.
--    zone لا يُستخدَم في حساب أي مبلغ/نسبة في أي هجرة سابقة (بُحث عبره
--    عبر كل الهجرات قبل كتابة هذا الملف) — فتصحيحه رجعياً، حتى على صفوف
--    مدفوعة، لا يُعيد كتابة مالاً ولا يخالف حظر «لا تعديل مبالغ الإنتاج».
-- ---------------------------------------------------------------------------

do $$
begin
  update public.installation_enrollments
  set zone = case when public.fdt_commission_scope(fdt_code) = 'FDT' then 'new' else 'old' end
  where zone is distinct from
        (case when public.fdt_commission_scope(fdt_code) = 'FDT' then 'new' else 'old' end);

  update public.installation_entitlements
  set zone = case when public.fdt_commission_scope(fdt) = 'FDT' then 'new' else 'old' end
  where zone is distinct from
        (case when public.fdt_commission_scope(fdt) = 'FDT' then 'new' else 'old' end);
end;
$$;

commit;
