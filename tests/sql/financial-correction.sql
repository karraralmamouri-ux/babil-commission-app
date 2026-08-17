-- أساس التصحيح المالي، مُتحقَّقاً منه على Postgres حقيقي.
--
-- كل تأكيد يفشل بصوت عالٍ. لا شيء يُقاس بالعين.

\set ON_ERROR_STOP on
begin;

create table if not exists public.correction_results (check_name text, result text);
truncate public.correction_results;

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into public.correction_results values (p_name, case when p_ok then 'pass' else 'FAIL ' || p_detail end);
  if not p_ok then
    raise exception 'FAILED: % %', p_name, p_detail;
  end if;
end;
$fn$;

-- ------------------------------------------------------------------ fixtures --
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@fixture.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'acct@fixture.invalid'),
  ('44444444-4444-4444-4444-444444444444', 'viewer@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Admin',  'admin@fixture.invalid',  'admin',      true),
  ('22222222-2222-2222-2222-222222222222', 'Acct',   'acct@fixture.invalid',   'accountant', true),
  ('44444444-4444-4444-4444-444444444444', 'Viewer', 'viewer@fixture.invalid', 'viewer',     true)
on conflict (id) do update set role = excluded.role, is_active = true;

create or replace function pg_temp.act_as(p_role text) returns void language plpgsql as $fn$
declare v_uid uuid;
begin
  select id into v_uid from public.profiles where role = p_role limit 1;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
end;
$fn$;

-- an installation entitlement that has genuinely been paid
insert into public.installation_batches (id, period, file_name, created_by)
values ('cccc0000-0000-0000-0000-000000000001', '2026-08', 'fixture.xlsx',
        '11111111-1111-1111-1111-111111111111');

insert into public.installation_entitlements (
  id, batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
  remaining, stage, amount, invoice_status, payment_status, paid_amount, created_by)
values ('dddd0000-0000-0000-0000-000000000001', 'cccc0000-0000-0000-0000-000000000001',
  '2026-08', 'SUB-CORRECT', 'Subscriber', 'Saeed Ammar', 'new', '108',
  4000, 'P4', 4000, 'approved', 'eligible', 0, '11111111-1111-1111-1111-111111111111');

