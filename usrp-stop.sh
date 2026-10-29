#!/usr/bin/env bash
# Stops the USRP gNB (the radio stops transmitting). The core stays up unless --all is given.
# Usage: ./usrp-stop.sh          gNB only
#        ./usrp-stop.sh --all    gNB + core (subscriber DB is kept; make clean removes it)
source "$(dirname "$0")/scripts/lib.sh"

step "gNB (USRP)"
if docker ps -a --format '{{.Names}}' | grep -x gnb-usrp >/dev/null; then
  # SIGINT first: srsRAN shuts the radio down cleanly; compose rm then removes the container.
  docker kill -s INT gnb-usrp >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do docker ps --format '{{.Names}}' | grep -x gnb-usrp >/dev/null || break; sleep 1; done
  docker compose --profile usrp rm -sf gnb-usrp >/dev/null 2>&1
  ok "gnb-usrp stopped: the USRP is no longer transmitting"
else
  ok "gnb-usrp was not running"
fi

if [[ "${1:-}" == "--all" ]]; then
  step "Core network"
  quiet scripts/down.sh
  ok "core stopped (subscriber DB kept)"
else
  echo "  core still up ($(docker compose ps --status running -q | wc -l) containers). ./usrp-stop.sh --all to stop it"
fi
