-- ---------------------------------------------------------------------------
-- الدفعة ٣ — استقبال ملفات SaaS: كاتب فعلي لِما كان معاينة متصفّح بلا كاتب.
--
-- assets/js/saas-import.js يحلّل الملف ويطابق الهوية ويعاين التصنيف منذ
-- دفعات سابقة — لكن لا دالة خادم واحدة تكتب سطراً في saas_activation_events
-- أو saas_user_snapshots. المعاينة كانت تنتهي بلا أثر.
--
-- هذه المهاجرة تضيف الكاتب فقط:
--   import_saas_activation_events   يكتب أحداث تفعيل خامّة، بتكرار على
--                                   مستوى الحدث (saas_event_id) لا المشترك —
--                                   القرار D-02 المعتمد سلفاً.
--   import_saas_user_snapshot       يكتب لقطة مستخدمين خامّة واحدة، غير
--                                   قابلة للتعديل كسابقتها.
--
-- كلاهما بنمط import_installation_history نفسه: قدرة saas.import القائمة،
-- request_id إلزامي وإعادة آمنة عبر audit_logs، قفل استشاري لكل نوع مصدر،
-- وفرزٌ يعيده الخادم لا يُستَورد كما ورد من المتصفح.
--
-- ولا تصنيف جِدّة هنا ولا استحقاق ولا مال. classify_newness() تبقى كما هي،
-- بلا استدعاء من هذا المسار.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. أحداث التفعيل.
-- ---------------------------------------------------------------------------

