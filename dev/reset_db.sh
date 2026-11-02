#!/usr/bin/env bash
# Creates (or recreates) a local Postgres test database from setup.sql.
# Needs PostgreSQL 14+ with pgcrypto. Default socket /tmp/pg, port 5433 (override with PGHOST/PGPORT).
set -e
cd "$(dirname "$0")/.."
H=${PGHOST:-/tmp/pg}; P=${PGPORT:-5433}; DB=${PGDATABASE:-sakal_test}
PSQL="psql -h $H -p $P -U postgres -q"
# Supabase has these roles; a plain Postgres needs them for setup.sql's grants
$PSQL -c "do \$\$ begin create role anon nologin; exception when duplicate_object then null; end \$\$" \
      -c "do \$\$ begin create role authenticated nologin; exception when duplicate_object then null; end \$\$"
$PSQL -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d $DB -v ON_ERROR_STOP=1 -f setup.sql >/dev/null 2>&1
echo "Database $DB ready. Log in as Prince with PIN 1234 (the app will ask for a 6-digit PIN)."
