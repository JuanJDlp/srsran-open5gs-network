#!/usr/bin/env bash
# RF validation of the gNB (USRP) with a HackRF One that ONLY RECEIVES. Runs natively on the host
# (Docker Desktop cannot pass USB devices). Never connect the HackRF straight to the USRP TX port:
# use attenuators (30-60 dB) or antennas inside a shielded box. Max HackRF input: about -5 dBm.
#
#   scripts/rf/rf.sh info       is the HackRF connected? (hackrf_info)
#   scripts/rf/rf.sh params     frequencies/sample rate taken from the gNB config
#   scripts/rf/rf.sh sweep      hackrf_sweep around the carrier -> sweep.csv + sweep.png
#   scripts/rf/rf.sh capture    IQ capture centered on the carrier -> capture.iq + capture.json
#   scripts/rf/rf.sh analyze [file.iq]   SSB/PCI/period/bandwidth checks (default: latest capture)
#   scripts/rf/rf.sh check      capture + analyze
#   scripts/rf/rf.sh selftest   synthetic signal through the analyzer (no hardware needed)
#
# gNB config: GNB_CFG=/path/gnb.yml (the one the USRP gNB really uses). Default: this repo's
# configs/gnb/gnb_zmq_${BW:-10}mhz.yml. SSB_ARFCN=<dl_ssb_arfcn from the gNB log> makes the
# frequency check exact. Tunables: LNA (0-40, step 8, default 16), VGA (0-62, step 2, default 20),
# AMP (0/1, default 0 = HackRF RF amplifier off), DUR (capture seconds, default 1),
# SWEEPS (hackrf_sweep passes, default 20).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-python3}"
ANALYZE="$ROOT/scripts/rf/rf_analyze.py"
OUT_BASE="$ROOT/results/rf"
LNA="${LNA:-16}"
VGA="${VGA:-20}"
AMP="${AMP:-0}"
DUR="${DUR:-1}"
SWEEPS="${SWEEPS:-20}"

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
step() { echo "${B}==> $*${N}"; }
ok()   { echo "${G}  ✔ $*${N}"; }
warn() { echo "${Y}  ! $*${N}"; }
die()  { echo "${R}  ✘ $*${N}"; exit 1; }

mhz() { awk -v v="$1" 'BEGIN { printf "%.4f", v / 1e6 }'; }   # Hz -> MHz text

need() { command -v "$1" >/dev/null || die "$1 not found: brew install hackrf (macOS) / apt install hackrf (Linux)"; }

load_params() { eval "$("$PY" "$ANALYZE" params)"; }

check_gains() {
  (( LNA % 8 == 0 && LNA >= 0 && LNA <= 40 )) || die "LNA must be 0-40 in steps of 8 (got $LNA)"
  (( VGA % 2 == 0 && VGA >= 0 && VGA <= 62 )) || die "VGA must be 0-62 in steps of 2 (got $VGA)"
  [[ "$AMP" == 0 ]] || warn "HackRF RF amplifier ON (+11 dB): only with low input levels"
}

new_run() { RUN="$OUT_BASE/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"; }

cmd_info() {
  need hackrf_info
  step "HackRF"
  local out; out=$(hackrf_info 2>&1 || true)
  echo "$out" | sed 's/^/  /'
  grep -q "Serial number" <<<"$out" && ok "HackRF found" || die "no HackRF found (USB cable? try another port)"
}

cmd_params() {
  load_params
  step "Radio parameters (from $RF_SOURCE)"
  echo "  carrier       $(mhz "$RF_FC_HZ") MHz, ${RF_BW_MHZ} MHz channel"
  if [[ -n "$RF_SSB_HZ" ]]; then echo "  SSB center    $(mhz "$RF_SSB_HZ") MHz"
  else echo "  SSB center    unknown (searched on the sync raster; set SSB_ARFCN to pin it)"; fi
  echo "  capture rate  $(mhz "$RF_FS_HZ") Msps"
  echo "  sweep range   ${RF_SWEEP_LO_MHZ}-${RF_SWEEP_HI_MHZ} MHz"
}

cmd_sweep() {
  need hackrf_sweep; load_params; check_gains; new_run
  step "Sweep ${RF_SWEEP_LO_MHZ}-${RF_SWEEP_HI_MHZ} MHz ($SWEEPS passes, LNA $LNA, VGA $VGA, AMP $AMP)"
  hackrf_sweep -f "${RF_SWEEP_LO_MHZ}:${RF_SWEEP_HI_MHZ}" -w 50000 -N "$SWEEPS" \
    -l "$LNA" -g "$VGA" -a "$AMP" -r "$RUN/sweep.csv" >/dev/null 2>"$RUN/sweep.log" \
    || { tail -3 "$RUN/sweep.log"; die "hackrf_sweep failed"; }
  "$PY" "$ANALYZE" sweep "$RUN/sweep.csv"
}

cmd_capture() {
  need hackrf_transfer; load_params; check_gains; new_run
  local n; n=$(awk -v fs="$RF_FS_HZ" -v d="$DUR" 'BEGIN { printf "%d", fs * d }')
  step "Capture ${DUR} s at $(mhz "$RF_FC_HZ") MHz, $(mhz "$RF_FS_HZ") Msps (LNA $LNA, VGA $VGA, AMP $AMP)"
  hackrf_transfer -r "$RUN/capture.iq" -f "$RF_FC_HZ" -s "$RF_FS_HZ" -n "$n" \
    -l "$LNA" -g "$VGA" -a "$AMP" >"$RUN/capture.log" 2>&1 \
    || { tail -3 "$RUN/capture.log"; die "hackrf_transfer failed"; }
  cat >"$RUN/capture.json" <<EOF
{"fc_hz": $RF_FC_HZ, "fs_hz": $RF_FS_HZ, "dur_s": $DUR, "lna": $LNA, "vga": $VGA, "amp": $AMP,
 "gnb_config": "$RF_SOURCE", "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  ok "$(du -h "$RUN/capture.iq" | cut -f1) -> ${RUN#"$ROOT"/}/capture.iq"
  LAST_CAPTURE="$RUN/capture.iq"
}

cmd_analyze() {
  local f="${1:-${LAST_CAPTURE:-}}"
  [[ -n "$f" ]] || f=$(ls -t "$OUT_BASE"/*/capture.iq 2>/dev/null | head -1 || true)
  [[ -n "$f" && -f "$f" ]] || die "no capture found: run 'scripts/rf/rf.sh capture' first"
  step "Analyze ${f#"$ROOT"/}"
  "$PY" "$ANALYZE" analyze "$f"
}

cmd_selftest() {
  step "Analyzer self-test (synthetic NR downlink, no hardware)"
  "$PY" "$ANALYZE" selftest
}

case "${1:-}" in
  info) cmd_info ;;
  params) cmd_params ;;
  sweep) cmd_sweep ;;
  capture) cmd_capture ;;
  analyze) cmd_analyze "${2:-}" ;;
  check) cmd_capture && cmd_analyze ;;
  selftest) cmd_selftest ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
