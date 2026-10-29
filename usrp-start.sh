#!/usr/bin/env bash
# Starts the 5G core + the gNB on a real USRP B200/B210 (no UE), checking everything on the way:
#   1. Docker, gNB image (built if missing) and radio configs (generated if missing)
#   2. USRP on USB (lsusb / sysfs), firmware + FPGA load, and that it ends up on USB 3
#   3. Open5GS core (NGAP + PFCP ready) -> gNB (NG Setup accepted) -> short stability check
# Usage: ./usrp-start.sh                 10 MHz (BW_MHZ from .env)
#        BW=20 ./usrp-start.sh           other bandwidth profile (10|15|20)
#        ALLOW_USB2=1 ./usrp-start.sh    run even if the USRP is on USB 2 (expect underflows)
#        USRP_TX_GAIN=89.75 ./usrp-start.sh   TX gain in dB (B200/B210 max 89.75 ~ +10 dBm; default 80 ~ 0 dBm)
source "$(dirname "$0")/scripts/lib.sh"

IMG=siscom/gnb-uhd:24.10.1
CFG="configs/gnb/gnb_usrp_${BW_MHZ}mhz.yml"
STABILITY_S="${STABILITY_S:-20}"   # seconds watched for Late/Underflow/Overflow after start
du() { docker compose --profile ran --profile usrp "$@"; }
uhd_run() { du run --rm --no-deps -T --entrypoint "$1" gnb-usrp "${@:2}" 2>&1; }

# Prints "<bus>-<port> <speed Mbit/s>" of the first Ettus device found in sysfs.
usrp_usb() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && "$(cat "$d/idVendor")" == 2500 ]] || continue
    echo "$(basename "$d") $(cat "$d/speed")"; return 0
  done
  return 1
}

step "1/5 Requirements"
docker info >/dev/null 2>&1 || die "Docker is not running (sudo systemctl start docker)"
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  warn "image $IMG not found: building it now (~10-15 min, only the first time)"
  docker compose --profile usrp build gnb-usrp || die "image build failed"
fi
if [[ -n "${USRP_TX_GAIN:-}${USRP_RX_GAIN:-}" ]]; then
  # Gains are baked into the generated configs: regenerate with the requested values.
  quiet scripts/gen-radio-configs.sh
  ok "configs regenerated with TX gain ${USRP_TX_GAIN:-80} dB, RX gain ${USRP_RX_GAIN:-40} dB"
fi
[[ -f "$CFG" ]] || { warn "missing $CFG: generating radio configs"; quiet scripts/gen-radio-configs.sh; }
ok "Docker OK, image $IMG, config $CFG"

step "2/5 USRP detection"
# A running gNB holds the USRP: release it (and the ZMQ gNB/UE, which use the same IP) first.
du rm -sf ue gnb gnb-usrp >/dev/null 2>&1 || true
read -r port speed < <(usrp_usb) || die "no Ettus USRP on USB. Check the cable and run lsusb (vendor 2500)"
ok "USRP found on USB port $port (${speed} Mbit/s before loading firmware)"
probe=$(uhd_run uhd_usrp_probe --args type=b200) || { echo "$probe" | tail -8; die "uhd_usrp_probe failed"; }
product=$(grep -oE 'Detected Device: \S+' <<<"$probe" | awk '{print $3}' || true)
serial=$(grep -oE 'serial: \S+' <<<"$probe" | head -1 | awk '{print $2}' || true)
usb=$(grep -oE 'Operating over USB [0-9]' <<<"$probe" | awk '{print $NF}' || true)
[[ -n "$product" ]] || { echo "$probe" | tail -8; die "UHD did not detect the USRP"; }
ok "UHD: ${product} serial ${serial:-?}, firmware and FPGA loaded"
if [[ "$usb" == 3 ]]; then
  read -r port speed < <(usrp_usb) || true
  ok "USB 3 (port $port, ${speed} Mbit/s)"
elif [[ -n "${ALLOW_USB2:-}" ]]; then
  warn "USRP on USB ${usb:-?}: continuing because ALLOW_USB2 is set (expect many underflows)"
else
  die "USRP on USB ${usb:-?}: connect it straight to a USB 3 port (not through a hub). ALLOW_USB2=1 to force"
fi

step "3/5 Core network (Open5GS)"
quiet docker compose up -d
wait_log amf 'ngap_server\(\) \[10\.88\.2\.2\]:38412' 60 || die "AMF did not open NGAP on 10.88.2.2:38412"
wait_log smf 'PFCP associated \[10\.88\.1\.3\]' 60 || die "SMF did not associate with the UPF over N4"
webui_admin || warn "could not ensure WebUI admin"
ok "$(docker compose ps --status running -q | wc -l) containers running, NGAP listening, PFCP (N4) associated"

step "4/5 gNB (srsRAN Project + UHD)"
rm -f logs/gnb.log
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
quiet du up -d gnb-usrp
SINCE=$t0 wait_log amf 'gNB-N2 accepted\[10\.88\.2\.20\]' 90 \
  || { clog gnb-usrp | grep -vE '^\s*$' | tail -20; die "no NG Setup from the gNB (docker logs gnb-usrp)"; }
wait_log gnb-usrp '==== gNB started' 30 || die "gNB did not start the cell (docker logs gnb-usrp)"
ok "N2: NG Setup accepted by the AMF, cell started"
clog gnb-usrp | grep -oE 'Cell pci=.*' | head -1 | sed 's/^/    /'

step "5/5 Stability (${STABILITY_S} s)"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep "$STABILITY_S"
docker ps --format '{{.Names}}' | grep -x gnb-usrp >/dev/null || die "gnb-usrp stopped (docker logs gnb-usrp)"
# srsRAN prints one "Late: x; Underflow: y; Overflow: z;" line per second that had RF events.
read -r late und ovf < <(SINCE=$SINCE clog gnb-usrp \
  | awk -F'[:;] *' '/^Late:/ { l += $2; u += $4; o += $6 } END { print l + 0, u + 0, o + 0 }')
msg="Late $late, Underflow $und, Overflow $ovf in ${STABILITY_S} s"
if (( late + und + ovf <= STABILITY_S / 5 )); then ok "$msg"; else warn "$msg (CPU governor in powersave? USB shared?)"; fi

echo
echo "${G}gNB on the air:${N} ${product} ${serial:-}, band n3, ${BW_MHZ} MHz, DL 1842.5 MHz / UL 1747.5 MHz"
echo "  console : docker attach gnb-usrp   (t = metrics, Ctrl-p Ctrl-q to detach)"
echo "  logs    : make usrp-logs           WebUI: http://127.0.0.1:3000 (admin / 1423)"
echo "  stop    : ./usrp-stop.sh           (./usrp-stop.sh --all also stops the core)"
