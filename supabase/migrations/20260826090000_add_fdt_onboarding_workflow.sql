-- إدخال الكابينات الجديدة إلى البيانات الرئيسية — عملية إدارية لا تطويرية.
--
-- الكابينة الجديدة تظهر في بيانات SaaS مع الوقت. هذا وضع تشغيلي متوقَّع، لا
-- عطل في المنتج. والمطلوب أن يُسجّلها مسؤولٌ مخوَّل من الواجهة، ثم يُعاد حساب
-- ما تأثّر — بلا تدخّل مبرمج.
--
-- ما يبقى ثابتاً: الكابينة غير المسجَّلة لا تصير «منطقة قديمة» بصمت. تُحجَب
-- سجلاتها المالية وحدها، ويبقى كل ما عداها عاملاً.
--
-- الحدود المرسومة عمداً:
--   • لا تُشتق المنطقة من رقم الكابينة. الأرقام ليست دليلاً؛ النطاق 94–117
--     جاء من تهيئة استيراد قديمة لا من سجلّ شبكة.
--   • لا يُكتب فوق تصنيف قائم بصمت: التغيير يستلزم إقراراً صريحاً.
--   • لا يُحسَم استثناء قبل نجاح إعادة الحساب.
--
-- forward-only. لا صف مالي يُمَس، ولا دفعة تُنشأ.

begin;

-- ---------------------------------------------------------------------------
-- 1. اكتشاف الكابينات غير المسجَّلة، بأدلّتها ومالها المحجوب.
--
-- الغرض أن يرى المسؤول ما يقرّر عليه: كم حدثاً، وكم مشتركاً، وأي وكلاء
-- لوحظوا، وكم مالاً معلَّقاً — قبل أن يختار منطقة.
-- ---------------------------------------------------------------------------

create or replace view public.unregistered_fdt_candidates as
select
  e.fdt_code,
  count(*)::integer as event_count,
  count(distinct e.username_key)::integer as subscriber_count,
  count(distinct e.raw_parent)::integer as distinct_parents,
  -- الآباء المرصودون: دليل يساعد على تحديد المنطقة، ولا يقرّرها.
  (array_agg(distinct e.raw_parent) filter (where e.raw_parent is not null))[1:5]
    as observed_parents,
  min(e.event_created_at) as first_seen,
  max(e.event_created_at) as last_seen,
  count(distinct e.profile_name)::integer as distinct_packages
from public.saas_activation_events e
left join public.fdts f on f.code = e.fdt_code
where e.fdt_code is not null
  and f.code is null
  and coalesce(e.canceled, false) = false
group by e.fdt_code;

revoke all on table public.unregistered_fdt_candidates from authenticated, anon, public;
grant select on table public.unregistered_fdt_candidates to authenticated;

-- المال المحجوب لكل كابينة داخل دورة بعينها.
create or replace function public.fdt_blocked_amount(p_cycle_id uuid, p_fdt_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'fdt_code', p_fdt_code,
    'blocked_events', count(*),
    'blocked_subscribers', count(distinct e.username_key),
    -- المبلغ يُقدَّر بسعر الشريحة الأولى: الشريحة الحقيقية لا تُعرف قبل أن
    -- تُحسَم المنطقة، فالرقم مؤشِّر حجم لا التزام.
    'indicative_amount', coalesce(sum(
      coalesce(public.commission_rate_for(
        (select scheme_version_id from public.commission_cycles c
         where c.id = p_cycle_id),
        'new', 1, e.profile_name), 0)), 0)
  )
  from public.saas_activation_events e
  join public.commission_cycles c on c.id = p_cycle_id
  left join public.fdts f on f.code = e.fdt_code
  where e.fdt_code = p_fdt_code
    and f.code is null
    and coalesce(e.canceled, false) = false
    and e.event_created_at >= c.period_start
    and e.event_created_at < (c.period_end + 1);
$$;

-- ---------------------------------------------------------------------------
-- 2. تسجيل كابينة واحدة.
--
-- المنطقة تُملى صراحةً. لا اشتقاق من الرقم ولا من الوكيل.
-- ---------------------------------------------------------------------------

