-- ---------------------------------------------------------------------------
-- الدفعة ٣ — معاينة المطابقة قبل التصنيف، لا تخمينه.
--
-- import_batch_detail() كانت تعرض الآباء والكابينات والباقات المجهولة لهذه
-- الدفعة، لكن لا شيء يقول: كم من مشتركيها مطابَق أصلاً بالسجل القانوني
-- subscriber_identities، وكم متعارض، وكم غير مطابَق؟ تلك القراءة كانت
-- غائبة، فتُضاف هنا وحدها — لا تصنيف جِدّة، لا استحقاق، فقط عدّ حالة
-- المطابقة كما هي مسجَّلة اليوم.
--
-- المطابقة تتّبع أولوية matchSubscriber() نفسها في saas-import.js: معرّف
-- SaaS أوّلاً إن وُجد، ثم اسم المستخدم الدقيق — لا تخمين ثانٍ بمنطق مختلف.
-- بقية الدالّة حرفاً بحرف من 20260915090000_imports_reports_archive.sql.
-- ---------------------------------------------------------------------------

begin;

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

    -- مطابقة الهوية: حالة اليوم كما سجّلها subscriber_identities، لا تخمين.
    -- لا NEW ولا EXISTING هنا؛ classify_newness() تبقى المصدر الوحيد لذلك.
    'identity_match', (
      select jsonb_build_object(
        'matched', count(*) filter (where i.identity_status = 'MATCHED'),
        'conflict', count(*) filter (where i.identity_status = 'CONFLICT'),
        'needs_review', count(*) filter (where i.identity_status = 'NEEDS_REVIEW'),
        'unmatched', count(*) filter (
          where i.identity_status is null or i.identity_status = 'UNMATCHED'),
        'total_subscribers', count(*))
      from (
        select distinct e.username_key, e.saas_user_id
        from public.saas_activation_events e
        where e.import_batch_id = p_batch_id) d
      left join lateral (
        select si.identity_status
        from public.subscriber_identities si
        where (d.saas_user_id is not null and si.saas_user_id = d.saas_user_id)
           or si.username_key = d.username_key
        order by (d.saas_user_id is not null and si.saas_user_id = d.saas_user_id) desc
        limit 1) i on true),

    'declarations', coalesce((
      select jsonb_agg(to_jsonb(d)) from (
        select c.* from public.import_completeness_declarations c
        where c.import_batch_id = p_batch_id) d), '[]'::jsonb))
  where public.has_capability('saas.review');
$fn$;

revoke execute on function public.import_batch_detail(uuid) from public, anon;
grant execute on function public.import_batch_detail(uuid) to authenticated;

commit;
