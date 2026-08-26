-- PR-B3: يستبدل page_activation_corrections المعرَّفة في
-- 20260923090000_activation_corrections.sql (مُطبَّقة على الإنتاج بالفعل —
-- لا تُعدَّل، تُستبدَل بـcreate or replace هنا) لإصلاح خللين حقيقيين:
--
-- 1) (تكملة LIVE-02) تصحيحات ADD لا مصدر حدثٍ لها (source_event_id فارغ
--    دوماً لأنها تُضيف حدثاً لا يُشير إلى سابق) فتفشل دوماً في الانضمام إلى
--    commission_qualifying_events، فيسقط نطاق عمولتها (scope_type/scope_id)
--    دوماً إلى المسار الاحتياطي القديم المبني على fdts.zone اليدوي — نفس
--    الخلط الذي أصلحه fdt_commission_scope() في محرّك الحساب، لم يبلغ هذا
--    المسار. النتيجة: شاشة /commissions/corrections تعرض/تُصفّي صفوف ADD
--    بقاعدة النطاق المهجورة، لا بقاعدة 94–119 المعتمدة.
--
-- 2) (خلل "KPI من صفحة مُجزَّأة" المسجَّل صراحةً) استبعادات/إضافات فعّالة في
--    corrections.ts كانت تُحتسَب من page.rows (صفحة 50 فقط) بينما تُعرَض
--    كإجماليٍ عام. هنا تُضاف active_exclusions/active_additions كإجماليين
--    خادميين على كامل المجموعة المُرشَّحة (نفس فلاتر p_scope_type/p_scope_id/
--    p_status)، فيتوقّف الاحتساب من الصفحة الحالية.
--
-- لا كتابة بيانات هنا — دالّة قراءة فقط (stable)، فلا أثر مالي ولا خطر على
-- تاريخ مُحتسَب، ولا تُغيَّر بيانات fdts.zone بأي شكل.

begin;

create or replace function public.page_activation_corrections(
  p_cycle_id uuid,
  p_scope_type text default null,
  p_scope_id text default null,
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
  v_rows jsonb;
  v_total bigint;
  v_lim integer;
  v_off integer;
  v_active_exclusions bigint;
  v_active_additions bigint;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select c.id, c.correction_type, c.status, c.reason, c.created_at, c.request_id,
           c.source_event_id, c.subscriber_username, c.package_code, c.event_at,
           c.fdt_code, c.raw_parent, c.revoke_reason, c.revoked_at,
           p.email as actor_email,
           coalesce(c.fdt_code, q.fdt_code) as effective_fdt,
           coalesce(lower(btrim(c.subscriber_username)), q.subscriber_key) as subscriber,
           coalesce(c.package_code, q.package_code) as package,
           -- تصحيحات ADD (لا q لها) تشتقّ النطاق من نفس قاعدة 94–119
           -- المعتمدة، لا من fdts.zone اليدوي. تصحيحات لها q تبقى على نطاق
           -- الحدث الأصلي كما هو دون تغيير.
           coalesce(q.scope_type,
             public.fdt_commission_scope(coalesce(c.fdt_code, q.fdt_code))) as scope_type,
           coalesce(q.scope_id,
             case when public.fdt_commission_scope(coalesce(c.fdt_code, q.fdt_code)) = 'FDT'
                  then coalesce(c.fdt_code, q.fdt_code) else null end) as scope_id
    from public.activation_corrections c
    left join public.profiles p on p.id = c.created_by
    left join public.commission_qualifying_events q on q.saas_event_id = c.source_event_id
    where c.cycle_id = p_cycle_id
      and (p_status is null or c.status = p_status)
  ),
  filtered as (
    select * from kept
    where (p_scope_type is null or scope_type = p_scope_type)
      and (p_scope_id is null or scope_id = p_scope_id)
  )
  select
    count(*),
    count(*) filter (where status = 'ACTIVE' and correction_type = 'EXCLUDE'),
    count(*) filter (where status = 'ACTIVE' and correction_type = 'ADD'),
    coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select k.* from filtered k order by k.created_at desc
        limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_active_exclusions, v_active_additions, v_rows
  from filtered;

  return public.page_envelope(v_rows, v_total, v_lim, v_off)
    || jsonb_build_object(
         'active_exclusions', coalesce(v_active_exclusions, 0),
         'active_additions', coalesce(v_active_additions, 0));
end;
$fn$;

revoke execute on function public.page_activation_corrections(uuid,text,text,text,integer,integer) from public, anon;
grant execute on function public.page_activation_corrections(uuid,text,text,text,integer,integer) to authenticated;

commit;
