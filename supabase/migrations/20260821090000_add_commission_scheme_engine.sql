-- محرّك مخططات العمولة: الشرائح والمبالغ تهيئة مُصدَّرة، لا شرط في الكود.
--
-- اليوم الشرائح مكتوبة في defaultTiers في المتصفح وتُنسَخ في كل شهر، والأساس
-- الذي تُختار به الشريحة هو p35+p45+p65 — أي مجموع أحداث التفعيل. القرار
-- التجاري النهائي (D-03) غيّر هذا: الأساس صار عدد المشتركين المميّزين الذين
-- جرى لهم تفعيل مؤهِّل خلال الدورة، لا عدد الأحداث.
--
-- هذه المهاجرة تبني التهيئة وحدها. الحساب في المهاجرة التالية.
--
-- V1 يُبذَر من التهيئة المقبولة فعلاً في الإنتاج — لا من رقم مقترح في نص:
--   T1  0–200    P-35000=4000  P-45000=5500  P-65000=8000
--   T2  201–400  P-35000=4750  P-45000=6000  P-65000=9000
--   T3  401+     P-35000=6000  P-45000=8000  P-65000=11500
-- وهي عين ما تحمله commission_months.tiers في الشهرين القائمين.
--
-- forward-only. لا صف مالي قائم يُمَس، ولا شهر مغلق يُعاد حسابه.

begin;

-- ---------------------------------------------------------------------------
-- 1. قدرات العمولة.
-- ---------------------------------------------------------------------------

insert into public.permission_capabilities
  (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable) values
  ('commission.view',              'commission', 'عرض العمولات',        false, false, true),
  ('commission.manage_cycle',      'commission', 'إدارة دورة العمولة',  true,  false, false),
  ('commission.configure',         'commission', 'تهيئة مخطط العمولة',  true,  false, false),
  ('commission.finalize',          'commission', 'اعتماد دورة العمولة', true,  false, false),
  ('commission.prepare_payment',   'commission', 'تحضير دفع العمولة',   true,  false, true),
  ('commission.execute_payment',   'commission', 'تنفيذ دفع العمولة',   true,  false, true),
  ('commission.reopen',            'commission', 'إعادة فتح دورة',      true,  false, false),
  ('commission.review_exception',  'commission', 'مراجعة الاستثناءات',  false, false, true)
on conflict (key) do nothing;

-- المدير يملك كل قدرة، كما هو قائم.
insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', key from public.permission_capabilities
on conflict do nothing;

-- العرض للجميع، كما هي حال قدرات العرض الأخرى قبل هذه المهاجرة.
insert into public.role_template_capabilities (role_key, capability_key)
select r.key, 'commission.view'
from (values ('accountant'), ('monitor'), ('viewer')) as r(key)
on conflict do nothing;

-- المحاسب يملك payment اليوم، فيأخذ تحضير العمولة وتنفيذها ومراجعة استثناءاتها.
-- ولا يأخذ الاعتماد ولا إعادة الفتح ولا التهيئة: تسجيل الدفع ليس سلطة تقرير
-- ما يُدفع، وهذا هو الفصل نفسه المطبَّق في أجور التنصيب.
insert into public.role_template_capabilities (role_key, capability_key)
select 'accountant', c.key from public.permission_capabilities c
where c.key in ('commission.prepare_payment', 'commission.execute_payment',
                'commission.review_exception')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. المخطط وإصداراته.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_schemes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name_ar text not null,
  description text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint commission_schemes_code_key unique (code),
  constraint commission_schemes_code_check check (btrim(code) <> '')
);

create table if not exists public.commission_scheme_versions (
  id uuid primary key default gen_random_uuid(),
  scheme_id uuid not null references public.commission_schemes(id) on delete restrict,
  version integer not null,
  status text not null default 'DRAFT',
  effective_from date,
  effective_to date,
  -- أساس الشريحة صار تهيئة أيضاً، حتى لا يعود قرار D-03 حبيس الكود.
  tier_basis text not null default 'UNIQUE_ACTIVATED_SUBSCRIBERS',
  -- نطاق تحديد الشريحة لكل منطقة: القديمة بالوكيل والجديدة بالكابينة.
  old_zone_scope text not null default 'AGENT',
  new_zone_scope text not null default 'FDT',
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  published_by uuid references auth.users(id),
  published_at timestamptz,
  retired_by uuid references auth.users(id),
  retired_at timestamptz,
  constraint commission_scheme_versions_identity unique (scheme_id, version),
  constraint commission_scheme_versions_version_check check (version >= 1),
  constraint commission_scheme_versions_status_check
    check (status in ('DRAFT', 'PUBLISHED', 'RETIRED')),
  -- الأساس المرفوض صراحةً: مجموع الأحداث لم يعد أساساً للشريحة.
  constraint commission_scheme_versions_basis_check
    check (tier_basis in ('UNIQUE_ACTIVATED_SUBSCRIBERS', 'QUALIFYING_EVENT_COUNT')),
  constraint commission_scheme_versions_scope_check
    check (old_zone_scope in ('AGENT', 'FDT', 'GLOBAL')
       and new_zone_scope in ('AGENT', 'FDT', 'GLOBAL')),
  constraint commission_scheme_versions_dates_check
    check (effective_to is null or effective_from is null or effective_to >= effective_from),
  -- المنشور يحمل وقت نشره. الفاعل يبقى فارغاً حين يبذره النظام، فالنسبة إلى
  -- مستخدم لم يفعل شيئاً كذبة في سجل التدقيق.
  constraint commission_scheme_versions_published_is_timed
    check (status = 'DRAFT' or published_at is not null)
);

