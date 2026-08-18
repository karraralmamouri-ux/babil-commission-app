-- ربط المسار: بوابة التسجيل الجديد، وصل الأساس التاريخي، وحارس الدفع.
--
-- ثلاث وصلات تُحوّل الجداول السابقة إلى مسار عمل حقيقي:
--   • التسجيل الجديد لا يقع إلا بدليل خادمي كامل.
--   • الـ5,693 التاريخيون يُوصَلون بـV1 من حالتهم الحالية، بلا إعادة بناء مال.
--   • الدفع يمرّ بمحرّك الأهلية قبل أن يلمس قرشاً.
--
-- forward-only. لا صف مالي تاريخي يتغيّر.

begin;

-- ---------------------------------------------------------------------------
-- 1. بوابة التسجيل الجديد.
--
-- كل شرط هنا خادمي. الواجهة قد تطلب التسجيل؛ ولا تقرّره.
-- ---------------------------------------------------------------------------

create or replace function public.evaluate_enrollment_gate(
  p_username_key text,
  p_event_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_blockers text[] := array[]::text[];
  v_event public.saas_activation_events%rowtype;
  v_identity public.subscriber_identities%rowtype;
  v_class public.subscriber_classifications%rowtype;
  v_batch public.saas_import_batches%rowtype;
  v_category text;
  v_alias record;
begin
  select * into v_event from public.saas_activation_events where saas_event_id = p_event_id;
  if not found then
    return jsonb_build_object('allowed', false, 'blockers', array['EVENT_NOT_FOUND']);
  end if;

  -- الحدث الملغى لا يموّل شيئاً.
  if v_event.canceled is true then
    v_blockers := v_blockers || 'EVENT_CANCELED'::text;
  end if;

  -- الدلالة من سجل الباقات؛ والأهلية من تهيئة المخطط. المجهول يُراجَع.
  select semantic_category into v_category from public.packages
  where code = v_event.profile_name;
  if v_category is null then
    v_blockers := v_blockers || 'UNKNOWN_PACKAGE'::text;
  elsif v_category = 'DEBT_SERVICE' then
    v_blockers := v_blockers || 'DEBT_SERVICE_NEVER_QUALIFIES'::text;
  elsif v_category <> 'PAID_PACKAGE' then
    v_blockers := v_blockers || 'PACKAGE_NOT_QUALIFYING'::text;
  end if;

  -- اكتمال المصدر. الحدث من دفعة مجهولة الاكتمال لا يُنشئ تسجيلاً تلقائياً.
  select * into v_batch from public.saas_import_batches where id = v_event.import_batch_id;
  if v_batch.completeness_status is distinct from 'COMPLETE' then
    v_blockers := v_blockers || 'SOURCE_INCOMPLETE'::text;
  end if;

  -- الهوية.
  select * into v_identity from public.subscriber_identities
  where username_key = p_username_key limit 1;
  if not found then
    v_blockers := v_blockers || 'UNMATCHED_SUBSCRIBER'::text;
  else
    if v_identity.identity_status = 'CONFLICT' then
      v_blockers := v_blockers || 'IDENTITY_CONFLICT'::text;
    elsif v_identity.identity_status <> 'MATCHED' then
      v_blockers := v_blockers || 'IDENTITY_NOT_RESOLVED'::text;
    end if;
    if v_identity.source_classification = 'DIRECT_COMPANY' then
      v_blockers := v_blockers || 'DIRECT_COMPANY_NOT_ELIGIBLE'::text;
    end if;
    if v_identity.source_classification = 'UNKNOWN_PARENT' then
      v_blockers := v_blockers || 'UNKNOWN_PARENT'::text;
    end if;
    if v_identity.effective_agent_id is null
       and v_identity.source_classification = 'RESELLER' then
      v_blockers := v_blockers || 'EFFECTIVE_AGENT_UNRESOLVED'::text;
    end if;
  end if;

  -- الأب الخام يجب أن يُحَلّ إلى وكيل معروف أو يُعلن مراجعةً.
  select * into v_alias from public.resolve_parent_alias(v_event.raw_parent);
  if v_alias.resolution = 'needs_review' then
    v_blockers := v_blockers || 'PARENT_NEEDS_REVIEW'::text;
  end if;

  -- التصنيف.
  select * into v_class from public.subscriber_classifications
  where username_key = p_username_key
  order by evaluated_at desc limit 1;
  if not found then
    v_blockers := v_blockers || 'NOT_CLASSIFIED'::text;
  elsif v_class.classification = 'EXISTING' then
    v_blockers := v_blockers || 'SUBSCRIBER_IS_EXISTING'::text;
  elsif v_class.classification = 'NEEDS_REVIEW' then
    v_blockers := v_blockers || 'CLASSIFICATION_NEEDS_REVIEW'::text;
  end if;

  -- لا تسجيل مكرر، ولا حدث يموّل تسجيلين.
  if exists (select 1 from public.installation_enrollments
             where subscriber_id = p_username_key) then
    v_blockers := v_blockers || 'ALREADY_ENROLLED'::text;
  end if;
  if exists (select 1 from public.installation_enrollments
             where first_qualifying_event_id = p_event_id) then
    v_blockers := v_blockers || 'EVENT_ALREADY_USED'::text;
  end if;

  return jsonb_build_object(
    'allowed', cardinality(v_blockers) = 0,
    'username_key', p_username_key,
    'event_id', p_event_id,
    'classification', v_class.classification,
    'source_completeness', v_batch.completeness_status,
    'package_category', v_category,
    'blockers', v_blockers
  );
end;
$$;

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

  insert into public.installation_enrollments (
    subscriber_id, subscriber_identity_id, scheme_version_id, origin,
    effective_agent_id, fdt_code, current_stage_code, status,
    newness_evidence, first_qualifying_event_id, source_cycle_id, enrolled_by
  ) values (
    p_username_key, v_identity.id, v_version, 'NEW_INSTALLATION',
    v_identity.effective_agent_id, coalesce(v_identity.fdt_code, v_event.fdt_code),
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
-- 2. وصل الأساس التاريخي.
--
-- لا يُعاد بناء أي مال. المشترك يُوصَل بـV1 وتُنسَخ مرحلته الحالية من حالته
-- المحسوبة سلفاً، فيكمل النظام من حيث وقف التاريخ لا من P1.
--
-- الحتمية شرط: من لا تُعرف مرحلته لا يُسجَّل، ويُبلَّغ عنه بالعدد بدل أن
-- يُخمَّن له موضع في المخطط.
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
    sub.fdt, null, sub.reseller, now(),
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
-- 3. حارس الدفع.
--
-- الدور وحده لم يعد كافياً: القدرة تُفحص، ومحرّك الأهلية يُستشار قبل أن
-- يتحرّك أي مبلغ. الترتيب مقصود — الفحص قبل القفل وقبل الكتابة.
--
-- التوافق: الدالة القائمة تبقى بتوقيعها ومسارها ودفترها. المضاف حارسان لا
-- منطق مالٍ جديد.
-- ---------------------------------------------------------------------------

create or replace function public.assert_installation_payment_allowed(p_entitlement_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_eval jsonb;
begin
  if not (public.has_capability('payment.execute')
          or public.current_app_role() in ('admin', 'accountant')) then
    raise exception 'Capability payment.execute is required' using errcode = '42501';
  end if;

  v_eval := public.installation_entitlement_eligibility(p_entitlement_id);

  -- الاستحقاق خارج المسار الجديد (بلا تسجيل) يبقى على سلوكه القديم، فلا
  -- تنكسر الدفعات القائمة لمجرد أن طبقة التسجيل وصلت بعدها.
  if not (v_eval ->> 'eligible')::boolean
     and not (v_eval -> 'blockers' ? 'NOT_ENROLLED') then
    raise exception 'Entitlement is not payable: %', v_eval ->> 'blockers'
      using errcode = '42501';
  end if;
end;
$$;

-- الحارس يُركَّب مُشغِّلاً لا نسخةً من دالة الدفع. نسخ جسم الدالة كان
-- سيُنشئ نصّين ماليين يتباعدان مع الوقت؛ والمُشغِّل يمسك كل مسار يُحوّل
-- استحقاقاً إلى «مدفوع»، بما فيه أي مسار يُضاف لاحقاً.
create or replace function public.guard_installation_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.payment_status = 'paid' and old.payment_status is distinct from 'paid' then
    perform public.assert_installation_payment_allowed(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_installation_payment on public.installation_entitlements;
create trigger trg_guard_installation_payment
  before update on public.installation_entitlements
  for each row execute function public.guard_installation_payment();

-- ---------------------------------------------------------------------------
-- 4. الصلاحيات.
-- ---------------------------------------------------------------------------

revoke execute on function public.guard_installation_payment()
  from public, anon, authenticated;

revoke execute on function public.bootstrap_historical_enrollments()
  from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.evaluate_enrollment_gate(text, text)',
    'public.enroll_new_installation(text, text, uuid, uuid)',
    'public.assert_installation_payment_allowed(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
