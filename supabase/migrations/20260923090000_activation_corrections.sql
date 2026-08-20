-- ---------------------------------------------------------------------------
-- تصحيح التفعيلات
--
-- المشغّل يرى في دورةٍ أنّ كابينةً سُجّل لها تفعيلٌ لا يعرفه، أو أن تفعيلاً
-- جرى ولم يصل في الملفّ. ولم يكن أمامه إلا أمران كلاهما خطأ: أن يُعدّل
-- الرقم المحسوب في الجدول — فيصير الرقم رأياً لا حساباً — أو أن يُعدّل
-- الصفّ المستورَد، فيضيع ما ورد فعلاً ولا يبقى ما يُراجَع.
--
-- فالتصحيح هنا طبقةٌ ثالثة: المصدر يبقى كما ورد، والمحرّك يبقى هو الحاسب،
-- ويُسجَّل بينهما ما استُبعد وما أُضيف — بفاعله وسببه ووقته.
--
-- وقاعدتان تحكمان الشكل:
--
--   الاستبعاد يشير إلى حدثٍ بعينه، لا إلى عددٍ يُطرح. «انقص واحداً» لا
--   يُبقي أثراً يُراجَع بعد شهر.
--
--   والإضافة تلزمها هوية مشترك. أساس الشريحة عددُ المشتركين الفريدين، فلو
--   قُبلت زيادةٌ مجهولة لصارت تزيد الأحداث ولا تُعرف أثرها في الشريحة —
--   وهذا بالضبط ما يجعل رقماً يبدو صحيحاً وهو ليس كذلك.
-- ---------------------------------------------------------------------------

begin;

create table if not exists public.activation_corrections (
  id                  uuid primary key default gen_random_uuid(),
  cycle_id            uuid not null references public.commission_cycles(id),
  correction_type     text not null check (correction_type in ('EXCLUDE', 'ADD')),

  -- للاستبعاد: الحدث المقصود بعينه.
  source_event_id     text,

  -- للإضافة: ما يلزم ليمرّ الحدث بنفس اشتقاقات المحرّك.
  subscriber_username text,
  package_code        text,
  event_at            timestamptz,
  fdt_code            text,
  raw_parent          text,

  reason              text not null check (btrim(reason) <> ''),
  request_id          uuid not null unique,
  status              text not null default 'ACTIVE'
                        check (status in ('ACTIVE', 'REVOKED')),
  created_by          uuid not null references auth.users(id),
  created_at          timestamptz not null default now(),
  revoked_by          uuid references auth.users(id),
  revoked_at          timestamptz,
  revoke_reason       text,

  constraint activation_corrections_shape check (
    (correction_type = 'EXCLUDE'
       and source_event_id is not null
       and subscriber_username is null and package_code is null
       and event_at is null and fdt_code is null)
    or
    (correction_type = 'ADD'
       and source_event_id is null
       and btrim(coalesce(subscriber_username, '')) <> ''
       and btrim(coalesce(package_code, '')) <> ''
       and event_at is not null
       and btrim(coalesce(fdt_code, '')) <> '')),

  constraint activation_corrections_revoked_is_attributed check (
    status = 'ACTIVE' or (revoked_by is not null and revoked_at is not null
                          and btrim(coalesce(revoke_reason, '')) <> ''))
);

comment on table public.activation_corrections is
  'طبقة تصحيح فوق الأحداث المستورَدة. المصدر لا يُمسّ، والمحرّك يقرأ الطبقتين.';

-- استبعادٌ واحد فعّال لكل حدث في الدورة الواحدة.
create unique index if not exists activation_corrections_exclude_key
  on public.activation_corrections (cycle_id, source_event_id)
  where correction_type = 'EXCLUDE' and status = 'ACTIVE';

create index if not exists activation_corrections_cycle_idx
  on public.activation_corrections (cycle_id, correction_type, status);

alter table public.activation_corrections enable row level security;

-- السياسة بلا منحٍ لا تفعل شيئاً: المنع يقع عند الصلاحية قبل أن تُقرأ
-- السياسة أصلاً. فالقراءة تُمنح، والكتابة لا تُمنح لأحد — تمرّ بالدوالّ.
revoke all on table public.activation_corrections from authenticated, anon;
grant select on table public.activation_corrections to authenticated;

