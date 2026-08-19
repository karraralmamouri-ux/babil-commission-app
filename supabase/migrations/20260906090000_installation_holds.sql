-- ---------------------------------------------------------------------------
-- تعليق أجور التنصيب: دائم ومؤقّت، فردي وبالجملة
--
-- التعليق يمنع الصرف ولا يمسّ التاريخ. هذا حدُّه الذي لا يُتجاوز: لا يحذف
-- دفعةً مسجَّلة، ولا يغيّر مرحلةً مدفوعة، ولا يعيد كتابة استحقاقٍ ماضٍ، ولا
-- يلمس قيداً في الدفتر. كل ما يفعله أنه يقف بين استحقاقٍ غير مدفوع ودفعة.
--
-- ثلاثة محاور مستقلّة، وخلطُها هو ما يُنتج الالتباس:
--
--   hold_type   SYSTEM | MANUAL      — من رفعه: النظام أم إنسان
--   permanence  PERMANENT | TEMPORARY — هل ينقضي بنفسه
--   source      INDIVIDUAL | BULK     — من شاشة المشترك أم من ملف
--
-- والمؤقّت ينقضي بمرور وقته لا بمهمّةٍ تكنسه: شرط الحجب يفحص السريان في
-- لحظة القراءة. المهمّة التي تتأخّر أو تتوقّف كانت ستُبقي المال محجوزاً بعد
-- انتهاء سبب حجزه.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. محورا الدوام والمصدر
-- ---------------------------------------------------------------------------

alter table public.installation_holds
  add column if not exists permanence text not null default 'PERMANENT',
  add column if not exists expires_at  timestamptz,
  add column if not exists source      text not null default 'INDIVIDUAL',
  add column if not exists upload_id   uuid,
  add column if not exists reason_note text;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'installation_holds_permanence_check') then
    alter table public.installation_holds
      add constraint installation_holds_permanence_check
      check (permanence in ('PERMANENT', 'TEMPORARY'));
  end if;

  -- المؤقّت بلا أجل ليس مؤقّتاً، والدائم بأجل ليس دائماً. كلاهما يُرفض.
  if not exists (select 1 from pg_constraint
                 where conname = 'installation_holds_expiry_matches_permanence') then
    alter table public.installation_holds
      add constraint installation_holds_expiry_matches_permanence
      check ((permanence = 'TEMPORARY' and expires_at is not null)
          or (permanence = 'PERMANENT' and expires_at is null));
  end if;

  if not exists (select 1 from pg_constraint
                 where conname = 'installation_holds_source_check') then
    alter table public.installation_holds
      add constraint installation_holds_source_check
      check (source in ('INDIVIDUAL', 'BULK'));
  end if;
end $$;

-- سببٌ لتعليقٍ إداري: الأسباب القائمة كلها آلية، ولا واحد منها يصف قراراً
-- بشرياً بحجب الصرف.
insert into public.installation_hold_reasons (code, label_ar, blocks_payment)
values ('MANUAL_REVIEW', 'حجب إداري', true)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 2. السريان — تُقرأ في كل فحص
-- ---------------------------------------------------------------------------

create or replace function public.hold_is_effective(
  p_status text,
  p_permanence text,
  p_expires_at timestamptz
)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select p_status = 'ACTIVE'
     and (p_permanence <> 'TEMPORARY' or p_expires_at > now());
$fn$;

