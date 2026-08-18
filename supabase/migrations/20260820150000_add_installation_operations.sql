-- التشغيل: تسجيل، دورات، تعليقات، فواتير، أهلية، ودفعات.
--
-- هذه الطبقة تحوّل أجور التنصيب من بيانات تاريخية للقراءة إلى مسار عمل. لا
-- تُنشئ مالاً بنفسها: كل مبلغ يبقى مشتقاً من إصدار المخطط، وكل دفع يمرّ
-- بالمسار المالي القائم ودفتره.
--
-- المبدأ الحاكم: الأهلية تُحسَب على الخادم وتُعاد قبل الدفع مباشرة. حالة
-- «جاهز» محسوبة قبل دقيقة ليست إذناً بالدفع الآن.
--
-- forward-only. لا صف مالي تاريخي يُمَس.

begin;

-- ---------------------------------------------------------------------------
-- 1. الدورات المالية.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_cycles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'DRAFT',
  scheme_version_id uuid references public.installation_scheme_versions(id),
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  closed_by uuid references auth.users(id),
  closed_at timestamptz,
  reopened_by uuid references auth.users(id),
  reopened_at timestamptz,
  reopen_reason text,
  snapshot jsonb,
  constraint installation_cycles_name_key unique (name),
  constraint installation_cycles_dates_check check (end_date >= start_date),
  constraint installation_cycles_status_check check (status in (
    'DRAFT','DATA_IMPORTED','UNDER_REVIEW','READY_FOR_PAYMENT',
    'PARTIALLY_PAID','PAID','CLOSED')),
  -- المقفلة تحمل من أقفلها ومتى ولقطتها.
  constraint installation_cycles_closed_is_attributed
    check (status <> 'CLOSED' or (closed_by is not null and closed_at is not null))
);

create index if not exists installation_cycles_status_idx on public.installation_cycles (status);

-- ---------------------------------------------------------------------------
-- 2. التسجيل في مخطط.
--
-- التسجيل يُجمّد إصدار المخطط. إصدار V2 لاحقاً لا يُعيد كتابة مال من سُجّل
-- على V1 — وهذا هو سبب وجود الجدول أصلاً.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_enrollments (
  id uuid primary key default gen_random_uuid(),
  subscriber_id text not null,
  subscriber_identity_id uuid references public.subscriber_identities(id) on delete set null,
  scheme_version_id uuid not null references public.installation_scheme_versions(id),
  origin text not null,
  effective_agent_id uuid references public.agents(id) on delete set null,
  agent_name_at_enrollment text,
  fdt_code text,
  zone text,
  current_stage_code text,
  status text not null default 'ACTIVE',
  -- دليل الجِدّة وقت التسجيل، محفوظاً لا مُعاد حسابه.
  newness_evidence jsonb not null default '{}'::jsonb,
  first_qualifying_event_id text,
  source_cycle_id uuid references public.installation_cycles(id),
  enrolled_by uuid references auth.users(id),
  enrolled_at timestamptz not null default now(),
  constraint installation_enrollments_subscriber_key unique (subscriber_id),
  constraint installation_enrollments_origin_check
    check (origin in ('HISTORICAL_BASELINE', 'NEW_INSTALLATION', 'MANUAL')),
  constraint installation_enrollments_status_check
    check (status in ('ACTIVE', 'COMPLETED', 'CANCELLED')),
  constraint installation_enrollments_zone_check check (zone is null or zone in ('old','new')),
  -- التسجيل الجديد يلزمه حدث مؤهِّل. التاريخي معفى: ماضيه سابق للنظام.
  constraint installation_enrollments_new_needs_event
    check (origin <> 'NEW_INSTALLATION' or first_qualifying_event_id is not null)
);

create index if not exists installation_enrollments_agent_idx
  on public.installation_enrollments (effective_agent_id);
create index if not exists installation_enrollments_stage_idx
  on public.installation_enrollments (current_stage_code);

-- حدث تفعيل واحد لا يموّل تسجيلين.
create unique index if not exists installation_enrollments_event_key
  on public.installation_enrollments (first_qualifying_event_id)
  where first_qualifying_event_id is not null;

