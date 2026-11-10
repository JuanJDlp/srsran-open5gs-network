#!/usr/bin/env bash
# "Core on the Pi" deployment: Open5GS core on a Raspberry Pi 5 (ARM64), gNB on this PC.
# Only N2 (NGAP/SCTP 38412) and N3 (GTP-U/UDP 2152) cross the Ethernet cable; Docker publishes/NATs them.
# Run everything from the PC:
#   scripts/picore.sh core     sync repo to the Pi and start only the core there
#   scripts/picore.sh up       core (Pi) -> gNB on the USRP B200/B210 (PC); waits for NG Setup + cell
#   scripts/picore.sh verify   core + N2 checks (with RADIO=zmq: the full 29 checks + Internet)
#   scripts/picore.sh down     stop the gNB/UE here and the core on the Pi (subscriber DB is kept)
#   scripts/picore.sh logs     last lines of amf/smf/upf (Pi) and the gNB (PC)
# RADIO=zmq tests the same split without a USRP: ZMQ gNB + srsUE, both on this PC.
# PI_HOST=<ssh alias> selects the Pi (default pi-cable). Pi images: make split-build (already built once).
source "$(dirname "$0")/lib.sh"

PI_HOST="${PI_HOST:-pi-cable}"
PI_DIR=5GDockerNetwork                      # relative to the remote user's home
RADIO="${RADIO:-usrp}"
[[ "$RADIO" == usrp || "$RADIO" == zmq ]] || die "RADIO must be usrp or zmq"
PI_IP=$(getent ahostsv4 "$(ssh -G "$PI_HOST" | awk '/^hostname /{print $2}')" | awk '{print $1; exit}')
[[ -n "$PI_IP" ]] || die "cannot resolve the IP of ssh host $PI_HOST"
PC_IP=$(ip -4 route get "$PI_IP" | grep -oE 'src [0-9.]+' | cut -d' ' -f2)
export PI_IP PC_IP
export CORE_HOST="$PI_HOST" GNB_LOCAL=1 GNB_N2_IP="$PC_IP"   # lib.sh/verify.sh: core remote, gNB here
GNB=gnb-usrp; [[ "$RADIO" == zmq ]] && GNB=gnb
STABILITY_S="${STABILITY_S:-20}"

# docker compose on the Pi (core only) and on this PC (gNB, plus the UE in zmq mode).
pdc() {
  ssh "$PI_HOST" "cd $PI_DIR && PI_IP=$PI_IP PC_IP=$PC_IP docker compose --env-file .env --env-file picore-pi.env \
    -f docker-compose.yml -f docker-compose.picore-pi.yml $*"
}
gdc() { docker compose -f docker-compose.yml -f docker-compose.picore-pc.yml --profile ran --profile usrp "$@"; }

# Configs for the Pi side. Docker 27 DNATs a published port to the container's IP on its FIRST network
# (cn: AMF 10.88.1.2, UPF 10.88.1.3), not on ran, and that cannot be chosen. So, only in this mode:
#   amf_picore.yaml  NGAP also listens on 10.88.1.2 (target of the published 38412/sctp)
#   upf_picore.yaml  GTP-U on 10.88.1.3 (target of the published 2152/udp), advertising PI_IP to the gNB
gen_core_cfgs() {
  { echo "# GENERADO por scripts/picore.sh a partir de amf.yaml (no editar, no está en git)."
    echo "# Única diferencia: NGAP escucha también en 10.88.1.2, adonde Docker reenvía el 38412/sctp de la Pi."
    sed -E "s|^( *)- address: 10\.88\.2\.2(.*)$|&\n\1- address: 10.88.1.2          # N2 desde el cable: Docker hace DNAT a la IP cn del AMF|" \
      configs/open5gs/amf.yaml; } > configs/open5gs/amf_picore.yaml
  { echo "# GENERADO por scripts/picore.sh a partir de upf.yaml (no editar, no está en git)."
    echo "# Diferencia: GTP-U (N3) en 10.88.1.3, adonde Docker reenvía el 2152/udp de la Pi, y anuncia $PI_IP al gNB."
    sed -E "s|^( *)- address: 10\.88\.2\.3 .*$|\1- address: 10.88.1.3          # N3 desde el cable (DNAT de Docker a la IP cn del UPF)\n\1  advertise: $PI_IP          # IP N3 que se le anuncia al gNB del PC|" \
      configs/open5gs/upf.yaml; } > configs/open5gs/upf_picore.yaml
  grep -q "10.88.1.2 " configs/open5gs/amf_picore.yaml || die "could not generate amf_picore.yaml"
  grep -q "advertise: $PI_IP" configs/open5gs/upf_picore.yaml || die "could not generate upf_picore.yaml"
}

