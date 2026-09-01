-- Free P1: مكافأة اشتراك مجاني واحد فوق عتبة نشاط، باعتماد صاحب المنتج الصريح
-- (FREE-001..006 في docs/MASTER_REQUIREMENTS_REGISTER.md، القرار المسجَّل في
-- docs/BUSINESS_DECISIONS_REQUIRED.md وADR الخاص به في docs/DECISIONS.md).
--
-- القاعدة المعتمدة حرفياً من صاحب المنتج:
--   NEW ZONE: P1 مجاني واحد لكل FDT مؤهِّل فوق العتبة — كل كابينة مستقلة، لا تجميع
--             بين عدة كابينات NEW ZONE عند تحديد الاستحقاق.
--   OLD ZONE: P1 مجاني واحد لكل موزّع (reseller) بإجمالي كل كابيناته في OLD ZONE
--             معاً فوق العتبة — لا يُحسَب لكل كابينة OLD ZONE على حدة.
--
-- لماذا لا تُبنى آلية تجميع جديدة: محرّك العمولة الحالي يحسم هذا التمييز نفسه أصلاً
-- (commission_scheme_versions.new_zone_scope='FDT'، old_zone_scope='AGENT') —
-- فـcommission_cycle_snapshots تُخزَّن بالفعل صفاً واحداً لكل FDT في NEW ZONE
-- وصفاً واحداً لكل وكيل (reseller) بإجمالي مشتركيه في OLD ZONE — هذا بالضبط تعريف
-- "reseller total" المعتمد، لا حساباً موازياً قد ينحرف عنه. Free P1 يقرأ هذه
-- اللقطة المعتمدة (finalized_at is not null) بدل إعادة اشتقاق العدّ.
--
-- العتبة (350 اليوم): قابلة للتهيئة (FREE-003)، لا رقماً حرفياً متناثراً في الكود.
-- مربوطة بمحور إصدار المخطط (scheme_version_id) نفسه الذي تُبنى عليه كل الشرائح،
-- فيبقى كل منح تاريخي يحمل قيمة العتبة التي طُبِّقت بها فعلياً (FREE-006) عبر عمود
-- free_p1_grants.rule_threshold المُلتقَط وقت المنح — لا عبر مرجع حي قد يتغيّر لاحقاً.
--
-- تعريف "العميل الفعّال" (FREE-004): نفس تعريف DEC-001 المعتمد فعلاً في محرّك
-- العمولة (UNIQUE_ACTIVATED_SUBSCRIBERS) — commission_cycle_snapshots.unique_activated_subscribers
-- هو نفسه العدد المستعمل، لا تعريف مواز.
--
-- Free P1 أهلية/عرض فقط، دائماً — قرار نهائي (ADR-031)، لا تأجيل بانتظار حسم
-- مالي لاحق. لا يُبنى هنا، ولن يُبنى لاحقاً ضمن هذا القرار، أي مسار يحوّل منح
-- Free P1 إلى قيد مالي فعلي: لا دفعة، لا رصيد، لا إعفاء مرحلة تنصيب، لا دخول
-- دفعات سداد، لا قيد دفتر أستاذ، لا وسم "مدفوع"، ولا تصحيح/عكس. هذه المهاجرة
-- تبني طبقة الاستحقاق فقط، بصلاحية دفع صفرية بنيوياً: حتمية، مدقَّقة، ومحمية
-- من الازدواج على مستوى القيد نفسه (constraint، لا فحص تطبيقي وحده).
--
-- forward-only. لا صف مالي قائم يُمَس، ولا دورة عمولة تُعاد حسابها.

begin;

-- ---------------------------------------------------------------------------
-- 1. قدرة مخصّصة لمنح Free P1، منفصلة عن commission.finalize.
-- ---------------------------------------------------------------------------