drop policy if exists activation_corrections_select on public.activation_corrections;
create policy activation_corrections_select on public.activation_corrections
  for select to authenticated
  using ((select public.has_capability('commission.view')));

-- ---------------------------------------------------------------------------
-- المضمون لا يُعدَّل بعد كتابته
--
-- التصحيح مستندٌ لا حقل. لو جاز تعديل سببه أو حدثه بعد أن حُسب به مال،
-- لصار سجلّ التدقيق يروي غير ما جرى. والخطأ يُعالَج بإلغاءٍ مُسجَّل، لا
-- بإعادة كتابةٍ صامتة.
-- ---------------------------------------------------------------------------

create or replace function public.protect_activation_correction()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'A correction is not deleted; revoke it instead'
      using errcode = '42501';
  end if;

  if new.cycle_id is distinct from old.cycle_id
     or new.correction_type is distinct from old.correction_type
     or new.source_event_id is distinct from old.source_event_id
     or new.subscriber_username is distinct from old.subscriber_username
     or new.package_code is distinct from old.package_code
     or new.event_at is distinct from old.event_at
     or new.fdt_code is distinct from old.fdt_code
     or new.raw_parent is distinct from old.raw_parent
     or new.reason is distinct from old.reason
     or new.request_id is distinct from old.request_id
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'A correction is immutable; only its status may change'
      using errcode = '42501';
  end if;

  if old.status = 'REVOKED' then
    raise exception 'This correction was already revoked' using errcode = '42501';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_protect_activation_correction on public.activation_corrections;
create trigger trg_protect_activation_correction
  before update or delete on public.activation_corrections
  for each row execute function public.protect_activation_correction();

-- ---------------------------------------------------------------------------
-- المحرّك يقرأ الطبقتين
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
as $fn$
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
  v_from timestamptz;
  v_to timestamptz;
