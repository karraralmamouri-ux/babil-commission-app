-- تدقيق QA ما بعد الإطلاق (2026-09-02) — الملف الحقيقي مرّةً أخرى:
-- Activations Report_Aug-2026.xlsx، 29,427 حدث تفعيل. المعاينة في المتصفّح
-- تقبلها كلها (مكرّر 0، مرفوض 0)، ثم «اعتمد الاستيراد» يعود بـ
-- «canceling statement due to statement timeout»، ولا يبقى صفٌّ واحد في
-- saas_import_batches — المعاملة كلها تُلغى، فلا أثر يُستأنف منه.
--
-- المهلة الفعلية للنداء المُصادَق عليه ثماني ثوانٍ. ولا تُرفع: القاعدة
-- المعتمدة في هذا المستودع أن يُزال العمل المتكرّر لكل صفّ، لا أن يُخبَّأ
-- خلف مهلةٍ أطول.
--
-- ---------------------------------------------------------------------
-- ما قِيس فعلياً قبل أيّ تغيير (Postgres 16، حاوية محلية، 30,000 صفّاً):
--
--   الحلقة الحالية صفّاً صفّاً ................... 5.21 ثانية
--   نفس الاستيعاب مجموعياً (CTE) ................ 2.98 ثانية
--   منه عند 10,000 صفّ .......................... 0.89 ثانية
--   منه عند  5,000 صفّ .......................... 0.45 ثانية
--
-- سبب الحلقة القديمة ليس الإدراج نفسه بل ما يغلّفه: كل دورةٍ فيها
-- begin ... exception when unique_violation ... end، وكتلة الاستثناء في
-- PL/pgSQL معاملةٌ فرعية (savepoint) كاملة. 29,427 معاملةً فرعيةً هي
-- الكلفة، لا 29,427 إدراجاً. الاستيعاب المجموعي يُلغيها تماماً.
--
-- لكنّه يُلغيها إلى 2.98 ثانية فقط — أي 1.75× لا 10×. والجهاز الذي فشل
-- عليه الاستيراد فعلياً أبطأ من هذه الحاوية بمعامل 1.55 على الأقل (5.21
-- ثانية هنا مقابل تجاوزٍ لثماني ثوانٍ هناك). 2.98 × 1.55 = 4.6 ثانية من
-- أصل 8: هامشٌ لا يُبنى عليه. والحدّ المُعلَن للنداء الواحد 100,000 صفّ،
-- وهو وحده ~10 ثوانٍ محلياً مهما بلغ تحسين الاستيعاب.
--
-- فالقرار: الاثنان معاً — استيعابٌ مجموعيٌّ داخل استيرادٍ منطقيٍّ مُجزّأ،
-- بنفس تصميم import_installation_entitlements المُثبَت في 20261027090000
-- و20261101090000 و20261102090000. جزءٌ من 5,000 صفّ يُقاس 0.45 ثانية
-- محلياً — هامشٌ يحتمل جهازاً أبطأ بعشرة أضعاف.
--
-- ---------------------------------------------------------------------
-- والعائق الثاني على الطريق نفسه، ظهر بالقياس لا بالقراءة:
--
--   bridge_saas_activations_to_enrollments، كل المرشّحين ممنوعون:
--     p_limit =  500 ....... 0.35 ثانية
--     p_limit = 1000 ....... 0.94 ثانية
--     p_limit = 2000 ....... 2.97 ثانية
--     p_limit = 3000 ....... 6.20 ثانية
--     p_limit = 5000 ...... 16.69 ثانية   ← ما ترسله الواجهة فعلاً
--
-- عشرة أضعاف المرشّحين، سبعةٌ وأربعون ضعف الزمن: تربيعيّ. والسبب سطرٌ
-- واحد في 20261103090000: v_blocked := v_blocked || jsonb_build_object(...)
-- داخل الحلقة. إلحاق عنصرٍ بمصفوفة jsonb يَنسخ المصفوفة كاملةً في كل مرّة،
-- فخمسة آلاف إلحاقٍ تنسخ ما مجموعه مئات الميغابايتات. والواجهة تستدعي
-- الجسر بـ p_limit = 5000 مباشرةً بعد كل استيراد — أي أن النداء الثاني
-- على المسار نفسه لا يمكنه أن ينتهي تحت ثماني ثوانٍ أصلاً.
--
-- والعائق الثالث في الجسر نفسه، وهو الأخطر لأنه صامت: المسح يأخذ أوّل
-- p_limit مرشّحاً غير مسجَّلٍ فقط. والممنوع يبقى غير مسجَّلٍ إلى الأبد، فهو
-- يشغل موضعه في النافذة إلى الأبد — دفعةٌ أوّل خمسة آلاف مرشّحٍ فيها
-- ممنوعون لا تصل إلى المرشّح 5001 أبداً، مهما أُعيد تشغيل الجسر. ملفٌّ فيه
-- 29,427 حدثاً قد يحمل عشرين ألف اسمٍ فريد؛ مسحةٌ واحدةٌ لا تكفيه، وتكرار
-- المسحة نفسها لا يُقدّم شيئاً.
--
-- ---------------------------------------------------------------------
-- ما لا يتغيّر في هذه الهجرة:
--
--   · إزالة التكرار تبقى على مستوى الحدث (saas_event_id) وحده — القرار
--     D-02. لا إزالة تكرارٍ بالمشترك أبداً: أحداث تفعيلٍ متعدّدة لنفس
--     الاسم صحيحةٌ ومقصودة.
--   · هوية الملف تبقى (source_checksum, source_kind) — قيدٌ فريدٌ قائم،
--     فملفٌّ واحدٌ لا يُنتج دفعتين منطقيّتين مهما بلغ عدد أجزائه.
--   · إعادة الطلب تبقى (actor_id, request_id) في audit_logs.
--   · البوابة تبقى evaluate_enrollment_gate كما هي حرفياً — لا قاعدة عملٍ
--     واحدة في التسجيل تتغيّر هنا. ما يتغيّر هو كيف يُمسح المرشّحون، لا
--     مَن يُجاز منهم.
--   · لا مالَ يُكتب: الاستيراد الخام يبقى كتابةً للتاريخ الخام وحده.
--
-- 20261003090000 و20261103090000 لا يُعدَّلان. هذه هجرةٌ أماميةٌ مضافة.