-- ---------------------------------------------------------------------------
-- 3. أسباب التعليق — بيانات رئيسية، لا ثوابت في الكود.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_hold_reasons (
  code text primary key,
  label_ar text not null,
  is_system boolean not null default false,
  blocks_payment boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.installation_hold_reasons (code, label_ar, is_system) values
  ('MISSING_INVOICE',      'فاتورة ناقصة',        true),
  ('FINANCIAL_MISMATCH',   'عدم تطابق مالي',      true),
  ('DUPLICATE',            'تكرار',               true),
  ('UNMATCHED_SUBSCRIBER', 'مشترك غير مطابَق',    true),
  ('IDENTITY_CONFLICT',    'تعارض هوية',          true),
  ('UNKNOWN_PARENT',       'أب غير معروف',        true),
  ('UNKNOWN_PACKAGE',      'باقة غير معروفة',     true),
  ('SOURCE_INCOMPLETE',    'مصدر غير مكتمل',      true),
  ('ALREADY_PAID',         'مدفوع سلفاً',         true),
  ('INVALID_STAGE',        'مرحلة غير صالحة',     true)
on conflict (code) do nothing;

create table if not exists public.installation_holds (
  id uuid primary key default gen_random_uuid(),
  subscriber_id text not null,
  enrollment_id uuid references public.installation_enrollments(id) on delete cascade,
  entitlement_id uuid references public.installation_entitlements(id) on delete cascade,
  stage_code text,
  reason_code text not null references public.installation_hold_reasons(code),
  hold_type text not null default 'SYSTEM',
  note text,
  status text not null default 'ACTIVE',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  released_by uuid references auth.users(id),
  released_at timestamptz,
  release_reason text,
  constraint installation_holds_type_check check (hold_type in ('SYSTEM', 'MANUAL')),
  constraint installation_holds_status_check check (status in ('ACTIVE', 'RELEASED')),
  -- المرفوع يحمل من رفعه ومتى وبأي سبب.
  constraint installation_holds_released_is_attributed
    check (status <> 'RELEASED'
           or (released_by is not null and released_at is not null
               and btrim(coalesce(release_reason, '')) <> ''))
);

create index if not exists installation_holds_subscriber_idx
  on public.installation_holds (subscriber_id, status);

-- تعليق نشط واحد لكل سبب على المشترك والمرحلة.
create unique index if not exists installation_holds_active_key
  on public.installation_holds (subscriber_id, coalesce(stage_code, ''), reason_code)
  where status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- 4. الفواتير — دليل جاهز لأودو، بلا نداء خارجي.
--
-- transaction_id في SaaS ليس رقم فاتورة أودو. الحقول منفصلة عمداً حتى لا
-- يُبنى ربط على افتراض.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_invoices (
  id uuid primary key default gen_random_uuid(),
  subscriber_id text not null,
  enrollment_id uuid references public.installation_enrollments(id) on delete set null,
  entitlement_id uuid references public.installation_entitlements(id) on delete set null,
  stage_code text,
  activation_event_id text,
  external_invoice_id text,
  invoice_number text,
  invoice_reference text,
  invoice_source text not null default 'MANUAL',
  amount bigint,
  invoice_date date,
  status text not null default 'PENDING',
  verification_source text,
  verified_by uuid references auth.users(id),
  verified_at timestamptz,
  rejected_by uuid references auth.users(id),
  rejected_at timestamptz,
  rejection_reason text,
  -- حقول أودو المستقبلية: موجودة ليُملأ بها لاحقاً بلا مهاجرة جديدة.
  odoo_model text,
  odoo_record_id text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint installation_invoices_status_check
    check (status in ('PENDING', 'VERIFIED', 'REJECTED')),
  constraint installation_invoices_source_check
    check (invoice_source in ('MANUAL', 'ODOO', 'SAAS', 'IMPORT')),
  constraint installation_invoices_verified_is_attributed
    check (status <> 'VERIFIED' or (verified_by is not null and verified_at is not null)),
  constraint installation_invoices_rejected_is_attributed
    check (status <> 'REJECTED'
           or (rejected_by is not null and rejected_at is not null
               and btrim(coalesce(rejection_reason, '')) <> ''))
);

create index if not exists installation_invoices_subscriber_idx
  on public.installation_invoices (subscriber_id, stage_code, status);

-- ---------------------------------------------------------------------------
-- 5. دفعات الدفع.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_payment_batches (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  cycle_id uuid references public.installation_cycles(id) on delete restrict,
  status text not null default 'DRAFT',
  prepared_by uuid references auth.users(id),
  prepared_at timestamptz not null default now(),
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  total_amount bigint not null default 0,
  item_count integer not null default 0,
  constraint installation_payment_batches_name_key unique (name),
  constraint installation_payment_batches_status_check
    check (status in ('DRAFT', 'READY', 'POSTED', 'CANCELLED')),
  constraint installation_payment_batches_posted_is_attributed
    check (status <> 'POSTED' or (posted_by is not null and posted_at is not null))
);

create table if not exists public.installation_payment_batch_items (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.installation_payment_batches(id) on delete cascade,
  entitlement_id uuid not null references public.installation_entitlements(id) on delete restrict,
  subscriber_id text not null,
  agent_name text,
  stage_code text not null,
  amount bigint not null,
  invoice_id uuid references public.installation_invoices(id),
  status text not null default 'PENDING',
  blocked_reason text,
  paid_at timestamptz,
  constraint installation_payment_batch_items_identity unique (batch_id, entitlement_id),
  constraint installation_payment_batch_items_status_check
    check (status in ('PENDING', 'PAID', 'BLOCKED', 'SKIPPED')),
  constraint installation_payment_batch_items_amount_check check (amount >= 0)
);

-- استحقاق واحد لا يدخل دفعتين غير ملغيتين.
create unique index if not exists installation_payment_batch_items_entitlement_key
  on public.installation_payment_batch_items (entitlement_id)
  where status in ('PENDING', 'PAID');

-- ---------------------------------------------------------------------------
-- 6. إدارة اكتمال المصدر.
--
-- الاكتمال قرار تشغيلي مُدقَّق، لا مفتاح في الواجهة. تحويل دفعة إلى COMPLETE
-- يلزمه حدّا تغطية ودليل وفاعل، لأن هذا الإعلان وحده يفتح باب تصنيف NEW.
-- ---------------------------------------------------------------------------

create table if not exists public.import_completeness_declarations (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.saas_import_batches(id) on delete cascade,
  previous_status text not null,
  declared_status text not null,
  coverage_start date,
  coverage_end date,
  evidence text not null,
  declared_by uuid not null references auth.users(id),
  declared_at timestamptz not null default now(),
  constraint import_completeness_declarations_status_check
    check (declared_status in ('UNKNOWN', 'PARTIAL', 'COMPLETE')),
  -- الاكتمال دعوى قوية: لا تُقبل بلا حدود تغطية ودليل مكتوب.
  constraint import_completeness_declarations_complete_needs_proof
    check (declared_status <> 'COMPLETE'
           or (coverage_start is not null and coverage_end is not null
               and btrim(evidence) <> '' and coverage_end >= coverage_start))
);

create or replace function public.declare_import_completeness(
  p_batch_id uuid,
  p_status text,
  p_coverage_start date,
  p_coverage_end date,
  p_evidence text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_batch public.saas_import_batches%rowtype;
begin
  perform public.require_capability('saas.import');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_batch from public.saas_import_batches where id = p_batch_id for update;
  if not found then
    raise exception 'Import batch was not found' using errcode = 'P0002';
  end if;

  insert into public.import_completeness_declarations
    (import_batch_id, previous_status, declared_status,
     coverage_start, coverage_end, evidence, declared_by)
  values (p_batch_id, v_batch.completeness_status, p_status,
          p_coverage_start, p_coverage_end, coalesce(p_evidence, ''), v_actor);

  update public.saas_import_batches
  set completeness_status = p_status,
      declared_coverage_start = coalesce(p_coverage_start, declared_coverage_start),
      declared_coverage_end = coalesce(p_coverage_end, declared_coverage_end)
  where id = p_batch_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra
  ) values (
    v_actor, 'import.completeness.declared', 'completeness_status',
    v_batch.completeness_status, p_status, 'saas_import_batch', p_batch_id,
    p_request_id, coalesce(p_evidence, '')
  );

  -- الإعلان لا يُنشئ مالاً بنفسه. إعادة التقييم خطوة لاحقة صريحة، حتى لا
  -- يتحوّل تبديل حقل إلى توليد استحقاقات صامت.
  return jsonb_build_object(
    'replayed', false, 'batch_id', p_batch_id, 'status', p_status,
    'reevaluation_required', p_status = 'COMPLETE' and v_batch.completeness_status <> 'COMPLETE'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. محرّك الأهلية — الحقيقة على الخادم.
--
-- يعيد قراراً مع أسبابه مُهيكلة. الواجهة تعرض؛ ولا تقرّر.
-- ---------------------------------------------------------------------------

create or replace function public.installation_entitlement_eligibility(p_entitlement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ent public.installation_entitlements%rowtype;
  v_enrollment public.installation_enrollments%rowtype;
  v_blockers text[] := array[]::text[];
  v_stage public.installation_stage_definitions%rowtype;
  v_identity public.subscriber_identities%rowtype;
  v_invoice_ok boolean;
begin
  select * into v_ent from public.installation_entitlements where id = p_entitlement_id;
  if not found then
    return jsonb_build_object('eligible', false, 'blockers', array['NOT_FOUND']);
  end if;

  if v_ent.payment_status = 'paid' or v_ent.paid_amount > 0 then
    v_blockers := v_blockers || 'ALREADY_PAID'::text;
  end if;
  if v_ent.stage = 'DONE' then
    v_blockers := v_blockers || 'INVALID_STAGE'::text;
  end if;

  select * into v_enrollment from public.installation_enrollments
  where subscriber_id = v_ent.subscriber_id;
  if not found then
    v_blockers := v_blockers || 'NOT_ENROLLED'::text;
  else
    if v_enrollment.status <> 'ACTIVE' then
      v_blockers := v_blockers || 'ENROLLMENT_INACTIVE'::text;
    end if;
    -- المرحلة المطلوبة يجب أن تكون التالية فعلاً، لا مرحلة أُقفزت.
    if v_enrollment.current_stage_code is distinct from v_ent.stage then
      v_blockers := v_blockers || 'STAGE_OUT_OF_SEQUENCE'::text;
    end if;
    select * into v_stage from public.installation_stage_definitions
    where scheme_version_id = v_enrollment.scheme_version_id and code = v_ent.stage;
    if not found then
      v_blockers := v_blockers || 'STAGE_NOT_IN_SCHEME'::text;
    elsif v_stage.amount is distinct from v_ent.amount then
      -- المبلغ يأتي من المخطط. اختلافه يعني أن أحدهما مغشوش.
      v_blockers := v_blockers || 'AMOUNT_DOES_NOT_MATCH_SCHEME'::text;
    end if;
  end if;

  -- الهوية والعائدية.
  select * into v_identity from public.subscriber_identities
  where username_key = pg_catalog.lower(pg_catalog.btrim(v_ent.subscriber_id))
  limit 1;
  if found then
    if v_identity.identity_status = 'CONFLICT' then
      v_blockers := v_blockers || 'IDENTITY_CONFLICT'::text;
    end if;
    if v_identity.source_classification = 'UNKNOWN_PARENT' then
      v_blockers := v_blockers || 'UNKNOWN_PARENT'::text;
    end if;
    -- الشركة المباشرة ليست استحقاق وكيل ما لم يُسمح صراحة.
    if v_identity.source_classification = 'DIRECT_COMPANY' then
      v_blockers := v_blockers || 'DIRECT_COMPANY_NOT_PAYABLE'::text;
    end if;
  end if;

  -- الفاتورة، إن اشترطها المخطط.
  if v_stage.id is null or v_stage.requires_invoice then
    select exists (
      select 1 from public.installation_invoices i
      where i.subscriber_id = v_ent.subscriber_id
        and i.stage_code is not distinct from v_ent.stage
        and i.status = 'VERIFIED'
    ) into v_invoice_ok;
    -- التوافق مع المسار القديم: تدقيق الفاتورة على الاستحقاق نفسه يكفي.
    if not v_invoice_ok and v_ent.invoice_status <> 'approved' then
      v_blockers := v_blockers || 'MISSING_INVOICE'::text;
    end if;
  end if;

  -- أي تعليق نشط يحجب.
  if exists (
    select 1 from public.installation_holds h
    join public.installation_hold_reasons r on r.code = h.reason_code
    where h.subscriber_id = v_ent.subscriber_id and h.status = 'ACTIVE'
      and r.blocks_payment
      and (h.stage_code is null or h.stage_code = v_ent.stage)
  ) then
    v_blockers := v_blockers || 'ON_HOLD'::text;
  end if;

  -- الحالة التاريخية غير المحسومة لا تُدفع أبداً.
  -- الحالة مفتاحها uuid المشترك لا معرّفه النصّي، فالوصل يمرّ بجدول المشتركين.
  if exists (
    select 1
    from public.installation_subscribers sub
    join public.installation_subscriber_state s on s.subscriber_uuid = sub.id
    where sub.subscriber_id = v_ent.subscriber_id
      and (s.resolution <> 'resolved' or s.payment_eligible is not true)
  ) then
    v_blockers := v_blockers || 'UNRESOLVED_HISTORICAL_STATE'::text;
  end if;

  return jsonb_build_object(
    'entitlement_id', p_entitlement_id,
    'subscriber_id', v_ent.subscriber_id,
    'stage', v_ent.stage,
    'amount', v_ent.amount,
    'eligible', cardinality(v_blockers) = 0,
    'blockers', v_blockers
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. التعليق ورفعه.
-- ---------------------------------------------------------------------------

create or replace function public.place_installation_hold(
  p_subscriber_id text, p_stage_code text, p_reason_code text,
  p_note text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  perform public.require_capability('installation.hold');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true);
  end if;

  insert into public.installation_holds
    (subscriber_id, stage_code, reason_code, hold_type, note, created_by)
  values (p_subscriber_id, p_stage_code, p_reason_code, 'MANUAL', p_note, v_actor)
  on conflict do nothing
  returning id into v_id;

  insert into public.audit_logs (actor_id, action, field, new_value,
    entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.hold.placed', p_reason_code, 'ACTIVE',
    'installation_subscriber', null, p_request_id,
    p_subscriber_id || coalesce(':' || p_stage_code, ''));

  return jsonb_build_object('replayed', false, 'hold_id', v_id);
end;
$$;

create or replace function public.release_installation_hold(
  p_hold_id uuid, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_hold public.installation_holds%rowtype;
begin
  perform public.require_capability('installation.release_hold');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A release reason is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true);
  end if;

  update public.installation_holds
  set status = 'RELEASED', released_by = v_actor, released_at = now(), release_reason = p_reason
  where id = p_hold_id and status = 'ACTIVE'
  returning * into v_hold;

  if not found then
    raise exception 'No active hold was found' using errcode = 'P0002';
  end if;

  insert into public.audit_logs (actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.hold.released', v_hold.reason_code, 'ACTIVE', 'RELEASED',
    'installation_hold', p_hold_id, p_request_id, p_reason);

  -- الرفع لا يدفع؛ الأهلية تُعاد وحدها عند الطلب التالي.
  return jsonb_build_object('replayed', false, 'hold_id', p_hold_id,
                            'subscriber_id', v_hold.subscriber_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. تدقيق الفاتورة.
-- ---------------------------------------------------------------------------

create or replace function public.verify_installation_invoice(
  p_invoice_id uuid, p_verified boolean, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.installation_invoices%rowtype;
begin
  perform public.require_capability(case when p_verified then 'invoice.verify' else 'invoice.reject' end);
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true);
  end if;
  if not p_verified and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A rejection reason is required' using errcode = '22023';
  end if;

  update public.installation_invoices
  set status = case when p_verified then 'VERIFIED' else 'REJECTED' end,
      verified_by = case when p_verified then v_actor else verified_by end,
      verified_at = case when p_verified then now() else verified_at end,
      verification_source = case when p_verified then 'MANUAL_REVIEW' else verification_source end,
      rejected_by = case when p_verified then rejected_by else v_actor end,
      rejected_at = case when p_verified then rejected_at else now() end,
      rejection_reason = case when p_verified then rejection_reason else p_reason end
  where id = p_invoice_id
  returning * into v_row;

  if not found then
    raise exception 'Invoice was not found' using errcode = 'P0002';
  end if;

  insert into public.audit_logs (actor_id, action, field, new_value,
    entity_type, entity_id, after_data, request_id, extra)
  values (v_actor, 'installation.invoice.reviewed', 'status', v_row.status,
    'installation_invoice', p_invoice_id, to_jsonb(v_row), p_request_id, coalesce(p_reason, ''));

  return jsonb_build_object('replayed', false, 'status', v_row.status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. إعادة التحقق قبل الترحيل.
--
-- هذه هي النقطة الحرجة: حالة «جاهز» في الواجهة ليست إذناً. كل بند يُعاد
-- تقييمه لحظة الترحيل، والمحجوب يُوسَم ولا يُدفع.
-- ---------------------------------------------------------------------------

create or replace function public.revalidate_payment_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item record;
  v_eval jsonb;
  v_ok integer := 0;
  v_blocked integer := 0;
begin
  perform public.require_capability('payment.prepare');

  for v_item in
    select * from public.installation_payment_batch_items
    where batch_id = p_batch_id and status = 'PENDING'
  loop
    v_eval := public.installation_entitlement_eligibility(v_item.entitlement_id);
    if (v_eval ->> 'eligible')::boolean then
      update public.installation_payment_batch_items
      set blocked_reason = null where id = v_item.id;
      v_ok := v_ok + 1;
    else
      update public.installation_payment_batch_items
      set status = 'BLOCKED', blocked_reason = v_eval ->> 'blockers'
      where id = v_item.id;
      v_blocked := v_blocked + 1;
    end if;
  end loop;

  return jsonb_build_object('batch_id', p_batch_id, 'eligible', v_ok, 'blocked', v_blocked);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'installation_cycles','installation_enrollments','installation_hold_reasons',
    'installation_holds','installation_invoices','installation_payment_batches',
    'installation_payment_batch_items','import_completeness_declarations'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
  end loop;
end;
$$;

create policy installation_cycles_select on public.installation_cycles
  for select to authenticated using (public.has_capability('cycle.view'));
create policy installation_enrollments_select on public.installation_enrollments
  for select to authenticated using (public.has_capability('installation.view'));
create policy installation_hold_reasons_select on public.installation_hold_reasons
  for select to authenticated using (true);
create policy installation_holds_select on public.installation_holds
  for select to authenticated using (public.has_capability('installation.view'));
create policy installation_invoices_select on public.installation_invoices
  for select to authenticated using (public.has_capability('invoice.view'));
create policy installation_payment_batches_select on public.installation_payment_batches
  for select to authenticated using (public.has_capability('payment.view'));
create policy installation_payment_batch_items_select on public.installation_payment_batch_items
  for select to authenticated using (public.has_capability('payment.view'));
create policy import_completeness_declarations_select on public.import_completeness_declarations
  for select to authenticated using (public.has_capability('saas.review'));

do $$
declare f text;
begin
  foreach f in array array[
    'public.installation_entitlement_eligibility(uuid)',
    'public.place_installation_hold(text, text, text, text, uuid)',
    'public.release_installation_hold(uuid, text, uuid)',
    'public.verify_installation_invoice(uuid, boolean, text, uuid)',
    'public.revalidate_payment_batch(uuid)',
    'public.declare_import_completeness(uuid, text, date, date, text, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
