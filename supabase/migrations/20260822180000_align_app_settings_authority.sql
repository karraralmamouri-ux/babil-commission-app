-- توحيد سلطة تحرير الوكلاء والأسماء البديلة.
--
-- المشكلة القائمة: المفهوم نفسه (الوكيل، اسمه البديل، ملكية الكابينة) قابل
-- للتحرير في مكانين — app_settings.raw_import وجداول البيانات الرئيسية. ومرجعان
-- قابلان للتحرير لمفهوم واحد يفترقان حتماً، ثم يصير السؤال أيّهما الصحيح.
--
-- ما لا نفعله: حذف app_settings. الاستيراد القديم يقرؤه فعلاً، وحذفه يكسر مساراً
-- حياً بلا بديل. «تُزال التبعية المُثبَت عدم لزومها» — وهذه لم تُثبَت.
--
-- ما نفعله شيئان:
--   1. سلطة واحدة: حفظ الإعدادات صار يستلزم agent.manage — القدرة نفسها التي
--      تحكم البيانات الرئيسية. فمن يملك تعديل الوكلاء في مكان يملكه في الآخر،
--      ولا يستطيع أحدٌ تعديل أحدهما دون الآخر بحكم صلاحية أضعف.
--   2. كشف الانحراف: دالة تُقارن الاثنين وتُظهر الفرق، فيكون التباعد مرئياً
--      بدل أن يُكتشف من رقم خاطئ في تقرير.
--
-- شروط الإزالة الكاملة، صراحةً: يُحذف raw_import حين يتوقف calculateRawImport
-- عن قراءته — أي حين تنتقل كل الشهور إلى دورات vNext ولا يبقى شهر قديم يحتاج
-- إعادة قراءة من ملف خام.
--
-- forward-only.

begin;

-- ---------------------------------------------------------------------------
-- 1. سلطة واحدة على الحفظ.
--
-- الدالة الأصلية كانت تفحص الدور 'admin' مباشرة. صارت تفحص القدرة، فتشترك مع
-- إدارة البيانات الرئيسية في الحارس نفسه. والمدير يملكها أصلاً، فلا يتغيّر
-- سلوك أحد قائم.
-- ---------------------------------------------------------------------------

create or replace function public.save_import_settings(
  p_value jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_before jsonb;
  v_existing public.audit_logs%rowtype;
begin
  -- القدرة نفسها التي تحكم جداول البيانات الرئيسية.
  perform public.require_capability('agent.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_value is null or jsonb_typeof(p_value) <> 'object' then
    raise exception 'Import settings must be an object' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0));

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select value into v_before from public.app_settings where key = 'raw_import';

  insert into public.app_settings (key, value, updated_by)
  values ('raw_import', p_value, v_actor)
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value,
    entity_type, entity_id, before_data, after_data, request_id, extra
  ) values (
    v_actor, 'settings.import.saved', 'raw_import',
    left(coalesce(v_before::text, ''), 400), left(p_value::text, 400),
    'app_settings', null, v_before, p_value, p_request_id,
    'legacy import configuration; master data is authoritative for agents and aliases'
  );

  return jsonb_build_object('replayed', false, 'request_id', p_request_id,
                            'drift', public.master_data_drift());
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. كشف الانحراف بين المرجعين.
--
-- يُظهر ما في الإعدادات وليس في البيانات الرئيسية والعكس. الهدف أن يُرى
-- التباعد لحظة حدوثه، لا أن يُستنتج لاحقاً من نتيجة خاطئة.
-- ---------------------------------------------------------------------------

create or replace function public.master_data_drift()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with cfg as (select value from public.app_settings where key = 'raw_import'),
  cfg_agents as (
    select a ->> 'id' as code, a ->> 'name' as name
    from cfg, jsonb_array_elements(coalesce(cfg.value -> 'agents', '[]'::jsonb)) a
  ),
  cfg_aliases as (
    select pg_catalog.lower(pg_catalog.btrim(acc)) as alias_key
    from cfg, jsonb_array_elements(coalesce(cfg.value -> 'agents', '[]'::jsonb)) a,
         jsonb_array_elements_text(coalesce(a -> 'accounts', '[]'::jsonb)) acc
  )
  select jsonb_build_object(
    'settings_present', exists (select 1 from cfg),
    'agents_in_settings', (select count(*) from cfg_agents),
    'agents_in_master', (select count(*) from public.agents),
    'aliases_in_settings', (select count(*) from cfg_aliases),
    'aliases_in_master', (select count(*) from public.agent_aliases where agent_id is not null),
    'agents_only_in_settings', coalesce((
      select jsonb_agg(c.code order by c.code) from cfg_agents c
      where not exists (select 1 from public.agents m where m.code = c.code)), '[]'::jsonb),
    'agents_only_in_master', coalesce((
      select jsonb_agg(m.code order by m.code) from public.agents m
      where not exists (select 1 from cfg_agents c where c.code = m.code)), '[]'::jsonb),
    'aliases_only_in_settings', coalesce((
      select jsonb_agg(c.alias_key order by c.alias_key) from cfg_aliases c
      where not exists (select 1 from public.agent_aliases m where m.alias_key = c.alias_key)),
      '[]'::jsonb),
    'aliases_only_in_master', coalesce((
      select jsonb_agg(m.alias_key order by m.alias_key)
      from public.agent_aliases m
      where m.agent_id is not null
        and not exists (select 1 from cfg_aliases c where c.alias_key = m.alias_key)), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------------
-- 3. الوسم.
-- ---------------------------------------------------------------------------

comment on table public.app_settings is
  'LEGACY COMPATIBILITY. The raw_import key configures the legacy browser commission import only. Master data (agents, agent_aliases, fdts, packages) is authoritative for those concepts, and the vNext commission engine reads none of this table. Remove raw_import when calculateRawImport is retired.';

revoke execute on function public.save_import_settings(jsonb, uuid) from public, anon;
grant execute on function public.save_import_settings(jsonb, uuid) to authenticated;
revoke execute on function public.master_data_drift() from public, anon;
grant execute on function public.master_data_drift() to authenticated;

commit;
