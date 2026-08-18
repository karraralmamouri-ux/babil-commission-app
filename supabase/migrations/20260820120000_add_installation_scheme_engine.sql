-- محرّك مخططات أجور التنصيب: المراحل والمبالغ تهيئة، لا شرط في الكود.
--
-- اليوم P1..P4 ومبالغها مكتوبة في SQL وJS معاً. أي تغيير مستقبلي في عدد
-- المراحل أو مبلغها يستلزم نشر كود، وهذا يجعل قراراً تجارياً رهينةَ إصدار.
--
-- البديل: مخطط له إصدارات، ولكل إصدار تعريفات مراحل. الإصدار المنشور لا
-- يُعدَّل — التغيير يعني إصداراً جديداً. والتسجيل يُجمّد على إصدار بعينه،
-- فلا يُعيد إصدارٌ لاحق كتابةَ ماضي المشتركين.
--
-- الدلالة ليست الأهلية. P-35000 باقة مدفوعة دلالةً، وكونُها مؤهِّلة لمرحلة
-- تنصيب قرارٌ في تهيئة المخطط. Loan-3 خدمة دَين ولا تؤهِّل أبداً.
--
-- forward-only. لا مبلغ تاريخي يتغيّر ولا صف مالي يُمَس.

begin;

-- ---------------------------------------------------------------------------
-- 1. المخطط وإصداراته.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_fee_schemes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name_ar text not null,
  description text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint installation_fee_schemes_code_key unique (code),
  constraint installation_fee_schemes_code_check check (btrim(code) <> '')
);

create table if not exists public.installation_scheme_versions (
  id uuid primary key default gen_random_uuid(),
  scheme_id uuid not null references public.installation_fee_schemes(id) on delete restrict,
  version integer not null,
  status text not null default 'DRAFT',
  effective_from date,
  effective_to date,
  applicability jsonb not null default '{}'::jsonb,
  -- المبلغ الكلي مشتق من المراحل ويُثبَّت عند النشر، فيُكشف أي انحراف لاحق.
  total_amount bigint,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  published_by uuid references auth.users(id),
  published_at timestamptz,
  retired_by uuid references auth.users(id),
  retired_at timestamptz,
  constraint installation_scheme_versions_identity unique (scheme_id, version),
  constraint installation_scheme_versions_version_check check (version >= 1),
  constraint installation_scheme_versions_status_check
    check (status in ('DRAFT', 'PUBLISHED', 'RETIRED')),
  constraint installation_scheme_versions_dates_check
    check (effective_to is null or effective_from is null or effective_to >= effective_from),
  -- المنشور يحمل وقت نشره دائماً. والفاعل قد يكون فارغاً في حالة واحدة فقط:
  -- أساس تاريخي بذرته المهاجرة. نسبةُ ذلك إلى أول مستخدم في الجدول كانت
  -- ستكون كذبة في سجل التدقيق؛ والفراغ هنا يقول الحقيقة: نشرَه النظام.
  constraint installation_scheme_versions_published_is_timed
    check (status = 'DRAFT' or published_at is not null)
);

create index if not exists installation_scheme_versions_status_idx
  on public.installation_scheme_versions (status);

-- ---------------------------------------------------------------------------
-- 2. تعريفات المراحل.
--
-- expected_remaining يحمل دلالة الرصيد التاريخية: المخطط الحالي يعرّف المرحلة
-- التالية من «المتبقي»، وهذا يبقى تهيئةً لا جدولاً ثابتاً في الكود.
-- ---------------------------------------------------------------------------

create table if not exists public.installation_stage_definitions (
  id uuid primary key default gen_random_uuid(),
  scheme_version_id uuid not null
    references public.installation_scheme_versions(id) on delete cascade,
  sequence integer not null,
  code text not null,
  display_name_ar text not null,
  amount bigint not null,
  expected_remaining bigint,
  -- الفئات الدلالية التي تُرضي هذه المرحلة. الفارغة تعني: لا شيء يؤهِّل.
  qualifying_categories text[] not null default array['PAID_PACKAGE'],
  requires_invoice boolean not null default true,
  is_terminal boolean not null default false,
  constraint installation_stage_definitions_identity unique (scheme_version_id, sequence),
  constraint installation_stage_definitions_code_key unique (scheme_version_id, code),
  constraint installation_stage_definitions_sequence_check check (sequence >= 1),
  constraint installation_stage_definitions_amount_check check (amount >= 0),
  constraint installation_stage_definitions_code_check check (btrim(code) <> ''),
  -- المرحلة المنتهية بلا مبلغ: DONE ليست دفعة.
  constraint installation_stage_definitions_terminal_is_free
    check (not is_terminal or amount = 0)
);