begin;

-- ---------------------------------------------------------------------------
-- ١ · هوية الاستقبال للدفعة: أيّ مواضع من صفوف الملف المصدر استقبلتها هذه
--    الدفعة فعلاً، وكم صفّاً يُنتظر منها إجمالاً.
--
-- received_rows اتحاد مجالاتٍ لا عدّاد: إعادة إرسال نفس المدى لا تزيده،
-- فإعادة التشغيل من الصفر بمعرّف طلبٍ جديد لا تُضخّم شيئاً. وهو نفس
-- العمود ونفس المعنى المعتمدَين في installation_batches (20261101090000)،
-- لأن المشكلة واحدة والحلّ المُثبَت واحد.
-- ---------------------------------------------------------------------------

alter table public.saas_import_batches
  add column if not exists received_rows int8multirange not null default '{}'::int8multirange;

alter table public.saas_import_batches
  add column if not exists expected_row_count integer;

comment on column public.saas_import_batches.received_rows is
  'مدى مواضع صفوف الملف المصدر (0-based، نصف مفتوح) التي استقبلتها هذه الدفعة فعلياً — اتحاد مجالاتٍ لا عدّاداً. أساس أمان إعادة التشغيل للاستيراد المُجزّأ (20261104090000).';

comment on column public.saas_import_batches.expected_row_count is
  'عدد صفوف الملف المصدر كما أعلنه الرافع عند فتح دفعةٍ للإلحاق. الإنهاء مرفوضٌ ما لم يُستقبَل هذا العدد كاملاً — فلا تُقفَل دفعةٌ منقوصةٌ على أنها مكتملة (20261104090000).';

-- ---------------------------------------------------------------------------
-- ٢ · فحص القابلية للتحويل بلا استثناء.
--
-- الحلقة القديمة كانت تعرف الصفّ المشوّه بأن ترميه في INSERT ثم تلتقط
-- when others — وهذا هو مصدر المعاملة الفرعية لكل صفّ، أي أصل المشكلة
-- كلها. pg_input_is_valid (Postgres 16) يسأل دالة الإدخال نفسها التي
-- كان التحويل سيستدعيها، فيعطي نفس الجواب بالضبط بلا savepoint.
--
-- الأعمدة المفحوصة هنا هي كل الأعمدة المُحوَّلة في INSERT دون سواها؛ بقيّة
-- الحقول نصوصٌ تمرّ عبر nullif فلا تفشل أبداً. وقيمةٌ غائبة (null) تُدرَج
-- null كما كانت تماماً، فلا تُعدّ تشويهاً — بينما نصٌّ فارغٌ '' يبقى
-- تحويلاً فاشلاً كما كان حرفياً، لأن ''::timestamptz خطأ.
--
-- immutable ودالةٌ تعبيريةٌ واحدة، فيُدمجها المخطِّط في الاستعلام نفسه.
-- ---------------------------------------------------------------------------

