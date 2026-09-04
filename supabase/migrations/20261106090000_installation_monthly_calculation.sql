-- الحساب الشهري لأجور التنصيب: مصدرٌ واحد، أقساطٌ متتابعة، وحسابٌ ليس دفعاً.
--
-- ما يسدّه هذا الملف — ثلاث فجوات مقرَّرة من صاحب المنتج (ADR-034):
--
--   ١. المصدر. المشغّل كان يرفع ملفاً للتفعيل، ثم ملفاً لتدقيق الفواتير،
--      ثم يُثبِّت الاستحقاق. والملف الشهري الواحد يحمل أصلاً مشتركي الشهر
--      ودليل تفعيلهم. فصار مصدراً واحداً: saas_activation_events تبقى
--      المصدر الخام الوحيد، تغذّي محرّك العمولات كما هي بلا حرفٍ يتغيّر،
--      وتغذّي هذا المحرّك معها. لا محلِّلَين، ولا استيرادَين.
--
--   ٢. تعدّد الأحداث. preview_bulk_invoice_upload يعدّ أكثر من فاتورةٍ
--      لمشتركٍ واحدٍ في رفعةٍ واحدة «تعارضاً» ويرفضها. وهذا ليس تعارضاً في
--      النموذج المقرَّر: كل حدثٍ صالحٍ يستهلك القسط التالي. مشتركٌ يفتتح
--      الشهر عند P3 وله حدثان صالحان يأخذ P3 ثم P4 — سبعة آلاف، وينتهي عند
--      DONE. فالترتيب حتميّ: event_created_at تصاعدياً، ثم saas_event_id
--      فاصلاً عند التساوي. ولا يُمنَح قسطٌ مرّتين، ولا يُتجاوَز DONE.
--
--   ٣. الحساب ليس دفعاً. BABIL FLOW لا يدفع أجور التنصيب — الدفع في نظامٍ
--      آخر. فالنتيجة الشهرية تُحسَب وتُعرَض وتُعتمَد، ولا تُنشئ دفعةً ولا
--      قيداً ولا وسمَ «مدفوع». ولا يُدرَج صفٌّ زائفٌ في
--      installation_payment_history لتقديم مرحلة: ذلك الجدول يبقى دليل
--      الدفع التاريخي وحده. المُعتمَد الجديد له سجلّه المستقل
--      installation_calculation_awards، فيبقى التاريخيّ والمحسوب متمايزَين
--      دلالةً كما طُلب صراحةً.
--
-- وما لا يفعله هذا الملف عمداً:
--   • لا يمسّ صيغة عمولةٍ واحدة، ولا calculate_commission_cycle، ولا
--     commission_qualifying_events.
--   • لا يغيّر مبالغ P1..P4 ولا سلّم «المتبقي»: المبلغ يُقرَأ من
--     installation_stage_definitions للإصدار الحاكم، كما يقرؤه الجسر.
--   • لا يحذف ولا يعطّل المسار القديم (تدقيق الفواتير بالجملة ←
--     materialize_installation_entitlements ← دفعة ← دفتر). يبقى قائماً
--     بحرفه، ويصير مساراً تاريخياً لا مسار العمل الشهري.
--   • لا يعيد كتابة صفٍّ تاريخيّ واحد: 5,693 مشتركاً و17,117 صفَّ دفعٍ
--     يبقون كما هم حرفياً.
--
-- وقاعدة واحدة تُحكِم كل ما سبق: **لا محرّك قواعد ثانٍ**.
-- evaluate_enrollment_gate تبقى الحَكَم في الأهلية، classify_newness في
-- الجِدّة، grace_status_from_dates في المهلة، hold_is_effective في التعليق،
-- subscriber_ownership_type في العائدية، enroll_new_installation في التسجيل.
-- هذا الملف يجمعها ويُسلسل المراحل، ولا يستنسخ منها قاعدةً واحدة.
--
-- ملاحظة صلاحيات: الاعتماد يستدعي enroll_new_installation، وتلك تشترط
-- installation.enroll. فالمعتمِد يحتاج installation.calculation_approve
-- و installation.enroll معاً — وكلاهما في قالب admin. و accountant يحسب
-- ولا يعتمد، وهذا هو الفصل المقصود.
--
-- إضافي بالكامل، forward-only.

begin;

-- ---------------------------------------------------------------------------
-- ١ · الصلاحيات: الحساب قراءةٌ محسوبة، والاعتماد قرارٌ مستقلّ.
-- ---------------------------------------------------------------------------

insert into public.permission_capabilities
  (key, domain, label_ar, description, is_sensitive, is_self_protecting, scopeable)