-- ---------------------------------------------------------------------------
-- 3. المنشور لا يُعدَّل بصمت.
--
-- التعديل المسموح على المنشور: التقاعد وحده. أي تغيير في المبالغ أو المراحل
-- أو التواريخ يستلزم إصداراً جديداً، لأن التسجيلات القائمة تشير إلى هذا
-- الإصدار ومالُها محسوب عليه.
-- ---------------------------------------------------------------------------

create or replace function public.protect_published_scheme_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'A published scheme version cannot be deleted' using errcode = '42501';
    end if;
    return old;
  end if;

  if old.status = 'PUBLISHED' then
    -- التقاعد هو التحوّل الوحيد المسموح.
    if new.status = 'RETIRED'
       and new.scheme_id is not distinct from old.scheme_id
       and new.version is not distinct from old.version
       and new.total_amount is not distinct from old.total_amount
       and new.effective_from is not distinct from old.effective_from
       and new.applicability is not distinct from old.applicability then
      return new;
    end if;
    raise exception 'A published scheme version is immutable; create a new version'
      using errcode = '42501';
  end if;

  if old.status = 'RETIRED' then
    raise exception 'A retired scheme version cannot change' using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_published_scheme on public.installation_scheme_versions;
create trigger trg_protect_published_scheme
  before update or delete on public.installation_scheme_versions
  for each row execute function public.protect_published_scheme_version();

-- المراحل تتبع إصدارها: ما دام منشوراً فتعريفاته مقفلة أيضاً.
create or replace function public.protect_published_stage_definitions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_status text;
begin
  select status into v_status from public.installation_scheme_versions
  where id = coalesce(new.scheme_version_id, old.scheme_version_id);

  if v_status is distinct from 'DRAFT' then
    raise exception 'Stage definitions of a published version are immutable'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_protect_published_stages on public.installation_stage_definitions;
create trigger trg_protect_published_stages
  before insert or update or delete on public.installation_stage_definitions
  for each row execute function public.protect_published_stage_definitions();

-- ---------------------------------------------------------------------------
-- 4. النشر عبر RPC مُدقَّق.
-- ---------------------------------------------------------------------------

