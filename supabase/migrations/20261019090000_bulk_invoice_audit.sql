-- تدقيق الفواتير بالجملة (INV-001..004, INV-007..009 جزئياً, INV-013 تمديد).
--
-- الفجوة كما وثّقها التدقيق: "لا مسار رفع/تحليل/معاينة/مطابقة-جماعية/تطبيق
-- للفواتير". هذا يبنيه، على نمط تعليق الجملة (installation_hold_uploads/
-- preview_bulk_hold/apply_bulk_hold) حرفياً: رفع ملف → معاينة مبوَّبة قبل أي
-- تطبيق → تطبيق دفعة واحدة يُسجَّل ويُدقَّق.
--
-- المطابقة والتطبيق يُعاد استخدام review_invoice نفسها لكل صفٍّ مطابق — لا
-- منطق إدراج/تحديث مُكرَّر، ولا قيدٌ فريد جديد يُخترَع؛ القيد الفريد
-- (subscriber_id, stage_code) من 20261016090000 هو الحارس نفسه هنا أيضاً.
-- هذا يعني كذلك أن review_invoice يبقى صمّام الأمان الأخير: لو تغيّر شيء
-- بين المعاينة والتطبيق (تدقيقٌ يدويٌّ حدث في الأثناء)، سيرفض الصفّ لا أن
-- يكتب فوق قرارٍ آخر.
--
-- ما لا يُبنى هنا، وسبب ذلك: INV-007/008/009 (فاتورتان مختلفتان لنفس
-- المشترك في الشهر نفسه، فتتقدَّم مرحلتان تباعاً P3ثم P4) تحتاج current_stage
-- أن يتحرَّك بفعل تدقيق الفاتورة نفسه. اليوم current_stage له كاتبٌ واحدٌ
-- فقط: استيراد "المتبقي" الخارجي (20260816090000:404 upsert). جعل تدقيق
-- الفاتورة كاتباً ثانياً لنفس العمود قرارٌ معماريٌّ/مالي — أيّ استيرادٍ لاحقٍ
-- للمتبقي قد يختلف عمّا تقدّمه الفاتورة، ولا قاعدة تسوية موجودة. هذا يُسجَّل
-- في BUSINESS_DECISIONS_REQUIRED.md ولا يُخترع هنا. الملف بدل ذلك يصنّف أيّ
-- مشتركٍ له أكثر من صفّ فاتورة في نفس الرفعة كـ"تعارض" (conflict) — يُرفض لا
-- يُخمَّن.

begin;

create or replace function public.try_parse_date(p_text text)
returns date
language plpgsql
immutable
set search_path = ''
as $fn$
begin
  return nullif(btrim(coalesce(p_text, '')), '')::date;
exception when others then
  return null;
end;
$fn$;

revoke execute on function public.try_parse_date(text) from public, anon;
grant execute on function public.try_parse_date(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. سجلّ الرفعات
-- ---------------------------------------------------------------------------

create table if not exists public.installation_invoice_uploads (
  id            uuid primary key default gen_random_uuid(),
  filename      text not null,
  row_count     integer not null default 0,
  applied_count integer not null default 0,
  skipped_count integer not null default 0,
  note          text,
  request_id    uuid unique,
  uploaded_by   uuid references auth.users(id),
  uploaded_at   timestamptz not null default now(),
  constraint installation_invoice_uploads_filename_check check (btrim(filename) <> '')
);

alter table public.installation_invoice_uploads enable row level security;

revoke all on public.installation_invoice_uploads from anon;
grant select on public.installation_invoice_uploads to authenticated;

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'installation_invoice_uploads'
                   and policyname = 'installation_invoice_uploads_select') then
    create policy installation_invoice_uploads_select on public.installation_invoice_uploads
      for select to authenticated
      using ((select public.has_capability('invoice.view')));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. المعاينة — التصنيف السداسي قبل أي تطبيق
--    matched | unknown | duplicate | already_used | invalid | conflict
-- ---------------------------------------------------------------------------

