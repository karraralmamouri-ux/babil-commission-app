-- ---------------------------------------------------------------------------
-- الدورة العاملة، ومصير المسوّدة المفتوحة سهواً
--
-- `current_commission_cycle_id()` كانت تختار «أحدث period_start» بلا شرط:
--
--     select id from public.commission_cycles order by period_start desc limit 1;
--
-- ففي 2026-08-22 فُتحت مسوّدة آب. لا تفعيلات فيها ولا استثناءات ولا نتيجة.
-- ومنذ تلك اللحظة صارت هي «الدورة الحالية» لكل عقد يقرأ الافتراضي: تموز
-- قيد المراجعة اختفت خلفها، وعادت الشاشات أصفاراً صحيحةً شكلاً كاذبةً معنى.
-- قِيس الأثر: `current_unknown_fdt_decisions` بالافتراضي تُعيد صفراً،
-- وبتمرير تموز صراحةً تُعيد 95 قراراً و4,215 حدثاً.
--
-- والصفر الكاذب أخطر من العطل: العطل يُرى، والصفر يُصدَّق.
--
-- القاعدة الجديدة: الدورة تصير عاملةً حين تدخل دورة حياتها فعلاً — إمّا
-- بتجاوز المسوّدة، أو ببقائها مسوّدةً وقد حُسبت (`calculated_at`). ومسوّدةٌ
-- فارغة لم يُشغَّل حسابها ليست نتيجةً مالية، فلا ترث مكان تموز.
--
-- والملغاة لا تُحذف. الحذف يمحو أن أحداً فتحها، ومتى، ولماذا أُلغيت.
-- فتُعلَّم `CANCELLED` ويبقى صفّها وسجلّ فتحها وسجلّ إلغائها.
--
-- forward-only. لا مساس بحساب العمولة ولا بالشرائح ولا بالملكية ولا بقواعد
-- الكابينات ولا بمنطق الدفع.
-- ---------------------------------------------------------------------------

begin;

-- ------------------------------------------------------------------
-- ١ · حالة الإلغاء
-- ------------------------------------------------------------------
--
-- `CANCELLED` حالةٌ نهائية بلا أثر مالي: لا تُعتمد ولا تُقفل ولا تُدفع.
-- ولذلك تُضاف إلى قائمة الحالات التي لا تشترط نسبة الاعتماد.

alter table public.commission_cycles
  drop constraint if exists commission_cycles_status_check;
alter table public.commission_cycles
  add constraint commission_cycles_status_check
  check (status = any (array['DRAFT','DATA_IMPORTED','UNDER_REVIEW','READY_TO_FINALIZE',
                             'FINALIZED','PARTIALLY_PAID','PAID','CLOSED','CANCELLED']));

alter table public.commission_cycles
  drop constraint if exists commission_cycles_finalized_is_attributed;
alter table public.commission_cycles
  add constraint commission_cycles_finalized_is_attributed
  check (status = any (array['DRAFT','DATA_IMPORTED','UNDER_REVIEW','READY_TO_FINALIZE','CANCELLED'])
         or (finalized_by is not null and finalized_at is not null));

-- ------------------------------------------------------------------
-- ٢ · الدورة العاملة
-- ------------------------------------------------------------------

create or replace function public.commission_cycle_is_operative(
  p_status text, p_calculated_at timestamptz)
returns boolean
language sql
immutable
as $fn$
  select p_status is distinct from 'CANCELLED'
     and (p_status is distinct from 'DRAFT' or p_calculated_at is not null);
$fn$;

comment on function public.commission_cycle_is_operative(text, timestamptz) is
  'الدورة عاملة حين تتجاوز المسوّدة أو يُشغَّل حسابها. الملغاة ليست عاملة أبداً.';

create or replace function public.current_commission_cycle_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $fn$
  select c.id
  from public.commission_cycles c
  where public.commission_cycle_is_operative(c.status, c.calculated_at)
  order by c.period_start desc, c.created_at desc
  limit 1;
$fn$;

revoke execute on function public.current_commission_cycle_id() from public, anon;
grant execute on function public.current_commission_cycle_id() to authenticated;

-- ------------------------------------------------------------------
-- ٣ · إلغاء مسوّدة فارغة
-- ------------------------------------------------------------------
--
-- لا يُلغى إلا ما لا أثر له: مسوّدة بلا حساب وبلا استحقاقات وبلا استثناءات
-- وبلا لقطات وبلا دفعات وبلا تصحيحات. وأي صفٍّ تابع يوقف العملية بذكر
-- عدده، فلا يضيع شيء صامتاً.

