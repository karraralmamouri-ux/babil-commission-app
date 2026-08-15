-- End-to-end installation-fee import against a throwaway local Postgres:
-- Excel/CSV rows -> Confirm Import -> central DB -> invoice audit -> eligibility
-- -> payment -> history -> archive. Rolled back at the end.

\set ON_ERROR_STOP on

begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@fixture.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'accountant@fixture.invalid'),
  ('44444444-4444-4444-4444-444444444444', 'viewer@fixture.invalid');

insert into public.profiles (id, full_name, email, role, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Admin',      'admin@fixture.invalid',      'admin',      true),
  ('22222222-2222-2222-2222-222222222222', 'Accountant', 'accountant@fixture.invalid', 'accountant', true),
  ('44444444-4444-4444-4444-444444444444', 'Viewer',     'viewer@fixture.invalid',     'viewer',     true);

create or replace function pg_temp.expect(p_label text, p_condition boolean)
returns void language plpgsql as $$
begin
  if not p_condition then raise exception 'FAIL % : condition was false', p_label; end if;
  raise notice 'pass  %', p_label;
end;
$$;

create or replace function pg_temp.expect_error(p_label text, p_sql text, p_sqlstate text)
returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if p_sqlstate is not null and sqlstate <> p_sqlstate then
      raise exception 'FAIL % : expected % got % (%)', p_label, p_sqlstate, sqlstate, sqlerrm;
    end if;
    raise notice 'pass  %', p_label; return;
  end;
  raise exception 'FAIL % : statement unexpectedly succeeded', p_label;
end;
$$;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_user::text, true); end;
$$;

-- Builds `count` raw subscriber rows exactly as the browser would send them.
create or replace function pg_temp.rows_at(p_reseller text, p_remaining bigint, p_count integer, p_tag text)
returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'subscriber_id', p_reseller || '-' || p_tag || '-' || g,
    'subscriber_name', 'subscriber ' || g,
    'reseller', p_reseller,
    'zone', 'new',
    'remaining', p_remaining
  )), '[]'::jsonb)
  from generate_series(1, p_count) g;
$$;

-- ------------------------------------------------------------ authorisation --
select pg_temp.act_as('44444444-4444-4444-4444-444444444444');
select pg_temp.expect_error(
  'viewer cannot import entitlements',
  $q$select public.import_installation_entitlements('2026-07','f.xlsx',null,
      '[{"subscriber_id":"X","reseller":"R","remaining":13000}]'::jsonb, gen_random_uuid())$q$,
  '42501');

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select pg_temp.expect_error(
  'accountant cannot import entitlements',
  $q$select public.import_installation_entitlements('2026-07','f.xlsx',null,
      '[{"subscriber_id":"X","reseller":"R","remaining":13000}]'::jsonb, gen_random_uuid())$q$,
  '42501');

select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select pg_temp.expect_error(
  'a malformed period is refused',
  $q$select public.import_installation_entitlements('July-2026','f.xlsx',null,
      '[{"subscriber_id":"X","reseller":"R","remaining":13000}]'::jsonb, gen_random_uuid())$q$,
  '22023');

