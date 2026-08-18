-- تقسية وفهرسة — كلٌّ منهما مبنيّ على قياس لا على ظنّ.
--
-- الفهرس. المقياس على الإنتاج الحقيقي (57,522 حدثاً، 22 ميغابايت):
--
--   Seq Scan on saas_activation_events
--     (actual time=2.466..516.036 rows=29246)
--     Rows Removed by Filter: 28276
--
-- وهذا المرشِّح هو مدخل كل حساب دورة: كل استدعاء لـcalculate_commission_cycle
-- يبدأ بنافذة التاريخ. اليوم يستبعد نصف الجدول، ومع تراكم الشهور تزداد
-- انتقائيته لا تنقص — شهر واحد من اثني عشر يعني استبعاد 92%.
--
-- ولم يُضَف غيره. تحقّقنا من البقية فوجدناها مغطّاة سلفاً:
--   financial_ledger_source_idx (domain, source_table, source_id)
--     يخدم commission_scope_payable مباشرة.
--   subscriber_identities_username_idx وagent_aliases_alias_key وfdts.code
--     وpackages.code تخدم وصلات commission_qualifying_events كلها.
--
-- التقسية. تدقيق شامل أعاد نتيجة نظيفة إلا بنداً واحداً:
--   set_updated_at قابلة للتنفيذ من anon وpublic.
-- وهي دالة مُشغِّل تُستعمل في أربعة مُشغِّلات، والمُشغِّل لا يحتاج صلاحية
-- تنفيذ ليعمل — يعمل بصلاحيات مالك الجدول. فالمنحة زائدة وتُسحَب.
--
-- forward-only. لا بيانات تتغيّر.

begin;

-- ---------------------------------------------------------------------------
-- 1. الفهرس المُثبَت بالقياس.
--
-- concurrently غير ممكن داخل معاملة، والجدول 22 ميغابايت فالقفل قصير.
-- ---------------------------------------------------------------------------

create index if not exists saas_activation_events_created_idx
  on public.saas_activation_events (event_created_at);

-- ---------------------------------------------------------------------------
-- 2. سحب منحة زائدة.
-- ---------------------------------------------------------------------------

revoke execute on function public.set_updated_at() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. سقف نتائج للقراءات الواسعة.
--
-- التقارير محدودة سلفاً بوسائطها. هذه الدالة تُعطي الواجهة صفحاتٍ من الأحداث
-- بدل أن تسحب 57,522 صفاً في طلب واحد — وهو ما كانت ستفعله قراءةٌ مباشرة.
-- ---------------------------------------------------------------------------

create or replace function public.commission_cycle_events_page(
  p_cycle_id uuid,
  p_scope_type text default null,
  p_scope_id text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  activation_event_id text, subscriber_key text, package_code text,
  tier_code text, amount bigint, event_at timestamptz, status text,
  total_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select e.activation_event_id, e.subscriber_key, e.package_code, e.tier_code,
         e.amount, e.event_at, e.status,
         count(*) over ()::bigint
  from public.commission_event_entitlements e
  where e.cycle_id = p_cycle_id
    and (p_scope_type is null or e.scope_type = p_scope_type)
    and (p_scope_id is null or e.scope_id = p_scope_id)
    and public.has_capability('commission.view')
  order by e.event_at nulls last, e.activation_event_id
  -- السقف مفروض هنا لا في الواجهة: طلبٌ يسأل مليوناً يحصل على المسموح.
  limit least(greatest(coalesce(p_limit, 100), 1), 500)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke execute on function
  public.commission_cycle_events_page(uuid, text, text, integer, integer) from public, anon;
grant execute on function
  public.commission_cycle_events_page(uuid, text, text, integer, integer) to authenticated;

commit;
