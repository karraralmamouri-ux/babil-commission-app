#!/usr/bin/env bash
# Rebuilds the throwaway database and runs every local database rule test.
set -euo pipefail

if ! docker exec babil-local-pg psql -U postgres -d babil_local -tAc "select 1" >/dev/null 2>&1; then
  echo "local postgres is not running. Run: npm run localdb:up" >&2
  exit 1
fi

bash tests/sql/rebuild-local.sh >/dev/null
echo "== installation fee rules =="
out=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/installation-fees-rules.sql 2>&1) || true
echo "$out" | grep -E "pass |FAIL|ERROR" || true
if echo "$out" | grep -qE "FAIL|ERROR"; then echo "RULE TESTS FAILED" >&2; exit 1; fi
passed=$(echo "$out" | grep -c "pass  ")

echo "== end-to-end import =="
out2=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q         < tests/sql/installation-fees-import.sql 2>&1) || true
echo "$out2" | grep -E "pass |FAIL|ERROR" || true
if echo "$out2" | grep -qE "FAIL|ERROR"; then echo "IMPORT TESTS FAILED" >&2; exit 1; fi
passed=$((passed + $(echo "$out2" | grep -c "pass  ")))

# The historical suite reports through a results table rather than notices, so
# it is counted from that table instead of by grepping for "pass  ".
echo "== initial historical import =="
out3=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/installation-history-rules.sql 2>&1) || true
if echo "$out3" | grep -qE "FAILED:|ERROR"; then
  echo "$out3" | grep -E "FAILED:|ERROR" || true
  echo "HISTORICAL IMPORT TESTS FAILED" >&2; exit 1
fi
echo "$out3" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out3" | grep -c "| pass")))

echo "== payment eligibility guards =="
out4=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/installation-history-eligibility.sql 2>&1) || true
if echo "$out4" | grep -qE "FAILED:|ERROR"; then
  echo "$out4" | grep -E "FAILED:|ERROR" || true
  echo "ELIGIBILITY TESTS FAILED" >&2; exit 1
fi
echo "$out4" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out4" | grep -c "| pass")))

echo "== financial write boundary =="
out5=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/financial-write-boundary.sql 2>&1) || true
if echo "$out5" | grep -qE "FAILED:|ERROR"; then
  echo "$out5" | grep -E "FAILED:|ERROR" || true
  echo "WRITE BOUNDARY TESTS FAILED" >&2; exit 1
fi
echo "$out5" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out5" | grep -c "| pass")))

echo "== financial correction =="
out6=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q         < tests/sql/financial-correction.sql 2>&1) || true
if echo "$out6" | grep -qE "FAILED:|ERROR"; then
  echo "$out6" | grep -E "FAILED:|ERROR" || true
  echo "FINANCIAL CORRECTION TESTS FAILED" >&2; exit 1
fi
echo "$out6" | grep -E "| (pass|FAIL)" || true
passed=$((passed + $(echo "$out6" | grep -c "| pass")))

echo "== ledger integration =="
out7=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q         < tests/sql/financial-ledger-integration.sql 2>&1) || true
if echo "$out7" | grep -qE "FAILED:|ERROR"; then
  echo "$out7" | grep -E "FAILED:|ERROR" || true
  echo "LEDGER INTEGRATION TESTS FAILED" >&2; exit 1
fi
echo "$out7" | grep -E "| (pass|FAIL)" || true
passed=$((passed + $(echo "$out7" | grep -c "| pass")))

echo "== data intelligence foundation =="
out8=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/data-intelligence.sql 2>&1) || true
if echo "$out8" | grep -qE "FAIL|ERROR"; then
  echo "$out8" | grep -E "FAIL|ERROR" || true
  echo "DATA INTELLIGENCE TESTS FAILED" >&2; exit 1
fi
echo "$out8" | grep -E "^ ok " || true
passed=$((passed + $(echo "$out8" | grep -c "^ ok ")))

echo "== financial operations engine =="
out9=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/financial-operations.sql 2>&1) || true
if echo "$out9" | grep -qE "FAILED|ERROR"; then
  echo "$out9" | grep -E "FAILED|ERROR" || true
  echo "FINANCIAL OPERATIONS TESTS FAILED" >&2; exit 1
fi
echo "$out9" | grep -E "^  (ok|==) " || true
passed=$((passed + $(echo "$out9" | grep -c "  ok   ")))

echo "== commission engine vNext =="
out10=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/commission-vnext.sql 2>&1) || true
if echo "$out10" | grep -qE "FAILED|ERROR"; then
  echo "$out10" | grep -E "FAILED|ERROR" || true
  echo "COMMISSION VNEXT TESTS FAILED" >&2; exit 1
