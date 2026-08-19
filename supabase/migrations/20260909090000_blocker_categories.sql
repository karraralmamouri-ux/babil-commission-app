-- ---------------------------------------------------------------------------
-- عطبان يُصلحان هنا: التعليق المؤقّت بلا أجل، و«محجوب = صفر» الكاذبة
--
-- ١. المؤقّت قد يكون بأجلٍ وقد يبقى حتى يُرفع يدوياً.
--
--    الصياغة السابقة اشترطت أجلاً لكل مؤقّت، فحرمت الحالة الأكثر وقوعاً:
--    «علِّقه حتى نتحقّق» بلا تاريخٍ معروف سلفاً. والفرق بين الدائم والمؤقّت
--    ليس وجود الأجل بل نيّة الرفع: الدائم قرارٌ يبقى حتى يُنقَض بإذنٍ أعلى،
--    والمؤقّت حجزٌ ينتهي — بأجله أو بيد من رفعه.
--
-- ٢. «محجوب = صفر» كانت تعني «لا تعليقات سارية» لا «لا شيء يمنع الصرف».
--
--    وهذا أخطر من رقمٍ خاطئ: يقرأ المشغّل صفراً فيفهم أن الطريق سالك، بينما
--    كل المرشّحين محجوبون بفاتورةٍ غير مدقَّقة. الحجب الآن مصنَّف:
--
--      HOLD | INVOICE | ELIGIBILITY | IDENTITY | FDT | PARENT | SOURCE | OTHER
--
--    ويُعدّ كلٌّ على حدة. و«جاهز» يعني خلوّه من كل الأصناف لا من التعليق وحده.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. المؤقّت بلا أجل مقبول؛ والدائم بأجل يبقى مرفوضاً
-- ---------------------------------------------------------------------------

alter table public.installation_holds
  drop constraint if exists installation_holds_expiry_matches_permanence;

alter table public.installation_holds
  add constraint installation_holds_expiry_matches_permanence
  check (permanence = 'TEMPORARY' or expires_at is null);

alter table public.installation_hold_uploads
  drop constraint if exists installation_hold_uploads_expiry_matches;

alter table public.installation_hold_uploads
  add constraint installation_hold_uploads_expiry_matches
  check (permanence = 'TEMPORARY' or expires_at is null);

-- السريان: الأجل يُفحص إن وُجد، وغيابه لا يعني الانقضاء.
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
     and (p_expires_at is null or p_expires_at > now());
$fn$;

-- والدالتان تكفّان عن اشتراط الأجل.
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
  -- المؤقّت بلا أجل مقبول: يبقى حتى يُرفع يدوياً.
  if p_permanence = 'PERMANENT' and p_expires_at is not null then
    raise exception 'A permanent hold cannot carry an end date' using errcode = '22023';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'A hold cannot end in the past' using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'A hold must state its reason' using errcode = '22023';
  end if;
  if btrim(coalesce(p_filename, '')) = '' then
    raise exception 'The source file must be named' using errcode = '22023';
  end if;

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
      || coalesce(' until=' || p_expires_at::text, ' until=manual')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object(
    'upload_id', v_upload,
    'idempotent', false,
    'submitted', v_seen,
    'applied', v_applied,
    'skipped', greatest(v_seen - v_applied, 0));
end;
$fn$;

