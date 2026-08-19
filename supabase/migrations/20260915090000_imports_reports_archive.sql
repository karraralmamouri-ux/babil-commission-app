-- ---------------------------------------------------------------------------
-- الاستيراد والتقارير والأرشيف — آخر ما كان حبيس الشاشات السابقة
--
-- ثلاث مساحات بقيت في #/legacy وحدها. كلها قراءة: لا تكتب صفاً، ولا تُعيد
-- حساب مالٍ في المتصفّح.
--
-- والقاعدة التي تحكم التقارير: المجموع والتفصيل من استعلامٍ واحد. حين
-- يُحسب المجموع في مكانٍ والتفصيل في آخر يفترقان عند أوّل شرطٍ يُنسى في
-- أحدهما — فيُصدَّر رقمٌ لا يطابق ما على الشاشة.
--
-- والاكتمال يبقى مُعلَناً لا مُستنتَجاً: مدى التواريخ لا يُثبت أن الملف كامل.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. مركز الاستيراد
-- ---------------------------------------------------------------------------

create or replace function public.page_import_batches(
  p_kind text default null,
  p_completeness text default null,
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
  perform public.require_capability('saas.review');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select
      b.id, b.source_kind, b.source_filename, b.source_checksum, b.parser_version,
      b.completeness_status, b.declared_coverage_start, b.declared_coverage_end,
      b.observed_min_created_at, b.observed_max_created_at,
      b.source_row_count, b.imported_row_count, b.duplicate_count,
      b.warning_count, b.error_count, b.status, b.imported_at,
      u.email as imported_by_email,
      -- ما وصل فعلاً إلى الأحداث من هذه الدفعة.
      (select count(*) from public.saas_activation_events e
       where e.import_batch_id = b.id) as stored_events,
      (select count(distinct e.username_key) from public.saas_activation_events e
       where e.import_batch_id = b.id) as stored_subscribers
    from public.saas_import_batches b
    left join public.profiles u on u.id = b.imported_by
    where (p_kind is null or b.source_kind = p_kind)
      and (p_completeness is null or b.completeness_status = p_completeness)
      and (p_search is null or btrim(p_search) = ''
           or b.source_filename ilike '%' || p_search || '%'
           or b.source_checksum ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k order by k.imported_at desc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_import_batches(text,text,text,integer,integer)
  from public, anon;
grant execute on function public.page_import_batches(text,text,text,integer,integer)
  to authenticated;

create or replace function public.import_batch_detail(p_batch_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'batch', (
      select jsonb_build_object(
        'id', b.id, 'source_kind', b.source_kind, 'filename', b.source_filename,
        'checksum', b.source_checksum, 'parser_version', b.parser_version,
        'completeness_status', b.completeness_status,
        'declared_coverage_start', b.declared_coverage_start,
        'declared_coverage_end', b.declared_coverage_end,
        'observed_min', b.observed_min_created_at, 'observed_max', b.observed_max_created_at,
        'source_rows', b.source_row_count, 'imported_rows', b.imported_row_count,
        'duplicates', b.duplicate_count, 'warnings', b.warning_count,
        'errors', b.error_count, 'status', b.status,
        'imported_at', b.imported_at, 'imported_by', u.email,
        'sheet_results', b.sheet_results)
      from public.saas_import_batches b
      left join public.profiles u on u.id = b.imported_by
      where b.id = p_batch_id),

    -- ما وصل فعلاً: الفارق عن source_rows هو المرفوض والمكرّر.
    'stored', (
      select jsonb_build_object(
        'events', count(*),
        'subscribers', count(distinct e.username_key),
        'parents', count(distinct e.raw_parent),
        'first_event', min(e.event_created_at),
        'last_event', max(e.event_created_at))
      from public.saas_activation_events e where e.import_batch_id = p_batch_id),

    -- الآباء الواردون: أوّل ما يُراجَع بعد استيراد.
    'parents', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select e.raw_parent as parent_name, count(*) as events,
               count(distinct e.username_key) as subscribers,
               public.parent_ownership_type(e.raw_parent) as ownership
        from public.saas_activation_events e
        where e.import_batch_id = p_batch_id and e.raw_parent is not null
        group by e.raw_parent order by count(*) desc limit 25) x), '[]'::jsonb),

    -- الكابينات المجهولة في هذه الدفعة بعينها.
    'unknown_fdts', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select e.fdt_code, count(*) as events, count(distinct e.username_key) as subscribers
        from public.saas_activation_events e
        where e.import_batch_id = p_batch_id
          and e.fdt_code is not null and btrim(e.fdt_code) <> ''
          and not exists (select 1 from public.fdts f where f.code = e.fdt_code)
        group by e.fdt_code order by count(*) desc limit 25) y), '[]'::jsonb),

    -- الباقات غير المعروفة: تمنع تسعير الحدث.
    'unknown_packages', coalesce((
      select jsonb_agg(to_jsonb(z)) from (
        select e.profile_name, count(*) as events
        from public.saas_activation_events e
        where e.import_batch_id = p_batch_id
          and e.profile_name is not null
          and not exists (select 1 from public.packages p where p.code = e.profile_name)
        group by e.profile_name order by count(*) desc limit 25) z), '[]'::jsonb),

    'declarations', coalesce((
      select jsonb_agg(to_jsonb(d)) from (
        select c.* from public.import_completeness_declarations c
        where c.import_batch_id = p_batch_id) d), '[]'::jsonb))
  where public.has_capability('saas.review');
