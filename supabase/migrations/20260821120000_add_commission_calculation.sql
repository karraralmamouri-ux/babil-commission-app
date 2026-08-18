-- حساب العمولة على الخادم: من الأحداث الخام إلى استحقاق لكل حدث.
--
-- القرار الجوهري (D-03 محسوماً): أساس الشريحة هو عدد المشتركين المميّزين
-- الذين جرى لهم تفعيل مؤهِّل في الدورة — لا عدد الأحداث ولا المستخدمون
-- المفعَّلون بمعنى enabled ولا تاريخ الانتهاء.
--
-- وهذان مقياسان مختلفان لا يجوز خلطهما:
--   أساس الشريحة        = count(distinct هوية المشترك)
--   الأحداث المُعمَّلة   = count(distinct معرّف الحدث)
--
-- مشترك له ثلاثة تفعيلات مؤهِّلة يساهم بواحد في الشريحة وبثلاثة في العمولة.
--
-- النطاق: المنطقة القديمة تُحسَب شريحتها على الوكيل، والجديدة على الكابينة —
-- وهو ما يفعله النظام اليوم فعلاً (17 صفاً قديماً تحمل tier_group_id، ولا صف
-- جديد يحملها).
--
-- الاكتمال شرط للاعتماد لا للعرض: الدورة المفتوحة تُعرض بحساب متوقَّع، والاعتماد
-- النهائي يستلزم تغطية مصدر مُثبتة أو استثناءً مُصرَّحاً به ومُدقَّقاً.
--
-- forward-only. لا شهر قائم يُعاد حسابه ولا صف مالي يُمَس.

begin;

-- ---------------------------------------------------------------------------
-- 1. دورة العمولة.
--
-- لا تُلغى commission_months ولا تُستبدل: الشهور القائمة تبقى مجمَّدة، وتُربَط
-- الدورة بشهرها حين يكون له مقابل، فيبقى الجسر قائماً بلا ازدواج.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_cycles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  period_start date not null,
  period_end date not null,
  status text not null default 'DRAFT',
  scheme_version_id uuid references public.commission_scheme_versions(id),
  -- يُسجَّل على كل دورة أي محرّك أنتجها، فلا يختلط قديم بجديد في دورة واحدة.
  engine_version text not null default 'VNEXT',
  legacy_month_id uuid references public.commission_months(id),
  source_batch_ids uuid[] not null default '{}',
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  calculated_at timestamptz,
  finalized_by uuid references auth.users(id),
  finalized_at timestamptz,
  closed_by uuid references auth.users(id),
  closed_at timestamptz,
  reopened_by uuid references auth.users(id),
  reopened_at timestamptz,
  reopen_reason text,
  constraint commission_cycles_name_key unique (name),
  constraint commission_cycles_dates_check check (period_end >= period_start),
  constraint commission_cycles_status_check check (status in (
    'DRAFT','DATA_IMPORTED','UNDER_REVIEW','READY_TO_FINALIZE',
    'FINALIZED','PARTIALLY_PAID','PAID','CLOSED')),
  constraint commission_cycles_engine_check check (engine_version in ('LEGACY','VNEXT')),
  constraint commission_cycles_finalized_is_attributed
    check (status in ('DRAFT','DATA_IMPORTED','UNDER_REVIEW','READY_TO_FINALIZE')
           or (finalized_by is not null and finalized_at is not null)),
  constraint commission_cycles_closed_is_attributed
    check (status <> 'CLOSED' or (closed_by is not null and closed_at is not null))
);

create index if not exists commission_cycles_status_idx on public.commission_cycles (status);

-- ---------------------------------------------------------------------------
-- 2. استحقاق لكل حدث.
--
-- الحدث الواحد يُنتج استحقاقاً واحداً في الدورة الواحدة. الفهرس الفريد هو ما
-- يجعل استيراداً مكرَّراً غير قادر على توليد عمولة مرتين.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_event_entitlements (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.commission_cycles(id) on delete cascade,
  activation_event_id text not null,
  subscriber_key text not null,
  subscriber_identity_id uuid references public.subscriber_identities(id) on delete set null,
  saas_user_id text,
  scope_type text not null,
  scope_id text not null,
  zone text not null,
  effective_agent_id uuid references public.agents(id) on delete set null,
  agent_name text,
  fdt_code text,
  raw_parent text,
  package_code text,
  scheme_version_id uuid not null references public.commission_scheme_versions(id),
  tier_code text,
  amount bigint not null default 0,
  status text not null default 'PROJECTED',
  event_at timestamptz,
  calculated_at timestamptz not null default now(),
  constraint commission_event_entitlements_identity unique (cycle_id, activation_event_id),
  constraint commission_event_entitlements_scope_check
    check (scope_type in ('AGENT', 'FDT', 'GLOBAL')),
  constraint commission_event_entitlements_zone_check check (zone in ('old', 'new')),
  constraint commission_event_entitlements_status_check
    check (status in ('PROJECTED', 'FINAL', 'EXCLUDED')),
  constraint commission_event_entitlements_amount_check check (amount >= 0)
);