fi
echo "$out10" | grep -E "^   (ok|==) " || true
passed=$((passed + $(echo "$out10" | grep -c "ok   ")))

echo "== commission payout and reporting =="
out11=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/commission-payout.sql 2>&1) || true
if echo "$out11" | grep -qE "FAILED|ERROR"; then
  echo "$out11" | grep -E "FAILED|ERROR" || true
  echo "COMMISSION PAYOUT TESTS FAILED" >&2; exit 1
fi
echo "$out11" | grep -E "^ {3,5}(ok|==) " || true
passed=$((passed + $(echo "$out11" | grep -c "    ok ")))

echo "== odoo integration readiness =="
out12=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/odoo-integration.sql 2>&1) || true
if echo "$out12" | grep -qE "FAILED|ERROR"; then
  echo "$out12" | grep -E "FAILED|ERROR" || true
  echo "ODOO INTEGRATION TESTS FAILED" >&2; exit 1
fi
echo "$out12" | grep -E "^ {4,6}(ok|==) " || true
passed=$((passed + $(echo "$out12" | grep -c "     ok ")))

echo "== identity bootstrap =="
out13=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/identity-bootstrap.sql 2>&1) || true
if echo "$out13" | grep -qE "FAILED|ERROR"; then
  echo "$out13" | grep -E "FAILED|ERROR" || true
  echo "IDENTITY BOOTSTRAP TESTS FAILED" >&2; exit 1
fi
echo "$out13" | grep -E "^ {5,7}(ok|==) " || true
passed=$((passed + $(echo "$out13" | grep -c "      ok ")))

echo "== fdt onboarding =="
out14=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/fdt-onboarding.sql 2>&1) || true
if echo "$out14" | grep -qE "FAILED|ERROR"; then
  echo "$out14" | grep -E "FAILED|ERROR" || true
  echo "FDT ONBOARDING TESTS FAILED" >&2; exit 1
fi
echo "$out14" | grep -E "^ {6,8}(ok|==) " || true
passed=$((passed + $(echo "$out14" | grep -c "       ok ")))

echo "== cycle window =="
out15=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/cycle-window.sql 2>&1) || true
if echo "$out15" | grep -qE "FAILED|ERROR"; then
  echo "$out15" | grep -E "FAILED|ERROR" || true
  echo "CYCLE WINDOW TESTS FAILED" >&2; exit 1
fi
echo "$out15" | grep -E "^ {7,9}(ok|==) " || true
passed=$((passed + $(echo "$out15" | grep -c "        ok ")))

echo "== rls capability scope =="
out16=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/rls-capability-scope.sql 2>&1) || true
if echo "$out16" | grep -qE "FAILED|ERROR"; then
  echo "$out16" | grep -E "FAILED|ERROR" || true
  echo "RLS CAPABILITY TESTS FAILED" >&2; exit 1
fi
echo "$out16" | grep -E "^ {8,10}(ok|==) " || true
passed=$((passed + $(echo "$out16" | grep -c "         ok ")))

echo "== operational read api =="
out17=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/operational-read-api.sql 2>&1) || true
if echo "$out17" | grep -qE "FAILED|ERROR"; then
  echo "$out17" | grep -E "FAILED|ERROR" || true
  echo "OPERATIONAL READ API TESTS FAILED" >&2; exit 1
fi
echo "$out17" | grep -E "^ {9,11}(ok|==) " || true
passed=$((passed + $(echo "$out17" | grep -c "          ok ")))

echo "== arabic label integrity =="
out18=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/arabic-label-integrity.sql 2>&1) || true
if echo "$out18" | grep -qE "FAILED|ERROR"; then
  echo "$out18" | grep -E "FAILED|ERROR" || true
  echo "ARABIC LABEL TESTS FAILED" >&2; exit 1
fi
echo "$out18" | grep -E "^ {10,12}(ok|==) " || true
passed=$((passed + $(echo "$out18" | grep -c "           ok ")))

echo "== subscriber ownership =="
out19=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/subscriber-ownership.sql 2>&1) || true
if echo "$out19" | grep -qE "FAILED|ERROR"; then
  echo "$out19" | grep -E "FAILED|ERROR" || true
  echo "OWNERSHIP TESTS FAILED" >&2; exit 1
fi
echo "$out19" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out19" | grep -c "            ok ")))

echo "== subscriber transfer =="
out20=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/subscriber-transfer.sql 2>&1) || true
if echo "$out20" | grep -qE "FAILED|ERROR"; then
  echo "$out20" | grep -E "FAILED|ERROR" || true
  echo "TRANSFER TESTS FAILED" >&2; exit 1
