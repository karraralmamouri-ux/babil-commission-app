#!/usr/bin/env bash
# Two accountants pay the SAME subscriber's SAME stage at the same moment —
# through two DIFFERENT entitlements in two different periods.
#
# installation_payments.unique(entitlement_id) does not protect this: the two
# rows have different entitlement ids. installation_entitlements identity is
# (period, subscriber, stage), so P1 legitimately exists in July and in August
# until one of them is paid. Without a subscriber-level guard both commit and
# the subscriber is paid P1 twice. Exactly one payment may land.
#
# Throwaway local database only. No production credentials exist here.
set -euo pipefail

PSQL="docker exec -i babil-local-pg psql -U postgres -d babil_local -tAq"
ACCOUNTANT='22222222-2222-2222-2222-222222222222'
SUB='cccccccc-0000-0000-0000-0000000000d0'
E1='cccccccc-0000-0000-0000-0000000000d1'
E2='cccccccc-0000-0000-0000-0000000000d2'

cleanup() {
  $PSQL >/dev/null <<SQL
delete from public.installation_payments where entitlement_id in ('$E1','$E2');
delete from public.audit_logs where entity_id in ('$E1','$E2','$SUB');
delete from public.installation_payment_history where subscriber_uuid = '$SUB';
delete from public.installation_entitlements where id in ('$E1','$E2');
delete from public.installation_subscriber_state where subscriber_uuid = '$SUB';
delete from public.installation_subscribers where id = '$SUB';
SQL
}

cleanup

$PSQL >/dev/null <<SQL
insert into auth.users (id, email) values ('$ACCOUNTANT','accountant@fixture.invalid')
  on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
  values ('$ACCOUNTANT','Accountant','accountant@fixture.invalid','accountant',true)
  on conflict (id) do nothing;

-- مشترك رسميّ بحالة رسمية: هذا ما يحميه الحارس. (المشترك بلا سجلّ لا هوية له.)
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values ('$SUB','SUB-XRACE','Fixture Reseller','105', current_date, 13000, '$ACCOUNTANT');
insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible, updated_by)
values ('$SUB', current_date, 13000, 0, 13000, 'P1', 'resolved', true, '$ACCOUNTANT');

-- نفس المشترك، نفس المرحلة، شهران مختلفان — استحقاقان صالحان بمفتاحهما.
insert into public.installation_entitlements
  (id, period, subscriber_id, reseller, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('$E1','2026-07','SUB-XRACE','Fixture Reseller',13000,'P1',3000,
        'approved','eligible','$ACCOUNTANT'),
       ('$E2','2026-08','SUB-XRACE','Fixture Reseller',13000,'P1',3000,
        'approved','eligible','$ACCOUNTANT');
SQL

attempt() {
  $PSQL <<SQL 2>&1 || true
begin;
select set_config('request.jwt.claim.sub','$ACCOUNTANT',true);
select pg_sleep(0.15);
select public.record_installation_payment('$1', null, gen_random_uuid());
commit;
SQL
}

attempt "$E1" > /tmp/xrace_a.out &
A=$!
attempt "$E2" > /tmp/xrace_b.out &
B=$!
wait $A $B

ok=0
for f in /tmp/xrace_a.out /tmp/xrace_b.out; do
  if grep -q 'paid_amount' "$f"; then ok=$((ok+1)); fi
done
refused=$(cat /tmp/xrace_a.out /tmp/xrace_b.out | grep -c 'STAGE_ALREADY_PAID' || true)

payments=$($PSQL -c "select count(*) from public.installation_payments where entitlement_id in ('$E1','$E2')")
paid_rows=$($PSQL -c "select count(*) from public.installation_entitlements where id in ('$E1','$E2') and payment_status='paid'")
ledger=$($PSQL -c "select count(*) from public.financial_ledger where source_id in ('$E1','$E2') and txn_type='PAYMENT'")
history=$($PSQL -c "select count(*) from public.installation_payment_history where subscriber_uuid='$SUB'")
audits=$($PSQL -c "select count(*) from public.audit_logs where entity_id in ('$E1','$E2') and action='installation.payment.recorded'")
stage=$($PSQL -c "select current_stage || '/' || remaining from public.installation_subscriber_state where subscriber_uuid='$SUB'")

echo "sessions reporting success  : $ok"
echo "sessions refused by guard   : $refused"
echo "installation_payments rows  : $payments"
echo "entitlements marked paid    : $paid_rows"
echo "financial_ledger PAYMENT    : $ledger"
echo "payment history rows        : $history"
echo "payment audit rows          : $audits"
echo "subscriber state            : $stage"

fail=0
[ "$ok" = "1" ]        || { echo "FAIL: expected exactly one session to succeed"; fail=1; }
[ "$refused" -ge 1 ]   || { echo "FAIL: expected the loser to be refused by STAGE_ALREADY_PAID"; fail=1; }
[ "$payments" = "1" ]  || { echo "FAIL: expected exactly one installation_payments row"; fail=1; }
[ "$paid_rows" = "1" ] || { echo "FAIL: expected exactly one entitlement marked paid"; fail=1; }
[ "$ledger" = "1" ]    || { echo "FAIL: expected exactly one PAYMENT ledger entry"; fail=1; }
[ "$history" = "1" ]   || { echo "FAIL: expected exactly one stage payment history row"; fail=1; }
[ "$audits" = "1" ]    || { echo "FAIL: expected exactly one payment audit row"; fail=1; }
[ "$stage" = "P2/10000" ] || { echo "FAIL: expected the subscriber to advance exactly one stage"; fail=1; }

cleanup

[ "$fail" = "0" ] && echo "pass  same subscriber + same stage in two periods pays exactly once"
exit $fail
