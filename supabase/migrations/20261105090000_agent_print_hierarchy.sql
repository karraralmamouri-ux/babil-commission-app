-- هوية الـPrint/الفرع: الوكيل الأب وفروعه، واسمُ المصدر غير المعروف يُحسم مرّة.
--
-- ما يسدّه هذا الملف. الوكلاء اليوم قائمةٌ مسطّحة: public.agents بلا أيّ
-- علاقةٍ بينها. والعمل الفعلي هرميّ — وكيلٌ رئيسيّ تحته Prints/فروع، وكلٌّ
-- منها يُنشئ تفعيلاتٍ باسم مصدرٍ (parent) خاصٍّ به. فحين يُطلَب «نتيجة
-- الفرع» و«مجموع الرئيسي» لا يوجد ما يُجمَع عليه، ويصير التجميع في الواجهة
-- بمطابقة الأسماء — وهو بالضبط ما يمنعه docs/PROJECT_CONTEXT.md.
--
-- والمعالجة أصغر ما يكفي: عمودٌ واحد يشير إلى الأب داخل الجدول نفسه، بلا
-- جدول علاقةٍ جديد وبلا لمس صفٍّ قائم. كل وكيلٍ اليوم يبقى صحيحاً كما هو:
-- parent_agent_id فارغ يعني «رئيسيّ/مستقلّ»، وهو الوضع الافتراضي للجميع.
--
-- والعمق مقيَّدٌ بمستويين عمداً (رئيسيّ ← فرع). هذا ليس تبسيطاً كسولاً:
-- الهرم المفتوح يستلزم منع الدورات بمسحٍ تكراريّ في كل كتابة، ويجعل «مجموع
-- الرئيسي» استعلاماً تكرارياً في كل تقرير. والعمل المطلوب مستويان. فحارسٌ
-- صريح يرفض الثالث، ورسالتُه تقول ما يجب فعله بدل أن يفشل صامتاً.
--
-- والاسم غير المعروف: لا مطابقةً تقريبية ولا إسناداً صامتاً. القرار يُتَّخذ
-- مرّةً واحدة عبر classify_parent القائمة — هي المحرّك، وهذا الملف لا
-- يستنسخها بل يغلّفها ليضيف الاحتمال الوحيد الناقص: «فرعٌ جديد تحت رئيسيّ
-- قائم». والمخرج محفوظ في agent_aliases فلا يُسأل عنه الشهر القادم.
--
-- ولا يُمَسّ مالٌ هنا: لا استحقاق ولا دفعة ولا قيد، ولا صفٌّ تاريخيّ يُعاد
-- كتابته. إضافي بالكامل، forward-only.

begin;

-- ---------------------------------------------------------------------------
-- ١ · الأب داخل جدول الوكلاء.
-- ---------------------------------------------------------------------------

alter table public.agents
  add column if not exists parent_agent_id uuid references public.agents(id) on delete restrict;

create index if not exists agents_parent_idx on public.agents (parent_agent_id);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'agents_parent_not_self') then
    alter table public.agents
      add constraint agents_parent_not_self
      check (parent_agent_id is null or parent_agent_id <> id);
  end if;
end;
$$;

comment on column public.agents.parent_agent_id is
  'الوكيل الرئيسي لهذا الفرع/Print. فارغ = رئيسيّ أو مستقلّ. مستويان فقط.';

-- الحارس البنيوي: مستويان لا ثالث، فلا دورة ممكنة أصلاً.
create or replace function public.guard_agent_hierarchy_depth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.parent_agent_id is null then
    return new;
  end if;

  if new.parent_agent_id = new.id then
    raise exception 'An agent cannot be its own parent' using errcode = '23514';
  end if;

  if exists (select 1 from public.agents a
             where a.id = new.parent_agent_id and a.parent_agent_id is not null) then
    raise exception
      'Agent hierarchy is two levels: % is already a branch and cannot be a parent',
      new.parent_agent_id using errcode = '23514';
  end if;

  if exists (select 1 from public.agents a where a.parent_agent_id = new.id) then
    raise exception
      'Agent % has branches of its own and cannot become a branch', new.id
      using errcode = '23514';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_agents_hierarchy_depth on public.agents;