values
  ('installation.calculate', 'installation', 'حساب نتيجة الشهر',
   'حساب أجور التنصيب من الملف الشهري بلا تغيير حالة أي مشترك', false, false, false),
  ('installation.calculation_approve', 'installation', 'اعتماد نتيجة الشهر',
   'تثبيت نتيجة الشهر وتقديم مراحل المشتركين. ليس دفعاً.', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', k
from (values ('installation.calculate'), ('installation.calculation_approve')) as c(k)
where exists (select 1 from public.role_templates where key = 'admin')
on conflict do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'accountant', 'installation.calculate'
where exists (select 1 from public.role_templates where key = 'accountant')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- ٢ · النموذج: تشغيلةٌ شهرية، وسطرٌ لكل حدث، وسجلٌّ لما اعتُمِد.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_calculation_runs (
  id uuid primary key default gen_random_uuid(),
  period text not null,
  source_batch_id uuid not null
    references public.saas_import_batches(id) on delete restrict,
  source_checksum text not null,
  status text not null default 'CALCULATED',
  subscribers_count integer not null default 0,
  events_count integer not null default 0,
  awarded_count integer not null default 0,
  total_amount bigint not null default 0,
  new_subscribers_count integer not null default 0,
  blocked_count integer not null default 0,
  unresolved_print_count integer not null default 0,
  calculated_at timestamptz not null default now(),
  calculated_by uuid not null references auth.users(id),
  calculation_request_id uuid,
  approved_at timestamptz,
  approved_by uuid references auth.users(id),
  approval_request_id uuid,
  -- نتيجةٌ واحدةٌ لكل (شهر، مصدر): إعادة الحساب تُحدِّث هذه لا تُنشئ ثانية.
  constraint installation_calculation_runs_source_key unique (period, source_batch_id),
  constraint installation_calculation_runs_period_check
    check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  constraint installation_calculation_runs_status_check
    check (status in ('CALCULATED', 'NEEDS_REVIEW', 'READY_TO_APPROVE', 'APPROVED')),
  constraint installation_calculation_runs_approved_is_attributed
    check (status <> 'APPROVED' or (approved_at is not null and approved_by is not null)),
  constraint installation_calculation_runs_counts_check
    check (subscribers_count >= 0 and events_count >= 0 and awarded_count >= 0
           and total_amount >= 0 and new_subscribers_count >= 0
           and blocked_count >= 0 and unresolved_print_count >= 0)
);

-- شهرٌ واحدٌ معتمَد: مصدرٌ ثانٍ لنفس الشهر لا يُعتمَد فوق الأول.
create unique index if not exists installation_calculation_runs_approved_period_uidx
  on public.installation_calculation_runs (period) where status = 'APPROVED';

create index if not exists installation_calculation_runs_batch_idx
  on public.installation_calculation_runs (source_batch_id);
create index if not exists installation_calculation_runs_status_idx
  on public.installation_calculation_runs (status);

comment on table public.installation_calculation_runs is
  'نتيجة حساب أجور التنصيب لشهرٍ من مصدرٍ واحد. حسابٌ لا دفع: لا دفعة ولا قيد ولا وسم مدفوع.';

create table if not exists public.installation_calculation_lines (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null
    references public.installation_calculation_runs(id) on delete cascade,
  subscriber_key text not null,
  activation_event_id text,
  sequence_in_subscriber integer not null default 1,
  event_at timestamptz,
  scheme_version_id uuid references public.installation_scheme_versions(id),
  opening_stage text,
  awarded_stage text,
  closing_stage text,
  amount bigint not null default 0,
  registry_hit boolean not null default false,
  source_parent_name text,
  agent_id_at_calculation uuid references public.agents(id),
  parent_agent_id_at_calculation uuid references public.agents(id),
  outcome text not null,
  reason_code text,
  evidence jsonb not null default '{}'::jsonb,
  approved boolean not null default false,
  created_at timestamptz not null default now(),
  -- حدثٌ واحدٌ يُحسَب مرّةً واحدةً في التشغيلة، مهما تكرّر في الملف.
  constraint installation_calculation_lines_event_key unique (run_id, activation_event_id),
  constraint installation_calculation_lines_subscriber_check
    check (btrim(subscriber_key) <> ''),
  constraint installation_calculation_lines_outcome_check
    check (outcome in ('AWARDED', 'NO_STAGE_REMAINING', 'BLOCKED', 'NEEDS_REVIEW')),
  constraint installation_calculation_lines_stage_check
    check ((awarded_stage is null or awarded_stage in ('P1', 'P2', 'P3', 'P4'))
           and (opening_stage is null or opening_stage in ('P1', 'P2', 'P3', 'P4', 'DONE'))
           and (closing_stage is null or closing_stage in ('P1', 'P2', 'P3', 'P4', 'DONE'))),
  -- المنح وحده يحمل مرحلةً ممنوحة، والمنح وحده يحمل مالاً.
  constraint installation_calculation_lines_awarded_shape
    check ((outcome = 'AWARDED') = (awarded_stage is not null)),
  constraint installation_calculation_lines_amount_shape
    check ((outcome = 'AWARDED' and amount > 0) or (outcome <> 'AWARDED' and amount = 0)),
  -- السطر المستبعَد يحمل سببه دائماً. لا استبعاد بلا سبب.
  constraint installation_calculation_lines_reason_shape
    check (outcome = 'AWARDED' or btrim(coalesce(reason_code, '')) <> ''),
  constraint installation_calculation_lines_approved_is_awarded
    check (not approved or outcome = 'AWARDED')
);

create index if not exists installation_calculation_lines_run_idx
  on public.installation_calculation_lines (run_id);
create index if not exists installation_calculation_lines_subscriber_idx
  on public.installation_calculation_lines (subscriber_key);
create index if not exists installation_calculation_lines_outcome_idx
  on public.installation_calculation_lines (run_id, outcome);
create index if not exists installation_calculation_lines_agent_idx
  on public.installation_calculation_lines (agent_id_at_calculation);

comment on table public.installation_calculation_lines is
  'سطرُ حسابٍ لكل حدث تفعيل: الافتتاح والممنوح والإغلاق والمبلغ والـPrint وقت الحساب وسبب الاستبعاد.';

-- سجلّ ما اعتُمِد فعلاً — منفصلٌ دلالةً عن installation_payment_history.
-- ذاك دليل دفعٍ تاريخي، وهذا قسطٌ حسبه النظام واعتُمِد. لا يختلطان.
create table if not exists public.installation_calculation_awards (
  id uuid primary key default gen_random_uuid(),
  subscriber_key text not null,
  stage text not null,
  period text not null,
  amount bigint not null,
  run_id uuid not null
    references public.installation_calculation_runs(id) on delete restrict,
  line_id uuid not null
    references public.installation_calculation_lines(id) on delete restrict,
  activation_event_id text,
  approved_at timestamptz not null default now(),
  approved_by uuid not null references auth.users(id),
  -- القاعدة المالية الأصعب في هذا النطاق: قسطٌ واحدٌ لكل (مشترك، مرحلة)
  -- عبر كل التشغيلات وكل الأشهر. مفتاحٌ فريد لا فحصٌ سابقٌ للكتابة.
  constraint installation_calculation_awards_stage_key unique (subscriber_key, stage),
  constraint installation_calculation_awards_stage_check
    check (stage in ('P1', 'P2', 'P3', 'P4')),
  constraint installation_calculation_awards_amount_check check (amount > 0),
  constraint installation_calculation_awards_period_check
    check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$')
);

create index if not exists installation_calculation_awards_run_idx
  on public.installation_calculation_awards (run_id);
create index if not exists installation_calculation_awards_subscriber_idx
  on public.installation_calculation_awards (subscriber_key);

comment on table public.installation_calculation_awards is
  'قسطٌ محسوبٌ ومعتمَد. ليس دفعاً ولا دليلَ دفع — الدفع في نظامٍ آخر. مفتاحه يمنع منح المرحلة مرّتين.';

-- ---------------------------------------------------------------------------
-- ٣ · الدليل لا يُعدَّل بعد الاعتماد.
--
-- ترتيبُ الاعتماد مقصود: الأسطر تُوسَم أولاً ثم تُوسَم التشغيلة. فحين
-- تُوسَم الأسطر تكون التشغيلة بعدُ READY_TO_APPROVE فيمرّ التحديث، وبعدها
-- يُغلق البابُ على الاثنين معاً.
-- ---------------------------------------------------------------------------

create or replace function public.protect_approved_calculation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_status text;
begin
  if tg_table_name = 'installation_calculation_runs' then
    v_status := old.status;
  else
    select r.status into v_status from public.installation_calculation_runs r
    where r.id = old.run_id;
  end if;

  if v_status = 'APPROVED' then
    raise exception
      'An approved monthly calculation is immutable evidence and cannot be % (%)',
      lower(tg_op), old.id
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$fn$;

drop trigger if exists trg_protect_approved_calculation_run
  on public.installation_calculation_runs;
create trigger trg_protect_approved_calculation_run
  before update or delete on public.installation_calculation_runs
  for each row execute function public.protect_approved_calculation();

drop trigger if exists trg_protect_approved_calculation_line
  on public.installation_calculation_lines;
create trigger trg_protect_approved_calculation_line
  before update or delete on public.installation_calculation_lines
  for each row execute function public.protect_approved_calculation();

create or replace function public.protect_calculation_award()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  raise exception 'An approved instalment award is append-only and cannot be % (%)',
    lower(tg_op), old.id using errcode = '42501';
end;
$fn$;

drop trigger if exists trg_protect_calculation_award
  on public.installation_calculation_awards;
create trigger trg_protect_calculation_award
  before update or delete on public.installation_calculation_awards
  for each row execute function public.protect_calculation_award();

-- ---------------------------------------------------------------------------
-- ٤ · RLS: قراءةٌ بصلاحية، ولا كتابةَ متصفّحٍ إطلاقاً.
-- ---------------------------------------------------------------------------

alter table public.installation_calculation_runs enable row level security;
alter table public.installation_calculation_lines enable row level security;
alter table public.installation_calculation_awards enable row level security;

revoke all on table public.installation_calculation_runs from authenticated;
revoke all on table public.installation_calculation_runs from anon;
revoke all on table public.installation_calculation_lines from authenticated;
revoke all on table public.installation_calculation_lines from anon;
revoke all on table public.installation_calculation_awards from authenticated;
revoke all on table public.installation_calculation_awards from anon;

grant select on table public.installation_calculation_runs to authenticated;
grant select on table public.installation_calculation_lines to authenticated;
grant select on table public.installation_calculation_awards to authenticated;

drop policy if exists installation_calculation_runs_select
  on public.installation_calculation_runs;
create policy installation_calculation_runs_select on public.installation_calculation_runs
  for select to authenticated using ((select public.has_capability('installation.view')));

drop policy if exists installation_calculation_lines_select
  on public.installation_calculation_lines;
create policy installation_calculation_lines_select on public.installation_calculation_lines
  for select to authenticated using ((select public.has_capability('installation.view')));

drop policy if exists installation_calculation_awards_select
  on public.installation_calculation_awards;
create policy installation_calculation_awards_select on public.installation_calculation_awards
  for select to authenticated using ((select public.has_capability('installation.view')));

-- ---------------------------------------------------------------------------
-- ٥ · أهلية الحدث للحساب — البوابة نفسها، بفارقٍ واحدٍ مُبرَّر.
--
-- evaluate_enrollment_gate بُنيت لسؤال «هل يُسجَّل هذا المشترك؟». وسؤالنا
-- «هل يستحقّ هذا الحدث قسطاً؟». الفارق موانعُ التسجيل وحدها: مَن هو في
-- السجل أصلاً «مسجَّل» و«قائم» بطبيعته، وهذان ليسا سبباً لحجب قسطه —
-- بل هما شرطُه. والقاعدة المعتمدة صراحةً (installation-fees-business-rules
-- §5.1): إصابةُ السجل حاسمة، فتصنيف الجِدّة لا يُسأل عنه أصلاً لمن فيه.
--
-- وكل ما عدا ذلك يبقى مانعاً بحرفه: الباقة، والإلغاء، والدفعة المُلغاة أو
-- غير المكتملة، والهوية، والعائدية، واسم المصدر غير المحسوم. ويُضاف إليها
-- ما يخصّ المال دون التسجيل: التعليق الفعّال، وحالةٌ غير محسومة، ومهلةُ
-- تفعيلٍ منقضية لمن ليس في السجل.
-- ---------------------------------------------------------------------------

create or replace function public.installation_event_eligibility(
  p_username_key text,
  p_event_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username_key, '')));
  v_gate jsonb;
  v_blockers text[] := array[]::text[];
  v_registry boolean;
  v_blocker text;
  v_state public.installation_subscriber_state%rowtype;
  v_sub_uuid uuid;
  v_ref record;
  v_grace text;
