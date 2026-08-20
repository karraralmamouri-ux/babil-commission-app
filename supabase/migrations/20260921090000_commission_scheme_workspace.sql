-- ---------------------------------------------------------------------------
-- مخطّط العمولة: قراءةٌ للمنشور، ومسوّدةٌ لما يُراد تغييره
--
-- «أسعار العمولات والتير» كان زرّاً ينادي openSettingsSection على قسمٍ يعيش
-- في المساحة السابقة، وهي مخفيّة خارج #/legacy. فكان الزرّ لا يفعل شيئاً.
--
-- والبديل ليس إحياء المحرّر القديم — ذاك كان يحرّر أسعار الشهر في الحالة
-- المحليّة — بل عرض المخطّط المنشور كما هو في القاعدة، وتغييرُه بنسخةٍ
-- جديدة لا بتعديل المنشور.
--
-- والمنشور محميّ أصلاً بمُشغِّلات على الجداول الثلاثة، فهذه الدوالّ لا
-- تُضيف حمايةً بل تعمل داخلها: كلّها ترفض ما ليس DRAFT قبل أن تصل إليها.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. القراءة
-- ---------------------------------------------------------------------------

create or replace function public.commission_scheme_detail(
  p_version_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
  v_doc jsonb;
begin
  perform public.require_capability('commission.view');

  -- بلا معرّف: النسخة المنشورة. وهي المرجع الذي يُحسب به المال اليوم.
  v_id := coalesce(
    p_version_id,
    (select v.id from public.commission_scheme_versions v
     where v.status = 'PUBLISHED' order by v.version desc limit 1));

  if v_id is null then
    return jsonb_build_object('found', false);
  end if;

  select jsonb_build_object(
    'found', true,
    'version', to_jsonb(v) - 'scheme_id',
    'scheme', to_jsonb(s),
    'published_by_email', (select p.email from public.profiles p where p.id = v.published_by),
    'created_by_email',   (select p.email from public.profiles p where p.id = v.created_by),
    'packages', (
      select coalesce(jsonb_agg(distinct r.package_code order by r.package_code), '[]'::jsonb)
      from public.commission_tier_definitions t
      join public.commission_package_rates r on r.tier_definition_id = t.id
      where t.scheme_version_id = v.id),
    'tiers', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.zone_key, x.sequence), '[]'::jsonb)
      from (
        select t.id, t.sequence, t.code, t.label_ar, t.zone,
               coalesce(t.zone, '') as zone_key,
               t.min_subscribers, t.max_subscribers,
               (select coalesce(jsonb_object_agg(r.package_code,
                  jsonb_build_object('amount', r.amount, 'qualifies', r.qualifies)), '{}'::jsonb)
                from public.commission_package_rates r
                where r.tier_definition_id = t.id) as rates
        from public.commission_tier_definitions t
        where t.scheme_version_id = v.id) x),
    'versions', (
      select coalesce(jsonb_agg(to_jsonb(y) order by y.version desc), '[]'::jsonb)
      from (select v2.id, v2.version, v2.status, v2.effective_from, v2.published_at
            from public.commission_scheme_versions v2
            where v2.scheme_id = v.scheme_id) y))
  into v_doc
  from public.commission_scheme_versions v
  join public.commission_schemes s on s.id = v.scheme_id
  where v.id = v_id;

  return coalesce(v_doc, jsonb_build_object('found', false));
end;
$fn$;

revoke execute on function public.commission_scheme_detail(uuid) from public, anon;
grant execute on function public.commission_scheme_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. مسوّدة من النسخة القائمة
--
-- التغيير يبدأ بنسخةٍ كاملة: الشرائح والأسعار كما هي الآن، ثم تُعدَّل.
-- البدء من فراغٍ يُغري بنسيان باقةٍ فتصير أحداثها بلا سعر.
-- ---------------------------------------------------------------------------

