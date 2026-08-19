-- عائدية المشترك، مؤرَّخة بالفترة.
--
-- المشكلة. العائدية اليوم تُشتقّ من الأب الخام لحظةَ القراءة، فتغييرها اليوم
-- يُعيد تفسير أحداث الأمس. مثال المستخدم:
--
--   ١–١٥ آب   المشترك تابع لـFTTH User  → لا عمولة وكيل
--   ١٦ آب فصاعداً  تابع للوكيل أ         → عمولة للوكيل أ
--
-- تفعيل يوم ١٠ آب يخصّ الشركة، وتفعيل يوم ٢٠ آب يخصّ الوكيل أ. ونقلُ
-- العائدية اليوم يجب ألّا يُعيد كتابة الأمس أبداً.
--
-- النموذج: فترات صريحة لا حالة واحدة. كل فترة تقول من يملك المشترك ومتى
-- بدأت ومتى انتهت ولماذا ومن نفّذها.
--
-- ثلاث قواعد تحكم التصميم:
--
--   ١. الجدول يبدأ فارغاً، والاشتقاق القديم يبقى الاحتياطَ لكل مدى لا تغطّيه
--      فترة صريحة. فالنتائج المالية القائمة لا تتغيّر بحرف — وهذا مُختبَر
--      على تموز بأرقامها المعتمدة.
--
--   ٢. FTTH User وOffice شركةٌ مباشرة مالياً. المفهوم المالي DIRECT_COMPANY
--      يبقى كما هو ولا يُمسّ؛ وهذان نوعان تشغيليان تحته يُميَّزان في العرض
--      والتصفية فقط. فلا عمولة وكيل، ولا مساهمة في شريحة، ولا استثناء
--      «وكيل مجهول» — لأن الأب معروف ومستبعَد عن عمد لا مجهول.
--
--   ٣. لا تصنيف يُخمَّن من نصّ. تُزرع هنا العائدية المُثبتة وحدها: الاسمان
--      البديلان اللذان يحملان أصلاً resolution = 'direct_company'. أما
--      hrins.office وoffice.1 المرصودان في البيانات فيبقيان قراراً بشرياً
--      يُتَّخذ في الشاشة، لا سطراً أكتبه أنا.

begin;

-- ---------------------------------------------------------------------------
-- 1. الأنواع التشغيلية
-- ---------------------------------------------------------------------------

create table if not exists public.subscriber_ownership (
  id uuid primary key default gen_random_uuid(),
  username_key text not null,
  ownership_type text not null,
  agent_id uuid references public.agents(id) on delete restrict,
  effective_from timestamptz not null,
  effective_to timestamptz,
  reason text not null,
  performed_by uuid references public.profiles(id),
  request_id uuid,
  created_at timestamptz not null default now(),

  constraint subscriber_ownership_type_check
    check (ownership_type in ('RESELLER', 'FTTH_USER', 'OFFICE', 'NEEDS_REVIEW')),

  -- الوكيل مطلوب للوكالة وحدها. النوع الشركاتي بلا وكيل بالتعريف، وربطه
  -- بوكيل يفتح باب عمولة لا يستحقّها.
  constraint subscriber_ownership_agent_shape
    check ((ownership_type = 'RESELLER' and agent_id is not null)
        or (ownership_type <> 'RESELLER' and agent_id is null)),

  constraint subscriber_ownership_range_check
    check (effective_to is null or effective_to > effective_from)
);

create index if not exists subscriber_ownership_key_idx
  on public.subscriber_ownership (username_key, effective_from desc);

-- لا فترتان متناقضتان لمشترك واحد. التداخل يعني إجابتين عن سؤال واحد،
-- وفي المال لا تُقبل إجابتان.
create extension if not exists btree_gist;
alter table public.subscriber_ownership
  drop constraint if exists subscriber_ownership_no_overlap;
alter table public.subscriber_ownership
  add constraint subscriber_ownership_no_overlap
  exclude using gist (
    username_key with =,
    tstzrange(effective_from, effective_to, '[)') with &&
  );

alter table public.subscriber_ownership enable row level security;

drop policy if exists subscriber_ownership_select on public.subscriber_ownership;
create policy subscriber_ownership_select on public.subscriber_ownership
  for select using ((select public.has_capability('subscriber.view')));

revoke all on public.subscriber_ownership from public, anon;
grant select on public.subscriber_ownership to authenticated;

-- ---------------------------------------------------------------------------
-- 2. الحلّ عند لحظة الحدث
--
-- الفترة الصريحة تسود على مداها وحده. وما لا تغطّيه فترة يعود إلى الاشتقاق
-- القائم من الأب الخام — فالتاريخ الذي لا سجلّ صريح له يبقى مقروءاً كما كان.
-- ---------------------------------------------------------------------------

create or replace function public.subscriber_ownership_at(
  p_username_key text, p_at timestamptz)
