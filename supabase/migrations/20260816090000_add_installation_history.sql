-- الاستيراد التاريخي الابتدائي لأجور التنصيب.
--
-- لماذا هذه المهاجرة. الجداول المنشورة تمثّل استحقاق شهر واحد:
-- installation_entitlements مفتاحه (period, subscriber_id, stage)، و
-- installation_payments دفعة صرف واحدة لكل استحقاق. لا يوجد فيها سجل
-- للمشترك نفسه، ولا تاريخ بدء، ولا الدفعات التي استلمها قبل دخوله النظام.
-- ملف المتابعة يحمل هذه المعلومات لأكثر من خمسة آلاف مشترك، ومحاولة
-- تمثيلها بالجداول الحالية تعني إما فقدان التاريخ أو تكرار المشترك بعدد
-- دفعاته. لذلك يضيف هذا الملف ثلاث طبقات مفصولة صراحة:
--
--   installation_subscribers       هوية المشترك ووصفه الثابت
--   installation_subscriber_state  حالته الحالية كما في لقطة الملف
--   installation_payment_history   وقائع الدفع السابقة، كل واحدة بتاريخها
--
-- إضافية بالكامل: لا تُعدَّل ولا تُحذف أي جدول أو دالة منشورة، ولا تُمسّ
-- جداول العمولات. forward-only.
--
-- ملاحظة على معنى stage: هي الدفعة التالية المستحقة مشتقة من المتبقي،
-- وليست دليلاً على أن ما قبلها غير مدفوع. تاريخ الدفع مصدره الوحيد
-- installation_payment_history.

begin;

-- ---------------------------------------------------------------------------
-- 1. الدفعة تُصنَّف بنوعها، واللقطة التاريخية تحمل تاريخها الصريح.
-- ---------------------------------------------------------------------------

alter table public.installation_batches
  add column if not exists batch_type text not null default 'monthly';

alter table public.installation_batches
  add column if not exists as_of_date date;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'installation_batches_type_check'
  ) then
    alter table public.installation_batches
      add constraint installation_batches_type_check
      check (batch_type in ('monthly', 'historical'));
  end if;
  -- اللقطة التاريخية بلا تاريخ لا معنى لها؛ والشهرية لا تحمل تاريخ لقطة.
  if not exists (
    select 1 from pg_constraint where conname = 'installation_batches_as_of_check'
  ) then
    alter table public.installation_batches
      add constraint installation_batches_as_of_check
      check (
        (batch_type = 'historical' and as_of_date is not null)
        or (batch_type = 'monthly' and as_of_date is null)
      );
  end if;
end;
$$;

-- period مطلوب في الجدول المنشور، والاستيراد التاريخي ليس لشهر بعينه.
-- بدل تعديل العمود المنشور نملأه من تاريخ اللقطة داخل الدالة.

-- ---------------------------------------------------------------------------
-- 2. سجل المشترك. الهوية هي المعرّف وحده.
--
-- قرار موثّق: في الملف الحقيقي 5693 معرّفاً فريداً عبر ثلاثة شيتات بلا أي
-- تكرار بينها، فالمعرّف كافٍ للهوية. جعل الوكيل جزءاً من المفتاح كان
-- سينشئ مشتركاً ثانياً عند انتقاله بين وكيلين ويُفقده تاريخه؛ وبهذا
-- الشكل ينتقل الوكيل على السجل نفسه ويُسجَّل التغيّر في التدقيق.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_subscribers (
  id uuid primary key default gen_random_uuid(),
  subscriber_id text not null,
  subscriber_key text not null
    generated always as (pg_catalog.lower(pg_catalog.btrim(subscriber_id))) stored,
  reseller text not null,
  fdt text,
  start_date date,
  total_amount bigint,
  notes text,
  first_batch_id uuid references public.installation_batches(id) on delete restrict,
  last_batch_id uuid references public.installation_batches(id) on delete restrict,
  created_by uuid not null references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint installation_subscribers_identity_key unique (subscriber_key),
  constraint installation_subscribers_id_check check (btrim(subscriber_id) <> ''),
  constraint installation_subscribers_reseller_check check (btrim(reseller) <> ''),
  constraint installation_subscribers_total_check check (total_amount is null or total_amount >= 0)
);