-- permission_capabilities.key يفرض ^[a-z_]+[.][a-z_]+$ (نقطة واحدة، بلا أرقام) —
-- لذا لا يمكن استخدام "free_p1" (يحوي رقماً) أو ثلاثة مقاطع؛ الاسم البديل هنا
-- "free_bonus" يشير لنفس المفهوم دون مخالفة قيد التسمية القائم في المشروع.
insert into public.permission_capabilities
  (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable) values
  ('commission.grant_free_bonus',     'commission', 'منح Free P1',        true, false, false),
  ('commission.configure_free_bonus', 'commission', 'تهيئة عتبة Free P1', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', c.key from public.permission_capabilities c
where c.key in ('commission.grant_free_bonus', 'commission.configure_free_bonus')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. عتبة قابلة للتهيئة، مربوطة بإصدار المخطط — لا تُنشئ محور إصدار موازياً.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_free_p1_rules (
  id uuid primary key default gen_random_uuid(),
  scheme_version_id uuid not null unique
    references public.commission_scheme_versions(id) on delete cascade,
  threshold integer not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint commission_free_p1_rules_threshold_check check (threshold > 0)
);

create trigger trg_free_p1_rule_updated
before update on public.commission_free_p1_rules
for each row execute function public.set_updated_at();

-- تحديث العتبة يمرّ بدالة، لا بكتابة مباشرة — يطابق منع الكتابة المباشرة لأي
-- تهيئة مالية في هذا المشروع (ADR-010).
create or replace function public.set_free_p1_threshold(
  p_scheme_version_id uuid,
  p_threshold integer,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_existing public.audit_logs%rowtype;
  v_before integer;
begin
  perform public.require_capability('commission.configure_free_bonus');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_threshold is null or p_threshold <= 0 then
    raise exception 'threshold must be a positive integer' using errcode = '22023';
  end if;
  if not exists (select 1 from public.commission_scheme_versions where id = p_scheme_version_id) then
    raise exception 'Commission scheme version was not found' using errcode = 'P0002';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select threshold into v_before from public.commission_free_p1_rules
  where scheme_version_id = p_scheme_version_id;

  insert into public.commission_free_p1_rules (scheme_version_id, threshold, created_by, updated_by)
  values (p_scheme_version_id, p_threshold, v_actor, v_actor)
  on conflict (scheme_version_id) do update
    set threshold = excluded.threshold, updated_by = excluded.updated_by;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, request_id)
  values (
    v_actor, 'commission.free_p1.threshold_set', 'threshold',
    v_before::text, p_threshold::text,
    'commission_scheme_version', p_scheme_version_id, p_request_id);

  return jsonb_build_object('replayed', false, 'request_id', p_request_id,
    'scheme_version_id', p_scheme_version_id, 'threshold', p_threshold);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. منح Free P1 نفسه.
--
-- هوية القيد الفريدة (cycle_id, scope_type, scope_id) هي الضمانة ضد الازدواج —
-- على مستوى قاعدة البيانات، لا فحصاً في الدالة وحدها يمكن أن يُتجاوز.
-- ---------------------------------------------------------------------------

create table if not exists public.free_p1_grants (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.commission_cycles(id) on delete cascade,
  scheme_version_id uuid not null references public.commission_scheme_versions(id),
  rule_threshold integer not null,
  zone text not null,
  scope_type text not null,
  scope_id text not null,
  scope_label text,
  unique_activated_subscribers integer not null,
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default now(),
  constraint free_p1_grants_identity unique (cycle_id, scope_type, scope_id),
  constraint free_p1_grants_zone_check check (zone in ('old', 'new')),
  constraint free_p1_grants_scope_check check (scope_type in ('AGENT', 'FDT')),
  -- NEW ZONE لكل FDT فقط، OLD ZONE لكل وكيل (reseller) فقط — لا تركيبة أخرى.
  constraint free_p1_grants_zone_scope_match check (
    (zone = 'new' and scope_type = 'FDT') or (zone = 'old' and scope_type = 'AGENT')),
  constraint free_p1_grants_threshold_check check (rule_threshold > 0),
  -- حتى لو أخطأت الدالة، لا يمكن لصفٍّ عند العتبة أو تحتها أن يُكتب أصلاً.
  -- القاعدة المعتمدة حرفياً من صاحب المنتج: "greater than 350" — 350 نفسها
  -- غير مؤهِّلة، 351 هي أول قيمة مؤهِّلة. عامل المقارنة > صريح، لا >=.
  constraint free_p1_grants_meets_threshold check (unique_activated_subscribers > rule_threshold)
);

create index if not exists free_p1_grants_cycle_idx on public.free_p1_grants (cycle_id);

comment on table public.free_p1_grants is
  'Free P1 eligibility/display record only — permanently, by owner decision (ADR-031). Never a payment/credit record: no payable amount, no payment batch, no ledger entry, no correction/reversal mechanics. See docs/BUSINESS_DECISIONS_REQUIRED.md § FREE-004.';

create or replace function public.grant_free_p1(
  p_cycle_id uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_threshold integer;
  v_existing public.audit_logs%rowtype;
  v_eligible integer := 0;
  v_granted integer := 0;
begin
  perform public.require_capability('commission.grant_free_bonus');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  -- يقرأ فقط اللقطة المعتمدة، لا يُعاد اشتقاق العدّ ولا يُقبل على دورة غير مُعتمَدة.
  if v_cycle.finalized_at is null then
    raise exception 'Free P1 can only be granted for a finalized cycle' using errcode = '42501';
  end if;

  select threshold into v_threshold
  from public.commission_free_p1_rules
  where scheme_version_id = v_cycle.scheme_version_id;
  if not found then
    -- فشل صريح، لا عتبة افتراضية مخترعة — راجع set_free_p1_threshold أولاً.
    raise exception 'No Free P1 threshold configured for scheme version %', v_cycle.scheme_version_id
      using errcode = 'P0002';
  end if;

  -- عتبة صاحب القرار حرفية: "greater than 350" — 350 نفسها غير مؤهِّلة، 351
  -- أول قيمة مؤهِّلة. عامل > صريح هنا، لا >=؛ ويطابقه free_bonus_eligibility()
  -- أدناه حرفياً — كلاهما يجب أن يتغيّر معاً، وتثبت ذلك
  -- tests/sql/free-p1.sql عبر مقارنة حيّة بين الدالتين، لا افتراضاً.
  select count(*) into v_eligible
  from public.commission_cycle_snapshots s
  where s.cycle_id = p_cycle_id
    and s.finalized_at is not null
    and s.unique_activated_subscribers > v_threshold
    and ((s.zone = 'new' and s.scope_type = 'FDT') or (s.zone = 'old' and s.scope_type = 'AGENT'));

  insert into public.free_p1_grants (
    cycle_id, scheme_version_id, rule_threshold, zone, scope_type, scope_id,
    scope_label, unique_activated_subscribers, granted_by)
  select p_cycle_id, v_cycle.scheme_version_id, v_threshold,
         s.zone, s.scope_type, s.scope_id, s.scope_label, s.unique_activated_subscribers, v_actor
  from public.commission_cycle_snapshots s
  where s.cycle_id = p_cycle_id
    and s.finalized_at is not null
    and s.unique_activated_subscribers > v_threshold
    and ((s.zone = 'new' and s.scope_type = 'FDT') or (s.zone = 'old' and s.scope_type = 'AGENT'))
  on conflict (cycle_id, scope_type, scope_id) do nothing;
  get diagnostics v_granted = row_count;

  insert into public.audit_logs (
    actor_id, action, field, new_value,
    entity_type, entity_id, request_id, extra)
  values (
    v_actor, 'commission.free_p1.granted', 'free_p1_grants', v_granted::text,
    'commission_cycle', p_cycle_id, p_request_id,
    'threshold=' || v_threshold::text || ' eligible=' || v_eligible::text
    || ' newly_granted=' || v_granted::text
    || ' already_granted=' || (v_eligible - v_granted)::text);

  return jsonb_build_object(
    'replayed', false, 'request_id', p_request_id,
    'cycle_id', p_cycle_id, 'threshold', v_threshold,
    'eligible_scopes', v_eligible, 'newly_granted', v_granted,
    'already_granted', v_eligible - v_granted);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3ب. عرض الأهلية للقراءة فقط — بلا كتابة، بلا سلطة دفع (ADR-031، FREE-004).
--
-- النظام "يحسب ويعرض من هو مؤهَّل" بحسب صاحب القرار — لا يجوز أن يبقى هذا
-- مرهوناً بأن يشغّل أحدٌ يملك صلاحية المنح grant_free_p1() أولاً؛ لذا هذه
-- دالة مستقلة للقراءة فقط، بصلاحية العرض العادية (commission.view) لا صلاحية
-- المنح، تُعيد نفس الصفوف التي كانت grant_free_p1() ستمنحها، دون أن تكتب
-- أي شيء. المعيار (>) يجب أن يبقى مطابقاً حرفياً لمعيار grant_free_p1() —
-- tests/sql/free-p1.sql يثبت التطابق بتشغيل حيّ للدالتين معاً على نفس البيانات،
-- لا بمقارنة نص الكود.
-- ---------------------------------------------------------------------------

create or replace function public.free_bonus_eligibility(p_cycle_id uuid)
returns table (
  scope_type text,
  scope_id text,
  scope_label text,
  zone text,
  unique_activated_subscribers integer,
  threshold integer,
  free_p1_count integer
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  perform public.require_capability('commission.view');

  return query
  select s.scope_type, s.scope_id, s.scope_label, s.zone,
         s.unique_activated_subscribers, r.threshold,
         1 as free_p1_count
  from public.commission_cycle_snapshots s
  join public.commission_cycles c on c.id = s.cycle_id
  join public.commission_free_p1_rules r on r.scheme_version_id = c.scheme_version_id
  where s.cycle_id = p_cycle_id
    and c.finalized_at is not null
    and s.finalized_at is not null
    and s.unique_activated_subscribers > r.threshold
    and ((s.zone = 'new' and s.scope_type = 'FDT') or (s.zone = 'old' and s.scope_type = 'AGENT'))
  order by s.zone, s.scope_label;
end;
$fn$;

comment on function public.free_bonus_eligibility(uuid) is
  'Read-only Free P1 eligibility display for a cycle. No write, no payment authority — informational only (ADR-031). Mirrors grant_free_p1()''s eligibility predicate exactly; keep both in sync.';

-- ---------------------------------------------------------------------------
-- 4. بذر عتبة V1 المعتمدة (350) لإصدار المخطط المنشور اليوم.
--
-- لا رقم مخترع: القيمة معتمدة صراحة من صاحب المنتج. تُربَط بإصدار المخطط
-- المنشور الوحيد اليوم (COMMISSION_STANDARD v1)، لا بكل الإصدارات مستقبلاً —
-- إصدار مستقبلي جديد يحتاج عتبته الخاصة عبر set_free_p1_threshold صراحة.
-- ---------------------------------------------------------------------------

do $$
declare
  v_version uuid;
begin
  select v.id into v_version
  from public.commission_scheme_versions v
  join public.commission_schemes s on s.id = v.scheme_id
  where s.code = 'COMMISSION_STANDARD' and v.version = 1;

  if v_version is not null then
    insert into public.commission_free_p1_rules (scheme_version_id, threshold)
    values (v_version, 350)
    on conflict (scheme_version_id) do nothing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. الحماية والصلاحيات — نفس نمط بقية جداول محرّك العمولة.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['commission_free_p1_rules', 'free_p1_grants'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    -- has_capability مُغلَّفة بـ(select ...) لتُقيَّم مرة واحدة (InitPlan) لا لكل
    -- صف — يفرضه tests/sql/rls-capability-scope.sql منذ 20260827120000.
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select public.has_capability(''commission.view'')))',
      t || '_select', t);
  end loop;
end;
$$;

revoke execute on function public.set_free_p1_threshold(uuid, integer, uuid) from public, anon;
grant execute on function public.set_free_p1_threshold(uuid, integer, uuid) to authenticated;
revoke execute on function public.grant_free_p1(uuid, uuid) from public, anon;
grant execute on function public.grant_free_p1(uuid, uuid) to authenticated;
revoke execute on function public.free_bonus_eligibility(uuid) from public, anon;
grant execute on function public.free_bonus_eligibility(uuid) to authenticated;

commit;