create index if not exists commission_scheme_versions_status_idx
  on public.commission_scheme_versions (status);

-- ---------------------------------------------------------------------------
-- 3. الشرائح.
--
-- الحد الأعلى الفارغ يعني «فما فوق». وهذا يطابق max=null في التهيئة القائمة.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_tier_definitions (
  id uuid primary key default gen_random_uuid(),
  scheme_version_id uuid not null
    references public.commission_scheme_versions(id) on delete cascade,
  sequence integer not null,
  code text not null,
  label_ar text not null,
  min_subscribers integer not null,
  max_subscribers integer,
  zone text,
  constraint commission_tier_definitions_identity unique (scheme_version_id, sequence),
  constraint commission_tier_definitions_code_key unique (scheme_version_id, code),
  constraint commission_tier_definitions_sequence_check check (sequence >= 1),
  constraint commission_tier_definitions_min_check check (min_subscribers >= 0),
  constraint commission_tier_definitions_range_check
    check (max_subscribers is null or max_subscribers >= min_subscribers),
  constraint commission_tier_definitions_zone_check
    check (zone is null or zone in ('old', 'new'))
);

-- ---------------------------------------------------------------------------
-- 4. قيمة العمولة لكل باقة داخل الشريحة.
--
-- الأهلية هنا لا في الدلالة: باقة مدفوعة دلالةً قد لا تُعمَّل في إصدار ما،
-- وخدمة الدَّين لا تُعمَّل أبداً — وهو ما يحرسه القيد أدناه.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_package_rates (
  id uuid primary key default gen_random_uuid(),
  tier_definition_id uuid not null
    references public.commission_tier_definitions(id) on delete cascade,
  package_code text not null,
  amount bigint not null,
  qualifies boolean not null default true,
  constraint commission_package_rates_identity unique (tier_definition_id, package_code),
  constraint commission_package_rates_amount_check check (amount >= 0),
  -- ما لا يؤهِّل لا يحمل مبلغاً. هذا يمنع «صفر مؤهِّل» و«مبلغ غير مؤهِّل» معاً.
  constraint commission_package_rates_shape
    check ((qualifies and amount > 0) or (not qualifies and amount = 0))
);

-- ---------------------------------------------------------------------------
-- 5. المنشور لا يُعدَّل.
-- ---------------------------------------------------------------------------

create or replace function public.protect_published_commission_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'A published commission version cannot be deleted' using errcode = '42501';
    end if;
    return old;
  end if;

  if old.status = 'PUBLISHED' then
    -- التقاعد وحده مسموح، وبشرط ألا يتغيّر شيء من جوهر الحساب.
    if new.status = 'RETIRED'
       and new.scheme_id is not distinct from old.scheme_id
       and new.version is not distinct from old.version
       and new.tier_basis is not distinct from old.tier_basis
       and new.old_zone_scope is not distinct from old.old_zone_scope
       and new.new_zone_scope is not distinct from old.new_zone_scope
       and new.effective_from is not distinct from old.effective_from then
      return new;
    end if;
    raise exception 'A published commission version is immutable; create a new version'
      using errcode = '42501';
  end if;

  if old.status = 'RETIRED' then
    raise exception 'A retired commission version cannot change' using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_published_commission on public.commission_scheme_versions;
create trigger trg_protect_published_commission
  before update or delete on public.commission_scheme_versions
  for each row execute function public.protect_published_commission_version();

create or replace function public.protect_published_commission_children()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version uuid;
  v_status text;