create or replace function public.saas_activation_row_is_castable(p_item jsonb)
returns boolean
language sql
immutable
parallel safe
as $fn$
  select
        (case when (p_item ->> 'event_created_at') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'event_created_at', 'timestamptz') end)
    and (case when (p_item ->> 'old_expiration') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'old_expiration', 'timestamptz') end)
    and (case when (p_item ->> 'new_expiration') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'new_expiration', 'timestamptz') end)
    and (case when (p_item ->> 'activations_count') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'activations_count', 'integer') end)
    and (case when (p_item ->> 'source_row') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'source_row', 'integer') end)
    and (case when (p_item ->> 'canceled') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'canceled', 'boolean') end)
    and (case when (p_item ->> 'price') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'price', 'numeric') end)
    and (case when (p_item ->> 'user_price') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'user_price', 'numeric') end)
    and (case when (p_item ->> 'total_price') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'total_price', 'numeric') end)
    and (case when (p_item ->> 'tax_amount') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'tax_amount', 'numeric') end)
    and (case when (p_item ->> 'tax_rate') is null then true
              else pg_catalog.pg_input_is_valid(p_item ->> 'tax_rate', 'numeric') end)
$fn$;

comment on function public.saas_activation_row_is_castable(jsonb) is
  'هل تُحوَّل كل حقول صفّ التفعيل المُحوَّلة بلا خطأ؟ نفس جواب التحويل الفعلي، بلا معاملةٍ فرعيةٍ لكل صفّ (20261104090000).';

