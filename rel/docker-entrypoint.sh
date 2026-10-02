#!/bin/sh
set -eu
if [ "${1:-start}" = "start" ]; then
  /app/bin/ca_tools eval 'CATools.Release.migrate()'
fi
exec /app/bin/ca_tools "$@"