create or replace function public.register_fdt(
  p_code text,
  p_zone text,
  p_agent_id uuid default null,
  p_label text default null,
  p_notes text default null,
  p_confirm_overwrite boolean default false,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_code text := btrim(coalesce(p_code, ''));
  v_before public.fdts%rowtype;
  v_after public.fdts%rowtype;
begin
  perform public.require_capability('fdt.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if v_code = '' then
    raise exception 'A cabinet code is required' using errcode = '22023';
  end if;
  -- المنطقة قرار صريح. لا قيمة افتراضية، ولا اشتقاق من رقم الكابينة.
  if p_zone is null or p_zone not in ('old', 'new') then
    raise exception 'Zone must be stated explicitly as old or new' using errcode = '22023';
  end if;
  if p_agent_id is not null
     and not exists (select 1 from public.agents where id = p_agent_id) then
    raise exception 'That agent does not exist' using errcode = 'P0002';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('fdt:' || v_code, 0));

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_before from public.fdts where code = v_code;

  -- تصنيف قائم لا يُكتب فوقه بصمت: تغيير المنطقة يُعيد تسعير مالٍ محسوب.
  if found and v_before.zone is distinct from p_zone and not p_confirm_overwrite then
    raise exception
      'Cabinet % is already classified as %; re-classifying changes money and needs explicit confirmation',
      v_code, coalesce(v_before.zone, 'unset')
      using errcode = '42501';
  end if;

  insert into public.fdts (code, label, zone, agent_id, status, notes)
  values (v_code, coalesce(p_label, 'FDT-' || v_code), p_zone, p_agent_id, 'active', p_notes)
  on conflict (code) do update
    set zone = excluded.zone,
        agent_id = coalesce(excluded.agent_id, public.fdts.agent_id),
        label = coalesce(excluded.label, public.fdts.label),
        notes = coalesce(excluded.notes, public.fdts.notes)
  returning * into v_after;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, before_data, after_data, request_id, extra
  ) values (
    v_actor, 'master.fdt.classified', 'zone',
    coalesce(v_before.zone, '(unregistered)'), p_zone,
    'fdt', v_after.id, to_jsonb(v_before), to_jsonb(v_after), p_request_id,
    case when v_before.code is null then 'newly registered' else 're-classified' end
  );

  return jsonb_build_object(
    'replayed', false, 'code', v_code, 'zone', p_zone,
    'was_registered', v_before.code is not null,
    -- التسجيل وحده لا يُحرّر مالاً: إعادة الحساب خطوة صريحة تالية.
    'recalculation_required', true
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. تسجيل جماعي.
--
-- 119 كابينة لا تُدخَل واحدةً واحدة. الدفعة تُطبَّق في معاملة واحدة: إما أن
-- تنجح كلها أو تُرفض كلها، فلا تبقى نصف تهيئة يُحسَب عليها مال.
-- ---------------------------------------------------------------------------

create or replace function public.register_fdt_bulk(
  p_rows jsonb,
  p_confirm_overwrite boolean default false,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row jsonb;
  v_code text;
  v_zone text;
  v_agent uuid;
  v_registered integer := 0;
  v_reclassified integer := 0;
  v_codes text[] := array[]::text[];
begin
  perform public.require_capability('fdt.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'A non-empty array of cabinets is required' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'At most 500 cabinets per batch' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  -- تحقّق كامل قبل أي كتابة: صفٌّ واحد فاسد يُبطل الدفعة كلها.
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_code := btrim(coalesce(v_row ->> 'code', ''));
    v_zone := v_row ->> 'zone';
    if v_code = '' then
      raise exception 'A cabinet code is missing in the batch' using errcode = '22023';
    end if;
    if v_zone is null or v_zone not in ('old', 'new') then
      raise exception 'Cabinet % has no explicit zone', v_code using errcode = '22023';
    end if;
    if v_code = any (v_codes) then
      raise exception 'Cabinet % appears twice in the same batch', v_code using errcode = '22023';
    end if;
    v_codes := v_codes || v_code;

    if not p_confirm_overwrite
       and exists (select 1 from public.fdts f
                   where f.code = v_code and f.zone is distinct from v_zone) then
      raise exception
        'Cabinet % is already classified differently; re-classifying needs explicit confirmation',
        v_code using errcode = '42501';
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_code := btrim(v_row ->> 'code');
    v_zone := v_row ->> 'zone';
    v_agent := nullif(v_row ->> 'agent_id', '')::uuid;

    if exists (select 1 from public.fdts where code = v_code) then
      v_reclassified := v_reclassified + 1;
    else
      v_registered := v_registered + 1;
    end if;

    insert into public.fdts (code, label, zone, agent_id, status, notes)
    values (v_code, coalesce(v_row ->> 'label', 'FDT-' || v_code), v_zone, v_agent, 'active',
            v_row ->> 'notes')
    on conflict (code) do update
      set zone = excluded.zone,
          agent_id = coalesce(excluded.agent_id, public.fdts.agent_id),
          notes = coalesce(excluded.notes, public.fdts.notes);
  end loop;

  insert into public.audit_logs (
    actor_id, action, field, new_value, entity_type, entity_id, after_data, request_id, extra
  ) values (
    v_actor, 'master.fdt.bulk_classified', 'zone',
    v_registered::text || ' registered, ' || v_reclassified::text || ' re-classified',
    'fdt', null, p_rows, p_request_id,
    array_to_string(v_codes, ',')
  );

  return jsonb_build_object(
    'replayed', false,
    'registered', v_registered,
    'reclassified', v_reclassified,
    'codes', to_jsonb(v_codes),
    'recalculation_required', true
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. إعادة الحساب بعد التصنيف.
--
-- تمرّ بالمحرّك المعتمد وحده. والاستثناءات لا تُحسَم يدوياً: إعادة الحساب
-- تُعيد بناء المفتوح منها، فما زال غير مسجَّل يعود، وما سُجِّل يختفي — وهو
-- ما يجعل «محلول» تعني فعلاً أن الحساب نجح.
-- ---------------------------------------------------------------------------

create or replace function public.recalculate_cycle_after_master_change(
  p_cycle_id uuid, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_before_gross bigint;
  v_before_blocking integer;
  v_result jsonb;
  v_after_blocking integer;
begin
  perform public.require_capability('fdt.manage');

  select * into v_cycle from public.commission_cycles where id = p_cycle_id;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  -- المال المُرحَّل لا يُعاد حسابه. الدورة المعتمدة أو المدفوعة خارج هذا الباب.
  if v_cycle.status in ('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED') then
    raise exception
      'This cycle is finalized or paid; master-data changes cannot rewrite it. Use correction instead'
      using errcode = '42501';
  end if;

  select coalesce(sum(gross_commission), 0) into v_before_gross
  from public.commission_cycle_snapshots where cycle_id = p_cycle_id;
  select count(*) into v_before_blocking from public.commission_exceptions
  where cycle_id = p_cycle_id and status = 'OPEN' and blocks_finalization;

  v_result := public.calculate_commission_cycle(p_cycle_id, false);

  select count(*) into v_after_blocking from public.commission_exceptions
  where cycle_id = p_cycle_id and status = 'OPEN' and blocks_finalization;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id, extra
  ) values (
    v_actor, 'commission.cycle.recalculated', 'gross_commission',
    v_before_gross::text, (v_result ->> 'gross_commission'),
    'commission_cycle', p_cycle_id, p_request_id,
    'blocking ' || v_before_blocking::text || ' -> ' || v_after_blocking::text
    || ' (after master data change)'
  );

  return jsonb_build_object(
    'cycle_id', p_cycle_id,
    'gross_before', v_before_gross,
    'gross_after', (v_result ->> 'gross_commission')::bigint,
    'blocking_before', v_before_blocking,
    'blocking_after', v_after_blocking,
    'calculation', v_result
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. الصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.fdt_blocked_amount(uuid, text)',
    'public.register_fdt(text, text, uuid, text, text, boolean, uuid)',
    'public.register_fdt_bulk(jsonb, boolean, uuid)',
    'public.recalculate_cycle_after_master_change(uuid, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
