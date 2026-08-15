#!/usr/bin/env bash
# Two accountants press "pay" on the same instalment at the same moment.
# Exactly one payment may land. Throwaway local database only.
set -euo pipefail

PSQL="docker exec -i babil-local-pg psql -U postgres -d babil_local -tAq"
ACCOUNTANT='22222222-2222-2222-2222-222222222222'
ENT='cccccccc-0000-0000-0000-000000000001'

$PSQL >/dev/null <<SQL
insert into auth.users (id, email) values ('$ACCOUNTANT','accountant@fixture.invalid')
  on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
  values ('$ACCOUNTANT','Accountant','accountant@fixture.invalid','accountant',true)
  on conflict (id) do nothing;
delete from public.installation_payments where entitlement_id = '$ENT';
delete from public.audit_logs where entity_id = '$ENT';
delete from public.installation_entitlements where id = '$ENT';
insert into public.installation_entitlements
  (id, period, subscriber_id, reseller, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('$ENT','2026-07','SUB-RACE','Fixture Reseller',13000,'P1',3000,
        'approved','eligible','$ACCOUNTANT');
SQL

attempt() {
  $PSQL <<SQL 2>&1 || true
begin;
select set_config('request.jwt.claim.sub','$ACCOUNTANT',true);
select pg_sleep($1);
select public.record_installation_payment('$ENT', null, gen_random_uuid());
commit;
SQL
}

# Both sessions enter the function at essentially the same instant.
attempt 0.15 > /tmp/race_a.out &
A=$!
attempt 0.15 > /tmp/race_b.out &
B=$!
wait $A $B

ok=0
for f in /tmp/race_a.out /tmp/race_b.out; do
  if grep -q '"replayed": false' "$f" || grep -q 'paid_amount' "$f"; then ok=$((ok+1)); fi
done

ledger=$($PSQL -c "select count(*) from public.installation_payments where entitlement_id='$ENT'")
paid=$($PSQL -c "select paid_amount from public.installation_entitlements where id='$ENT'")
audits=$($PSQL -c "select count(*) from public.audit_logs where entity_id='$ENT' and action='installation.payment.recorded'")

echo "sessions reporting success : $ok"
echo "ledger rows                : $ledger"
echo "paid_amount                : $paid"
echo "payment audit rows         : $audits"

fail=0
[ "$ok" = "1" ]     || { echo "FAIL: expected exactly one session to succeed"; fail=1; }
[ "$ledger" = "1" ] || { echo "FAIL: expected exactly one ledger row"; fail=1; }
[ "$paid" = "3000" ]|| { echo "FAIL: expected paid_amount 3000"; fail=1; }
[ "$audits" = "1" ] || { echo "FAIL: expected exactly one payment audit row"; fail=1; }

$PSQL >/dev/null <<SQL
delete from public.installation_payments where entitlement_id = '$ENT';
delete from public.audit_logs where entity_id = '$ENT';
delete from public.installation_entitlements where id = '$ENT';
SQL

[ "$fail" = "0" ] && echo "pass  concurrent payment attempts produce exactly one payment"
exit $fail
