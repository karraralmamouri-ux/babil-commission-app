-- ---------------------------------------------------------------------------
-- مهلة الثماني ثوانٍ: دالّتان كانتا تردّان 500 في الإنتاج
--
-- دور `authenticated` عليه `statement_timeout = 8s`. الدالّتان أدناه كانتا
-- تتجاوزانه، فيُلغي Postgres الجملة بالرمز 57014 ويردّ PostgREST بـ500.
--
-- ولا يظهر ذلك في اختبارٍ يُشغَّل بدور `postgres`: مهلته دقيقتان. وحتى
-- `set role authenticated` لا يكفي — تعيين الدور لا يطبّق `rolconfig`
-- الخاصّ به، فتبقى مهلة الجلسة الأصلية. لذلك يثبّت الاختبار المرافق
-- `statement_timeout` صراحةً على 8s قبل النداء.
--
-- العلّة واحدة في الاثنتين: دالّةٌ عدديّة تُنادى مرّةً لكل صفّ.
--
--   installation_payout_candidates → subscriber_ownership_type لكل مشترك
--                                    (5,693 نداءً)
--   commission_finalization_blockers → commission_rate_for لكل استثناء
--                                      (22,727 نداءً)
--
-- والعلاج ليس رفع المهلة — رفعُها يُخفي البطء ويتركه ينمو مع البيانات — بل
-- إزالة النداء المتكرّر: الأول يقرأ الصفّ الحاضر أصلاً، والثاني يحسب السعر
-- مرّةً لكل باقةٍ مميّزة لا مرّةً لكل صفّ.
--
-- النتيجة يجب أن تبقى مطابقة حرفاً بحرف، ويحرس ذلك اختبارٌ يقارن البصمة.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. مرشّحو الصرف
-- ---------------------------------------------------------------------------

create or replace function public.installation_payout_candidates()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with base as (
    select
      s.subscriber_id,
      s.reseller,
      st.remaining,
      st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      -- الحجب بالتعليق
      exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at)) as b_hold,
      -- الحجب بالفاتورة: كل مرحلة في المخطّط المنشور تشترط فاتورة مدقَّقة.
      not exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED') as b_invoice,
      -- الحجب بالحالة التاريخية
      (st.resolution <> 'resolved' or st.payment_eligible is not true) as b_source,
      -- الحجب بالهوية
      exists (
        select 1 from public.subscriber_identities i
        where i.username_key = lower(btrim(s.subscriber_id))
          and i.identity_status = 'CONFLICT') as b_identity,
      -- الحجب بالعائدية: غير محسومة، أو شركة مباشرة لا تنشأ عنها عمولة وكيل.
      --
      -- كان هذا السطر ينادي `subscriber_ownership_type(s.subscriber_id)` مرّةً
      -- لكل مشترك — 5,693 نداءً، كلٌّ منها يُعيد الانضمام إلى
      -- `installation_subscribers` ليجد الصفّ الذي بين أيدينا أصلاً. فتجاوز
      -- الاستعلامُ مهلةَ الثماني ثوانٍ المفروضة على دور `authenticated`،
      -- فردّ PostgREST بـ500. والصفّ حاضر هنا ومفتاحه معنا، فالبحث يتمّ
      -- مباشرةً بلا نداء ولا انضمامٍ ثانٍ — والحكم نفسه حرفاً بحرف.
      (coalesce(
        (select public.normalize_ownership_type(o.ownership_type)
         from public.subscriber_ownership o
         where o.username_key = s.subscriber_key
           and o.effective_from <= now()
           and (o.effective_to is null or o.effective_to > now())
         order by o.effective_from desc limit 1),
        (select case
           when si.source_classification = 'DIRECT_COMPANY' then 'DIRECT_COMPANY'
           when si.source_classification = 'RESELLER' then 'RESELLER'
           else 'NEEDS_REVIEW' end
         from public.subscriber_identities si
         where si.username_key = s.subscriber_key limit 1),
        'NEEDS_REVIEW') <> 'RESELLER') as b_parent
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  ),
  judged as (
    select b.*,
      (not b_hold and not b_invoice and not b_source
       and not b_identity and not b_parent) as is_ready
    from base b
  )
  select jsonb_build_object(
    'subscribers', count(*),
    'amount', coalesce(sum(amount), 0),

    -- الحجب مصنَّفاً. صفرٌ في صنفٍ لا يعني أن الطريق سالك.
    'blocked', jsonb_build_object(
      'hold',        count(*) filter (where b_hold),
      'invoice',     count(*) filter (where b_invoice),
      'source',      count(*) filter (where b_source),
      'identity',    count(*) filter (where b_identity),
      'parent',      count(*) filter (where b_parent),
      'any',         count(*) filter (where not is_ready)),
    'blocked_amount', jsonb_build_object(
      'hold',    coalesce(sum(amount) filter (where b_hold), 0),
      'invoice', coalesce(sum(amount) filter (where b_invoice), 0),
      'source',  coalesce(sum(amount) filter (where b_source), 0),
      'identity', coalesce(sum(amount) filter (where b_identity), 0),
      'parent',  coalesce(sum(amount) filter (where b_parent), 0),
      'any',     coalesce(sum(amount) filter (where not is_ready), 0)),

    'ready', count(*) filter (where is_ready),
    'ready_amount', coalesce(sum(amount) filter (where is_ready), 0),

    'by_stage', coalesce((
      select jsonb_object_agg(x.stage, jsonb_build_object(
        'subscribers', x.n, 'amount', x.amt, 'ready', x.rdy))
      from (select stage, count(*) as n, sum(amount) as amt,
                   count(*) filter (where is_ready) as rdy
            from judged group by stage) x), '{}'::jsonb),

    'by_reseller', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select j.reseller,
               count(*) as subscribers,
               sum(j.amount) as amount,
               count(*) filter (where j.stage = 'P1') as p1,
               count(*) filter (where j.stage = 'P2') as p2,
               count(*) filter (where j.stage = 'P3') as p3,
               count(*) filter (where j.stage = 'P4') as p4,
               count(*) filter (where j.b_hold) as blocked_hold,
               count(*) filter (where j.b_invoice) as blocked_invoice,
               count(*) filter (where j.b_source or j.b_identity) as blocked_eligibility,
               count(*) filter (where j.b_parent) as blocked_other,
               count(*) filter (where j.is_ready) as ready,
               coalesce(sum(j.amount) filter (where j.is_ready), 0) as ready_amount
        from judged j
        group by j.reseller
        order by sum(j.amount) desc) y), '[]'::jsonb))
  from judged
  where public.has_capability('installation.view');
