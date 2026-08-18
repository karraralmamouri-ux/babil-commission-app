-- طبقة البيانات الأساسية: بيانات رئيسية + تاريخ SaaS خام + سجل مشتركين + مطابقة.
--
-- لا تُنشئ هذه المهاجرة أي استحقاق مالي ولا دفعة ولا تمسّ صفاً مالياً قائماً.
-- الأساس المالي التاريخي (5693 مشتركاً و17117 دفعة) يبقى كما هو حرفياً؛ السجل
-- الجديد يشير إليه ولا يستبدله.
--
-- القرارات المعتمدة المطبَّقة هنا:
--   • الباقة مجهولة الدلالة تبقى UNKNOWN ولا تُنتج مالاً تلقائياً.
--   • أب غير معروف يصير UNKNOWN_PARENT للمراجعة، ولا يُنشئ وكيلاً صامتاً.
--   • اكتمال المصدر يبدأ UNKNOWN، فلا تُصنَّف NEW من تساوي الأعداد وحده.
--   • ct_password لا يُخزَّن إطلاقاً — يُسقَط عند التحليل.
--
-- forward-only. إضافية بالكامل.

begin;

-- ---------------------------------------------------------------------------
-- 1. الوكيل القانوني وأسماؤه البديلة.
--
-- الهوية المالية لا تعتمد على الاسم المعروض. الأسماء البديلة بيانات تُدار من
-- النظام، لا شروط في الكود: الملفات الحقيقية تُظهر 46 و41 و49 قيمة أب مختلفة
-- في ثلاثة ملفات، والمجموعة تتغيّر بين شهر وآخر.
-- ---------------------------------------------------------------------------

create table if not exists public.agents (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  official_name text not null,
  status text not null default 'active',
  zone text,
  notes text,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agents_code_key unique (code),
  constraint agents_code_check check (btrim(code) <> ''),
  constraint agents_name_check check (btrim(official_name) <> ''),
  constraint agents_status_check check (status in ('active', 'inactive')),
  constraint agents_zone_check check (zone is null or zone in ('old', 'new', 'both', 'direct'))
);

create table if not exists public.agent_aliases (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid references public.agents(id) on delete restrict,
  alias text not null,
  alias_key text not null generated always as (pg_catalog.lower(pg_catalog.btrim(alias))) stored,
  alias_kind text not null default 'saas_parent',
  -- الأب غير المعروف يُسجَّل كصف بلا وكيل، فيبقى مرئياً للمراجعة بدل أن
  -- يختفي أو يُنشئ وكيلاً لم يقرّره أحد.
  resolution text not null default 'mapped',
  active boolean not null default true,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agent_aliases_key unique (alias_key),
  constraint agent_aliases_alias_check check (btrim(alias) <> ''),
  constraint agent_aliases_kind_check check (alias_kind in ('saas_parent', 'display', 'legacy')),
  constraint agent_aliases_resolution_check
    check (resolution in ('mapped', 'direct_company', 'needs_review')),
  -- ربط مؤكد يستلزم وكيلاً؛ والمراجعة أو الشركة المباشرة لا وكيل لها.
  constraint agent_aliases_shape
    check (
      (resolution = 'mapped' and agent_id is not null)
      or (resolution <> 'mapped' and agent_id is null)
    )
);

create index if not exists agent_aliases_agent_idx on public.agent_aliases (agent_id);
create index if not exists agent_aliases_resolution_idx on public.agent_aliases (resolution);

-- ---------------------------------------------------------------------------
-- 2. الكابينات.
-- ---------------------------------------------------------------------------

create table if not exists public.fdts (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  label text,
  zone text,
  agent_id uuid references public.agents(id) on delete set null,
  status text not null default 'active',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fdts_code_key unique (code),
  constraint fdts_code_check check (btrim(code) <> ''),
  constraint fdts_status_check check (status in ('active', 'inactive')),
  constraint fdts_zone_check check (zone is null or zone in ('old', 'new'))
);

-- ---------------------------------------------------------------------------
-- 3. الباقات والخدمات — دلالة فقط، لا أهلية مالية.
--
-- الأهلية المالية تخص الإعدادات المُصدَّرة في طور لاحق. هنا تُسجَّل الدلالة
-- وحدها، وأي باقة مجهولة تبقى UNKNOWN فلا تُنتج مالاً بالصمت.
-- ---------------------------------------------------------------------------

create table if not exists public.packages (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text,
  semantic_category text not null default 'UNKNOWN',
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint packages_code_key unique (code),
  constraint packages_code_check check (btrim(code) <> ''),
  constraint packages_category_check
    check (semantic_category in ('PAID_PACKAGE', 'DEBT_SERVICE', 'OTHER', 'UNKNOWN', 'DEPRECATED'))
);