returns table (ownership_type text, agent_id uuid, source text)
language sql stable set search_path = ''
as $fn$
  select o.ownership_type, o.agent_id, 'EXPLICIT'::text
  from public.subscriber_ownership o
  where o.username_key = p_username_key
    and o.effective_from <= p_at
    and (o.effective_to is null or o.effective_to > p_at)
  order by o.effective_from desc
  limit 1;
$fn$;

grant execute on function public.subscriber_ownership_at(text, timestamptz) to authenticated;

/** النوع التشغيلي الحالي لمشترك، للعرض والتصفية. */
create or replace function public.subscriber_ownership_type(p_subscriber_id text)
returns text
language sql stable set search_path = ''
as $fn$
  select coalesce(
    (select o.ownership_type
     from public.subscriber_ownership o
     join public.installation_subscribers s on s.subscriber_key = o.username_key
     where s.subscriber_id = p_subscriber_id
       and o.effective_from <= now()
       and (o.effective_to is null or o.effective_to > now())
     order by o.effective_from desc limit 1),
    -- الاحتياط: التصنيف المشتقّ القائم.
    (select case
       when si.source_classification = 'DIRECT_COMPANY' then 'FTTH_USER'
       when si.source_classification = 'RESELLER' then 'RESELLER'
       else 'NEEDS_REVIEW' end
     from public.subscriber_identities si
     join public.installation_subscribers s2 on s2.subscriber_key = si.username_key
     where s2.subscriber_id = p_subscriber_id limit 1),
    'NEEDS_REVIEW');
$fn$;

grant execute on function public.subscriber_ownership_type(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. النوع التشغيلي لاسم أبٍ خام
--
-- يُستعمل في الطوابير والعرض. الاسمان المرصودان يحملان direct_company أصلاً،
-- فتصنيفهما FTTH_USER قراءةٌ لما هو مُثبت لا تصنيفٌ جديد.
-- ---------------------------------------------------------------------------

create or replace function public.parent_ownership_type(p_raw_parent text)
returns text
language sql stable set search_path = ''
as $fn$
  -- الأب بلا اسم بديل ليس شركةً ولا وكالة: هو قرارٌ لم يُتَّخذ بعد.
  -- وإعادة NULL هنا كانت تُسقط الصفّ من التجميع بدل أن تُظهره للمراجعة.
  select coalesce(
    (select case
       when al.agent_id is not null then 'RESELLER'
       when al.resolution = 'direct_company' then 'FTTH_USER'
       when al.resolution = 'office' then 'OFFICE'
       else 'NEEDS_REVIEW' end
     from public.agent_aliases al
     where al.alias_key = lower(btrim(coalesce(p_raw_parent, '')))
       and al.active
     limit 1),
    'NEEDS_REVIEW');
$fn$;
grant execute on function public.parent_ownership_type(text) to authenticated;

-- الاسم البديل يقبل 'office' نوعاً صريحاً، فيُصنَّف من الشاشة لا بالتخمين.
alter table public.agent_aliases drop constraint if exists agent_aliases_resolution_check;
alter table public.agent_aliases add constraint agent_aliases_resolution_check
  check (resolution in ('mapped', 'direct_company', 'office', 'needs_review'));

-- ---------------------------------------------------------------------------
-- 4. عرض العائدية التشغيلية
--
-- يبني على commission_qualifying_events دون تغيير أي قاعدة فيه: نفس المنطقة،
-- ونفس النطاق، ونفس التصنيف المالي. المضاف عمودٌ تشغيلي واحد يُميّز
-- FTTH User عن Office عن الوكيل — للعرض والتصفية لا للحساب.
-- ---------------------------------------------------------------------------

create or replace view public.subscriber_event_ownership as
select
  q.saas_event_id,
  q.username_key,
  q.event_created_at,
  q.raw_parent,
  q.effective_agent_id,
  q.source_classification,
  coalesce(
    (select ownership_type from public.subscriber_ownership_at(q.username_key, q.event_created_at)),
    public.parent_ownership_type(q.raw_parent),
    'NEEDS_REVIEW') as ownership_type,
  coalesce(
    (select agent_id from public.subscriber_ownership_at(q.username_key, q.event_created_at)),
    q.effective_agent_id) as owning_agent_id
from public.commission_qualifying_events q;

revoke all on public.subscriber_event_ownership from public, anon;
grant select on public.subscriber_event_ownership to authenticated;

-- ---------------------------------------------------------------------------
-- 5. عدّاد الشركة — لبطاقتَي الرئيسية
-- ---------------------------------------------------------------------------

create or replace function public.company_subscriber_counts()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $fn$
declare v jsonb;
begin
  perform public.require_capability('subscriber.view');
  select jsonb_object_agg(t, n) into v from (
    select public.parent_ownership_type(e.raw_parent) as t,
           count(distinct e.username_key) as n
    from public.saas_activation_events e
    where coalesce(e.canceled, false) = false
    group by 1) x;
  return coalesce(v, '{}'::jsonb);
end;
$fn$;

revoke execute on function public.company_subscriber_counts() from public, anon;
grant execute on function public.company_subscriber_counts() to authenticated;

commit;
