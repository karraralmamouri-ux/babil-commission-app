-- إصلاح: min(uuid) غير موجودة في Postgres.
--
-- الدالة بُنيت في المهاجرة السابقة ولم تُستدعَ في أي اختبار، فمرّ الخطأ إلى
-- الإنتاج وظهر عند أول تشغيل حقيقي. الاختبار المرافق يستدعيها الآن فعلاً.
--
-- البديل array_agg مع ترتيب صريح: يعطي صفاً واحداً محدَّداً بدل الاعتماد على
-- ترتيب غير مضمون.
--
-- forward-only. لا أثر مالي.

begin;

create or replace function public.bootstrap_subscriber_identities()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created integer := 0;
  v_matched integer := 0;
  v_conflicts integer := 0;
begin
  with latest as (
    select distinct on (s.saas_user_id)
      s.saas_user_id, s.username, s.username_key, s.parent_name,
      s.fdt_code, s.fat_code, s.port_code
    from public.saas_user_snapshots s
    order by s.saas_user_id, s.snapshot_at desc, s.created_at desc
  ),
  registry as (
    select pg_catalog.lower(pg_catalog.btrim(sub.subscriber_id)) as key,
           count(*) as hits,
           (array_agg(sub.id order by sub.id))[1] as one
    from public.installation_subscribers sub
    group by 1
  )
  insert into public.subscriber_identities (
    installation_subscriber_id, saas_user_id, username, display_name,
    identity_status, match_method, match_evidence,
    source_classification, raw_parent, normalized_agent_id, effective_agent_id,
    fdt_code, fat_code, port_code
  )
  select
    case when r.hits = 1 then r.one else null end,
    l.saas_user_id, l.username, null,
    case when r.hits > 1 then 'CONFLICT'
         when r.hits = 1 then 'MATCHED'
         else 'UNMATCHED' end,
    case when r.hits = 1 then 'EXACT_USERNAME' else null end,
    jsonb_build_object('saas_user_id', l.saas_user_id, 'username_key', l.username_key,
                       'registry_hits', coalesce(r.hits, 0)),
    case when al.resolution = 'direct_company' then 'DIRECT_COMPANY'
         when al.agent_id is not null then 'RESELLER'
         else 'UNKNOWN_PARENT' end,
    l.parent_name, al.agent_id, al.agent_id,
    l.fdt_code, l.fat_code, l.port_code
  from latest l
  left join registry r on r.key = l.username_key
  left join public.agent_aliases al
    on al.alias_key = pg_catalog.lower(pg_catalog.btrim(coalesce(l.parent_name, '')))
   and al.active
  on conflict (saas_user_id) do nothing;

  get diagnostics v_created = row_count;
  select count(*) filter (where identity_status = 'MATCHED'),
         count(*) filter (where identity_status = 'CONFLICT')
  into v_matched, v_conflicts
  from public.subscriber_identities;

  return jsonb_build_object(
    'identities_created', v_created,
    'identities_total', (select count(*) from public.subscriber_identities),
    'matched_to_registry', v_matched,
    'conflicts', v_conflicts,
    'unmatched', (select count(*) from public.subscriber_identities
                  where identity_status = 'UNMATCHED'),
    'direct_company', (select count(*) from public.subscriber_identities
                       where source_classification = 'DIRECT_COMPANY'),
    'unknown_parent', (select count(*) from public.subscriber_identities
                       where source_classification = 'UNKNOWN_PARENT')
  );
end;
$$;

revoke execute on function public.bootstrap_subscriber_identities()
  from public, anon, authenticated;

commit;
