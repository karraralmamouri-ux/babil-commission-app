#!/usr/bin/env bash
# 30,000 حدث تفعيل — بالدور المُصادَق عليه وبمهلته الحقيقية.
#
# تدقيق QA ما بعد الإطلاق (2026-09-02): Activations Report_Aug-2026.xlsx فيه
# 29,427 حدثاً. المعاينة في المتصفّح كانت تقبلها كلها، ثم «اعتمد الاستيراد»
# يعود بـ «canceling statement due to statement timeout» ولا يترك دفعةً.
#
# ما يُثبته هذا الملف ليس أن الدالة تعمل تحت جلسة postgres بمهلة دقيقتين —
# ذلك لم يكن موضع شكّ أصلاً. المهلة تُفرَض هنا على الدور نفسه:
#
#   alter role authenticated set statement_timeout = '8s'
#
# ثم يُتّصل بالقاعدة بذلك الدور مباشرةً، فتصل كل عبارةٍ إلى الخادم بنفس
# الشرط الذي تصل به من PostgREST حرفياً. ولا تُرفع المهلة ولا تُلمس داخل
# الجلسة: القاعدة المعتمدة هنا أن يُزال العمل المتكرّر لكل صفّ، لا أن
# يُخبَّأ خلف مهلةٍ أطول.
#
# قاعدة محلية للرمي فقط. لا توجد هنا أي بيانات إنتاج ولا أي اعتماد إنتاج.
set -euo pipefail

PSQL="docker exec -i babil-local-pg psql -U postgres -d babil_local -tAq"
AUTH="docker exec -i babil-local-pg psql -U authenticated -d babil_local"
ADMIN='5d000000-0000-0000-0000-0000000000a1'
CHECKSUM='sl-large-30k'
ROWS=30000
CHUNK=5000
BUDGET_MS=8000

cleanup() {
  $PSQL >/dev/null <<SQL
-- التاريخ الخام مُلحَقٌ فقط بحكم trg_protect_activation_events. تنظيف
-- تجهيزةٍ محليةٍ يتطلّب تعطيله لحظةً — وهذا لا يمكن إلا بـpostgres على
-- قاعدةٍ للرمي، ولا يمسّ الإنتاج بشيء.
alter table public.saas_activation_events disable trigger trg_protect_activation_events;
delete from public.saas_activation_events e
 using public.saas_import_batches b
 where b.id = e.import_batch_id and b.source_checksum = '$CHECKSUM';
alter table public.saas_activation_events enable trigger trg_protect_activation_events;
delete from public.audit_logs where actor_id = '$ADMIN';
delete from public.saas_import_batches where source_checksum = '$CHECKSUM';
drop table if exists public.sl_perf_chunks;
alter role authenticated reset statement_timeout;
alter role authenticated with nologin;
SQL
}
trap cleanup EXIT
cleanup

$PSQL >/dev/null <<SQL
insert into auth.users (id, email) values ('$ADMIN', 'sl-admin@fixture.invalid')
  on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
  values ('$ADMIN', 'SL Admin', 'sl-admin@fixture.invalid', 'admin', true)
  on conflict (id) do update set role = 'admin', is_active = true;

-- صفوفٌ مكتملة الحقول: كل عمودٍ يُحوَّل في الاستيراد مملوءٌ فعلاً، فالقياس
-- لا يُجمّل نفسه بصفوفٍ نصفِ فارغة.
create table public.sl_perf_chunks as
select ((i - 1) / $CHUNK) as chunk_no, jsonb_agg(jsonb_build_object(
  'saas_event_id', 'SL-EV-' || i, 'username', 'sl-user-' || i,
  'transaction_id', 'TX-' || i, 'saas_user_id', 'SU-' || i,
  'event_created_at', (timestamptz '2026-08-01 00:00:00+03' + (i || ' seconds')::interval)::text,
  'profile_name', 'P-35000',
  'old_expiration', '2026-07-01 00:00:00+03', 'new_expiration', '2026-09-01 00:00:00+03',
  'activations_count', 1, 'raw_parent', 'sl.parent', 'canceled', false,
  'price', 35000, 'user_price', 35000, 'total_price', 41125,
  'tax_amount', 6125, 'tax_rate', 0.175,
  'contract_id', 'C-' || i, 'card', 'CARD-' || i, 'card_owner', 'Owner ' || i,
  'comment', 'note ' || i, 'group_name', 'G1', 'national_id', 'NID-' || i,
  'topology_raw', 'FDT105/FAT7/P3', 'fdt_code', '105', 'fat_code', '7',
  'port_code', '3', 'source_sheet', 'Sheet1', 'source_row', i
) order by i) as rows
from generate_series(1, $ROWS) i group by ((i - 1) / $CHUNK);
grant select on public.sl_perf_chunks to authenticated;

