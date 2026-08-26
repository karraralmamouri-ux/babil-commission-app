begin;

-- ---------------------------------------------------------------------------
-- PR-B1 — إضافة مشترك استثنائي (Manual Exception Intake).
--
-- ينفّذ العقد المصمَّم في docs/product/manual-exception-intake-design.md
-- حرفياً: قدرة مخصّصة، سبب إلزامي، تدقيق كامل، حالة أولية NEEDS_REVIEW لا
-- تصير NEW أبداً تلقائياً، وقفلٌ ضد التكرار على نفس الهوية. لا يمسّ
-- classify_newness ولا installation_grace_status ولا أي مسار استحقاق.
-- ---------------------------------------------------------------------------

create table public.manual_exception_intakes (
  id uuid primary key default gen_random_uuid(),
  exception_type text not null,
  username_key text not null,
  subscriber_name text,
  reseller text,
  import_batch_id uuid references public.saas_import_batches(id) on delete set null,
  source_context text,
  reason text not null,
  supporting_reference text,
  status text not null default 'NEEDS_REVIEW',
  request_id uuid not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz,
  resolution_action text,
  resolution_reason text,
  linked_subscriber_identity_id uuid references public.subscriber_identities(id) on delete set null,
  constraint manual_exception_intakes_type_check
    check (exception_type in (
      'NOT_VISIBLE_IN_SAAS', 'MISSING_HISTORICAL_DATA', 'IMPORT_SOURCE_ERROR',
      'APPROVED_ADMINISTRATIVE_EXCEPTION', 'OTHER')),
  constraint manual_exception_intakes_reason_check check (btrim(reason) <> ''),
  constraint manual_exception_intakes_status_check
    check (status in ('NEEDS_REVIEW', 'RESOLVED')),
  constraint manual_exception_intakes_request_key unique (request_id),
  -- الحلّ يحمل من حسمه ومتى وبأي فعل وسبب، كنمط override_grace_expired_review.
  constraint manual_exception_intakes_resolved_is_attributed
    check (status <> 'RESOLVED'
           or (resolved_by is not null and resolved_at is not null
               and btrim(coalesce(resolution_action, '')) <> ''
               and btrim(coalesce(resolution_reason, '')) <> '')),
  constraint manual_exception_intakes_resolution_action_check
    check (resolution_action is null or resolution_action in (
      'LINKED_TO_REAL_IDENTITY', 'CONFIRMED_ADMINISTRATIVE_EXCEPTION', 'REJECTED_DUPLICATE',
      'REJECTED_INVALID'))
);

-- قفل ضد التكرار: استثناءٌ نشطٌ واحد فقط لكل username_key في وقتٍ واحد. ثانٍ
-- لنفس الهوية يُحسَم عبر مراجعة الأول لا صفّاً منافساً.
create unique index manual_exception_intakes_active_key
  on public.manual_exception_intakes (username_key)
  where status = 'NEEDS_REVIEW';

create index manual_exception_intakes_username_idx
  on public.manual_exception_intakes (username_key);
create index manual_exception_intakes_status_idx
  on public.manual_exception_intakes (status);

alter table public.manual_exception_intakes enable row level security;
revoke all on table public.manual_exception_intakes from authenticated, anon, public;
grant select on table public.manual_exception_intakes to authenticated;

drop policy if exists manual_exception_intakes_select on public.manual_exception_intakes;
create policy manual_exception_intakes_select on public.manual_exception_intakes
  for select to authenticated
  using ((select public.has_capability('installation.view')));

-- ---------------------------------------------------------------------------
-- القدرة: إنشاء استثناء حساسٌ ونادر، لا يُدرَج ضمن دورٍ عريض افتراضياً.
-- المراجعة (الحسم) تستعمل installation.view + قدرة حسمٍ مخصّصة أيضاً، فلا
-- يملك كل من يرى الطابور صلاحية إغلاق صفوفه.
-- ---------------------------------------------------------------------------

insert into public.permission_capabilities (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable)
values
  ('installation.manual_exception_create', 'installation', 'إضافة مشترك استثنائي', true, false, false),
  ('installation.manual_exception_resolve', 'installation', 'حسم استثناء يدوي', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', k from (values
  ('installation.manual_exception_create'), ('installation.manual_exception_resolve')) as v(k)
where exists (select 1 from public.role_templates where key = 'admin')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- الحارس السادس على تصنيف NEW: سبب الاستثناء اليدوي لا يظهر في الحكم
-- الآلي أصلاً (classify_newness لا يكتب هذا السبب)، لكنه يحتاج أن يكون
-- قيمةً صالحة في القيد نفسه لأن الصفّ المقابل في subscriber_classifications
-- يُدرَج بهذا السبب صراحةً أدناه.
-- ---------------------------------------------------------------------------

alter table public.subscriber_classifications
  drop constraint if exists subscriber_classifications_reason_check;