begin
  if tg_table_name = 'commission_tier_definitions' then
    v_version := coalesce(new.scheme_version_id, old.scheme_version_id);
  else
    select scheme_version_id into v_version
    from public.commission_tier_definitions
    where id = coalesce(new.tier_definition_id, old.tier_definition_id);
  end if;

  select status into v_status from public.commission_scheme_versions where id = v_version;
  if v_status is distinct from 'DRAFT' then
    raise exception 'Tiers and rates of a published version are immutable'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_protect_commission_tiers on public.commission_tier_definitions;
create trigger trg_protect_commission_tiers
  before insert or update or delete on public.commission_tier_definitions
  for each row execute function public.protect_published_commission_children();

drop trigger if exists trg_protect_commission_rates on public.commission_package_rates;
create trigger trg_protect_commission_rates
  before insert or update or delete on public.commission_package_rates
  for each row execute function public.protect_published_commission_children();

-- ---------------------------------------------------------------------------
-- 6. حارس خدمة الدَّين.
--
-- قاعدة تجارية محمية: خدمة الدَّين ليست تفعيل اشتراك، فلا تُعمَّل في أي
-- إصدار مهما بدت التهيئة. الحارس في القاعدة لا في الواجهة، لأن تهيئة خاطئة
-- تُنتج مالاً وتهيئة الواجهة لا تمنعها.
-- ---------------------------------------------------------------------------

create or replace function public.guard_debt_service_never_qualifies()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_category text;
begin
  if not new.qualifies then
    return new;
  end if;
  select semantic_category into v_category from public.packages where code = new.package_code;
  if v_category = 'DEBT_SERVICE' then
    raise exception 'A debt service package can never earn commission (%)', new.package_code
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_debt_service on public.commission_package_rates;
create trigger trg_guard_debt_service
  before insert or update on public.commission_package_rates
  for each row execute function public.guard_debt_service_never_qualifies();

-- ---------------------------------------------------------------------------
-- 7. النشر عبر RPC مُدقَّق.
-- ---------------------------------------------------------------------------