create or replace function public.cancel_empty_commission_cycle(
  p_cycle_id uuid, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := auth.uid();
  v_cycle public.commission_cycles%rowtype;
  v_entitlements bigint; v_exceptions bigint; v_snapshots bigint;
  v_batches bigint; v_corrections bigint;
begin
  perform public.require_capability('commission.manage_cycle');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Cancelling a cycle needs a reason' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  select * into v_cycle from public.commission_cycles where id = p_cycle_id for update;
  if not found then
    raise exception 'Commission cycle was not found' using errcode = 'P0002';
  end if;
  if v_cycle.status = 'CANCELLED' then
    return jsonb_build_object('replayed', true, 'cycle_id', p_cycle_id, 'status', 'CANCELLED');
  end if;
  if v_cycle.status <> 'DRAFT' then
    raise exception 'Only a DRAFT cycle can be cancelled; this one is %', v_cycle.status
      using errcode = '42501';
  end if;
  if v_cycle.calculated_at is not null then
    raise exception 'This draft has a calculated result and is not empty'
      using errcode = '42501';
  end if;

  select count(*) into v_entitlements from public.commission_event_entitlements
    where cycle_id = p_cycle_id;
  select count(*) into v_exceptions from public.commission_exceptions
    where cycle_id = p_cycle_id;
  select count(*) into v_snapshots from public.commission_cycle_snapshots
    where cycle_id = p_cycle_id;
  select count(*) into v_batches from public.commission_payment_batches
    where cycle_id = p_cycle_id;
  select count(*) into v_corrections from public.activation_corrections
    where cycle_id = p_cycle_id;

  if v_entitlements + v_exceptions + v_snapshots + v_batches + v_corrections > 0 then
    raise exception
      'The cycle carries business rows and cannot be cancelled (entitlements %, exceptions %, snapshots %, batches %, corrections %)',
      v_entitlements, v_exceptions, v_snapshots, v_batches, v_corrections
      using errcode = '42501';
  end if;

  update public.commission_cycles
  set status = 'CANCELLED',
      notes = btrim(coalesce(notes, '') || ' [أُلغيت: ' || btrim(p_reason) || ']')
  where id = p_cycle_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'commission.cycle.cancelled', 'status', v_cycle.status, 'CANCELLED',
    'commission_cycle', p_cycle_id, p_request_id, btrim(p_reason));

  return jsonb_build_object('replayed', false, 'cycle_id', p_cycle_id, 'status', 'CANCELLED');
end;
$fn$;

revoke execute on function public.cancel_empty_commission_cycle(uuid, text, uuid)
  from public, anon;
grant execute on function public.cancel_empty_commission_cycle(uuid, text, uuid)
  to authenticated;

-- ------------------------------------------------------------------
-- ٤ · الملغاة لا تحجز فترتها
-- ------------------------------------------------------------------
--
-- فحص التداخل كان يمنع فتح أيّ دورة تتقاطع مع دورةٍ قائمة. ولو بقيت
-- الملغاة في الفحص لتعذّر فتح آب من جديد إلى الأبد.
--
-- والفحص في الدالّة وحده لا يكفي: الحارس الفعليّ قيدُ الاستبعاد
-- `commission_cycles_no_overlap`، وهو لا يعرف الحالات. فلو رُخِّص في الدالّة
-- وحدها لرُفض الإدراج عند القيد برسالةٍ لا تقول شيئاً عن السبب.
--
-- وحجّة القيد نفسها هي التي تُخرج الملغاة منه: علّته أنّ «فترتين متقاطعتين
-- تحسبان الحدث نفسه مرّتين»، والملغاة لا تحسب شيئاً.

alter table public.commission_cycles
  drop constraint if exists commission_cycles_no_overlap;
alter table public.commission_cycles
  add constraint commission_cycles_no_overlap
  exclude using gist (daterange(period_start, period_end, '[]') with &&)
  where (status <> 'CANCELLED');

comment on constraint commission_cycles_no_overlap on public.commission_cycles is
  'فترتان متقاطعتان تحسبان الحدث نفسه في دورتين. والملغاة لا تحسب، فلا تحجز فترتها.';

create or replace function public.open_commission_cycle(
  p_name text, p_period_start date, p_period_end date,
  p_notes text default null, p_request_id uuid default null)
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
  where c.status <> 'CANCELLED'
    and daterange(c.period_start, c.period_end, '[]')
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

revoke execute on function public.open_commission_cycle(text, date, date, text, uuid)
  from public, anon;
grant execute on function public.open_commission_cycle(text, date, date, text, uuid)
  to authenticated;

commit;
