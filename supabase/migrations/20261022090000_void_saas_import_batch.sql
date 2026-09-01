-- VOID لاستيراد SaaS خاطئ — دلالة منطقية لا حذفاً مادياً (DEC-005 في
-- docs/BUSINESS_DECISIONS_REQUIRED.md، القرار المسجَّل بADR في docs/DECISIONS.md).
--
-- القاعدة المعتمدة حرفياً من صاحب المنتج:
--   • لا حذف مادي لتاريخ مالي إطلاقاً.
--   • إن لم تكن الدفعة قد أثّرت بعد على نتائج مُعتمَدة/مدفوعة: يجوز لمسؤول
--     مخوَّل إلغاءها منطقياً (VOID) بسبب إلزامي + فاعل + وقت، مدقَّقاً بالكامل،
--     على أن تتوقف بياناتها عن المشاركة في أي حساب مستقبلي، مع بقاء إعادة
--     استيراد المصدر المصحَّح ممكنة.
--   • إن كانت الدفعة قد أثّرت فعلاً على نتائج FINALIZED/PARTIALLY_PAID/PAID/
--     CLOSED: رفض صريح — لا حذف/إعادة كتابة/إعادة حساب صامتة؛ مسار التصحيح
--     القائم (activation_corrections) هو الأداة لتلك الحالة، لا VOID.
--
-- الحدّ الآمن المطبَّق هنا (موثَّق صراحةً، لا مفترَض): يغطي VOID سلسلة العمولة
-- الكاملة (saas_activation_events → commission_qualifying_events →
-- commission_event_entitlements → commission_cycles) التي لها حدود نضج
-- (finalized/paid) مؤكَّدة ومُختبَرة أصلاً في هذا المستودع. مسار التنصيب
-- الموازي (installation_enrollments) يستهلك نفس الأحداث الخام لكنه غير
-- مربوط بـsaas_import_batches برابط مفتاحي مؤكَّد؛ بدل افتراض السلامة هناك،
-- هذه المهاجرة تغلق بأمان: أي دفعة أنتجت أي تسجيل تنصيب تُرفض من VOID كاملاً
-- حتى تُحسم تلك الحالة صراحة لاحقاً — إغلاق محافظ، لا تجاهل للمخاطر.
--
-- forward-only. لا صف مالي قائم يُمَس، ولا دورة عمولة تُعاد حسابها.

begin;

-- ---------------------------------------------------------------------------
-- 1. قدرة مخصّصة، منفصلة عن saas.import — الإلغاء أخطر من الاستيراد نفسه.
-- ---------------------------------------------------------------------------