-- ---------------------------------------------------------------------------
-- 3. الحالة الحالية، مفصولة عن الهوية لأنها هي ما يتغيّر مع كل لقطة.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_subscriber_state (
  subscriber_uuid uuid primary key
    references public.installation_subscribers(id) on delete cascade,
  as_of_date date not null,
  remaining bigint,
  received_total bigint,
  total_amount bigint,
  current_stage text,
  resolution text not null default 'resolved',
  -- الأهلية للصرف حقل محسوب على الخادم لا مُدخل، وقيود أدناه تجعل تخزين
  -- صف غير محسوم كمؤهَّل مستحيلاً حتى لو أخطأ الاستدعاء.
  payment_eligible boolean not null default false,
  warnings text[] not null default '{}',
  batch_id uuid references public.installation_batches(id) on delete restrict,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint installation_state_resolution_check
    check (resolution in ('resolved', 'unresolved')),
  constraint installation_state_stage_check
    check (current_stage is null or current_stage in ('P1', 'P2', 'P3', 'P4', 'DONE')),
  constraint installation_state_remaining_check
    check (remaining is null or remaining >= 0),
  constraint installation_state_received_check
    check (received_total is null or received_total >= 0),
  -- `is not distinct from` وليس `=`: المقارنة بـNULL تعطي NULL وCHECK يمرّ
  -- عليها، وهي الثغرة التي ظهرت في المهاجرة السابقة.
  constraint installation_state_stage_matches_remaining
    check (current_stage is not distinct from public.installation_stage_for_remaining(remaining)),
  -- متبقٍّ غير معروف لا يُخمَّن له مرحلة.
  constraint installation_state_unknown_remaining_has_no_stage
    check (remaining is not null or current_stage is null),
  -- اختلال محاسبي يعني حالة غير محسومة، مهما كانت المرحلة المشتقة.
  -- المتغيّرات الثلاثة مطلوبة معاً حتى تكون المطابقة ذات معنى.
  constraint installation_state_mismatch_is_unresolved
    check (
      total_amount is null or received_total is null or remaining is null
      or total_amount - received_total = remaining
      or resolution = 'unresolved'
    ),
  -- لا صرف من صف غير محسوم، ولا صرف حيث لا توجد دفعة قادمة.
  constraint installation_state_unresolved_is_never_eligible
    check (payment_eligible is false or resolution = 'resolved'),
  constraint installation_state_eligible_needs_pending_stage
    check (payment_eligible is false or current_stage in ('P1', 'P2', 'P3', 'P4'))
);

-- ---------------------------------------------------------------------------
-- 4. تاريخ الدفعات. واقعة واحدة لكل (مشترك، مرحلة).
--
-- قرار موثّق: المفتاح (subscriber, stage) أقوى من
-- (subscriber, stage, date, amount) الذي اقتُرح: المشترك لا يملك أكثر من
-- دفعة واحدة لكل مرحلة، فلو صُحّح تاريخ P2 في ملف لاحق فالمفتاح الأضعف
-- كان سينشئ P2 ثانية بينما هذا يحدّثها في مكانها.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_payment_history (
  id uuid primary key default gen_random_uuid(),
  subscriber_uuid uuid not null
    references public.installation_subscribers(id) on delete cascade,
  stage text not null,
  amount bigint not null,
  payment_date date,
  batch_id uuid references public.installation_batches(id) on delete restrict,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint installation_history_identity_key unique (subscriber_uuid, stage),
  constraint installation_history_stage_check check (stage in ('P1', 'P2', 'P3', 'P4')),
  -- المبلغ يأتي من الملف كما هو ولا يُصحَّح، لكنه لا يكون صفراً أو سالباً:
  -- الخانة الفارغة لا تُنشئ واقعة دفع أصلاً.
  constraint installation_history_amount_check check (amount > 0)
);

create index if not exists installation_subscribers_reseller_idx
  on public.installation_subscribers (reseller);
create index if not exists installation_subscribers_batch_idx
  on public.installation_subscribers (last_batch_id);
create index if not exists installation_state_stage_idx
  on public.installation_subscriber_state (current_stage);
create index if not exists installation_state_resolution_idx
  on public.installation_subscriber_state (resolution);
create index if not exists installation_history_subscriber_idx
  on public.installation_payment_history (subscriber_uuid);
create index if not exists installation_history_stage_idx
  on public.installation_payment_history (stage);