begin
  perform public.require_capability(
    case when p_finalize then 'commission.finalize' else 'commission.view' end);

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;

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

  delete from public.commission_event_entitlements where cycle_id = p_cycle_id;
  delete from public.commission_cycle_snapshots where cycle_id = p_cycle_id and finalized_at is null;
  delete from public.commission_exceptions where cycle_id = p_cycle_id and status = 'OPEN';

  -- النافذة بتوقيت العمل، لا بتوقيت جلسة القاعدة.
  v_from := public.cycle_window_start(v_cycle.period_start);
  v_to := public.cycle_window_end(v_cycle.period_end);

  drop table if exists tmp_cycle_events;
  drop table if exists tmp_billable;
  drop table if exists tmp_scope;
  -- تصحيحات التفعيلات تُطبَّق هنا، على مدخل المحرّك لا على مصدره.
  --
  -- المصدر المستورَد لا يُمسّ أبداً: صفّ الملفّ يبقى كما ورد. والتصحيح
  -- طبقةٌ فوقه تُقرأ عند كل حساب، فيبقى الأصل قابلاً للمراجعة ويبقى الفرق
  -- بين «ما ورد» و«ما اعتُمد» مرئياً ومُدقَّقاً.
  --
  -- والإضافة اليدوية تلزمها هوية مشترك: أساس الشريحة عددُ المشتركين
  -- الفريدين، فزيادةٌ بلا مشترك تُفسد الشريحة بصمت.
  create temporary table tmp_cycle_events on commit drop as
  select q.*
  from public.commission_qualifying_events q
  where q.event_created_at >= v_from
    and q.event_created_at < v_to
    and not exists (
      select 1 from public.activation_corrections c
      where c.cycle_id = p_cycle_id
        and c.correction_type = 'EXCLUDE'
        and c.status = 'ACTIVE'
        and c.source_event_id = q.saas_event_id)

  union all

  -- الحدث المُضاف يمرّ بنفس الاشتقاقات التي يمرّ بها الوارد: الهوية،
  -- والاسم البديل، والكابينة، والنطاق. لا مسارَ ثانٍ لحساب النطاق.
  select
    'MANUAL-' || c.id::text,
    c.event_at,
    lower(btrim(c.subscriber_username)),
    null::text,
    c.package_code,
    c.raw_parent,
    c.fdt_code,
    null::uuid,
    coalesce(si.id::text, lower(btrim(c.subscriber_username))),
    si.id,
    si.identity_status,
    si.source_classification,
    coalesce(si.effective_agent_id, al.agent_id),
    ag.official_name,
    f.zone,
    case when c.fdt_code is not null and f.code is null then 'unresolved'
         when f.zone = 'new' then 'new' else 'old' end,
    case when c.fdt_code is not null and f.code is null then 'UNRESOLVED'
         when f.zone = 'new' then 'FDT' else 'AGENT' end,
    case when c.fdt_code is not null and f.code is null then null
         when f.zone = 'new' then c.fdt_code
         else coalesce(si.effective_agent_id, al.agent_id)::text end,
    p.semantic_category,
    al.resolution
  from public.activation_corrections c
  left join public.subscriber_identities si
    on si.username_key = lower(btrim(c.subscriber_username))
  left join public.agent_aliases al
    on al.alias_key = lower(btrim(coalesce(c.raw_parent, ''))) and al.active
  left join public.agents ag on ag.id = coalesce(si.effective_agent_id, al.agent_id)
  left join public.fdts f on f.code = c.fdt_code
  left join public.packages p on p.code = c.package_code
  where c.cycle_id = p_cycle_id
    and c.correction_type = 'ADD'
    and c.status = 'ACTIVE'
    and c.event_at >= v_from
    and c.event_at < v_to;

  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_PACKAGE',
         'package not in the master list', true
  from tmp_cycle_events t
  where (t.package_category is null or t.package_category = 'UNKNOWN')
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

  -- الأب المجهول: من لم يُحَلّ إلى وكيل ولم يُعرَف شركةً مباشرة.
  -- الشركة المباشرة محلولة ومستبعدة عن عمد، فليست مجهولة.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_AGENT',
         'the raw parent does not resolve to an agent', true
  from tmp_cycle_events t
  where t.zone = 'old' and t.effective_agent_id is null
    and coalesce(t.parent_resolution, 'needs_review') <> 'direct_company'
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_AGENT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

  -- الكابينة تُشترط في المنطقة الجديدة وحدها؛ القديمة شريحتها بالوكيل.
  insert into public.commission_exceptions
    (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
  select p_cycle_id, t.saas_event_id, t.subscriber_key, 'UNKNOWN_FDT',
         case when t.zone = 'unresolved'
              then 'cabinet ' || coalesce(t.fdt_code, '?') || ' is not in the FDT master, so its zone is undecided'
              else 'the event is in the new zone but carries no usable cabinet' end,
         true
  from tmp_cycle_events t
  where (t.zone = 'unresolved' or (t.zone = 'new' and t.scope_id is null))
    and not exists (
      select 1 from public.commission_exceptions x
      where x.cycle_id = p_cycle_id and x.reason_code = 'UNKNOWN_FDT'
        and x.activation_event_id is not distinct from t.saas_event_id
        and x.status <> 'OPEN')
  on conflict do nothing;

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

  create temporary table tmp_billable on commit drop as
  select t.*
  from tmp_cycle_events t
  where t.package_category = 'PAID_PACKAGE'
    and t.scope_id is not null
    and coalesce(t.identity_status, 'UNMATCHED') <> 'CONFLICT'
    and coalesce(t.source_classification, 'RESELLER') <> 'DIRECT_COMPANY'
    and exists (
      select 1 from public.commission_package_rates r
      join public.commission_tier_definitions d on d.id = r.tier_definition_id
      where d.scheme_version_id = v_version and r.package_code = t.package_code and r.qualifies);

  create temporary table tmp_scope on commit drop as
  select
    b.scope_type, b.scope_id, b.zone,
    count(distinct b.subscriber_key)::integer as unique_subscribers,
    count(distinct b.saas_event_id)::integer as qualifying_events,
    max(b.agent_name) as scope_label
  from tmp_billable b
  group by b.scope_type, b.scope_id, b.zone;

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
    'blocking_exceptions', v_blocking,
    'window_start', v_from,
    'window_end', v_to
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- الدوالّ
-- ---------------------------------------------------------------------------

/** يرفض التصحيح على دورةٍ اعتُمدت: ما حُسب به مالٌ نهائيّ لا يُعاد فتحه هنا. */
create or replace function public.assert_cycle_correctable(p_cycle_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_status text;
begin
  select status into v_status from public.commission_cycles where id = p_cycle_id;
  if v_status is null then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  if v_status in ('FINALIZED', 'PARTIALLY_PAID', 'PAID', 'CLOSED') then
    raise exception 'This cycle is % and cannot be corrected here; reopen it first', v_status
      using errcode = '42501';
  end if;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- استبعاد حدثٍ قائم
-- ---------------------------------------------------------------------------

create or replace function public.exclude_activation_event(
  p_cycle_id uuid,
  p_source_event_id text,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_event public.commission_qualifying_events%rowtype;
  v_from  timestamptz;
  v_to    timestamptz;
  v_cycle public.commission_cycles%rowtype;
begin
  perform public.require_capability('commission.manage_cycle');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'An exclusion must state its reason' using errcode = '22023';
  end if;

  perform public.assert_cycle_correctable(p_cycle_id);

  if exists (select 1 from public.activation_corrections where request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.commission_cycles where id = p_cycle_id;
  v_from := public.cycle_window_start(v_cycle.period_start);
  v_to   := public.cycle_window_end(v_cycle.period_end);

  -- الحدث يجب أن يكون موجوداً وداخل نافذة الدورة فعلاً. استبعاد ما ليس
  -- فيها لا يُغيّر رقماً، ويترك في السجلّ تصحيحاً بلا أثر يُربك من يقرأه.
  select * into v_event from public.commission_qualifying_events
  where saas_event_id = p_source_event_id
    and event_created_at >= v_from and event_created_at < v_to;

  if not found then
    raise exception 'No such activation event inside this cycle window'
      using errcode = 'P0002';
  end if;

  insert into public.activation_corrections
    (cycle_id, correction_type, source_event_id, reason, request_id, created_by)
  values (p_cycle_id, 'EXCLUDE', p_source_event_id, btrim(p_reason), p_request_id, v_actor)
  returning id into v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.activation.excluded', 'saas_event_id',
    p_source_event_id, 'EXCLUDED', 'activation_correction', v_id, p_request_id,
    'cycle=' || p_cycle_id::text
      || ' subscriber=' || coalesce(v_event.subscriber_key, '?')
      || ' package=' || coalesce(v_event.package_code, '?')
      || ' reason=' || btrim(p_reason));

  return jsonb_build_object(
    'replayed', false, 'correction_id', v_id,
    'subscriber_key', v_event.subscriber_key,
    'package_code', v_event.package_code,
    'scope_type', v_event.scope_type, 'scope_id', v_event.scope_id,
    'recalculate_required', true);
end;
$fn$;

revoke execute on function public.exclude_activation_event(uuid,text,text,uuid) from public, anon;
grant execute on function public.exclude_activation_event(uuid,text,text,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- إضافة حدثٍ مُتحقَّق منه
-- ---------------------------------------------------------------------------

create or replace function public.add_activation_correction(
  p_cycle_id uuid,
  p_subscriber_username text,
  p_package_code text,
  p_event_at timestamptz,
  p_fdt_code text,
  p_reason text,
  p_request_id uuid,
  p_raw_parent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_cycle public.commission_cycles%rowtype;
  v_from  timestamptz;
  v_to    timestamptz;
  v_key   text := lower(btrim(coalesce(p_subscriber_username, '')));
begin
  perform public.require_capability('commission.manage_cycle');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'An added activation must state its reason' using errcode = '22023';
  end if;

  -- الهوية شرطٌ لا تزيين: أساس الشريحة عددُ المشتركين الفريدين، فإضافةٌ
  -- بلا مشترك تزيد الأحداث ولا يُعرف أثرها في الشريحة.
  if v_key = '' then
    raise exception 'An added activation must name its subscriber' using errcode = '22023';
  end if;
  if btrim(coalesce(p_fdt_code, '')) = '' then
    raise exception 'An added activation must name its cabinet' using errcode = '22023';
  end if;
  if p_event_at is null then
    raise exception 'An added activation must carry its time' using errcode = '22023';
  end if;

  perform public.assert_cycle_correctable(p_cycle_id);

  if exists (select 1 from public.activation_corrections where request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  if not exists (select 1 from public.packages where code = btrim(p_package_code)) then
    raise exception 'Unknown package %', p_package_code using errcode = '22023';
  end if;

  select * into v_cycle from public.commission_cycles where id = p_cycle_id;
  v_from := public.cycle_window_start(v_cycle.period_start);
  v_to   := public.cycle_window_end(v_cycle.period_end);

  if p_event_at < v_from or p_event_at >= v_to then
    raise exception 'That time is outside this cycle window (% .. %)', v_from, v_to
      using errcode = '22023';
  end if;

  insert into public.activation_corrections
    (cycle_id, correction_type, subscriber_username, package_code, event_at,
     fdt_code, raw_parent, reason, request_id, created_by)
  values (p_cycle_id, 'ADD', btrim(p_subscriber_username), btrim(p_package_code),
          p_event_at, btrim(p_fdt_code), nullif(btrim(coalesce(p_raw_parent, '')), ''),
          btrim(p_reason), p_request_id, v_actor)
  returning id into v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.activation.added', 'subscriber',
    'NONE', v_key, 'activation_correction', v_id, p_request_id,
    'cycle=' || p_cycle_id::text
      || ' package=' || btrim(p_package_code)
      || ' fdt=' || btrim(p_fdt_code)
      || ' at=' || p_event_at::text
      || ' reason=' || btrim(p_reason));

  return jsonb_build_object(
    'replayed', false, 'correction_id', v_id,
    'subscriber_key', v_key, 'synthetic_event_id', 'MANUAL-' || v_id::text,
    'recalculate_required', true);
end;
$fn$;

revoke execute on function public.add_activation_correction(
  uuid,text,text,timestamptz,text,text,uuid,text) from public, anon;
grant execute on function public.add_activation_correction(
  uuid,text,text,timestamptz,text,text,uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- إلغاء تصحيح
-- ---------------------------------------------------------------------------

create or replace function public.revoke_activation_correction(
  p_correction_id uuid,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_row   public.activation_corrections%rowtype;
begin
  perform public.require_capability('commission.manage_cycle');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A revocation must state its reason' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id
               and action = 'commission.activation.correction.revoked') then
    return jsonb_build_object('replayed', true);
  end if;

  select * into v_row from public.activation_corrections
  where id = p_correction_id for update;
  if not found then
    raise exception 'Correction was not found' using errcode = 'P0002';
  end if;

  perform public.assert_cycle_correctable(v_row.cycle_id);

  update public.activation_corrections
  set status = 'REVOKED', revoked_by = v_actor, revoked_at = now(),
      revoke_reason = btrim(p_reason)
  where id = p_correction_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.activation.correction.revoked', 'status',
    'ACTIVE', 'REVOKED', 'activation_correction', p_correction_id, p_request_id,
    'cycle=' || v_row.cycle_id::text || ' reason=' || btrim(p_reason));

  return jsonb_build_object('replayed', false, 'correction_id', p_correction_id,
                            'recalculate_required', true);
end;
$fn$;

revoke execute on function public.revoke_activation_correction(uuid,text,uuid)
  from public, anon;
grant execute on function public.revoke_activation_correction(uuid,text,uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- القراءة: ما استُبعد وما أُضيف، وأثر كلٍّ منهما
-- ---------------------------------------------------------------------------

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
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('commission.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select c.id, c.correction_type, c.status, c.reason, c.created_at, c.request_id,
           c.source_event_id, c.subscriber_username, c.package_code, c.event_at,
           c.fdt_code, c.raw_parent, c.revoke_reason, c.revoked_at,
           p.email as actor_email,
           -- الاستبعاد يُعرَف أثره من الحدث الذي أشار إليه.
           coalesce(c.fdt_code, q.fdt_code) as effective_fdt,
           coalesce(lower(btrim(c.subscriber_username)), q.subscriber_key) as subscriber,
           coalesce(c.package_code, q.package_code) as package,
           coalesce(q.scope_type,
             case when f.zone = 'new' then 'FDT' else 'AGENT' end) as scope_type,
           coalesce(q.scope_id,
             case when f.zone = 'new' then c.fdt_code else null end) as scope_id
    from public.activation_corrections c
    left join public.profiles p on p.id = c.created_by
    left join public.commission_qualifying_events q
      on q.saas_event_id = c.source_event_id
    left join public.fdts f on f.code = c.fdt_code
    where c.cycle_id = p_cycle_id
      and (p_status is null or c.status = p_status)
  ),
  filtered as (
    select * from kept
    where (p_scope_type is null or scope_type = p_scope_type)
      and (p_scope_id is null or scope_id = p_scope_id)
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from filtered k order by k.created_at desc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from filtered;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_activation_corrections(
  uuid,text,text,text,integer,integer) from public, anon;
grant execute on function public.page_activation_corrections(
  uuid,text,text,text,integer,integer) to authenticated;

commit;