alter table public.subscriber_classifications
  add constraint subscriber_classifications_reason_check
  check (reason_code in (
    'REGISTRY_PREEXISTING', 'LIFETIME_COUNT_EXCEEDS_OBSERVED',
    'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'PARTIAL_SOURCE',
    'UNKNOWN_SOURCE_COMPLETENESS', 'IDENTITY_CONFLICT',
    'CANCELED_ONLY_HISTORY', 'NO_QUALIFYING_PAID_EVENT',
    'IDENTITY_UNRESOLVED', 'MANUAL_EXCEPTION'));

-- الحارس القائم على NEW لا يتغيّر: NEW يبقى ممنوعاً إلا بمصدرٍ مكتمل مُثبَت
-- وسببٍ COMPLETE_LIFETIME_HISTORY_OBSERVED — MANUAL_EXCEPTION لا يحقّقه أبداً،
-- فلا يمكن لصفّ استثناء يدوي أن يصير NEW ولو أُدخل مباشرة في الجدول.

-- ---------------------------------------------------------------------------
-- الإنشاء: صفّان معاً وبمعاملة واحدة — تفصيل الاستثناء، ودخول موحَّد إلى
-- طابور مراجعة التصنيف الذي يستعمله كل صفّ NEEDS_REVIEW آخر أصلاً.
-- ---------------------------------------------------------------------------

create or replace function public.create_manual_exception_intake(
  p_exception_type text,
  p_username_key text,
  p_reason text,
  p_subscriber_name text default null,
  p_reseller text default null,
  p_import_batch_id uuid default null,
  p_source_context text default null,
  p_supporting_reference text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_key   text := lower(btrim(coalesce(p_username_key, '')));
  v_row   public.manual_exception_intakes%rowtype;
  v_class_id uuid;
begin
  perform public.require_capability('installation.manual_exception_create');

  if v_key = '' then
    raise exception 'subscriber identifying data (username_key) is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'reason is required' using errcode = '22023';
  end if;
  if p_exception_type is null
     or p_exception_type not in (
       'NOT_VISIBLE_IN_SAAS', 'MISSING_HISTORICAL_DATA', 'IMPORT_SOURCE_ERROR',
       'APPROVED_ADMINISTRATIVE_EXCEPTION', 'OTHER') then
    raise exception 'exception_type is invalid' using errcode = '22023';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  -- إعادة إرسال بنفس request_id من نفس الفاعل تُعيد الصفّ القائم بدل الفشل أو
  -- التكرار. مطابقة request_id وحده غير كافية (نمط audit_logs في كل مكان آخر
  -- يربطه بالفاعل)، فلو تصادف request_id مع فاعلٍ آخر يفشل الإدراج لاحقاً على
  -- القيد الفريد بدل أن يُعاد لهذا الفاعل صفّ ليس له.
  select * into v_row from public.manual_exception_intakes
  where request_id = p_request_id and created_by = v_actor;
  if found then
    return jsonb_build_object('replayed', true, 'intake', to_jsonb(v_row));
  end if;

  -- التكرار الصامت (بلا request_id مطابق): استثناء نشط قائم على نفس الهوية.
  if exists (select 1 from public.manual_exception_intakes
             where username_key = v_key and status = 'NEEDS_REVIEW') then
    raise exception 'An active manual exception already exists for this subscriber — review it instead of creating a second one'
      using errcode = '23505';
  end if;

  insert into public.manual_exception_intakes (
    exception_type, username_key, subscriber_name, reseller, import_batch_id,
    source_context, reason, supporting_reference, request_id, created_by
  ) values (
    p_exception_type, v_key, nullif(btrim(coalesce(p_subscriber_name, '')), ''),
    nullif(btrim(coalesce(p_reseller, '')), ''), p_import_batch_id,
    nullif(btrim(coalesce(p_source_context, '')), ''), p_reason,
    nullif(btrim(coalesce(p_supporting_reference, '')), ''), p_request_id, v_actor
  ) returning * into v_row;

  -- الدخول الموحَّد: صفّ NEEDS_REVIEW/MANUAL_EXCEPTION في نفس سطح المراجعة
  -- الذي يستعمله كل صفّ NEEDS_REVIEW آخر — لا مسارٌ أقل تدقيقاً.
  insert into public.subscriber_classifications (
    username_key, classification, reason_code, source_completeness,
    qualifying_paid_event_count, evidence, import_batch_id
  ) values (
    v_key, 'NEEDS_REVIEW', 'MANUAL_EXCEPTION', 'UNKNOWN', 0,
    jsonb_build_object('manual_exception_intake_id', v_row.id, 'exception_type', p_exception_type),
    p_import_batch_id
  ) returning id into v_class_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra
  ) values (
    v_actor, 'installation.manual_exception.created', 'status',
    null, 'NEEDS_REVIEW', 'manual_exception_intake', v_row.id, p_request_id, p_reason
  );

  return jsonb_build_object('replayed', false, 'intake', to_jsonb(v_row), 'classification_id', v_class_id);
end;
$fn$;