fi
echo "$out20" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out20" | grep -c "            ok ")))

echo "== installation holds =="
out22=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/installation-holds.sql 2>&1) || true
if echo "$out22" | grep -qE "FAILED|ERROR"; then
  echo "$out22" | grep -E "FAILED|ERROR" || true
  echo "HOLD TESTS FAILED" >&2; exit 1
fi
echo "$out22" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out22" | grep -c "            ok ")))

echo "== installation payout =="
if ! out23=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/installation-payout.sql 2>&1); then
  echo "$out23" >&2
  echo "PAYOUT TESTS FAILED (psql exited non-zero)" >&2; exit 1
fi
if echo "$out23" | grep -qE "FAILED|ERROR"; then
  echo "$out23" | grep -E "FAILED|ERROR" || true
  echo "PAYOUT TESTS FAILED" >&2; exit 1
fi
echo "$out23" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out23" | grep -c "            ok ")))

echo "== invoice review =="
out24=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/invoice-review.sql 2>&1) || true
if echo "$out24" | grep -qE "FAILED|ERROR"; then
  echo "$out24" | grep -E "FAILED|ERROR" || true
  echo "INVOICE TESTS FAILED" >&2; exit 1
fi
echo "$out24" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out24" | grep -c "            ok ")))

echo "== ownership and contracts =="
out29=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/ownership-and-contracts.sql 2>&1) || true
if echo "$out29" | grep -qE "FAILED|ERROR"; then
  echo "$out29" | grep -E "FAILED|ERROR" || true
  echo "OWNERSHIP CONTRACT TESTS FAILED" >&2; exit 1
fi
echo "$out29" | grep -E "^ {15,18}(ok|==) " || true
passed=$((passed + $(echo "$out29" | grep -c "ok " || true)))

echo "== activation corrections =="
out28=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/activation-corrections.sql 2>&1) || true
if echo "$out28" | grep -qE "FAILED|ERROR"; then
  echo "$out28" | grep -E "FAILED|ERROR" || true
  echo "ACTIVATION CORRECTION TESTS FAILED" >&2; exit 1
fi
echo "$out28" | grep -E "^ {14,16}(ok|==) " || true
passed=$((passed + $(echo "$out28" | grep -c "ok " || true)))

echo "== hot path call counts =="
out27=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/hot-path-call-counts.sql 2>&1) || true
if echo "$out27" | grep -qE "FAILED|ERROR"; then
  echo "$out27" | grep -E "FAILED|ERROR" || true
  echo "HOT PATH TESTS FAILED" >&2; exit 1
fi
echo "$out27" | grep -E "^ {13,15}(ok|==) " || true
passed=$((passed + $(echo "$out27" | grep -c "              ok ")))

echo "== master write domains =="
out26=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/master-write-domains.sql 2>&1) || true
if echo "$out26" | grep -qE "FAILED|ERROR"; then
  echo "$out26" | grep -E "FAILED|ERROR" || true
  echo "MASTER WRITE TESTS FAILED" >&2; exit 1
fi
echo "$out26" | grep -E "^ {12,14}(ok|==) " || true
passed=$((passed + $(echo "$out26" | grep -c "             ok ")))

echo "== payout end to end =="
out25=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/payout-end-to-end.sql 2>&1) || true
if echo "$out25" | grep -qE "FAILED|ERROR"; then
  echo "$out25" | grep -E "FAILED|ERROR" || true
  echo "END TO END TESTS FAILED" >&2; exit 1
fi
echo "$out25" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out25" | grep -c "            ok ")))

echo "== newness parity =="
out21=$(bash tests/sql/newness-parity.sh 2>&1) || true
if [ $? -ne 0 ]; then echo "$out21" >&2; echo "PARITY TESTS FAILED" >&2; exit 1; fi
echo "$out21" | grep -E "^pass  parity" || true
passed=$((passed + $(echo "$out21" | grep -c "^pass  parity")))

echo "== product acceptance read contracts =="
out30=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/product-acceptance-contracts.sql 2>&1) || true
if echo "$out30" | grep -qE "FAILED|ERROR"; then
  echo "$out30" | grep -E "FAILED|ERROR" || true
  echo "PRODUCT ACCEPTANCE CONTRACT TESTS FAILED" >&2; exit 1
fi
echo "$out30" | grep -E "^ {15,18}(ok|==) " || true
passed=$((passed + $(echo "$out30" | grep -c "ok " || true)))