create index if not exists installation_history_date_idx
  on public.installation_payment_history (payment_date);

drop trigger if exists trg_installation_subscribers_updated on public.installation_subscribers;
create trigger trg_installation_subscribers_updated
  before update on public.installation_subscribers
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. الاستيراد التاريخي.
--
-- يقبل صفوفاً تحمل المشترك ووصفه ودفعاته، ويشتق المرحلة على الخادم من
-- المتبقي لا من المُرسِل. إعادة تشغيله بنفس الملف لا تنشئ مشتركاً ولا
-- دفعة ولا حالة مكرّرة.
-- ---------------------------------------------------------------------------

create or replace function public.import_installation_history(
  p_as_of_date date,
  p_file_name text,
  p_file_checksum text,
  p_rows jsonb,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing record;
  v_batch_id uuid;
  v_item jsonb;
  v_payment jsonb;
  v_subscriber text;
  v_reseller text;
  v_remaining bigint;
  v_received bigint;
  v_total bigint;
  v_stage text;
  v_resolution text;
  v_mismatch boolean;
  v_incomplete boolean;
  v_eligible boolean;
  v_warnings text[];
  v_mismatches integer := 0;
  v_incompletes integer := 0;
  v_eligibles integer := 0;
  v_blocked integer := 0;
  v_uuid uuid;
  v_is_new boolean;
  v_prev_reseller text;
  v_seen text[] := array[]::text[];
  v_key text;
  v_source integer := 0;
  v_new_subscribers integer := 0;
  v_updated_subscribers integer := 0;
  v_new_payments integer := 0;
  v_updated_payments integer := 0;
  v_touched_payments integer := 0;
  v_unresolved integer := 0;
  v_reseller_moves integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  -- لا يُخترع تاريخ لقطة، ولا يُشتق من آخر دفعة: المستخدم يختاره صراحة.
  if p_as_of_date is null then
    raise exception 'as_of_date is required for a historical import' using errcode = '22023';
  end if;
  if p_as_of_date > current_date then
    raise exception 'as_of_date cannot be in the future' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 20000 then
    raise exception 'Rows must contain between 1 and 20000 entries' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.history.imported' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('batch', v_existing.after_data, 'replayed', true);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('installation-history-import', 0)
  );

  insert into public.installation_batches (
    period, file_name, file_checksum, batch_type, as_of_date, created_by
  ) values (
    pg_catalog.to_char(p_as_of_date, 'YYYY-MM'),
    coalesce(pg_catalog.btrim(p_file_name), ''),
    nullif(pg_catalog.btrim(coalesce(p_file_checksum, '')), ''),
    'historical', p_as_of_date, v_actor
  ) returning id into v_batch_id;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_source := v_source + 1;
    v_subscriber := pg_catalog.btrim(coalesce(v_item ->> 'subscriber_id', ''));
    v_reseller := pg_catalog.btrim(coalesce(v_item ->> 'reseller', ''));

    -- صف بلا مشترك فعلي ليس مشتركاً: يُتجاهل ولا يدخل أي إحصاء.
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

    v_key := lower(v_subscriber);
    if v_key = any (v_seen) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;
    v_seen := v_seen || v_key;

    begin
      v_remaining := (v_item ->> 'remaining')::bigint;
    exception when others then
      v_remaining := null;
    end;
    begin
      v_received := (v_item ->> 'received_total')::bigint;
    exception when others then
      v_received := null;
    end;
    begin
      v_total := (v_item ->> 'total_amount')::bigint;
    exception when others then
      v_total := null;
    end;

    -- المرحلة تُشتق على الخادم؛ ما يرسله العميل لا يُصدَّق.
    v_stage := public.installation_stage_for_remaining(v_remaining);

    -- الاختلال المحاسبي يُحسب هنا لا في المتصفح. القيم الخام تُخزَّن كما
    -- وصلت، لكن الصف يفقد صفة الحسم ومعها الأهلية للصرف.
    v_mismatch := v_total is not null and v_received is not null and v_remaining is not null
                  and v_total - v_received <> v_remaining;
    if v_mismatch then v_mismatches := v_mismatches + 1; end if;

    v_resolution := case when v_stage is null or v_mismatch then 'unresolved' else 'resolved' end;
    if v_resolution = 'unresolved' then v_unresolved := v_unresolved + 1; end if;

    -- حالة مكتملة بلا دفعة رابعة: يُعلَّم النقص ولا تُخترع دفعة.
    v_incomplete := v_stage = 'DONE' and not exists (
      select 1 from jsonb_array_elements(coalesce(v_item -> 'payments', '[]'::jsonb)) as p
      where p.value ->> 'stage' = 'P4' and coalesce((p.value ->> 'amount')::bigint, 0) > 0
    );
    if v_incomplete then v_incompletes := v_incompletes + 1; end if;

    v_eligible := v_resolution = 'resolved' and v_stage in ('P1', 'P2', 'P3', 'P4');
    if v_eligible then v_eligibles := v_eligibles + 1; else v_blocked := v_blocked + 1; end if;

    v_warnings := array[]::text[];
    if v_remaining is null then v_warnings := v_warnings || 'remaining_missing'::text;
    elsif v_stage is null then v_warnings := v_warnings || 'remaining_unmapped'::text;
    end if;
    if v_mismatch then v_warnings := v_warnings || 'remaining_mismatch'::text; end if;
    if v_incomplete then v_warnings := v_warnings || 'historical_payment_detail_incomplete'::text; end if;

    select id, reseller into v_uuid, v_prev_reseller
    from public.installation_subscribers where subscriber_key = v_key;
    v_is_new := not found;

    if v_is_new then
      insert into public.installation_subscribers (
        subscriber_id, reseller, fdt, start_date, total_amount, notes,
        first_batch_id, last_batch_id, created_by, updated_by
      ) values (
        v_subscriber, v_reseller,
        nullif(pg_catalog.btrim(coalesce(v_item ->> 'fdt', '')), ''),
        (nullif(v_item ->> 'start_date', ''))::date,
        v_total,
        nullif(pg_catalog.btrim(coalesce(v_item ->> 'notes', '')), ''),
        v_batch_id, v_batch_id, v_actor, v_actor
      ) returning id into v_uuid;
      v_new_subscribers := v_new_subscribers + 1;
    else
      if v_prev_reseller is distinct from v_reseller then
        v_reseller_moves := v_reseller_moves + 1;
      end if;
      -- التحديث لا يمسح ما لا يحمله الملف الجديد.
      update public.installation_subscribers
      set reseller = v_reseller,
          fdt = coalesce(nullif(pg_catalog.btrim(coalesce(v_item ->> 'fdt', '')), ''), fdt),
          start_date = coalesce((nullif(v_item ->> 'start_date', ''))::date, start_date),
          total_amount = coalesce(v_total, total_amount),
          notes = coalesce(nullif(pg_catalog.btrim(coalesce(v_item ->> 'notes', '')), ''), notes),
          last_batch_id = v_batch_id,
          updated_by = v_actor
      where id = v_uuid;
      v_updated_subscribers := v_updated_subscribers + 1;
    end if;

    insert into public.installation_subscriber_state (
      subscriber_uuid, as_of_date, remaining, received_total, total_amount,
      current_stage, resolution, payment_eligible, warnings, batch_id, updated_by
    ) values (
      v_uuid, p_as_of_date, v_remaining, v_received, v_total,
      v_stage, v_resolution, v_eligible, v_warnings, v_batch_id, v_actor
    )
    on conflict (subscriber_uuid) do update
      set as_of_date = excluded.as_of_date,
          remaining = excluded.remaining,
          received_total = excluded.received_total,
          total_amount = excluded.total_amount,
          current_stage = excluded.current_stage,
          resolution = excluded.resolution,
          payment_eligible = excluded.payment_eligible,
          warnings = excluded.warnings,
          batch_id = excluded.batch_id,
          updated_by = excluded.updated_by,
          updated_at = now();

    for v_payment in select value from jsonb_array_elements(coalesce(v_item -> 'payments', '[]'::jsonb))
    loop
      -- خانة فارغة أو صفرية لا تنشئ واقعة دفع.
      continue when coalesce((v_payment ->> 'amount')::bigint, 0) <= 0;
      continue when coalesce(v_payment ->> 'stage', '') not in ('P1', 'P2', 'P3', 'P4');

      insert into public.installation_payment_history as h (
        subscriber_uuid, stage, amount, payment_date, batch_id, created_by
      ) values (
        v_uuid,
        v_payment ->> 'stage',
        (v_payment ->> 'amount')::bigint,
        (nullif(v_payment ->> 'payment_date', ''))::date,
        v_batch_id, v_actor
      )
      on conflict (subscriber_uuid, stage) do update
        set amount = excluded.amount,
            payment_date = coalesce(excluded.payment_date, h.payment_date),
            updated_at = now()
      -- التحديث يحدث فقط عند تغيّر فعلي، فإعادة الرفع لا تلمس شيئاً.
      where h.amount is distinct from excluded.amount
         or (excluded.payment_date is not null
             and h.payment_date is distinct from excluded.payment_date);

      get diagnostics v_updated_payments = row_count;
      v_touched_payments := v_touched_payments + v_updated_payments;
    end loop;
  end loop;

  select count(*) into v_new_payments
  from public.installation_payment_history where batch_id = v_batch_id;

  update public.installation_batches
  set source_rows = v_source,
      accepted_rows = v_new_subscribers + v_updated_subscribers,
      duplicate_rows = v_duplicate,
      rejected_rows = v_rejected,
      status = case when v_new_subscribers + v_updated_subscribers = 0
                    then 'no_new_rows' else 'completed' end
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'id', v_batch_id,
    'batch_type', 'historical',
    'as_of_date', p_as_of_date,
    'file_name', coalesce(pg_catalog.btrim(p_file_name), ''),
    'source_rows', v_source,
    'new_subscribers', v_new_subscribers,
    'updated_subscribers', v_updated_subscribers,
    'payments_recorded', v_new_payments,
    'payments_changed', v_touched_payments,
    'unresolved', v_unresolved,
    'financial_mismatches', v_mismatches,
    'incomplete_histories', v_incompletes,
    'eligible', v_eligibles,
    'blocked', v_blocked,
    'reseller_moves', v_reseller_moves,
    'duplicates', v_duplicate,
    'rejected', v_rejected,
    'rejections', case when jsonb_array_length(v_rejects) > 50
                       then jsonb_build_object('truncated', true)
                       else v_rejects end
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, extra, before_data, after_data, request_id
  ) values (
    v_actor, 'installation.history.imported', 'installation_batch', v_batch_id, 'subscribers',
    '0', (v_new_subscribers + v_updated_subscribers)::text,
    pg_catalog.to_char(p_as_of_date, 'YYYY-MM-DD'),
    jsonb_build_object('as_of_date', p_as_of_date, 'file_name', coalesce(pg_catalog.btrim(p_file_name), '')),
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. الحماية. جلسة المتصفح تقرأ ولا تكتب؛ الكتابة عبر الدالة أعلاه فقط.
-- ---------------------------------------------------------------------------

alter table public.installation_subscribers enable row level security;
alter table public.installation_subscriber_state enable row level security;
alter table public.installation_payment_history enable row level security;

drop policy if exists installation_subscribers_select on public.installation_subscribers;
create policy installation_subscribers_select
  on public.installation_subscribers for select to authenticated using (true);

drop policy if exists installation_state_select on public.installation_subscriber_state;
create policy installation_state_select
  on public.installation_subscriber_state for select to authenticated using (true);

drop policy if exists installation_history_select on public.installation_payment_history;
create policy installation_history_select
  on public.installation_payment_history for select to authenticated using (true);

-- revoke all أولاً وليس revoke insert/update/delete فقط: امتيازات Supabase
-- الافتراضية تمنح ALL على الجداول الجديدة لدور authenticated، ومنها TRUNCATE
-- الذي لا يخضع لسياسات الصفوف. هذا هو الدرس المستخلص من 20260815180000.
revoke all on table public.installation_subscribers from authenticated;
revoke all on table public.installation_subscriber_state from authenticated;
revoke all on table public.installation_payment_history from authenticated;

grant select on table public.installation_subscribers to authenticated;
grant select on table public.installation_subscriber_state to authenticated;
grant select on table public.installation_payment_history to authenticated;

revoke all on table public.installation_subscribers from anon;
revoke all on table public.installation_subscriber_state from anon;
revoke all on table public.installation_payment_history from anon;

revoke execute on function public.import_installation_history(date, text, text, jsonb, uuid)
  from public, anon;
grant execute on function public.import_installation_history(date, text, text, jsonb, uuid)
  to authenticated;

commit;