sync_repo() {
  ssh "$PI_HOST" "mkdir -p $PI_DIR/logs $PI_DIR/captures"
  quiet rsync -a --delete --exclude .git --exclude captures --exclude logs --exclude results \
    --exclude images/phy-sim ./ "$PI_HOST:$PI_DIR/"
}

cmd_core() {
  step "Core on $PI_HOST ($PI_IP) <-> gNB on this PC ($PC_IP)"
  for img in siscom/open5gs:${OPEN5GS_VERSION} siscom/open5gs-webui:${OPEN5GS_VERSION} siscom/dn:1.0 mongo:${MONGO_VERSION}; do
    cdocker image inspect "$img" >/dev/null 2>&1 || die "image $img not found on the Pi: run 'make split-build'"
  done
  gen_core_cfgs
  sync_repo
  # A previous split run (core+gNB on the Pi) may have left its gNB there: it would also register.
  ssh "$PI_HOST" "docker rm -f gnb gnb-usrp >/dev/null 2>&1" || true
  quiet pdc up -d --force-recreate upf amf
  quiet pdc up -d
  for i in $(seq 1 90); do
    running=$(pdc ps --status running -q | wc -l)
    [[ "$running" -ge 13 ]] && break
    sleep 1
  done
  [[ "$running" -ge 13 ]] || die "only $running/13 core containers running on the Pi"
  wait_log amf 'ngap_server\(\) \[10\.88\.2\.2\]:38412' 60 || die "AMF did not open NGAP on 10.88.2.2:38412"
  wait_log smf 'PFCP associated \[10\.88\.1\.3\]' 60 || die "SMF did not associate with the UPF over N4"
  ok "13 containers running on the Pi, NGAP listening, PFCP (N4) associated"
  # The UPF's default route points to N6 (dn); downlink GTP-U to the gNB must leave through cn, where the
  # published 2152/udp lands, so Docker's NAT maps it back to PI_IP:2152. Route lives inside the container.
  cdocker exec upf ip route replace "$PC_IP/32" via 10.88.1.1
  ok "published on the cable: $PI_IP:38412/sctp (N2 -> AMF), $PI_IP:2152/udp (N3 -> UPF)"
  webui_admin && ok "WebUI http://$PI_IP:3000  (admin / 1423)" || warn "could not ensure WebUI admin"
}

