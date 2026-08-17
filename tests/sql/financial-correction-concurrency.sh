#!/usr/bin/env bash
# Two sessions try to reverse the same payment at the same instant.
#
# A single-session suite cannot prove this: the unique index and the advisory
# lock only matter when two transactions overlap. Exactly one must win and the
# money must move exactly once.
set -euo pipefail

DB="docker exec -i babil-local-pg psql -U postgres -d babil_local -tA"

$DB <<'SQL' >/dev/null
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','admin@fixture.invalid') on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('11111111-1111-1111-1111-111111111111','Admin','admin@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

-- The ledger refuses deletion by design, so a throwaway test database can only
-- reset it by stepping outside the application entirely. session_replication_role
-- is a superuser setting; it is available here and nowhere in the product.
set session_replication_role = replica;
delete from public.financial_ledger;
delete from public.installation_payments;
delete from public.installation_entitlements where subscriber_id = 'SUB-CONCURRENT';
delete from public.installation_batches where id = 'cccc0000-0000-0000-0000-0000000000c1';
reset session_replication_role;

insert into public.installation_batches (id, period, file_name, created_by)
values ('cccc0000-0000-0000-0000-0000000000c1','2026-08','concurrency.xlsx',
        '11111111-1111-1111-1111-111111111111');

insert into public.installation_entitlements (
  id, batch_id, period, subscriber_id, subscriber_name, reseller, zone, fdt,
  remaining, stage, amount, invoice_status, payment_status, paid_amount, created_by)
values ('dddd0000-0000-0000-0000-0000000000c1','cccc0000-0000-0000-0000-0000000000c1',
  '2026-08','SUB-CONCURRENT','Subscriber','Saeed Ammar','new','108',
  4000,'P4',4000,'approved','eligible',0,'11111111-1111-1111-1111-111111111111');

select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111', false);
select public.record_installation_payment(
  'dddd0000-0000-0000-0000-0000000000c1'::uuid,
  (select updated_at from public.installation_entitlements
   where id='dddd0000-0000-0000-0000-0000000000c1'),
  '00000000-0000-0000-0000-0000000000c9'::uuid);
SQL

attempt() {
  docker exec -i babil-local-pg psql -U postgres -d babil_local -tA <<SQL 2>&1 || true
begin;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111', true);
select pg_sleep($1);
select public.reverse_financial_entry(
  'installation', 'dddd0000-0000-0000-0000-0000000000c1'::uuid,
  'concurrent attempt', '$2'::uuid);
commit;
SQL
}

# Overlapping windows: both are inside the function at the same moment.
attempt 0.4 00000000-0000-0000-0000-0000000000d1 > /tmp/rev_a.txt &
A=$!
attempt 0.4 00000000-0000-0000-0000-0000000000d2 > /tmp/rev_b.txt &
B=$!
wait $A $B

ok=0
for f in /tmp/rev_a.txt /tmp/rev_b.txt; do
  grep -q "reversal_id" "$f" && ok=$((ok+1))
done

read -r reversals net payments <<<"$($DB -c "
select (select count(*) from public.financial_ledger where txn_type='REVERSAL'),
       (select coalesce(sum(amount*direction),0) from public.financial_ledger
        where source_id='dddd0000-0000-0000-0000-0000000000c1'),
       (select count(*) from public.installation_payments);" | tr '|' ' ')"

echo "sessions reporting success : $ok"
echo "reversal entries           : $reversals"
echo "net after both attempts    : $net"
echo "installation payment rows  : $payments"

fail=0
[ "$ok" = "1" ]        || { echo "FAIL: expected exactly one session to succeed"; fail=1; }
[ "$reversals" = "1" ] || { echo "FAIL: expected exactly one reversal entry"; fail=1; }
[ "$net" = "0" ]       || { echo "FAIL: expected the net to be zero, got $net"; fail=1; }
[ "$payments" = "1" ]  || { echo "FAIL: the original payment must survive untouched"; fail=1; }

$DB <<'SQL' >/dev/null
-- The ledger refuses deletion by design, so a throwaway test database can only
-- reset it by stepping outside the application entirely. session_replication_role
-- is a superuser setting; it is available here and nowhere in the product.
set session_replication_role = replica;
delete from public.financial_ledger;
delete from public.installation_payments;
delete from public.installation_entitlements where subscriber_id = 'SUB-CONCURRENT';
delete from public.installation_batches where id = 'cccc0000-0000-0000-0000-0000000000c1';
delete from public.audit_logs where action in ('financial.reversed','installation.payment.recorded');
reset session_replication_role;
SQL

[ "$fail" = "0" ] || exit 1
echo "pass  concurrent reversal attempts produce exactly one reversal"
