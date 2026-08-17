-- أساس التصحيح المالي: دفتر أستاذ موحّد + عكس + تصحيح + تسوية.
--
-- المشكلة التي يحلها. الحمايات الحالية تمنع تعديل دفعة مسوّاة — وهذا صحيح —
-- لكنها تترك النظام بلا أي مسار قانوني للتصحيح. دفعة ذهبت للوكيل الخطأ لا
-- علاج لها اليوم إلا تعديل مباشر على القاعدة، أي خارج التدقيق تماماً. هذه
-- المهاجرة تبني المسار المفقود.
--
-- المبدأ الحاكم: المعاملة الأصلية تبقى كما هي إلى الأبد. التصحيح يضيف حركات
-- جديدة ولا يمحو ولا يعدّل شيئاً.
--
-- ما لا تفعله هذه المهاجرة عمداً:
--   • لا تُرحّل أي جدول قائم. commission_rows وinstallation_payments
--     وinstallation_payment_history تبقى كما هي وتعمل كما تعمل اليوم.
--   • لا تُنشئ قيوداً اصطناعية للبيانات التاريخية. الدفتر يبدأ فارغاً؛
--     والقيد الأصلي يُستنسخ من السجل الحي لحظة أول تصحيح عليه فقط.
--   • لا تلمس record_commission_payment ولا record_installation_payment.
--     مسار الدفع العادي يبقى بحرفه.
--   • لا تُعيد المشترك إلى «مؤهَّل» بعد العكس. الأهلية سؤال مشتق، وإعادة
--     الضبط الأعمى هي بالضبط ما يُنتج دفعة مكررة.
--
-- forward-only. إضافية بالكامل.

begin;

-- ---------------------------------------------------------------------------
-- 1. الدفتر.
--
-- جدول واحد يخدم النطاقين. الأعمدة مالية حقيقية لا حقل JSON عام: السؤال
-- «كم صافي ما يستحقه هذا الوكيل» يجب أن يُجاب باستعلام لا بتفسير نص.
-- ---------------------------------------------------------------------------

create table if not exists public.financial_ledger (
  id uuid primary key default gen_random_uuid(),

  domain text not null,
  txn_type text not null,
  source_origin text not null,

  -- السجل الحي الذي نشأت عنه الحركة. مرجع فضفاض عمداً: النطاقان يشيران إلى
  -- جدولين مختلفين، ومفتاح أجنبي واحد لا يمكنه تغطية الاثنين.
  source_table text,
  source_id uuid,

  -- سياق مالي محفوظ لحظة الحركة، لا يُقرأ لاحقاً من جدول قد يتغيّر.
  agent_name text,
  subscriber_id text,
  stage text,
  month_key text,
  original_cycle_key text,

  amount bigint not null,
  direction smallint not null,
  currency text not null default 'IQD',

  status text not null default 'posted',
  reason text,

  reverses_entry_id uuid references public.financial_ledger(id) on delete restrict,
  corrects_entry_id uuid references public.financial_ledger(id) on delete restrict,

  request_id uuid not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  posted_by uuid references auth.users(id),
  posted_at timestamptz not null default now(),

  constraint financial_ledger_domain_check
    check (domain in ('commission', 'installation')),
  constraint financial_ledger_type_check
    check (txn_type in ('HISTORICAL_PAYMENT', 'PAYMENT', 'ADJUSTMENT', 'CORRECTION', 'REVERSAL')),
  constraint financial_ledger_origin_check
    check (source_origin in ('PAYMENT_PATH', 'HISTORICAL_MIGRATION', 'LEGACY_BACKFILL', 'CORRECTION_PATH')),
  constraint financial_ledger_status_check
    check (status in ('posted', 'superseded')),
  constraint financial_ledger_amount_check check (amount > 0),
  constraint financial_ledger_direction_check check (direction in (-1, 1)),
  constraint financial_ledger_currency_check check (currency = 'IQD'),
  constraint financial_ledger_stage_check
    check (stage is null or stage in ('P1', 'P2', 'P3', 'P4', 'DONE')),

  -- العكس يشير دائماً إلى أصل، ويحمل الاتجاه المعاكس.
  constraint financial_ledger_reversal_shape
    check (
      (txn_type = 'REVERSAL' and reverses_entry_id is not null and direction = -1)
      or (txn_type <> 'REVERSAL' and reverses_entry_id is null)
    ),
  -- التصحيح يشير إلى ما يصحّحه، وهو حركة موجبة تحلّ محلّ الأصل.
  constraint financial_ledger_correction_shape
    check (
      (txn_type = 'CORRECTION' and corrects_entry_id is not null and direction = 1)
      or (txn_type <> 'CORRECTION' and corrects_entry_id is null)
    ),
  -- سبب إلزامي لكل حركة تصحيحية. لا تصحيح مجهول السبب.
  constraint financial_ledger_reason_required
    check (
      txn_type not in ('REVERSAL', 'CORRECTION', 'ADJUSTMENT')
      or (reason is not null and btrim(reason) <> '')
    )
);

