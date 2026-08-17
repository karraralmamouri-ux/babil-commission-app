-- تكامل مسار الدفع العادي مع الدفتر.
--
-- الفجوة التي تغلقها هذه الاختبارات: تصحيح موجب يرفع الوضع الفعلي، فإن ظل
-- حارس التجاوز يقيس على العمود القديم وحده سمح بدفع زائد. الحالة الحاسمة هي
-- §4 أدناه، وهي تفشل ضد النسخة السابقة من الدالة.

\set ON_ERROR_STOP on
begin;

create table if not exists public.integration_results (check_name text, result text);
truncate public.integration_results;

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into public.integration_results values (p_name, case when p_ok then 'pass' else 'FAIL ' || p_detail end);
  if not p_ok then raise exception 'FAILED: % %', p_name, p_detail; end if;
end;
$fn$;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@fixture.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'acct@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Admin', 'admin@fixture.invalid', 'admin', true),
  ('22222222-2222-2222-2222-222222222222', 'Acct',  'acct@fixture.invalid',  'accountant', true)
on conflict (id) do update set role = excluded.role, is_active = true;

create or replace function pg_temp.act_as(p_role text) returns void language plpgsql as $fn$
declare v_uid uuid;
begin
  select id into v_uid from public.profiles where role = p_role limit 1;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
end;
$fn$;

create or replace function pg_temp.row_stamp(p_id uuid) returns timestamptz
language sql as $fn$ select updated_at from public.commission_rows where id = p_id; $fn$;

-- المستحق: تير t1 بسعر 1000 لكل P35 × 10 = 10000، وهو الرقم في مثال المراجعة.
insert into public.commission_months (id, month_key, tiers, status, is_visible, created_by)
values ('aaaa1111-0000-0000-0000-000000000001', '2026-08',
  '[{"key":"t1","label":"T1","min":0,"max":200,"p35":1000,"p45":1000,"p65":1000}]'::jsonb,
  'approved', true, '11111111-1111-1111-1111-111111111111');
insert into public.commission_rows (id, month_id, zone, name, p35, p45, p65, custom_tier, paid, created_by)
values ('bbbb1111-0000-0000-0000-000000000001', 'aaaa1111-0000-0000-0000-000000000001',
  'old', 'Saeed Ammar', 10, 0, 0, 't1', 0, '11111111-1111-1111-1111-111111111111');

-- ---------------------------------------------------------------------------
-- 1. الدفعة العادية تُنشئ دليلاً في الدفتر.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('accountant');
select public.record_commission_payment(
  'bbbb1111-0000-0000-0000-000000000001'::uuid,
  pg_temp.row_stamp('bbbb1111-0000-0000-0000-000000000001'),
  3000, current_date, '00000000-0000-0000-0000-00000000e001'::uuid);

select pg_temp.assert_that('a normal commission payment writes a PAYMENT ledger entry',
  (select count(*) = 1 and max(amount) = 3000 and max(direction) = 1
   from public.financial_ledger
   where domain = 'commission' and source_id = 'bbbb1111-0000-0000-0000-000000000001'
     and txn_type = 'PAYMENT'));

select pg_temp.assert_that('the ledger entry records its origin as the payment path',
  (select source_origin = 'PAYMENT_PATH' from public.financial_ledger
   where source_id = 'bbbb1111-0000-0000-0000-000000000001' and txn_type = 'PAYMENT'));

select pg_temp.assert_that('effective paid matches the legacy column before any correction',
  public.effective_paid_amount('commission', 'bbbb1111-0000-0000-0000-000000000001'::uuid,
    (select paid from public.commission_rows where id='bbbb1111-0000-0000-0000-000000000001')) = 3000);

-- ---------------------------------------------------------------------------
-- 2. إعادة الطلب لا تُضاعف قيد الدفتر.
-- ---------------------------------------------------------------------------

do $$
declare v_result jsonb;
begin
  perform pg_temp.act_as('accountant');
  v_result := public.record_commission_payment(
    'bbbb1111-0000-0000-0000-000000000001'::uuid,
    pg_temp.row_stamp('bbbb1111-0000-0000-0000-000000000001'),
    3000, current_date, '00000000-0000-0000-0000-00000000e001'::uuid);
  perform pg_temp.assert_that('a replayed payment adds no second ledger entry',
    (v_result ->> 'replayed')::boolean
    and (select count(*) = 1 from public.financial_ledger
         where source_id = 'bbbb1111-0000-0000-0000-000000000001' and txn_type = 'PAYMENT'));