insert into public.permission_capabilities
  (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable) values
  ('saas.void_import', 'saas', 'إلغاء دفعة استيراد (VOID)', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', c.key from public.permission_capabilities c
where c.key = 'saas.void_import'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. عمود الحالة + إسناد الإلغاء — نفس نمط finalized_by/finalized_at في
--    commission_cycles، لا جدولاً منفصلاً: الإلغاء تحوّل حالة على الكيان
--    نفسه، لا حقيقة جديدة تُسجَّل عن بيانات ثابتة (خلافاً لـactivation_corrections).
-- ---------------------------------------------------------------------------

alter table public.saas_import_batches
  add column if not exists voided_by uuid references auth.users(id),
  add column if not exists voided_at timestamptz,
  add column if not exists void_reason text;

alter table public.saas_import_batches
  drop constraint if exists saas_import_batches_status_check;
alter table public.saas_import_batches
  add constraint saas_import_batches_status_check
  check (status in ('draft', 'imported', 'failed', 'rejected', 'voided'));

alter table public.saas_import_batches
  drop constraint if exists saas_import_batches_voided_is_attributed;
alter table public.saas_import_batches
  add constraint saas_import_batches_voided_is_attributed
  check (status <> 'voided' or (
    voided_by is not null and voided_at is not null
    and btrim(coalesce(void_reason, '')) <> ''));

-- دفعة أُلغيت تصبح ثابتة تماماً — لا حتى declare_import_completeness يمسّها بعد.
create or replace function public.protect_voided_import_batch()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'voided' then
    raise exception 'A voided import batch is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_voided_import_batch on public.saas_import_batches;
create trigger trg_protect_voided_import_batch
before update on public.saas_import_batches
for each row execute function public.protect_voided_import_batch();

-- ---------------------------------------------------------------------------
-- 3. استبعاد بيانات الدفعات المُلغاة من كل حساب مستقبلي.
--
-- commission_qualifying_events هي نقطة العبور الوحيدة من الحدث الخام إلى أي
-- حساب مالي (calculate_commission_cycle يقرأ منها فقط) — استبعادٌ هنا يكفي
-- ولا يحتاج تكراراً في calculate_commission_cycle نفسها. الجسم مطابق حرفياً
-- لتعريف 20261011090000_effective_ownership_and_fdt_scope.sql:54 مع إضافة
-- شرط واحد فقط في النهاية.
-- ---------------------------------------------------------------------------

create or replace view public.commission_qualifying_events as
select
  e.saas_event_id,
  e.event_created_at,
  e.username_key,
  e.saas_user_id,
  e.profile_name as package_code,
  e.raw_parent,
  e.fdt_code,
  e.import_batch_id,
  coalesce(si.id::text, e.saas_user_id, e.username_key) as subscriber_key,
  si.id as subscriber_identity_id,
  si.identity_status,
  case
    when eo.ownership_type is not null then
      case eo.ownership_type
        when 'RESELLER' then 'RESELLER'
        when 'DIRECT_COMPANY' then 'DIRECT_COMPANY'
        when 'FTTH_USER' then 'DIRECT_COMPANY'
        when 'OFFICE' then 'DIRECT_COMPANY'
        when 'NEEDS_REVIEW' then 'UNKNOWN_PARENT'
      end
    else si.source_classification
  end as source_classification,
  case
    when eo.ownership_type is not null then
      case when eo.ownership_type = 'RESELLER' then eo.agent_id end
    else coalesce(si.effective_agent_id, al.agent_id)
  end as effective_agent_id,
  ag.official_name as agent_name,
  f.zone as fdt_zone,
  case when public.fdt_commission_scope(e.fdt_code) = 'FDT' then 'new' else 'old' end as zone,
  public.fdt_commission_scope(e.fdt_code) as scope_type,
  case
    when public.fdt_commission_scope(e.fdt_code) = 'FDT' then e.fdt_code
    else (case
      when eo.ownership_type is not null then
        case when eo.ownership_type = 'RESELLER' then eo.agent_id end
      else coalesce(si.effective_agent_id, al.agent_id)
    end)::text
  end as scope_id,
  p.semantic_category as package_category,
  al.resolution as parent_resolution
from public.saas_activation_events e
left join public.subscriber_identities si on si.username_key = e.username_key
left join public.agent_aliases al
  on al.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(e.raw_parent, '')))
 and al.active
left join lateral public.subscriber_ownership_at(e.username_key, e.event_created_at) eo on true
left join public.agents ag on ag.id = (case
    when eo.ownership_type is not null then
      case when eo.ownership_type = 'RESELLER' then eo.agent_id end
    else coalesce(si.effective_agent_id, al.agent_id)
  end)
left join public.fdts f on f.code = e.fdt_code
left join public.packages p on p.code = e.profile_name
where coalesce(e.canceled, false) = false
  and not exists (
    select 1 from public.saas_import_batches b
    where b.id = e.import_batch_id and b.status = 'voided');

revoke all on table public.commission_qualifying_events from authenticated, anon, public;
grant select on table public.commission_qualifying_events to authenticated;

