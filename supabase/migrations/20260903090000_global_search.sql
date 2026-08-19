-- ---------------------------------------------------------------------------
-- البحث الشامل — من الاسم إلى ملفّه مباشرة
--
-- الشكوى التشغيلية التي يعالجها هذا: المشغّل يعرف اسم مشترك أو أب أو كابينة،
-- ولا يعرف في أيّ شاشة يجده. فيتنقّل بين ست شاشات مُصفّياً في كل واحدة.
--
-- البحث هنا يعبر الحدود: مشتركو التنصيب، ومستخدمو SaaS، والآباء، والوكلاء،
-- والكابينات — كلٌّ بنوعه ومسار ملفّه. والصلاحية تُفحص لكل نوع على حدة، فمن
-- لا يرى التنصيب لا تظهر له مشتركوه ولو طابق البحث.
--
-- البادئة أوّلاً ثم الاحتواء: الكتابة الكاملة لمعرّف يجب أن تأتي أوّلاً، لا
-- أن تضيع تحت عشرين مطابقةً جزئية.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.global_search(
  p_query text,
  p_limit integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_q   text := btrim(coalesce(p_query, ''));
  v_key text := lower(v_q);
  v_lim integer := least(greatest(coalesce(p_limit, 8), 1), 25);
  v_out jsonb := '[]'::jsonb;
begin
  -- بحثٌ بحرفٍ واحد يمسح الجداول كلها بلا فائدة.
  if length(v_q) < 2 then
    return jsonb_build_object('query', v_q, 'too_short', true, 'results', '[]'::jsonb);
  end if;

  if public.has_capability('installation.view') then
    v_out := v_out || coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select 'subscriber' as kind,
               s.subscriber_id as key,
               s.subscriber_id as title,
               coalesce(s.reseller, '') as subtitle,
               '/installation/subscribers/' || s.subscriber_id as path,
               case when lower(s.subscriber_id) = v_key then 0
                    when lower(s.subscriber_id) like v_key || '%' then 1
                    else 2 end as rank
        from public.installation_subscribers s
        where s.subscriber_id ilike '%' || v_q || '%'
           or s.reseller ilike '%' || v_q || '%'
        order by rank, s.subscriber_id
        limit v_lim) x), '[]'::jsonb);
  end if;

  if public.has_capability('agent.view') then
    -- الأب: اسمٌ واحد لكل قيمة مصدرٍ متمايزة، لا صفٌّ لكل حدث.
    v_out := v_out || coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select 'parent' as kind,
               p.raw_parent as key,
               p.raw_parent as title,
               public.parent_ownership_type(p.raw_parent) as subtitle,
               '/master/parents/' || p.raw_parent as path,
               case when lower(btrim(p.raw_parent)) = v_key then 0
                    when lower(btrim(p.raw_parent)) like v_key || '%' then 1
                    else 2 end as rank
        from (
          select distinct e.raw_parent
          from public.saas_activation_events e
          where e.raw_parent is not null
            and e.raw_parent ilike '%' || v_q || '%') p
        order by rank, p.raw_parent
        limit v_lim) x), '[]'::jsonb);

    v_out := v_out || coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select 'agent' as kind,
               a.id::text as key,
               a.official_name as title,
               coalesce(a.code, '') as subtitle,
               '/commissions/agents/' || a.id::text as path,
               case when lower(a.code) = v_key then 0
                    when lower(a.official_name) like v_key || '%' then 1
                    else 2 end as rank
        from public.agents a
        where a.official_name ilike '%' || v_q || '%'
           or a.code ilike '%' || v_q || '%'
        order by rank, a.official_name
        limit v_lim) x), '[]'::jsonb);
  end if;

  if public.has_capability('commission.view') then
    v_out := v_out || coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select 'fdt' as kind,
               f.code as key,
               f.code as title,
               coalesce(f.label, '') as subtitle,
               '/legacy' as path,
               case when lower(f.code) = v_key then 0
                    when lower(f.code) like v_key || '%' then 1
                    else 2 end as rank
        from public.fdts f
        where f.code ilike '%' || v_q || '%'
           or f.label ilike '%' || v_q || '%'
        order by rank, f.code
        limit v_lim) x), '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'query', v_q,
    'too_short', false,
    -- الترتيب النهائي عبر الأنواع: المطابقة التامة أوّلاً أيّاً كان نوعها.
    'results', coalesce((
      select jsonb_agg(r order by (r ->> 'rank')::int, r ->> 'kind', r ->> 'title')
      from jsonb_array_elements(v_out) r), '[]'::jsonb));
end;
$fn$;

revoke execute on function public.global_search(text,integer) from public, anon;
grant execute on function public.global_search(text,integer) to authenticated;

commit;