-- لا يُعكس القيد مرتين. هذا هو الحارس البنيوي ضد العكس المزدوج، وهو أقوى من
-- أي فحص داخل الدالة لأنه يصمد أمام التزامن.
create unique index if not exists financial_ledger_one_reversal_per_entry
  on public.financial_ledger (reverses_entry_id)
  where reverses_entry_id is not null;

-- طلب واحد لا يُنفَّذ مرتين لنفس الفاعل.
create unique index if not exists financial_ledger_request_key
  on public.financial_ledger (created_by, request_id, txn_type);

create index if not exists financial_ledger_source_idx
  on public.financial_ledger (domain, source_table, source_id);
create index if not exists financial_ledger_agent_idx
  on public.financial_ledger (agent_name);
create index if not exists financial_ledger_subscriber_idx
  on public.financial_ledger (subscriber_id);

-- ---------------------------------------------------------------------------
-- 2. الصافي المشتق.
--
-- سؤال «كم صافي ما دُفع فعلاً» يُجاب من الدفتر وحده، بلا تعديل أي أصل.
--   PAYMENT +3000، REVERSAL -3000، CORRECTION +4000  ⇒  الصافي 4000
-- ---------------------------------------------------------------------------

create or replace view public.financial_net_position as
select
  l.domain,
  l.source_table,
  l.source_id,
  l.agent_name,
  l.subscriber_id,
  l.stage,
  sum(l.amount * l.direction)                                        as net_amount,
  sum(l.amount) filter (where l.direction = 1  and l.txn_type <> 'CORRECTION') as original_amount,
  sum(l.amount) filter (where l.txn_type = 'REVERSAL')               as reversed_amount,
  sum(l.amount) filter (where l.txn_type = 'CORRECTION')             as corrected_amount,
  sum(l.amount * l.direction) filter (where l.txn_type = 'ADJUSTMENT') as adjusted_amount,
  count(*) filter (where l.txn_type = 'REVERSAL') > 0                as is_reversed,
  count(*)                                                            as entry_count,
  max(l.posted_at)                                                    as last_movement_at
from public.financial_ledger l
group by l.domain, l.source_table, l.source_id, l.agent_name, l.subscriber_id, l.stage;

-- ---------------------------------------------------------------------------
-- 3. الحماية. لا كتابة مباشرة إطلاقاً؛ المسار هو الدوال أدناه.
-- ---------------------------------------------------------------------------

alter table public.financial_ledger enable row level security;

drop policy if exists financial_ledger_select on public.financial_ledger;
create policy financial_ledger_select
  on public.financial_ledger for select to authenticated using (true);

-- revoke all أولاً: قائمة الأفعال هي ما ترك TRUNCATE في app_settings.
revoke all on table public.financial_ledger from authenticated;
grant select on table public.financial_ledger to authenticated;
revoke all on table public.financial_ledger from anon;
revoke all on table public.financial_ledger from public;

revoke all on table public.financial_net_position from authenticated;
grant select on table public.financial_net_position to authenticated;
revoke all on table public.financial_net_position from anon;
revoke all on table public.financial_net_position from public;

