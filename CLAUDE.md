# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A complete 5G Standalone network simulation running entirely in Docker on one host, for SISCOM2 lab
work. Three logical pieces, each a separate Docker image/profile:

- **Core (5GC):** Open5GS 2.7.7, one container per network function (NRF, AMF, SMF, UPF, AUSF, UDM,
  UDR, PCF, BSF, NSSF) plus Mongo + WebUI. Always started (`docker compose up -d`, no profile).
- **gNB:** srsRAN Project `release_24_10_1`, monolithic CU+DU. `profiles: ["ran"]`.
- **UE:** srsUE (srsRAN 4G `release_25_10`) with a software USIM. `profiles: ["ran"]`.

Radio is simulated over ZeroMQ (IQ samples over TCP between gnb and ue containers) — the entire NR
stack runs for real (PHY LDPC/Polar, MAC, RLC, PDCP, RRC, NAS). Nothing is installed on the host
besides Docker; no host routes/iptables/sysctl are touched.

Four Docker bridge networks map 1:1 to 3GPP interface groups, so a tcpdump on a given bridge is a
tcpdump on a specific interface:

| Bridge | Subnet | Interfaces |
|---|---|---|
| `br-5g-cn` | `10.88.1.0/24` | SBI (HTTP/2), N4 (PFCP) |
| `br-5g-ran` | `10.88.2.0/24` | N2 (NGAP/SCTP), N3 (GTP-U); N1/NAS rides inside NGAP |
| `br-5g-air` | `10.88.3.0/24` | Simulated Uu (ZMQ) |
| `br-5g-dn` | `10.88.4.0/24` | N6 |

## Commands

```bash
make build        # builds gnb + srsue images (~15 min first time), pulls Open5GS images
make up           # scripts/up.sh: core -> gNB (NG Setup) -> UE (registration + PDU session), ~30s
make verify       # scripts/verify.sh: 29 end-to-end checks V0-V5, exits non-zero on any failure
make capture      # scripts/capture.sh: per-interface pcaps into captures/ while UE re-registers
make down         # scripts/down.sh: stop everything, keep the subscriber DB volume
make clean         # down --volumes, with a confirmation prompt (also wipes the subscriber DB)
make configs       # scripts/gen-radio-configs.sh: regenerate configs/gnb and configs/ue
make ps            # docker compose ps for the "ran" profile
make logs          # tail amf/smf/upf/gnb/ue logs
make attach-gnb    # docker attach gnb (press t for MCS/CQI/BLER/throughput metrics; detach Ctrl-p Ctrl-q)
make attach-ue     # docker attach ue  (same metrics key, same detach)
make rf-selftest   # scripts/rf/rf.sh: HackRF analyzer self-test (synthetic NR signal, no hardware)
make rf-check      # HackRF (receive-only) capture + SSB/PCI/period checks of a real USRP gNB
```

RF validation (`scripts/rf/`) runs natively on the host, not in Docker (no USB passthrough on Docker
Desktop): `brew install hackrf`. Point it at the gNB config the USRP really uses with
`GNB_CFG=/path/gnb.yml` (default: this repo's ZMQ profile) and pin the SSB with
`SSB_ARFCN=<dl_ssb_arfcn>`. Captures go to `results/rf/<timestamp>/` (`.iq` files are gitignored).
The HackRF is half-duplex with no timed TX/RX, so it can only observe the gNB, never act as its radio.

Bandwidth override: `BW=15 make up` or `BW=20 make up` (default 10 MHz via `BW_MHZ` in `.env`).
CPU pinning is controlled by `CORE_CPUS` / `GNB_CPUS` / `UE_CPUS` in `.env`.

There is no unit test suite — `make verify` *is* the test suite, asserting against live container
state and logs rather than mocks. Run it after every `make up` when validating a change.

To debug a single component, raise its log verbosity and re-run:
```bash
LOG_LEVEL=info scripts/gen-radio-configs.sh && make up
# then inspect logs/gnb.log and logs/ue.log
```

WebUI (subscriber management) at http://127.0.0.1:3000, `admin` / `1423` (seeded by `scripts/up.sh`,
not by Open5GS itself — production Open5GS doesn't create a default admin).

Traffic from the UE: `docker exec ue ping 10.88.4.10`, `docker exec ue iperf3 -c 10.88.4.10 [-R] [-u -b 10M]`,
or `docker exec ue ping 8.8.8.8` (real Internet, routed through the simulated 5G path).

## Architecture notes that matter for changes

- **Startup order is load-bearing.** `scripts/up.sh` brings up the core first and polls AMF/SMF logs
  for NGAP listening + PFCP association before touching the RAN. It then restarts gNB and UE
  *together* (`dc rm -sf ue gnb` then bring both up fresh) because the ZMQ radio link needs both
  sides to start clean — a stale gNB or UE on one end of the ZMQ TCP socket will not resync.
- **Radio configs are generated, not hand-edited.** `configs/gnb/*.yml` and `configs/ue/*.conf` are
  produced by `scripts/gen-radio-configs.sh` from one table of `<bw_mhz, srate_mhz, nof_prb,
  ssb_nr_arfcn, coreset0_index>` tuples. Edit the generator, not the generated files. CORESET#0
  index 6 (48 RB) is used at 10/15 MHz and index 12 (96 RB) at 20 MHz — these are the only indices
  srsUE 25.10 actually locks onto; 5 MHz has no working CORESET#0 and is intentionally not offered.
- **NAS ciphering must stay NEA0-first.** AMF's `ciphering_order` is `[NEA0, NEA1, NEA2]` — srsUE
  25.10 cannot decrypt NAS under NEA2, so the Registration Accept would decode as garbage and the
  gNB would time out waiting for the PDU session. Integrity stays NIA2. Don't "fix" this ordering.
- **Mongo subscriber fields must be numeric, not string-typed doubles.** `configs/open5gs/mongo-init.js`
  seeds the one test subscriber (IMSI `001010123456780`) using `NumberInt`/`NumberLong` explicitly —
  plain JS numbers insert as doubles and break 5G-AKA with an HTTP 500 from the UDM.
- **Radio/network parameters must stay consistent across gNB config, UE config, AMF config, and the
  Mongo seed** (PLMN `001/01`, TAC `7`, SST `1`, DNN `internet`, IMSI/K/OPc). `make verify`'s V0
  stage checks this consistency; if you change one side, update the others and re-run `make verify`.
- **`upf` runs as root with `NET_ADMIN` and a custom entrypoint** (`scripts/upf-entrypoint.sh`) to own
  the `ogstun` TUN device and the UE pool route (`10.99.0.0/16` gateway `10.99.0.1`). There is no NAT
  inside the lab — the DN container gets a static route back to the UE pool via the UPF.
- `scripts/lib.sh` holds shared shell helpers (`step`, `ok`, `bad`, `warn`, `wait_log`, `clog`, `dc`,
  `quiet`) used by `up.sh`, `verify.sh`, and `capture.sh` — check there before adding ad hoc bash
  helpers to one script.