revoke execute on function public.create_manual_exception_intake(
  text, text, text, text, text, uuid, text, text, uuid) from public, anon;
grant execute on function public.create_manual_exception_intake(
  text, text, text, text, text, uuid, text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- الحسم: مراجعٌ يقرّر — لا سقوط تلقائي إلى NEW أو استحقاق أبداً. الرفض حسمٌ
-- كامل الأثر أيضاً (يوثَّق ويُغلَق)، لا حذفاً للسجل.
-- ---------------------------------------------------------------------------

create or replace function public.resolve_manual_exception_intake(
  p_intake_id uuid,
  p_resolution_action text,
  p_resolution_reason text,
  p_linked_subscriber_identity_id uuid default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_row   public.manual_exception_intakes%rowtype;
begin
  perform public.require_capability('installation.manual_exception_resolve');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_resolution_reason, '')) = '' then
    raise exception 'resolution_reason is required' using errcode = '22023';
  end if;
  if p_resolution_action is null or p_resolution_action not in (
      'LINKED_TO_REAL_IDENTITY', 'CONFIRMED_ADMINISTRATIVE_EXCEPTION',
      'REJECTED_DUPLICATE', 'REJECTED_INVALID') then
    raise exception 'resolution_action is invalid' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_row from public.manual_exception_intakes where id = p_intake_id for update;
  if not found then
    raise exception 'Manual exception intake not found' using errcode = '22023';
  end if;
  if v_row.status <> 'NEEDS_REVIEW' then
    raise exception 'This intake is already resolved' using errcode = '22023';
  end if;
  if p_resolution_action = 'LINKED_TO_REAL_IDENTITY' and p_linked_subscriber_identity_id is null then
    raise exception 'linked_subscriber_identity_id is required when linking to a real identity'
      using errcode = '22023';
  end if;

  update public.manual_exception_intakes set
    status = 'RESOLVED',
    resolved_by = v_actor,
    resolved_at = now(),
    resolution_action = p_resolution_action,
    resolution_reason = p_resolution_reason,
    linked_subscriber_identity_id = p_linked_subscriber_identity_id
  where id = p_intake_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra
  ) values (
    v_actor, 'installation.manual_exception.resolved', 'status',
    'NEEDS_REVIEW', p_resolution_action, 'manual_exception_intake', p_intake_id,
    p_request_id, p_resolution_reason
  );

  return jsonb_build_object('replayed', false, 'intake_id', p_intake_id, 'status', 'RESOLVED');
end;
$fn$;

revoke execute on function public.resolve_manual_exception_intake(uuid, text, text, uuid, uuid) from public, anon;
grant execute on function public.resolve_manual_exception_intake(uuid, text, text, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- قراءة مُرقَّمة: نفس عقد page_envelope المستعمل في كل مكان آخر.
-- ---------------------------------------------------------------------------

create or replace function public.page_manual_exceptions(
  p_status text default 'NEEDS_REVIEW',
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
  v_lim integer := public.page_limit(p_limit);
  v_off integer := public.page_offset(p_offset);
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_capability('installation.view');

  with base as (
    select i.*
    from public.manual_exception_intakes i
    where (p_status is null or i.status = p_status)
      and (p_search is null or btrim(p_search) = '' or
           i.username_key ilike '%' || btrim(p_search) || '%' or
           coalesce(i.subscriber_name, '') ilike '%' || btrim(p_search) || '%')
  )
  select count(*), coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
    into v_total, v_rows
  from (select * from base order by created_at desc limit v_lim offset v_off) x;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_manual_exceptions(text, text, integer, integer) from public, anon;
grant execute on function public.page_manual_exceptions(text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- كشف مرشّح دمج: هويةٌ حقيقية لاحقة بنفس username_key تعني احتمال أن يكون
-- الاستثناء اليدوي هو نفس الشخص. اكتشافٌ فقط — لا دمجاً ضبابياً تلقائياً،
-- كما يشترط التصميم المعتمد صراحةً.
-- ---------------------------------------------------------------------------

create or replace function public.manual_exception_merge_candidates(p_intake_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key text;
  v_rows jsonb;
begin
  perform public.require_capability('installation.view');

  select username_key into v_key from public.manual_exception_intakes where id = p_intake_id;
  if v_key is null then
    raise exception 'Manual exception intake not found' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'subscriber_identity_id', i.id, 'saas_user_id', i.saas_user_id,
      'identity_status', i.identity_status, 'match_method', i.match_method,
      'installation_subscriber_id', i.installation_subscriber_id)), '[]'::jsonb)
    into v_rows
  from public.subscriber_identities i
  where i.username_key = v_key and i.identity_status = 'MATCHED';

  return jsonb_build_object('username_key', v_key, 'candidates', v_rows);
end;
$fn$;

revoke execute on function public.manual_exception_merge_candidates(uuid) from public, anon;
grant execute on function public.manual_exception_merge_candidates(uuid) to authenticated;

commit;
