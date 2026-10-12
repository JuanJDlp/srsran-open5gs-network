#!/usr/bin/env bash
# Repeatable performance measurements. Only collects raw data into results/raw/<run>/;
# scripts/analysis/throughput.py turns it into CSVs, tables and plots.
#
#   scripts/measure.sh bw     bandwidth sweep (BWS="10 15 20"): latency, TCP/UDP DL/UL, CPU, gNB metrics
#   scripts/measure.sh mcs    fixed-MCS sweep at BW (MCS_LIST="0 4 9 14 19 24 28"): TCP DL/UL + gNB metrics
#   scripts/measure.sh tbs    short debug-log runs to record the TBS the gNB scheduler really uses
#   scripts/measure.sh all    the three above
#
# Every run restarts gNB+UE (scripts/up.sh) with its own gNB overrides file, so runs are independent.
# Tunables: REPS (TCP repetitions, 3), DUR (iperf3 seconds, 10), PINGS (100), UDP_RATE (10M), UDP_SAT (80M).
source "$(dirname "$0")/lib.sh"

MODE="${1:-bw}"
REPS="${REPS:-3}"
DUR="${DUR:-10}"
PINGS="${PINGS:-100}"
UDP_RATE="${UDP_RATE:-10M}"
UDP_SAT="${UDP_SAT:-80M}"   # above every profile's capacity: measures the radio limit without TCP
BWS="${BWS:-10 15 20}"
MCS_LIST="${MCS_LIST:-0 4 9 14 19 24 28}"
TBS_MCS="${TBS_MCS:-28 9 3}"
DN_IP=10.88.4.10
RAW="$ROOT/results/raw"
TMP="$ROOT/results/.tmp"
mkdir -p "$RAW" "$TMP"

now() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }

# write_overrides <file> <min_mcs> <max_mcs> [mac_log_level]
write_overrides() {
  {
    echo "cell_cfg:"
    echo "  pdsch: {min_ue_mcs: $2, max_ue_mcs: $3}"
    echo "  pusch: {min_ue_mcs: $2, max_ue_mcs: $3}"
    echo "metrics: {autostart_stdout_metrics: true}"
    if [[ -n "${4:-}" ]]; then echo "log: {mac_level: $4}"; fi
  } >"$1"
}

# start_ran <bw> <overrides file>: fresh gNB+UE with that profile.
start_ran() {
  BW="$1" GNB_OVERRIDES="$2" "$ROOT/scripts/up.sh" >"$TMP/up.log" 2>&1 \
    || { tail -5 "$TMP/up.log"; die "up.sh failed (BW=$1)"; }
  sleep 3   # let CQI/OLLA settle after the PDU session
}

# gnb_rows <since> <until> <out>: gNB console metric rows (one per UE per second) in that window.
gnb_rows() {
  docker logs --since "$1" --until "$2" gnb 2>&1 | sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g; s/\r//g' \
    | grep -E '^ +[0-9]+ +[0-9a-f]+ +\|' >"$3" || true
}

# stats_loop <out>: docker stats samples until the file $TMP/stop exists.
stats_loop() {
  rm -f "$TMP/stop"
  while [[ ! -f "$TMP/stop" ]]; do
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' gnb ue upf amf smf mongo >>"$1"
  done
}

# iperf <out.json> <args...>: one iperf3 run from the UE to the DN server, retried once if busy.
iperf() {
  local out="$1"; shift
  local t0 t1
  t0=$(now)
  docker exec ue iperf3 -c "$DN_IP" -t "$DUR" -J "$@" >"$out" 2>/dev/null \
    || { sleep 2; docker exec ue iperf3 -c "$DN_IP" -t "$DUR" -J "$@" >"$out" 2>/dev/null; } \
    || warn "iperf3 $* failed (see $out)"
  t1=$(now)
  gnb_rows "$t0" "$t1" "${out%.json}.gnb.txt"
  sleep 1
}

meta() { # meta <dir> <key=value...>
  {
    echo "date=$(date -u +%FT%TZ)"
    echo "host_cpus=$(nproc)"
    echo "gnb_image=siscom/gnb:24.10.1"
    echo "ue_image=siscom/srsue:25.10"
    for kv in "${@:2}"; do echo "$kv"; done
  } >"$1/meta.env"
}