create index if not exists commission_event_entitlements_scope_idx
  on public.commission_event_entitlements (cycle_id, scope_type, scope_id);
create index if not exists commission_event_entitlements_subscriber_idx
  on public.commission_event_entitlements (cycle_id, subscriber_key);

-- ---------------------------------------------------------------------------
-- 3. لقطة النطاق عند الاعتماد.
--
-- تُفسِّر النتيجة لاحقاً بلا الاعتماد على تهيئة اليوم: أي قواعد، أي مصدر، أي
-- نطاق، أي قيم، أي فاعل، وأي وقت.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_cycle_snapshots (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.commission_cycles(id) on delete cascade,
  scheme_version_id uuid not null references public.commission_scheme_versions(id),
  scope_type text not null,
  scope_id text not null,
  scope_label text,
  zone text not null,
  unique_activated_subscribers integer not null,
  qualifying_event_count integer not null,
  tier_code text,
  package_breakdown jsonb not null default '{}'::jsonb,
  gross_commission bigint not null default 0,
  source_batch_ids uuid[] not null default '{}',
  measurement_start date,
  measurement_end date,
  calculated_at timestamptz not null default now(),
  finalized_at timestamptz,
  constraint commission_cycle_snapshots_identity unique (cycle_id, scope_type, scope_id),
  constraint commission_cycle_snapshots_counts_check
    check (unique_activated_subscribers >= 0 and qualifying_event_count >= 0),
  -- لا يمكن أن يتجاوز عدد المشتركين عدد الأحداث: كل مشترك جاء بحدث على الأقل.
  constraint commission_cycle_snapshots_basis_is_sane
    check (unique_activated_subscribers <= qualifying_event_count)
);

-- اللقطة المعتمدة لا تتغيّر بعد اعتمادها.
create or replace function public.protect_finalized_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.finalized_at is not null then
    raise exception 'A finalized commission snapshot is immutable' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_protect_finalized_snapshot on public.commission_cycle_snapshots;
create trigger trg_protect_finalized_snapshot
  before update or delete on public.commission_cycle_snapshots
  for each row execute function public.protect_finalized_snapshot();

-- ---------------------------------------------------------------------------
-- 4. الاستثناءات — لا يُسقَط حدث بصمت.
-- ---------------------------------------------------------------------------

create table if not exists public.commission_exceptions (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.commission_cycles(id) on delete cascade,
  activation_event_id text,
  subscriber_key text,
  reason_code text not null,
  detail text,
  -- المادّي مالياً يمنع الاعتماد؛ وغيره يبقى مرئياً للمراجعة.
  blocks_finalization boolean not null default true,
  status text not null default 'OPEN',
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz,
  resolution_note text,
  created_at timestamptz not null default now(),
  constraint commission_exceptions_reason_check check (reason_code in (
    'UNKNOWN_AGENT','UNKNOWN_FDT','UNKNOWN_PACKAGE','IDENTITY_CONFLICT',
    'SOURCE_INCOMPLETE','EVENT_CONFLICT','ATTRIBUTION_REVIEW','MISSING_PERIOD')),
  constraint commission_exceptions_status_check check (status in ('OPEN','RESOLVED','WAIVED')),
  constraint commission_exceptions_resolved_is_attributed
    check (status = 'OPEN'
           or (resolved_by is not null and resolved_at is not null
               and btrim(coalesce(resolution_note, '')) <> ''))
);

create index if not exists commission_exceptions_cycle_idx
  on public.commission_exceptions (cycle_id, status);

-- استثناء واحد مفتوح لكل سبب على الحدث نفسه.
create unique index if not exists commission_exceptions_open_key
  on public.commission_exceptions (cycle_id, coalesce(activation_event_id, ''),
                                   coalesce(subscriber_key, ''), reason_code)
  where status = 'OPEN';

