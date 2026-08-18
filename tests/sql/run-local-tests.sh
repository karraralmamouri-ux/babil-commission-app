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
        < tests/sql/installation-fees-rules.sql 2>&1)
echo "$out" | grep -E "pass |FAIL|ERROR" || true
if echo "$out" | grep -qE "FAIL|ERROR"; then echo "RULE TESTS FAILED" >&2; exit 1; fi
passed=$(echo "$out" | grep -c "pass  ")

echo "== end-to-end import =="
out2=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q         < tests/sql/installation-fees-import.sql 2>&1)
echo "$out2" | grep -E "pass |FAIL|ERROR" || true
if echo "$out2" | grep -qE "FAIL|ERROR"; then echo "IMPORT TESTS FAILED" >&2; exit 1; fi
passed=$((passed + $(echo "$out2" | grep -c "pass  ")))

# The historical suite reports through a results table rather than notices, so
# it is counted from that table instead of by grepping for "pass  ".
echo "== initial historical import =="
out3=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/installation-history-rules.sql 2>&1)
if echo "$out3" | grep -qE "FAILED:|ERROR"; then
  echo "$out3" | grep -E "FAILED:|ERROR" || true
  echo "HISTORICAL IMPORT TESTS FAILED" >&2; exit 1
fi
echo "$out3" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out3" | grep -c "| pass")))

echo "== payment eligibility guards =="
out4=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/installation-history-eligibility.sql 2>&1)
if echo "$out4" | grep -qE "FAILED:|ERROR"; then
  echo "$out4" | grep -E "FAILED:|ERROR" || true
  echo "ELIGIBILITY TESTS FAILED" >&2; exit 1
fi
echo "$out4" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out4" | grep -c "| pass")))

echo "== financial write boundary =="
out5=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/financial-write-boundary.sql 2>&1)
if echo "$out5" | grep -qE "FAILED:|ERROR"; then
  echo "$out5" | grep -E "FAILED:|ERROR" || true
  echo "WRITE BOUNDARY TESTS FAILED" >&2; exit 1
fi
echo "$out5" | grep -E "\| (pass|FAIL)" || true
passed=$((passed + $(echo "$out5" | grep -c "| pass")))

echo "== financial correction =="
out6=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q         < tests/sql/financial-correction.sql 2>&1)
if echo "$out6" | grep -qE "FAILED:|ERROR"; then
  echo "$out6" | grep -E "FAILED:|ERROR" || true
  echo "FINANCIAL CORRECTION TESTS FAILED" >&2; exit 1
fi
echo "$out6" | grep -E "| (pass|FAIL)" || true
passed=$((passed + $(echo "$out6" | grep -c "| pass")))

echo "== ledger integration =="
out7=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q         < tests/sql/financial-ledger-integration.sql 2>&1)
if echo "$out7" | grep -qE "FAILED:|ERROR"; then
  echo "$out7" | grep -E "FAILED:|ERROR" || true
  echo "LEDGER INTEGRATION TESTS FAILED" >&2; exit 1
fi
echo "$out7" | grep -E "| (pass|FAIL)" || true
passed=$((passed + $(echo "$out7" | grep -c "| pass")))

echo "== data intelligence foundation =="
out8=$(docker exec -i babil-local-pg psql -U postgres -d babil_local -q \
        < tests/sql/data-intelligence.sql 2>&1)
if echo "$out8" | grep -qE "FAIL|ERROR"; then
  echo "$out8" | grep -E "FAIL|ERROR" || true
  echo "DATA INTELLIGENCE TESTS FAILED" >&2; exit 1
fi
echo "$out8" | grep -E "^ ok " || true
passed=$((passed + $(echo "$out8" | grep -c "^ ok ")))

echo "== concurrency =="
bash tests/sql/installation-fees-concurrency.sh
bash tests/sql/financial-correction-concurrency.sh

echo
echo "local database assertions passed: $((passed + 1))"
