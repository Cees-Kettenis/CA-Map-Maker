#!/bin/sh
set -eu
: "${POSTGRES_PASSWORD:?Database admin password is required}"
: "${APP_DATABASE_PASSWORD:?Application database password is required}"
psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username="${DATABASE_SETUP_USER:-$POSTGRES_USER}" \
  --dbname="$POSTGRES_DB" \
  --file=/docker-entrypoint-initdb.d/roles.sql.in