run_bw() {
  local bw dir r
  for bw in $BWS; do
    dir="$RAW/bw${bw}"; rm -rf "$dir"; mkdir -p "$dir"
    step "BW ${bw} MHz -> $dir"
    write_overrides "$TMP/ov.yml" 0 28
    start_ran "$bw" "$TMP/ov.yml"
    meta "$dir" "sweep=bw" "bw_mhz=$bw" "mcs=adaptive" "reps=$REPS" "dur_s=$DUR" "udp_rate=$UDP_RATE" "udp_sat=$UDP_SAT"

    # Latency: idle UE->DN (uplink-initiated), DN->UE (downlink-initiated), DN->UPF (wired part only).
    docker exec ue ping -n -c "$PINGS" -i 0.2 -I tun_srsue "$DN_IP" >"$dir/ping_ue_dn.txt" || true
    docker exec dn ping -n -c "$((PINGS / 2))" -i 0.2 "$(docker exec ue ip -4 -o addr show tun_srsue | awk '{print $4}' | cut -d/ -f1)" >"$dir/ping_dn_ue.txt" || true
    docker exec dn ping -n -c "$((PINGS / 2))" -i 0.2 10.88.4.3 >"$dir/ping_dn_upf.txt" || true
    ok "ping done"

    # TCP downlink (-R) and uplink, REPS times each. During rep 1 of DL: CPU samples + ping under load.
    for r in $(seq 1 "$REPS"); do
      if [[ $r == 1 ]]; then
        stats_loop "$dir/stats_tcp_dl.csv" & local sp=$!
        docker exec ue ping -n -c $((DUR * 4 - 8)) -i 0.2 -I tun_srsue "$DN_IP" >"$dir/ping_ue_dn_loaded.txt" 2>&1 &
        local pp=$!
      fi
      iperf "$dir/tcp_dl_$r.json" -R
      if [[ $r == 1 ]]; then touch "$TMP/stop"; wait "$sp" "$pp" || true; fi
      iperf "$dir/tcp_ul_$r.json"
    done
    ok "TCP DL/UL x$REPS done"

    stats_loop "$dir/stats_udp_ul.csv" & local sp2=$!
    iperf "$dir/udp_ul.json" -u -b "$UDP_RATE"
    touch "$TMP/stop"; wait "$sp2" || true
    iperf "$dir/udp_dl.json" -u -b "$UDP_RATE" -R
    ok "UDP DL/UL at $UDP_RATE done"

    # Saturating UDP: received rate = what the radio+UE can carry, no TCP congestion control involved.
    stats_loop "$dir/stats_udp_dl_sat.csv" & local sp4=$!
    iperf "$dir/udp_dl_sat.json" -u -b "$UDP_SAT" -R
    touch "$TMP/stop"; wait "$sp4" || true
    iperf "$dir/udp_ul_sat.json" -u -b "$UDP_SAT"
    ok "UDP DL/UL saturated at $UDP_SAT done"

    # Idle CPU, for comparison with the loaded samples.
    stats_loop "$dir/stats_idle.csv" & local sp3=$!
    sleep 6; touch "$TMP/stop"; wait "$sp3" || true
  done
}

run_mcs() {
  local bw="${BW_MHZ}" m dir
  for m in $MCS_LIST; do
    dir="$RAW/mcs${m}_bw${bw}"; rm -rf "$dir"; mkdir -p "$dir"
    step "Fixed MCS $m at ${bw} MHz -> $dir"
    write_overrides "$TMP/ov.yml" "$m" "$m"
    start_ran "$bw" "$TMP/ov.yml"
    meta "$dir" "sweep=mcs" "bw_mhz=$bw" "mcs=$m" "reps=1" "dur_s=$DUR"
    iperf "$dir/tcp_dl_1.json" -R
    iperf "$dir/tcp_ul_1.json"
    ok "MCS $m done"
  done
}

# Debug-level scheduler logs are huge; keep only one line per distinct grant shape.
run_tbs() {
  local bw="${BW_MHZ}" m dir="$RAW/tbs_bw${BW_MHZ}"
  rm -rf "$dir"; mkdir -p "$dir"
  meta "$dir" "sweep=tbs" "bw_mhz=$bw" "mcs_list=$TBS_MCS"
  for m in $TBS_MCS; do
    step "Scheduler TBS log, fixed MCS $m at ${bw} MHz"
    write_overrides "$TMP/ov.yml" "$m" "$m" debug
    start_ran "$bw" "$TMP/ov.yml"
    DUR=4 iperf "$TMP/tbs_dl.json" -R
    DUR=4 iperf "$TMP/tbs_ul.json"
    docker stop gnb >/dev/null   # flush the file log
    # PUSCH lines do not print the MCS: tag them with the fixed one.
    grep -oE 'UE PDSCH: .*' logs/gnb.log | sed -E 's/ (h_id|nrtx|k1|dl_bo|olla)=[^ ]*//g; s/ grants:.*//' \
      | sort | uniq -c | sort -rn >"$dir/pdsch_mcs${m}.txt" || true
    grep -oE 'UE PUSCH: .*' logs/gnb.log | sed -E 's/ (h_id|nrtx)=[^ ]*//g; s/ grants:.*//' \
      | sort | uniq -c | sort -rn | sed "s/\$/ mcs=$m/" >"$dir/pusch_mcs${m}.txt" || true
    ok "$(wc -l <"$dir/pdsch_mcs${m}.txt") PDSCH / $(wc -l <"$dir/pusch_mcs${m}.txt") PUSCH grant shapes"
  done
}

case "$MODE" in
  bw) run_bw ;;
  mcs) run_mcs ;;
  tbs) run_tbs ;;
  all) run_tbs; run_mcs; run_bw ;;
  *) die "usage: $0 bw|mcs|tbs|all" ;;
esac

# Leave the network as `make up` would: default profile, adaptive MCS.
step "Restoring default network (BW ${BW_MHZ} MHz, adaptive MCS)"
GNB_OVERRIDES= BW="$BW_MHZ" "$ROOT/scripts/up.sh" >"$TMP/up.log" 2>&1 && ok "network up" || warn "restore failed: make up"
rm -rf "$TMP"
echo "Raw data in results/raw/. Next: python3 scripts/analysis/throughput.py"
