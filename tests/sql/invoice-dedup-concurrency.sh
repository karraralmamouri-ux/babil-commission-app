#!/usr/bin/env bash
# IMP-001 (B): two accountants verify the SAME invoice number for two
# DIFFERENT subscribers at essentially the same instant. A read-then-write
# app check alone cannot stop this — both sessions can read "not used yet"
# before either commits. The partial unique index on
# (invoice_source, invoice_number) where status='VERIFIED' is the actual
# guard: exactly one session's insert may land, the other must fail at the
# database, not merely be discouraged by application logic.
# Throwaway local database only.
set -euo pipefail

PSQL="docker exec -i babil-local-pg psql -U postgres -d babil_local -tAq"
ACTOR='33333333-3333-3333-3333-333333333333'
SUB_X='imp-race-x'
SUB_Y='imp-race-y'
INV='IMP-RACE-1'

$PSQL >/dev/null <<SQL
insert into auth.users (id, email) values ('$ACTOR','imp-race@fixture.invalid')
  on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
  values ('$ACTOR','IMP-Race','imp-race@fixture.invalid','admin',true)
  on conflict (id) do update set role='admin', is_active=true;

delete from public.installation_invoices where subscriber_id in ('$SUB_X','$SUB_Y');
delete from public.audit_logs where extra like '%$SUB_X%' or extra like '%$SUB_Y%';
delete from public.installation_subscriber_state where subscriber_uuid in (
  select id from public.installation_subscribers where subscriber_id in ('$SUB_X','$SUB_Y'));
delete from public.installation_subscribers where subscriber_id in ('$SUB_X','$SUB_Y');

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('dd000000-0000-0000-0000-0000000000e1','$SUB_X','Fixture Reseller','IMP-FDT',date '2026-01-01',13000,'$ACTOR'),
  ('dd000000-0000-0000-0000-0000000000e2','$SUB_Y','Fixture Reseller','IMP-FDT',date '2026-01-01',13000,'$ACTOR');
insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('dd000000-0000-0000-0000-0000000000e1', date '2026-08-31', 13000, 'P1', 'resolved', true),
  ('dd000000-0000-0000-0000-0000000000e2', date '2026-08-31', 13000, 'P1', 'resolved', true);
SQL

attempt() {
  $PSQL <<SQL 2>&1 || true
begin;
select set_config('request.jwt.claim.sub','$ACTOR',true);
select pg_sleep($2);
select public.review_invoice('$1', 'P1', 'VERIFIED', 'سباق فاتورة', '$INV', gen_random_uuid());
commit;
SQL
}

# Both sessions attempt to verify the SAME invoice number, for two
# different subscribers, at essentially the same instant.
attempt "$SUB_X" 0.15 > /tmp/imp_race_x.out &
X=$!
attempt "$SUB_Y" 0.15 > /tmp/imp_race_y.out &
Y=$!
wait $X $Y

ok=0
for f in /tmp/imp_race_x.out /tmp/imp_race_y.out; do
  if grep -q '"status_after": "VERIFIED"' "$f"; then ok=$((ok+1)); fi
done

verified=$($PSQL -c "select count(*) from public.installation_invoices where invoice_number='$INV' and status='VERIFIED'")
holders=$($PSQL -c "select count(distinct subscriber_id) from public.installation_invoices where invoice_number='$INV' and status='VERIFIED'")

echo "sessions reporting VERIFIED : $ok"
echo "VERIFIED rows for $INV      : $verified"
echo "distinct subscribers holding it : $holders"

fail=0
[ "$ok" = "1" ]       || { echo "FAIL: expected exactly one session to verify successfully"; fail=1; }
[ "$verified" = "1" ] || { echo "FAIL: expected exactly one VERIFIED row for $INV"; fail=1; }
[ "$holders" = "1" ]  || { echo "FAIL: expected exactly one subscriber to hold $INV"; fail=1; }

$PSQL >/dev/null <<SQL
delete from public.installation_invoices where subscriber_id in ('$SUB_X','$SUB_Y');
delete from public.audit_logs where extra like '%$SUB_X%' or extra like '%$SUB_Y%';
delete from public.installation_subscriber_state where subscriber_uuid in (
  select id from public.installation_subscribers where subscriber_id in ('$SUB_X','$SUB_Y'));
delete from public.installation_subscribers where subscriber_id in ('$SUB_X','$SUB_Y');
SQL

[ "$fail" = "0" ] && echo "pass  concurrent verification of the same invoice number lands exactly once"
exit $fail
