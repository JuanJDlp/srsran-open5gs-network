#!/usr/bin/env bash
# Stops everything. Keeps the Mongo volume unless --volumes is given.
source "$(dirname "$0")/lib.sh"
if [[ "${1:-}" == "--volumes" ]]; then
  docker compose --profile ran --profile capture down -v
else
  docker compose --profile ran --profile capture down
fi
