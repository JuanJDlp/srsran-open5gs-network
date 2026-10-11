#!/bin/bash
# UPF container entrypoint: creates the ogstun device (UE pool gateway) and N6 routing, then runs upfd.
set -euo pipefail

UE_POOL=10.99.0.0/16
UE_GW=10.99.0.1/16
DN_SUBNET=10.88.4.0/24
DN_GW=10.88.4.1

if ! ip link show ogstun >/dev/null 2>&1; then
  ip tuntap add name ogstun mode tun
fi
ip addr replace "$UE_GW" dev ogstun
ip link set ogstun up

# N6: send UE traffic out through the dn network. Traffic to the lab DN keeps the UE source IP
# (the dn container routes 10.99.0.0/16 back via the UPF); anything else (Internet) is NATed and
# leaves through Docker's own NAT on the dn bridge.
dn_if=$(ip -o -4 addr show | awk -v p="10.88.4." '$4 ~ "^"p {print $2; exit}')
ip route replace default via "$DN_GW" dev "$dn_if"
iptables -t nat -C POSTROUTING -s "$UE_POOL" ! -d "$DN_SUBNET" -o "$dn_if" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$UE_POOL" ! -d "$DN_SUBNET" -o "$dn_if" -j MASQUERADE

exec open5gs-upfd -c /config/upf.yaml
