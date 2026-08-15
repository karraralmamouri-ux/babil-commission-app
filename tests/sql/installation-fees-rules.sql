-- Installation-fee rule tests against a throwaway local Postgres.
-- Everything runs inside one transaction and is rolled back, so the database is
-- left exactly as it was found. Never point this at production or staging.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------- fixtures --
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@fixture.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'accountant@fixture.invalid'),
  ('33333333-3333-3333-3333-333333333333', 'monitor@fixture.invalid'),
  ('44444444-4444-4444-4444-444444444444', 'viewer@fixture.invalid');

insert into public.profiles (id, full_name, email, role, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Admin',      'admin@fixture.invalid',      'admin',      true),
  ('22222222-2222-2222-2222-222222222222', 'Accountant', 'accountant@fixture.invalid', 'accountant', true),
  ('33333333-3333-3333-3333-333333333333', 'Monitor',    'monitor@fixture.invalid',    'monitor',    true),
  ('44444444-4444-4444-4444-444444444444', 'Viewer',     'viewer@fixture.invalid',     'viewer',     true);

insert into public.installation_batches (id, period, file_name, created_by)
values ('aaaaaaaa-0000-0000-0000-000000000001', '2026-07', 'fixture.xlsx',
        '11111111-1111-1111-1111-111111111111');

insert into public.installation_entitlements
  (id, batch_id, period, subscriber_id, reseller, zone, remaining, stage, amount, created_by)
values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
   '2026-07', 'SUB-P1', 'Fixture Reseller', 'new', 13000, 'P1', 3000,
   '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
   '2026-07', 'SUB-P4', 'Fixture Reseller', 'new', 4000, 'P4', 4000,
   '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001',
   '2026-07', 'SUB-DONE', 'Fixture Reseller', 'new', 0, 'DONE', 0,
   '11111111-1111-1111-1111-111111111111');

-- --------------------------------------------------------------- assertions --
create or replace function pg_temp.expect_error(p_label text, p_sql text, p_sqlstate text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_sqlstate is not null and sqlstate <> p_sqlstate then
      raise exception 'FAIL % : expected SQLSTATE % but got % (%)', p_label, p_sqlstate, sqlstate, sqlerrm;
    end if;
    raise notice 'pass  %', p_label;
    return;
  end;
  raise exception 'FAIL % : statement unexpectedly succeeded', p_label;
end;
$$;

create or replace function pg_temp.expect(p_label text, p_condition boolean)
returns void language plpgsql as $$
begin
  if not p_condition then
    raise exception 'FAIL % : condition was false', p_label;
  end if;
  raise notice 'pass  %', p_label;
end;
$$;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
end;
$$;

-- Rule 3 — Remaining, stage and amount must agree.
select pg_temp.expect_error(
  'amount that does not match the stage is rejected',
  $q$insert into public.installation_entitlements
       (period, subscriber_id, reseller, remaining, stage, amount, created_by)
     values ('2026-07','SUB-BAD-AMT','R',13000,'P1',50000,
             '11111111-1111-1111-1111-111111111111')$q$,
  '23514');

select pg_temp.expect_error(
  'stage that does not match Remaining is rejected',
  $q$insert into public.installation_entitlements
       (period, subscriber_id, reseller, remaining, stage, amount, created_by)
     values ('2026-07','SUB-BAD-STAGE','R',10000,'P1',3000,
             '11111111-1111-1111-1111-111111111111')$q$,
  '23514');

select pg_temp.expect_error(
  'an unknown Remaining has no stage and is rejected',
  $q$insert into public.installation_entitlements
       (period, subscriber_id, reseller, remaining, stage, amount, created_by)
     values ('2026-07','SUB-UNKNOWN','R',5500,'P1',3000,
             '11111111-1111-1111-1111-111111111111')$q$,
  '23514');

-- Rule 22 — one entitlement per subscriber, stage and period.
select pg_temp.expect_error(
  'a duplicate subscriber/stage/period is rejected',
  $q$insert into public.installation_entitlements
       (period, subscriber_id, reseller, remaining, stage, amount, created_by)
     values ('2026-07','SUB-P1','Fixture Reseller',13000,'P1',3000,
             '11111111-1111-1111-1111-111111111111')$q$,
  '23505');

-- Rule 1 — the invoice gate.
select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select pg_temp.expect_error(
  'payment is blocked while the invoice is unaudited',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000001', null, gen_random_uuid())$q$,
  '23514');

select public.audit_installation_invoice(
  'bbbbbbbb-0000-0000-0000-000000000001', 'missing', 'no invoice on file', gen_random_uuid());
select pg_temp.expect_error(
  'payment is blocked when the invoice is missing',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000001', null, gen_random_uuid())$q$,
  '23514');

select public.audit_installation_invoice(
  'bbbbbbbb-0000-0000-0000-000000000001', 'rejected', 'invalid invoice', gen_random_uuid());
select pg_temp.expect_error(
  'payment is blocked when the invoice is rejected',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000001', null, gen_random_uuid())$q$,
  '23514');

-- Rule 2 — DONE is never payable, even with an approved invoice.
select public.audit_installation_invoice(
  'bbbbbbbb-0000-0000-0000-000000000003', 'approved', null, gen_random_uuid());
select pg_temp.expect(
  'approving a DONE invoice still leaves it not eligible',
  (select payment_status = 'not_eligible' from public.installation_entitlements
    where id = 'bbbbbbbb-0000-0000-0000-000000000003'));
select pg_temp.expect_error(
  'a DONE subscriber cannot be paid',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000003', null, gen_random_uuid())$q$,
  '23514');

-- Happy path — approve, then pay.
select public.audit_installation_invoice(
  'bbbbbbbb-0000-0000-0000-000000000001', 'approved', 'invoice checked', gen_random_uuid());
select pg_temp.expect(
  'an approved invoice makes the instalment eligible',
  (select payment_status = 'eligible' from public.installation_entitlements
    where id = 'bbbbbbbb-0000-0000-0000-000000000001'));

select public.record_installation_payment(
  'bbbbbbbb-0000-0000-0000-000000000001', null, '99999999-0000-0000-0000-000000000001');

select pg_temp.expect(
  'the paid instalment records the server-derived amount',
  (select paid_amount = 3000 and payment_status = 'paid'
     and paid_by = '22222222-2222-2222-2222-222222222222'
   from public.installation_entitlements where id = 'bbbbbbbb-0000-0000-0000-000000000001'));
select pg_temp.expect(
  'a ledger row is written for the payment',
  (select count(*) = 1 from public.installation_payments
    where entitlement_id = 'bbbbbbbb-0000-0000-0000-000000000001' and amount = 3000));
select pg_temp.expect(
  'the payment is recorded in the shared audit log',
  (select count(*) = 1 from public.audit_logs
    where action = 'installation.payment.recorded'
      and entity_id = 'bbbbbbbb-0000-0000-0000-000000000001'));

-- Rule 4 — no second payment for the same instalment.
select pg_temp.expect_error(
  'the same instalment cannot be paid twice',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000001', null, gen_random_uuid())$q$,
  '23505');

-- Idempotency — replaying the original request returns the first result.
select pg_temp.expect(
  'replaying the same request_id is reported as a replay',
  (select (public.record_installation_payment(
            'bbbbbbbb-0000-0000-0000-000000000001', null,
            '99999999-0000-0000-0000-000000000001') ->> 'replayed')::boolean));
select pg_temp.expect(
  'a replay does not add a second ledger row',
  (select count(*) = 1 from public.installation_payments
    where entitlement_id = 'bbbbbbbb-0000-0000-0000-000000000001'));

-- A paid instalment is frozen for auditing.
select pg_temp.expect_error(
  'a paid instalment cannot be re-audited',
  $q$select public.audit_installation_invoice(
       'bbbbbbbb-0000-0000-0000-000000000001', 'rejected', null, gen_random_uuid())$q$,
  '23514');

-- Optimistic concurrency.
select public.audit_installation_invoice(
  'bbbbbbbb-0000-0000-0000-000000000002', 'approved', null, gen_random_uuid());
select pg_temp.expect_error(
  'a stale updated_at is refused',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000002',
       '2000-01-01T00:00:00Z'::timestamptz, gen_random_uuid())$q$,
  '40001');

