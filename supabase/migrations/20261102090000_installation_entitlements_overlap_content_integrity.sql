-- Independent review of PR #95 at 3acabde (post 20261101090000): one
-- remaining financial-integrity finding against import_installation_entitlements.
-- Additive only — neither 20261031090000 nor 20261101090000 is edited.
--
-- Blocker (partial overlap could process already-received row content):
-- 20261101090000 correctly computed v_new_length as "positions in this call
-- not already in received_rows", and correctly skipped the whole ingestion
-- CTE when a call was a *full* replay (v_new_length = 0). But whenever a
-- call was a *partial* overlap (some positions new, some already received),
-- v_new_length > 0 ran the CTE over the ENTIRE incoming p_rows array — so an
-- already-received position resent with DIFFERENT content in the same call
-- as a genuinely new position could still be parsed and, if its
-- (period, subscriber_id, stage) identity happened to be new (e.g. the
-- replay changed the subscriber_id), inserted. received_rows said that file
-- position was already received while its financial content could still be
-- altered by the very call that was supposed to be a safe replay.
--
-- Fixed with the simplest sufficient invariant: an already-received logical
-- file position is never read again, regardless of what content a later
-- call attaches to it. The ingestion CTE's row source now filters out any
-- element whose absolute file position (p_row_offset + its index in this
-- call) is already contained in the batch's received_rows — before that
-- element is parsed, classified, or considered for insertion. A position is
-- only ever ingested once, from whichever call first delivers it; every
-- later call touching that same position, same content or not, is inert for
-- it. This also removes the narrow "duplicate_rows/rejected_rows may
-- slightly over-count an overlapping resend" limitation 20261101090000
-- documented — those informational counters are now exact too, since they
-- are computed from the same filtered, genuinely-new row set.
--
-- No change to how much of a call counts toward source_rows: v_new_length
-- (multirange arithmetic) and "how many of p_rows survive the position
-- filter" are the same set by construction, so the two stay consistent.
-- No change to finalize-time gap detection: source_rows already equals the
-- cardinality of received_rows, and received_rows is by construction a
-- subset of [0, expected_rows); reaching source_rows = expected_rows is
-- therefore only possible when received_rows covers [0, expected_rows) with
-- no gaps, so the existing "source_rows <> expected_rows" finalize check
-- already rejects an incomplete/gapped batch without further change.
--
-- Also closes a migration-upgrade gap: any batch that was left IN_PROGRESS
-- by the pre-20261101090000 function has source_rows > 0 but a default
-- empty received_rows (the column did not exist for it before). Under the
-- old, offset-less contract such a batch's rows were guaranteed contiguous
-- — every chunk was appended at the end — so its true coverage is exactly
-- [0, source_rows). Left unbackfilled, the very first post-upgrade call to
-- such a batch would treat all of [0, source_rows) as "not yet received",
-- letting old, already-committed positions be reprocessed (with a
-- different, changeable request) and inflating source_rows past
-- expected_rows. Backfilled once, narrowly, for exactly that legacy shape;
-- completed/no_new_rows batches and their entitlement data are untouched —
-- a finalized batch never accepts continuation regardless of received_rows.
begin;

-- ---------------------------------------------------------------------
-- ٠ · ترحيل: أيّ دفعةٍ IN_PROGRESS خلّفها العقد القديم (قبل 20261101090000)
--    لها source_rows > 0 لكن received_rows فارغة افتراضياً — العقد القديم
--    كان يُلحِق دوماً في النهاية، فتغطيتها الحقيقية هي [0, source_rows)
--    بالضبط. تُملأ مرّةً واحدةً هنا كي لا تبدو مواضعها القديمة "غير
--    مستقبلة" فتُعاد معالجتها بعد الترقية.
-- ---------------------------------------------------------------------

do $$
begin
  update public.installation_batches
  set received_rows = int8multirange(int8range(0, source_rows))
  where status = 'in_progress'
    and source_rows > 0
    and received_rows = '{}'::int8multirange;
end;
$$;

-- ---------------------------------------------------------------------
-- ١ · إعادة الكتابة: فلترة مصدر الاستيعاب على مواضع الملف الجديدة فعلياً
--    فقط — لا يُقرأ محتوى موضعٍ سبق استقباله مطلقاً، بصرف النظر عمّا يحمله
--    نداءٌ لاحقٌ له. التوقيع لم يتغيّر فـcreate or replace يكفي.
-- ---------------------------------------------------------------------