create or replace function public.create_commission_draft(
  p_request_id uuid,
  p_from_version uuid default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_src   public.commission_scheme_versions%rowtype;
  v_new   uuid;
  v_next  integer;
begin
  perform public.require_capability('commission.configure');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_src from public.commission_scheme_versions
  where id = coalesce(p_from_version,
    (select id from public.commission_scheme_versions
     where status = 'PUBLISHED' order by version desc limit 1));

  if not found then
    raise exception 'No commission version to copy from' using errcode = 'P0002';
  end if;

  -- مسوّدةٌ واحدة في كل وقت: مسوّدتان تتنافسان على النشر تُربكان من يراجع.
  if exists (select 1 from public.commission_scheme_versions
             where scheme_id = v_src.scheme_id and status = 'DRAFT') then
    raise exception 'A draft already exists for this scheme; publish or discard it first'
      using errcode = '23505';
  end if;

  select max(version) + 1 into v_next from public.commission_scheme_versions
  where scheme_id = v_src.scheme_id;

  insert into public.commission_scheme_versions
    (scheme_id, version, status, tier_basis, old_zone_scope, new_zone_scope,
     notes, created_by)
  values (v_src.scheme_id, v_next, 'DRAFT', v_src.tier_basis,
          v_src.old_zone_scope, v_src.new_zone_scope,
          nullif(btrim(coalesce(p_notes, '')), ''), v_actor)
  returning id into v_new;

  insert into public.commission_tier_definitions
    (scheme_version_id, sequence, code, label_ar, min_subscribers, max_subscribers, zone)
  select v_new, t.sequence, t.code, t.label_ar, t.min_subscribers, t.max_subscribers, t.zone
  from public.commission_tier_definitions t
  where t.scheme_version_id = v_src.id;

  insert into public.commission_package_rates
    (tier_definition_id, package_code, amount, qualifies)
  select nt.id, r.package_code, r.amount, r.qualifies
  from public.commission_package_rates r
  join public.commission_tier_definitions ot on ot.id = r.tier_definition_id
  join public.commission_tier_definitions nt
    on nt.scheme_version_id = v_new and nt.code = ot.code
   and nt.zone is not distinct from ot.zone
  where ot.scheme_version_id = v_src.id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.version.drafted', 'version',
    v_src.version::text, v_next::text, 'commission_scheme_version', v_new, p_request_id,
    'from=' || v_src.id::text);

  return jsonb_build_object('replayed', false, 'version_id', v_new, 'version', v_next);
end;
$fn$;

revoke execute on function public.create_commission_draft(uuid,uuid,text) from public, anon;
grant execute on function public.create_commission_draft(uuid,uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. تعديل حدود الشريحة وأسعار الباقة — في المسوّدة وحدها
-- ---------------------------------------------------------------------------

create or replace function public.update_commission_draft_tier(
  p_tier_id uuid,
  p_min_subscribers integer,
  p_max_subscribers integer,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_tier  public.commission_tier_definitions%rowtype;
  v_status text;
begin
  perform public.require_capability('commission.configure');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true);
  end if;

  select * into v_tier from public.commission_tier_definitions where id = p_tier_id;
  if not found then
    raise exception 'Tier was not found' using errcode = 'P0002';
  end if;

  select status into v_status from public.commission_scheme_versions
  where id = v_tier.scheme_version_id;
  if v_status <> 'DRAFT' then
    raise exception 'Only a draft version can be edited; version is %', v_status
      using errcode = '42501';
  end if;

  if p_min_subscribers is null or p_min_subscribers < 0 then
    raise exception 'A tier needs a lower bound of zero or more' using errcode = '22023';
  end if;
  if p_max_subscribers is not null and p_max_subscribers < p_min_subscribers then
    raise exception 'The tier ends below where it starts' using errcode = '22023';
  end if;

  update public.commission_tier_definitions
  set min_subscribers = p_min_subscribers, max_subscribers = p_max_subscribers
  where id = p_tier_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.draft.tier.changed', v_tier.code,
    v_tier.min_subscribers::text || '..' || coalesce(v_tier.max_subscribers::text, '∞'),
    p_min_subscribers::text || '..' || coalesce(p_max_subscribers::text, '∞'),
    'commission_tier', p_tier_id, p_request_id,
    'version=' || v_tier.scheme_version_id::text);

  return jsonb_build_object('replayed', false, 'tier_id', p_tier_id);
end;
$fn$;

revoke execute on function public.update_commission_draft_tier(uuid,integer,integer,uuid)
  from public, anon;
grant execute on function public.update_commission_draft_tier(uuid,integer,integer,uuid)
  to authenticated;