echo "== current cycle and draft lifecycle =="
if ! out31=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/current-cycle-and-draft-lifecycle.sql 2>&1); then
  echo "$out31" >&2
  echo "CURRENT CYCLE TESTS FAILED (psql exited non-zero)" >&2; exit 1
fi
if echo "$out31" | grep -qE "FAILED|ERROR"; then
  echo "$out31" | grep -E "FAILED|ERROR" || true
  echo "CURRENT CYCLE TESTS FAILED" >&2; exit 1
fi
echo "$out31" | grep -E "^ {17,20}(ok|==) " || true
passed=$((passed + $(echo "$out31" | grep -c "                  ok " || true)))

echo "== identity operations (batch 2) =="
out32=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/identity-operations.sql 2>&1) || true
if echo "$out32" | grep -qE "FAILED:|ERROR"; then
  echo "$out32" | grep -E "FAILED:|ERROR" || true
  echo "IDENTITY OPERATIONS TESTS FAILED" >&2; exit 1
fi
echo "$out32" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out32" | grep -c "| pass")))

echo "== batch 4 rule engine (D-01/D-12/D-13/D-14) =="
out33=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/batch4-rule-engine.sql 2>&1) || true
if echo "$out33" | grep -qE "FAILED|ERROR"; then
  echo "$out33" | grep -E "FAILED|ERROR" || true
  echo "BATCH 4 RULE ENGINE TESTS FAILED" >&2; exit 1
fi
echo "$out33" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out33" | grep -c "            ok ")))

echo "== manual exception intake + grace-expired queue (PR-B1) =="
out34=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/manual-exception-and-grace-queue.sql 2>&1) || true
if echo "$out34" | grep -qE "FAILED|ERROR"; then
  echo "$out34" | grep -E "FAILED|ERROR" || true
  echo "MANUAL EXCEPTION / GRACE QUEUE TESTS FAILED" >&2; exit 1
fi
echo "$out34" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out34" | grep -c "            ok ")))

echo "== monthly readiness + grace history (PR-B2) =="
out35=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/monthly-readiness-and-grace-history.sql 2>&1) || true
if echo "$out35" | grep -qE "FAILED|ERROR"; then
  echo "$out35" | grep -E "FAILED|ERROR" || true
  echo "MONTHLY READINESS TESTS FAILED" >&2; exit 1
fi
echo "$out35" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out35" | grep -c "            ok ")))

echo "== pr-b3: live-01 effective ownership + live-02 fdt 94-119 scope =="
out36=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/pr-b3-live01-live02.sql 2>&1) || true
if echo "$out36" | grep -qE "FAILED|ERROR"; then
  echo "$out36" | grep -E "FAILED|ERROR" || true
  echo "PR-B3 LIVE-01/LIVE-02 TESTS FAILED" >&2; exit 1
fi
echo "$out36" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out36" | grep -c "            ok ")))

echo "== pr-b3: live-03 recalculation lifecycle =="
out37=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/pr-b3-recalculation-lifecycle.sql 2>&1) || true
if echo "$out37" | grep -qE "FAILED|ERROR"; then
  echo "$out37" | grep -E "FAILED|ERROR" || true
  echo "PR-B3 LIVE-03 TESTS FAILED" >&2; exit 1
fi
echo "$out37" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out37" | grep -c "            ok ")))

echo "== pr-b3: live-04 manual exception page total =="
out38=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/pr-b3-manual-exception-page-total.sql 2>&1) || true
if echo "$out38" | grep -qE "FAILED|ERROR"; then
  echo "$out38" | grep -E "FAILED|ERROR" || true
  echo "PR-B3 LIVE-04 TESTS FAILED" >&2; exit 1
fi
echo "$out38" | grep -E "^ {11,13}(ok|==) " || true
passed=$((passed + $(echo "$out38" | grep -c "            ok ")))

echo "== pr-b3: activation corrections scope + kpi =="
out39=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q < tests/sql/pr-b3-activation-corrections-kpi.sql 2>&1) || true
if echo "$out39" | grep -qE "FAILED|ERROR"; then
  echo "$out39" | grep -E "FAILED|ERROR" || true
  echo "PR-B3 ACTIVATION CORRECTIONS SCOPE + KPI TESTS FAILED" >&2; exit 1
fi
echo "$out39" | grep -E "^ {18,19}(ok|==) " || true
passed=$((passed + $(echo "$out39" | grep -c "                   ok ")))

echo "== concurrency =="
bash tests/sql/installation-fees-concurrency.sh
bash tests/sql/financial-correction-concurrency.sh

echo
echo "local database assertions passed: $((passed + 1))"