$fn$;

revoke execute on function public.import_batch_detail(uuid) from public, anon;
grant execute on function public.import_batch_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. تقرير أجور التنصيب
--
-- المجموع والتفصيل من CTE واحدة: يستحيل أن يفترقا.
-- ---------------------------------------------------------------------------

create or replace function public.report_installation_fees(
  p_period text default null,
  p_reseller text default null,
  p_stage text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_sum jsonb; v_lim integer; v_off integer;
begin
  perform public.require_capability('report.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select t.id, t.period, t.subscriber_id, t.reseller, t.stage, t.amount,
           t.invoice_status, t.payment_status, t.paid_amount, t.paid_at, t.zone, t.fdt
    from public.installation_entitlements t
    where (p_period is null or t.period = p_period)
      and (p_reseller is null or t.reseller = p_reseller)
      and (p_stage is null or t.stage = p_stage)
  )
  select
    count(*),
    -- المجموع من المجموعة نفسها التي تُصفَّح.
    jsonb_build_object(
      'entitlements', count(*),
      'total_amount', coalesce(sum(amount), 0),
      'paid_amount', coalesce(sum(paid_amount), 0),
      'due_amount', coalesce(sum(amount) filter (where payment_status <> 'paid'), 0),
      'paid_count', count(*) filter (where payment_status = 'paid'),
      'by_stage', coalesce((
        select jsonb_object_agg(s.stage, jsonb_build_object('n', s.n, 'amount', s.amt))
        from (select stage, count(*) as n, sum(amount) as amt from base group by stage) s), '{}'::jsonb),
      'by_reseller', coalesce((
        select jsonb_agg(to_jsonb(r)) from (
          select reseller, count(*) as n, sum(amount) as amount,
                 sum(paid_amount) as paid
          from base group by reseller order by sum(amount) desc limit 50) r), '[]'::jsonb)),
    coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select b.* from base b order by b.reseller, b.subscriber_id
        limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_sum, v_rows
  from base;

  return jsonb_build_object(
    'summary', v_sum,
    'page', public.page_envelope(v_rows, v_total, v_lim, v_off));
end;
$fn$;

revoke execute on function public.report_installation_fees(text,text,text,integer,integer)
  from public, anon;
grant execute on function public.report_installation_fees(text,text,text,integer,integer)
  to authenticated;

-- تقرير الدفعات والمدفوعات.
create or replace function public.report_payment_history(
  p_from date default null,
  p_to date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_sum jsonb; v_lim integer; v_off integer;
begin
  perform public.require_capability('report.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select l.id, l.created_at, l.subscriber_id, l.agent_name, l.stage,
           l.amount, l.month_key, l.txn_type, l.direction, l.source_origin,
           b.name as batch_name, b.payment_ref, b.payment_date
    from public.financial_ledger l
    left join public.installation_payments ip on ip.entitlement_id = l.source_id
    left join public.installation_payment_batch_items bi on bi.entitlement_id = l.source_id
    left join public.installation_payment_batches b on b.id = bi.batch_id
    where l.domain = 'installation'
      and (p_from is null or l.created_at >= p_from)
      and (p_to is null or l.created_at < (p_to + 1))
  )
  select count(*),
    jsonb_build_object(
      'entries', count(*),
      'total_amount', coalesce(sum(amount * direction), 0),
      'payments', count(*) filter (where txn_type = 'PAYMENT'),
      'reversals', count(*) filter (where txn_type = 'REVERSAL'),
      'adjustments', count(*) filter (where txn_type = 'ADJUSTMENT')),
    coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select b.* from base b order by b.created_at desc
        limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_sum, v_rows
  from base;

  return jsonb_build_object(
    'summary', v_sum,
    'page', public.page_envelope(v_rows, v_total, v_lim, v_off));
end;
$fn$;

revoke execute on function public.report_payment_history(date,date,integer,integer)
  from public, anon;
grant execute on function public.report_payment_history(date,date,integer,integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. الأرشيف — قراءة محضة
--
-- يميّز الحالي عن التاريخي عن المحسوم. ولا يكتب شيئاً: الأرشيف مرجعٌ لا
-- سلطةٌ ثانية على المال.
-- ---------------------------------------------------------------------------

create or replace function public.archive_overview()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'commission_cycles', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.period_start desc) from (
        select c.id, c.name, c.status, c.period_start, c.period_end,
               c.finalized_at, c.closed_at,
               (c.status in ('FINALIZED','PARTIALLY_PAID','PAID','CLOSED')) as settled
        from public.commission_cycles c) x), '[]'::jsonb),

    'installation_batches', coalesce((
      select jsonb_agg(to_jsonb(y) order by y.prepared_at desc) from (
        select b.id, b.name, b.status, b.total_amount, b.item_count, b.prepared_at,
               b.payment_date, b.payment_ref, b.posted_at,
               (b.status = 'PAID') as settled
        from public.installation_payment_batches b limit 200) y), '[]'::jsonb),

    'imports', coalesce((
      select jsonb_agg(to_jsonb(z) order by z.imported_at desc) from (
        select b.id, b.source_kind, b.source_filename, b.completeness_status,
               b.imported_row_count, b.imported_at
        from public.saas_import_batches b limit 200) z), '[]'::jsonb),

    'scheme_versions', coalesce((
      select jsonb_agg(to_jsonb(w) order by w.created_at desc) from (
        select v.id, v.status, v.created_at,
               (select count(*) from public.installation_stage_definitions d
                where d.scheme_version_id = v.id) as stages
        from public.installation_scheme_versions v) w), '[]'::jsonb),

    'totals', jsonb_build_object(
      'historical_paid', (select coalesce(sum(amount), 0) from public.installation_payment_history),
      'historical_rows', (select count(*) from public.installation_payment_history),
      'historical_subscribers', (select count(distinct subscriber_uuid)
                                 from public.installation_payment_history),
      'ledger_entries', (select count(*) from public.financial_ledger)))
  where public.has_capability('report.view');