create or replace function public.place_hold_v2(
  p_subscriber_id text,
  p_permanence text,
  p_reason_code text,
  p_note text,
  p_stage_code text default null,
  p_expires_at timestamptz default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_known boolean;
begin
  perform public.require_capability('installation.hold');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_permanence not in ('PERMANENT', 'TEMPORARY') then
    raise exception 'Hold must be PERMANENT or TEMPORARY' using errcode = '22023';
  end if;
  if p_permanence = 'PERMANENT' and p_expires_at is not null then
    raise exception 'A permanent hold cannot carry an end date' using errcode = '22023';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'A hold cannot end in the past' using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'A hold must state its reason' using errcode = '22023';
  end if;

  select id into v_id from public.installation_holds where request_id = p_request_id;
  if found then
    return jsonb_build_object('hold_id', v_id, 'idempotent', true);
  end if;

  select exists (
    select 1 from public.installation_subscribers s
    where lower(btrim(s.subscriber_id)) = lower(btrim(p_subscriber_id))) into v_known;
  if not v_known then
    raise exception 'Subscriber % is not in the installation registry', p_subscriber_id
      using errcode = '22023';
  end if;

  select h.id into v_id
  from public.installation_holds h
  where lower(btrim(h.subscriber_id)) = lower(btrim(p_subscriber_id))
    and public.hold_is_effective(h.status, h.permanence, h.expires_at)
    and (h.stage_code is not distinct from p_stage_code)
  limit 1;
  if found then
    return jsonb_build_object('hold_id', v_id, 'idempotent', true, 'note', 'already held');
  end if;

  insert into public.installation_holds (
    subscriber_id, stage_code, reason_code, hold_type, note, status, created_by,
    permanence, expires_at, source, reason_note, request_id)
  select s.subscriber_id, p_stage_code, p_reason_code, 'MANUAL', btrim(p_note),
         'ACTIVE', v_actor, p_permanence, p_expires_at, 'INDIVIDUAL',
         btrim(p_note), p_request_id
  from public.installation_subscribers s
  where lower(btrim(s.subscriber_id)) = lower(btrim(p_subscriber_id))
  limit 1
  returning id into v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'installation.hold.placed', 'status', 'NONE', 'ACTIVE',
    'installation_hold', p_request_id,
    'subscriber=' || p_subscriber_id || ' permanence=' || p_permanence
      || coalesce(' stage=' || p_stage_code, '')
      || coalesce(' until=' || p_expires_at::text, ' until=manual')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object('hold_id', v_id, 'idempotent', false,
                            'permanence', p_permanence,
                            'expires_at', p_expires_at);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. تصنيف الحاجب
--
-- الرموز موجودة سلفاً في installation_entitlement_eligibility. هذا يجمعها في
-- أصنافٍ يفهمها المشغّل: كلٌّ منها يُحسم في شاشةٍ مختلفة وبدورٍ مختلف.
-- ---------------------------------------------------------------------------

create or replace function public.blocker_category(p_code text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select case p_code
    when 'ON_HOLD'                     then 'HOLD'
    when 'MISSING_INVOICE'             then 'INVOICE'
    when 'IDENTITY_CONFLICT'           then 'IDENTITY'
    when 'UNKNOWN_PARENT'              then 'PARENT'
    when 'DIRECT_COMPANY_NOT_PAYABLE'  then 'PARENT'
    when 'UNKNOWN_FDT'                 then 'FDT'
    when 'SOURCE_INCOMPLETE'           then 'SOURCE'
    when 'UNRESOLVED_HISTORICAL_STATE' then 'SOURCE'
    when 'ALREADY_PAID'                then 'ELIGIBILITY'
    when 'INVALID_STAGE'               then 'ELIGIBILITY'
    when 'STAGE_OUT_OF_SEQUENCE'       then 'ELIGIBILITY'
    when 'ENROLLMENT_INACTIVE'         then 'ELIGIBILITY'
    when 'STAGE_NOT_IN_SCHEME'         then 'ELIGIBILITY'
    when 'AMOUNT_DOES_NOT_MATCH_SCHEME' then 'ELIGIBILITY'
    when 'NOT_ENROLLED'                then 'ELIGIBILITY'
    else 'OTHER' end;
$fn$;

revoke execute on function public.blocker_category(text) from public, anon;
grant execute on function public.blocker_category(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. المرشّحون — بحجبٍ مصنَّف وجاهزٍ صادق
--
-- «جاهز» هنا يعني: لا تعليق، ولا فاتورة ناقصة، ولا حالة تاريخية غير محسومة،
-- ولا تعارض هوية، ولا عائدية غير محسومة. خلوٌّ من صنفٍ واحد لا يكفي.
-- ---------------------------------------------------------------------------

create or replace function public.installation_payout_candidates()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with base as (
    select
      s.subscriber_id,
      s.reseller,
      st.remaining,
      st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      -- الحجب بالتعليق
      exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at)) as b_hold,
      -- الحجب بالفاتورة: كل مرحلة في المخطّط المنشور تشترط فاتورة مدقَّقة.
      not exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED') as b_invoice,
      -- الحجب بالحالة التاريخية
      (st.resolution <> 'resolved' or st.payment_eligible is not true) as b_source,
      -- الحجب بالهوية
      exists (
        select 1 from public.subscriber_identities i
        where i.username_key = lower(btrim(s.subscriber_id))
          and i.identity_status = 'CONFLICT') as b_identity,
      -- الحجب بالعائدية: غير محسومة، أو شركة مباشرة لا تنشأ عنها عمولة وكيل.
      (public.subscriber_ownership_type(s.subscriber_id) <> 'RESELLER') as b_parent
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  ),
  judged as (
    select b.*,
      (not b_hold and not b_invoice and not b_source
       and not b_identity and not b_parent) as is_ready
    from base b
  )
  select jsonb_build_object(
    'subscribers', count(*),
    'amount', coalesce(sum(amount), 0),

    -- الحجب مصنَّفاً. صفرٌ في صنفٍ لا يعني أن الطريق سالك.
    'blocked', jsonb_build_object(
      'hold',        count(*) filter (where b_hold),
      'invoice',     count(*) filter (where b_invoice),
      'source',      count(*) filter (where b_source),
      'identity',    count(*) filter (where b_identity),
      'parent',      count(*) filter (where b_parent),
      'any',         count(*) filter (where not is_ready)),
    'blocked_amount', jsonb_build_object(
      'hold',    coalesce(sum(amount) filter (where b_hold), 0),
      'invoice', coalesce(sum(amount) filter (where b_invoice), 0),
      'source',  coalesce(sum(amount) filter (where b_source), 0),
      'identity', coalesce(sum(amount) filter (where b_identity), 0),
      'parent',  coalesce(sum(amount) filter (where b_parent), 0),
      'any',     coalesce(sum(amount) filter (where not is_ready), 0)),

    'ready', count(*) filter (where is_ready),
    'ready_amount', coalesce(sum(amount) filter (where is_ready), 0),

    'by_stage', coalesce((
      select jsonb_object_agg(x.stage, jsonb_build_object(
        'subscribers', x.n, 'amount', x.amt, 'ready', x.rdy))
      from (select stage, count(*) as n, sum(amount) as amt,
                   count(*) filter (where is_ready) as rdy
            from judged group by stage) x), '{}'::jsonb),

    'by_reseller', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select j.reseller,
               count(*) as subscribers,
               sum(j.amount) as amount,
               count(*) filter (where j.stage = 'P1') as p1,
               count(*) filter (where j.stage = 'P2') as p2,
               count(*) filter (where j.stage = 'P3') as p3,
               count(*) filter (where j.stage = 'P4') as p4,
               count(*) filter (where j.b_hold) as blocked_hold,
               count(*) filter (where j.b_invoice) as blocked_invoice,
               count(*) filter (where j.b_source or j.b_identity) as blocked_eligibility,
               count(*) filter (where j.b_parent) as blocked_other,
               count(*) filter (where j.is_ready) as ready,
               coalesce(sum(j.amount) filter (where j.is_ready), 0) as ready_amount
        from judged j
        group by j.reseller
        order by sum(j.amount) desc) y), '[]'::jsonb))
  from judged
  where public.has_capability('installation.view');