-- الحذف ممنوع على أي مسار تطبيقي. القيد المالي لا يختفي.
create or replace function public.protect_financial_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Financial ledger entries cannot be deleted' using errcode = '42501';
  end if;
  -- التعديل مسموح فقط لتحويل الحالة إلى superseded؛ لا مبالغ ولا أطراف.
  if tg_op = 'UPDATE' then
    if new.amount is distinct from old.amount
      or new.direction is distinct from old.direction
      or new.txn_type is distinct from old.txn_type
      or new.domain is distinct from old.domain
      or new.agent_name is distinct from old.agent_name
      or new.subscriber_id is distinct from old.subscriber_id
      or new.stage is distinct from old.stage
      or new.source_id is distinct from old.source_id
      or new.reverses_entry_id is distinct from old.reverses_entry_id
      or new.corrects_entry_id is distinct from old.corrects_entry_id
      or new.created_by is distinct from old.created_by
      or new.request_id is distinct from old.request_id
    then
      raise exception 'A posted financial entry is immutable' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_financial_ledger on public.financial_ledger;
create trigger trg_protect_financial_ledger
  before update or delete on public.financial_ledger
  for each row execute function public.protect_financial_ledger();

-- ---------------------------------------------------------------------------
-- 4. استنساخ القيد الأصلي عند أول تصحيح عليه.
--
-- الدفتر يبدأ فارغاً ولا يُملأ بأثر رجعي. أول عملية تصحيح على سجل حي تُنشئ
-- قيده الأصلي من السجل نفسه ثم تبني عليه، فلا تُختلق بيانات لسجلات لم
-- يُطلب تصحيحها قط.
-- ---------------------------------------------------------------------------

