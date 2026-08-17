-- إصلاح: المدفوع القديم كان يضيع عند أول حركة في الدفتر.
--
-- العيب. effective_paid_amount تعتمد قاعدة «ما دام الدفتر فارغاً لهذا السجل
-- فالعمود القديم هو الحقيقة، وبمجرد وجود قيد واحد يصير الدفتر هو الحقيقة
-- الكاملة». وهذا سليم بشرط أن يحمل الدفتر كامل ما دُفع. لكن مسار الدفع كان
-- يكتب الزيادة وحدها، فإن كان العمود القديم يحمل مبلغاً سابقاً على 0b، ضاع
-- ذلك المبلغ لحظة أول قيد:
--
--   العمود القديم 3000 · زيادة جديدة 2000
--   ⇒ الدفتر 2000 وحدها ⇒ الفعلي 2000، والصحيح 5000
--
-- الخطورة: النتيجة تُنقِص الوضع الفعلي، وحارس التجاوز يقيس عليها، فيسمح بدفع
-- أكثر من المستحق — وهي نفس الثغرة التي أُغلقت في 20260818140000 عائدة من باب
-- آخر. مُثبَتة على قاعدة حقيقية قبل الإصلاح.
--
-- الإصلاح. قبل كتابة أول قيد لسجل يحمل مدفوعاً قديماً، يُستنسخ ذلك المبلغ
-- كقيد أصل بوسم LEGACY_BACKFILL. عندها يساوي مجموع الدفتر كل ما دُفع فعلاً،
-- وتبقى القاعدة صحيحة.
--
-- لا backfill شامل: الاستنساخ يحدث للسجل الذي يُدفع له أو يُصحَّح فقط، لحظة
-- حدوث ذلك. السجلات التي لم يُطلب تحريكها تبقى بلا قيود.
--
-- forward-only. لا بيانات تتغير، ولا عمود يُعدَّل.

begin;

create or replace function public.record_commission_payment(
  p_row_id uuid,
  p_expected_updated_at timestamptz,
  p_paid numeric,
  p_payment_date date,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := public.current_app_role();
  v_existing public.audit_logs%rowtype;
  v_before public.commission_rows%rowtype;
  v_after public.commission_rows%rowtype;
  v_tiers jsonb;
  v_month_key text;
  v_due numeric;
  v_effective_before numeric;
  v_delta numeric;
  v_ledger_entries integer;
begin
  if v_actor is null or v_role is null
    or v_role not in ('admin', 'accountant')
  then
    raise exception 'Payment permission is required' using errcode = '42501';
  end if;

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_actor::text || ':' || p_request_id::text, 0)
  );

  select * into v_existing from public.audit_logs
  where actor_id = v_actor and request_id = p_request_id;

  if found then
    if v_existing.action <> 'commission.payment.recorded'
      or v_existing.entity_id is distinct from p_row_id
    then
      raise exception 'request_id was already used for another operation'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'row', v_existing.after_data, 'due', (v_existing.extra)::numeric,
      'replayed', true, 'request_id', p_request_id
    );
  end if;

  if p_paid is null or p_paid < 0 then
    raise exception 'Payment cannot be negative' using errcode = '22023';
  end if;

  select r.* into v_before from public.commission_rows as r
  where r.id = p_row_id for update;

  if not found then
    raise exception 'Commission row was not found' using errcode = 'P0002';
  end if;

  if p_expected_updated_at is null
    or v_before.updated_at is distinct from p_expected_updated_at
  then
    raise exception 'Commission row changed since it was loaded' using errcode = '40001';
  end if;

  select month_key, tiers into v_month_key, v_tiers
  from public.commission_months where id = v_before.month_id;

  v_due := public.calculate_commission_due(
    v_tiers, v_before.p35, v_before.p45, v_before.p65, v_before.custom_tier);

  v_effective_before := public.effective_paid_amount('commission', p_row_id, v_before.paid);
  v_delta := p_paid - v_before.paid;

  if v_effective_before + v_delta > v_due then
    raise exception 'Payment cannot exceed commission due'
      using errcode = '23514',
            detail = format('effective paid %s + new %s exceeds due %s',
                            v_effective_before, v_delta, v_due);
  end if;

  update public.commission_rows
  set paid = p_paid, payment_date = p_payment_date
  where id = p_row_id
  returning * into v_after;

  if v_delta > 0 then
    -- هنا الإصلاح. الدفتر يصير المرجع بمجرد أول قيد، فيجب أن يحمل ما دُفع
    -- قبله أيضاً؛ وإلا اختفى المبلغ القديم من الوضع الفعلي.
    select count(*) into v_ledger_entries from public.financial_ledger
    where domain = 'commission' and source_id = p_row_id;

    if v_ledger_entries = 0 and v_before.paid > 0 then
      insert into public.financial_ledger (
        domain, txn_type, source_origin, source_table, source_id,
        agent_name, month_key, original_cycle_key,
        amount, direction, reason, request_id, created_by, posted_by
      ) values (
        'commission', 'PAYMENT', 'LEGACY_BACKFILL', 'commission_rows', p_row_id,
        v_after.name, v_month_key, v_month_key,
        v_before.paid::bigint, 1, 'paid before the ledger existed',
        p_request_id, v_actor, v_actor
      );
    end if;

    insert into public.financial_ledger (
      domain, txn_type, source_origin, source_table, source_id,
      agent_name, month_key, original_cycle_key,
      amount, direction, reason, request_id, created_by, posted_by
    ) values (
      'commission', 'PAYMENT', 'PAYMENT_PATH', 'commission_rows', p_row_id,
      v_after.name, v_month_key, v_month_key,
      v_delta::bigint, 1, null, p_request_id, v_actor, v_actor
    );
  end if;

  insert into public.audit_logs (
    actor_id, month_key, zone, agent, action, field,
    old_value, new_value, extra, entity_type, entity_id,
    before_data, after_data, request_id
  ) values (
    v_actor, v_month_key, v_after.zone, v_after.name,
    'commission.payment.recorded', 'paid,payment_date',
    to_jsonb(v_before)::text, to_jsonb(v_after)::text, v_due::text,
    'commission_row', v_after.id,
    to_jsonb(v_before), to_jsonb(v_after), p_request_id
  );

  return jsonb_build_object(
    'row', to_jsonb(v_after), 'due', v_due,
    'effective_paid', v_effective_before + greatest(v_delta, 0),
    'replayed', false, 'request_id', p_request_id
  );
end;
$$;

-- القيد الفريد على (created_by, request_id, txn_type) يمنع قيدَي PAYMENT من
-- الطلب نفسه، والاستنساخ أعلاه يُنشئ قيداً ثانياً بالنوع نفسه. الفهرس يُوسَّع
-- ليشمل مصدر القيد، فيبقى منع التكرار قائماً لكل مصدر على حدة.
drop index if exists public.financial_ledger_request_key;
create unique index if not exists financial_ledger_request_key
  on public.financial_ledger (created_by, request_id, txn_type, source_origin);

revoke execute on function public.record_commission_payment(uuid, timestamptz, numeric, date, uuid)
  from public, anon;
grant execute on function public.record_commission_payment(uuid, timestamptz, numeric, date, uuid)
  to authenticated;

commit;
