-- Codex review of PR #95 — three findings against
-- import_installation_entitlements (20261027090000), all in the same
-- function/table pair, closed together:
--
-- Blocker 1 (timeout): the per-row loop runs one EXISTS lookup per row
-- inside PL/pgSQL. Codex reproduced a 20,000-row call exceeding Production's
-- authenticated statement_timeout=8s (~8006ms). Fixed by replacing the loop
-- with a single set-based statement: parse -> classify -> reject-reason ->
-- intra-chunk dedup (distinct on) -> insert ... on conflict do nothing,
-- using the installation_entitlements_identity_key unique(period,
-- subscriber_id, stage) constraint the row-by-row EXISTS check was
-- redundant with all along.
--
-- Blocker 2 (partial-batch lifecycle): every successful call — including a
-- non-final chunk — unconditionally set status to 'completed'/'no_new_rows'.
-- A later chunk's failure then left the batch looking finished when it
-- wasn't. Fixed with an explicit p_finalize flag (default true, so every
-- existing single-call caller is unaffected) and an optional p_expected_rows
-- declared at batch creation: a non-finalizing call now leaves the batch
-- 'in_progress'; only an explicit, successful finalize call — validated
-- against expected_rows when the caller opted into that — can mark it
-- completed/no_new_rows, and a batch already completed refuses further
-- continuation outright.
--
-- Blocker 3 (cross-admin IDOR): continuation validated period and checksum
-- against the batch but never created_by, so Admin B could append rows to
-- Admin A's batch by supplying its batch_id and matching checksum. Fixed:
-- continuation now requires created_by = auth.uid(). Cross-owner
-- continuation is not offered as a capability in this migration — if ever
-- wanted, it needs its own explicit, audited path.
--
-- Backward compatible by construction: every existing caller (all current
-- tests, the pre-chunking single-shot import UI) omits p_finalize and
-- p_expected_rows and gets byte-identical behaviour to before this
-- migration. Only chunked continuation (import-run.ts, and the tests that
-- simulate it) needs to say p_finalize := false on every non-final chunk —
-- those call sites are updated alongside this migration.
begin;

-- ---------------------------------------------------------------------
-- ١ · دورة حياة الدفعة: بيانات دائمة إضافية + حالة IN_PROGRESS/FAILED
-- ---------------------------------------------------------------------

alter table public.installation_batches
  add column if not exists expected_rows integer,
  add column if not exists finalized_at timestamptz,
  add column if not exists finalized_by uuid references auth.users(id);

alter table public.installation_batches
  drop constraint if exists installation_batches_status_check;
alter table public.installation_batches
  add constraint installation_batches_status_check
  -- 'failed' غير منتَجة بعد في هذه الهجرة عمداً — لا مسار إلغاءٍ صريحٌ
  -- يُنتجها حالياً؛ أُضيفت للقيد استباقاً لقدرةٍ لاحقة (BUSINESS DECISION
  -- REQUIRED إن رُغب بها)، تماماً كما دخلت 'voided' على saas_import_batches
  -- تدريجياً (20261022090000). 'in_progress' وحدها فعّالة اليوم.
  check (status in ('completed', 'no_new_rows', 'in_progress', 'failed'));

comment on column public.installation_batches.expected_rows is
  'العدد الكلي للصفوف المصرَّح به عند إنشاء الدفعة، إن أعلنه المستدعي — اختياري، يُستخدم للتحقّق عند الإنهاء الصريح فقط.';
comment on column public.installation_batches.finalized_at is
  'وقت الإنهاء الصريح (p_finalize=true ناجح) فقط — لا يُضبط لأيّ جزءٍ غير نهائي.';

-- ---------------------------------------------------------------------
-- ٢ · إعادة الكتابة: مجموعيّة بدل حلقة سطرٍ بسطر، دورة حياةٍ صريحة،
--    وربطٌ بالمالك الأصلي على الإلحاق
-- ---------------------------------------------------------------------

drop function if exists public.import_installation_entitlements(
  text, text, text, jsonb, uuid, uuid);