-- ---------------------------------------------------------------------------
-- 4. دفعات الاستيراد.
--
-- البصمة تكشف الملف نفسه باسم مختلف. الاكتمال يبدأ UNKNOWN: الملفات الحقيقية
-- لا تُعلن فترة تغطيتها، والحدود المرصودة من البيانات لا تُثبت الاكتمال.
-- ---------------------------------------------------------------------------

create table if not exists public.saas_import_batches (
  id uuid primary key default gen_random_uuid(),
  source_kind text not null,
  source_filename text not null,
  source_checksum text not null,
  parser_version text not null,
  observed_min_created_at timestamptz,
  observed_max_created_at timestamptz,
  declared_coverage_start date,
  declared_coverage_end date,
  completeness_status text not null default 'UNKNOWN',
  sheet_results jsonb not null default '[]'::jsonb,
  source_row_count integer not null default 0,
  imported_row_count integer not null default 0,
  duplicate_count integer not null default 0,
  warning_count integer not null default 0,
  error_count integer not null default 0,
  status text not null default 'draft',
  imported_by uuid not null references auth.users(id),
  imported_at timestamptz not null default now(),
  constraint saas_import_batches_kind_check
    check (source_kind in ('USERS_SNAPSHOT', 'ACTIVATION_EVENTS')),
  constraint saas_import_batches_completeness_check
    check (completeness_status in ('UNKNOWN', 'PARTIAL', 'COMPLETE')),
  constraint saas_import_batches_status_check
    check (status in ('draft', 'imported', 'failed', 'rejected')),
  constraint saas_import_batches_checksum_key unique (source_checksum, source_kind),
  constraint saas_import_batches_checksum_check check (btrim(source_checksum) <> '')
);

-- ---------------------------------------------------------------------------
-- 5. لقطات حالة المستخدم — غير قابلة للتعديل.
--
-- لا صف واحد متغيّر: enabled وexpiration يتغيّران، ولقطة الشهر المغلق يجب أن
-- تبقى قابلة للاستعلام. ct_password غير موجود هنا عمداً ولن يُخزَّن.
-- ---------------------------------------------------------------------------

create table if not exists public.saas_user_snapshots (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.saas_import_batches(id) on delete restrict,
  snapshot_at timestamptz not null,
  saas_user_id text not null,
  username text not null,
  username_key text not null generated always as (pg_catalog.lower(pg_catalog.btrim(username))) stored,
  enabled boolean,
  expiration timestamptz,
  parent_name text,
  profile_name text,
  saas_created_at timestamptz,
  last_online timestamptz,
  contract_id text,
  group_name text,
  company text,
  -- حقول هوية حسّاسة: تُحفظ للمراجعة المصرّح بها فقط، ولا تُعرض في قراءة عامة.
  phone text,
  national_id text,
  -- الطوبولوجيا: النص الخام يبقى دائماً، والمحلَّل يبقى فارغاً عند الشك.
  topology_raw text,
  fdt_code text,
  fat_code text,
  port_code text,
  created_at timestamptz not null default now(),
  constraint saas_user_snapshots_identity_key unique (import_batch_id, saas_user_id),
  constraint saas_user_snapshots_user_check check (btrim(saas_user_id) <> ''),
  constraint saas_user_snapshots_username_check check (btrim(username) <> '')
);

create index if not exists saas_user_snapshots_user_idx
  on public.saas_user_snapshots (saas_user_id, snapshot_at desc);
create index if not exists saas_user_snapshots_username_idx
  on public.saas_user_snapshots (username_key);

-- أحدث لقطة لكل مستخدم. الحالة الحالية مشتقة، لا صف يُكتب فوقه.
create or replace view public.saas_user_current as
select distinct on (s.saas_user_id)
  s.saas_user_id, s.username, s.username_key, s.enabled, s.expiration,
  s.parent_name, s.profile_name, s.saas_created_at, s.last_online,
  s.fdt_code, s.fat_code, s.port_code, s.snapshot_at, s.import_batch_id
from public.saas_user_snapshots s
order by s.saas_user_id, s.snapshot_at desc, s.created_at desc;

-- ---------------------------------------------------------------------------
-- 6. أحداث التفعيل الخام — غير قابلة للتعديل.
--
-- الهوية هي معرّف الحدث لا المشترك. الأدلة الحقيقية قاطعة: تموز يحمل 29289
-- حدثاً بـ29289 معرّفاً مميزاً و20772 اسم مستخدم فقط، فالإزالة على مستوى
-- المشترك كانت ستُسقط 8517 حدثاً — 29% من الشهر.
-- ---------------------------------------------------------------------------

