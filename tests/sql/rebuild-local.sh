#!/usr/bin/env bash
# Rebuilds the throwaway local database from bootstrap + every migration.
set -euo pipefail
docker exec babil-local-pg psql -U postgres -d postgres -q \
  -c "drop database if exists babil_local" -c "create database babil_local" >/dev/null
apply(){ docker exec -i babil-local-pg psql -U postgres -d babil_local -v ON_ERROR_STOP=1 -q < "$1" >/dev/null; }
apply tests/sql/local-bootstrap.sql
for m in supabase/migrations/*.sql; do apply "$m"; done
echo "local database rebuilt from $(ls supabase/migrations/*.sql | wc -l) migrations"