-- بلا set search_path عمداً، وهذا هو بيت القصيد: دالة SQL تحمل شرط SET لا
-- يدمجها المخطِّط أبداً، فتصير نداءً حقيقياً لكل صفّ — أي بالضبط الكلفة
-- المتكرّرة التي جاءت هذه الهجرة لإزالتها. وكل ما بداخلها مؤهَّل بـpg_catalog
-- ولا يقرأ جدولاً ولا يكتب شيئاً، ومستدعيها الوحيد
-- import_saas_activation_events يعمل أصلاً بـsearch_path فارغ. ولا تُمنح
-- لأحد: لا يبلغها إلا مالكُ الدالة الآمرة.
revoke execute on function public.saas_activation_row_is_castable(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- ٣ · الكاتب: نفس الدلالات، بلا معاملةٍ فرعيةٍ لكلّ صفّ، وبأجزاءٍ ضمن
--    دفعةٍ منطقيةٍ واحدة.
--
-- إضافة معاملاتٍ بقيمٍ افتراضية عبر create or replace لا تستبدل التوقيع
-- القديم بل تُنشئ حِملاً زائداً موازياً، فيصير نداءٌ بسبعة معطياتٍ غامضاً
-- بين الاثنين. لا بدّ من إسقاط التوقيع القديم صراحةً أولاً.
-- ---------------------------------------------------------------------------

drop function if exists public.import_saas_activation_events(
  text, text, text, jsonb, uuid, date, date);

create or replace function public.import_saas_activation_events(
  p_file_name text,
  p_file_checksum text,
  p_parser_version text,
  p_rows jsonb,
  p_request_id uuid,
  p_declared_coverage_start date default null,
  p_declared_coverage_end date default null,
  p_batch_id uuid default null,
  p_expected_rows integer default null,
  p_finalize boolean default true,
  p_row_offset bigint default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_batch public.saas_import_batches%rowtype;
  v_batch_id uuid;
  v_checksum text := nullif(pg_catalog.btrim(coalesce(p_file_checksum, '')), '');
  -- ملفٌّ من ثلاثين ألف صفٍّ يصل كقيمة jsonb مضغوطةٍ خارج الصفّ (TOAST)،
  -- وكلُّ قراءةٍ لطولها تفكُّ ضغطها من جديد. تُقرأ مرّةً واحدةً هنا.
  v_row_count integer;
  v_file_name text := coalesce(pg_catalog.btrim(p_file_name), '');
  v_source integer := 0;
  v_inserted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_valid_total integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_rejects_total integer := 0;
  v_min timestamptz;
  v_max timestamptz;
  v_status text;
  v_action text;
  v_row_offset bigint;
  v_incoming_range int8range;
  v_new_range int8multirange;
  v_new_length bigint;
  v_new_source_total integer;
  v_new_accepted_total integer;
  v_new_duplicate_total integer;
  v_new_rejected_total integer;
  v_result jsonb;
begin
  perform public.require_capability('saas.import');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if v_checksum is null then
    raise exception 'file_checksum is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array' using errcode = '22023';
  end if;
  v_row_count := jsonb_array_length(p_rows);
  if v_row_count = 0 or v_row_count > 100000 then
    raise exception 'Rows must contain between 1 and 100000 entries' using errcode = '22023';
  end if;

  -- إعادة نفس الطلب تُعيد نتيجته الأصلية، لا تستورد مرّتين. والجزء غير
  -- النهائي فعلٌ مستقلٌّ بمعرّف طلبٍ خاصٍّ به، فكلا الفعلين مقبولٌ هنا؛ ما
  -- عداهما معرّف طلبٍ استُعمل لعمليةٍ أخرى وهذا خطأٌ صريح.
  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action not in (
      'saas.activation_events.imported', 'saas.activation_events.chunk_received') then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('batch', v_existing.after_data, 'replayed', true);
  end if;

  -- قفلٌ واحدٌ لكلّ استيراد أحداث تفعيل: لا رفعان يتداخلان، ولا جزءان من
  -- نفس الملف يتسابقان على نفس صفّ الدفعة.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('saas-activation-events-import', 0)
  );

  -- -------------------------------------------------------------------
  -- الدفعة المنطقية للملف. القيد الفريد (source_checksum, source_kind)
  -- هو هوية الملف نفسها، فملفٌّ واحدٌ لا يملك إلا دفعةً واحدة مهما بلغ
  -- عدد أجزائه — وهذا يُبقي الالتزام «ملفٌّ واحد = دفعةٌ منطقيةٌ واحدة»
  -- محروساً بالمخطط لا بحُسن نيّة المستدعي.
  -- -------------------------------------------------------------------
  if p_batch_id is not null then
    select * into v_batch from public.saas_import_batches where id = p_batch_id for update;
    if not found then
      raise exception 'batch_id does not refer to an existing import batch' using errcode = '22023';
    end if;
    if v_batch.source_kind <> 'ACTIVATION_EVENTS' then
      raise exception 'batch_id does not belong to an activation events import' using errcode = '22023';
    end if;
    if v_batch.imported_by <> v_actor then
      raise exception 'batch_id belongs to a different importer' using errcode = '42501';
    end if;
    if v_batch.status <> 'draft' then
      raise exception 'batch_id is no longer open for further chunks (status %)', v_batch.status
        using errcode = '22023';
    end if;
    if v_batch.source_checksum is distinct from v_checksum then
      raise exception 'batch_id does not match the checksum of this file' using errcode = '22023';
    end if;
    if v_batch.source_filename <> v_file_name then
      raise exception 'batch_id does not match the file name of this upload' using errcode = '22023';
    end if;
    if v_batch.expected_row_count is not null
       and (p_expected_rows is null or p_expected_rows <> v_batch.expected_row_count) then
      raise exception 'batch_id does not match the expected row count of this file' using errcode = '22023';
    end if;
    v_batch_id := v_batch.id;
  else
    select * into v_batch from public.saas_import_batches
    where source_checksum = v_checksum and source_kind = 'ACTIVATION_EVENTS'
    for update;

    if found then
      -- دفعةٌ مُنهاةٌ لنفس الملف حرفياً: تُرفض كما كانت تُرفض قبل هذه
      -- الهجرة تماماً، بنفس رمز الخطأ ونفس النصّ. لا استيراد مرّتين.
      if v_batch.status <> 'draft' then
        raise exception 'This exact file was already imported as batch %', v_batch.id
          using errcode = '23505';
      end if;
      -- دفعةٌ مفتوحةٌ لنفس الملف: تُستأنَف. هذا بالضبط ما يجعل إعادة تحميل
      -- الصفحة أثناء رفعٍ طويلٍ آمنة — الرفع يبدأ من الصفر، والخادم يعرف
      -- أيّ مواضع استقبلها فعلاً فلا يُعيد عدّها ولا يُعيد قراءتها.
      if v_batch.imported_by <> v_actor then
        raise exception 'This file is already being imported by another importer (batch %)', v_batch.id
          using errcode = '42501';
      end if;
      if v_batch.source_filename <> v_file_name then
        raise exception 'An open batch for this checksum was uploaded under a different file name (batch %)',
          v_batch.id using errcode = '22023';
      end if;
      if v_batch.expected_row_count is distinct from p_expected_rows then
        raise exception 'An open batch for this file declares a different expected row count (batch %)',
          v_batch.id using errcode = '22023';
      end if;
      v_batch_id := v_batch.id;
    else
      -- فتح دفعةٍ يُنتظر لها أجزاءٌ لاحقة بلا عددٍ مُعلَنٍ موجَب مرفوضٌ عند
      -- حدود الخادم: بغيره لا يعرف الإنهاء متى تكتمل، فتُقفَل منقوصةً أو
      -- تبقى مفتوحةً بلا تفسير. نداءٌ نهائيٌّ منذ إنشائه يكتمل ذرّياً في
      -- معاملته فلا شيء يُستأنَف، ولا حاجة تفرضه.
      if not p_finalize and (p_expected_rows is null or p_expected_rows <= 0) then
        raise exception
          'expected_rows is required and must be a positive integer when a batch is left open for continuation (p_finalize=false)'
          using errcode = '22023';
      end if;
      insert into public.saas_import_batches (
        source_kind, source_filename, source_checksum, parser_version,
        declared_coverage_start, declared_coverage_end,
        source_row_count, expected_row_count, imported_by, status
      ) values (
        'ACTIVATION_EVENTS', v_file_name, v_checksum,
        coalesce(nullif(pg_catalog.btrim(p_parser_version), ''), 'unknown'),
        p_declared_coverage_start, p_declared_coverage_end,
        0, p_expected_rows, v_actor, 'draft'
      ) returning * into v_batch;
      v_batch_id := v_batch.id;
    end if;
  end if;

  -- -------------------------------------------------------------------
  -- موضع هذا الجزء داخل الملف. مُعلَنٌ صراحةً من عميلٍ يعرف موضعه الحقيقي،
  -- أو مُشتقٌّ ضمنياً كـ«حيث توقّفت هذه الدفعة» لأيّ مستدعٍ لا يُعلنه —
  -- وهذا يُعيد بالضبط سلوك النداء الواحد القديم لكلّ مستدعٍ لا يعرف عن
  -- التجزئة شيئاً: دفعةٌ جديدةٌ source_row_count = 0، فالموضع 0 والمدى
  -- [0, n) كما لو لم تكن هناك تجزئة أصلاً.
  -- -------------------------------------------------------------------
  v_row_offset := coalesce(p_row_offset, v_batch.source_row_count);
  if v_row_offset < 0 then
    raise exception 'row_offset must not be negative' using errcode = '22023';
  end if;
  v_incoming_range := int8range(v_row_offset, v_row_offset + v_row_count);
  if v_batch.expected_row_count is not null and upper(v_incoming_range) > v_batch.expected_row_count then
    raise exception 'row_offset and row count exceed the declared expected_rows for this batch'
      using errcode = '22023';
  end if;

  v_new_range := int8multirange(v_incoming_range) - v_batch.received_rows;
  v_new_length := coalesce((select sum(upper(r) - lower(r)) from unnest(v_new_range) as r), 0);

  if v_new_length > 0 then
    -- -----------------------------------------------------------------
    -- الاستيعاب مجموعياً. نفس أولوية الحلقة القديمة حرفياً:
    --   معرّف حدثٍ ناقص  -> MISSING_EVENT_ID
    --   اسم مستخدمٍ ناقص -> MISSING_USERNAME
    --   قيمةٌ لا تُحوَّل   -> MALFORMED_ROW
    -- ثم التكرار: أوّل ورودٍ لمعرّف الحدث يفوز، وما عداه مكرّر — سواءٌ
    -- تكرّر داخل هذا الجزء (distinct on) أو اصطدم بحدثٍ مُثبَّتٍ سلفاً
    -- (on conflict do nothing). كلاهما «صفٌّ صالحٌ لم يُدرَج»، وهو بالضبط
    -- ما كانت unique_violation تعدّه مكرّراً.
    --
    -- الحلقة القديمة كانت تكتشف القيمة التي لا تُحوَّل برميها داخل
    -- INSERT ثم التقاطها في when others — أي معاملةٌ فرعيةٌ لكل صفّ.
    -- pg_input_is_valid (Postgres 16) يفحص نفس دوال الإدخال نفسها بلا
    -- استثناءٍ ولا savepoint، فالتصنيف واحدٌ والكلفة تسقط. والترتيب
    -- محفوظ: التحويل يُفحص قبل الإدراج، تماماً كما كان يُقيَّم داخل
    -- VALUES قبل أن يصل الصفّ إلى الفهرس الفريد — فصفٌّ مشوّهٌ ومكرّرٌ
    -- معاً يبقى MALFORMED_ROW لا مكرّراً، كما كان.
    --
    -- والموضع المُستقبَل سلفاً لا يُقرأ محتواه إطلاقاً (شرط received_rows
    -- في المصدر): إعادة إرسالٍ بمحتوىً مختلفٍ لموضعٍ سبق استقباله لا
    -- تُدخِل شيئاً ولا تُغيّر عدّاداً — نفس الثابت المعتمد في
    -- 20261102090000.
    -- -----------------------------------------------------------------
    with source as (
      select (v_row_offset + ordinality)::bigint as row_no, value as item
      from jsonb_array_elements(p_rows) with ordinality as t(value, ordinality)
      where not (v_batch.received_rows @> (v_row_offset + ordinality - 1))
    ),
    parsed as (
      select row_no, item,
        pg_catalog.btrim(coalesce(item ->> 'saas_event_id', '')) as event_id,
        pg_catalog.btrim(coalesce(item ->> 'username', '')) as username
      from source
    ),
    classified as (
      select p.row_no, p.item, p.event_id, p.username,
        case
          when p.event_id = '' then 'MISSING_EVENT_ID'
          when p.username = '' then 'MISSING_USERNAME'
          when not public.saas_activation_row_is_castable(p.item) then 'MALFORMED_ROW'
          else null
        end as reject_reason
      from parsed p
    ),
    valid as (
      select c.* from classified c where c.reject_reason is null
    ),
    deduped as (
      select distinct on (v.event_id) v.*
      from valid v order by v.event_id, v.row_no
    ),
    inserted as (
      insert into public.saas_activation_events (
        import_batch_id, saas_event_id, transaction_id, saas_user_id, username,
        event_created_at, profile_name, old_expiration, new_expiration,
        activations_count, raw_parent, canceled, price, user_price, total_price,
        tax_amount, tax_rate, contract_id, card, card_owner, comment, group_name,
        national_id, topology_raw, fdt_code, fat_code, port_code,
        source_sheet, source_row
      )
      select
        v_batch_id, d.event_id,
        nullif(d.item ->> 'transaction_id', ''),
        nullif(d.item ->> 'saas_user_id', ''), d.username,
        (d.item ->> 'event_created_at')::timestamptz,
        nullif(d.item ->> 'profile_name', ''),
        (d.item ->> 'old_expiration')::timestamptz,
        (d.item ->> 'new_expiration')::timestamptz,
        (d.item ->> 'activations_count')::integer,
        nullif(d.item ->> 'raw_parent', ''),
        (d.item ->> 'canceled')::boolean,
        (d.item ->> 'price')::numeric,
        (d.item ->> 'user_price')::numeric,
        (d.item ->> 'total_price')::numeric,
        (d.item ->> 'tax_amount')::numeric,
        (d.item ->> 'tax_rate')::numeric,
        nullif(d.item ->> 'contract_id', ''),
        nullif(d.item ->> 'card', ''),
        nullif(d.item ->> 'card_owner', ''),
        nullif(d.item ->> 'comment', ''),
        nullif(d.item ->> 'group_name', ''),
        nullif(d.item ->> 'national_id', ''),
        nullif(d.item ->> 'topology_raw', ''),
        nullif(d.item ->> 'fdt_code', ''),
        nullif(d.item ->> 'fat_code', ''),
        nullif(d.item ->> 'port_code', ''),
        nullif(d.item ->> 'source_sheet', ''),
        (d.item ->> 'source_row')::integer
      from deduped d
      on conflict (saas_event_id) do nothing
      returning 1
    )
    select
      (select count(*) from classified where reject_reason is not null),
      (select count(*) from valid),
      (select count(*) from inserted),
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'row', row_no, 'reason', reject_reason, 'event_id', event_id)
                 order by row_no)
        from (select row_no, reject_reason, event_id from classified
              where reject_reason is not null order by row_no limit 200) capped
      ), '[]'::jsonb)
    into v_rejected, v_valid_total, v_inserted, v_rejects;

    v_source := v_new_length::integer;
    v_duplicate := v_valid_total - v_inserted;
    v_rejects_total := v_rejected;
  end if;

  v_new_source_total := v_batch.source_row_count + v_source;
  v_new_accepted_total := v_batch.imported_row_count + v_inserted;
  v_new_duplicate_total := v_batch.duplicate_count + v_duplicate;
  v_new_rejected_total := v_batch.error_count + v_rejected;

  if p_finalize then
    -- الإنهاء الصريح يفشل صراحةً إن لم تكتمل الصفوف المصرَّح بها. و
    -- source_row_count يساوي بالبناء عدد المواضع في received_rows، و
    -- received_rows جزءٌ من [0, expected_row_count)، فبلوغ المساواة لا
    -- يكون إلا بتغطيةٍ متّصلةٍ بلا فجوات: دفعةٌ ناقصةٌ في وسطها لا تُقفَل.
    if v_batch.expected_row_count is not null
       and v_new_source_total <> v_batch.expected_row_count then
      raise exception
        'finalization requested before all rows were received (% of % rows)',
        v_new_source_total, v_batch.expected_row_count
        using errcode = '22023';
    end if;
    v_status := 'imported';
    v_action := 'saas.activation_events.imported';
  else
    v_status := 'draft';
    v_action := 'saas.activation_events.chunk_received';
  end if;

  select min(event_created_at), max(event_created_at) into v_min, v_max
  from public.saas_activation_events where import_batch_id = v_batch_id;

  update public.saas_import_batches
  set source_row_count = v_new_source_total,
      imported_row_count = v_new_accepted_total,
      duplicate_count = v_new_duplicate_total,
      error_count = v_new_rejected_total,
      received_rows = case when v_new_length > 0
                           then v_batch.received_rows + int8multirange(v_incoming_range)
                           else v_batch.received_rows end,
      observed_min_created_at = v_min,
      observed_max_created_at = v_max,
      status = v_status
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'batch_id', v_batch_id, 'source_kind', 'ACTIVATION_EVENTS',
    -- هذا النداء وحده — نداءٌ واحدٌ غير مُجزّأ يجعلها مطابقةً للإجمالي.
    'source_rows', v_source, 'accepted', v_inserted,
    'duplicates', v_duplicate, 'rejected', v_rejected,
    'rejects', v_rejects,
    'rejects_truncated', v_rejects_total > 200,
    'observed_min_created_at', v_min, 'observed_max_created_at', v_max,
    'status', v_status, 'finalized', p_finalize,
    'expected_rows', v_batch.expected_row_count,
    -- الدفعة المنطقية كلها عبر كل أجزائها: هذا ما يُعرض للمشغّل، وهذا ما
    -- يُقرأ منه أن الملف استُوعب كاملاً.
    'batch_totals', jsonb_build_object(
      'source_rows', v_new_source_total,
      'accepted', v_new_accepted_total,
      'duplicates', v_new_duplicate_total,
      'rejected', v_new_rejected_total)
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, after_data, request_id
  ) values (
    v_actor, v_action, 'saas_import_batch', v_batch_id,
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$fn$;

comment on function public.import_saas_activation_events(
  text, text, text, jsonb, uuid, date, date, uuid, integer, boolean, bigint) is
  'يستوعب أحداث التفعيل الخام مجموعياً وبأجزاءٍ ضمن دفعةٍ منطقيةٍ واحدةٍ لكلّ ملف. إزالة التكرار بمعرّف الحدث وحده، وإعادة الطلب والاستئناف آمنان (20261104090000).';

revoke execute on function public.import_saas_activation_events(
  text, text, text, jsonb, uuid, date, date, uuid, integer, boolean, bigint) from public, anon;
grant execute on function public.import_saas_activation_events(
  text, text, text, jsonb, uuid, date, date, uuid, integer, boolean, bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- ٤ · الجسر: نفس البوابة، بلا كلفةٍ تربيعية، ويتقدّم فعلاً.
--
-- لا قاعدة عملٍ واحدة تتغيّر هنا. evaluate_enrollment_gate تبقى الحَكَم
-- الوحيد بحرفها، وenroll_new_installation تبقى الطريق الوحيد للتسجيل، ومَن
-- منعته البوابة يبقى ممنوعاً. ما يتغيّر ثلاثة أشياء في كيفية المسح وحدها:
--
-- (أ) الكلفة التربيعية. v_blocked := v_blocked || ... داخل الحلقة كان
--     ينسخ المصفوفة كاملةً في كل إلحاق. صار العدّ عدّاداً، والأسباب
--     تُجمَّع في كائنٍ صغيرٍ ثابت الحجم (عدد أنواع المنع لا عدد الممنوعين)،
--     وblocked_rows عيّنةٌ محدودةٌ بخمسين صفّاً. المشغّل يحتاج «١٤٠ بلا
--     تصنيف» لا مئةً وأربعين سطراً متطابقاً، والعدد الكامل يبقى في
--     reasons وblocked مضبوطاً — العيّنة وحدها محدودة. وهذا يُخرِج أيضاً
--     صفَّ تدقيقٍ بحجم مئات الكيلوبايتات من كل مسحة.
--
-- (ب) التقدّم. المسح كان يأخذ أوّل p_limit مرشّحاً غير مسجَّل. والممنوع
--     لا يُسجَّل فيبقى مرشّحاً إلى الأبد، فيحتلّ موضعه في النافذة إلى
--     الأبد: دفعةٌ أوّل خمسة آلاف مرشّحٍ فيها ممنوعون لا تبلغ المرشّح
--     5001 مهما أُعيد تشغيلها. p_after_username مؤشّرٌ صريح: المسحة
--     التالية تبدأ بعد آخر اسمٍ نظرت فيه المسحة السابقة، فيُغطّى الملف
--     كاملاً بعددٍ محدودٍ من المسحات مهما كثر الممنوعون. والترتيب
--     username_key ترتيبٌ كليٌّ ثابت، فالتغطية حتميّةٌ لا احتمالية.
--
-- (ج) الإبلاغ. last_username_key وexhausted وremaining تجعل الواجهة تعرف
--     متى تتوقّف، بدل أن تفترض أن مسحةً واحدةً كفت.
--
-- وp_limit يبقى محدوداً بـ5000 كما كان — لكن القياس يقول إن 5000 مرشّحٍ
-- في نداءٍ واحدٍ كانت 16.7 ثانية قبل هذا الإصلاح، أي أن النداء الذي
-- ترسله الواجهة فعلياً لم يكن ليكتمل تحت ثماني ثوانٍ أصلاً. الواجهة صارت
-- تمسح بـ500 وتُكرّر.
-- ---------------------------------------------------------------------------

drop function if exists public.bridge_saas_activations_to_enrollments(uuid, integer, uuid);

create or replace function public.bridge_saas_activations_to_enrollments(
  p_batch_id uuid default null,
  p_limit integer default 500,
  p_request_id uuid default null,
  p_after_username text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_cand record;
  v_gate jsonb;
  v_considered integer := 0;
  v_enrolled integer := 0;
  v_blocked_count integer := 0;
  v_sample jsonb := '[]'::jsonb;
  v_reasons jsonb := '{}'::jsonb;
  v_row jsonb;
  v_key text;
  v_last_key text := p_after_username;
  v_remaining integer;
  v_result jsonb;
begin
  perform public.require_capability('installation.enroll');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 5000 then
    raise exception 'limit must be between 1 and 5000' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'installation.enrollment.bulk_bridged' then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;
    return jsonb_build_object('result', v_existing.after_data, 'replayed', true);
  end if;

  for v_cand in
    select distinct on (e.username_key)
           e.username_key, e.saas_event_id
    from public.saas_activation_events e
    where (p_batch_id is null or e.import_batch_id = p_batch_id)
      and coalesce(e.canceled, false) = false
      and (p_after_username is null or e.username_key > p_after_username)
      and not exists (
        select 1 from public.installation_enrollments en
        where en.subscriber_id = e.username_key)
    order by e.username_key, e.event_created_at, e.saas_event_id
    limit p_limit
  loop
    v_considered := v_considered + 1;
    v_last_key := v_cand.username_key;
    v_gate := public.evaluate_enrollment_gate(v_cand.username_key, v_cand.saas_event_id);
    v_row := null;

    if (v_gate ->> 'allowed')::boolean then
      begin
        perform public.enroll_new_installation(
          v_cand.username_key, v_cand.saas_event_id, null,
          public.uuid_from_parts(p_request_id, pg_catalog.md5(v_cand.username_key)::uuid));
        v_enrolled := v_enrolled + 1;
      exception
        when others then
          v_row := jsonb_build_object(
            'username_key', v_cand.username_key,
            'event_id', v_cand.saas_event_id,
            'blockers', jsonb_build_array('ENROLL_FAILED'),
            'detail', sqlerrm);
      end;
    else
      v_row := jsonb_build_object(
        'username_key', v_cand.username_key,
        'event_id', v_cand.saas_event_id,
        'blockers', v_gate -> 'blockers');
    end if;

    if v_row is not null then
      v_blocked_count := v_blocked_count + 1;
      -- الأسباب تُعدّ فوراً: الكائن بحجم أنواع المنع لا بعدد الممنوعين،
      -- فكلفته ثابتةٌ مهما بلغ عددهم.
      for v_key in select jsonb_array_elements_text(v_row -> 'blockers')
      loop
        v_reasons := jsonb_set(v_reasons, array[v_key],
          to_jsonb(coalesce((v_reasons ->> v_key)::integer, 0) + 1));
      end loop;
      -- والعيّنة محدودة، فلا نسخَ مصفوفةٍ متناميةٍ لكل صفّ.
      if jsonb_array_length(v_sample) < 50 then
        v_sample := v_sample || v_row;
      end if;
    end if;
  end loop;

  -- كم مرشّحاً بقي بعد هذا الموضع؟ المشغّل والواجهة يحتاجانه ليعرفا أن
  -- الملف لم يُغطَّ بعد — ولا يُخمَّن من عدد المُسجَّلين.
  select count(distinct e.username_key)::integer into v_remaining
  from public.saas_activation_events e
  where (p_batch_id is null or e.import_batch_id = p_batch_id)
    and coalesce(e.canceled, false) = false
    and (v_last_key is null or e.username_key > v_last_key)
    and not exists (
      select 1 from public.installation_enrollments en
      where en.subscriber_id = e.username_key);

  v_result := jsonb_build_object(
    'batch_id', p_batch_id,
    'considered', v_considered,
    'enrolled', v_enrolled,
    'blocked', v_blocked_count,
    'reasons', v_reasons,
    'blocked_rows', v_sample,
    'blocked_rows_truncated', v_blocked_count > 50,
    'after_username', p_after_username,
    'last_username_key', v_last_key,
    'remaining', v_remaining,
    -- المسحة التي لم تبلغ حدّها نظرت في كل ما بقي بعد مؤشّرها: لا مزيد
    -- بعدها من هذا الموضع.
    'exhausted', v_considered < p_limit
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, after_data, request_id, extra
  ) values (
    v_actor, 'installation.enrollment.bulk_bridged', 'saas_import_batch', p_batch_id,
    v_result, p_request_id,
    'enrolled=' || v_enrolled::text || ' blocked=' || v_blocked_count::text
      || ' remaining=' || coalesce(v_remaining, 0)::text
  );

  return jsonb_build_object('result', v_result, 'replayed', false);
end;
$fn$;

comment on function public.bridge_saas_activations_to_enrollments(uuid, integer, uuid, text) is
  'مسح جماعي: يُسجّل من ملف التفعيل الخام كل مَن أجازته بوابة التسجيل، ويُعيد الممنوعين بأسبابهم. يتقدّم بمؤشّر اسمٍ فيُغطّي الدفعة كاملةً بمسحاتٍ متتابعة، وقابل لإعادة التشغيل.';

revoke execute on function public.bridge_saas_activations_to_enrollments(uuid, integer, uuid, text)
  from public, anon;
grant execute on function public.bridge_saas_activations_to_enrollments(uuid, integer, uuid, text)
  to authenticated;

commit;
