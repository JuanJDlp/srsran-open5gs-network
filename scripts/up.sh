#!/usr/bin/env bash
# Brings the network up in order: core -> gNB (NG Setup) -> UE (PDU session) -> UE routes.
# Usage: scripts/up.sh            (bandwidth from .env)
#        BW=20 scripts/up.sh      (override bandwidth profile)
source "$(dirname "$0")/lib.sh"

step "Bandwidth profile: ${BW_MHZ} MHz ($GNB_CFG, $UE_CFG)"
[[ -f "$GNB_CFG" && -f "$UE_CFG" ]] || die "missing radio configs for ${BW_MHZ} MHz (run scripts/gen-radio-configs.sh)"
for img in siscom/gnb:24.10.1 siscom/srsue:25.10 siscom/dn:1.0; do
  docker image inspect "$img" >/dev/null 2>&1 || die "image $img not found: run 'make build'"
done

step "Core network (Open5GS) + DN"
quiet docker compose up -d
for i in $(seq 1 60); do
  running=$(docker compose ps --status running -q | wc -l)
  [[ "$running" -ge 13 ]] && break
  sleep 1
done
[[ "$running" -ge 13 ]] || die "only $running/13 core containers running (docker compose ps)"
wait_log amf 'ngap_server\(\) \[10\.88\.2\.2\]:38412' 30 || die "AMF did not open NGAP on 10.88.2.2:38412"
wait_log smf 'PFCP associated \[10\.88\.1\.3\]' 30 || die "SMF did not associate with the UPF over N4"
ok "13 containers running, NGAP listening, PFCP (N4) associated"

step "WebUI admin account"
docker exec webui node -e "
const m=require('mongoose');const A=require('./server/models/account');
(async()=>{await m.connect(process.env.DB_URI);
 if(!(await A.countDocuments({username:'admin'}))){await A.register(new A({username:'admin',roles:['admin']}),'1423');}
 process.exit(0);})().catch(e=>{console.error(e);process.exit(1);});" >/dev/null 2>&1 \
  && ok "http://127.0.0.1:3000  (admin / 1423)" || warn "could not ensure WebUI admin"

step "gNB (srsRAN Project) - restarting gNB and UE together (ZMQ needs both sides fresh)"
dc rm -sf ue gnb >/dev/null 2>&1 || true
rm -f logs/gnb.log logs/ue.log
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
quiet dc up -d gnb
SINCE=$t0 wait_log amf 'gNB-N2 accepted\[10\.88\.2\.20\]' 60 || die "no NG Setup from the gNB (docker logs gnb)"
ok "N2: NG Setup accepted by the AMF"

wait_log gnb 'dl_ssb_arfcn=' 10 || true
gnb_ssb=$(clog gnb | grep -oE 'dl_ssb_arfcn=[0-9]+' | head -1 | cut -d= -f2 || true)
ue_ssb=$(grep -oE '^ssb_nr_arfcn *= *[0-9]+' "$UE_CFG" | grep -oE '[0-9]+$')
if [[ -n "$gnb_ssb" ]]; then
  [[ "$gnb_ssb" == "$ue_ssb" ]] || die "SSB mismatch: gNB dl_ssb_arfcn=$gnb_ssb, UE ssb_nr_arfcn=$ue_ssb (fix scripts/gen-radio-configs.sh)"
  ok "SSB ARFCN matches ($gnb_ssb)"
else
  warn "gNB did not print dl_ssb_arfcn; using UE ssb_nr_arfcn=$ue_ssb"
fi

step "UE (srsUE) - waiting for registration and PDU session (up to 120 s)"
quiet dc up -d ue
wait_log ue 'PDU Session Establishment successful' 120 || die "UE did not get a PDU session (docker logs ue; docker logs amf)"
ue_ip=$(clog ue | grep -oE 'PDU Session Establishment successful\. IP: [0-9.]+' | tail -1 | awk '{print $NF}')
ok "PDU session up, UE IP $ue_ip"

# All UE traffic (except the air link itself, which is on-link) goes through the 5G tunnel.
docker exec ue ip route replace default dev tun_srsue
ok "UE default route -> tun_srsue"

echo
echo "Network is up. Next: make verify"