$fn$;

revoke execute on function public.installation_payout_candidates() from public, anon;
grant execute on function public.installation_payout_candidates() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. السطور — بأصناف الحجب لكل سطر
-- ---------------------------------------------------------------------------

create or replace function public.page_payout_candidate_lines(
  p_reseller text default null,
  p_stage text default null,
  p_only_ready boolean default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_blocker text default null,
  p_search text default null
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

  with base as (
    select
      s.subscriber_id, s.reseller, s.fdt,
      st.remaining, st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      st.resolution, st.payment_eligible,
      (select h.id from public.installation_holds h
       where h.subscriber_id = s.subscriber_id
         and public.hold_is_effective(h.status, h.permanence, h.expires_at)
       limit 1) as hold_id,
      (select coalesce(h.reason_note, h.note) from public.installation_holds h
       where h.subscriber_id = s.subscriber_id
         and public.hold_is_effective(h.status, h.permanence, h.expires_at)
       limit 1) as hold_reason,
      exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED') as invoice_ok,
      exists (
        select 1 from public.subscriber_identities i
        where i.username_key = lower(btrim(s.subscriber_id))
          and i.identity_status = 'CONFLICT') as identity_conflict,
      public.subscriber_ownership_type(s.subscriber_id) as ownership
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  ),
  judged as (
    select b.*,
      -- الأصناف التي تحجب هذا السطر، بترتيب ما يُحسم أوّلاً.
      array_remove(array[
        case when b.hold_id is not null then 'HOLD' end,
        case when not b.invoice_ok then 'INVOICE' end,
        case when b.resolution <> 'resolved' or b.payment_eligible is not true
             then 'SOURCE' end,
        case when b.identity_conflict then 'IDENTITY' end,
        case when b.ownership <> 'RESELLER' then 'PARENT' end
      ], null) as blockers
    from base b
  ),
  kept as (
    select j.*, cardinality(j.blockers) = 0 as is_ready
    from judged j
    where (p_reseller is null or j.reseller = p_reseller)
      and (p_stage is null or j.stage = p_stage)
      and (p_search is null or btrim(p_search) = ''
           or j.subscriber_id ilike '%' || p_search || '%'
           or j.reseller ilike '%' || p_search || '%')
      and (p_blocker is null or p_blocker = any (j.blockers))
  ),
  filtered as (
    select * from kept k
    where p_only_ready is null or k.is_ready = p_only_ready
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select f.subscriber_id, f.reseller, f.fdt, f.stage, f.amount, f.remaining,
             f.hold_id is not null as held, f.hold_reason, f.invoice_ok,
             f.identity_conflict, f.ownership,
             f.resolution, f.payment_eligible,
             to_jsonb(f.blockers) as blockers, f.is_ready
      from filtered f
      order by f.is_ready desc, f.subscriber_id
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from filtered;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_payout_candidate_lines(text,text,boolean,integer,integer,text,text)
  from public, anon;
grant execute on function public.page_payout_candidate_lines(text,text,boolean,integer,integer,text,text)
  to authenticated;

-- التوقيع القديم يُسقَط: بقاؤه يعني نسختين تتباعدان.
drop function if exists public.page_payout_candidate_lines(text,text,boolean,integer,integer);

commit;
