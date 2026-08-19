-- ---------------------------------------------------------------------------
-- سجلّ التصحيحات — الخام مقابل المعتمد
--
-- مسارات التصحيح موجودة كلّها وتعمل:
--
--   الأب          classify_parent        → agent_aliases
--   العائدية      transfer_subscriber    → subscriber_ownership (مؤرَّخة)
--   الكابينة      register_fdt           → fdts
--   المال         correct_financial_entry / reverse_financial_entry → الدفتر
--
-- الناقص لم يكن مسار كتابة بل مسار قراءة: لا شاشة تقول «هذه قيمة المصدر،
-- وهذه القيمة المعتمدة، وهذا من غيّرها ولماذا». وبناء مسار كتابةٍ ثانٍ كان
-- سيُنشئ سلطتين على الحقيقة نفسها — وهو ما يُمنع صراحةً.
--
-- فهذه قراءةٌ محضة تجمع الأربعة في مكانٍ واحد. الخام يبقى كما ورد في
-- saas_activation_events ولا يُمسّ أبداً.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 1. تصحيحات مشترك بعينه
-- ---------------------------------------------------------------------------

create or replace function public.subscriber_corrections(p_subscriber_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key      text := lower(btrim(coalesce(p_subscriber_id, '')));
  v_raw_par  text;
  v_raw_fdt  text;
  v_doc      jsonb;
begin
  perform public.require_capability('installation.view');

  -- الخام: آخر ما ورد من المصدر، بلا أيّ معالجة.
  select e.raw_parent, e.fdt_code into v_raw_par, v_raw_fdt
  from public.saas_activation_events e
  where e.username_key = v_key
  order by e.event_created_at desc
  limit 1;

  select jsonb_build_object(
    'subscriber_id', p_subscriber_id,

    -- الأب: الخام هو نصّ المصدر، والمعتمد هو تصنيفه — لا اسمٌ بديل.
    'parent', jsonb_build_object(
      'dimension', 'PARENT',
      'raw', v_raw_par,
      'effective', case when v_raw_par is null then null
                   else public.parent_ownership_type(v_raw_par) end,
      'note', 'الاسم لا يتغيّر بالتصنيف — المعتمد حكمٌ بجانبه',
      'decided_at', (select al.updated_at from public.agent_aliases al
                     where al.alias_key = lower(btrim(coalesce(v_raw_par, ''))) limit 1),
      'agent', (select ag.official_name from public.agent_aliases al
                join public.agents ag on ag.id = al.agent_id
                where al.alias_key = lower(btrim(coalesce(v_raw_par, ''))) limit 1)),

    -- العائدية: مؤرَّخة، فتُعرض الفترة السارية ومَن قرّرها ولماذا.
    'ownership', (
      select jsonb_build_object(
        'dimension', 'OWNERSHIP',
        'raw', case when v_raw_par is null then null
               else public.parent_ownership_type(v_raw_par) end,
        'effective', o.ownership_type,
        'agent', ag.official_name,
        'effective_from', o.effective_from,
        'reason', o.reason,
        'actor', u.email,
        'decided_at', o.created_at,
        'request_id', o.request_id)
      from public.subscriber_ownership o
      left join public.agents ag on ag.id = o.agent_id
      left join public.profiles u on u.id = o.performed_by
      where o.username_key = v_key and o.effective_to is null
      order by o.effective_from desc limit 1),

    -- الكابينة: الخام رمزٌ ورد، والمعتمد صفُّها في السجلّ بمنطقته المُعلَنة.
    'fdt', jsonb_build_object(
      'dimension', 'FDT',
      'raw', v_raw_fdt,
      'effective', (select f.zone from public.fdts f where f.code = v_raw_fdt),
      'registered', exists (select 1 from public.fdts f where f.code = v_raw_fdt),
      'label', (select f.label from public.fdts f where f.code = v_raw_fdt),
      'note', 'المنطقة مُعلَنة لا مُشتقّة من الرقم'),

    -- التصحيحات المالية: عبر الدفتر وحده.
    'financial', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select l.id, l.txn_type, l.amount, l.direction, l.reason,
               l.created_at, u.email as actor, l.corrects_entry_id, l.reverses_entry_id
        from public.financial_ledger l
        left join public.profiles u on u.id = l.created_by
        where l.subscriber_id = p_subscriber_id
          and l.txn_type in ('CORRECTION', 'REVERSAL', 'ADJUSTMENT')
        order by l.created_at desc limit 20) x), '[]'::jsonb),

    -- الأثر المُدقَّق لكل قرارٍ مسّ هذا المشترك.
    'audit', coalesce((
      select jsonb_agg(to_jsonb(y)) from (
        select a.created_at, a.action, a.field, a.old_value, a.new_value,
               a.extra, u.email as actor
        from public.audit_logs a
        left join public.profiles u on u.id = a.actor_id
        where a.extra like '%' || p_subscriber_id || '%'
           or (a.entity_type = 'subscriber' and a.extra like '%' || v_key || '%')
        order by a.created_at desc limit 20) y), '[]'::jsonb))
  into v_doc;

  return v_doc;
end;
$fn$;

revoke execute on function public.subscriber_corrections(text) from public, anon;
grant execute on function public.subscriber_corrections(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. سجلّ كل التصحيحات
--
-- من الأثر المُدقَّق: كل قرارٍ غيّر قيمةً معتمدة، بأيّ بُعد، ومن اتّخذه.
-- ---------------------------------------------------------------------------

create or replace function public.page_corrections(
  p_dimension text default null,
  p_search text default null,
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
  perform public.require_capability('audit.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with kept as (
    select
      a.id, a.created_at, a.action, a.field,
      a.old_value, a.new_value, a.extra, a.request_id,
      u.email as actor,
      case
        when a.action = 'master.parent.classified'          then 'PARENT'
        when a.action = 'subscriber.ownership.transferred'  then 'OWNERSHIP'
        when a.action like 'fdt.%'                          then 'FDT'
        when a.action = 'installation.invoice.reviewed'     then 'INVOICE'
        when a.action like '%hold%'                         then 'HOLD'
        when a.action like '%correct%' or a.action like '%revers%' then 'FINANCIAL'
        else 'OTHER' end as dimension
    from public.audit_logs a
    left join public.profiles u on u.id = a.actor_id
    -- أفعالٌ تُغيّر قيمةً معتمدة، لا كل ما في السجلّ.
    where a.action in ('master.parent.classified', 'subscriber.ownership.transferred',
                       'installation.invoice.reviewed')
       or a.action like 'fdt.%'
       or a.action like '%hold%'
       or a.action like '%correct%'
       or a.action like '%revers%'
  ),
  filtered as (
    select * from kept k
    where (p_dimension is null or k.dimension = p_dimension)
      and (p_search is null or btrim(p_search) = ''
           or k.extra ilike '%' || p_search || '%'
           or k.actor ilike '%' || p_search || '%'
           or k.new_value ilike '%' || p_search || '%')
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select f.* from filtered f order by f.created_at desc
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from filtered;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_corrections(text,text,integer,integer) from public, anon;
grant execute on function public.page_corrections(text,text,integer,integer) to authenticated;

commit;
