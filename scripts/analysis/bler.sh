#!/usr/bin/env bash
# Link-level BLER over AWGN with srsRAN 4G's own NR PHY (image siscom/phy-sim:25.10):
#   - LDPC data channel: pusch_nr_bler_test, every MCS of the 64QAM table, 48 PRB x 14 symbols,
#     DMRS type A pos2 + 2 additional (same layout our gNB configures for PUSCH).
#   - Polar control channel: polar_chain_test with our PBCH and DCI 1_0 sizes.
# The ZMQ link of the lab is noiseless, so this is how we see "the channel" effect on MCS/coding.
# Output: results/raw/bler/*.txt (parsed by throughput.py). Does not touch the running network.
#   scripts/analysis/bler.sh            (MCS="0 1 ... 28", PRB=48, STEP=0.5, JOBS=6)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; source "$ROOT/.env"; set +a

IMG=siscom/phy-sim:25.10
OUT="$ROOT/results/raw/bler"
MCS="${MCS:-$(seq -s ' ' 0 28)}"
PRB="${PRB:-48}"
STEP="${STEP:-0.5}"
MAXN="${MAXN:-2000}"     # max transport blocks per SNR point (stops earlier after 100 errors)
JOBS="${JOBS:-6}"

docker image inspect "$IMG" >/dev/null 2>&1 || docker build -t "$IMG" "$ROOT/images/phy-sim"
rm -rf "$OUT"; mkdir -p "$OUT"

# One MCS per job: walk SNR upwards from -8 dB, skip quickly while BLER=1 and stop after
# two consecutive error-free points. Each output line: mcs snr_db bler errors blocks
cat >"$OUT/.ldpc_job.sh" <<'EOF'
m=$1; prb=$2; step=$3; maxn=$4; zeros=0
for snr in $(seq -8 "$step" 32); do
  r=$(pusch_nr_bler_test -p "$prb" -m "$m" -s "$snr" -N "$maxn" 2>&1 | grep -E '^BLER|tbs=|R=' | tr '\n' ' ')
  bler=$(sed -nE 's/.*BLER: ([0-9.e+-]+) \(([0-9]+) errors out of ([0-9]+).*/\1 \2 \3/p' <<<"$r")
  tbs=$(grep -oE 'tbs=[0-9]+' <<<"$r" | tail -1 | cut -d= -f2)
  echo "$m $snr $bler $tbs"
  case "$bler" in 0.000e+00*) zeros=$((zeros + 1)) ;; *) zeros=0 ;; esac
  [ "$zeros" -ge 2 ] && break
done
EOF

echo "==> LDPC/PUSCH BLER: MCS {$MCS}, $PRB PRB, step $STEP dB, $JOBS jobs"
# shellcheck disable=SC2086
printf '%s\n' $MCS | docker run --rm -i --user "$(id -u):$(id -g)" --cpuset-cpus "$CORE_CPUS" -v "$OUT:/out" "$IMG" \
  sh -c "xargs -P $JOBS -I{} sh -c 'bash /out/.ldpc_job.sh {} $PRB $STEP $MAXN > /out/ldpc_mcs{}.txt'"

# Polar: K = payload + 24 CRC bits, E = bits after rate matching, nMax = 9 (downlink).
#   PBCH: 32-bit payload (MIB + extra PBCH bits) -> K=56, E=864 (TS 38.212 7.1.5)
#   DCI 1_0 (39 bits, sized by CORESET#0 = 48 RB) -> K=63, E = 108 x aggregation level (AL 2/4/8)
echo "==> Polar BLER: PBCH and DCI 1_0 at AL 2/4/8"
cat >"$OUT/.polar_job.sh" <<'EOF'
name=$1; k=$2; e=$3
for snr in $(seq -12 0.5 6); do
  wer=$(polar_chain_test -k "$k" -e "$e" -n 9 -s "$snr" -o 1 2>&1 | grep -E 'FLOAT WER' | tail -1 \
        | sed -nE 's/.*WER: ([0-9.]+) ([0-9]+)\/([0-9]+).*/\1 \2/p')   # WER, word errors
  echo "$name $k $e $snr $wer"
  case "$wer" in 0.00000000*) break ;; esac
done
EOF
printf '%s\n' "pbch 56 864" "dci_al2 63 216" "dci_al4 63 432" "dci_al8 63 864" \
  | docker run --rm -i --user "$(id -u):$(id -g)" --cpuset-cpus "$CORE_CPUS" -v "$OUT:/out" "$IMG" \
    sh -c "xargs -P 4 -L1 sh -c 'bash /out/.polar_job.sh \$0 \$1 \$2 > /out/polar_\$0.txt'"

rm -f "$OUT"/.*.sh
echo "Done: $(ls "$OUT" | wc -l) files in results/raw/bler/"