create table if not exists public.saas_activation_events (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.saas_import_batches(id) on delete restrict,
  saas_event_id text not null,
  transaction_id text,
  saas_user_id text,
  username text not null,
  username_key text not null generated always as (pg_catalog.lower(pg_catalog.btrim(username))) stored,
  event_created_at timestamptz,
  profile_name text,
  old_expiration timestamptz,
  new_expiration timestamptz,
  activations_count integer,
  raw_parent text,
  canceled boolean,
  price numeric,
  user_price numeric,
  total_price numeric,
  tax_amount numeric,
  tax_rate numeric,
  contract_id text,
  card text,
  card_owner text,
  comment text,
  group_name text,
  national_id text,
  topology_raw text,
  fdt_code text,
  fat_code text,
  port_code text,
  source_sheet text,
  source_row integer,
  created_at timestamptz not null default now(),
  -- حدث واحد مهما تكرر في الملفات أو الشيتات. لا إزالة تكرار بالمشترك أبداً.
  constraint saas_activation_events_identity_key unique (saas_event_id),
  constraint saas_activation_events_event_check check (btrim(saas_event_id) <> ''),
  constraint saas_activation_events_username_check check (btrim(username) <> '')
);

create index if not exists saas_activation_events_username_idx
  on public.saas_activation_events (username_key);
create index if not exists saas_activation_events_user_idx
  on public.saas_activation_events (saas_user_id);
create index if not exists saas_activation_events_parent_idx
  on public.saas_activation_events (raw_parent);
create index if not exists saas_activation_events_profile_idx
  on public.saas_activation_events (profile_name);
create index if not exists saas_activation_events_batch_idx
  on public.saas_activation_events (import_batch_id);

-- ---------------------------------------------------------------------------
-- 7. سجل المشتركين القانوني.
--
-- لا كون موازٍ: السجل يشير إلى installation_subscribers ولا يستبدله، فيبقى
-- كل مشترك مالي تاريخي متتبَّعاً، وحالته المالية بلا مساس.
-- ---------------------------------------------------------------------------

create table if not exists public.subscriber_identities (
  id uuid primary key default gen_random_uuid(),
  installation_subscriber_id uuid
    references public.installation_subscribers(id) on delete restrict,
  saas_user_id text,
  username text,
  username_key text generated always as (pg_catalog.lower(pg_catalog.btrim(username))) stored,
  display_name text,
  identity_status text not null default 'UNMATCHED',
  match_method text,
  match_evidence jsonb not null default '{}'::jsonb,
  source_classification text not null default 'RESELLER',
  raw_parent text,
  normalized_agent_id uuid references public.agents(id) on delete set null,
  effective_agent_id uuid references public.agents(id) on delete set null,
  fdt_code text,
  fat_code text,
  port_code text,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subscriber_identities_status_check
    check (identity_status in ('MATCHED', 'UNMATCHED', 'CONFLICT', 'NEEDS_REVIEW')),
  constraint subscriber_identities_classification_check
    check (source_classification in ('RESELLER', 'DIRECT_COMPANY', 'UNKNOWN_PARENT')),
  constraint subscriber_identities_method_check
    check (match_method is null or match_method in
      ('EXPLICIT_LINK', 'SAAS_USER_ID', 'EXACT_USERNAME', 'MANUAL_REVIEW')),
  -- المطابَق يحمل دليلاً على المطابقة.
  constraint subscriber_identities_matched_has_method
    check (identity_status <> 'MATCHED' or match_method is not null),
  constraint subscriber_identities_saas_key unique (saas_user_id),
  constraint subscriber_identities_installation_key unique (installation_subscriber_id)
);

create index if not exists subscriber_identities_username_idx
  on public.subscriber_identities (username_key);
create index if not exists subscriber_identities_status_idx
  on public.subscriber_identities (identity_status);
create index if not exists subscriber_identities_effective_agent_idx
  on public.subscriber_identities (effective_agent_id);

create table if not exists public.subscriber_attribution_history (
  id uuid primary key default gen_random_uuid(),
  subscriber_identity_id uuid not null
    references public.subscriber_identities(id) on delete cascade,
  from_agent_id uuid references public.agents(id) on delete set null,
  to_agent_id uuid references public.agents(id) on delete set null,
  effective_at timestamptz not null default now(),
  reason text not null,
  performed_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  constraint subscriber_attribution_reason_check check (btrim(reason) <> '')
);