$fn$;

revoke execute on function public.archive_overview() from public, anon;
grant execute on function public.archive_overview() to authenticated;

-- سجلّ الدفع التاريخي مُصفَّحاً — كان يُقرأ في الشاشات السابقة وحدها.
create or replace function public.page_historical_payments(
  p_search text default null,
  p_stage text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_sum bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('report.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select h.id, h.stage, h.amount, h.payment_date, h.created_at,
           s.subscriber_id, s.reseller, s.fdt
    from public.installation_payment_history h
    join public.installation_subscribers s on s.id = h.subscriber_uuid
    where (p_stage is null or h.stage = p_stage)
      and (p_search is null or btrim(p_search) = ''
           or s.subscriber_id ilike '%' || p_search || '%'
           or s.reseller ilike '%' || p_search || '%')
  )
  select count(*), coalesce(sum(amount), 0), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select b.* from base b order by b.payment_date desc nulls last, b.subscriber_id
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_sum, v_rows
  from base;

  return public.page_envelope(v_rows, v_total, v_lim, v_off)
      || jsonb_build_object('sum_amount', v_sum);
end;
$fn$;

revoke execute on function public.page_historical_payments(text,text,integer,integer)
  from public, anon;
grant execute on function public.page_historical_payments(text,text,integer,integer)
  to authenticated;

commit;