end $$;

-- ---------------------------------------------------------------------------
-- 3. التصحيح يحرّك الوضع الفعلي دون لمس العمود القديم.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.correct_financial_entry(
  'commission', 'bbbb1111-0000-0000-0000-000000000001'::uuid,
  'the instalment was understated', null, 4000,
  '00000000-0000-0000-0000-00000000e002'::uuid);

select pg_temp.assert_that('the legacy paid column is untouched by the correction',
  (select paid = 3000 from public.commission_rows
   where id = 'bbbb1111-0000-0000-0000-000000000001'));

select pg_temp.assert_that('the effective paid position moved to the corrected figure',
  public.effective_paid_amount('commission', 'bbbb1111-0000-0000-0000-000000000001'::uuid, 3000) = 4000);

-- ---------------------------------------------------------------------------
-- 4. الحالة الحاسمة — لا دفع زائد بعد تصحيح موجب.
--
-- المستحق 10000 · القديم 3000 · الفعلي 4000 ⇒ الأقصى الإضافي 6000.
-- طلب زيادة 7000 (أي paid=10000) يجب أن يُرفض. النسخة السابقة كانت تقبله.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('accountant');
  begin
    perform public.record_commission_payment(
      'bbbb1111-0000-0000-0000-000000000001'::uuid,
      pg_temp.row_stamp('bbbb1111-0000-0000-0000-000000000001'),
      10000, current_date, '00000000-0000-0000-0000-00000000e003'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that(
    'a payment that ignores the correction is refused',
    v_failed,
    'effective 4000 + new 7000 would exceed the 10000 due');
end $$;

select pg_temp.assert_that('the refused attempt changed nothing',
  (select paid = 3000 from public.commission_rows where id = 'bbbb1111-0000-0000-0000-000000000001')
  and public.effective_paid_amount('commission', 'bbbb1111-0000-0000-0000-000000000001'::uuid, 3000) = 4000);

-- الزيادة المسموحة بالضبط تمر.
select pg_temp.act_as('accountant');
select public.record_commission_payment(
  'bbbb1111-0000-0000-0000-000000000001'::uuid,
  pg_temp.row_stamp('bbbb1111-0000-0000-0000-000000000001'),
  9000, current_date, '00000000-0000-0000-0000-00000000e004'::uuid);

select pg_temp.assert_that('the largest legitimate top-up is accepted and lands exactly on the due',
  public.effective_paid_amount('commission', 'bbbb1111-0000-0000-0000-000000000001'::uuid, 9000) = 10000);

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('accountant');
  begin
    perform public.record_commission_payment(
      'bbbb1111-0000-0000-0000-000000000001'::uuid,
      pg_temp.row_stamp('bbbb1111-0000-0000-0000-000000000001'),
      9500, current_date, '00000000-0000-0000-0000-00000000e005'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('nothing more can be paid once the due is reached', v_failed);
end $$;

-- ---------------------------------------------------------------------------
-- 5. أثر العكس يُحتسب باتساق: العكس يفتح مساحة دفع بقدره، لا أكثر.
-- ---------------------------------------------------------------------------

insert into public.commission_rows (id, month_id, zone, name, p35, p45, p65, custom_tier, paid, created_by)
values ('bbbb1111-0000-0000-0000-000000000002', 'aaaa1111-0000-0000-0000-000000000001',
  'old', 'Reversal Agent', 10, 0, 0, 't1', 0, '11111111-1111-1111-1111-111111111111');

select pg_temp.act_as('accountant');
select public.record_commission_payment(
  'bbbb1111-0000-0000-0000-000000000002'::uuid,
  pg_temp.row_stamp('bbbb1111-0000-0000-0000-000000000002'),
  10000, current_date, '00000000-0000-0000-0000-00000000e006'::uuid);

select pg_temp.act_as('admin');
select public.reverse_financial_entry(
  'commission', 'bbbb1111-0000-0000-0000-000000000002'::uuid,
  'sent in error', '00000000-0000-0000-0000-00000000e007'::uuid);

select pg_temp.assert_that('a full reversal returns the effective position to zero',
  public.effective_paid_amount('commission', 'bbbb1111-0000-0000-0000-000000000002'::uuid, 10000) = 0);

select pg_temp.assert_that('the reversal did not rewrite the legacy paid column',
  (select paid = 10000 from public.commission_rows where id = 'bbbb1111-0000-0000-0000-000000000002'));

-- ---------------------------------------------------------------------------
-- 6. التنصيب: قيد الدفتر، ثم استحالة إعادة الدفع بعد العكس.
-- ---------------------------------------------------------------------------

insert into public.installation_batches (id, period, file_name, created_by)
values ('cccc1111-0000-0000-0000-000000000001', '2026-08', 'integration.xlsx',
        '11111111-1111-1111-1111-111111111111');
insert into public.installation_entitlements (
  id, batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
  remaining, stage, amount, invoice_status, payment_status, paid_amount, created_by)
values ('dddd1111-0000-0000-0000-000000000001', 'cccc1111-0000-0000-0000-000000000001',
  '2026-08', 'SUB-INT', 'Subscriber', 'Saeed Ammar', 'new', '108',
  4000, 'P4', 4000, 'approved', 'eligible', 0, '11111111-1111-1111-1111-111111111111');

select pg_temp.act_as('accountant');
select public.record_installation_payment(
  'dddd1111-0000-0000-0000-000000000001'::uuid,
  (select updated_at from public.installation_entitlements where id='dddd1111-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-00000000e008'::uuid);

select pg_temp.assert_that('a normal installation payment writes a PAYMENT ledger entry',
  (select count(*) = 1 and max(amount) = 4000 and max(stage) = 'P4'
   from public.financial_ledger
   where domain = 'installation' and source_id = 'dddd1111-0000-0000-0000-000000000001'
     and txn_type = 'PAYMENT'));

select pg_temp.act_as('admin');
select public.reverse_financial_entry(
  'installation', 'dddd1111-0000-0000-0000-000000000001'::uuid,
  'paid against the wrong subscriber', '00000000-0000-0000-0000-00000000e009'::uuid);

select pg_temp.assert_that('the reversal did not create a second origin entry',
  (select count(*) = 1 from public.financial_ledger
   where source_id = 'dddd1111-0000-0000-0000-000000000001' and txn_type = 'PAYMENT'),
  'ensure_financial_origin must reuse the entry the payment path already wrote');

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('accountant');
  begin
    perform public.record_installation_payment(
      'dddd1111-0000-0000-0000-000000000001'::uuid,
      (select updated_at from public.installation_entitlements
       where id='dddd1111-0000-0000-0000-000000000001'),
      '00000000-0000-0000-0000-00000000e010'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that(
    'a reversed installation stage cannot be repaid through the normal path',
    v_failed,
    'the entitlement deliberately stays paid so the ordinary path refuses it');
end $$;

select pg_temp.assert_that('only one installation payment row exists for that stage',
  (select count(*) = 1 from public.installation_payments
   where entitlement_id = 'dddd1111-0000-0000-0000-000000000001'));

-- ---------------------------------------------------------------------------
-- 7. إجابة واحدة لا إجابتان.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that('the net view and the effective function agree',
  (select n.net_amount = public.effective_paid_amount(n.domain, n.source_id, 0)
   from public.financial_net_position n
   where n.source_id = 'bbbb1111-0000-0000-0000-000000000001'));

select pg_temp.assert_that('a source with no ledger entry falls back to its legacy column',
  public.effective_paid_amount('commission', gen_random_uuid(), 777) = 777);

select pg_temp.assert_that('every payment kept its audit entry',
  (select count(*) >= 4 from public.audit_logs
   where action in ('commission.payment.recorded', 'installation.payment.recorded')));

select pg_temp.assert_that('every correction kept its audit entry',
  -- one correction in section 3, two reversals in sections 5 and 6
  (select count(*) = 3 from public.audit_logs
   where action in ('financial.corrected', 'financial.reversed')),
  (select count(*)::text from public.audit_logs
   where action in ('financial.corrected', 'financial.reversed')));

select check_name, result from public.integration_results order by check_name;
drop table public.integration_results;

rollback;
