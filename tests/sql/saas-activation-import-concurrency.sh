#!/usr/bin/env bash
# جزءان من نفس الملف يصلان في اللحظة نفسها.
#
# التجزئة تُدخل احتمالاً لم يكن قائماً قبلها: نداءان متزامنان على نفس الدفعة
# المنطقية. والخطر المالي فيه ليس البطء بل الازدواج — حدث تفعيلٍ واحدٌ
# يُخزَّن مرّتين، أو موضعٌ واحدٌ من الملف يُعدّ مرّتين فيتضخّم source_rows حتى
# يستحيل إنهاء الدفعة أبداً.
#
# ثلاثة أشياء تحرسه، وهذا الملف يُشغّلها كلها فعلياً لا يفترضها:
#   · قفل استشاريّ واحد لكل استيراد أحداث تفعيل — فالنداءان يتسلسلان.
#   · received_rows اتحاد مجالات — فالموضع المُستقبَل لا يُعدّ ثانيةً.
#   · saas_activation_events_identity_key فريدٌ على معرّف الحدث — فالحدث
#     الواحد لا يُخزَّن مرّتين مهما تسابق عليه نداءان.
#
# قاعدة محلية للرمي فقط. لا توجد هنا أي بيانات إنتاج ولا أي اعتماد إنتاج.
set -euo pipefail

PSQL="docker exec -i babil-local-pg psql -U postgres -d babil_local -tAq"
ADMIN='5e000000-0000-0000-0000-0000000000a1'
CHECKSUM='sr-race-1'

cleanup() {
  $PSQL >/dev/null <<SQL
alter table public.saas_activation_events disable trigger trg_protect_activation_events;
delete from public.saas_activation_events e
 using public.saas_import_batches b
 where b.id = e.import_batch_id and b.source_checksum = '$CHECKSUM';
alter table public.saas_activation_events enable trigger trg_protect_activation_events;
delete from public.audit_logs where actor_id = '$ADMIN';
delete from public.saas_import_batches where source_checksum = '$CHECKSUM';
SQL
}
trap cleanup EXIT
cleanup

$PSQL >/dev/null <<SQL
insert into auth.users (id, email) values ('$ADMIN', 'sr-admin@fixture.invalid')
  on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
  values ('$ADMIN', 'SR Admin', 'sr-admin@fixture.invalid', 'admin', true)
  on conflict (id) do update set role = 'admin', is_active = true;
SQL

# جزءٌ من مئة صفّ بمواضع [from, from+100) من ملفٍ مُعلَنٍ بثلاثمئة صفّ.
submit() {
  local first="$1" offset="$2" finalize="$3"
  $PSQL <<SQL 2>&1 || true
select set_config('request.jwt.claim.sub', '$ADMIN', false);
select pg_sleep(0.2);
select 'submitted=' || (public.import_saas_activation_events(
  'race.xlsx', '$CHECKSUM', 'saas-import.js',
  (select jsonb_agg(jsonb_build_object(
     'saas_event_id', 'SR-EV-' || i, 'username', 'sr-user-' || i,
     'event_created_at', (timestamptz '2026-08-01 00:00:00+03' + (i || ' seconds')::interval)::text
   ) order by i) from generate_series($first, $first + 99) i),
  gen_random_uuid(), null, null, null, 300, $finalize, $offset
) #>> '{batch,source_rows}');
SQL
}

echo "— نداءان متطابقان تماماً على نفس الموضع، في اللحظة نفسها —"
submit 1 0 false > /tmp/sr_a.out &
A=$!
submit 1 0 false > /tmp/sr_b.out &
B=$!
wait $A $B

got=$(cat /tmp/sr_a.out /tmp/sr_b.out | grep -c 'submitted=100' || true)
none=$(cat /tmp/sr_a.out /tmp/sr_b.out | grep -c 'submitted=0' || true)
src1=$($PSQL -c "select source_row_count from public.saas_import_batches where source_checksum='$CHECKSUM'")
batches1=$($PSQL -c "select count(*) from public.saas_import_batches where source_checksum='$CHECKSUM'")
events1=$($PSQL -c "select count(*) from public.saas_activation_events where saas_event_id like 'SR-EV-%'")

echo "  sessions that carried the range : $got"
echo "  sessions that carried nothing   : $none"
echo "  logical batches                 : $batches1"
echo "  source_row_count                : $src1"
echo "  activation events stored        : $events1"

echo "— جزءان مختلفان في اللحظة نفسها، ثم الإنهاء —"
submit 101 100 false > /tmp/sr_c.out &
C=$!
submit 201 200 false > /tmp/sr_d.out &
D=$!
wait $C $D

src2=$($PSQL -c "select source_row_count from public.saas_import_batches where source_checksum='$CHECKSUM'")
events2=$($PSQL -c "select count(*) from public.saas_activation_events where saas_event_id like 'SR-EV-%'")
dups=$($PSQL -c "select count(*) from (select saas_event_id from public.saas_activation_events where saas_event_id like 'SR-EV-%' group by saas_event_id having count(*) > 1) d")
batches2=$($PSQL -c "select count(*) from public.saas_import_batches where source_checksum='$CHECKSUM'")
status=$($PSQL -c "select status from public.saas_import_batches where source_checksum='$CHECKSUM'")

echo "  source_row_count                : $src2"
echo "  activation events stored        : $events2"
echo "  event ids stored more than once : $dups"
echo "  logical batches                 : $batches2"
echo "  batch status before finalizing  : $status"

fail=0
[ "$got" = "1" ]      || { echo "FAIL: exactly one session may carry a contested range"; fail=1; }
[ "$none" = "1" ]     || { echo "FAIL: the losing session must carry nothing, not fail"; fail=1; }
[ "$batches1" = "1" ] || { echo "FAIL: two concurrent chunks must not create two logical batches"; fail=1; }
[ "$src1" = "100" ]   || { echo "FAIL: a re-sent position must not be counted twice"; fail=1; }
[ "$events1" = "100" ] || { echo "FAIL: an event id must be stored exactly once"; fail=1; }
[ "$src2" = "300" ]   || { echo "FAIL: two distinct concurrent chunks must both land"; fail=1; }
[ "$events2" = "300" ] || { echo "FAIL: every distinct event must be stored exactly once"; fail=1; }
[ "$dups" = "0" ]     || { echo "FAIL: no event id may be stored twice"; fail=1; }
[ "$batches2" = "1" ] || { echo "FAIL: one source file must remain one logical batch"; fail=1; }
[ "$status" = "draft" ] || { echo "FAIL: a batch must stay open until it is finalized explicitly"; fail=1; }

if [ "$fail" = "0" ]; then
  echo "pass  concurrent chunks of one file stay one batch, counted once, stored once"
fi
exit $fail