usrp_checks() {
  local img=siscom/gnb-uhd:24.10.1 cfg="configs/gnb/gnb_usrp_${BW_MHZ}mhz.yml" probe port speed usb
  docker image inspect "$img" >/dev/null 2>&1 || die "image $img not found: run 'make usrp-build'"
  [[ -f "$cfg" ]] || quiet scripts/gen-radio-configs.sh
  read -r port speed < <(usrp_usb) || die "no Ettus USRP on USB. Check the cable and run lsusb (vendor 2500)"
  ok "USRP found on USB port $port (${speed} Mbit/s before loading firmware)"
  probe=$(gdc run --rm --no-deps -T --entrypoint uhd_usrp_probe gnb-usrp --args type=b200 2>&1) \
    || { echo "$probe" | tail -8; die "uhd_usrp_probe failed"; }
  grep -oE 'Detected Device: \S+' <<<"$probe" | sed 's/^/    /' || die "UHD did not detect the USRP"
  usb=$(grep -oE 'Operating over USB [0-9]' <<<"$probe" | awk '{print $NF}' || true)
  # No ALLOW_USB2 here on purpose: on USB 2 the gNB underflows constantly; move it to a USB 3 port.
  [[ "$usb" == 3 ]] || die "USRP on USB ${usb:-?}: connect it straight to a USB 3 port (not through a hub)"
  ok "UHD: firmware and FPGA loaded, operating over USB 3"
}

cmd_up() {
  step "gNB ($RADIO) requirements"
  if [[ "$RADIO" == usrp ]]; then
    if [[ -n "${USRP_TX_GAIN:-}${USRP_RX_GAIN:-}" ]]; then quiet scripts/gen-radio-configs.sh; fi
    gdc rm -sf ue gnb gnb-usrp >/dev/null 2>&1 || true   # a running gNB holds the USRP
    usrp_checks
  else
    for img in siscom/gnb:24.10.1 siscom/srsue:25.10; do
      docker image inspect "$img" >/dev/null 2>&1 || die "image $img not found: run 'make build'"
    done
    gdc rm -sf ue gnb gnb-usrp >/dev/null 2>&1 || true
    ok "images present, ZMQ profile ${BW_MHZ} MHz"
  fi
  # The local single-PC core must not run at the same time (same container names, would confuse logs).
  if docker ps --format '{{.Names}}' | grep -xE 'amf|upf' >/dev/null; then
    warn "local core is running on this PC: stopping it (core lives on the Pi in this mode)"
    quiet docker compose stop
    quiet docker compose rm -f
  fi

  cmd_core

  step "gNB on this PC -> AMF at $PI_IP:38412 over the cable"
  rm -f logs/gnb.log logs/ue.log
  t0=$(ssh "$PI_HOST" date -u +%Y-%m-%dT%H:%M:%SZ)   # AMF logs are timestamped by the Pi's clock
  quiet gdc up -d "$GNB"
  SINCE=$t0 wait_log amf "gNB-N2 accepted\\[${PC_IP//./\\.}\\]" 90 \
    || { clog "$GNB" | grep -vE '^\s*$' | tail -20; die "no NG Setup from the gNB (docker logs $GNB)"; }
  wait_log "$GNB" '==== gNB started' 30 || die "gNB did not start the cell (docker logs $GNB)"
  ok "N2: NG Setup accepted by the AMF on the Pi (gNB seen as $PC_IP), cell started"
  clog "$GNB" | grep -oE 'Cell pci=.*' | head -1 | sed 's/^/    /'

  if [[ "$RADIO" == zmq ]]; then
    step "srsUE on this PC (ZMQ) - registration and PDU session through the Pi core"
    quiet gdc up -d ue
    wait_log ue 'PDU Session Establishment successful' 120 || die "UE did not get a PDU session (docker logs ue)"
    ue_ip=$(clog ue | grep -oE 'PDU Session Establishment successful\. IP: [0-9.]+' | tail -1 | awk '{print $NF}')
    docker exec ue ip route replace default dev tun_srsue
    ok "PDU session up, UE IP $ue_ip (GTP-U PC <-> Pi over the cable)"
    echo; echo "Next: RADIO=zmq scripts/picore.sh verify"
    return
  fi

  step "Stability (${STABILITY_S} s)"
  SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sleep "$STABILITY_S"
  docker ps --format '{{.Names}}' | grep -x gnb-usrp >/dev/null || die "gnb-usrp stopped (docker logs gnb-usrp)"
  read -r late und ovf < <(SINCE=$SINCE clog gnb-usrp \
    | awk -F'[:;] *' '/^Late:/ { l += $2; u += $4; o += $6 } END { print l + 0, u + 0, o + 0 }')
  msg="Late $late, Underflow $und, Overflow $ovf in ${STABILITY_S} s"
  if (( late + und + ovf <= STABILITY_S / 5 )); then ok "$msg"; else warn "$msg (CPU governor in powersave? USB shared?)"; fi
  echo
  echo "${G}gNB on the air${N} (PC) with the core on the Pi: band n3, ${BW_MHZ} MHz, DL 1842.5 MHz / UL 1747.5 MHz"
  echo "  console : docker attach gnb-usrp   (t = metrics, Ctrl-p Ctrl-q to detach)"
  echo "  core    : WebUI http://$PI_IP:3000 (admin / 1423);  scripts/picore.sh logs"
  echo "  stop    : make picore-down"
}