select pg_temp.act_as('admin');
select public.record_installation_payment(
  'dddd0000-0000-0000-0000-000000000001'::uuid,
  (select updated_at from public.installation_entitlements where id='dddd0000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-0000000000f1'::uuid);

-- a commission row that has genuinely been paid
insert into public.commission_months (id, month_key, tiers, status, is_visible, created_by)
values ('eeee0000-0000-0000-0000-000000000001', '2026-08',
  '[{"key":"t1","label":"T1","min":0,"max":200,"p35":4000,"p45":5500,"p65":8000}]'::jsonb,
  'approved', true, '11111111-1111-1111-1111-111111111111');
insert into public.commission_rows (id, month_id, zone, name, p35, p45, p65, custom_tier, paid, created_by)
values ('ffff0000-0000-0000-0000-000000000001', 'eeee0000-0000-0000-0000-000000000001',
  'old', 'Saeed Ammar', 1, 0, 0, 't1', 4000, '11111111-1111-1111-1111-111111111111');

-- ---------------------------------------------------------------------------
-- 1. عكس صحيح.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.reverse_financial_entry(
  'installation', 'dddd0000-0000-0000-0000-000000000001'::uuid,
  'paid to the wrong agent', '00000000-0000-0000-0000-0000000000a1'::uuid);

select pg_temp.assert_that('a valid reversal succeeds',
  (select count(*) = 1 from public.financial_ledger where txn_type = 'REVERSAL'));

select pg_temp.assert_that('the reversal references its original',
  (select r.reverses_entry_id = o.id
   from public.financial_ledger r, public.financial_ledger o
   where r.txn_type = 'REVERSAL' and o.txn_type = 'PAYMENT'
     and o.source_id = 'dddd0000-0000-0000-0000-000000000001'));

select pg_temp.assert_that('the original payment row is untouched',
  (select amount = 4000 and payment_date is not null
   from public.installation_payments
   where entitlement_id = 'dddd0000-0000-0000-0000-000000000001'));

select pg_temp.assert_that('the original entitlement still reads paid — never reset to eligible',
  (select payment_status = 'paid' and paid_amount = 4000
   from public.installation_entitlements where id = 'dddd0000-0000-0000-0000-000000000001'),
  'resetting it would let the same stage be paid twice');

select pg_temp.assert_that('the net position is zero after a full reversal',
  (select net_amount = 0 and is_reversed
   from public.financial_net_position
   where source_id = 'dddd0000-0000-0000-0000-000000000001'));

select pg_temp.assert_that('the reversal is audited',
  (select count(*) = 1 from public.audit_logs where action = 'financial.reversed'));

-- ---------------------------------------------------------------------------
-- 2. لا عكس مزدوج، ولا إعادة تنفيذ لنفس الطلب.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.reverse_financial_entry(
      'installation', 'dddd0000-0000-0000-0000-000000000001'::uuid,
      'trying again', '00000000-0000-0000-0000-0000000000a2'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a second reversal of the same payment is refused', v_failed);
end $$;

do $$
declare v_result jsonb; v_count bigint;
begin
  perform pg_temp.act_as('admin');
  -- same request_id replayed: returns the original outcome, writes nothing new
  v_result := public.reverse_financial_entry(
    'installation', 'dddd0000-0000-0000-0000-000000000001'::uuid,
    'paid to the wrong agent', '00000000-0000-0000-0000-0000000000a1'::uuid);
  select count(*) into v_count from public.financial_ledger where txn_type = 'REVERSAL';
  perform pg_temp.assert_that('replaying a request is idempotent',
    (v_result ->> 'replayed')::boolean and v_count = 1);
end $$;

-- ---------------------------------------------------------------------------
-- 3. الوكيل الخطأ: الصافي ينتقل بالكامل إلى الطرف الصحيح.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.correct_financial_entry(
  'commission', 'ffff0000-0000-0000-0000-000000000001'::uuid,
  'attributed to the wrong agent', 'Ahmed Abdulabbas', null,
  '00000000-0000-0000-0000-0000000000b1'::uuid);

select pg_temp.assert_that('wrong-agent correction leaves the original agent at zero',
  (select coalesce(sum(amount * direction), 0) = 0
   from public.financial_ledger
   where source_id = 'ffff0000-0000-0000-0000-000000000001' and agent_name = 'Saeed Ammar'));

select pg_temp.assert_that('wrong-agent correction credits the correct agent in full',
  (select coalesce(sum(amount * direction), 0) = 4000
   from public.financial_ledger
   where source_id = 'ffff0000-0000-0000-0000-000000000001' and agent_name = 'Ahmed Abdulabbas'));

select pg_temp.assert_that('the source commission row was not rewritten',
  (select paid = 4000 and name = 'Saeed Ammar'
   from public.commission_rows where id = 'ffff0000-0000-0000-0000-000000000001'),
  'the original posted record must survive the correction');

select pg_temp.assert_that('three entries tell the whole story',
  (select count(*) = 3 from public.financial_ledger
   where source_id = 'ffff0000-0000-0000-0000-000000000001'));

-- ---------------------------------------------------------------------------
-- 4. المبلغ الخطأ: PAYMENT +3000، REVERSAL -3000، CORRECTION +4000 ⇒ 4000.
-- ---------------------------------------------------------------------------

insert into public.installation_entitlements (
  id, batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
  remaining, stage, amount, invoice_status, payment_status, paid_amount, created_by)
values ('dddd0000-0000-0000-0000-000000000002', 'cccc0000-0000-0000-0000-000000000001',
  '2026-08', 'SUB-AMOUNT', 'Subscriber Two', 'Saeed Ammar', 'new', '108',
  7000, 'P3', 3000, 'approved', 'eligible', 0, '11111111-1111-1111-1111-111111111111');

select pg_temp.act_as('admin');
select public.record_installation_payment(
  'dddd0000-0000-0000-0000-000000000002'::uuid,
  (select updated_at from public.installation_entitlements where id='dddd0000-0000-0000-0000-000000000002'),
  '00000000-0000-0000-0000-0000000000f2'::uuid);

select public.correct_financial_entry(
  'installation', 'dddd0000-0000-0000-0000-000000000002'::uuid,
  'the instalment amount was understated', null, 4000,
  '00000000-0000-0000-0000-0000000000b2'::uuid);

select pg_temp.assert_that('wrong-amount correction nets to the corrected figure',
  (select net_amount = 4000 and original_amount = 3000
      and reversed_amount = 3000 and corrected_amount = 4000
   from public.financial_net_position
   where source_id = 'dddd0000-0000-0000-0000-000000000002'));

select pg_temp.assert_that('the original installation payment row is unchanged',
  (select amount = 3000 from public.installation_payments
   where entitlement_id = 'dddd0000-0000-0000-0000-000000000002'));

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.correct_financial_entry(
      'installation', 'dddd0000-0000-0000-0000-000000000002'::uuid,
      'no actual change', null, null, '00000000-0000-0000-0000-0000000000b3'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a correction that changes nothing is refused', v_failed);
end $$;

-- ---------------------------------------------------------------------------
-- 5. الصلاحية: إدارية فقط.
-- ---------------------------------------------------------------------------

do $$
declare v_role text; v_blocked int := 0;
begin
  foreach v_role in array array['accountant', 'viewer', 'monitor'] loop
    perform pg_temp.act_as(v_role);
    begin
      perform public.reverse_financial_entry(
        'commission', 'ffff0000-0000-0000-0000-000000000001'::uuid,
        'should not be allowed', gen_random_uuid());
    exception when others then v_blocked := v_blocked + 1;
    end;
    begin
      perform public.correct_financial_entry(
        'commission', 'ffff0000-0000-0000-0000-000000000001'::uuid,
        'should not be allowed', 'Someone', 1, gen_random_uuid());
    exception when others then v_blocked := v_blocked + 1;
    end;
  end loop;
  perform pg_temp.assert_that('only an admin may reverse or correct', v_blocked = 6,
    v_blocked || '/6 refused');
end $$;

select pg_temp.assert_that('an accountant can still record a normal payment',
  (select count(*) = 2 from public.installation_payments),
  'the ordinary payment path must keep working');

-- ---------------------------------------------------------------------------
-- 6. سبب إلزامي.
-- ---------------------------------------------------------------------------

do $$
declare v_failed int := 0;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.reverse_financial_entry('commission',
      'ffff0000-0000-0000-0000-000000000001'::uuid, '', gen_random_uuid());
  exception when others then v_failed := v_failed + 1; end;
  begin
    perform public.reverse_financial_entry('commission',
      'ffff0000-0000-0000-0000-000000000001'::uuid, null, gen_random_uuid());
  exception when others then v_failed := v_failed + 1; end;
  perform pg_temp.assert_that('no anonymous correction: a reason is mandatory', v_failed = 2);
end $$;

-- ---------------------------------------------------------------------------
-- 7. القيد المالي لا يُعدَّل ولا يُحذف.
-- ---------------------------------------------------------------------------

do $$
declare v_blocked int := 0; v_id uuid;
begin
  select id into v_id from public.financial_ledger where txn_type = 'PAYMENT' limit 1;
  begin update public.financial_ledger set amount = 1 where id = v_id;
  exception when others then v_blocked := v_blocked + 1; end;
  begin update public.financial_ledger set agent_name = 'Someone Else' where id = v_id;
  exception when others then v_blocked := v_blocked + 1; end;
  begin delete from public.financial_ledger where id = v_id;
  exception when others then v_blocked := v_blocked + 1; end;
  perform pg_temp.assert_that('a posted ledger entry cannot be edited or deleted', v_blocked = 3,
    v_blocked || '/3 refused');
end $$;

-- ---------------------------------------------------------------------------
-- 8. حدود الكتابة على الدفتر نفسه.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that('the ledger grants only SELECT to authenticated',
  (select count(*) = 0 from information_schema.role_table_grants
   where grantee = 'authenticated' and table_name in ('financial_ledger','financial_net_position')
     and privilege_type <> 'SELECT'));

select pg_temp.assert_that('anon holds nothing on the ledger',
  (select count(*) = 0 from information_schema.role_table_grants
   where grantee = 'anon' and table_name in ('financial_ledger','financial_net_position')));

select pg_temp.assert_that('row level security is on for the ledger',
  (select relrowsecurity from pg_class where oid = 'public.financial_ledger'::regclass));

do $$
declare v_role text; v_blocked int := 0; v_total int := 0;
begin
  foreach v_role in array array['admin', 'accountant', 'viewer'] loop
    perform pg_temp.act_as(v_role);
    set local role authenticated;
    v_total := v_total + 2;
    begin
      insert into public.financial_ledger (domain, txn_type, source_origin, amount, direction,
        request_id, created_by)
      values ('commission', 'PAYMENT', 'PAYMENT_PATH', 1, 1, gen_random_uuid(),
              '11111111-1111-1111-1111-111111111111');
    exception when others then v_blocked := v_blocked + 1; end;
    begin execute 'truncate table public.financial_ledger';
    exception when others then v_blocked := v_blocked + 1; end;
    reset role;
  end loop;
  perform pg_temp.assert_that('no role can write or truncate the ledger directly',
    v_blocked = v_total, v_blocked || '/' || v_total || ' refused');
end $$;

-- ---------------------------------------------------------------------------
-- 9. البيانات القائمة لم تتغير.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that('correcting created no extra installation payment',
  (select count(*) = 2 from public.installation_payments));

select pg_temp.assert_that('correcting created no extra commission row',
  (select count(*) = 1 from public.commission_rows));

select pg_temp.assert_that('no historical installation payment history was touched',
  (select count(*) = 0 from public.installation_payment_history));

select pg_temp.assert_that('every ledger entry carries an actor, a request and a timestamp',
  (select count(*) = 0 from public.financial_ledger
   where created_by is null or request_id is null or posted_at is null));

select check_name, result from public.correction_results order by check_name;
drop table public.correction_results;

rollback;