-- ------------------------------------------------------- a mixed-quality file --
select pg_temp.expect(
  'a partially bad file accepts the good rows and reports the rest',
  (with result as (
     select public.import_installation_entitlements('2026-07','mixed.xlsx','sha-mixed', jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-2','reseller','R','remaining',0),
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-4','reseller','','remaining',13000),
       jsonb_build_object('subscriber_id','M-5','reseller','R','remaining',5500)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'source_rows')::int = 6
      and (payload -> 'batch' ->> 'accepted')::int = 2
      and (payload -> 'batch' ->> 'duplicates')::int = 1
      and (payload -> 'batch' ->> 'rejected')::int = 3
   from result));

select pg_temp.expect(
  'the batch row records the same counts and a status',
  (select source_rows = 6 and accepted_rows = 2 and duplicate_rows = 1
      and rejected_rows = 3 and status = 'completed' and file_name = 'mixed.xlsx'
      and file_checksum = 'sha-mixed' and created_by = '11111111-1111-1111-1111-111111111111'
   from public.installation_batches where file_name = 'mixed.xlsx'));

select pg_temp.expect(
  'only the two valid subscribers were written',
  (select count(*) = 2 from public.installation_entitlements where period = '2026-07'));
select pg_temp.expect(
  'the unknown Remaining never reached the table',
  (select count(*) = 0 from public.installation_entitlements where subscriber_id = 'M-5'));
select pg_temp.expect(
  'stage and amount were derived on the server',
  (select stage = 'P1' and amount = 3000 and payment_status = 'awaiting_invoice'
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));
select pg_temp.expect(
  'a DONE row is stored as not eligible with a zero amount',
  (select stage = 'DONE' and amount = 0 and payment_status = 'not_eligible'
   from public.installation_entitlements where subscriber_id = 'M-2'));
select pg_temp.expect(
  'the import wrote an audit record',
  (select count(*) = 1 from public.audit_logs where action = 'installation.batch.imported'));

-- The client cannot smuggle its own figures in.
select pg_temp.expect(
  'a client-supplied stage and amount are ignored',
  (with result as (
     select public.import_installation_entitlements('2026-07','forged.xlsx',null, jsonb_build_array(
       jsonb_build_object('subscriber_id','FORGED','reseller','R','remaining',4000,
                          'stage','P1','amount',999999)
     ), gen_random_uuid()) as payload)
   select true from result))
;
select pg_temp.expect(
  'the forged row was priced from its Remaining, not from the payload',
  (select stage = 'P4' and amount = 4000
   from public.installation_entitlements where subscriber_id = 'FORGED'));

-- --------------------------------------------------------------- idempotency --
select pg_temp.expect(
  'the same file imported twice adds nothing',
  (with result as (
     select public.import_installation_entitlements('2026-07','mixed.xlsx','sha-mixed', jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-2','reseller','R','remaining',0)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 0
      and (payload -> 'batch' ->> 'duplicates')::int = 2
      and (payload -> 'batch' ->> 'status') = 'no_new_rows'
   from result));

select pg_temp.expect(
  'a different file carrying the same entitlement is still a duplicate',
  (with result as (
     select public.import_installation_entitlements('2026-07','other-file.xlsx','sha-other', jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-9','reseller','R','remaining',7000)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 1
      and (payload -> 'batch' ->> 'duplicates')::int = 1
   from result));

select pg_temp.expect(
  'the duplicate subscriber still has exactly one entitlement',
  (select count(*) = 1 from public.installation_entitlements
    where period = '2026-07' and subscriber_id = 'M-1' and stage = 'P1'));

select pg_temp.expect(
  'the same subscriber in another period is a separate entitlement',
  (with result as (
     select public.import_installation_entitlements('2026-08','august.xlsx',null, jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',10000)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 1 from result));

-- ------------------------------------------------------------- atomicity ------
-- A row count beyond the guard aborts the whole call: no batch, no entitlements.
select pg_temp.expect_error(
  'an oversized payload is refused outright',
  $q$select public.import_installation_entitlements('2026-07','huge.xlsx',null,'[]'::jsonb, gen_random_uuid())$q$,
  '22023');
select pg_temp.expect(
  'the refused import left no batch behind',
  (select count(*) = 0 from public.installation_batches where file_name = 'huge.xlsx'));

-- ------------------------------------------------ full pipeline to payment ----
select pg_temp.expect(
  'an imported entitlement is not payable before its invoice is approved',
  (select payment_status = 'awaiting_invoice'
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select pg_temp.expect_error(
  'payment on a freshly imported row is blocked',
  $q$select public.record_installation_payment(
       (select id from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'),
       null, gen_random_uuid())$q$,
  '23514');

select public.audit_installation_invoice(
  (select id from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'),
  'approved', 'checked', gen_random_uuid());
select public.record_installation_payment(
  (select id from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'),
  null, gen_random_uuid());

select pg_temp.expect(
  'the imported entitlement completes the pipeline through to payment',
  (select payment_status = 'paid' and paid_amount = 3000 and paid_at is not null
      and paid_by = '22222222-2222-2222-2222-222222222222'
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));
select pg_temp.expect(
  'payment history exists for the imported entitlement',
  (select count(*) = 1 from public.installation_payments p
     join public.installation_entitlements e on e.id = p.entitlement_id
    where e.subscriber_id = 'M-1' and e.period = '2026-07' and p.amount = 3000));

-- Archive: a later import of the same period cannot restate the settled row.
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select pg_temp.expect(
  're-importing a settled subscriber is reported as a duplicate, not a rewrite',
  (with result as (
     select public.import_installation_entitlements('2026-07','late.xlsx',null, jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','RENAMED','remaining',13000)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'duplicates')::int = 1
      and (payload -> 'batch' ->> 'accepted')::int = 0
   from result));
select pg_temp.expect(
  'the settled row kept its original reseller and payment',
  (select reseller = 'R' and paid_amount = 3000
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));

-- ------------------------------------------------- acceptance fixtures --------
select pg_temp.expect(
  'Saeed Ammar imports as 3943 subscribers',
  (with payload as (
     select public.import_installation_entitlements('2026-09','saeed.xlsx',null,
       pg_temp.rows_at('Saeed Ammar', 0, 2687, 'done')
       || pg_temp.rows_at('Saeed Ammar', 13000, 662, 'p1')
       || pg_temp.rows_at('Saeed Ammar', 10000, 166, 'p2')
       || pg_temp.rows_at('Saeed Ammar', 7000, 175, 'p3')
       || pg_temp.rows_at('Saeed Ammar', 4000, 253, 'p4'),
       gen_random_uuid()) as result)
   select (result -> 'batch' ->> 'accepted')::int = 3943 from payload));

select pg_temp.expect(
  'Saeed Ammar persists as 2687 DONE, 1256 pending and 4,021,000 IQD',
  (select count(*) = 3943
      and count(*) filter (where stage = 'DONE') = 2687
      and count(*) filter (where stage <> 'DONE') = 1256
      and count(*) filter (where stage = 'P1') = 662
      and count(*) filter (where stage = 'P2') = 166
      and count(*) filter (where stage = 'P3') = 175
      and count(*) filter (where stage = 'P4') = 253
      and coalesce(sum(amount), 0) = 4021000
   from public.installation_entitlements
   where period = '2026-09' and reseller = 'Saeed Ammar'));

select pg_temp.expect(
  'Ahmed Abdulabbas imports as 1507 subscribers',
  (with payload as (
     select public.import_installation_entitlements('2026-09','ahmed.xlsx',null,
       pg_temp.rows_at('Ahmed Abdulabbas', 0, 602, 'done')
       || pg_temp.rows_at('Ahmed Abdulabbas', 13000, 114, 'p1')
       || pg_temp.rows_at('Ahmed Abdulabbas', 10000, 177, 'p2')
       || pg_temp.rows_at('Ahmed Abdulabbas', 7000, 197, 'p3')
       || pg_temp.rows_at('Ahmed Abdulabbas', 4000, 417, 'p4'),
       gen_random_uuid()) as result)
   select (result -> 'batch' ->> 'accepted')::int = 1507 from payload));

select pg_temp.expect(
  'Ahmed Abdulabbas persists as 602 DONE, 905 pending and 3,132,000 IQD',
  (select count(*) = 1507
      and count(*) filter (where stage = 'DONE') = 602
      and count(*) filter (where stage <> 'DONE') = 905
      and count(*) filter (where stage = 'P1') = 114
      and count(*) filter (where stage = 'P2') = 177
      and count(*) filter (where stage = 'P3') = 197
      and count(*) filter (where stage = 'P4') = 417
      and coalesce(sum(amount), 0) = 3132000
   from public.installation_entitlements
   where period = '2026-09' and reseller = 'Ahmed Abdulabbas'));

select pg_temp.expect(
  'the two resellers stay separated in the same period',
  (select coalesce(sum(amount), 0) = 4021000 + 3132000
   from public.installation_entitlements where period = '2026-09'));

rollback;