create or replace function public.update_commission_draft_rate(
  p_tier_id uuid,
  p_package_code text,
  p_amount bigint,
  p_qualifies boolean,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_tier  public.commission_tier_definitions%rowtype;
  v_status text;
  v_before bigint;
begin
  perform public.require_capability('commission.configure');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true);
  end if;

  select * into v_tier from public.commission_tier_definitions where id = p_tier_id;
  if not found then
    raise exception 'Tier was not found' using errcode = 'P0002';
  end if;

  select status into v_status from public.commission_scheme_versions
  where id = v_tier.scheme_version_id;
  if v_status <> 'DRAFT' then
    raise exception 'Only a draft version can be edited; version is %', v_status
      using errcode = '42501';
  end if;

  if p_amount is null or p_amount < 0 then
    raise exception 'A rate cannot be negative' using errcode = '22023';
  end if;
  if not exists (select 1 from public.packages where code = p_package_code) then
    raise exception 'Unknown package %', p_package_code using errcode = '22023';
  end if;

  select amount into v_before from public.commission_package_rates
  where tier_definition_id = p_tier_id and package_code = p_package_code;

  insert into public.commission_package_rates
    (tier_definition_id, package_code, amount, qualifies)
  values (p_tier_id, p_package_code, p_amount, coalesce(p_qualifies, true))
  on conflict (tier_definition_id, package_code)
  do update set amount = excluded.amount, qualifies = excluded.qualifies;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.draft.rate.changed',
    v_tier.code || '/' || p_package_code,
    coalesce(v_before::text, 'NONE'), p_amount::text,
    'commission_tier', p_tier_id, p_request_id,
    'version=' || v_tier.scheme_version_id::text);

  return jsonb_build_object('replayed', false, 'tier_id', p_tier_id,
                            'package', p_package_code, 'amount', p_amount);
end;
$fn$;

revoke execute on function public.update_commission_draft_rate(uuid,text,bigint,boolean,uuid)
  from public, anon;
grant execute on function public.update_commission_draft_rate(uuid,text,bigint,boolean,uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. فحص المسوّدة قبل نشرها
--
-- ثلاثة عيوب تُفسد الحساب صامتةً: فجوةٌ بين شريحتين يقع فيها عددٌ فلا يجد
-- شريحته، وتداخلٌ يجعل العدد في شريحتين، وباقةٌ بلا سعر في شريحة.
-- ---------------------------------------------------------------------------

create or replace function public.validate_commission_draft(p_version_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_problems jsonb := '[]'::jsonb;
  v_status text;
begin
  perform public.require_capability('commission.view');

  select status into v_status from public.commission_scheme_versions where id = p_version_id;
  if v_status is null then
    return jsonb_build_object('found', false);
  end if;

  -- فجوة أو تداخل بين شريحةٍ وتاليتها، داخل كل نطاق على حدة.
  v_problems := v_problems || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', case when g.next_min > g.max_plus then 'GAP' else 'OVERLAP' end,
      'detail', g.code || ' → ' || g.next_code,
      'message', case when g.next_min > g.max_plus
        then 'فجوة: لا شريحة تغطّي ' || g.max_plus::text || '..' || (g.next_min - 1)::text
        else 'تداخل: ' || g.next_min::text || ' يقع في شريحتين' end))
    from (
      select t.code, t.zone,
             (t.max_subscribers + 1) as max_plus,
             lead(t.min_subscribers) over w as next_min,
             lead(t.code) over w as next_code
      from public.commission_tier_definitions t
      where t.scheme_version_id = p_version_id
      window w as (partition by coalesce(t.zone, '') order by t.sequence)) g
    where g.next_min is not null and g.max_plus is not null
      and g.next_min <> g.max_plus), '[]'::jsonb);

  -- باقةٌ مسعَّرة في شريحةٍ وغائبة عن أخرى.
  v_problems := v_problems || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'MISSING_RATE',
      'detail', t.code || ' / ' || pk.package_code,
      'message', 'لا سعر لهذه الباقة في هذه الشريحة'))
    from public.commission_tier_definitions t
    cross join (
      select distinct r.package_code
      from public.commission_package_rates r
      join public.commission_tier_definitions t2 on t2.id = r.tier_definition_id
      where t2.scheme_version_id = p_version_id) pk
    where t.scheme_version_id = p_version_id
      and not exists (
        select 1 from public.commission_package_rates r2
        where r2.tier_definition_id = t.id
          and r2.package_code = pk.package_code)), '[]'::jsonb);

  -- الشريحة الأخيرة يجب أن تكون مفتوحة، وإلا وقف الحساب عند سقفٍ لا بعده شيء.
  if not exists (
    select 1 from public.commission_tier_definitions
    where scheme_version_id = p_version_id and max_subscribers is null)
  then
    v_problems := v_problems || jsonb_build_array(jsonb_build_object(
      'kind', 'CLOSED_TOP',
      'detail', '—',
      'message', 'لا شريحة مفتوحة الأعلى: عددٌ فوق السقف لا يجد شريحته'));
  end if;

  return jsonb_build_object(
    'found', true,
    'status', v_status,
    'publishable', (v_status = 'DRAFT' and jsonb_array_length(v_problems) = 0),
    'problems', v_problems);
end;
$fn$;

revoke execute on function public.validate_commission_draft(uuid) from public, anon;
grant execute on function public.validate_commission_draft(uuid) to authenticated;

commit;