-- ---------------------------------------------------------------------------
-- 5. الأحداث المؤهِّلة للدورة.
--
-- هنا تُطبَّق كل قواعد الأهلية دفعةً واحدة، فيقرأها الحساب والمراجعة معاً من
-- مصدر واحد بدل نسختين تتباعدان.
--
-- المنطقة تُشتق من الكابينة: حدث بكابينة مسجَّلة في المنطقة الجديدة يخصّها
-- ونطاقه الكابينة؛ وما عداه للمنطقة القديمة ونطاقه الوكيل.
-- ---------------------------------------------------------------------------

create or replace view public.commission_qualifying_events as
select
  e.saas_event_id,
  e.event_created_at,
  e.username_key,
  e.saas_user_id,
  e.profile_name as package_code,
  e.raw_parent,
  e.fdt_code,
  e.import_batch_id,
  -- الهوية القانونية أولاً، ثم معرّف SaaS المستقر، ثم اسم المستخدم. الاسم
  -- المعروض لا يدخل في هذا أبداً.
  coalesce(si.id::text, e.saas_user_id, e.username_key) as subscriber_key,
  si.id as subscriber_identity_id,
  si.identity_status,
  si.source_classification,
  coalesce(si.effective_agent_id, al.agent_id) as effective_agent_id,
  ag.official_name as agent_name,
  f.zone as fdt_zone,
  case when f.zone = 'new' then 'new' else 'old' end as zone,
  case when f.zone = 'new' then 'FDT' else 'AGENT' end as scope_type,
  case when f.zone = 'new' then e.fdt_code
       else coalesce(si.effective_agent_id, al.agent_id)::text end as scope_id,
  p.semantic_category as package_category,
  al.resolution as parent_resolution
from public.saas_activation_events e
left join public.subscriber_identities si on si.username_key = e.username_key
left join public.agent_aliases al
  on al.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(e.raw_parent, '')))
 and al.active
left join public.agents ag on ag.id = coalesce(si.effective_agent_id, al.agent_id)
left join public.fdts f on f.code = e.fdt_code
left join public.packages p on p.code = e.profile_name
where coalesce(e.canceled, false) = false;

-- ---------------------------------------------------------------------------
-- 6. الحساب.
--
-- خطوة واحدة تُنتج: استثناءات، استحقاقات لكل حدث، ولقطات لكل نطاق. تُستدعى
-- للعرض المتوقَّع وللاعتماد معاً، فلا يختلف ما يُعرض عمّا يُعتمد.
-- ---------------------------------------------------------------------------

