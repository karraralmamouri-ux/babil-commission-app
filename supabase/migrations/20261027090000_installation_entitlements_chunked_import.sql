-- تدقيق QA ما بعد الإطلاق (2026-09-01) — الملف الحقيقي
-- Activations Report_Aug-2026.xlsx فيه 29,427 صفاً؛ الاستيراد يفشل بـ
-- «Rows must contain between 1 and 20000 entries» — نصّ الخطأ وحدّه 20000
-- موجودان حرفياً في import_installation_entitlements وحدها دون سواها
-- (بُحث عبر كل الهجرات وكل الواجهة قبل هذا القرار).
--
-- الإصلاح: p_batch_id اختياري جديد يحوّل الحدّ من سقفٍ صلبٍ للملف إلى حجم
-- دفعةٍ داخلية. أوّل نداء (بلا p_batch_id) يبقى كما كان تماماً: يتحقّق من
-- بصمة الملف مقابل استيرادٍ سابق، وينشئ صفّ الدفعة. نداءٌ لاحقٌ بنفس
-- p_batch_id يُلحِق صفوفه بالدفعة القائمة بدل إنشاء دفعةٍ جديدة، وبصمة
-- الملف تُقارَن بما هو مسجَّل لا تُعاد فحصه تكراراً — فملفٌّ واحدٌ يبقى دفعةً
-- واحدة، مهما بلغ عدد أجزائه. طلب كلّ جزءٍ (request_id) منفصل، فإعادة جزءٍ
-- فشل بمعزلٍ عن غيره آمنة كسابقتها تماماً — لا شيء في حماية إعادة الطلب
-- تغيّر. والتكرار عبر حدود الأجزاء يُكتشَف بنفس فحص
-- (period, subscriber_id, stage) الحاليّ، لأن كل جزءٍ يُثبَّت في معاملته
-- الخاصة قبل الجزء الذي يليه.
--
-- الحدّ 20000 نفسه لم يتغيّر — صار حجم الدفعة الداخلية، لا سقف الملف.

begin;

-- إضافة معامل بقيمةٍ افتراضية عبر create or replace لا تستبدل التوقيع القديم؛
-- تُنشئ حِملاً زائداً (overload) موازياً، فيصبح نداءٌ بخمسة معطياتٍ غامضاً بين
-- الاثنين. لا بدّ من إسقاط التوقيع القديم صراحةً أولاً.
drop function if exists public.import_installation_entitlements(text, text, text, jsonb, uuid);

create or replace function public.import_installation_entitlements(
  p_period text,
  p_file_name text,
  p_file_checksum text,
  p_rows jsonb,
  p_request_id uuid,
  p_batch_id uuid default null
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
  v_item jsonb;
  v_subscriber text;
  v_reseller text;
  v_fdt text;
  v_zone text;
  v_remaining bigint;
  v_stage text;
  v_amount bigint;
  v_key text;
  v_seen text[] := array[]::text[];
  v_source integer := 0;
  v_accepted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_status text;
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
    insert into public.installation_batches (period, file_name, file_checksum, created_by)
    values (p_period, coalesce(btrim(p_file_name), ''), nullif(btrim(coalesce(p_file_checksum, '')), ''), v_actor)
    returning * into v_batch;
    v_batch_id := v_batch.id;
  else
    select * into v_batch from public.installation_batches where id = p_batch_id for update;
    if not found then
      raise exception 'batch_id does not refer to an existing import batch' using errcode = '22023';
    end if;
    if v_batch.period <> p_period then
      raise exception 'batch_id belongs to a different period' using errcode = '22023';
    end if;
    if v_batch.file_checksum is distinct from nullif(btrim(coalesce(p_file_checksum, '')), '') then
      raise exception 'batch_id does not match the checksum of this file' using errcode = '22023';
    end if;
    v_batch_id := v_batch.id;
  end if;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_source := v_source + 1;
    v_subscriber := btrim(coalesce(v_item ->> 'subscriber_id', ''));
    v_reseller := btrim(coalesce(v_item ->> 'reseller', ''));
    v_fdt := nullif(btrim(coalesce(v_item ->> 'fdt', '')), '');
    v_zone := case when public.fdt_commission_scope(v_fdt) = 'FDT' then 'new' else 'old' end;

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

    -- Remaining must be an exact integer; anything else has no stage.
    begin
      v_remaining := (v_item ->> 'remaining')::bigint;
    exception when others then
      v_remaining := null;
    end;
    v_stage := case when v_remaining is null then null
                    else public.installation_stage_for_remaining(v_remaining) end;
    if v_stage is null then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'unknown_remaining');
      continue;
    end if;
    v_amount := public.installation_amount_for_stage(v_stage);

    v_key := lower(v_subscriber) || chr(31) || v_stage;
    if v_key = any(v_seen) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;
    v_seen := array_append(v_seen, v_key);

    -- يلتقط تكراراً من دفعةٍ سابقة أو من جزءٍ سابقٍ من الدفعة نفسها — كلاهما مُثبَّتٌ فعلاً.
    if exists (
      select 1 from public.installation_entitlements
      where period = p_period and subscriber_id = v_subscriber and stage = v_stage
    ) then
      v_duplicate := v_duplicate + 1;
      continue;
    end if;

    insert into public.installation_entitlements (
      batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
      remaining, stage, amount, payment_status, created_by
    ) values (
      v_batch_id, p_period, v_subscriber,
      btrim(coalesce(v_item ->> 'subscriber_name', '')), v_reseller, v_zone, v_fdt,
      v_remaining, v_stage, v_amount,
      case when v_stage = 'DONE' then 'not_eligible' else 'awaiting_invoice' end,
      v_actor
    );
    v_accepted := v_accepted + 1;
  end loop;

  v_status := case when v_batch.accepted_rows + v_accepted = 0 then 'no_new_rows' else 'completed' end;
  update public.installation_batches
  set source_rows = v_batch.source_rows + v_source,
      accepted_rows = v_batch.accepted_rows + v_accepted,
      duplicate_rows = v_batch.duplicate_rows + v_duplicate,
      rejected_rows = v_batch.rejected_rows + v_rejected,
      status = v_status
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'id', v_batch_id, 'batch_id', v_batch_id,
    'period', p_period, 'file_name', coalesce(btrim(p_file_name), ''),
    'source_rows', v_source, 'accepted', v_accepted,
    'duplicates', v_duplicate, 'rejected', v_rejected, 'status', v_status,
    -- إجماليّ الدفعة كلها حتى الآن، لا هذا الجزء وحده — الواجهة تعرضه بعد آخر جزء.
    'batch_totals', jsonb_build_object(
      'source_rows', v_batch.source_rows + v_source,
      'accepted', v_batch.accepted_rows + v_accepted,
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
  text, text, text, jsonb, uuid, uuid) from public, anon;
grant execute on function public.import_installation_entitlements(
  text, text, text, jsonb, uuid, uuid) to authenticated;

commit;