create trigger trg_agents_hierarchy_depth
  before insert or update of parent_agent_id on public.agents
  for each row execute function public.guard_agent_hierarchy_depth();

-- ---------------------------------------------------------------------------
-- ٢ · جذر الوكيل — الوحدة التي يُجمَع عليها تقرير الرئيسي.
--
-- الفرع يعود إلى أبيه، والرئيسي يعود إلى نفسه. فالتقرير يجمع على قيمةٍ
-- واحدةٍ دائماً بلا حالتين في الاستعلام.
-- ---------------------------------------------------------------------------

create or replace function public.agent_root_id(p_agent_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
    (select a.parent_agent_id from public.agents a where a.id = p_agent_id),
    p_agent_id);
$fn$;

comment on function public.agent_root_id(uuid) is
  'جذر الوكيل: الأب إن كان فرعاً، وإلا هو نفسه. وحدة تجميع تقرير الرئيسي.';

revoke execute on function public.agent_root_id(uuid) from public, anon;
grant execute on function public.agent_root_id(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- ٣ · ربط الفرع بأبيه — كتابةٌ مدقَّقة، لا UPDATE مباشر.
-- ---------------------------------------------------------------------------

create or replace function public.set_agent_parent(
  p_agent_id uuid,
  p_parent_agent_id uuid,
  p_reason text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_before uuid;
  v_code text;
begin
  perform public.require_capability('agent.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  select parent_agent_id, code into v_before, v_code
  from public.agents where id = p_agent_id;
  if v_code is null then
    raise exception 'Agent % was not found', p_agent_id using errcode = 'P0002';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'master.agent.parent_set') then
    return jsonb_build_object('agent_id', p_agent_id, 'idempotent', true);
  end if;

  if p_parent_agent_id is not null
     and not exists (select 1 from public.agents where id = p_parent_agent_id) then
    raise exception 'Parent agent % was not found', p_parent_agent_id using errcode = 'P0002';
  end if;

  update public.agents
  set parent_agent_id = p_parent_agent_id, updated_by = v_actor, updated_at = now()
  where id = p_agent_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'master.agent.parent_set', 'parent_agent_id',
    coalesce(v_before::text, 'NONE'), coalesce(p_parent_agent_id::text, 'NONE'),
    'agent', p_agent_id, p_request_id,
    'code=' || v_code || coalesce(' reason=' || nullif(btrim(coalesce(p_reason, '')), ''), ''));

  return jsonb_build_object(
    'agent_id', p_agent_id, 'code', v_code,
    'parent_before', v_before, 'parent_after', p_parent_agent_id, 'idempotent', false);
end;
$fn$;

revoke execute on function public.set_agent_parent(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.set_agent_parent(uuid, uuid, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- ٤ · حسم اسم مصدرٍ غير معروف — أربعة احتمالات، ومحرّكٌ واحد.
--
-- classify_parent هي التي تكتب الحكم وتُعلم الدورات المتأثّرة. هذه الدالة لا
-- تعيد تنفيذ شيءٍ منها: تُنشئ الوكيل حين يكون الاحتمال «جديد»، ثم تُسلّمها
-- الحكم. فلا قاعدتَي تصنيف، ولا مسارَي تدقيق.
--
-- والمطابقة التقريبية ممنوعة صراحةً: لا شيء هنا يخمّن أن اسماً يشبه اسماً.
-- المدخل قرارُ إنسانٍ مخوَّل، ومخرجُه صفٌّ في agent_aliases يُغني عن السؤال
-- في الشهر القادم.
-- ---------------------------------------------------------------------------

create or replace function public.resolve_print_name(
  p_source_name text,
  p_resolution text,
  p_agent_id uuid default null,
  p_new_agent_code text default null,
  p_new_agent_name text default null,
  p_parent_agent_id uuid default null,
  p_reason text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_name text := btrim(coalesce(p_source_name, ''));
  v_agent uuid := p_agent_id;
  v_ownership text;
  v_created boolean := false;
  v_classify jsonb;
begin
  perform public.require_capability('agent.manage');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'A source name is required' using errcode = '22023';
  end if;
  if p_resolution not in ('ALIAS_OF_EXISTING', 'NEW_BRANCH', 'NEW_PARENT', 'DIRECT_COMPANY') then
    raise exception
      'Resolution must be ALIAS_OF_EXISTING, NEW_BRANCH, NEW_PARENT or DIRECT_COMPANY'
      using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'master.print.resolved') then
    return jsonb_build_object('source_name', v_name, 'idempotent', true);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('print:' || pg_catalog.lower(v_name), 0));

  if p_resolution = 'ALIAS_OF_EXISTING' then
    if v_agent is null then
      raise exception 'ALIAS_OF_EXISTING needs an existing agent' using errcode = '22023';
    end if;
    v_ownership := 'RESELLER';

  elsif p_resolution = 'DIRECT_COMPANY' then
    if v_agent is not null then
      raise exception 'DIRECT_COMPANY carries no agent' using errcode = '22023';
    end if;
    v_ownership := 'DIRECT_COMPANY';

  else
    -- فرعٌ جديد أو رئيسيٌّ جديد: يُنشأ هنا ثم يُسلَّم للتصنيف.
    if btrim(coalesce(p_new_agent_code, '')) = ''
       or btrim(coalesce(p_new_agent_name, '')) = '' then
      raise exception 'A new agent needs a code and an official name' using errcode = '22023';
    end if;
    if p_resolution = 'NEW_BRANCH' and p_parent_agent_id is null then
      raise exception 'NEW_BRANCH needs the parent agent' using errcode = '22023';
    end if;
    if p_resolution = 'NEW_PARENT' and p_parent_agent_id is not null then
      raise exception 'NEW_PARENT carries no parent of its own' using errcode = '22023';
    end if;

    select id into v_agent from public.agents where code = btrim(p_new_agent_code);
    if v_agent is null then
      insert into public.agents (code, official_name, parent_agent_id, created_by)
      values (btrim(p_new_agent_code), btrim(p_new_agent_name), p_parent_agent_id, v_actor)
      returning id into v_agent;
      v_created := true;
    elsif p_resolution = 'NEW_BRANCH' then
      -- رمزٌ قائم: يُربط بأبيه ولا يُنشأ ثانياً، ولا يُعاد تسميته صامتاً.
      update public.agents
      set parent_agent_id = p_parent_agent_id, updated_by = v_actor, updated_at = now()
      where id = v_agent and parent_agent_id is distinct from p_parent_agent_id;
    end if;
    v_ownership := 'RESELLER';
  end if;

  v_classify := public.classify_parent(
    v_name, v_ownership, v_agent, p_reason,
    public.uuid_from_parts(p_request_id, pg_catalog.md5('classify')::uuid));

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'master.print.resolved', 'resolution', null, p_resolution,
    'agent_alias', v_agent, p_request_id,
    'source=' || v_name || coalesce(' agent=' || v_agent::text, '')
      || case when v_created then ' created=true' else '' end);

  return jsonb_build_object(
    'source_name', v_name,
    'resolution', p_resolution,
    'agent_id', v_agent,
    'parent_agent_id', public.agent_root_id(v_agent),
    'agent_created', v_created,
    'classification', v_classify,
    'idempotent', false);
end;
$fn$;

comment on function public.resolve_print_name(text, text, uuid, text, text, uuid, text, uuid) is
  'يحسم اسم مصدرٍ غير معروف مرّة واحدة: اسم بديل لPrint قائم، أو فرع جديد تحت رئيسي، أو رئيسي مستقل، أو الشركة المباشرة. لا مطابقة تقريبية.';

revoke execute on function public.resolve_print_name(text, text, uuid, text, text, uuid, text, uuid)
  from public, anon;
grant execute on function public.resolve_print_name(text, text, uuid, text, text, uuid, text, uuid)
  to authenticated;


-- دوالّ الزنادات لا تُستدعى نداءً، فلا صلاحيةَ تنفيذٍ لها لأحد.
revoke execute on function public.guard_agent_hierarchy_depth() from public;
revoke execute on function public.guard_agent_hierarchy_depth() from anon;
revoke execute on function public.guard_agent_hierarchy_depth() from authenticated;

commit;
