#!/usr/bin/env bash
# USRP helpers. up/down are ./usrp-start.sh and ./usrp-stop.sh (core + gNB on a real USRP, no UE).
# Usage: scripts/usrp.sh up|down|probe|logs     (BW=10|15|20 picks configs/gnb/gnb_usrp_<BW>mhz.yml)
source "$(dirname "$0")/lib.sh"

IMG=siscom/gnb-uhd:24.10.1
du() { docker compose --profile ran --profile usrp "$@"; }

# Runs a UHD utility in a throwaway container with the same USB access as the gNB.
uhd_run() { du run --rm --no-deps --entrypoint "$1" gnb-usrp "${@:2}"; }

case "${1:-up}" in
probe)
  docker image inspect "$IMG" >/dev/null 2>&1 || die "image $IMG not found: run 'make usrp-build'"
  uhd_run uhd_find_devices
  uhd_run uhd_usrp_probe --args type=b200 2>&1 | grep -E 'Detected|Operating over|Mboard:|name:|serial|FPGA|Error' || true
  ;;
up) exec ./usrp-start.sh ;;
down) exec ./usrp-stop.sh "${@:2}" ;;
logs)
  clog gnb-usrp | tail -n 40
  ;;
*) die "usage: $0 up|down|probe|logs" ;;
esac
