-- ---------------------------------------------------------------------------
-- Batch 4 — D-01 / D-12 / D-13 / D-14، APPROVED، تمديدٌ للمحرّك القائم
--
-- لا محرّك تصنيف ثانٍ: classify_newness() نفسها، بحارسٍ واحد أضيف. لا نظام
-- حجبٍ مواز: القراءة الزمنية تُشتَق من subscriber_classifications نفسها،
-- وتجاوزها الوحيد سجلٌّ صغير مدقَّق. لا حالة اكتمال خامسة على التصنيف: بقيت
-- ثلاثية القيم، وSOURCE_NEEDS_REVALIDATION حالة على الدفعة وحدها.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. D-01 — الهوية غير المطابقة (UNMATCHED) لا تصبح NEW صمتاً.
--
-- الحارس الخامس كان يمنح NEW من اكتمال المصدر وتساوي العدّادين فقط، بلا أي
-- شرط على حالة الهوية غير CONFLICT. فمشتركٌ UNMATCHED (لا صفّ هوية له أصلاً،
-- أو صفّه بلا مطابقة) كان يمرّ من الحارس الخامس لو تساوى عدّاداه من مصدرٍ
-- مكتمل. سبب جديد لحالة لم تكن ممكنة الحدوث فعلياً على بيانات اليوم (لأن
-- الاكتمال UNKNOWN دوماً)، فلا صفّ تصنيف حاليّ يتأثّر رجعياً.
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
    'IDENTITY_UNRESOLVED'));

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

  select exists (
    select 1 from public.installation_subscribers s
    where lower(btrim(s.subscriber_id)) = v_key) into v_pre;

  select i.identity_status into v_identity
  from public.subscriber_identities i
  where i.username_key = v_key
  limit 1;

  -- اكتمال المصدر: أيّ حالة غير COMPLETE بالضبط تُسقط الادعاء، بلا حال
  -- افتراضي يمنح COMPLETE لقيمةٍ مستقبلية مجهولة (كـNEEDS_REVALIDATION).
  select case
           when count(*) = 0 then 'UNKNOWN'
           when bool_and(b.completeness_status = 'COMPLETE') then 'COMPLETE'
           when bool_or(b.completeness_status = 'UNKNOWN') then 'UNKNOWN'
           else 'PARTIAL' end,
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
      'unknown_package_events', v_unknown,
      'identity_status', v_identity))

  || case when v_pre then
       jsonb_build_object('classification', 'EXISTING', 'reason_code', 'REGISTRY_PREEXISTING')
     when v_identity = 'CONFLICT' then
       jsonb_build_object('classification', 'NEEDS_REVIEW', 'reason_code', 'IDENTITY_CONFLICT')
     when v_lifetime > v_observed then
       jsonb_build_object('classification', 'EXISTING', 'reason_code', 'LIFETIME_COUNT_EXCEEDS_OBSERVED')
     when v_qualifying = 0 then
       jsonb_build_object('classification', 'NEEDS_REVIEW', 'reason_code',
         case when v_observed > 0 and v_all_cxl
              then 'CANCELED_ONLY_HISTORY' else 'NO_QUALIFYING_PAID_EVENT' end)
     -- D-01، شرطٌ سادس: الهوية يجب أن تكون مطابقة (MATCHED) فعلاً، لا مجرّد
     -- غير متعارضة. UNMATCHED (بلا صفّ، أو صفّ بلا مطابقة) لا يصنَّف NEW.
     when coalesce(v_identity, 'UNMATCHED') <> 'MATCHED' then
       jsonb_build_object('classification', 'NEEDS_REVIEW', 'reason_code', 'IDENTITY_UNRESOLVED')
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

-- ---------------------------------------------------------------------------
-- 2. D-14 — حالة رابعة على الدفعة وحدها: NEEDS_REVALIDATION.
--
-- لا تُضاف إلى subscriber_classifications.source_completeness (تبقى ثلاثية:
-- الحارس أعلاه يُسقط أي حالة غير COMPLETE بالضبط إلى PARTIAL/UNKNOWN بأمان).
-- ---------------------------------------------------------------------------

alter table public.saas_import_batches
  drop constraint if exists saas_import_batches_completeness_check;

alter table public.saas_import_batches
  add constraint saas_import_batches_completeness_check
  check (completeness_status in ('UNKNOWN', 'PARTIAL', 'COMPLETE', 'NEEDS_REVALIDATION'));

