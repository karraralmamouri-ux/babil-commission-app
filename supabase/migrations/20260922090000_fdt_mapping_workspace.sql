-- ---------------------------------------------------------------------------
-- ربط الوكلاء والكابينات
--
-- «ربط الوكلاء والكابينات» كان زرّاً ينادي openSettingsSection على قسم
-- إعدادات القراءة الخام — نموذج المدَيات الرقميّة القديم: «الكابينات من 100
-- إلى 200 لفلان». وذاك يستنتج العائدية والنطاق من رقم الكابينة، وهو ما لا
-- يجوز: الرقم ليس حقيقةً مالية.
--
-- والبديل يقرأ الحقيقة القائمة: `fdts.agent_id` و`fdts.zone`، ويكتبها
-- بـ`register_fdt` التي تشترط النطاق صراحةً وتُسجّل الأثر. لا مدَيات، ولا
-- استنتاج، ولا شريحة افتراضية للوكيل — الشريحة يحسبها محرّك العمولة.
--
-- والكتابة كلّها موجودة أصلاً في `register_fdt`؛ الناقص كان القراءة التي
-- تُظهر الربط كما هو: من مربوط، وبمن، وما الذي بقي بلا وكيل.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.page_fdt_mapping(
  p_search text default null,
  p_agent text default null,
  p_zone text default null,
  p_mapped boolean default null,
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
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select f.code, f.label, f.zone, f.status, f.notes,
           f.agent_id, a.code as agent_code, a.official_name as agent_name,
           a.status as agent_status,
           (select count(*) from public.saas_activation_events e
            where e.fdt_code = f.code) as events,
           (select count(distinct e2.username_key) from public.saas_activation_events e2
            where e2.fdt_code = f.code) as subscribers
    from public.fdts f
    left join public.agents a on a.id = f.agent_id
    where (p_zone is null or f.zone = p_zone)
      and (p_mapped is null
           or (p_mapped and f.agent_id is not null)
           or (not p_mapped and f.agent_id is null))
      and (p_agent is null or btrim(p_agent) = ''
           or a.code ilike '%' || p_agent || '%'
           or a.official_name ilike '%' || p_agent || '%')
      and (p_search is null or btrim(p_search) = ''
           or f.code ilike '%' || p_search || '%'
           or f.label ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k
      -- غير المربوط أوّلاً: هو ما ينتظر قراراً.
      order by (k.agent_id is not null), k.events desc, k.code
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_fdt_mapping(text,text,text,boolean,integer,integer)
  from public, anon;
grant execute on function public.page_fdt_mapping(text,text,text,boolean,integer,integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- الخلاصة: ما هو مربوط وما ينتظر
--
-- «غير مسجَّلة» ليست «غير مربوطة»: الأولى كابينةٌ وردت في المصدر ولا وجود
-- لها في السجلّ أصلاً، والثانية مسجَّلة بلا وكيل. الخلط بينهما يجعل رقماً
-- واحداً يخفي مشكلتين مختلفتي العلاج.
-- ---------------------------------------------------------------------------

create or replace function public.fdt_mapping_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  perform public.require_capability('commission.view');

  return jsonb_build_object(
    'registered',  (select count(*) from public.fdts),
    'mapped',      (select count(*) from public.fdts where agent_id is not null),
    'unmapped',    (select count(*) from public.fdts where agent_id is null),
    'by_zone', (
      select coalesce(jsonb_object_agg(z.zone, z.n), '{}'::jsonb)
      from (select coalesce(zone, 'بلا نطاق') as zone, count(*) as n
            from public.fdts group by 1) z),
    'agents_with_cabinets', (
      select count(distinct agent_id) from public.fdts where agent_id is not null),
    -- الواردة في المصدر ولا سجلّ لها: تُحسب هنا لتُقرأ إلى جانب أختها.
    'unregistered', (
      select count(distinct e.fdt_code) from public.saas_activation_events e
      where e.fdt_code is not null and btrim(e.fdt_code) <> ''
        and not exists (select 1 from public.fdts f where f.code = e.fdt_code)));
end;
$fn$;

revoke execute on function public.fdt_mapping_summary() from public, anon;
grant execute on function public.fdt_mapping_summary() to authenticated;

commit;
