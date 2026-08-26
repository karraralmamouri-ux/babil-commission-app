-- LIVE-04 (PR-B3): إجمالي صدفة الاستثناءات اليدوية كان محسوباً من الصفحة لا
-- من المجموعة.
--
-- page_manual_exceptions حسب count(*) من نتيجة الفرعية المُقيَّدة بـ limit/
-- offset نفسها — العيب ذاته الذي أصلحه page_installation_grace_queue
-- (20261010090000): صفحة أخيرة قصيرة تجعل "الإجمالي" يساوي عدد صفوفها لا
-- عدد الاستثناءات الحقيقي، فتبدو الأرشفة/الأرقام في الأعلى متناقضة مع
-- التفصيل. الإصلاح: عدّ المجموعة الكاملة في CTE منفصل قبل limit/offset —
-- النمط المثبَت في نفس الملف لطابور آخر.

begin;

create or replace function public.page_manual_exceptions(
  p_status text default 'NEEDS_REVIEW',
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
    select i.*
    from public.manual_exception_intakes i
    where (p_status is null or i.status = p_status)
      and (p_search is null or btrim(p_search) = '' or
           i.username_key ilike '%' || btrim(p_search) || '%' or
           coalesce(i.subscriber_name, '') ilike '%' || btrim(p_search) || '%')
  ),
  total as (select count(*)::bigint as n from base),
  paged as (select * from base order by created_at desc limit v_lim offset v_off)
  select (select n from total),
         coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from paged p), '[]'::jsonb)
    into v_total, v_rows;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_manual_exceptions(text, text, integer, integer) from public, anon;
grant execute on function public.page_manual_exceptions(text, text, integer, integer) to authenticated;

commit;
