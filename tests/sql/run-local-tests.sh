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

echo "== concurrency =="
bash tests/sql/installation-fees-concurrency.sh

echo
echo "local database assertions passed: $((passed + 1))"