begin
  v_gate := public.evaluate_enrollment_gate(v_key, p_event_id);

  select s.id into v_sub_uuid from public.installation_subscribers s
  where s.subscriber_key = v_key;
  v_registry := v_sub_uuid is not null;

  for v_blocker in select jsonb_array_elements_text(v_gate -> 'blockers')
  loop
    -- موانع التسجيل وحده. مَن في السجل مسجَّلٌ وقائمٌ بحكم وجوده فيه.
    if v_registry and v_blocker in (
      'ALREADY_ENROLLED', 'SUBSCRIBER_IS_EXISTING',
      'NOT_CLASSIFIED', 'CLASSIFICATION_NEEDS_REVIEW') then
      continue;
    end if;
    -- الحدث الذي فتح تسجيلَ هذا المشترك نفسه ليس «مستهلَكاً من غيره»،
    -- وإلا فقد المشترك قسطه الأول عند إعادة حساب المصدر نفسه.
    if v_blocker = 'EVENT_ALREADY_USED'
       and exists (select 1 from public.installation_enrollments en
                   where en.first_qualifying_event_id = p_event_id
                     and pg_catalog.lower(pg_catalog.btrim(en.subscriber_id)) = v_key) then
      continue;
    end if;
    v_blockers := v_blockers || v_blocker;
  end loop;

  -- تعليقٌ فعّال: لا مال بالصمت.
  if exists (
    select 1 from public.installation_holds h
    where pg_catalog.lower(pg_catalog.btrim(h.subscriber_id)) = v_key
      and public.hold_is_effective(h.status, h.permanence, h.expires_at))
  then
    v_blockers := v_blockers || 'SUBSCRIBER_ON_HOLD'::text;
  end if;

  if v_registry then
    -- العائدية المعتمدة للقائم — نفس المِحمول الذي يستعمله مسار الاستحقاق
    -- القائم. وهو مقصورٌ على السجل ببنيته: subscriber_ownership_type يصل إلى
    -- installation_subscribers في فرعيه معاً ثم يقع على NEEDS_REVIEW لمن ليس
    -- فيه. فلو سألناه عن مشتركٍ جديد لأجاب «تحت المراجعة» دائماً، ولاستحال
    -- على أيّ جديدٍ مؤهَّلٍ أن يدخل عند P1 أبداً.
    -- وعائديةُ الجديد تحكمها بوابةُ التسجيل وحدها — فيها أصلاً
    -- DIRECT_COMPANY_NOT_ELIGIBLE و UNKNOWN_PARENT و EFFECTIVE_AGENT_UNRESOLVED
    -- و PARENT_NEEDS_REVIEW. فلا محرّك ثانٍ، ولا سؤالَ محمولٍ عمّا لا يعرفه.
    if public.subscriber_ownership_type(v_key) is distinct from 'RESELLER' then
      v_blockers := v_blockers || 'OWNERSHIP_NOT_RESELLER'::text;
    end if;

    select * into v_state from public.installation_subscriber_state
    where subscriber_uuid = v_sub_uuid;
    if not found then
      v_blockers := v_blockers || 'STATE_MISSING'::text;
    elsif v_state.resolution <> 'resolved' then
      v_blockers := v_blockers || 'STATE_UNRESOLVED'::text;
    end if;
  else
    -- مهلة التفعيل المعتمدة: ثلاثون يوماً من أول واقعة مصدرٍ إلى تفعيلٍ
    -- مؤهِّلٍ مدفوع، مع التجاوز المدقَّق القائم. لا نسخةً ثانية منها.
    select d.reference_at, d.qualifying_at into v_ref
    from public.installation_reference_dates(v_key) d;
    v_grace := public.grace_status_from_dates(
      v_ref.reference_at, v_ref.qualifying_at,
      exists (select 1 from public.grace_period_overrides o where o.username_key = v_key));
    if v_grace = 'GRACE_EXPIRED_REVIEW' then
      v_blockers := v_blockers || 'GRACE_EXPIRED_REVIEW'::text;
    end if;
  end if;

  return jsonb_build_object(
    'username_key', v_key,
    'event_id', p_event_id,
    'registry_hit', v_registry,
    'allowed', cardinality(v_blockers) = 0,
    'blockers', to_jsonb(v_blockers),
    'gate_blockers', v_gate -> 'blockers');
