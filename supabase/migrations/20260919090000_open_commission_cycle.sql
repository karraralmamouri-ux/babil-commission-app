-- ---------------------------------------------------------------------------
-- فتح دورة عمولة
--
-- كل انتقالات الدورة موجودة على الخادم: الحساب والاعتماد والإغلاق وإعادة
-- الفتح. الناقص وحده أوّلها — إنشاء الدورة. وكان يُفعل من الشاشات السابقة.
--
-- ولا حالة جديدة تُخترع هنا: الدورة تُفتح DRAFT كما هي أصلاً أوّل الحالات
-- في القيد، وما بعدها يبقى لدوالّه.
--
-- والقيد الجديد هو الأهمّ: دورتان تتقاطع فترتاهما تحسبان الحدث نفسه مرّتين.
-- الفحص في الدالّة يعطي رسالةً مفهومة، والقيد يمنع فعلاً — بينهما سباقٌ لا
-- يسدّه الفحص وحده.
-- ---------------------------------------------------------------------------

begin;

alter table public.commission_cycles
  drop constraint if exists commission_cycles_no_overlap;

alter table public.commission_cycles
  add constraint commission_cycles_no_overlap
  exclude using gist (daterange(period_start, period_end, '[]') with &&);

comment on constraint commission_cycles_no_overlap on public.commission_cycles is
  'فترتان متقاطعتان تحسبان الحدث نفسه في دورتين.';

create or replace function public.open_commission_cycle(
  p_name text,
  p_period_start date,
  p_period_end date,
  p_notes text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
  v_clash text;
begin
  perform public.require_capability('commission.manage_cycle');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'A cycle name is required' using errcode = '22023';
  end if;
  if p_period_start is null or p_period_end is null then
    raise exception 'A cycle needs both of its period dates' using errcode = '22023';
  end if;
  if p_period_end < p_period_start then
    raise exception 'The cycle ends before it starts' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select c.name into v_clash
  from public.commission_cycles c
  where daterange(c.period_start, c.period_end, '[]')
        && daterange(p_period_start, p_period_end, '[]')
  limit 1;

  if v_clash is not null then
    raise exception 'The period overlaps cycle %, and one event would be counted twice',
      v_clash using errcode = '23P01';
  end if;

  insert into public.commission_cycles
    (name, period_start, period_end, status, engine_version, notes, created_by)
  values (btrim(p_name), p_period_start, p_period_end, 'DRAFT', 'VNEXT',
          nullif(btrim(coalesce(p_notes, '')), ''), v_actor)
  returning id into v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.cycle.opened', 'status', 'NONE', 'DRAFT',
    'commission_cycle', v_id, p_request_id,
    btrim(p_name) || ' ' || p_period_start::text || '..' || p_period_end::text);

  return jsonb_build_object('replayed', false, 'cycle_id', v_id, 'status', 'DRAFT');
end;
$fn$;

revoke execute on function public.open_commission_cycle(text,date,date,text,uuid)
  from public, anon;
grant execute on function public.open_commission_cycle(text,date,date,text,uuid)
  to authenticated;

commit;