-- Roles — monitor and viewer may never audit or pay.
select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select pg_temp.expect_error(
  'monitor cannot audit an invoice',
  $q$select public.audit_installation_invoice(
       'bbbbbbbb-0000-0000-0000-000000000002','approved',null,gen_random_uuid())$q$,
  '42501');
select pg_temp.expect_error(
  'monitor cannot record a payment',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000002', null, gen_random_uuid())$q$,
  '42501');

select pg_temp.act_as('44444444-4444-4444-4444-444444444444');
select pg_temp.expect_error(
  'viewer cannot record a payment',
  $q$select public.record_installation_payment(
       'bbbbbbbb-0000-0000-0000-000000000002', null, gen_random_uuid())$q$,
  '42501');

-- Admin retains both abilities.
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select public.record_installation_payment(
  'bbbbbbbb-0000-0000-0000-000000000002', null, gen_random_uuid());
select pg_temp.expect(
  'admin can pay an approved P4 instalment for its exact amount',
  (select paid_amount = 4000 and payment_status = 'paid'
   from public.installation_entitlements where id = 'bbbbbbbb-0000-0000-0000-000000000002'));

-- RLS — a browser session reads but never writes.
set local role authenticated;
select pg_temp.act_as('44444444-4444-4444-4444-444444444444');
select pg_temp.expect(
  'viewer can read entitlements through RLS',
  (select count(*) >= 3 from public.installation_entitlements));
select pg_temp.expect_error(
  'authenticated has no direct update on entitlements',
  $q$update public.installation_entitlements set paid_amount = 999
      where id = 'bbbbbbbb-0000-0000-0000-000000000003'$q$,
  '42501');
select pg_temp.expect_error(
  'authenticated has no direct insert into the payment ledger',
  $q$insert into public.installation_payments
       (entitlement_id, amount, request_id, created_by)
     values ('bbbbbbbb-0000-0000-0000-000000000003', 5000, gen_random_uuid(),
             '44444444-4444-4444-4444-444444444444')$q$,
  '42501');
reset role;

rollback;