revoke execute on function public.hold_is_effective(text,text,timestamptz) from public, anon;
grant execute on function public.hold_is_effective(text,text,timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. رفعات الجملة — الملف يبقى معروفاً بعد تطبيقه
-- ---------------------------------------------------------------------------

create table if not exists public.installation_hold_uploads (
  id            uuid primary key default gen_random_uuid(),
  filename      text not null,
  row_count     integer not null default 0,
  applied_count integer not null default 0,
  skipped_count integer not null default 0,
  permanence    text not null,
  expires_at    timestamptz,
  reason_code   text not null references public.installation_hold_reasons(code),
  note          text,
  request_id    uuid unique,
  uploaded_by   uuid references auth.users(id),
  uploaded_at   timestamptz not null default now(),
  constraint installation_hold_uploads_permanence_check
    check (permanence in ('PERMANENT', 'TEMPORARY')),
  constraint installation_hold_uploads_expiry_matches
    check ((permanence = 'TEMPORARY' and expires_at is not null)
        or (permanence = 'PERMANENT' and expires_at is null)),
  constraint installation_hold_uploads_filename_check check (btrim(filename) <> '')
);

alter table public.installation_hold_uploads enable row level security;

-- القراءة فقط عبر الدور؛ الكتابة تمرّ بالدوال وحدها.
revoke all on public.installation_hold_uploads from anon;
grant select on public.installation_hold_uploads to authenticated;

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'installation_hold_uploads'
                   and policyname = 'installation_hold_uploads_select') then
    create policy installation_hold_uploads_select on public.installation_hold_uploads
      for select to authenticated
      -- الوسيط ثابت لكل الصفوف؛ اللفّ في استعلامٍ قياسي يجعل المخطِّط
      -- يحسبه مرّةً واحدة بدل مرّةٍ لكل صف.
      using ((select public.has_capability('installation.view')));
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'installation_holds_upload_fkey') then
    alter table public.installation_holds
      add constraint installation_holds_upload_fkey
      foreign key (upload_id) references public.installation_hold_uploads(id)
      on delete set null;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. المعاينة — تُقرأ قبل أن يُطبَّق شيء
--
-- كل معرّف يقع في دلوٍ واحد بالضبط، والترتيب هو ترتيب الأهمية: المجهول أوّلاً
-- لأنه غالباً خطأ كتابة، ثم المكرّر، ثم ما لا معنى لتعليقه.
-- ---------------------------------------------------------------------------

create or replace function public.preview_bulk_hold(p_ids text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_doc jsonb;
begin
  perform public.require_capability('installation.hold');

  with raw as (
    select btrim(x) as id, row_number() over () as ord
    from unnest(coalesce(p_ids, array[]::text[])) x
    where btrim(coalesce(x, '')) <> ''
  ),
  first_seen as (
    select id, min(ord) as ord, count(*) as times
    from raw group by id
  ),
  judged as (
    select
      f.id,
      f.times,
      s.subscriber_id is not null as known,
      coalesce(st.remaining, -1) as remaining,
      exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at)) as held,
      exists (
        select 1 from public.installation_entitlements e
        where e.subscriber_id = s.subscriber_id and e.payment_status = 'paid') as paid_ent
    from first_seen f
    left join public.installation_subscribers s
      on lower(btrim(s.subscriber_id)) = lower(f.id)
    left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
  ),
  bucketed as (
    select j.*,
      case
        when not j.known        then 'unknown'
        when j.held             then 'already_held'
        when j.remaining = 0    then 'already_done'
        when j.paid_ent and j.remaining <= 0 then 'already_paid'
        else 'valid'
      end as bucket
    from judged j
  )
  select jsonb_build_object(
    'submitted', (select count(*) from raw),
    'distinct_ids', (select count(*) from first_seen),
    -- التكرار داخل الملف يُعدّ ولا يُطبَّق مرّتين.
    'duplicate', (select coalesce(sum(times - 1), 0) from first_seen),
    'counts', (
      select coalesce(jsonb_object_agg(b.bucket, b.n), '{}'::jsonb)
      from (select bucket, count(*) as n from bucketed group by bucket) b),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select b.id as subscriber_id, b.bucket, b.times,
               nullif(b.remaining, -1) as remaining,
               public.installation_stage_for_remaining(nullif(b.remaining, -1)) as next_stage
        from bucketed b
        order by case b.bucket when 'unknown' then 0 when 'already_held' then 1
                               when 'already_done' then 2 when 'already_paid' then 3
                               else 4 end, b.id
        limit 500) x), '[]'::jsonb))
  into v_doc;

  return v_doc;
end;
$fn$;