create index if not exists subscriber_attribution_history_identity_idx
  on public.subscriber_attribution_history (subscriber_identity_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 8. تصنيف الجِدّة — دليل فقط، لا مال.
--
-- التصنيف يُخزَّن مع سببه وأرقامه، فيكون قابلاً للتفسير والمراجعة لاحقاً بدل
-- أن يكون منطقاً مخفياً في الواجهة.
-- ---------------------------------------------------------------------------

create table if not exists public.subscriber_classifications (
  id uuid primary key default gen_random_uuid(),
  subscriber_identity_id uuid
    references public.subscriber_identities(id) on delete cascade,
  username_key text not null,
  saas_user_id text,
  classification text not null,
  reason_code text not null,
  lifetime_activations_count integer,
  observed_event_count integer,
  registry_preexisting boolean not null default false,
  source_completeness text not null default 'UNKNOWN',
  qualifying_paid_event_count integer not null default 0,
  evidence jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default now(),
  import_batch_id uuid references public.saas_import_batches(id) on delete set null,
  constraint subscriber_classifications_value_check
    check (classification in ('NEW', 'EXISTING', 'NEEDS_REVIEW')),
  constraint subscriber_classifications_reason_check
    check (reason_code in (
      'REGISTRY_PREEXISTING',
      'LIFETIME_COUNT_EXCEEDS_OBSERVED',
      'COMPLETE_LIFETIME_HISTORY_OBSERVED',
      'PARTIAL_SOURCE',
      'UNKNOWN_SOURCE_COMPLETENESS',
      'IDENTITY_CONFLICT',
      'CANCELED_ONLY_HISTORY',
      'NO_QUALIFYING_PAID_EVENT')),
  constraint subscriber_classifications_completeness_check
    check (source_completeness in ('UNKNOWN', 'PARTIAL', 'COMPLETE')),
  -- الحارس الجوهري: NEW لا تُقال إلا بمصدر مكتمل مُثبت. الملفات الحقيقية
  -- اكتمالها UNKNOWN، فتساوي الأعداد وحده لا يكفي أبداً.
  constraint subscriber_classifications_new_requires_complete_source
    check (
      classification <> 'NEW'
      or (source_completeness = 'COMPLETE'
          and reason_code = 'COMPLETE_LIFETIME_HISTORY_OBSERVED')
    )
);

create index if not exists subscriber_classifications_username_idx
  on public.subscriber_classifications (username_key);
create index if not exists subscriber_classifications_value_idx
  on public.subscriber_classifications (classification);

-- ---------------------------------------------------------------------------
-- 9. الحماية.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'agents','agent_aliases','fdts','packages','saas_import_batches',
    'saas_user_snapshots','saas_activation_events','subscriber_identities',
    'subscriber_attribution_history','subscriber_classifications'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)',
                   t || '_select', t);
    -- revoke all قبل أي منح: قائمة الأفعال هي ما ترك TRUNCATE مرتين من قبل.
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
  end loop;
end;
$$;

revoke all on table public.saas_user_current from authenticated;
grant select on table public.saas_user_current to authenticated;
revoke all on table public.saas_user_current from anon;
revoke all on table public.saas_user_current from public;

-- التاريخ الخام لا يُعدَّل ولا يُحذف عبر أي مسار تطبيقي.
create or replace function public.protect_raw_saas_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Raw SaaS history is append-only' using errcode = '42501';
end;
$$;

drop trigger if exists trg_protect_user_snapshots on public.saas_user_snapshots;
create trigger trg_protect_user_snapshots
  before update or delete on public.saas_user_snapshots
  for each row execute function public.protect_raw_saas_history();

drop trigger if exists trg_protect_activation_events on public.saas_activation_events;
create trigger trg_protect_activation_events
  before update or delete on public.saas_activation_events
  for each row execute function public.protect_raw_saas_history();

-- ---------------------------------------------------------------------------
-- 10. حلّ الأب إلى وكيل — القلب المشترك بين الاستيراد والمراجعة.
-- ---------------------------------------------------------------------------

create or replace function public.resolve_parent_alias(p_parent text)
returns table (agent_id uuid, resolution text)
language sql
stable
security definer
set search_path = ''
as $$
  select a.agent_id,
         case when a.alias_key is null then 'needs_review' else a.resolution end
  from (select 1) as anchor
  left join public.agent_aliases a
    on a.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(p_parent, '')))
   and a.active
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 11. بيانات رئيسية أولية — حتمية وقابلة لإعادة التشغيل.
--
-- الوكلاء وأسماؤهم البديلة تُبذَر من الإعدادات القائمة في app_settings، وهي
-- المرجع الحالي في الإنتاج. النتيجة نفسها مهما تكرّر التشغيل.
-- ---------------------------------------------------------------------------