cmd_verify() {
  if [[ "$RADIO" == zmq ]]; then
    scripts/verify.sh || rc=$?
    step "picore extras - core on the Pi, gNB+UE here, Internet through the 5G network"
    ok "gNB/UE on $(hostname), core on $(ssh "$PI_HOST" hostname) ($PI_IP)"
    if docker exec ue ping -c 3 -W 3 -I tun_srsue 8.8.8.8 | tail -2; then ok "ping 8.8.8.8 through 5G"; else bad "Internet ping failed"; rc=1; fi
    return "${rc:-0}"
  fi
  local fail=0
  chk() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fail=1; fi; }
  step "Core on the Pi + gNB (USRP) here"
  running=$(cdocker ps --filter status=running --format '{{.Names}}' | grep -cE '^(nrf|amf|smf|upf|ausf|udm|udr|pcf|bsf|nssf|mongo|webui|dn)$' || true)
  chk "13 core containers running on the Pi ($running)" test "$running" -ge 13
  logs_has() { SINCE="${3:-}" clog "$1" | grep -E "$2" >/dev/null; }
  chk "N4: SMF-UPF PFCP association" logs_has smf 'PFCP associated'

  chk "UPF advertises N3 $PI_IP" grep -q "advertise: $PI_IP" configs/open5gs/upf_picore.yaml
  chk "gnb-usrp running here" bash -c "[[ \$(docker inspect -f '{{.State.Running}}' gnb-usrp) == true ]]"
  start=$(docker inspect -f '{{.State.StartedAt}}' gnb-usrp 2>/dev/null || echo "")
  chk "AMF accepted gNB $PC_IP (current run)" logs_has amf "gNB-N2 accepted\\[${PC_IP//./\\.}\\]" "$start"
  chk "cell started (gNB log)" logs_has gnb-usrp '==== gNB started'
  regs=$(SINCE="$start" clog amf | grep -c 'Registration complete' || true)
  echo "  UEs registered since the gNB started: $regs (a phone on the cell shows up here)"
  return "$fail"
}

cmd_down() {
  if docker ps --format '{{.Names}}' | grep -x gnb-usrp >/dev/null; then
    docker kill -s INT gnb-usrp >/dev/null 2>&1 || true   # srsRAN shuts the radio down cleanly
    for _ in $(seq 1 10); do docker ps --format '{{.Names}}' | grep -x gnb-usrp >/dev/null || break; sleep 1; done
  fi
  gdc down 2>/dev/null || true
  ok "gNB/UE stopped on this PC"
  pdc down
  ok "core stopped on the Pi (subscriber DB kept)"
}

cmd_logs() {
  for c in amf smf upf; do echo "== $c (Pi)"; clog "$c" | tail -n 15; done
  for c in gnb-usrp gnb ue; do docker ps -a --format '{{.Names}}' | grep -x "$c" >/dev/null || continue
    echo "== $c (PC)"; clog "$c" | tail -n 15; done
}

case "${1:-}" in
  core|up|verify|down|logs) "cmd_$1" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