-- بيانات متأخّرة تصل لدفعةٍ من نفس نوع المصدر وتتقاطع تغطيتها مع دفعةٍ
-- COMPLETE سابقة: الدفعة السابقة تتحوّل تلقائياً NEEDS_REVALIDATION. مُشغَّلٌ
-- على تحوّل حالة الدفعة نفسها إلى 'imported'، لا داخل RPC الاستيراد — فيسري
-- على كل مسار استيراد بلا لمس عقود import_saas_activation_events/
-- import_saas_user_snapshot المنشورتين فعلاً.
create or replace function public.flag_overlapping_batches_for_revalidation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_affected uuid;
begin
  if new.observed_min_created_at is null or new.observed_max_created_at is null then
    return new;
  end if;

  for v_affected in
    select b.id
    from public.saas_import_batches b
    where b.id <> new.id
      and b.source_kind = new.source_kind
      and b.completeness_status = 'COMPLETE'
      and b.declared_coverage_start is not null
      and b.declared_coverage_end is not null
      and new.observed_min_created_at::date <= b.declared_coverage_end
      and new.observed_max_created_at::date >= b.declared_coverage_start
  loop
    update public.saas_import_batches
    set completeness_status = 'NEEDS_REVALIDATION'
    where id = v_affected;

    insert into public.audit_logs (
      actor_id, action, field, old_value, new_value, entity_type, entity_id, extra
    ) values (
      new.imported_by, 'import.completeness.needs_revalidation', 'completeness_status',
      'COMPLETE', 'NEEDS_REVALIDATION', 'saas_import_batch', v_affected,
      'late data in batch ' || new.id::text || ' overlaps declared coverage'
    );
  end loop;

  return new;
end;
$fn$;

drop trigger if exists trg_flag_overlapping_batches on public.saas_import_batches;
create trigger trg_flag_overlapping_batches
  after update of status on public.saas_import_batches
  for each row
  when (new.status = 'imported' and old.status is distinct from 'imported')
  execute function public.flag_overlapping_batches_for_revalidation();

-- إعادة التصريح بعد المراجعة تستعمل declare_import_completeness نفسها —
-- previous_status يقبل أي نص أصلاً، فالانتقال NEEDS_REVALIDATION → COMPLETE
-- يعمل بلا أي تغيير على الدالة. المُشغِّل هو الوحيد الذي يكتب
-- NEEDS_REVALIDATION، فالمشغّل التشغيلي لا يُعلنها بنفسه أبداً.

-- ---------------------------------------------------------------------------
-- 3. D-12 — عقد قراءة مهلة التفعيل: 30 يوماً تقويمياً من إنشاء حساب SaaS.
--
-- لا عمود installation_date قائم قبل التسجيل؛ أقرب مرساة موثوقة لمرشّح لم
-- يُسجَّل بعد هي saas_user_snapshots.saas_created_at — تاريخ إنشاء الحساب
-- في منصّة SaaS نفسها، لا تاريخ أي حدث لاحق.
-- ---------------------------------------------------------------------------

