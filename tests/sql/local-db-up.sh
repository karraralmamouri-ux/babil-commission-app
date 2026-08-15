#!/usr/bin/env bash
# Starts the throwaway local Postgres used to validate migrations, RLS and RPCs.
#
# This container is disposable and completely isolated: it holds no production
# data, no Supabase credentials and no service-role key. Nothing here ever
# targets a Supabase project.
set -euo pipefail

docker rm -f babil-local-pg >/dev/null 2>&1 || true
docker run -d --name babil-local-pg \
  -e POSTGRES_PASSWORD=localonly \
  -e POSTGRES_DB=babil_local \
  -p 55432:5432 \
  postgres:16-alpine >/dev/null

n=0
until docker exec babil-local-pg psql -U postgres -d babil_local -tAc "select 1" >/dev/null 2>&1; do
  n=$((n+1))
  if [ "$n" -gt 90 ]; then echo "local postgres did not become ready" >&2; exit 1; fi
  sleep 1
done
echo "local postgres ready on 127.0.0.1:55432 (database babil_local)"
