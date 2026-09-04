-- عقود قراءة نتيجة الشهر: ما تعرضه الشاشة يُحسَب في الخادم لا في المتصفّح.
--
-- الشاشة الشهرية تحتاج ثلاثة، وكلّها قراءةٌ صرف:
--   • قائمة تشغيلات الأشهر (مرقَّمة الصفحات).
--   • أسطر تشغيلةٍ واحدة، مرشَّحةً بالنتيجة (ممنوح · محجوب · مراجعة).
--   • طابور الأسماء غير المحسومة: ما الذي يمنع اعتماد هذا الشهر بالضبط.
--
-- ولا شيء منها يحسب مالاً في الواجهة: المبالغ والتجميعات تخرج من
-- installation_calculation_run_summary وحدها، وهذه تُصفّي وترقّم لا أكثر.
--
-- إضافي بالكامل، forward-only. لا جدولَ يُمَس، ولا سلوكَ حسابٍ يتغيّر.

begin;

-- ---------------------------------------------------------------------------
-- ١ · أشهر الحساب
-- ---------------------------------------------------------------------------

create or replace function public.page_installation_calculation_runs(
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_lim integer := public.page_limit(p_limit);
  v_off integer := public.page_offset(p_offset);
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_capability('installation.view');

  with base as (
    select r.id, r.period, r.status, r.source_batch_id, r.source_checksum,
           b.source_filename, r.subscribers_count, r.events_count, r.awarded_count,
           r.total_amount, r.new_subscribers_count, r.blocked_count,
           r.unresolved_print_count, r.calculated_at, r.approved_at
    from public.installation_calculation_runs r
    left join public.saas_import_batches b on b.id = r.source_batch_id
    where p_status is null or btrim(p_status) = '' or r.status = p_status
  ),
  total as (select count(*)::bigint as n from base),
  paged as (select * from base order by period desc, calculated_at desc
            limit v_lim offset v_off)
  select (select n from total),
         coalesce((select jsonb_agg(to_jsonb(p) order by p.period desc, p.calculated_at desc)
                   from paged p), '[]'::jsonb)
    into v_total, v_rows;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_installation_calculation_runs(text, integer, integer)
  from public;
revoke execute on function public.page_installation_calculation_runs(text, integer, integer)
  from anon;
grant execute on function public.page_installation_calculation_runs(text, integer, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- ٢ · أسطر شهرٍ واحد
--
-- الترتيب بالمشترك ثم بتسلسله يجعل قراءة السلّم ممكنةً بالعين: P3 ثم P4
-- لصاحبهما متتاليتين، لا مبعثرتين في الصفحة.
-- ---------------------------------------------------------------------------

create or replace function public.page_installation_calculation_lines(
  p_run_id uuid,
  p_outcome text default null,
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
declare
  v_lim integer := public.page_limit(p_limit);
  v_off integer := public.page_offset(p_offset);
  v_total bigint;
  v_rows jsonb;
begin
  perform public.require_capability('installation.view');

  with base as (
    select l.id, l.subscriber_key, l.activation_event_id, l.sequence_in_subscriber,
           l.event_at, l.opening_stage, l.awarded_stage, l.closing_stage, l.amount,
           l.registry_hit, l.source_parent_name, l.outcome, l.reason_code, l.approved,
           l.agent_id_at_calculation, a.official_name as print_name,
           l.parent_agent_id_at_calculation, pa.official_name as parent_name
    from public.installation_calculation_lines l
    left join public.agents a on a.id = l.agent_id_at_calculation
    left join public.agents pa on pa.id = l.parent_agent_id_at_calculation
    where l.run_id = p_run_id
      and (p_outcome is null or btrim(p_outcome) = '' or l.outcome = p_outcome)
      and (p_search is null or btrim(p_search) = ''
           or l.subscriber_key ilike '%' || btrim(p_search) || '%'
           or coalesce(l.source_parent_name, '') ilike '%' || btrim(p_search) || '%')
  ),
  total as (select count(*)::bigint as n from base),
  paged as (select * from base
            order by subscriber_key, sequence_in_subscriber
            limit v_lim offset v_off)
  select (select n from total),
         coalesce((select jsonb_agg(to_jsonb(p)
                     order by p.subscriber_key, p.sequence_in_subscriber)
                   from paged p), '[]'::jsonb)
    into v_total, v_rows;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function
  public.page_installation_calculation_lines(uuid, text, text, integer, integer) from public;
revoke execute on function
  public.page_installation_calculation_lines(uuid, text, text, integer, integer) from anon;
grant execute on function
  public.page_installation_calculation_lines(uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- ٣ · طابور الأسماء غير المحسومة
--
-- الشاشة تسأل سؤالاً واحداً: ما الأسماء التي تمنع اعتماد هذا الشهر، وكم
-- مشتركاً وراء كلٍّ منها؟ والجواب أسماءُ مصدرٍ خام لا وكلاء — لأنّ حسمها
-- هو بالضبط ما لم يحدث بعد. ولا يُخمَّن لها مالكٌ هنا ولا في الواجهة:
-- resolve_print_name وحدها تحسم، بقرارٍ مسجَّل.
-- ---------------------------------------------------------------------------

create or replace function public.installation_unmapped_print_names(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_rows jsonb;
begin
  perform public.require_capability('installation.view');

  select coalesce(jsonb_agg(t order by t ->> 'source_name'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
             'source_name', l.source_parent_name,
             'subscribers', count(distinct l.subscriber_key),
             'lines', count(*),
             'resolution', coalesce(max(al.resolution), 'unmapped')) as t
    from public.installation_calculation_lines l
    left join public.agent_aliases al
      on al.alias_key = lower(btrim(coalesce(l.source_parent_name, '')))
    where l.run_id = p_run_id
      and l.agent_id_at_calculation is null
      and btrim(coalesce(l.source_parent_name, '')) <> ''
    group by l.source_parent_name
  ) s;

  return v_rows;
end;
$fn$;

revoke execute on function public.installation_unmapped_print_names(uuid) from public;
revoke execute on function public.installation_unmapped_print_names(uuid) from anon;
grant execute on function public.installation_unmapped_print_names(uuid) to authenticated;

commit;