revoke execute on function public.preview_bulk_hold(text[]) from public, anon;
grant execute on function public.preview_bulk_hold(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. التطبيق — دفعةً واحدة أو لا شيء
-- ---------------------------------------------------------------------------

create or replace function public.apply_bulk_hold(
  p_ids text[],
  p_permanence text,
  p_reason_code text,
  p_note text,
  p_filename text,
  p_expires_at timestamptz default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor   uuid := auth.uid();
  v_upload  uuid;
  v_applied integer := 0;
  v_seen    integer := 0;
begin
  perform public.require_capability('installation.hold');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_permanence not in ('PERMANENT', 'TEMPORARY') then
    raise exception 'Hold must be PERMANENT or TEMPORARY' using errcode = '22023';
  end if;
  if p_permanence = 'TEMPORARY' and p_expires_at is null then
    raise exception 'A temporary hold needs an end date' using errcode = '22023';
  end if;
  if p_permanence = 'TEMPORARY' and p_expires_at <= now() then
    raise exception 'A temporary hold cannot end in the past' using errcode = '22023';
  end if;
  if p_permanence = 'PERMANENT' and p_expires_at is not null then
    raise exception 'A permanent hold cannot carry an end date' using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'A hold must state its reason' using errcode = '22023';
  end if;
  if btrim(coalesce(p_filename, '')) = '' then
    raise exception 'The source file must be named' using errcode = '22023';
  end if;

  -- إعادة الرفع نفسه لا تُعلّق مرّةً ثانية.
  select id into v_upload from public.installation_hold_uploads
  where request_id = p_request_id;
  if found then
    return jsonb_build_object('upload_id', v_upload, 'idempotent', true);
  end if;

  select count(distinct btrim(x)) into v_seen
  from unnest(coalesce(p_ids, array[]::text[])) x
  where btrim(coalesce(x, '')) <> '';

  insert into public.installation_hold_uploads (
    filename, row_count, permanence, expires_at, reason_code, note,
    request_id, uploaded_by)
  values (btrim(p_filename), v_seen, p_permanence, p_expires_at,
          p_reason_code, btrim(p_note), p_request_id, v_actor)
  returning id into v_upload;

  -- يُعلَّق ما يستحق التعليق فقط: المجهول والمنتهي والمعلَّق سلفاً يُترك.
  -- والعملية كلّها داخل معاملة واحدة، فإمّا أن تقع كاملةً أو لا تقع.
  with candidates as (
    select distinct s.subscriber_id
    from unnest(p_ids) x
    join public.installation_subscribers s
      on lower(btrim(s.subscriber_id)) = lower(btrim(x))
    left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where btrim(coalesce(x, '')) <> ''
      and coalesce(st.remaining, 0) > 0
      and not exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at))
  )
  insert into public.installation_holds (
    subscriber_id, stage_code, reason_code, hold_type, note,
    status, created_by, permanence, expires_at, source, upload_id, reason_note)
  select c.subscriber_id, null, p_reason_code, 'MANUAL', btrim(p_note),
         'ACTIVE', v_actor, p_permanence, p_expires_at, 'BULK', v_upload, btrim(p_note)
  from candidates c;

  get diagnostics v_applied = row_count;

  update public.installation_hold_uploads
  set applied_count = v_applied,
      skipped_count = greatest(v_seen - v_applied, 0)
  where id = v_upload;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'installation.hold.bulk_applied', 'holds', '0', v_applied::text,
    'installation_hold_upload', p_request_id,
    'file=' || btrim(p_filename) || ' permanence=' || p_permanence
      || coalesce(' until=' || p_expires_at::text, '')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object(
    'upload_id', v_upload,
    'idempotent', false,
    'submitted', v_seen,
    'applied', v_applied,
    'skipped', greatest(v_seen - v_applied, 0));
end;
$fn$;

revoke execute on function public.apply_bulk_hold(text[],text,text,text,text,timestamptz,uuid)
  from public, anon;
