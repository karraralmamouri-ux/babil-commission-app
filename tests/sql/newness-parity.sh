#!/usr/bin/env bash
# تكافؤ التصنيف: المتصفّح والخادم يقولان الشيء نفسه.
#
# التصنيف يقرّر ادعاءً مالياً («هذا مشترك جديد»)، وله الآن تنفيذان: JS عند
# الاستيراد وSQL على الخادم. تنفيذان لقاعدةٍ واحدة ينحرفان بصمت ما لم
# يُقارَنا. هنا تُغذّى الحالات نفسها إلى الاثنين وتُقارَن المخرجات حرفياً.
set -euo pipefail

if ! docker exec babil-local-pg psql -U postgres -d babil_local -tAc "select 1" >/dev/null 2>&1; then
  echo "local postgres is not running. Run: npm run localdb:up" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# جانب المتصفّح — الدالة الحقيقية لا نسخةٌ منها.
node tests/sql/newness-parity-js.js > "$tmp/js.txt"

# جانب الخادم — نفس الحالات، مبنيّةً صفوفاً ثم مقروءةً بالدالة الحقيقية.
node tests/sql/newness-parity-sql.js > "$tmp/gen.sql"
docker exec -i babil-local-pg psql -U postgres -d babil_local -q -t -A \
  < "$tmp/gen.sql" 2>&1 | grep -E '^nc-' > "$tmp/sql.txt"

if ! diff -u "$tmp/js.txt" "$tmp/sql.txt" > "$tmp/diff.txt"; then
  echo "FAILED: التصنيف يختلف بين المتصفّح والخادم" >&2
  cat "$tmp/diff.txt" >&2
  exit 1
fi

n=$(wc -l < "$tmp/js.txt" | tr -d ' ')
while read -r line; do
  echo "pass  parity ${line}"
done < "$tmp/js.txt"
echo "newness parity cases compared: $n"