$fn$;

-- ---------------------------------------------------------------------------
-- 2. حواجب اعتماد الدورة
--
-- السعر هنا لا يتغيّر إلا بتغيّر الباقة: النسخة واحدة للدورة كلّها، والنطاق
-- والعدد ثابتان في النداء. فحسابه لكل صفٍّ من 22,727 صفاً حسابٌ لخمس قيمٍ
-- مكرّرةً آلاف المرّات. يُحسب مرّةً لكل باقة، ثم يُضمّ.
-- ---------------------------------------------------------------------------

create or replace function public.commission_finalization_blockers(p_cycle_id uuid)
returns table (
  reason_code text, events integer, subscribers integer,
  indicative_amount bigint, owner_hint text, action_hint text
)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  perform public.require_capability('commission.view');
  return query
  with v as (
    select public.commission_version_for_cycle(p_cycle_id) as version_id
  ),
  open_blockers as (
    select x.reason_code, x.subscriber_key, e.profile_name
    from public.commission_exceptions x
    left join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    where x.cycle_id = p_cycle_id and x.status = 'OPEN' and x.blocks_finalization
  ),
  rate_per_package as (
    select p.profile_name,
           coalesce(public.commission_rate_for(
             (select version_id from v), 'new', 1, p.profile_name), 0) as rate
    from (select distinct profile_name from open_blockers) p
  )
  select b.reason_code::text,
    count(*)::integer,
    count(distinct b.subscriber_key)::integer,
    coalesce(sum(r.rate), 0)::bigint,
    (case b.reason_code
      when 'UNKNOWN_FDT'       then 'إدارة البيانات الرئيسية'
      when 'UNKNOWN_AGENT'     then 'إدارة البيانات الرئيسية'
      when 'UNKNOWN_PACKAGE'   then 'إدارة البيانات الرئيسية'
      when 'SOURCE_INCOMPLETE' then 'استيراد SaaS'
      when 'IDENTITY_CONFLICT' then 'مراجعة المشتركين'
      else 'مراجعة تشغيلية' end)::text,
    (case b.reason_code
      when 'UNKNOWN_FDT'       then 'صنِّف الكابينة ثم أعد حساب الدورة'
      when 'UNKNOWN_AGENT'     then 'اربط الاسم البديل بوكيل أو عرِّفه حساباً مباشراً'
      when 'UNKNOWN_PACKAGE'   then 'أضف الباقة وحدِّد صنفها'
      when 'SOURCE_INCOMPLETE' then 'أثبت اكتمال الملف أو استورد التغطية الناقصة'
      when 'IDENTITY_CONFLICT' then 'احسم الهوية المتعارضة'
      else 'راجع تفصيل الاستثناء' end)::text
  from open_blockers b
  left join rate_per_package r on r.profile_name is not distinct from b.profile_name
  group by b.reason_code
  order by 4 desc, 2 desc;
end;
$fn$;

commit;