-- بوابة تسجيل التنصيب: حدث من دفعة مُلغاة يُرفض بوضوح، لا يُهمَل صامتاً —
-- نفس منطق SOURCE_INCOMPLETE الموجود أصلاً، مانع إضافي بجانبه لا بديل عنه.
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

  if v_event.canceled is true then
    v_blockers := v_blockers || 'EVENT_CANCELED'::text;
  end if;

  select semantic_category into v_category from public.packages
  where code = v_event.profile_name;
  if v_category is null then
    v_blockers := v_blockers || 'UNKNOWN_PACKAGE'::text;
  elsif v_category = 'DEBT_SERVICE' then
    v_blockers := v_blockers || 'DEBT_SERVICE_NEVER_QUALIFIES'::text;
  elsif v_category <> 'PAID_PACKAGE' then
    v_blockers := v_blockers || 'PACKAGE_NOT_QUALIFYING'::text;
  end if;

  select * into v_batch from public.saas_import_batches where id = v_event.import_batch_id;
  if v_batch.status = 'voided' then
    v_blockers := v_blockers || 'BATCH_VOIDED'::text;
  end if;
  if v_batch.completeness_status is distinct from 'COMPLETE' then
    v_blockers := v_blockers || 'SOURCE_INCOMPLETE'::text;
  end if;

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

  select * into v_alias from public.resolve_parent_alias(v_event.raw_parent);
  if v_alias.resolution = 'needs_review' then
    v_blockers := v_blockers || 'PARENT_NEEDS_REVIEW'::text;
  end if;

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

-- ---------------------------------------------------------------------------
-- 4. دالة الإلغاء نفسها — فشل صريح أمام أي أثر مالي معتمَد، لا حذفاً ولا
--    إعادة حساب صامتة.
-- ---------------------------------------------------------------------------

create or replace function public.void_saas_import_batch(
  p_batch_id uuid,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_batch public.saas_import_batches%rowtype;
  v_existing public.audit_logs%rowtype;
  v_posted_count integer;
  v_enrollment_count integer;
begin
  perform public.require_capability('saas.void_import');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason is required' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_batch from public.saas_import_batches where id = p_batch_id for update;
  if not found then
    raise exception 'Import batch was not found' using errcode = 'P0002';
  end if;
  if v_batch.status = 'voided' then
    raise exception 'This batch was already voided' using errcode = '42501';
  end if;
  -- draft لم يُدرِج صفوفاً بعد؛ failed/rejected لا صفوف ملتزمة لهما — لا شيء
  -- ليُلغى منطقياً في الحالتين. فقط imported تحمل بيانات فعلية في الجداول الخام.
  if v_batch.status <> 'imported' then
    raise exception 'Only an imported batch with committed rows can be voided (status=%)', v_batch.status
      using errcode = '42501';
  end if;

  -- الفشل الصريح المطلوب: أثّرت الدفعة فعلاً على دورة معتمدة/مدفوعة؟
  select count(*) into v_posted_count
  from public.commission_event_entitlements ce
  join public.saas_activation_events e on e.saas_event_id = ce.activation_event_id
  join public.commission_cycles c on c.id = ce.cycle_id
  where e.import_batch_id = p_batch_id
    and c.status in ('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED');

  if v_posted_count > 0 then
    raise exception
      'This batch already affected % finalized/paid commission row(s); use the correction workflow instead of VOID',
      v_posted_count
      using errcode = '42501';
  end if;

  -- إغلاق محافظ لمسار التنصيب الموازي: لا رابط مفتاحي مؤكَّد بعد بين
  -- installation_enrollments وdفعة الاستيراد، فالرفض هو الافتراضي الآمن.
  select count(*) into v_enrollment_count
  from public.installation_enrollments ie
  join public.saas_activation_events e on e.saas_event_id = ie.first_qualifying_event_id
  where e.import_batch_id = p_batch_id;

  if v_enrollment_count > 0 then
    raise exception
      'This batch already produced % installation enrollment(s); void is not yet supported for this case',
      v_enrollment_count
      using errcode = '42501';
  end if;

  update public.saas_import_batches
  set status = 'voided', voided_by = v_actor, voided_at = now(), void_reason = btrim(p_reason)
  where id = p_batch_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra)
  values (
    v_actor, 'saas.import_batch.voided', 'status', v_batch.status, 'voided',
    'saas_import_batch', p_batch_id, p_request_id, btrim(p_reason));

  return jsonb_build_object(
    'replayed', false, 'request_id', p_request_id,
    'batch_id', p_batch_id, 'status', 'voided');
end;
$fn$;

revoke execute on function public.void_saas_import_batch(uuid, text, uuid) from public, anon;
grant execute on function public.void_saas_import_batch(uuid, text, uuid) to authenticated;

commit;
