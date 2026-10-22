#!/usr/bin/env bash
# Split deployment: Open5GS core + gNB on a remote ARM64 host (Raspberry Pi 5), srsUE on this PC.
# The ZMQ "radio" (IQ samples) crosses the Ethernet cable; N2/N3/N4/SBI stay inside the Pi.
# Run everything from the PC:
#   scripts/split.sh build    sync repo to the Pi and build its ARM64 images (first time ~1 h)
#   scripts/split.sh up       core (Pi) -> gNB (Pi) -> UE (PC), waits for the PDU session
#   scripts/split.sh verify   verify.sh against both machines + Internet through the 5G network
#   scripts/split.sh down     stop both sides (keeps the subscriber DB on the Pi)
# PI_HOST=<ssh alias> selects the Pi (default pi-cable). Needs key-based SSH and Docker on the Pi.
source "$(dirname "$0")/lib.sh"

PI_HOST="${PI_HOST:-pi-cable}"
PI_DIR=5GDockerNetwork                      # relative to the remote user's home
PI_IP=$(getent ahostsv4 "$(ssh -G "$PI_HOST" | awk '/^hostname /{print $2}')" | awk '{print $1; exit}')
[[ -n "$PI_IP" ]] || die "cannot resolve the IP of ssh host $PI_HOST"
PC_IP=$(ip -4 route get "$PI_IP" | grep -oE 'src [0-9.]+' | cut -d' ' -f2)
export PI_IP PC_IP
export CORE_HOST="$PI_HOST"                 # lib.sh: core/gNB containers live on the Pi
[[ "$BW_MHZ" == 10 ]] || die "split mode only supports BW=10 (lowest sample rate srsUE accepts)"

# docker compose on the Pi (core + gNB) and on this PC (UE only).
pdc() {
  ssh "$PI_HOST" "cd $PI_DIR && PI_IP=$PI_IP PC_IP=$PC_IP docker compose --env-file .env --env-file split-pi.env \
    -f docker-compose.yml -f docker-compose.split-pi.yml $*"
}
udc() { docker compose -f docker-compose.yml -f docker-compose.split-pc.yml --profile ran "$@"; }

sync_repo() {
  ssh "$PI_HOST" "mkdir -p $PI_DIR/logs $PI_DIR/captures"
  quiet rsync -a --delete --exclude .git --exclude captures --exclude logs --exclude results \
    --exclude images/phy-sim ./ "$PI_HOST:$PI_DIR/"
}

cmd_build() {
  step "Syncing repo to $PI_HOST:~/$PI_DIR"
  sync_repo
  step "Building ARM64 images on the Pi (Open5GS + WebUI ~20 min, gNB ~40 min)"
  ssh "$PI_HOST" "cd $PI_DIR && set -e
    docker build -q -t siscom/open5gs:${OPEN5GS_VERSION} images/open5gs
    docker build -q -t siscom/open5gs-webui:${OPEN5GS_VERSION} images/open5gs-webui
    docker build -q -t siscom/dn:1.0 images/dn
    docker build -q -t siscom/gnb:24.10.1 --build-arg JOBS=3 --build-arg MARCH=armv8.2-a+dotprod+fp16 images/gnb   # srsRAN appends +crypto on aarch64
    docker pull -q mongo:${MONGO_VERSION}"
  ok "Pi images ready"
  step "Building the UE image on this PC"
  quiet udc build ue
  ok "siscom/srsue:25.10 ready"
}

cmd_up() {
  step "Pi $PI_HOST ($PI_IP) <-> this PC ($PC_IP), ${BW_MHZ} MHz"
  docker image inspect siscom/srsue:25.10 >/dev/null 2>&1 || die "image siscom/srsue:25.10 not found: run 'make split-build'"
  for img in siscom/open5gs:${OPEN5GS_VERSION} siscom/open5gs-webui:${OPEN5GS_VERSION} siscom/gnb:24.10.1 siscom/dn:1.0; do
    cdocker image inspect "$img" >/dev/null 2>&1 || die "image $img not found on the Pi: run 'make split-build'"
  done
  sync_repo

  step "Core network (Open5GS) + DN on the Pi"
  udc rm -sf ue >/dev/null 2>&1 || true
  pdc --profile ran rm -sf gnb >/dev/null 2>&1 || true
  quiet pdc up -d
  for i in $(seq 1 90); do
    running=$(pdc ps --status running -q | wc -l)
    [[ "$running" -ge 13 ]] && break
    sleep 1
  done
  [[ "$running" -ge 13 ]] || die "only $running/13 core containers running on the Pi"
  wait_log amf 'ngap_server\(\) \[10\.88\.2\.2\]:38412' 60 || die "AMF did not open NGAP on 10.88.2.2:38412"
  wait_log smf 'PFCP associated \[10\.88\.1\.3\]' 60 || die "SMF did not associate with the UPF over N4"
  ok "13 containers running, NGAP listening, PFCP (N4) associated"
  webui_admin && ok "WebUI http://$PI_IP:3000  (admin / 1423)" || warn "could not ensure WebUI admin"

  step "gNB on the Pi (ZMQ TX on $PI_IP:2000, UL from $PC_IP:2001)"
  t0=$(ssh "$PI_HOST" date -u +%Y-%m-%dT%H:%M:%SZ)   # Pi clock: AMF logs are timestamped there
  ssh "$PI_HOST" "rm -f $PI_DIR/logs/gnb.log" 2>/dev/null || true
  quiet pdc --profile ran up -d gnb
  SINCE=$t0 wait_log amf 'gNB-N2 accepted\[10\.88\.2\.20\]' 120 || die "no NG Setup from the gNB (make split-logs)"
  ok "N2: NG Setup accepted by the AMF"

  step "UE on this PC - registration and PDU session over the cable (up to 300 s)"
  rm -f logs/ue.log
  quiet udc up -d ue
  wait_log ue 'PDU Session Establishment successful' 300 || die "UE did not get a PDU session (docker logs ue)"
  ue_ip=$(clog ue | grep -oE 'PDU Session Establishment successful\. IP: [0-9.]+' | tail -1 | awk '{print $NF}')
  ok "PDU session up, UE IP $ue_ip"

  # The ZMQ link to the Pi is not on-link: pin it to the air bridge before the 5G tunnel takes the default.
  docker exec ue ip route replace "$PI_IP/32" via 10.88.3.1
  docker exec ue ip route replace default dev tun_srsue
  ok "UE default route -> tun_srsue (ZMQ to $PI_IP stays on the cable)"
  echo
  echo "Network is up across two machines. Next: make split-verify"
}

cmd_verify() {
  scripts/verify.sh || rc=$?
  step "Split extras - the UE really is on this PC and reaches the Internet through the Pi"
  ok "UE container on $(hostname), gNB/core on $(ssh "$PI_HOST" hostname) ($PI_IP)"
  if docker exec ue ping -c 3 -W 3 -I tun_srsue 8.8.8.8 | tail -2; then ok "ping 8.8.8.8 through 5G"; else bad "Internet ping failed"; rc=1; fi
  return "${rc:-0}"
}

cmd_down() {
  udc --profile capture down 2>/dev/null || true
  pdc --profile ran --profile capture down
}

cmd_logs() {
  for c in amf smf upf gnb; do echo "== $c (Pi)"; clog "$c" | tail -n 15; done
  echo "== ue (PC)"; clog ue | tail -n 15
}

case "${1:-}" in
  build|up|verify|down|logs) "cmd_$1" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