create or replace function public.calculate_commission_cycle(
  p_cycle_id uuid,
  p_finalize boolean default false,
  p_request_id uuid default null,
  p_completeness_override_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_version uuid;
  v_blocking integer := 0;
  v_incomplete integer := 0;
  v_events integer := 0;
  v_subscribers integer := 0;
  v_gross bigint := 0;
  v_scopes integer := 0;
begin
  perform public.require_capability(
    case when p_finalize then 'commission.finalize' else 'commission.view' end);

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;

  -- المعتمَدة والمقفلة لا يُعاد حسابها. النتيجة التاريخية تبقى كما حُسبت.
  if v_cycle.status in ('FINALIZED','PARTIALLY_PAID','PAID','CLOSED') then
    raise exception 'A finalized commission cycle is not recalculated' using errcode = '42501';
  end if;
  if v_cycle.engine_version <> 'VNEXT' then
    raise exception 'This cycle is not a vNext cycle' using errcode = '42501';
  end if;

  v_version := v_cycle.scheme_version_id;
  if v_version is null then
    select v.id into v_version
    from public.commission_scheme_versions v
    join public.commission_schemes s on s.id = v.scheme_id
    where v.status = 'PUBLISHED' and s.is_active
      and (v.effective_from is null or v.effective_from <= v_cycle.period_start)
    order by v.effective_from desc nulls last, v.version desc
    limit 1;
  end if;
  if v_version is null then
    raise exception 'No published commission scheme version applies' using errcode = 'P0002';
  end if;

  -- المسودّة تُمسح وتُعاد؛ ولا شيء معتمد يُمَس لأن الاعتماد يمنع الوصول هنا.
  delete from public.commission_event_entitlements where cycle_id = p_cycle_id;
  delete from public.commission_cycle_snapshots where cycle_id = p_cycle_id and finalized_at is null;
  -- المفتوح وحده يُمسح ويُعاد بناؤه. المحسوم يبقى: قرار المراجِع ليس نتيجة
  -- حساب تُعاد كتابتها في كل تشغيل.
  delete from public.commission_exceptions where cycle_id = p_cycle_id and status = 'OPEN';

  -- الأحداث الداخلة في الدورة.
  -- تُسقَط أولاً: on commit drop تعني نهاية المعاملة، والدالة قد تُستدعى
  -- مرتين داخل معاملة واحدة (عرض متوقَّع ثم اعتماد).
  drop table if exists tmp_cycle_events;
  drop table if exists tmp_billable;
  drop table if exists tmp_scope;
  create temporary table tmp_cycle_events on commit drop as
  select q.*
  from public.commission_qualifying_events q
  where q.event_created_at >= v_cycle.period_start
    and q.event_created_at < (v_cycle.period_end + 1);

  -- ---- الاستثناءات: يُسجَّل كل ما لا يُحتسب، ولا يُسقَط حدث بصمت. ----
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_PACKAGE',
         'package not in the master list', true
  from tmp_cycle_events t
  -- المجهول دلالةً كالمجهول تماماً: كلاهما لا يُعرَف حكمه، فيُراجَع.
  -- وخدمة الدَّين ليست استثناءً — استبعادها قرار معروف لا غموض.
  where t.package_category is null or t.package_category = 'UNKNOWN'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_PACKAGE'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'IDENTITY_CONFLICT',
         'subscriber identity is in conflict', true
  from tmp_cycle_events t where t.identity_status = 'CONFLICT'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'IDENTITY_CONFLICT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_AGENT',
         'the raw parent does not resolve to an agent', true
  from tmp_cycle_events t
  where t.zone = 'old' and t.effective_agent_id is null
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_AGENT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_FDT',
         'the event has no usable scope', true
  from tmp_cycle_events t where t.scope_id is null
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_FDT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  -- اكتمال المصدر: يُسجَّل استثناءً واحداً للدورة لا لكل حدث.
  select count(*) into v_incomplete
  from public.saas_import_batches b
  where b.id in (select distinct import_batch_id from tmp_cycle_events)
    and b.completeness_status <> 'COMPLETE';
  if v_incomplete > 0
     and not exists (select 1 from public.commission_exceptions x
                     where x.cycle_id = p_cycle_id and x.reason_code = 'SOURCE_INCOMPLETE'
                       and x.status <> 'OPEN') then
    insert into public.commission_exceptions
      (cycle_id, reason_code, detail, blocks_finalization)
    values (p_cycle_id, 'SOURCE_INCOMPLETE',
            v_incomplete::text || ' source batch(es) are not proven complete', true)
    on conflict do nothing;
  end if;

  -- ---- الأحداث المُعمَّلة: ما نجا من كل ما سبق. ----
  create temporary table tmp_billable on commit drop as
  select t.*
  from tmp_cycle_events t
  where t.package_category = 'PAID_PACKAGE'      -- خدمة الدَّين والمجهول خارجان
    and t.scope_id is not null
    and coalesce(t.identity_status, 'UNMATCHED') <> 'CONFLICT'
    and coalesce(t.source_classification, 'RESELLER') <> 'DIRECT_COMPANY'
    and exists (
      select 1 from public.commission_package_rates r
      join public.commission_tier_definitions d on d.id = r.tier_definition_id
      where d.scheme_version_id = v_version and r.package_code = t.package_code and r.qualifies);

  -- ---- أساس الشريحة: مشترك واحد مرة واحدة داخل نطاقه. ----
  create temporary table tmp_scope on commit drop as
  select
    b.scope_type, b.scope_id, b.zone,
    count(distinct b.subscriber_key)::integer as unique_subscribers,
    count(distinct b.saas_event_id)::integer as qualifying_events,
    max(b.agent_name) as scope_label
  from tmp_billable b
  group by b.scope_type, b.scope_id, b.zone;

  -- ---- الاستحقاق لكل حدث بسعر شريحة نطاقه. ----
  insert into public.commission_event_entitlements (
    cycle_id, activation_event_id, subscriber_key, subscriber_identity_id, saas_user_id,
    scope_type, scope_id, zone, effective_agent_id, agent_name, fdt_code, raw_parent,
    package_code, scheme_version_id, tier_code, amount, status, event_at)
  select
    p_cycle_id, b.saas_event_id, b.subscriber_key, b.subscriber_identity_id, b.saas_user_id,
    b.scope_type, b.scope_id, b.zone, b.effective_agent_id, b.agent_name, b.fdt_code,
    b.raw_parent, b.package_code, v_version,
    (public.commission_tier_for_subscribers(v_version, b.zone, s.unique_subscribers)).code,
    coalesce(public.commission_rate_for(v_version, b.zone, s.unique_subscribers, b.package_code), 0),
    case when p_finalize then 'FINAL' else 'PROJECTED' end,
    b.event_created_at
  from tmp_billable b
  join tmp_scope s on s.scope_type = b.scope_type and s.scope_id = b.scope_id;

  -- ---- اللقطة لكل نطاق. ----
  insert into public.commission_cycle_snapshots (
    cycle_id, scheme_version_id, scope_type, scope_id, scope_label, zone,
    unique_activated_subscribers, qualifying_event_count, tier_code,
    package_breakdown, gross_commission, source_batch_ids,
    measurement_start, measurement_end, finalized_at)
  select
    p_cycle_id, v_version, s.scope_type, s.scope_id, s.scope_label, s.zone,
    s.unique_subscribers, s.qualifying_events,
    (public.commission_tier_for_subscribers(v_version, s.zone, s.unique_subscribers)).code,
    coalesce((select jsonb_object_agg(x.package_code, x.n)
              from (select e.package_code, count(*) as n
                    from public.commission_event_entitlements e
                    where e.cycle_id = p_cycle_id and e.scope_type = s.scope_type
                      and e.scope_id = s.scope_id
                    group by e.package_code) x), '{}'::jsonb),
    coalesce((select sum(e.amount) from public.commission_event_entitlements e
              where e.cycle_id = p_cycle_id and e.scope_type = s.scope_type
                and e.scope_id = s.scope_id), 0),
    coalesce((select array_agg(distinct t.import_batch_id) from tmp_cycle_events t), '{}'),
    v_cycle.period_start, v_cycle.period_end,
    case when p_finalize then now() else null end
  from tmp_scope s;

  select count(*) into v_blocking from public.commission_exceptions
  where cycle_id = p_cycle_id and status = 'OPEN' and blocks_finalization;
  select count(*), coalesce(sum(amount), 0) into v_events, v_gross
  from public.commission_event_entitlements where cycle_id = p_cycle_id;
  select count(*), coalesce(sum(unique_activated_subscribers), 0)
  into v_scopes, v_subscribers
  from public.commission_cycle_snapshots where cycle_id = p_cycle_id;

  if p_finalize then
    if p_request_id is null then
      raise exception 'request_id is required to finalize' using errcode = '22023';
    end if;
    -- الاعتماد من مصدر غير مُثبت الاكتمال يحتاج تصريحاً مكتوباً، ولا يمرّ صمتاً.
    if v_blocking > 0 and btrim(coalesce(p_completeness_override_reason, '')) = '' then
      raise exception 'Finalization is blocked by % open exception(s)', v_blocking
        using errcode = '42501';
    end if;

    update public.commission_cycles
    set status = 'FINALIZED', scheme_version_id = v_version,
        finalized_by = v_actor, finalized_at = now(), calculated_at = now()
    where id = p_cycle_id;

    insert into public.audit_logs (
      actor_id, action, field, new_value, entity_type, entity_id, request_id, extra)
    values (v_actor, 'commission.cycle.finalized', 'status', 'FINALIZED',
      'commission_cycle', p_cycle_id, p_request_id,
      'events=' || v_events::text || ' subscribers=' || v_subscribers::text
      || ' gross=' || v_gross::text
      || coalesce(' override=' || nullif(btrim(coalesce(p_completeness_override_reason,'')),''), ''));
  else
    update public.commission_cycles
    set calculated_at = now(),
        status = case when status = 'DRAFT' then 'UNDER_REVIEW' else status end
    where id = p_cycle_id;
  end if;

  return jsonb_build_object(
    'cycle_id', p_cycle_id,
    'scheme_version_id', v_version,
    'finalized', p_finalize,
    'scopes', v_scopes,
    'unique_activated_subscribers', v_subscribers,
    'qualifying_events', v_events,
    'gross_commission', v_gross,
    'blocking_exceptions', v_blocking
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['commission_cycles','commission_event_entitlements',
                           'commission_cycle_snapshots','commission_exceptions'] loop
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

-- الرؤية تحمل أسماء أب خام ومعرّفات؛ تُقصَر على من يملك عرض العمولات.
revoke all on table public.commission_qualifying_events from authenticated, anon, public;
grant select on table public.commission_qualifying_events to authenticated;

revoke execute on function public.protect_finalized_snapshot() from public, anon, authenticated;
revoke execute on function public.calculate_commission_cycle(uuid, boolean, uuid, text)
  from public, anon;
grant execute on function public.calculate_commission_cycle(uuid, boolean, uuid, text)
  to authenticated;

commit;