create or replace function public.publish_commission_version(
  p_version_id uuid,
  p_effective_from date,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.commission_scheme_versions%rowtype;
  v_tiers integer;
  v_rates integer;
  v_gap integer;
begin
  perform public.require_capability('commission.configure');
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_row from public.commission_scheme_versions
  where id = p_version_id for update;
  if not found then
    raise exception 'Commission scheme version was not found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'DRAFT' then
    raise exception 'Only a draft version can be published' using errcode = '42501';
  end if;

  select count(*) into v_tiers from public.commission_tier_definitions
  where scheme_version_id = p_version_id;
  select count(*) into v_rates from public.commission_package_rates r
  join public.commission_tier_definitions t on t.id = r.tier_definition_id
  where t.scheme_version_id = p_version_id;

  if v_tiers = 0 then
    raise exception 'A commission version needs at least one tier' using errcode = '23514';
  end if;
  if v_rates = 0 then
    raise exception 'A commission version needs at least one package rate' using errcode = '23514';
  end if;

  -- فجوة بين شريحتين تعني عدداً من المشتركين بلا شريحة، وهو صمت مالي.
  select count(*) into v_gap
  from public.commission_tier_definitions a
  join public.commission_tier_definitions b
    on b.scheme_version_id = a.scheme_version_id and b.sequence = a.sequence + 1
  where a.scheme_version_id = p_version_id
    and (a.max_subscribers is null or b.min_subscribers <> a.max_subscribers + 1);
  if v_gap > 0 then
    raise exception 'Tier bands must be contiguous with no gap' using errcode = '23514';
  end if;

  update public.commission_scheme_versions
  set status = 'PUBLISHED', published_by = v_actor, published_at = now(),
      effective_from = coalesce(p_effective_from, effective_from)
  where id = p_version_id
  returning * into v_row;

  insert into public.audit_logs (
    actor_id, action, field, new_value, entity_type, entity_id,
    after_data, request_id, extra
  ) values (
    v_actor, 'commission.scheme.published', 'status', 'PUBLISHED',
    'commission_scheme_version', p_version_id, to_jsonb(v_row), p_request_id,
    v_tiers::text || ' tiers, ' || v_rates::text || ' rates'
  );

  return jsonb_build_object('replayed', false, 'version', to_jsonb(v_row),
                            'tiers', v_tiers, 'rates', v_rates);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. قراءات التهيئة.
-- ---------------------------------------------------------------------------

-- الشريحة من عدد المشتركين المميّزين — لا من عدد الأحداث.
create or replace function public.commission_tier_for_subscribers(
  p_version_id uuid, p_zone text, p_subscribers integer)
returns public.commission_tier_definitions
language sql
stable
security definer
set search_path = ''
as $$
  select t.*
  from public.commission_tier_definitions t
  where t.scheme_version_id = p_version_id
    and (t.zone is null or t.zone = p_zone)
    and p_subscribers >= t.min_subscribers
    and (t.max_subscribers is null or p_subscribers <= t.max_subscribers)
  order by t.sequence
  limit 1;
$$;

create or replace function public.commission_rate_for(
  p_version_id uuid, p_zone text, p_subscribers integer, p_package text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case when r.qualifies then r.amount else 0 end
  from public.commission_package_rates r
  join public.commission_tier_definitions t on t.id = r.tier_definition_id
  where t.id = (public.commission_tier_for_subscribers(p_version_id, p_zone, p_subscribers)).id
    and r.package_code = p_package;
$$;

-- ---------------------------------------------------------------------------
-- 9. بذر V1 من التهيئة المقبولة فعلاً.
--
-- المصدر: commission_months.tiers في الإنتاج، وهي عين defaultTiers في الكود.
-- لا رقم هنا مخترع؛ وكلها مطابقة لما يعمل به النظام اليوم.
-- ---------------------------------------------------------------------------

do $$
declare
  v_scheme uuid;
  v_version uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
begin
  insert into public.commission_schemes (code, name_ar, description)
  values ('COMMISSION_STANDARD', 'عمولات الوكلاء القياسية',
          'baseline reconstructed from the live configuration, not re-typed')
  on conflict (code) do nothing;
  select id into v_scheme from public.commission_schemes where code = 'COMMISSION_STANDARD';

  insert into public.commission_scheme_versions
    (scheme_id, version, status, tier_basis, old_zone_scope, new_zone_scope, notes)
  values (v_scheme, 1, 'DRAFT', 'UNIQUE_ACTIVATED_SUBSCRIBERS', 'AGENT', 'FDT',
          'tier values identical to the accepted live configuration; the basis is the resolved D-03 rule')
  on conflict (scheme_id, version) do nothing;
  select id into v_version from public.commission_scheme_versions
  where scheme_id = v_scheme and version = 1;

  insert into public.commission_tier_definitions
    (scheme_version_id, sequence, code, label_ar, min_subscribers, max_subscribers)
  values (v_version, 1, 't1', 'T1', 0, 200),
         (v_version, 2, 't2', 'T2', 201, 400),
         (v_version, 3, 't3', 'T3', 401, null)
  on conflict (scheme_version_id, sequence) do nothing;

  select id into v_t1 from public.commission_tier_definitions
  where scheme_version_id = v_version and code = 't1';
  select id into v_t2 from public.commission_tier_definitions
  where scheme_version_id = v_version and code = 't2';
  select id into v_t3 from public.commission_tier_definitions
  where scheme_version_id = v_version and code = 't3';

  insert into public.commission_package_rates (tier_definition_id, package_code, amount, qualifies)
  values (v_t1, 'P-35000',  4000, true), (v_t1, 'P-45000',  5500, true), (v_t1, 'P-65000',  8000, true),
         (v_t2, 'P-35000',  4750, true), (v_t2, 'P-45000',  6000, true), (v_t2, 'P-65000',  9000, true),
         (v_t3, 'P-35000',  6000, true), (v_t3, 'P-45000',  8000, true), (v_t3, 'P-65000', 11500, true)
  on conflict (tier_definition_id, package_code) do nothing;

  -- النشر بذرةً: هذه القيم معتمدة سلفاً وتعمل في الإنتاج، والنشر هنا لا
  -- يُنشئ مالاً ولا يُعيد حساب شهر.
  -- بلا تاريخ بدء: هذه القيم سارية اليوم فعلاً، لكن متى بدأت بالضبط غير
  -- معروف — وتاريخٌ مخترع هنا كان سيدّعي حكماً على شهور لم يحكمها. الحد
  -- المفتوح يقول الحقيقة: سارية حتى يُنسخها إصدار لاحق.
  update public.commission_scheme_versions
  set status = 'PUBLISHED', published_at = now()
  where id = v_version and status = 'DRAFT';
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['commission_schemes','commission_scheme_versions',
                           'commission_tier_definitions','commission_package_rates'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.has_capability(''commission.view''))',
      t || '_select', t);
  end loop;
end;
$$;

revoke execute on function public.protect_published_commission_version() from public, anon, authenticated;
revoke execute on function public.protect_published_commission_children() from public, anon, authenticated;
revoke execute on function public.guard_debt_service_never_qualifies() from public, anon, authenticated;
revoke execute on function public.publish_commission_version(uuid, date, uuid) from public, anon;
grant execute on function public.publish_commission_version(uuid, date, uuid) to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.commission_tier_for_subscribers(uuid, text, integer)',
    'public.commission_rate_for(uuid, text, integer, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