create or replace function public.publish_scheme_version(
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
  v_row public.installation_scheme_versions%rowtype;
  v_stages integer;
  v_total bigint;
  v_terminal integer;
begin
  perform public.require_capability('scheme.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_row from public.installation_scheme_versions
  where id = p_version_id for update;
  if not found then
    raise exception 'Scheme version was not found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'DRAFT' then
    raise exception 'Only a draft version can be published' using errcode = '42501';
  end if;

  select count(*), coalesce(sum(amount), 0), count(*) filter (where is_terminal)
  into v_stages, v_total, v_terminal
  from public.installation_stage_definitions where scheme_version_id = p_version_id;

  -- إصدار بلا مراحل مالية لا يُنشر: النشر يعني أن المال صار قابلاً للحساب.
  if v_stages = 0 then
    raise exception 'A scheme version needs at least one stage' using errcode = '23514';
  end if;
  if v_total <= 0 then
    raise exception 'A scheme version needs a positive total amount' using errcode = '23514';
  end if;

  update public.installation_scheme_versions
  set status = 'PUBLISHED', published_by = v_actor, published_at = now(),
      effective_from = coalesce(p_effective_from, effective_from),
      total_amount = v_total
  where id = p_version_id
  returning * into v_row;

  insert into public.audit_logs (
    actor_id, action, field, new_value, entity_type, entity_id,
    after_data, request_id, extra
  ) values (
    v_actor, 'scheme.version.published', 'status', 'PUBLISHED',
    'installation_scheme_version', p_version_id, to_jsonb(v_row), p_request_id,
    v_stages::text || ' stages, total ' || v_total::text
  );

  return jsonb_build_object('replayed', false, 'version', to_jsonb(v_row),
                            'stages', v_stages, 'total_amount', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. قراءات المخطط. المبلغ يأتي من التهيئة، لا من ثابت في الكود.
-- ---------------------------------------------------------------------------

create or replace function public.stage_amount_for_version(
  p_version_id uuid, p_stage_code text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select amount from public.installation_stage_definitions
  where scheme_version_id = p_version_id and code = p_stage_code;
$$;

create or replace function public.next_stage_for_version(
  p_version_id uuid, p_current_code text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.code
  from public.installation_stage_definitions s
  where s.scheme_version_id = p_version_id
    and s.sequence > coalesce(
      (select c.sequence from public.installation_stage_definitions c
       where c.scheme_version_id = p_version_id and c.code = p_current_code), 0)
  order by s.sequence
  limit 1;
$$;

-- المرحلة المستحقة من «المتبقي» — دلالة تاريخية صارت تهيئة.
create or replace function public.stage_for_remaining_in_version(
  p_version_id uuid, p_remaining bigint)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select code from public.installation_stage_definitions
  where scheme_version_id = p_version_id
    and expected_remaining is not distinct from p_remaining
  order by sequence
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 6. المخطط التاريخي V1 — الأساس المعتمد كما هو.
--
-- P1..P3 بثلاثة آلاف وP4 بأربعة، ومجموعها 13,000. ودلالة «المتبقي» تُسجَّل
-- على المرحلة نفسها: 13000 يعني أن P1 هي التالية، وصفر يعني الانتهاء.
-- ---------------------------------------------------------------------------

do $$
declare
  v_scheme uuid;
  v_version uuid;
begin
  insert into public.installation_fee_schemes (code, name_ar, description)
  values ('INSTALLATION_STANDARD', 'أجور التنصيب القياسية',
          'the accepted historical baseline, four instalments totalling 13,000 IQD')
  on conflict (code) do nothing;

  select id into v_scheme from public.installation_fee_schemes
  where code = 'INSTALLATION_STANDARD';

  insert into public.installation_scheme_versions
    (scheme_id, version, status, applicability, notes)
  values (v_scheme, 1, 'DRAFT', '{"zones": ["old", "new"]}'::jsonb,
          'historical baseline; carries the accepted Remaining semantics')
  on conflict (scheme_id, version) do nothing;

  select id into v_version from public.installation_scheme_versions
  where scheme_id = v_scheme and version = 1;

  insert into public.installation_stage_definitions
    (scheme_version_id, sequence, code, display_name_ar, amount, expected_remaining, is_terminal)
  values
    (v_version, 1, 'P1',   'القسط الأول',  3000, 13000, false),
    (v_version, 2, 'P2',   'القسط الثاني', 3000, 10000, false),
    (v_version, 3, 'P3',   'القسط الثالث', 3000,  7000, false),
    (v_version, 4, 'P4',   'القسط الرابع', 4000,  4000, false),
    (v_version, 5, 'DONE', 'مكتمل',           0,     0, true)
  on conflict (scheme_version_id, sequence) do nothing;

  -- النشر هنا مباشر: هذا الإصدار يمثّل أساساً تاريخياً معتمداً سلفاً، ولا
  -- يُنشئ مالاً — الأرقام هي عين ما تعمل به المنظومة اليوم.
  update public.installation_scheme_versions
  set status = 'PUBLISHED', published_at = now(),
      total_amount = 13000,
      effective_from = coalesce(effective_from, date '2026-01-01')
  where id = v_version and status = 'DRAFT';
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['installation_fee_schemes','installation_scheme_versions',
                           'installation_stage_definitions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)',
                   t || '_select', t);
  end loop;
end;
$$;

revoke execute on function public.protect_published_scheme_version() from public, anon, authenticated;
revoke execute on function public.protect_published_stage_definitions() from public, anon, authenticated;
revoke execute on function public.publish_scheme_version(uuid, date, uuid) from public, anon;
grant execute on function public.publish_scheme_version(uuid, date, uuid) to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.stage_amount_for_version(uuid, text)',
    'public.next_stage_for_version(uuid, text)',
    'public.stage_for_remaining_in_version(uuid, bigint)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