create or replace function public.bootstrap_master_data_from_settings()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_config jsonb;
  v_agent jsonb;
  v_account text;
  v_range jsonb;
  v_agent_id uuid;
  v_agents integer := 0;
  v_aliases integer := 0;
  v_fdts integer := 0;
  v_packages integer := 0;
begin
  -- الباقات: دلالة معروفة فقط. Diamond تبقى UNKNOWN فلا تُنتج مالاً بالصمت.
  insert into public.packages (code, name, semantic_category, notes) values
    ('P-35000', 'P-35000', 'PAID_PACKAGE', 'observed in every source file'),
    ('P-45000', 'P-45000', 'PAID_PACKAGE', 'observed in every source file'),
    ('P-65000', 'P-65000', 'PAID_PACKAGE', 'observed in every source file'),
    ('Loan-3',  'Loan-3',  'DEBT_SERVICE', 'debt service, never a paid activation'),
    ('Diamond', 'Diamond', 'UNKNOWN',      'one user observed; semantics undecided')
  on conflict (code) do nothing;

  select value into v_config from public.app_settings where key = 'raw_import';
  if v_config is null then
    -- الحالة الراهنة، لا عدد الصفوف المُدرَجة هذه المرة. عدّ الإدراج يعطي 5
    -- ثم 0، فيبدو البذر غير حتمي وهو حتمي — والفرق كان يظهر فقط على قاعدة
    -- بلا إعدادات، وهي حالة النشر الأولى بالضبط.
    select count(*) into v_packages from public.packages;
    return jsonb_build_object('agents', 0, 'aliases', 0, 'fdts', 0,
                              'packages', v_packages, 'source', 'none');
  end if;

  for v_agent in select value from jsonb_array_elements(coalesce(v_config -> 'agents', '[]'::jsonb))
  loop
    insert into public.agents (code, official_name, status)
    values (v_agent ->> 'id', coalesce(v_agent ->> 'name', v_agent ->> 'id'), 'active')
    on conflict (code) do update set official_name = excluded.official_name
    returning id into v_agent_id;

    if v_agent_id is null then
      select id into v_agent_id from public.agents where code = v_agent ->> 'id';
    else
      v_agents := v_agents + 1;
    end if;

    for v_account in
      select jsonb_array_elements_text(coalesce(v_agent -> 'accounts', '[]'::jsonb))
    loop
      insert into public.agent_aliases (agent_id, alias, alias_kind, resolution)
      values (v_agent_id, v_account, 'saas_parent', 'mapped')
      on conflict (alias_key) do nothing;
      v_aliases := v_aliases + coalesce((select 1 where found), 0);
    end loop;
  end loop;

  -- الشركة المباشرة: كلا الإملاءين مرصودان في ملفين مختلفين.
  insert into public.agent_aliases (agent_id, alias, alias_kind, resolution)
  values (null, 'FTTH_Users', 'saas_parent', 'direct_company'),
         (null, 'TTH_Users',  'saas_parent', 'direct_company')
  on conflict (alias_key) do nothing;

  for v_range in select value from jsonb_array_elements(coalesce(v_config -> 'cabinetRanges', '[]'::jsonb))
  loop
    select id into v_agent_id from public.agents where code = v_range ->> 'ownerId';
    insert into public.fdts (code, label, zone, agent_id, status)
    select gs::text, 'FDT-' || gs::text, 'new', v_agent_id, 'active'
    from generate_series((v_range ->> 'from')::int, (v_range ->> 'to')::int) gs
    on conflict (code) do nothing;
    v_fdts := v_fdts + ((v_range ->> 'to')::int - (v_range ->> 'from')::int + 1);
  end loop;

  select count(*) into v_agents from public.agents;
  select count(*) into v_aliases from public.agent_aliases;
  select count(*) into v_fdts from public.fdts;
  select count(*) into v_packages from public.packages;

  return jsonb_build_object('agents', v_agents, 'aliases', v_aliases,
                            'fdts', v_fdts, 'packages', v_packages, 'source', 'app_settings');
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. صلاحيات التنفيذ.
-- ---------------------------------------------------------------------------

revoke execute on function public.protect_raw_saas_history() from public, anon;
revoke execute on function public.bootstrap_master_data_from_settings() from public, anon, authenticated;
revoke execute on function public.resolve_parent_alias(text) from public, anon;
grant execute on function public.resolve_parent_alias(text) to authenticated;

commit;