end;
$fn$;

comment on function public.installation_event_eligibility(text, text) is
  'أهلية حدثٍ لاستهلاك قسط: بوابة التسجيل نفسها بلا موانع التسجيل لمن في السجل، مضافاً إليها التعليق والعائدية والحالة والمهلة.';

revoke execute on function public.installation_event_eligibility(text, text) from public;
revoke execute on function public.installation_event_eligibility(text, text) from anon;
grant execute on function public.installation_event_eligibility(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- ٦ · ملخّص التشغيلة: النتيجة، وتجميع الـPrint، وتجميع الأب.
--
-- التجميعان يخرجان من نفس الأسطر لا من حسابَين، فيتطابقان بالبناء لا
-- بالمصادفة: parent_agent_id_at_calculation هو agent_root_id للـPrint نفسه.
-- ---------------------------------------------------------------------------

create or replace function public.installation_calculation_run_summary(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_run public.installation_calculation_runs%rowtype;
begin
  perform public.require_capability('installation.view');

  select * into v_run from public.installation_calculation_runs where id = p_run_id;
  if not found then
    raise exception 'Calculation run % was not found', p_run_id using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'run_id', v_run.id,
    'period', v_run.period,
    'source_batch_id', v_run.source_batch_id,
    'status', v_run.status,
    'subscribers', v_run.subscribers_count,
    'events', v_run.events_count,
    'awarded', v_run.awarded_count,
    'total_amount', v_run.total_amount,
    'new_subscribers', v_run.new_subscribers_count,
    'blocked', v_run.blocked_count,
    'unresolved_print_count', v_run.unresolved_print_count,
    'approved_at', v_run.approved_at,
    'stages', coalesce((
      select jsonb_object_agg(t.awarded_stage, t.n)
      from (select l.awarded_stage, count(*) as n
            from public.installation_calculation_lines l
            where l.run_id = p_run_id and l.outcome = 'AWARDED'
            group by l.awarded_stage) t), '{}'::jsonb),
    'reasons', coalesce((
      select jsonb_object_agg(t.reason_code, t.n)
      from (select l.reason_code, count(*) as n
            from public.installation_calculation_lines l
            where l.run_id = p_run_id and l.outcome <> 'AWARDED'
              and l.reason_code is not null
            group by l.reason_code) t), '{}'::jsonb),
    'by_print', coalesce((
      select jsonb_agg(s.t order by s.t ->> 'print_name')
      from (select jsonb_build_object(
              'agent_id', l.agent_id_at_calculation,
              'print_name', max(a.official_name),
              'parent_agent_id', l.parent_agent_id_at_calculation,
              'subscribers', count(distinct l.subscriber_key),
              'awarded', count(*),
              'amount', sum(l.amount)) as t
            from public.installation_calculation_lines l
            left join public.agents a on a.id = l.agent_id_at_calculation
            where l.run_id = p_run_id and l.outcome = 'AWARDED'
            group by l.agent_id_at_calculation, l.parent_agent_id_at_calculation) s),
      '[]'::jsonb),
    'by_parent', coalesce((
      select jsonb_agg(s.t order by s.t ->> 'parent_name')
      from (select jsonb_build_object(
              'parent_agent_id', l.parent_agent_id_at_calculation,
              'parent_name', max(a.official_name),
              'prints', count(distinct l.agent_id_at_calculation),
              'subscribers', count(distinct l.subscriber_key),
              'awarded', count(*),
              'amount', sum(l.amount)) as t
            from public.installation_calculation_lines l
            left join public.agents a on a.id = l.parent_agent_id_at_calculation
            where l.run_id = p_run_id and l.outcome = 'AWARDED'
            group by l.parent_agent_id_at_calculation) s),
      '[]'::jsonb));
end;
$fn$;

comment on function public.installation_calculation_run_summary(uuid) is
  'ملخّص نتيجة الشهر: المراحل والأسباب وتجميع الـPrint وتجميع الأب — من نفس الأسطر فيتطابقان بالبناء.';

revoke execute on function public.installation_calculation_run_summary(uuid) from public;
revoke execute on function public.installation_calculation_run_summary(uuid) from anon;
grant execute on function public.installation_calculation_run_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- ٧ · المعاينة: تحسب ولا تُغيّر حالة مشتركٍ واحد.
--
-- كل ما تكتبه هذه الدالة صفوفُ التشغيلة وأسطرها — وكلاهما جدولٌ جديد.
-- installation_subscribers و installation_subscriber_state و
-- installation_enrollments و installation_payment_history لا تُلمَس هنا
-- بحرف. فالمشغّل يرى النتيجة كاملةً قبل أن يلتزم بها.
--
-- وإعادة التشغيل على المصدر نفسه تُعيد بناء الأسطر لا تُضاعفها: تشغيلةٌ
-- واحدةٌ لكل (شهر، مصدر)، وأسطرُها تُمسَح وتُبنى. والمعتمَدة لا تُمَسّ.
--
-- وقيدُ التخزين: installation_subscriber_state يشترط أن يكون «المتبقي»
-- إحدى قيم السلّم القياسي حصراً (installation_stage_for_remaining بلا
-- ELSE). فإصدارُ مخطّطٍ بمبالغ أخرى يُحسَب صحيحاً هنا لكنه لا يُخزَّن
-- عند الاعتماد. فنكشفه في المعاينة بسببٍ صريح بدل أن ينفجر قيدُ جدول
-- عند الاعتماد.
-- ---------------------------------------------------------------------------

create or replace function public.preview_installation_calculation(
  p_period text,
  p_batch_id uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_batch public.saas_import_batches%rowtype;
  v_run public.installation_calculation_runs%rowtype;
  v_run_id uuid;
  v_sub record;
  v_ev record;
  v_elig jsonb;
  v_registry boolean;
  v_state public.installation_subscriber_state%rowtype;
  v_sub_uuid uuid;
  v_version uuid;
  v_stage text;
  v_next text;
  v_open text;
  v_terminal boolean;
  v_amount bigint;
  v_remaining bigint;
  v_seq integer;
  v_agent uuid;
  v_outcome text;
  v_reason text;
  v_awarded_stage text;
  v_closing text;
  v_sub_block text;
  v_subs integer := 0;
  v_events integer := 0;
  v_new integer := 0;
  v_gated integer := 0;
begin
  perform public.require_capability('installation.calculate');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Period must be YYYY-MM' using errcode = '22023';
  end if;

  select * into v_batch from public.saas_import_batches where id = p_batch_id;
  if not found then
    raise exception 'Import batch % was not found', p_batch_id using errcode = 'P0002';
  end if;
  if v_batch.source_kind <> 'ACTIVATION_EVENTS' then
    raise exception 'Only an activation-events source can be calculated' using errcode = '22023';
  end if;
  if v_batch.status = 'voided' then
    raise exception 'A voided import batch cannot be calculated' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('inst-calc:' || p_period || ':' || p_batch_id::text, 0));

  select * into v_run from public.installation_calculation_runs
  where period = p_period and source_batch_id = p_batch_id;

  if found and v_run.status = 'APPROVED' then
    -- المعتمَد دليلٌ ثابت. إعادة الحساب فوقه ممنوعة، لا صامتة.
    raise exception
      'The result for % is already approved and cannot be recalculated', p_period
      using errcode = '42501';
  end if;

  if found then
    v_run_id := v_run.id;
    delete from public.installation_calculation_lines where run_id = v_run_id;
    update public.installation_calculation_runs
    set status = 'CALCULATED', calculated_at = now(), calculated_by = v_actor,
        calculation_request_id = p_request_id, source_checksum = v_batch.source_checksum
    where id = v_run_id;
  else
    insert into public.installation_calculation_runs (
      period, source_batch_id, source_checksum, calculated_by, calculation_request_id)
    values (p_period, p_batch_id, v_batch.source_checksum, v_actor, p_request_id)
    returning id into v_run_id;
  end if;

  for v_sub in
    select e.username_key
    from public.saas_activation_events e
    where e.import_batch_id = p_batch_id
    group by e.username_key
    order by e.username_key
  loop
    v_subs := v_subs + 1;
    v_sub_block := null;
    v_seq := 0;
    v_remaining := null;

    select s.id into v_sub_uuid from public.installation_subscribers s
    where s.subscriber_key = v_sub.username_key;
    v_registry := v_sub_uuid is not null;

    v_version := public.installation_scheme_version_for_subscriber(v_sub.username_key);
    if v_version is null then
      v_sub_block := 'NO_EFFECTIVE_SCHEME_VERSION';
      v_stage := null;
    elsif v_registry then
      select * into v_state from public.installation_subscriber_state
      where subscriber_uuid = v_sub_uuid;
      if not found then
        v_sub_block := 'STATE_MISSING';
        v_stage := null;
      elsif v_state.resolution <> 'resolved' or v_state.current_stage is null then
        v_sub_block := 'STATE_UNRESOLVED';
        v_stage := null;
      else
        -- المشترك القائم يبدأ من مرحلته الملتزَمة. لا أحد يعود إلى P1.
        v_stage := v_state.current_stage;
        v_remaining := v_state.remaining;
      end if;
    else
      select d.code into v_stage
      from public.installation_stage_definitions d
      where d.scheme_version_id = v_version and not d.is_terminal
      order by d.sequence limit 1;
      if v_stage is null then
        v_sub_block := 'SCHEME_HAS_NO_OPENING_STAGE';
      else
        select coalesce(sum(d.amount), 0) into v_remaining
        from public.installation_stage_definitions d
        where d.scheme_version_id = v_version and not d.is_terminal;
      end if;
    end if;

    v_open := v_stage;

    for v_ev in
      select e.saas_event_id, e.event_created_at, e.raw_parent
      from public.saas_activation_events e
      where e.import_batch_id = p_batch_id and e.username_key = v_sub.username_key
      -- الترتيب المقرَّر: الزمن أولاً، ثم معرّف الحدث فاصلاً حتمياً.
      order by e.event_created_at nulls last, e.saas_event_id
    loop
      v_seq := v_seq + 1;
      v_events := v_events + 1;
      v_agent := null;
      v_awarded_stage := null;
      v_closing := v_stage;
      v_amount := 0;
      v_reason := null;

      select a.agent_id into v_agent from public.resolve_parent_alias(v_ev.raw_parent) a;

      v_elig := public.installation_event_eligibility(v_sub.username_key, v_ev.saas_event_id);

      if v_sub_block is not null then
        v_outcome := 'NEEDS_REVIEW';
        v_reason := v_sub_block;
      elsif not (v_elig ->> 'allowed')::boolean then
        v_outcome := 'BLOCKED';
        v_reason := (select string_agg(b, ',' order by b)
                     from jsonb_array_elements_text(v_elig -> 'blockers') b);
      elsif exists (select 1 from public.installation_calculation_awards w
                    where w.subscriber_key = v_sub.username_key and w.stage = v_stage) then
        -- مرحلةٌ مُنحت واعتُمدت سلفاً في شهرٍ سابق: لا تُمنَح ثانيةً أبداً.
        v_outcome := 'BLOCKED';
        v_reason := 'STAGE_ALREADY_AWARDED';
      else
        select d.is_terminal into v_terminal
        from public.installation_stage_definitions d
        where d.scheme_version_id = v_version and d.code = v_stage;

        if v_stage is null or coalesce(v_terminal, true) then
          -- انتهت الأقساط. الحدث التالي لا يُنشئ مالاً — ولا يُعدّ خطأً.
          v_outcome := 'NO_STAGE_REMAINING';
          v_reason := 'INSTALMENTS_COMPLETE';
        else
          v_amount := public.stage_amount_for_version(v_version, v_stage);
          v_next := public.next_stage_for_version(v_version, v_stage);
          if v_amount is null or v_amount <= 0 or v_next is null then
            v_outcome := 'NEEDS_REVIEW';
            v_reason := 'SCHEME_STAGE_NOT_PRICEABLE';
            v_amount := 0;
          elsif v_remaining is null
                or public.installation_stage_for_remaining(v_remaining - v_amount)
                     is distinct from v_next then
            -- المخطّط سليمٌ حسابياً لكنه لا يُمثَّل في تخزين الحالة القائم.
            v_outcome := 'NEEDS_REVIEW';
            v_reason := 'SCHEME_NOT_REPRESENTABLE_IN_STORAGE';
            v_amount := 0;
          else
            v_outcome := 'AWARDED';
            v_awarded_stage := v_stage;
            v_remaining := v_remaining - v_amount;
            v_stage := v_next;
            v_closing := v_next;
          end if;
        end if;
      end if;

      insert into public.installation_calculation_lines (
        run_id, subscriber_key, activation_event_id, sequence_in_subscriber, event_at,
        scheme_version_id, opening_stage, awarded_stage, closing_stage, amount,
        registry_hit, source_parent_name, agent_id_at_calculation,
        parent_agent_id_at_calculation, outcome, reason_code, evidence)
      values (
        v_run_id, v_sub.username_key, v_ev.saas_event_id, v_seq, v_ev.event_created_at,
        v_version, v_open, v_awarded_stage, v_closing, coalesce(v_amount, 0),
        v_registry, v_ev.raw_parent, v_agent,
        case when v_agent is null then null else public.agent_root_id(v_agent) end,
        v_outcome, v_reason, v_elig)
      on conflict on constraint installation_calculation_lines_event_key do nothing;

      v_open := v_closing;
    end loop;

    if not v_registry and exists (
      select 1 from public.installation_calculation_lines l
      where l.run_id = v_run_id and l.subscriber_key = v_sub.username_key
        and l.outcome = 'AWARDED')
    then
      v_new := v_new + 1;
    end if;
  end loop;

  -- الحاجز الذي يمنع الاعتماد: من لا نعرف مالكه لا يُعتمَد شهرُه.
  select count(*) into v_gated
  from public.installation_calculation_lines l
  where l.run_id = v_run_id
    and l.reason_code is not null
    and (l.reason_code like '%PARENT_NEEDS_REVIEW%'
         or l.reason_code like '%UNKNOWN_PARENT%'
         or l.reason_code like '%EFFECTIVE_AGENT_UNRESOLVED%');

  update public.installation_calculation_runs r
  set subscribers_count = v_subs,
      events_count = v_events,
      new_subscribers_count = v_new,
      unresolved_print_count = v_gated,
      awarded_count = (select count(*) from public.installation_calculation_lines l
                       where l.run_id = v_run_id and l.outcome = 'AWARDED'),
      total_amount = (select coalesce(sum(l.amount), 0)
                      from public.installation_calculation_lines l
                      where l.run_id = v_run_id and l.outcome = 'AWARDED'),
      blocked_count = (select count(*) from public.installation_calculation_lines l
                       where l.run_id = v_run_id and l.outcome in ('BLOCKED', 'NEEDS_REVIEW')),
      status = case when v_gated > 0 then 'NEEDS_REVIEW' else 'READY_TO_APPROVE' end
  where r.id = v_run_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.calculation.previewed', 'awarded', '0',
    (select awarded_count::text from public.installation_calculation_runs where id = v_run_id),
    'installation_calculation_run', v_run_id, p_request_id,
    'period=' || p_period || ' batch=' || p_batch_id::text
      || ' unresolved_print_lines=' || v_gated::text)
  on conflict do nothing;

  return public.installation_calculation_run_summary(v_run_id);
