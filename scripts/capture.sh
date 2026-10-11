#!/usr/bin/env bash
# Captures every interface group while generating traffic, one pcap per Docker bridge:
#   <ts>_ran.pcap  N2 (NGAP/SCTP) + N3 (GTP-U)     <ts>_cn.pcap  SBI (HTTP/2) + N4 (PFCP)
#   <ts>_dn.pcap   N6                               (+ gnb_ngap/gnb_mac/ue_mac_nr/ue_nas pcaps from the apps)
# Usage: scripts/capture.sh [seconds]   (default 40). Re-attaches the UE so registration is captured too.
source "$(dirname "$0")/lib.sh"
dur="${1:-40}"
ts=$(date +%Y%m%d-%H%M%S)

quiet docker compose --profile capture up -d tools
step "Capturing ${dur}s on br-5g-ran, br-5g-cn, br-5g-dn -> captures/${ts}_*.pcap"
for br in ran cn dn; do
  docker exec -d tools timeout "$dur" tcpdump -i "br-5g-$br" -nn -s 0 -w "/captures/${ts}_${br}.pcap"
done
sleep 2

step "Re-attaching gNB + UE (NG Setup, registration and PDU session go into the capture)"
scripts/up.sh >/dev/null
docker exec ue ping -c 5 -i 0.5 10.88.4.10 >/dev/null || warn "ping failed"
docker exec ue ping -c 3 8.8.8.8 >/dev/null || warn "Internet ping failed"
remaining=$(( dur - SECONDS - 2 )); (( remaining > 0 )) && sleep "$remaining"
sleep 3

step "Protocols found"
for br in ran cn dn; do
  f="/captures/${ts}_${br}.pcap"
  protos=$(docker exec tools tshark -r "$f" -T fields -e frame.protocols 2>/dev/null \
    | tr ':' '\n' | grep -E '^(ngap|nas-5gs|gtp|pfcp|http2|icmp|sctp)$' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  ok "${br}: ${protos:-none}"
done
