#!/usr/bin/env bash
# Shared helpers. Source it: source "$(dirname "$0")/lib.sh"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
_overrides="${GNB_OVERRIDES:-}"   # caller's value must win over .env
set -a; source "$ROOT/.env"; set +a
BW_MHZ="${BW:-$BW_MHZ}"
GNB_OVERRIDES="${_overrides:-$GNB_OVERRIDES}"
export BW_MHZ GNB_OVERRIDES

GNB_CFG="configs/gnb/gnb_zmq_${BW_MHZ}mhz.yml"
UE_CFG="configs/ue/ue_zmq_${BW_MHZ}mhz.conf"

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
step() { echo "${B}==> $*${N}"; }
ok()   { echo "${G}  ✔ $*${N}"; }
bad()  { echo "${R}  ✘ $*${N}"; }
warn() { echo "${Y}  ! $*${N}"; }
die()  { bad "$*"; exit 1; }

dc() { docker compose --profile ran "$@"; }

# Docker for core/gNB containers. Split deployment (scripts/split.sh) sets CORE_HOST=<ssh alias>
# so they are reached on the remote engine; the UE always runs on this machine.
cdocker() { if [[ -n "${CORE_HOST:-}" ]]; then DOCKER_HOST="ssh://$CORE_HOST" docker "$@"; else docker "$@"; fi; }
export -f cdocker   # verify.sh runs some checks in "bash -c" subshells

# Container logs without ANSI colors. Set SINCE=<timestamp> to only read newer lines.
clog() {
  local d=cdocker; [[ "$1" == ue ]] && d=docker
  $d logs ${SINCE:+--since "$SINCE"} "$1" 2>&1 | sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g; s/\r//g'
}

# Creates the WebUI admin account (admin / 1423) if it does not exist yet.
webui_admin() {
  cdocker exec webui node -e "
const m=require('mongoose');const A=require('./server/models/account');
(async()=>{await m.connect(process.env.DB_URI);
 if(!(await A.countDocuments({username:'admin'}))){await A.register(new A({username:'admin',roles:['admin']}),'1423');}
 process.exit(0);})().catch(e=>{console.error(e);process.exit(1);});" >/dev/null 2>&1
}

# Runs a command quietly; on failure prints its output and exits.
quiet() { local out; out=$("$@" 2>&1) || { echo "$out" | tail -5; die "command failed: $*"; }; }

# wait_log <container> <regex> <timeout_s> : waits until the container log matches.
wait_log() {
  local c="$1" re="$2" t="$3" i
  for ((i = 0; i < t; i++)); do
    if clog "$c" | grep -E "$re" >/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}