create or replace function public.import_saas_activation_events(
  p_file_name text,
  p_file_checksum text,
  p_parser_version text,
  p_rows jsonb,
  p_request_id uuid,
  p_declared_coverage_start date default null,
  p_declared_coverage_end date default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_dupe_batch uuid;
  v_batch_id uuid;
  v_item jsonb;
  v_source integer := 0;
  v_inserted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_event_id text;
  v_username text;
  v_min timestamptz;
  v_max timestamptz;
  v_result jsonb;
begin
  perform public.require_capability('saas.import');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_file_checksum is null or btrim(p_file_checksum) = '' then
    raise exception 'file_checksum is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 100000 then
    raise exception 'Rows must contain between 1 and 100000 entries' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'saas.activation_events.imported' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('batch', v_existing.after_data, 'replayed', true);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('saas-activation-events-import', 0)
  );

  -- نفس الملف حرفياً مستورَدٌ سلفاً: يُرفض بوضوح، لا يُعاد صامتاً ولا يُكرَّر.
  select id into v_dupe_batch from public.saas_import_batches
  where source_checksum = p_file_checksum and source_kind = 'ACTIVATION_EVENTS';
  if found then
    raise exception 'This exact file was already imported as batch %', v_dupe_batch
      using errcode = '23505';
  end if;

  insert into public.saas_import_batches (
    source_kind, source_filename, source_checksum, parser_version,
    declared_coverage_start, declared_coverage_end,
    source_row_count, imported_by, status
  ) values (
    'ACTIVATION_EVENTS', coalesce(btrim(p_file_name), ''), p_file_checksum,
    coalesce(nullif(btrim(p_parser_version), ''), 'unknown'),
    p_declared_coverage_start, p_declared_coverage_end,
    jsonb_array_length(p_rows), v_actor, 'draft'
  ) returning id into v_batch_id;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_source := v_source + 1;
    v_event_id := btrim(coalesce(v_item ->> 'saas_event_id', ''));
    v_username := btrim(coalesce(v_item ->> 'username', ''));

    if v_event_id = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'MISSING_EVENT_ID');
      continue;
    end if;
    if v_username = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'MISSING_USERNAME');
      continue;
    end if;

    begin
      insert into public.saas_activation_events (
        import_batch_id, saas_event_id, transaction_id, saas_user_id, username,
        event_created_at, profile_name, old_expiration, new_expiration,
        activations_count, raw_parent, canceled, price, user_price, total_price,
        tax_amount, tax_rate, contract_id, card, card_owner, comment, group_name,
        national_id, topology_raw, fdt_code, fat_code, port_code,
        source_sheet, source_row
      ) values (
        v_batch_id, v_event_id, nullif(v_item ->> 'transaction_id', ''),
        nullif(v_item ->> 'saas_user_id', ''), v_username,
        (v_item ->> 'event_created_at')::timestamptz,
        nullif(v_item ->> 'profile_name', ''),
        (v_item ->> 'old_expiration')::timestamptz,
        (v_item ->> 'new_expiration')::timestamptz,
        (v_item ->> 'activations_count')::integer,
        nullif(v_item ->> 'raw_parent', ''),
        (v_item ->> 'canceled')::boolean,
        (v_item ->> 'price')::numeric,
        (v_item ->> 'user_price')::numeric,
        (v_item ->> 'total_price')::numeric,
        (v_item ->> 'tax_amount')::numeric,
        (v_item ->> 'tax_rate')::numeric,
        nullif(v_item ->> 'contract_id', ''),
        nullif(v_item ->> 'card', ''),
        nullif(v_item ->> 'card_owner', ''),
        nullif(v_item ->> 'comment', ''),
        nullif(v_item ->> 'group_name', ''),
        nullif(v_item ->> 'national_id', ''),
        nullif(v_item ->> 'topology_raw', ''),
        nullif(v_item ->> 'fdt_code', ''),
        nullif(v_item ->> 'fat_code', ''),
        nullif(v_item ->> 'port_code', ''),
        nullif(v_item ->> 'source_sheet', ''),
        (v_item ->> 'source_row')::integer
      );
      v_inserted := v_inserted + 1;
    exception
      -- تكرار على مستوى الحدث فقط — القرار D-02: لا إزالة تكرار بالمشترك أبداً.
      when unique_violation then
        v_duplicate := v_duplicate + 1;
      when others then
        v_rejected := v_rejected + 1;
        v_rejects := v_rejects
          || jsonb_build_object('row', v_source, 'reason', 'MALFORMED_ROW', 'event_id', v_event_id);
    end;
  end loop;

  select min(event_created_at), max(event_created_at) into v_min, v_max
  from public.saas_activation_events where import_batch_id = v_batch_id;

  update public.saas_import_batches
  set imported_row_count = v_inserted,
      duplicate_count = v_duplicate,
      error_count = v_rejected,
      observed_min_created_at = v_min,
      observed_max_created_at = v_max,
      status = 'imported'
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'batch_id', v_batch_id, 'source_kind', 'ACTIVATION_EVENTS',
    'source_rows', v_source, 'accepted', v_inserted,
    'duplicates', v_duplicate, 'rejected', v_rejected, 'rejects', v_rejects,
    'observed_min_created_at', v_min, 'observed_max_created_at', v_max
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, after_data, request_id
  ) values (
    v_actor, 'saas.activation_events.imported', 'saas_import_batch', v_batch_id,
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$fn$;

revoke execute on function public.import_saas_activation_events(
  text, text, text, jsonb, uuid, date, date) from public, anon;
grant execute on function public.import_saas_activation_events(
  text, text, text, jsonb, uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. لقطة المستخدمين.
--
-- snapshot_at لا يُشتقّ من الملف ولا من وقت الاستيراد — يُختار صراحةً، بنفس
-- منطق as_of_date في import_installation_history: لقطة بلا تاريخ مُعلَن
-- تختلط بلقطة الشهر الذي يليه.
-- ---------------------------------------------------------------------------

create or replace function public.import_saas_user_snapshot(
  p_file_name text,
  p_file_checksum text,
  p_parser_version text,
  p_snapshot_at timestamptz,
  p_rows jsonb,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_dupe_batch uuid;
  v_batch_id uuid;
  v_item jsonb;
  v_source integer := 0;
  v_inserted integer := 0;
  v_duplicate integer := 0;
  v_rejected integer := 0;
  v_rejects jsonb := '[]'::jsonb;
  v_user_id text;
  v_username text;
  v_result jsonb;
begin
  perform public.require_capability('saas.import');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_snapshot_at is null then
    raise exception 'snapshot_at is required for a user snapshot' using errcode = '22023';
  end if;
  if p_file_checksum is null or btrim(p_file_checksum) = '' then
    raise exception 'file_checksum is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Rows must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 100000 then
    raise exception 'Rows must contain between 1 and 100000 entries' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'saas.user_snapshot.imported' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('batch', v_existing.after_data, 'replayed', true);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('saas-user-snapshot-import', 0)
  );

  select id into v_dupe_batch from public.saas_import_batches
  where source_checksum = p_file_checksum and source_kind = 'USERS_SNAPSHOT';
  if found then
    raise exception 'This exact file was already imported as batch %', v_dupe_batch
      using errcode = '23505';
  end if;

  insert into public.saas_import_batches (
    source_kind, source_filename, source_checksum, parser_version,
    observed_min_created_at, observed_max_created_at,
    source_row_count, imported_by, status
  ) values (
    'USERS_SNAPSHOT', coalesce(btrim(p_file_name), ''), p_file_checksum,
    coalesce(nullif(btrim(p_parser_version), ''), 'unknown'),
    p_snapshot_at, p_snapshot_at,
    jsonb_array_length(p_rows), v_actor, 'draft'
  ) returning id into v_batch_id;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_source := v_source + 1;
    v_user_id := btrim(coalesce(v_item ->> 'saas_user_id', ''));
    v_username := btrim(coalesce(v_item ->> 'username', ''));

    if v_user_id = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'MISSING_USER_ID');
      continue;
    end if;
    if v_username = '' then
      v_rejected := v_rejected + 1;
      v_rejects := v_rejects || jsonb_build_object('row', v_source, 'reason', 'MISSING_USERNAME');
      continue;
    end if;

    begin
      insert into public.saas_user_snapshots (
        import_batch_id, snapshot_at, saas_user_id, username, enabled, expiration,
        parent_name, profile_name, saas_created_at, last_online, contract_id,
        group_name, company, phone, national_id, topology_raw, fdt_code, fat_code, port_code
      ) values (
        v_batch_id, p_snapshot_at, v_user_id, v_username,
        (v_item ->> 'enabled')::boolean,
        (v_item ->> 'expiration')::timestamptz,
        nullif(v_item ->> 'parent_name', ''),
        nullif(v_item ->> 'profile_name', ''),
        (v_item ->> 'saas_created_at')::timestamptz,
        (v_item ->> 'last_online')::timestamptz,
        nullif(v_item ->> 'contract_id', ''),
        nullif(v_item ->> 'group_name', ''),
        nullif(v_item ->> 'company', ''),
        nullif(v_item ->> 'phone', ''),
        nullif(v_item ->> 'national_id', ''),
        nullif(v_item ->> 'topology_raw', ''),
        nullif(v_item ->> 'fdt_code', ''),
        nullif(v_item ->> 'fat_code', ''),
        nullif(v_item ->> 'port_code', '')
      );
      v_inserted := v_inserted + 1;
    exception
      -- تكرار معرّف المستخدم داخل الدفعة نفسها فقط — عبر الدفعات لقطات متعاقبة صحيحة.
      when unique_violation then
        v_duplicate := v_duplicate + 1;
      when others then
        v_rejected := v_rejected + 1;
        v_rejects := v_rejects
          || jsonb_build_object('row', v_source, 'reason', 'MALFORMED_ROW', 'user_id', v_user_id);
    end;
  end loop;

  update public.saas_import_batches
  set imported_row_count = v_inserted,
      duplicate_count = v_duplicate,
      error_count = v_rejected,
      status = 'imported'
  where id = v_batch_id;

  v_result := jsonb_build_object(
    'batch_id', v_batch_id, 'source_kind', 'USERS_SNAPSHOT',
    'source_rows', v_source, 'accepted', v_inserted,
    'duplicates', v_duplicate, 'rejected', v_rejected, 'rejects', v_rejects,
    'snapshot_at', p_snapshot_at
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, after_data, request_id
  ) values (
    v_actor, 'saas.user_snapshot.imported', 'saas_import_batch', v_batch_id,
    v_result, p_request_id
  );

  return jsonb_build_object('batch', v_result, 'replayed', false);
end;
$fn$;

revoke execute on function public.import_saas_user_snapshot(
  text, text, text, timestamptz, jsonb, uuid) from public, anon;
grant execute on function public.import_saas_user_snapshot(
  text, text, text, timestamptz, jsonb, uuid) to authenticated;

commit;