end;
$fn$;

comment on function public.preview_installation_calculation(text, uuid, uuid) is
  'يحسب نتيجة الشهر من المصدر الواحد بلا لمس حالة أي مشترك. قابل لإعادة التشغيل، ولا يُعاد فوق نتيجة معتمَدة.';

revoke execute on function public.preview_installation_calculation(text, uuid, uuid) from public;
revoke execute on function public.preview_installation_calculation(text, uuid, uuid) from anon;
grant execute on function public.preview_installation_calculation(text, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- ٨ · اعتماد نتيجة الشهر — التزامٌ لا دفع.
--
-- «اعتماد نتيجة الشهر» يعني: هذا ما حُسِب، وهذه مراحل المشتركين للشهر
-- القادم. لا دفعة، لا دفعة سداد، لا قيد دفتر، لا وسم «مدفوع».
--
-- والتقدّم يُثبَّت مرّةً واحدة: مفتاح (مشترك، مرحلة) في سجلّ المُعتمَد يرفع
-- unique_violation عند أي تكرار فتسقط المعاملة كلها. والتسجيل الجديد يمرّ
-- بـenroll_new_installation نفسها لا بمسارٍ ثانٍ، فتُقيَّم البوابة داخل
-- المعاملة كما تُقيَّم دائماً.
--
-- وتحديث الحالة يمسّ remaining و received_total معاً: قيدُ الجدول يشترط
-- total_amount − received_total = remaining. هذه مسكُ دفاترِ سُلّمٍ لا
-- تسجيلُ دفع — لا صفَّ في installation_payment_history ولا في أي جدول دفع.
-- ---------------------------------------------------------------------------

create or replace function public.approve_installation_calculation(
  p_run_id uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_run public.installation_calculation_runs%rowtype;
  v_sub record;
  v_line public.installation_calculation_lines%rowtype;
  v_sub_uuid uuid;
  v_state public.installation_subscriber_state%rowtype;
  v_first_event text;
  v_new_remaining bigint;
  v_new integer := 0;
  v_awarded integer := 0;
  v_total bigint := 0;
begin
  perform public.require_capability('installation.calculation_approve');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('inst-calc-approve:' || p_run_id::text, 0));

  select * into v_run from public.installation_calculation_runs where id = p_run_id;
  if not found then
    raise exception 'Calculation run % was not found', p_run_id using errcode = 'P0002';
  end if;

  -- اعتمادٌ ثانٍ لنفس التشغيلة لا يفعل شيئاً ولا يفشل.
  if v_run.status = 'APPROVED' then
    return jsonb_build_object(
      'run_id', p_run_id, 'period', v_run.period, 'status', 'APPROVED',
      'replayed', true, 'awarded', v_run.awarded_count, 'total_amount', v_run.total_amount,
      'new_subscribers', v_run.new_subscribers_count);
  end if;

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('run_id', p_run_id, 'replayed', true);
  end if;

  if v_run.status = 'NEEDS_REVIEW' then
    raise exception
      'Run % still has unresolved source/Print names; resolve them before approval', p_run_id
      using errcode = '42501';
  end if;

  for v_sub in
    select distinct l.subscriber_key
    from public.installation_calculation_lines l
    where l.run_id = p_run_id and l.outcome = 'AWARDED'
    order by 1
  loop
    select s.id into v_sub_uuid from public.installation_subscribers s
    where s.subscriber_key = v_sub.subscriber_key;

    if v_sub_uuid is null then
      -- تسجيل المشترك الجديد المؤهَّل: البوابة القائمة تُقيَّم داخلها.
      select l.activation_event_id into v_first_event
      from public.installation_calculation_lines l
      where l.run_id = p_run_id and l.subscriber_key = v_sub.subscriber_key
        and l.outcome = 'AWARDED'
      order by l.sequence_in_subscriber limit 1;

      perform public.enroll_new_installation(
        v_sub.subscriber_key, v_first_event, null,
        public.uuid_from_parts(p_request_id,
          pg_catalog.md5('enroll:' || v_sub.subscriber_key)::uuid));
      v_new := v_new + 1;

      select s.id into v_sub_uuid from public.installation_subscribers s
      where s.subscriber_key = v_sub.subscriber_key;
      if v_sub_uuid is null then
        raise exception 'Enrolment did not open an installation state for %',
          v_sub.subscriber_key using errcode = 'P0002';
      end if;
    end if;

    for v_line in
      select * from public.installation_calculation_lines
      where run_id = p_run_id and subscriber_key = v_sub.subscriber_key
        and outcome = 'AWARDED'
      order by sequence_in_subscriber
    loop
      select * into v_state from public.installation_subscriber_state
      where subscriber_uuid = v_sub_uuid for update;
      if not found then
        raise exception 'Subscriber % has no installation state to advance',
          v_sub.subscriber_key using errcode = 'P0002';
      end if;

      -- انحرافُ الحالة بين الحساب والاعتماد يُسقط المعاملة، ولا يُصحَّح صامتاً.
      if v_state.current_stage is distinct from v_line.awarded_stage then
        raise exception
          'Stage drift for %: state is % but the run awards %; recalculate before approving',
          v_sub.subscriber_key, coalesce(v_state.current_stage, 'NULL'), v_line.awarded_stage
          using errcode = '55006';
      end if;

      -- دليل الدفع التاريخي لا يُنافَس: مرحلةٌ فيه لا تُحسب ثانيةً.
      if exists (select 1 from public.installation_payment_history h
                 where h.subscriber_uuid = v_sub_uuid and h.stage = v_line.awarded_stage) then
        raise exception
          'Stage % of % is already historical paid evidence and cannot be awarded again',
          v_line.awarded_stage, v_sub.subscriber_key using errcode = '23505';
      end if;

      v_new_remaining := v_state.remaining - v_line.amount;
      if v_new_remaining is null or v_new_remaining < 0
         or public.installation_stage_for_remaining(v_new_remaining)
              is distinct from v_line.closing_stage then
        raise exception
          'Advancing % to % would leave a remaining balance the state store cannot represent',
          v_sub.subscriber_key, v_line.closing_stage using errcode = '23514';
      end if;

      insert into public.installation_calculation_awards (
        subscriber_key, stage, period, amount, run_id, line_id,
        activation_event_id, approved_by)
      values (
        v_sub.subscriber_key, v_line.awarded_stage, v_run.period, v_line.amount,
        p_run_id, v_line.id, v_line.activation_event_id, v_actor);

      -- مسك دفاتر السلّم: المتبقي والمستلَم معاً، وإلا سقط قيد الجدول.
      update public.installation_subscriber_state
      set remaining = v_new_remaining,
          received_total = coalesce(v_state.received_total, 0) + v_line.amount,
          current_stage = v_line.closing_stage,
          payment_eligible = (v_line.closing_stage in ('P1', 'P2', 'P3', 'P4')),
          as_of_date = greatest(v_state.as_of_date,
                                coalesce(v_line.event_at::date, current_date)),
          updated_by = v_actor,
          updated_at = now()
      where subscriber_uuid = v_sub_uuid;

      -- ومرحلة التسجيل تتبع الحالة، وإلا منع حارس التسلسل ما بعدها.
      update public.installation_enrollments
      set current_stage_code = v_line.closing_stage,
          status = case when v_line.closing_stage = 'DONE' then 'COMPLETED' else status end
      where subscriber_id = v_sub.subscriber_key
        and current_stage_code is distinct from v_line.closing_stage;

      v_awarded := v_awarded + 1;
      v_total := v_total + v_line.amount;
    end loop;
  end loop;

  update public.installation_calculation_lines
  set approved = true
  where run_id = p_run_id and outcome = 'AWARDED';

  update public.installation_calculation_runs
  set status = 'APPROVED', approved_at = now(), approved_by = v_actor,
      approval_request_id = p_request_id
  where id = p_run_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id,
    after_data, request_id, extra)
  values (v_actor, 'installation.calculation.approved', 'status',
    v_run.status, 'APPROVED', 'installation_calculation_run', p_run_id,
    jsonb_build_object('period', v_run.period, 'awarded', v_awarded,
      'total_amount', v_total, 'new_subscribers', v_new),
    p_request_id,
    'period=' || v_run.period || ' awarded=' || v_awarded::text
      || ' amount=' || v_total::text || ' new=' || v_new::text);

  return jsonb_build_object(
    'run_id', p_run_id, 'period', v_run.period, 'status', 'APPROVED',
    'replayed', false, 'awarded', v_awarded, 'total_amount', v_total,
    'new_subscribers', v_new);
end;
$fn$;

comment on function public.approve_installation_calculation(uuid, uuid) is
  'اعتماد نتيجة الشهر: يُسجّل الجدد ويُثبّت مرحلة كل مشترك للشهر القادم. ليس دفعاً — لا دفعة ولا قيد ولا وسم مدفوع.';

revoke execute on function public.approve_installation_calculation(uuid, uuid) from public;
revoke execute on function public.approve_installation_calculation(uuid, uuid) from anon;
grant execute on function public.approve_installation_calculation(uuid, uuid) to authenticated;


-- دوالّ الزنادات لا تُستدعى نداءً، فلا صلاحيةَ تنفيذٍ لها لأحد.
revoke execute on function public.protect_approved_calculation() from public;
revoke execute on function public.protect_approved_calculation() from anon;
revoke execute on function public.protect_approved_calculation() from authenticated;
revoke execute on function public.protect_calculation_award() from public;
revoke execute on function public.protect_calculation_award() from anon;
revoke execute on function public.protect_calculation_award() from authenticated;

commit;