-- المهلة على الدور نفسه، كما هي في الإنتاج — لا على العبارة ولا على الجلسة.
alter role authenticated with login;
alter role authenticated set statement_timeout = '${BUDGET_MS}ms';
SQL

# جلسةٌ واحدةٌ بالدور المُصادَق عليه، وكل جزءٍ عبارةٌ مستقلّةٌ تُثبَّت وحدها —
# فسقوط جزءٍ لا يُلغي ما قبله، وهذا شرط الاستئناف أصلاً.
script=$(mktemp)
{
  echo '\timing on'
  echo '\pset tuples_only on'
  echo "select set_config('request.jwt.claim.sub', '$ADMIN', false);"
  last=$(( ROWS / CHUNK - 1 ))
  for n in $(seq 0 "$last"); do
    if [ "$n" = "$last" ]; then fin=true; else fin=false; fi
    off=$(( n * CHUNK ))
    echo "select 'CHUNK$n=' || (public.import_saas_activation_events("
    echo "  'Activations Report_Aug-2026.xlsx', '$CHECKSUM', 'saas-import.js',"
    echo "  (select rows from public.sl_perf_chunks where chunk_no = $n),"
    echo "  gen_random_uuid(), null, null, null, $ROWS, $fin, $off"
    echo ") #>> '{batch,batch_totals,source_rows}');"
  done
} > "$script"

out=$($AUTH < "$script" 2>&1)
rm -f "$script"

if echo "$out" | grep -qiE "statement timeout|ERROR"; then
  echo "$out" | grep -iE "statement timeout|ERROR" || true
  echo "FAIL: the authenticated 8s statement timeout was hit" >&2
  exit 1
fi

# زمن كل جزءٍ كما قاسه psql للعبارة نفسها — أوّل توقيتٍ للتهيئة لا لجزء.
times=$(echo "$out" | grep "^Time:" | tail -n +2 | sed -E 's/^Time: ([0-9.]+) ms.*/\1/' || true)
worst=0
total=0
i=0
for t in $times; do
  ms=${t%.*}
  printf "  chunk %d  %8s ms\n" "$i" "$ms"
  if [ "$ms" -gt "$worst" ]; then worst=$ms; fi
  total=$(( total + ms ))
  i=$(( i + 1 ))
done

batches=$($PSQL -c "select count(*) from public.saas_import_batches where source_checksum='$CHECKSUM'")
status=$($PSQL -c "select status from public.saas_import_batches where source_checksum='$CHECKSUM'")
src=$($PSQL -c "select source_row_count from public.saas_import_batches where source_checksum='$CHECKSUM'")
acc=$($PSQL -c "select imported_row_count from public.saas_import_batches where source_checksum='$CHECKSUM'")
events=$($PSQL -c "select count(*) from public.saas_activation_events e join public.saas_import_batches b on b.id=e.import_batch_id where b.source_checksum='$CHECKSUM'")
finals=$($PSQL -c "select count(*) from public.audit_logs a join public.saas_import_batches b on b.id=a.entity_id where b.source_checksum='$CHECKSUM' and a.action='saas.activation_events.imported'")

echo "rows in the file            : $ROWS"
echo "chunks                      : $i of $CHUNK"
echo "slowest chunk               : $worst ms  (budget $BUDGET_MS ms)"
echo "all chunks together         : $total ms"
echo "logical batches for the file: $batches"
echo "batch status                : $status"
echo "source / accepted           : $src / $acc"
echo "activation events stored    : $events"
echo "final import audit rows     : $finals"

fail=0
[ "$i" = "6" ]             || { echo "FAIL: expected six chunks"; fail=1; }
[ "$worst" -lt "$BUDGET_MS" ] || { echo "FAIL: a chunk did not fit the authenticated statement budget"; fail=1; }
[ "$batches" = "1" ]       || { echo "FAIL: one source file must remain one logical batch"; fail=1; }
[ "$status" = "imported" ] || { echo "FAIL: the batch must be finalized exactly once, at the end"; fail=1; }
[ "$src" = "$ROWS" ]       || { echo "FAIL: source_row_count must equal the file's row count"; fail=1; }
[ "$acc" = "$ROWS" ]       || { echo "FAIL: every unique event must have been accepted"; fail=1; }
[ "$events" = "$ROWS" ]    || { echo "FAIL: every row must be stored exactly once"; fail=1; }
[ "$finals" = "1" ]        || { echo "FAIL: exactly one final import audit row per logical file"; fail=1; }

if [ "$fail" = "0" ]; then
  echo "pass  30,000 activation events imported under the authenticated 8s timeout"
fi
exit $fail
