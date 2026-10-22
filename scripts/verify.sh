#!/usr/bin/env bash
# End-to-end checks. One line per check, exit 1 if any fails.
#   V0 config  V1 core  V2 N2  V3 RRC/registration  V4 PDU session  V5 user data over 5G
source "$(dirname "$0")/lib.sh"

pass=0; fail=0
check() { # check "<description>" <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; pass=$((pass + 1)); else bad "$desc"; fail=$((fail + 1)); fi
}
has_log() { clog "$1" | grep -E "$2" >/dev/null; }  # no -q: with pipefail it SIGPIPEs docker logs

ue_cfg_val() { grep -E "^$1 *=" "$UE_CFG" | head -1 | sed -E 's/^[^=]+= *//; s/ *#.*$//'; }
same() { [[ "$1" == "$2" ]]; }

step "V0 - configuration consistency (${BW_MHZ} MHz)"
check "docker compose config is valid" docker compose --profile ran config -q
check "PLMN 00101 in gNB cell and TA" bash -c "[[ \$(grep -c 'plmn: \"00101\"' '$GNB_CFG') -eq 2 ]]"
check "AMF PLMN 001/01 and TAC 7" bash -c "grep -q 'mcc: 001' configs/open5gs/amf.yaml && grep -q 'tac: 7' configs/open5gs/amf.yaml && grep -q 'tac: 7' '$GNB_CFG'"
check "UE IMSI matches subscriber seed" same "$(ue_cfg_val imsi)" "001010123456780"
check "UE K/OPc match subscriber seed" bash -c "grep -qi \"k: '$(ue_cfg_val k)'\" configs/open5gs/mongo-init.js && grep -qi \"opc: '$(ue_cfg_val opc)'\" configs/open5gs/mongo-init.js"
gnb_srate=$(grep -E '^ *srate:' "$GNB_CFG" | awk '{print $2}')
check "gNB/UE sample rate match (${gnb_srate} MHz)" same "${gnb_srate}e6" "$(ue_cfg_val srate)"

step "V1 - core"
# One `docker ps` (not `compose ps`, which opens one SSH session per container in split mode).
project=$(basename "$ROOT" | tr '[:upper:]' '[:lower:]')
running=$(cdocker ps --filter "label=com.docker.compose.project=$project" --filter status=running \
  --format '{{.Label "com.docker.compose.service"}}' | grep -cvE '^(gnb|ue|tools)$' || true)
check "13 core containers running ($running)" test "$running" -ge 13
check "NRF healthy" bash -c "[[ \$(cdocker inspect -f '{{.State.Health.Status}}' nrf) == healthy ]]"
for nf in amf smf ausf udm udr pcf nssf bsf; do
  check "$nf registered in NRF" has_log "$nf" 'NF registered'
done
check "N4: SMF-UPF PFCP association" has_log smf 'PFCP associated \[10\.88\.1\.3\]'

step "V2 - N2 (NGAP over SCTP)"
check "gnb container running" bash -c "[[ \$(cdocker inspect -f '{{.State.Running}}' gnb) == true ]]"
# Only AMF log lines written after the current gNB started count (older runs leave stale lines).
gnb_start=$(cdocker inspect -f '{{.State.StartedAt}}' gnb 2>/dev/null || echo "")
amf_since() { SINCE="$gnb_start" clog amf | grep -E "$1" >/dev/null; }
check "AMF accepted gNB 10.88.2.20 (current run)" amf_since 'gNB-N2 accepted\[10\.88\.2\.20\]'

step "V3 - radio access and registration"
check "UE: Random Access complete" has_log ue 'Random Access Complete'
check "UE: RRC connected" has_log ue 'RRC Connected'
check "AMF: Registration complete (current run)" amf_since 'Registration complete'

step "V4 - PDU session"
ue_ip=$(docker exec ue ip -4 -o addr show tun_srsue 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
check "UE: PDU session established" has_log ue 'PDU Session Establishment successful'
check "UE has IP in 10.99.0.0/16 on tun_srsue (${ue_ip:-none})" bash -c "[[ '${ue_ip:-}' == 10.99.* ]]"

step "V5 - user plane through the 5G network (UE -> gNB -> GTP-U -> UPF -> N6)"
check "UE route to DN goes via tun_srsue" bash -c "docker exec ue ip route get 10.88.4.10 | grep -q 'dev tun_srsue'"
check "ping UE -> UPF gateway 10.99.0.1" docker exec ue ping -c 3 -W 3 -I tun_srsue 10.99.0.1
check "ping UE -> DN 10.88.4.10" docker exec ue ping -c 3 -W 3 -I tun_srsue 10.88.4.10
check "DN sees the UE IP (no NAT inside the lab)" bash -c "cdocker exec dn ping -c 2 -W 3 '${ue_ip:-0.0.0.0}'"
check "GTP-U counters grew on the UPF (packets crossed N3)" bash -c "cdocker exec upf cat /proc/net/dev | awk '/ogstun/ {exit !(\$3 > 0)}'"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "${G}RESULT: $pass/$pass checks passed${N}"
else
  echo "${R}RESULT: $fail failed, $pass passed${N}"
  exit 1
fi