create or replace function public.preview_bulk_invoice_upload(p_rows jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_doc jsonb;
begin
  perform public.require_capability('invoice.view');

  with raw as (
    select
      row_number() over () as ord,
      btrim(coalesce(x ->> 'subscriber_id', '')) as subscriber_id,
      btrim(coalesce(x ->> 'invoice_number', '')) as invoice_number,
      public.try_parse_date(x ->> 'invoice_date') as invoice_date
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  ),
  parsed as (
    select r.*,
      (r.subscriber_id <> '' and r.invoice_number <> ''
       and r.invoice_date is not null) as looks_valid
    from raw r
  ),
  inv_counts as (
    select invoice_number, count(*) as times, min(ord) as first_ord
    from parsed where looks_valid group by invoice_number
  ),
  sub_counts as (
    select subscriber_id, count(*) as times
    from parsed where looks_valid group by subscriber_id
  ),
  joined as (
    select
      p.*,
      s.subscriber_id as known_subscriber_id,
      st.current_stage,
      coalesce(st.remaining, -1) as remaining,
      ic.times as invoice_times, ic.first_ord as invoice_first_ord,
      coalesce(sc.times, 0) as sub_times,
      exists (
        select 1 from public.installation_invoices ei
        where ei.invoice_number is not null
          and ei.invoice_number = p.invoice_number
          and ei.status = 'VERIFIED') as invoice_number_used,
      exists (
        select 1 from public.installation_invoices ei2
        where ei2.subscriber_id = s.subscriber_id
          and ei2.stage_code is not distinct from st.current_stage
          and ei2.status = 'VERIFIED') as stage_already_verified
    from parsed p
    left join public.installation_subscribers s
      on lower(btrim(s.subscriber_id)) = lower(p.subscriber_id)
    left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    left join inv_counts ic on ic.invoice_number = p.invoice_number
    left join sub_counts sc on sc.subscriber_id = p.subscriber_id
  ),
  bucketed as (
    select j.*,
      case
        when not j.looks_valid then 'invalid'
        when j.known_subscriber_id is null then 'unknown'
        -- نفس المشترك أكثر من مرّة في الرفعة نفسها: هذا بالضبط سيناريو
        -- فاتورتين لمرحلتين متتاليتين في شهرٍ واحد (INV-007..009) الذي لا
        -- تُوجد له آلية تقدّمٍ آمنة اليوم — يُرفض لا يُخمَّن.
        when j.sub_times > 1 then 'conflict'
        when j.invoice_times > 1 and j.ord <> j.invoice_first_ord then 'duplicate'
        when j.current_stage is null or j.current_stage not in ('P1','P2','P3','P4')
             or j.remaining <= 0 then 'already_used'
        when j.invoice_number_used or j.stage_already_verified then 'already_used'
        else 'matched'
      end as bucket
    from joined j
  )
  select jsonb_build_object(
    'submitted', (select count(*) from raw),
    'counts', (
      select coalesce(jsonb_object_agg(b.bucket, b.n), '{}'::jsonb)
      from (select bucket, count(*) as n from bucketed group by bucket) b),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select b.ord, b.subscriber_id, b.invoice_number, b.invoice_date, b.bucket,
               b.current_stage as stage,
               case when b.bucket = 'matched'
                    then public.installation_amount_for_stage(b.current_stage) end as amount
        from bucketed b
        order by case b.bucket
                   when 'invalid' then 0 when 'unknown' then 1
                   when 'conflict' then 2 when 'duplicate' then 3
                   when 'already_used' then 4 else 5 end,
                 b.ord
        limit 1000) x), '[]'::jsonb))
  into v_doc;

  return v_doc;
end;
$fn$;

