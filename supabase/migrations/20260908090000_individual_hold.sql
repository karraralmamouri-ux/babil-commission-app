-- ---------------------------------------------------------------------------
-- تعليق مشترك واحد من ملفّه
--
-- الطريق الثاني للتعليق. القواعد نفسها التي تحكم الرفع بالجملة تحكمه: نوع
-- ودوام وسبب ومعرّف طلب، والمؤقّت بأجلٍ في المستقبل. الفرق الوحيد أن مصدره
-- INDIVIDUAL وأنه لا يحمل ملفاً.
--
-- وُضعت دالةً ثانية لا توسعةً للقائمة: place_installation_hold مستعملة في
-- مسارات أخرى، وتغيير توقيعها يمسّها كلها بلا داعٍ.
-- ---------------------------------------------------------------------------

begin;

-- المعرّف يُقرأ للتحقّق من التكرار، فيُفهرس.
alter table public.installation_holds
  add column if not exists request_id uuid;

create unique index if not exists installation_holds_request_uidx
  on public.installation_holds (request_id) where request_id is not null;

create or replace function public.place_hold_v2(
  p_subscriber_id text,
  p_permanence text,
  p_reason_code text,
  p_note text,
  p_stage_code text default null,
  p_expires_at timestamptz default null,
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
  v_known boolean;
begin
  perform public.require_capability('installation.hold');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_permanence not in ('PERMANENT', 'TEMPORARY') then
    raise exception 'Hold must be PERMANENT or TEMPORARY' using errcode = '22023';
  end if;
  if p_permanence = 'TEMPORARY' and p_expires_at is null then
    raise exception 'A temporary hold needs an end date' using errcode = '22023';
  end if;
  if p_permanence = 'TEMPORARY' and p_expires_at <= now() then
    raise exception 'A temporary hold cannot end in the past' using errcode = '22023';
  end if;
  if p_permanence = 'PERMANENT' and p_expires_at is not null then
    raise exception 'A permanent hold cannot carry an end date' using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'A hold must state its reason' using errcode = '22023';
  end if;

  -- تكرار الطلب نفسه لا يُنتج تعليقاً ثانياً.
  select id into v_id from public.installation_holds where request_id = p_request_id;
  if found then
    return jsonb_build_object('hold_id', v_id, 'idempotent', true);
  end if;

  select exists (
    select 1 from public.installation_subscribers s
    where lower(btrim(s.subscriber_id)) = lower(btrim(p_subscriber_id))) into v_known;
  if not v_known then
    raise exception 'Subscriber % is not in the installation registry', p_subscriber_id
      using errcode = '22023';
  end if;

  -- تعليقٌ سارٍ قائم يُعاد لا يُضاعَف.
  select h.id into v_id
  from public.installation_holds h
  where lower(btrim(h.subscriber_id)) = lower(btrim(p_subscriber_id))
    and public.hold_is_effective(h.status, h.permanence, h.expires_at)
    and (h.stage_code is not distinct from p_stage_code)
  limit 1;
  if found then
    return jsonb_build_object('hold_id', v_id, 'idempotent', true,
                              'note', 'already held');
  end if;

  insert into public.installation_holds (
    subscriber_id, stage_code, reason_code, hold_type, note, status, created_by,
    permanence, expires_at, source, reason_note, request_id)
  select s.subscriber_id, p_stage_code, p_reason_code, 'MANUAL', btrim(p_note),
         'ACTIVE', v_actor, p_permanence, p_expires_at, 'INDIVIDUAL',
         btrim(p_note), p_request_id
  from public.installation_subscribers s
  where lower(btrim(s.subscriber_id)) = lower(btrim(p_subscriber_id))
  limit 1
  returning id into v_id;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, request_id, extra)
  values (v_actor, 'installation.hold.placed', 'status', 'NONE', 'ACTIVE',
    'installation_hold', p_request_id,
    'subscriber=' || p_subscriber_id || ' permanence=' || p_permanence
      || coalesce(' stage=' || p_stage_code, '')
      || coalesce(' until=' || p_expires_at::text, '')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object('hold_id', v_id, 'idempotent', false,
                            'permanence', p_permanence);
end;
$fn$;

revoke execute on function public.place_hold_v2(text,text,text,text,text,timestamptz,uuid)
  from public, anon;
grant execute on function public.place_hold_v2(text,text,text,text,text,timestamptz,uuid)
  to authenticated;

commit;