grant execute on function public.apply_bulk_hold(text[],text,text,text,text,timestamptz,uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. رفع تعليق دائم — قرارٌ يحتاج إذناً أعلى
--
-- الدائم لا ينقضي بنفسه بحكم تعريفه؛ ورفعه قرارٌ إداري صريح، فيُشترط له
-- installation.release_hold لا مجرّد installation.hold.
-- ---------------------------------------------------------------------------

create or replace function public.release_hold_v2(
  p_hold_id uuid,
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
  v_hold  public.installation_holds%rowtype;
begin
  perform public.require_capability('installation.release_hold');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A release must state its reason' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'installation.hold.released') then
    return jsonb_build_object('hold_id', p_hold_id, 'idempotent', true);
  end if;

  select * into v_hold from public.installation_holds where id = p_hold_id for update;
  if not found then
    raise exception 'Hold not found' using errcode = '22023';
  end if;
  if v_hold.status <> 'ACTIVE' then
    return jsonb_build_object('hold_id', p_hold_id, 'idempotent', true,
                              'note', 'already released');
  end if;

  update public.installation_holds
  set status = 'RELEASED', released_by = v_actor, released_at = now(),
      release_reason = btrim(p_reason)
  where id = p_hold_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'installation.hold.released', 'status', 'ACTIVE', 'RELEASED',
    'installation_hold', p_request_id,
    'subscriber=' || v_hold.subscriber_id
      || ' permanence=' || v_hold.permanence
      || ' reason=' || btrim(p_reason));

  return jsonb_build_object('hold_id', p_hold_id, 'idempotent', false,
                            'permanence', v_hold.permanence);
end;
$fn$;

revoke execute on function public.release_hold_v2(uuid,text,uuid) from public, anon;
grant execute on function public.release_hold_v2(uuid,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. قائمة التعليقات — بكل ما تطلبه الشاشة
-- ---------------------------------------------------------------------------

create or replace function public.page_installation_holds(
  p_status text default null,
  p_permanence text default null,
  p_source text default null,
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
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select
      h.id, h.subscriber_id, h.stage_code, h.reason_code, h.hold_type,
      h.permanence, h.expires_at, h.source, h.status,
      coalesce(h.reason_note, h.note) as reason_note,
      h.created_at, h.released_at, h.release_reason,
      public.hold_is_effective(h.status, h.permanence, h.expires_at) as effective,
      r.label_ar as reason_label,
      cb.email as created_by_email,
      rb.email as released_by_email,
      u.filename as upload_filename,
      u.id as upload_id
    from public.installation_holds h
    left join public.installation_hold_reasons r on r.code = h.reason_code
    left join public.profiles cb on cb.id = h.created_by
    left join public.profiles rb on rb.id = h.released_by
    left join public.installation_hold_uploads u on u.id = h.upload_id
    where (p_status is null
           or (p_status = 'EFFECTIVE'
               and public.hold_is_effective(h.status, h.permanence, h.expires_at))
           or (p_status = 'EXPIRED'
               and h.status = 'ACTIVE' and h.permanence = 'TEMPORARY'
               and h.expires_at <= now())
           or h.status = p_status)
      and (p_permanence is null or h.permanence = p_permanence)
      and (p_source is null or h.source = p_source)
      and (p_search is null or btrim(p_search) = ''
           or h.subscriber_id ilike '%' || p_search || '%'
           or coalesce(h.reason_note, h.note) ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k
      order by k.effective desc, k.created_at desc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_installation_holds(text,text,text,text,integer,integer)
  from public, anon;
grant execute on function public.page_installation_holds(text,text,text,text,integer,integer)
  to authenticated;

create index if not exists installation_holds_subscriber_active_idx
  on public.installation_holds (subscriber_id) where status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- 8. الأهلية تحترم الانقضاء
--
-- مُعاد توليدها من نصّها الأصلي في 20260820150000، بتغييرٍ واحدٍ لا غير:
-- شرط التعليق صار يفحص السريان بدل الحالة وحدها. أُعيد التوليد من ملف
-- المهاجرة لا من قراءة الخادم، لأن رحلة القراءة تُفسد التعليقات العربية.
-- كل قاعدةٍ أخرى فيها باقيةٌ حرفاً بحرف.
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
  --
  -- «نشط» هنا تعني السريان لا الحالة وحدها: التعليق المؤقّت الذي انقضى
  -- أجله يتوقّف عن الحجب في اللحظة نفسها، بلا مهمّة تكنس ولا تدخّل. وإلّا
  -- بقي يحجب مالاً بعد انتهاء سبب حجبه.
  if exists (
    select 1 from public.installation_holds h
    join public.installation_hold_reasons r on r.code = h.reason_code
    where h.subscriber_id = v_ent.subscriber_id
      and public.hold_is_effective(h.status, h.permanence, h.expires_at)
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

commit;