revoke execute on function public.preview_bulk_invoice_upload(jsonb) from public, anon;
grant execute on function public.preview_bulk_invoice_upload(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. التطبيق — يُعيد حساب التصنيف من الخادم (لا يثق بمعاينة العميل)، ثم
--    يستدعي review_invoice نفسها لكل صفٍّ مطابق فقط.
-- ---------------------------------------------------------------------------

create or replace function public.apply_bulk_invoice_upload(
  p_rows jsonb,
  p_filename text,
  p_note text,
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
  v_seen    integer := 0;
  v_applied integer := 0;
  v_skipped integer := 0;
  v_row     record;
begin
  perform public.require_capability('invoice.verify');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_filename, '')) = '' then
    raise exception 'The source file must be named' using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'A bulk invoice decision must state its reason' using errcode = '22023';
  end if;

  select id into v_upload from public.installation_invoice_uploads
  where request_id = p_request_id;
  if found then
    return jsonb_build_object('upload_id', v_upload, 'idempotent', true);
  end if;

  select count(*) into v_seen from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb));

  insert into public.installation_invoice_uploads (
    filename, row_count, note, request_id, uploaded_by)
  values (btrim(p_filename), v_seen, btrim(p_note), p_request_id, v_actor)
  returning id into v_upload;

  -- نفس تصنيف المعاينة حرفياً، مُعاد حسابه هنا لا مُستقبَلاً من العميل.
  for v_row in
    with raw as (
      select
        row_number() over () as ord,
        btrim(coalesce(x ->> 'subscriber_id', '')) as subscriber_id,
        btrim(coalesce(x ->> 'invoice_number', '')) as invoice_number,
        public.try_parse_date(x ->> 'invoice_date') as invoice_date
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
    ),
    parsed as (
      select r.*,
        (r.subscriber_id <> '' and r.invoice_number <> ''
         and r.invoice_date is not null) as looks_valid
      from raw r
    ),
    inv_counts as (
      select invoice_number, count(*) as times, min(ord) as first_ord
      from parsed where looks_valid group by invoice_number
    ),
    sub_counts as (
      select subscriber_id, count(*) as times
      from parsed where looks_valid group by subscriber_id
    ),
    joined as (
      select
        p.*,
        s.subscriber_id as known_subscriber_id,
        st.current_stage,
        coalesce(st.remaining, -1) as remaining,
        ic.times as invoice_times, ic.first_ord as invoice_first_ord,
        coalesce(sc.times, 0) as sub_times,
        exists (
          select 1 from public.installation_invoices ei
          where ei.invoice_number is not null
            and ei.invoice_number = p.invoice_number
            and ei.status = 'VERIFIED') as invoice_number_used,
        exists (
          select 1 from public.installation_invoices ei2
          where ei2.subscriber_id = s.subscriber_id
            and ei2.stage_code is not distinct from st.current_stage
            and ei2.status = 'VERIFIED') as stage_already_verified
      from parsed p
      left join public.installation_subscribers s
        on lower(btrim(s.subscriber_id)) = lower(p.subscriber_id)
      left join public.installation_subscriber_state st on st.subscriber_uuid = s.id
      left join inv_counts ic on ic.invoice_number = p.invoice_number
      left join sub_counts sc on sc.subscriber_id = p.subscriber_id
    )
    select
      j.known_subscriber_id as subscriber_id, j.current_stage, j.invoice_number, j.ord,
      case
        when not j.looks_valid then 'invalid'
        when j.known_subscriber_id is null then 'unknown'
        when j.sub_times > 1 then 'conflict'
        when j.invoice_times > 1 and j.ord <> j.invoice_first_ord then 'duplicate'
        when j.current_stage is null or j.current_stage not in ('P1','P2','P3','P4')
             or j.remaining <= 0 then 'already_used'
        when j.invoice_number_used or j.stage_already_verified then 'already_used'
        else 'matched'
      end as bucket
    from joined j
    order by j.ord
  loop
    if v_row.bucket <> 'matched' then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- review_invoice يبقى صمّام الأمان الأخير: لو تغيّر شيءٌ منذ المعاينة
    -- (تدقيقٌ يدويٌّ وقع في الأثناء، أو المرحلة لم تعد القسط القادم)
    -- سيرفض هذا الصفّ بعينه، لا الرفعة كلّها.
    begin
      perform public.review_invoice(
        v_row.subscriber_id, v_row.current_stage, 'VERIFIED',
        btrim(p_note), v_row.invoice_number, gen_random_uuid());
      v_applied := v_applied + 1;
    exception when others then
      v_skipped := v_skipped + 1;
    end;
  end loop;

  update public.installation_invoice_uploads
  set applied_count = v_applied, skipped_count = v_skipped
  where id = v_upload;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.invoice.bulk_uploaded', 'applied_count', '0', v_applied::text,
    'installation_invoice_upload', v_upload, p_request_id,
    'filename=' || btrim(p_filename) || ' seen=' || v_seen::text
      || ' applied=' || v_applied::text || ' skipped=' || v_skipped::text
      || ' reason=' || btrim(p_note));

  return jsonb_build_object(
    'upload_id', v_upload, 'idempotent', false,
    'seen', v_seen, 'applied', v_applied, 'skipped', v_skipped);
end;
$fn$;

revoke execute on function public.apply_bulk_invoice_upload(jsonb,text,text,uuid) from public, anon;
grant execute on function public.apply_bulk_invoice_upload(jsonb,text,text,uuid) to authenticated;

commit;