create or replace function public.import_installation_entitlements(
  p_period text,
  p_file_name text,
  p_file_checksum text,
  p_rows jsonb,
  p_request_id uuid,
  p_batch_id uuid default null,
  p_expected_rows integer default null,
  p_finalize boolean default true
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
  v_batch public.installation_batches%rowtype;
  v_checksum text := nullif(btrim(coalesce(p_file_checksum, '')), '');
  v_resumed boolean := false;
  v_source integer := 0;
  v_accepted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_valid_total integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_status text;
  v_new_source_total integer;
  v_new_accepted_total integer;
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

  -- One import per period at a time, so two uploads cannot interleave —
  -- including two chunks of the same file, so they cannot race each other.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('installation-import:' || p_period, 0)
  );

  if p_batch_id is null then
    -- نفس الملف (بصمةٌ ونصف فترةٍ متطابقتان) له دفعةٌ IN_PROGRESS بالفعل
    -- لنفس الفاعل؟ يُستأنَف بدل إنشاء دفعةٍ جديدةٍ منفصلة — هذا بالضبط ما
    -- يمنع «إعادة تحميل الملف تنشئ دفعةً مكتملةً منقوصةً لا صلة لها». ملفٌّ
    -- مكتمل الدفعة سابقاً (completed/no_new_rows) لا يُستأنَف — رفعٌ جديدٌ
    -- له يبقى دفعةً جديدةً كما كان قبل هذه الهجرة (اختبار «رفع الملف نفسه
    -- مرتين» يثبّت هذا).
    if v_checksum is not null then
      select * into v_batch from public.installation_batches
      where period = p_period
        and file_checksum = v_checksum
        and status = 'in_progress'
        and created_by = v_actor
      order by created_at desc
      limit 1
      for update;
      if found then v_resumed := true; end if;
    end if;

    if not v_resumed then
      insert into public.installation_batches (
        period, file_name, file_checksum, created_by, expected_rows, status
      ) values (
        p_period, coalesce(btrim(p_file_name), ''), v_checksum, v_actor,
        p_expected_rows, 'in_progress'
      )
      returning * into v_batch;
    end if;
    v_batch_id := v_batch.id;
  else
    select * into v_batch from public.installation_batches where id = p_batch_id for update;
    if not found then
      raise exception 'batch_id does not refer to an existing import batch' using errcode = '22023';
    end if;
    -- Blocker 3 (IDOR): دفعةُ مالكٍ آخر لا تُلحَق بها، ولو طابقت الفترة
    -- والبصمة تماماً. لا سعةٌ لإلحاقٍ عابرٍ للمالك في هذا الإصدار.
    if v_batch.created_by <> v_actor then
      raise exception 'batch_id belongs to a different administrator' using errcode = '42501';
    end if;
    if v_batch.status in ('completed', 'no_new_rows') then
      raise exception 'batch_id already finalized — cannot append further chunks' using errcode = '22023';
    end if;
    if v_batch.period <> p_period then
      raise exception 'batch_id belongs to a different period' using errcode = '22023';
    end if;
    if v_batch.file_checksum is distinct from v_checksum then
      raise exception 'batch_id does not match the checksum of this file' using errcode = '22023';
    end if;
    if p_expected_rows is not null and v_batch.expected_rows is not null
       and p_expected_rows <> v_batch.expected_rows then
      raise exception 'batch_id does not match the expected row count of this file' using errcode = '22023';
    end if;
    v_batch_id := v_batch.id;
  end if;

  -- ---------------------------------------------------------------------
  -- الاستيعاب مجموعياً: تحليلٌ ثم تصنيفٌ ثم سبب رفضٍ (بنفس أولوية الحلقة
  -- القديمة: مشترك ناقص -> موزّع ناقص -> Remaining غير محسوم) ثم إزالة
  -- تكرارٍ داخل الجزء (أوّل ورودٍ يفوز، بلا حساسية حالة الأحرف على
  -- المشترك) ثم إدراجٌ يتجاهل تعارض قيد الهوية الفريد بدل فحصٍ مسبقٍ
  -- لكلّ صفّ — هذا وحده كان يتجاوز 8 ثوانٍ عند 20,000 صفّ.
  -- ---------------------------------------------------------------------
  with source as (
    select ordinality::int as row_no, value as item
    from jsonb_array_elements(p_rows) with ordinality as t(value, ordinality)
  ),
  parsed as (
    select row_no,
      btrim(coalesce(item ->> 'subscriber_id', '')) as subscriber_id,
      btrim(coalesce(item ->> 'reseller', '')) as reseller,
      nullif(btrim(coalesce(item ->> 'fdt', '')), '') as fdt,
      btrim(coalesce(item ->> 'subscriber_name', '')) as subscriber_name,
      -- صيغة صحيحٍ آمنة بدل cast+exception لكلّ صفّ — نفس نمط الحرس من
      -- الفيضان المعتمد أصلاً في fdt_commission_scope (لا أكثر من 18 رقماً).
      case when (item ->> 'remaining') ~ '^-?[0-9]{1,18}$'
           then (item ->> 'remaining')::bigint else null end as remaining
    from source
  ),
  classified as (
    select p.row_no, p.subscriber_id, p.reseller, p.subscriber_name, p.fdt,
      (case when public.fdt_commission_scope(p.fdt) = 'FDT' then 'new' else 'old' end) as zone,
      (case when p.remaining is null then null
            else public.installation_stage_for_remaining(p.remaining) end) as stage,
      p.remaining
    from parsed p
  ),
  reason as (
    select row_no,
      case when subscriber_id = '' then 'missing_subscriber'
           when reseller = '' then 'missing_reseller'
           when stage is null then 'unknown_remaining'
           else null end as reject_reason
    from classified
  ),
  valid as (
    select c.* from classified c join reason r using (row_no) where r.reject_reason is null
  ),
  deduped as (
    select distinct on (lower(subscriber_id), stage) *
    from valid order by lower(subscriber_id), stage, row_no
  ),
  inserted as (
    insert into public.installation_entitlements (
      batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
      remaining, stage, amount, payment_status, created_by
    )
    select v_batch_id, p_period, d.subscriber_id, d.subscriber_name, d.reseller, d.zone, d.fdt,
      d.remaining, d.stage, public.installation_amount_for_stage(d.stage),
      case when d.stage = 'DONE' then 'not_eligible' else 'awaiting_invoice' end, v_actor
    from deduped d
    on conflict (period, subscriber_id, stage) do nothing
    returning 1
  )
  select
    (select count(*) from reason where reject_reason is not null),
    (select count(*) from valid),
    (select count(*) from inserted),
    coalesce((select jsonb_agg(jsonb_build_object('row', row_no, 'reason', reject_reason) order by row_no)
              from reason where reject_reason is not null), '[]'::jsonb)
  into v_rejected, v_valid_total, v_accepted, v_rejects;

  v_source := jsonb_array_length(p_rows);
  -- يشمل تكرار الجزء الداخلي (distinct on) وتعارض قيد الهوية معاً — كلاهما
  -- صفوفٌ صالحةٌ لم تُدرَج، بالضبط ما كانت الحلقة القديمة تعدّه تكراراً.
  v_duplicate := v_valid_total - v_accepted;

  v_new_source_total := v_batch.source_rows + v_source;
  v_new_accepted_total := v_batch.accepted_rows + v_accepted;

  if p_finalize then
    -- Blocker 2: الإنهاء الصريح يفشل صراحةً إن لم تكتمل الصفوف المصرَّح
    -- بها عند الإنشاء — لا إكمالٌ صامتٌ ولا بقاءٌ معلَّقٌ بلا تفسير.
    if v_batch.expected_rows is not null and v_new_source_total <> v_batch.expected_rows then
      raise exception
        'finalization requested before all rows were received (% of % rows)',
        v_new_source_total, v_batch.expected_rows
        using errcode = '22023';
    end if;
    v_status := case when v_new_accepted_total = 0 then 'no_new_rows' else 'completed' end;
  else
    v_status := 'in_progress';
  end if;

  update public.installation_batches
  set source_rows = v_new_source_total,
      accepted_rows = v_new_accepted_total,
      duplicate_rows = v_batch.duplicate_rows + v_duplicate,
      rejected_rows = v_batch.rejected_rows + v_rejected,
      status = v_status,
      finalized_at = case when p_finalize then now() else finalized_at end,
      finalized_by = case when p_finalize then v_actor else finalized_by end
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'id', v_batch_id, 'batch_id', v_batch_id,
    'period', p_period, 'file_name', coalesce(btrim(p_file_name), ''),
    'source_rows', v_source, 'accepted', v_accepted,
    'duplicates', v_duplicate, 'rejected', v_rejected, 'status', v_status,
    -- إجماليّ الدفعة كلها حتى الآن، لا هذا الجزء وحده — الواجهة تعرضه بعد آخر جزء.
    'batch_totals', jsonb_build_object(
      'source_rows', v_new_source_total,
      'accepted', v_new_accepted_total,
      'duplicates', v_batch.duplicate_rows + v_duplicate,
      'rejected', v_batch.rejected_rows + v_rejected),
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

revoke execute on function public.import_installation_entitlements(
  text, text, text, jsonb, uuid, uuid, integer, boolean) from public, anon;
grant execute on function public.import_installation_entitlements(
  text, text, text, jsonb, uuid, uuid, integer, boolean) to authenticated;

commit;