create or replace function public.installation_grace_status(p_username_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key         text := lower(btrim(coalesce(p_username_key, '')));
  v_class       public.subscriber_classifications%rowtype;
  v_install_at  timestamptz;
  v_qualify_at  timestamptz;
  v_overridden  boolean;
  v_deadline    date;
  v_status      text;
  v_days        integer;
begin
  perform public.require_capability('installation.view');

  if v_key = '' then
    raise exception 'Subscriber key is required' using errcode = '22023';
  end if;

  select * into v_class from public.subscriber_classifications where username_key = v_key;

  select s.saas_created_at into v_install_at
  from public.saas_user_snapshots s
  where s.username_key = v_key
  order by s.snapshot_at asc, s.created_at asc
  limit 1;

  select min(e.event_created_at) into v_qualify_at
  from public.saas_activation_events e
  left join public.packages pk on pk.code = e.profile_name
  where e.username_key = v_key
    and coalesce(e.canceled, false) = false
    and coalesce(pk.semantic_category, 'UNKNOWN') = 'PAID_PACKAGE';

  select exists (
    select 1 from public.grace_period_overrides o where o.username_key = v_key
  ) into v_overridden;

  if v_class.classification in ('EXISTING', 'NEW') then
    -- محسوم بالفعل — جِدّته لم تعد قيد الانتظار.
    v_status := 'NOT_APPLICABLE';
  elsif v_class.classification = 'NEEDS_REVIEW'
        and coalesce(v_class.reason_code, '') <> 'NO_QUALIFYING_PAID_EVENT' then
    -- مسدودٌ لسببٍ آخر (تعارض هوية، مصدر غير مكتمل...) — ليس انتظار تفعيل.
    v_status := 'NOT_APPLICABLE';
  elsif v_install_at is null then
    v_status := 'UNKNOWN';
  elsif v_qualify_at is not null then
    v_status := 'QUALIFIED';
  else
    v_deadline := (v_install_at::date) + 30;
    if v_overridden then
      v_status := 'PENDING_ACTIVATION';
    elsif now()::date > v_deadline then
      v_status := 'GRACE_EXPIRED_REVIEW';
    else
      v_status := 'PENDING_ACTIVATION';
    end if;
  end if;

  v_deadline := case when v_install_at is null then null else (v_install_at::date) + 30 end;
  v_days := case when v_deadline is null then null else (v_deadline - now()::date) end;

  return jsonb_build_object(
    'username_key', v_key,
    'installation_date', v_install_at,
    'deadline', v_deadline,
    'qualifying_activation_at', v_qualify_at,
    'days_remaining', v_days,
    'overridden', v_overridden,
    'status', v_status);
end;
$fn$;

revoke execute on function public.installation_grace_status(text) from public, anon;
grant execute on function public.installation_grace_status(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. D-13 — تجاوزٌ مدقَّق وحيد، لا نظام حجبٍ مواز.
--
-- المهلة المنقضية لا تُنشئ استحقاقاً ولا حجباً دائماً بذاتها: القراءة أعلاه
-- تُظهرها GRACE_EXPIRED_REVIEW حتى تفعيلٍ مؤهّل فعلي أو تجاوز مُدقَّق.
-- installation_holds لا يلائم هذه الحالة (يلزمه صفّ في installation_subscribers
-- لم يوجد بعد لمرشّحٍ لم يُسجَّل)، فسجلٌّ صغيرٌ مضافٌ عمداً بدل تمديد الحجز.
-- ---------------------------------------------------------------------------

create table if not exists public.grace_period_overrides (
  id uuid primary key default gen_random_uuid(),
  username_key text not null,
  reason text not null,
  overridden_by uuid not null references auth.users(id),
  overridden_at timestamptz not null default now(),
  request_id uuid,
  constraint grace_period_overrides_reason_check check (btrim(reason) <> ''),
  constraint grace_period_overrides_request_key unique (request_id)
);

create index if not exists grace_period_overrides_username_idx
  on public.grace_period_overrides (username_key);

alter table public.grace_period_overrides enable row level security;
revoke all on table public.grace_period_overrides from authenticated, anon, public;
grant select on table public.grace_period_overrides to authenticated;

drop policy if exists grace_period_overrides_select on public.grace_period_overrides;
create policy grace_period_overrides_select on public.grace_period_overrides
  for select to authenticated using (public.has_capability('installation.view'));

insert into public.permission_capabilities (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable)
values ('installation.grace_override', 'installation', 'تجاوز مهلة التفعيل', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', 'installation.grace_override'
where exists (select 1 from public.role_templates where key = 'admin')
on conflict do nothing;

create or replace function public.override_grace_expired_review(
  p_username_key text,
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
  v_key   text := lower(btrim(coalesce(p_username_key, '')));
  v_status jsonb;
begin
  perform public.require_capability('installation.grace_override');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'reason is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  v_status := public.installation_grace_status(v_key);
  if v_status ->> 'status' <> 'GRACE_EXPIRED_REVIEW' then
    raise exception 'Subscriber is not in an expired-grace review state' using errcode = '22023';
  end if;

  insert into public.grace_period_overrides (username_key, reason, overridden_by, request_id)
  values (v_key, p_reason, v_actor, p_request_id);

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra
  ) values (
    v_actor, 'installation.grace.overridden', 'status',
    'GRACE_EXPIRED_REVIEW', 'PENDING_ACTIVATION', 'subscriber_classification', null,
    p_request_id, p_reason
  );

  return jsonb_build_object(
    'replayed', false, 'username_key', v_key,
    'status', public.installation_grace_status(v_key) ->> 'status');
end;
$fn$;

revoke execute on function public.override_grace_expired_review(text, text, uuid) from public, anon;
grant execute on function public.override_grace_expired_review(text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. مركز القرار: مجموعتان جديدتان، بلا مساس بأي مسار قائم.
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
  classification as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_classifications c
    where c.classification = 'NEEDS_REVIEW'
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
  grace_expired as (
    select count(*)::bigint as decisions, count(*)::bigint as subscribers
    from public.subscriber_classifications c
    join public.saas_user_snapshots s on s.username_key = c.username_key
    where c.classification = 'NEEDS_REVIEW'
      and c.reason_code = 'NO_QUALIFYING_PAID_EVENT'
      and s.saas_created_at is not null
      and now()::date > (s.saas_created_at::date + 30)
      and not exists (
        select 1 from public.grace_period_overrides o where o.username_key = c.username_key)
      and not exists (
        select 1 from public.saas_activation_events e
        left join public.packages pk on pk.code = e.profile_name
        where e.username_key = c.username_key
          and coalesce(e.canceled, false) = false
          and coalesce(pk.semantic_category, 'UNKNOWN') = 'PAID_PACKAGE')
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
        'path', '/system/imports?status=NEEDS_REVALIDATION'),

      jsonb_build_object(
        'key', 'GRACE_EXPIRED_REVIEW', 'label', 'مهلة تفعيل منقضية',
        'unit', 'المشترك', 'role', 'العمليات',
        'decisions', (select decisions from grace_expired),
        'subscribers', (select subscribers from grace_expired),
        'events', null, 'amount', null,
        'next_action', 'راجِع أو جاوِز بسببٍ مُدقَّق',
        'path', '/installation?grace=EXPIRED')
    ))
  into v_doc;

  return v_doc;
end;
$function$;

commit;