create or replace function public.import_installation_entitlements(
  p_period text,
  p_file_name text,
  p_file_checksum text,
  p_rows jsonb,
  p_request_id uuid,
  p_batch_id uuid default null,
  p_expected_rows integer default null,
  p_finalize boolean default true,
  p_row_offset bigint default null
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
  v_file_name text := coalesce(btrim(p_file_name), '');
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
  v_row_offset bigint;
  v_incoming_range int8range;
  v_new_range int8multirange;
  v_new_length bigint;
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
    -- نفس الملف (بصمةٌ واسمٌ وعدد صفوفٍ متصرَّحٍ به متطابقة) له دفعةٌ
    -- IN_PROGRESS بالفعل لنفس الفاعل؟ يُستأنَف بدل إنشاء دفعةٍ جديدةٍ
    -- منفصلة — هذا بالضبط ما يمنع «إعادة تحميل الملف تنشئ دفعةً مكتملةً
    -- منقوصةً لا صلة لها» (Blocker 1). طريقٌ ضمنيٌّ أفضل-جهدٍ لا صريح: عدم
    -- تطابق الاسم أو العدد المتصرَّح به لا يُرفَض هنا، بل يُفتَح ببساطة
    -- دفعةٌ جديدة منفصلة — الرفض الصريح محجوزٌ لإلحاقٍ صريحٍ بـp_batch_id
    -- (أدناه)، حيث الفاعل يعلن نيّةً محدَّدة لا مجرّد استئنافٍ تلقائي.
    -- ملفٌّ مكتمل الدفعة سابقاً (completed/no_new_rows) لا يُستأنَف — رفعٌ
    -- جديدٌ له يبقى دفعةً جديدةً كما كان قبل هذه الهجرة.
    if v_checksum is not null then
      select * into v_batch from public.installation_batches
      where period = p_period
        and file_checksum = v_checksum
        and file_name = v_file_name
        and status = 'in_progress'
        and expected_rows is not distinct from p_expected_rows
        and created_by = v_actor
      order by created_at desc
      limit 1
      for update;
      if found then v_resumed := true; end if;
    end if;

    if not v_resumed then
      -- Blocker 2: فتح دفعةٍ غير نهائية (سيلحق بها المزيد لاحقاً) بلا
      -- expected_rows صالح موجَبٍ مرفوضٌ عند حدود الخادم — لا اعتماد على
      -- أن الواجهة أرسلته. نداءٌ نهائيٌّ منذ إنشائه (p_finalize الافتراضي
      -- true) يكتمل ذرّياً في نفس النداء فلا شيء يُستأنَف لاحقاً، فلا حاجة
      -- تفرضه.
      if not p_finalize and (p_expected_rows is null or p_expected_rows <= 0) then
        raise exception
          'expected_rows is required and must be a positive integer when a batch is left open for continuation (p_finalize=false)'
          using errcode = '22023';
      end if;
      insert into public.installation_batches (
        period, file_name, file_checksum, created_by, expected_rows, status
      ) values (
        p_period, v_file_name, v_checksum, v_actor,
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
    -- Blocker 3: هوية الملف تشمل اسمه أيضاً، لا البصمة والفترة فحسب — ملفٌّ
    -- مختلفٌ لا يُلحَق بدفعة ملفٍّ آخر لمجرّد تطابق البصمة عرَضاً.
    if v_batch.file_name <> v_file_name then
      raise exception 'batch_id does not match the file name of this upload' using errcode = '22023';
    end if;
    -- Blocker 2: أيّ دفعةٍ وصلت هذا الفرع بحالة in_progress أُنشئت عبر
    -- p_finalize=false، وهذا يفرض منذ الإنشاء (أعلاه) أن يكون لها
    -- expected_rows موجَب — فلا تبقى غير محدَّدة هنا أبداً. كلّ إلحاقٍ لاحقٍ
    -- يعيدها بالضبط، لا يُغيّرها ولا يُغفلها.
    if v_batch.expected_rows is not null
       and (p_expected_rows is null or p_expected_rows <> v_batch.expected_rows) then
      raise exception 'batch_id does not match the expected row count of this file' using errcode = '22023';
    end if;
    v_batch_id := v_batch.id;
  end if;

  -- ---------------------------------------------------------------------
  -- Blocker 1: موضع هذا الجزء داخل الملف المصدر. مُعلَنٌ صراحةً
  -- (p_row_offset) من عميلٍ يعرف موضعه الحقيقي، أو مُشتقٌّ ضمنياً كموضع
  -- «حيث توقّفت هذه الدفعة» لأيّ عميلٍ لا يُعلنه — وهذا يُعيد بالضبط سلوك
  -- الإلحاق التراكمي القديم لكلّ مستدعٍ لا يعرف عن إعادة التشغيل شيئاً
  -- (كامل مصفوفة الاختبارات الحالية)، لأن مدى الاستقبال المُتراكم بهذا
  -- الطريق يبقى دائماً [0, source_rows) متّصلاً بلا فجوات.
  -- ---------------------------------------------------------------------
  v_row_offset := coalesce(p_row_offset, v_batch.source_rows);
  if v_row_offset < 0 then
    raise exception 'row_offset must not be negative' using errcode = '22023';
  end if;
  v_incoming_range := int8range(v_row_offset, v_row_offset + jsonb_array_length(p_rows));
  if v_batch.expected_rows is not null and upper(v_incoming_range) > v_batch.expected_rows then
    raise exception 'row_offset and row count exceed the declared expected_rows for this batch'
      using errcode = '22023';
  end if;

  -- الجزء الجديد فعلياً من هذا النداء: مدى المواضع الوارد ناقص ما استقبلته
  -- هذه الدفعة من قبل. نداءٌ يعيد بالضبط مدىً استُقبل سابقاً (إعادة تشغيلٍ
  -- كاملة من البداية، بمعرّف طلبٍ جديد) لا يحمل شيئاً جديداً إطلاقاً —
  -- v_new_length = 0 — فلا تُنفَّذ عملية الاستيعاب أصلاً ولا يتغيّر أيّ
  -- عدّادٍ في الدفعة (المطلوب حرفياً: source_rows يبقى كما كان).
  v_new_range := int8multirange(v_incoming_range) - v_batch.received_rows;
  v_new_length := coalesce((select sum(upper(r) - lower(r)) from unnest(v_new_range) as r), 0);

  if v_new_length > 0 then
    -- ---------------------------------------------------------------------
    -- الاستيعاب مجموعياً: تحليلٌ ثم تصنيفٌ ثم سبب رفضٍ (بنفس أولوية الحلقة
    -- القديمة: مشترك ناقص -> موزّع ناقص -> Remaining غير محسوم) ثم إزالة
    -- تكرارٍ داخل الجزء (أوّل ورودٍ يفوز، بلا حساسية حالة الأحرف على
    -- المشترك) ثم إدراجٌ يتجاهل تعارض قيد الهوية الفريد بدل فحصٍ مسبقٍ
    -- لكلّ صفّ — هذا وحده كان يتجاوز 8 ثوانٍ عند 20,000 صفّ.
    --
    -- تراكبٌ جزئيٌّ (بعض الموضع الوارد جديدٌ وبعضه مُعادٌ): المصدر هنا
    -- يُفلتَر أصلاً على المواضع الجديدة فعلياً فقط (WHERE أدناه) — موضعٌ
    -- سبق استقباله لا يُقرأ محتواه إطلاقاً في هذا النداء ولا في أيّ نداءٍ
    -- لاحق، مهما اختلف؛ فلا يمكن لإعادة إرسالٍ (بنفس المحتوى أو بمحتوىً
    -- مختلف) أن تُدخِل أو تُبدِّل بيانات موضعٍ استقبلته الدفعة من قبل.
    -- ---------------------------------------------------------------------
    with source as (
      select ordinality::int as row_no, value as item
      from jsonb_array_elements(p_rows) with ordinality as t(value, ordinality)
      where not (v_batch.received_rows @> (v_row_offset + ordinality - 1))
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

    v_source := v_new_length;
    -- يشمل تكرار الجزء الداخلي (distinct on) وتعارض قيد الهوية معاً — كلاهما
    -- صفوفٌ صالحةٌ لم تُدرَج، بالضبط ما كانت الحلقة القديمة تعدّه تكراراً.
    -- محسوبان الآن حصراً من المواضع الجديدة فعلياً (المصدر مُفلترٌ أعلاه)،
    -- فلا مبالغة في عدّهما عند تراكبٍ جزئي كما كان محدوداً ومقصوداً سابقاً.
    v_duplicate := v_valid_total - v_accepted;
  else
    v_source := 0;
    v_accepted := 0;
    v_duplicate := 0;
    v_rejected := 0;
    v_rejects := '[]'::jsonb;
  end if;

  v_new_source_total := v_batch.source_rows + v_source;
  v_new_accepted_total := v_batch.accepted_rows + v_accepted;

  if p_finalize then
    -- Blocker 2: الإنهاء الصريح يفشل صراحةً إن لم تكتمل الصفوف المصرَّح
    -- بها عند الإنشاء — لا إكمالٌ صامتٌ ولا بقاءٌ معلَّقٌ بلا تفسير. بما أن
    -- source_rows يساوي دوماً عدد مواضع received_rows المتميّزة، وهذه
    -- الأخيرة زُمرةٌ جزئيةٌ من [0, expected_rows) دوماً (الحدّ العلوي مضبوطٌ
    -- أعلاه)، فمساواة العددين هنا تعني تغطيةً كاملةً بلا فجوةٍ فعلياً — لا
    -- حاجة لفحصٍ إضافي.
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
      received_rows = case when v_new_length > 0
                            then v_batch.received_rows + int8multirange(v_incoming_range)
                            else v_batch.received_rows end,
      status = v_status,
      finalized_at = case when p_finalize then now() else finalized_at end,
      finalized_by = case when p_finalize then v_actor else finalized_by end
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'id', v_batch_id, 'batch_id', v_batch_id,
    'period', p_period, 'file_name', v_file_name,
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
    jsonb_build_object('period', p_period, 'file_name', v_file_name),
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$$;

revoke execute on function public.import_installation_entitlements(
  text, text, text, jsonb, uuid, uuid, integer, boolean, bigint) from public, anon;
grant execute on function public.import_installation_entitlements(
  text, text, text, jsonb, uuid, uuid, integer, boolean, bigint) to authenticated;

commit;