create or replace function public.ensure_financial_origin(
  p_domain text,
  p_source_id uuid,
  p_request_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing uuid;
  v_id uuid;
  v_row record;
begin
  select id into v_existing from public.financial_ledger
  where domain = p_domain and source_id = p_source_id
    and txn_type in ('PAYMENT', 'HISTORICAL_PAYMENT')
  limit 1;
  if found then return v_existing; end if;

  if p_domain = 'installation' then
    select e.id, e.subscriber_id, e.reseller, e.stage, e.period, p.amount
      into v_row
    from public.installation_entitlements e
    join public.installation_payments p on p.entitlement_id = e.id
    where e.id = p_source_id;
    if not found then
      raise exception 'No installation payment found for %', p_source_id using errcode = 'P0002';
    end if;

    insert into public.financial_ledger (
      domain, txn_type, source_origin, source_table, source_id,
      agent_name, subscriber_id, stage, month_key, original_cycle_key,
      amount, direction, reason, request_id, created_by, posted_by
    ) values (
      'installation', 'PAYMENT', 'LEGACY_BACKFILL', 'installation_entitlements', v_row.id,
      v_row.reseller, v_row.subscriber_id, v_row.stage, v_row.period, v_row.period,
      v_row.amount, 1, 'origin captured for correction', p_request_id, v_actor, v_actor
    ) returning id into v_id;

  elsif p_domain = 'commission' then
    select r.id, r.name, m.month_key, r.paid into v_row
    from public.commission_rows r
    join public.commission_months m on m.id = r.month_id
    where r.id = p_source_id;
    if not found then
      raise exception 'No commission row found for %', p_source_id using errcode = 'P0002';
    end if;
    if coalesce(v_row.paid, 0) <= 0 then
      raise exception 'This commission row has no payment to correct' using errcode = '23514';
    end if;

    insert into public.financial_ledger (
      domain, txn_type, source_origin, source_table, source_id,
      agent_name, month_key, original_cycle_key,
      amount, direction, reason, request_id, created_by, posted_by
    ) values (
      'commission', 'PAYMENT', 'LEGACY_BACKFILL', 'commission_rows', v_row.id,
      v_row.name, v_row.month_key, v_row.month_key,
      v_row.paid::bigint, 1, 'origin captured for correction', p_request_id, v_actor, v_actor
    ) returning id into v_id;
  else
    raise exception 'Unknown financial domain %', p_domain using errcode = '22023';
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. العكس.
--
-- يُنشئ حركة معاكسة تشير إلى الأصل. الأصل يبقى. الصافي يصير صفراً.
-- ---------------------------------------------------------------------------

create or replace function public.reverse_financial_entry(
  p_domain text,
  p_source_id uuid,
  p_reason text,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing record;
  v_origin_id uuid;
  v_origin record;
  v_reversal_id uuid;
  v_net bigint;
  v_result jsonb;
begin
  -- العكس صلاحية إدارية. لا يُمنح للمحاسب لمجرد أنه يسجّل الدفعات:
  -- القدرة على إرسال المال والقدرة على نقضه سلطتان مختلفتان.
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required to reverse a payment' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required for every reversal' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'financial.reversed' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('reversal', v_existing.after_data, 'replayed', true);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('financial-correction:' || p_domain || ':' || p_source_id::text, 0)
  );

  v_origin_id := public.ensure_financial_origin(p_domain, p_source_id, p_request_id);
  select * into v_origin from public.financial_ledger where id = v_origin_id for update;

  -- الحارس البنيوي يمنع الثاني على أي حال؛ هذا يعطي رسالة مفهومة بدل خطأ فهرس.
  if exists (select 1 from public.financial_ledger where reverses_entry_id = v_origin_id) then
    raise exception 'This payment was already reversed' using errcode = '23505';
  end if;

  insert into public.financial_ledger (
    domain, txn_type, source_origin, source_table, source_id,
    agent_name, subscriber_id, stage, month_key, original_cycle_key,
    amount, direction, reason, reverses_entry_id,
    request_id, created_by, posted_by
  ) values (
    v_origin.domain, 'REVERSAL', 'CORRECTION_PATH', v_origin.source_table, v_origin.source_id,
    v_origin.agent_name, v_origin.subscriber_id, v_origin.stage,
    v_origin.month_key, v_origin.original_cycle_key,
    v_origin.amount, -1, btrim(p_reason), v_origin_id,
    p_request_id, v_actor, v_actor
  ) returning id into v_reversal_id;

  select coalesce(sum(amount * direction), 0) into v_net
  from public.financial_ledger where domain = v_origin.domain and source_id = v_origin.source_id;

  v_result := jsonb_build_object(
    'reversal_id', v_reversal_id, 'origin_id', v_origin_id,
    'domain', v_origin.domain, 'source_id', v_origin.source_id,
    'agent_name', v_origin.agent_name, 'stage', v_origin.stage,
    'original_amount', v_origin.amount, 'reversed_amount', v_origin.amount,
    'net_amount', v_net, 'reason', btrim(p_reason)
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, extra, before_data, after_data, request_id
  ) values (
    v_actor, 'financial.reversed', 'financial_ledger', v_reversal_id, 'net_amount',
    v_origin.amount::text, v_net::text, btrim(p_reason),
    jsonb_build_object('origin_id', v_origin_id, 'amount', v_origin.amount,
                       'agent_name', v_origin.agent_name),
    v_result, p_request_id
  );

  return jsonb_build_object('reversal', v_result, 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. التصحيح: عكس + بديل، في معاملة واحدة.
--
-- الوكيل الخطأ  : نفس المبلغ، طرف مختلف   ⇒ صافي الأصل صفر، والبديل كامل.
-- المبلغ الخطأ  : نفس الطرف، مبلغ مختلف   ⇒ الصافي هو المبلغ الصحيح.
-- ---------------------------------------------------------------------------

create or replace function public.correct_financial_entry(
  p_domain text,
  p_source_id uuid,
  p_reason text,
  p_corrected_agent_name text,
  p_corrected_amount bigint,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_existing record;
  v_origin_id uuid;
  v_origin record;
  v_reversal_id uuid;
  v_correction_id uuid;
  v_agent text;
  v_amount bigint;
  v_net bigint;
  v_result jsonb;
begin
  if v_actor is null or public.current_app_role() <> 'admin' then
    raise exception 'Admin permission is required to correct a payment' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required for every correction' using errcode = '22023';
  end if;

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_existing.action <> 'financial.corrected' then
      raise exception 'request_id was already used for another operation' using errcode = '23505';
    end if;
    return jsonb_build_object('correction', v_existing.after_data, 'replayed', true);
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('financial-correction:' || p_domain || ':' || p_source_id::text, 0)
  );

  v_origin_id := public.ensure_financial_origin(p_domain, p_source_id, p_request_id);
  select * into v_origin from public.financial_ledger where id = v_origin_id for update;

  if exists (select 1 from public.financial_ledger where reverses_entry_id = v_origin_id) then
    raise exception 'This payment was already reversed or corrected' using errcode = '23505';
  end if;

  v_agent := coalesce(nullif(btrim(coalesce(p_corrected_agent_name, '')), ''), v_origin.agent_name);
  v_amount := coalesce(p_corrected_amount, v_origin.amount);

  if v_amount <= 0 then
    raise exception 'A corrected amount must be greater than zero' using errcode = '23514';
  end if;
  if v_agent = v_origin.agent_name and v_amount = v_origin.amount then
    raise exception 'A correction must change the agent, the amount, or both' using errcode = '22023';
  end if;

  insert into public.financial_ledger (
    domain, txn_type, source_origin, source_table, source_id,
    agent_name, subscriber_id, stage, month_key, original_cycle_key,
    amount, direction, reason, reverses_entry_id,
    request_id, created_by, posted_by
  ) values (
    v_origin.domain, 'REVERSAL', 'CORRECTION_PATH', v_origin.source_table, v_origin.source_id,
    v_origin.agent_name, v_origin.subscriber_id, v_origin.stage,
    v_origin.month_key, v_origin.original_cycle_key,
    v_origin.amount, -1, btrim(p_reason), v_origin_id,
    p_request_id, v_actor, v_actor
  ) returning id into v_reversal_id;

  insert into public.financial_ledger (
    domain, txn_type, source_origin, source_table, source_id,
    agent_name, subscriber_id, stage, month_key, original_cycle_key,
    amount, direction, reason, corrects_entry_id,
    request_id, created_by, posted_by
  ) values (
    v_origin.domain, 'CORRECTION', 'CORRECTION_PATH', v_origin.source_table, v_origin.source_id,
    v_agent, v_origin.subscriber_id, v_origin.stage,
    v_origin.month_key, v_origin.original_cycle_key,
    v_amount, 1, btrim(p_reason), v_origin_id,
    p_request_id, v_actor, v_actor
  ) returning id into v_correction_id;

  select coalesce(sum(amount * direction), 0) into v_net
  from public.financial_ledger where domain = v_origin.domain and source_id = v_origin.source_id;

  v_result := jsonb_build_object(
    'origin_id', v_origin_id, 'reversal_id', v_reversal_id, 'correction_id', v_correction_id,
    'domain', v_origin.domain, 'source_id', v_origin.source_id,
    'original_agent', v_origin.agent_name, 'corrected_agent', v_agent,
    'original_amount', v_origin.amount, 'corrected_amount', v_amount,
    'net_amount', v_net, 'reason', btrim(p_reason)
  );

  insert into public.audit_logs (
    actor_id, action, entity_type, entity_id, field,
    old_value, new_value, extra, before_data, after_data, request_id
  ) values (
    v_actor, 'financial.corrected', 'financial_ledger', v_correction_id, 'net_amount',
    v_origin.amount::text, v_net::text, btrim(p_reason),
    jsonb_build_object('origin_id', v_origin_id, 'agent_name', v_origin.agent_name,
                       'amount', v_origin.amount),
    v_result, p_request_id
  );

  return jsonb_build_object('correction', v_result, 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. صلاحيات التنفيذ.
-- ---------------------------------------------------------------------------

revoke execute on function public.protect_financial_ledger() from public, anon;
revoke execute on function public.ensure_financial_origin(text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.reverse_financial_entry(text, uuid, text, uuid) from public, anon;
revoke execute on function public.correct_financial_entry(text, uuid, text, text, bigint, uuid) from public, anon;

grant execute on function public.reverse_financial_entry(text, uuid, text, uuid) to authenticated;
grant execute on function public.correct_financial_entry(text, uuid, text, text, bigint, uuid) to authenticated;

commit;
